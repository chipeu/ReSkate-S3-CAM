// SPDX-License-Identifier: GPL-3.0-only
// Golden-trace generator for the Dynamic Camera Luau port.
//
// Runs the C++ reference camera (F:\Dev\ReSkate\Engine\Game\Camera, read only) through scripted scenarios and writes, per
// scenario, every input it was given (dt, subject snapshot, extras), every world ray it cast in order (from, to, hit),
// and the output pose plus the key FrameDebug values. The Luau side (tests\replay.lua) feeds the same inputs to the port,
// answers its rays from the recording and compares. Format: tools\trace\FORMAT.md.
//
// The scripted subjects and analytic worlds (Timeline, BoxWorld, QuarterPipe, DropIn, DownhillRun, DownhillPlane, PoleOrWall,
// the carve path) are small copies of the ones in Engine/Game/Camera/Test/s3cam_layers_tests.cpp (GPL-3.0-only, same project).
#include "Engine/Game/Camera/s3_camera.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

using namespace dingosdk::s3cam;
namespace fs = std::filesystem;

namespace {

constexpr float gravity_ms2 = 10.1f;
constexpr float root_height = 0.95f;

// ---------------------------------------------------------------- analytic worlds

// Ground height field: upper level until drop_z, then drop_to (a step down or up); an optional wall plane at z = wall_z.
struct World {
    float upper_y = 0.0f;
    float drop_z = 1.0e9f, drop_to = -2.5f;
    bool has_wall = false;
    float wall_z = 0.0f;

    float surface(float z) const noexcept { return z < drop_z ? upper_y : drop_to; }

    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        std::optional<GroundHit> best;
        float best_t = 2.0f;
        if (has_wall && (from[2] - wall_z) * (to[2] - wall_z) < 0.0f) {
            const float t = (wall_z - from[2]) / std::max(std::abs(to[2] - from[2]), 1e-9f) * (to[2] > from[2] ? 1.0f : -1.0f);
            best = GroundHit{lerp(from, to, t), {0.0f, 0.0f, from[2] < wall_z ? -1.0f : 1.0f}};
            best_t = t;
        }
        constexpr int samples = 96;
        float previous_t = 0.0f;
        bool was_above = from[1] >= surface(from[2]);
        for (int i = 1; i <= samples && was_above; ++i) {
            const float t = static_cast<float>(i) / static_cast<float>(samples);
            const Vec3 p = lerp(from, to, t);
            if (p[1] < surface(p[2])) {
                float low = previous_t, high = t;
                for (int k = 0; k < 24; ++k) {
                    const float mid = 0.5f * (low + high);
                    const Vec3 q = lerp(from, to, mid);
                    (q[1] < surface(q[2]) ? high : low) = mid;
                }
                if (high < best_t) best = GroundHit{lerp(from, to, high), {0.0f, 1.0f, 0.0f}};
                break;
            }
            previous_t = t;
        }
        return best;
    }
};

struct Box {
    Vec3 lo, hi;
};

// World plus boxes (rails, ledges, poles, walls).
struct BoxWorld {
    World ground;
    std::vector<Box> boxes;

    static bool slab(const Vec3& a, const Vec3& b, const Box& box, float& t_hit, Vec3& normal) noexcept {
        float t0 = 0.0f, t1 = 1.0f;
        Vec3 n{0.0f, 0.0f, 0.0f};
        for (int axis = 0; axis < 3; ++axis) {
            const std::size_t k = static_cast<std::size_t>(axis);
            const float d = b[k] - a[k];
            const float lo = box.lo[k], hi = box.hi[k];
            const float start = a[k];
            if (std::abs(d) < 1e-9f) {
                if (start < lo || start > hi) return false;
                continue;
            }
            float ta = (lo - start) / d, tb = (hi - start) / d, sign = -1.0f;
            if (ta > tb) {
                std::swap(ta, tb);
                sign = 1.0f;
            }
            if (ta > t0) {
                t0 = ta;
                n = {0.0f, 0.0f, 0.0f};
                n[k] = sign;
            }
            t1 = std::min(t1, tb);
            if (t0 > t1) return false;
        }
        if (n[0] == 0.0f && n[1] == 0.0f && n[2] == 0.0f) return false; // starts inside: no hit (as a physics ray would)
        t_hit = t0;
        normal = n;
        return true;
    }
    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        std::optional<GroundHit> best = ground(from, to);
        float best_t = 2.0f;
        const float span = length(sub(to, from));
        if (best && span > 1e-9f) best_t = length(sub(best->point, from)) / span;
        for (const Box& box : boxes) {
            float t = 0.0f;
            Vec3 normal{0, 1, 0};
            if (slab(from, to, box, t, normal) && t < best_t) {
                best_t = t;
                best = GroundHit{lerp(from, to, t), normal};
            }
        }
        return best;
    }
};

struct PoleOrWall {
    bool wall = true;
    float z = -1.2f;
    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        const Vec3 d = sub(to, from);
        if (wall) {
            if ((from[2] - z) * (to[2] - z) >= 0.0f) return std::nullopt;
            const float t = (z - from[2]) / d[2];
            return GroundHit{add(from, scale(d, t)), {0.0f, 0.0f, 1.0f}};
        }
        return std::nullopt;
    }
};

struct QuarterPipe {
    static constexpr float radius = 3.0f;
    static float height(float z) noexcept {
        if (z < 0.0f) return radius;
        if (z > radius) return 0.0f;
        const float d = z - radius;
        return radius - std::sqrt(std::max(0.0f, radius * radius - d * d));
    }
    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        constexpr int samples = 64;
        Vec3 prev = from;
        for (int i = 1; i <= samples; ++i) {
            const Vec3 p = lerp(from, to, static_cast<float>(i) / samples);
            if (p[1] <= height(p[2]) && prev[1] > height(prev[2]) - 1e-4f) return GroundHit{p, {0.0f, 1.0f, 0.0f}};
            if (p[1] <= height(p[2]) && i == 1) return GroundHit{from, {0.0f, 1.0f, 0.0f}};
            prev = p;
        }
        return std::nullopt;
    }
};

struct DownhillPlane {
    float tan_t = 0.2f;
    float height(float z) const noexcept { return -tan_t * z; }
    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        const float a = from[1] - height(from[2]), b = to[1] - height(to[2]);
        if (a < 0.0f || b >= 0.0f) return std::nullopt;
        const float f = a / (a - b);
        const float c = std::cos(std::atan(tan_t));
        return GroundHit{lerp(from, to, f), {0.0f, c, tan_t * c}};
    }
};

// ---------------------------------------------------------------- scripted subjects

// A straight ride along +Z with scripted events (hops, spins, flip-trick orbits, manuals, rails, a step, a bail).
struct Timeline {
    float speed = 6.5f;
    struct Rail {
        float z0, z1, h, w;
        int kind; // 0 rail, 1 ledge
        int side; // grind_side
    };
    std::vector<Rail> rails;
    struct Hop {
        float t0, t1;
    };
    std::vector<Hop> hops;
    struct Orbit {
        float tb, te, radius, rps;
    };
    std::vector<Orbit> orbits;
    struct Span {
        float tb, te;
    };
    std::vector<Span> manuals, switched;
    float manual_board_along = -0.18f;
    float drop_z = 1.0e9f, drop_to = 0.0f;
    float bail_t = -1.0f;
    struct Plan {
        float t0, t1, h0, h1, vy;
    };
    std::vector<Plan> plans;

    float ground_y(float z) const { return z < drop_z ? 0.0f : drop_to; }
    float surface(float z) const {
        float h = ground_y(z);
        for (const Rail& r : rails)
            if (z >= r.z0 && z <= r.z1) h = std::max(h, r.h);
        return h;
    }
    float zpos(float t) const {
        constexpr float decay = 1.2f;
        if (bail_t < 0.0f || t <= bail_t) return speed * t;
        return speed * bail_t + speed / decay * (1.0f - std::exp(-decay * (t - bail_t)));
    }
    void hop(float t0, float t1) { hops.push_back({t0, t1}); }
    void ollie(float t0, float vy) { hop(t0, t0 + 2.0f * vy / gravity_ms2); }
    void finalize() {
        plans.clear();
        for (const Hop& h : hops) {
            Plan p{h.t0, h.t1, surface(zpos(h.t0)), surface(zpos(h.t1)), 0.0f};
            const float T = h.t1 - h.t0;
            p.vy = (p.h1 - p.h0) / T + 0.5f * gravity_ms2 * T;
            plans.push_back(p);
        }
    }
    SubjectSnapshot at(float t) const {
        SubjectSnapshot s;
        s.valid = true;
        s.time = t;
        const float z = zpos(t);
        const float surf = surface(z);
        const Plan* plan = nullptr;
        for (const Plan& p : plans)
            if (t >= p.t0 && t < p.t1) plan = &p;
        float root_y = surf + root_height;
        float vy = 0.0f;
        s.physics_state = physics_state::ride;
        s.ground_clearance = root_height;
        s.ground_normal = {0.0f, 1.0f, 0.0f};
        const Rail* rail = nullptr;
        for (const Rail& r : rails)
            if (z >= r.z0 && z <= r.z1) rail = &r;
        if (plan) {
            const float since = t - plan->t0;
            root_y = plan->h0 + plan->vy * since - 0.5f * gravity_ms2 * since * since + root_height;
            vy = plan->vy - gravity_ms2 * since;
            s.physics_state = since < 0.08f ? physics_state::pop : physics_state::air;
            s.ground_clearance = root_y - surf;
        } else if (rail) {
            s.physics_state = physics_state::grind_first;
            s.grind_side = rail->side;
        }
        if (!plan && !rail)
            for (const Span& m : manuals)
                if (t >= m.tb && t < m.te) s.manual = true;
        for (const Span& w : switched)
            if (t >= w.tb && t < w.te) s.switch_stance = true;
        s.forward = {0.0f, 0.0f, 1.0f};
        s.velocity = {0.0f, vy, speed};
        Vec3 board_offset{0.0f, -0.9f, 0.0f};
        for (const Orbit& o : orbits)
            if (t >= o.tb && t < o.te) {
                const float phase = tau * o.rps * (t - o.tb);
                board_offset = add(board_offset, {o.radius * std::cos(phase), o.radius * std::sin(phase), 0.15f * std::sin(2.0f * phase)});
            }
        if (s.manual) board_offset = add(board_offset, {0.0f, 0.04f, manual_board_along});
        if (bail_t >= 0.0f && t >= bail_t) {
            const float tb = t - bail_t;
            s.bailing = true;
            s.onboard = false;
            s.physics_state = physics_state::offboard;
            s.velocity = {0.0f, 0.0f, speed * std::exp(-1.2f * tb)};
            root_y = surf + 0.35f + 0.6f * std::exp(-6.0f * tb);
            s.ground_clearance = root_y - surf;
            const float spin = tau * 1.5f * std::min(tb, 1.2f);
            s.forward = {0.0f, std::sin(spin), std::cos(spin)};
            s.ground_normal = {0.0f, 1.0f, 0.0f};
            board_offset = {0.3f * std::min(tb, 1.5f), -0.5f, 1.2f * std::min(tb, 1.5f)};
        }
        s.position = {0.0f, root_y, z};
        s.board_position = add(s.position, board_offset);
        s.board_valid = true;
        return s;
    }
};

// A planar path with a constant speed and a turn rate omega(t) (carving), integrated at 1 kHz.
struct CarvePath {
    float dt = 0.001f;
    std::vector<Vec3> pos;
    std::vector<float> heading;
    float speed = 7.0f;
    void build(float duration, const std::function<float(float)>& omega_of) {
        const std::size_t n = static_cast<std::size_t>(duration / dt) + 2;
        pos.assign(n, {0.0f, root_height, 0.0f});
        heading.assign(n, 0.0f);
        for (std::size_t i = 1; i < n; ++i) {
            const float t = static_cast<float>(i - 1) * dt;
            heading[i] = heading[i - 1] + omega_of(t) * dt;
            const float th = heading[i - 1];
            pos[i] = {pos[i - 1][0] - std::sin(th) * speed * dt, root_height, pos[i - 1][2] + std::cos(th) * speed * dt};
        }
    }
    SubjectSnapshot at(float t) const {
        const float x = std::clamp(t / dt, 0.0f, static_cast<float>(pos.size() - 2));
        const std::size_t i = static_cast<std::size_t>(x);
        const float f = x - static_cast<float>(i);
        SubjectSnapshot s;
        s.valid = true;
        s.time = t;
        s.position = lerp(pos[i], pos[i + 1], f);
        const float th = heading[i] + (heading[i + 1] - heading[i]) * f;
        s.forward = {-std::sin(th), 0.0f, std::cos(th)};
        s.velocity = scale(s.forward, speed);
        s.ground_clearance = root_height;
        s.board_position = add(s.position, {0.0f, -0.9f, 0.0f});
        s.board_valid = true;
        return s;
    }
};

// Standing, then pushing off to a cruise speed (a start with a wall close behind).
SubjectSnapshot launch_at(float t) {
    SubjectSnapshot s;
    s.valid = true;
    s.time = t;
    const float t0 = 1.5f, accel = 3.0f, top = 6.0f;
    const float u = std::max(0.0f, t - t0), ramp = top / accel;
    const float z = u < ramp ? 0.5f * accel * u * u : 0.5f * accel * ramp * ramp + top * (u - ramp);
    const float v = std::min(top, accel * u);
    s.position = {0.0f, root_height, z};
    s.forward = {0.0f, 0.0f, 1.0f};
    s.velocity = {0.0f, 0.0f, v};
    s.ground_clearance = root_height;
    s.board_position = add(s.position, {0.0f, -0.9f, 0.0f});
    s.board_valid = true;
    return s;
}

// A ride that stops dead (speed 8 until 3 s, then standing).
SubjectSnapshot stop_at(float t) {
    SubjectSnapshot s;
    s.valid = true;
    s.time = t;
    const float speed = 8.0f, stop = 3.0f;
    s.position = {0.0f, root_height, speed * std::min(t, stop)};
    s.forward = {0.0f, 0.0f, 1.0f};
    s.velocity = {0.0f, 0.0f, t >= stop ? 0.0f : speed};
    s.ground_clearance = root_height;
    s.board_position = add(s.position, {0.0f, -0.9f, 0.0f});
    s.board_valid = true;
    return s;
}

// Drop-in: stands on the coping of a 3 m quarter pipe, drops in, rides away on the flat.
SubjectSnapshot drop_in_at(float t) {
    SubjectSnapshot s;
    s.time = t;
    s.valid = true;
    s.forward = {0.0f, 0.0f, 1.0f};
    s.ground_clearance = root_height;
    float z = -0.3f, vz = 0.0f, vy = 0.0f;
    Vec3 n{0.0f, 1.0f, 0.0f};
    if (t > 2.0f) {
        const float k = std::min(1.0f, (t - 2.0f) / 0.75f), a = 0.5f * pi * k;
        const float speed = std::sqrt(2.0f * gravity_ms2 * QuarterPipe::radius * std::sin(a)) + 0.5f;
        if (k < 1.0f) {
            z = QuarterPipe::radius - QuarterPipe::radius * std::cos(a);
            n = {0.0f, std::sin(a), std::cos(a)};
            vz = speed * std::sin(a);
            vy = -speed * std::cos(a);
        } else {
            const float flat_speed = std::sqrt(2.0f * gravity_ms2 * QuarterPipe::radius) + 0.5f;
            z = QuarterPipe::radius + flat_speed * (t - 2.75f);
            vz = flat_speed;
        }
    }
    const float y = QuarterPipe::height(z);
    s.position = add({0.0f, y, z}, scale(n, root_height));
    s.velocity = {0.0f, vy, vz};
    s.ground_normal = n;
    return s;
}

// A carving ride down a plane (15 degrees), heading swinging +-carve_deg.
struct DownhillRun {
    float slope_deg = 15.0f, speed = 9.0f, carve_deg = 20.0f, period = 3.0f, bumps = 0.1f;
    float tan_t() const { return std::tan(slope_deg * degrees); }
    SubjectSnapshot at(float t) const {
        float x = 0.0f, z = 0.0f;
        const int steps = static_cast<int>(t * 240.0f);
        for (int k = 0; k < steps; ++k) {
            const float tk = (static_cast<float>(k) + 0.5f) / 240.0f;
            const float psi = carve_deg * degrees * std::sin(tau * tk / period);
            x += speed * std::sin(psi) / 240.0f;
            z += speed * std::cos(psi) / 240.0f;
        }
        const float tt = tan_t(), c = std::cos(std::atan(tt));
        const float psi = carve_deg * degrees * std::sin(tau * t / period);
        const Vec3 d{std::sin(psi), 0.0f, std::cos(psi)};
        SubjectSnapshot s;
        s.valid = true;
        s.time = t;
        s.physics_state = physics_state::ride;
        s.ground_clearance = root_height;
        const float bump = bumps * std::sin(t * 23.0f) * std::sin(t * 7.0f);
        s.ground_normal = normalized(Vec3{bump, c, tt * c}, {0, 1, 0});
        s.position = {x, -tt * z + root_height / c, z};
        s.velocity = {speed * d[0], -tt * speed * d[2], speed * d[2]};
        s.forward = normalized(s.velocity, {0, 0, 1});
        s.board_position = add(s.position, {0.0f, -0.9f, 0.0f});
        s.board_valid = true;
        return s;
    }
};

// ---------------------------------------------------------------- settings dump / diff

using Pair = std::pair<std::string, std::string>; // dotted C++ path, value token (numbers/true/false bare, enums as a name)

std::string num(double v) {
    char buf[40];
    std::snprintf(buf, sizeof buf, "%.9g", v);
    return buf;
}

std::vector<Pair> flatten(const CameraSettings& c) {
    std::vector<Pair> out;
    const auto F = [&](const char* k, float v) { out.push_back({k, num(v)}); };
    const auto I = [&](const char* k, int v) { out.push_back({k, std::to_string(v)}); };
    const auto B = [&](const char* k, bool v) { out.push_back({k, v ? "true" : "false"}); };
    const auto S = [&](const char* k, const char* v) { out.push_back({k, v}); };
    S("preset", c.preset == CameraPreset::FullS3 ? "FullS3" : "NativePlus");
    S("angle", c.angle == CameraAngle::Low ? "Low" : "High");
    F("fov_override_deg", c.fov_override_deg);
    B("shake_enabled", c.shake_enabled);
    F("orientation.max_pitch_degrees", c.orientation.max_pitch_degrees);
    F("orientation.roll_response", c.orientation.roll_response);
    F("orientation.smoothing_cap", c.orientation.smoothing_cap);
    F("trajectory.gravity", c.trajectory.gravity);
    F("trajectory.step", c.trajectory.step);
    F("trajectory.max_time", c.trajectory.max_time);
    F("points.board_drop", c.points.board_drop);
    F("points.anchor_height", c.points.anchor_height);
    F("points.head_height", c.points.head_height);
    F("points.com_height", c.points.com_height);
    F("points.trajectory_lookahead", c.points.trajectory_lookahead);
    F("pipeline.accel_smoothing_time", c.pipeline.accel_smoothing_time);
    F("pipeline.push_accel_threshold", c.pipeline.push_accel_threshold);
    F("pipeline.push_window", c.pipeline.push_window);
    F("pipeline.repredict_interval", c.pipeline.repredict_interval);
    F("pipeline.floor_clearance", c.pipeline.floor_clearance);
    F("pipeline.teleport_distance", c.pipeline.teleport_distance);
    F("pipeline.resume_reset_time", c.pipeline.resume_reset_time);
    F("pipeline.no_lag_after_reset", c.pipeline.no_lag_after_reset);
    I("pipeline.max_steps_per_update", c.pipeline.max_steps_per_update);
    F("pipeline.shake_distance_scale", c.pipeline.shake_distance_scale);
    B("look.landing_look", c.look.landing_look);
    F("look.landing_look_strength", c.look.landing_look_strength);
    F("look.landing_look_full_drop", c.look.landing_look_full_drop);
    B("look.slope_look", c.look.slope_look);
    F("look.slope_look_strength", c.look.slope_look_strength);
    F("look.vertical_follow", c.look.vertical_follow);
    F("look.response_time", c.look.response_time);
    F("look.manual_focus", c.look.manual_focus);
    F("look.grind_focus", c.look.grind_focus);
    B("look.board_anchor", c.look.board_anchor);
    F("look.closeup_exit_time", c.look.closeup_exit_time);
    F("look.shot_blend", c.look.shot_blend);
    S("shoulder.mode", c.shoulder.mode == ShoulderSide::Off ? "Off" : c.shoulder.mode == ShoulderSide::Manual ? "Manual" : "Auto");
    F("shoulder.offset", c.shoulder.offset);
    I("shoulder.side", c.shoulder.side);
    B("shoulder.goofy", c.shoulder.goofy);
    F("shoulder.switch_time", c.shoulder.switch_time);
    F("follow.strength", c.follow.strength);
    B("follow.dynamic", c.follow.dynamic);
    F("follow.dynamic_speed", c.follow.dynamic_speed);
    F("follow.dynamic_boost", c.follow.dynamic_boost);
    F("follow.horizontal", c.follow.horizontal);
    B("fov.shot_fov", c.fov.shot_fov);
    B("fov.speed_fov", c.fov.speed_fov);
    F("fov.speed_fov_degrees", c.fov.speed_fov_degrees);
    F("fov.speed_fov_min", c.fov.speed_fov_min);
    F("fov.speed_fov_max", c.fov.speed_fov_max);
    B("fov.air_fov", c.fov.air_fov);
    F("fov.air_fov_degrees", c.fov.air_fov_degrees);
    F("fov.air_fov_full_height", c.fov.air_fov_full_height);
    F("fov.smoothing_time", c.fov.smoothing_time);
    B("speed_shake.enabled", c.speed_shake.enabled);
    F("speed_shake.strength", c.speed_shake.strength);
    F("speed_shake.top_speed", c.speed_shake.top_speed);
    B("speed_shake.downhill_boost", c.speed_shake.downhill_boost);
    F("speed_shake.downhill_scale", c.speed_shake.downhill_scale);
    F("speed_shake.downhill_full_degrees", c.speed_shake.downhill_full_degrees);
    B("collision.enabled", c.collision.enabled);
    B("collision.automatic", c.collision.automatic);
    F("collision.radius", c.collision.radius);
    F("collision.min_distance", c.collision.min_distance);
    F("collision.pull_in_time", c.collision.pull_in_time);
    F("collision.release_time", c.collision.release_time);
    F("collision.ground_clearance", c.collision.ground_clearance);
    const auto framing = [&](const std::string& p, const FramingSettings& f) {
        const auto add_f = [&](const char* k, float v) { out.push_back({p + "." + k, num(v)}); };
        const auto add_b = [&](const char* k, bool v) { out.push_back({p + "." + k, v ? "true" : "false"}); };
        add_f("distance_scale", f.distance_scale);
        add_f("height_degrees", f.height_degrees);
        add_f("pitch_degrees", f.pitch_degrees);
        add_b("manual_camera", f.manual_camera);
        add_f("manual_distance", f.manual_distance);
        add_f("manual_height_degrees", f.manual_height_degrees);
        add_f("manual_pitch_degrees", f.manual_pitch_degrees);
        add_b("grind_camera", f.grind_camera);
        add_f("grind_distance", f.grind_distance);
        add_f("grind_height_degrees", f.grind_height_degrees);
        add_f("grind_pitch_degrees", f.grind_pitch_degrees);
        add_f("manual_distance_scale", f.manual_distance_scale);
        add_f("grind_distance_scale", f.grind_distance_scale);
        out.push_back({p + ".manual_mode", f.manual_mode == ManualDistanceMode::Fixed ? "Fixed" : "Speed"});
        add_f("manual_min_distance", f.manual_min_distance);
        add_f("manual_max_distance", f.manual_max_distance);
    };
    framing("framing", c.framing);
    framing("framing_high", c.framing_high);
    B("trick_yaw.enabled", c.trick_yaw.enabled);
    F("trick_yaw.angle_degrees", c.trick_yaw.angle_degrees);
    I("trick_yaw.side", c.trick_yaw.side);
    B("trick_yaw.in_air", c.trick_yaw.in_air);
    B("trick_yaw.on_grinds", c.trick_yaw.on_grinds);
    B("trick_yaw.on_manuals", c.trick_yaw.on_manuals);
    F("trick_yaw.min_air_time", c.trick_yaw.min_air_time);
    F("trick_yaw.in_time", c.trick_yaw.in_time);
    F("trick_yaw.hold_time", c.trick_yaw.hold_time);
    F("trick_yaw.return_time", c.trick_yaw.return_time);
    F("air_camera.follow_height", c.air_camera.follow_height);
    F("air_camera.rise_degrees", c.air_camera.rise_degrees);
    F("air_camera.rise_full_height", c.air_camera.rise_full_height);
    F("air_camera.ease_time", c.air_camera.ease_time);
    B("air_camera.keep_in_frame", c.air_camera.keep_in_frame);
    F("landing_shake.min_fall", c.landing_shake.min_fall);
    F("landing_shake.full_fall", c.landing_shake.full_fall);
    F("landing_shake.speed_weight", c.landing_shake.speed_weight);
    F("distance.min", c.distance.min);
    F("distance.max", c.distance.max);
    F("distance_high.min", c.distance_high.min);
    F("distance_high.max", c.distance_high.max);
    const auto ride = [&](const std::string& p, const RideDistance& r) {
        out.push_back({p + ".mode", r.mode == DistanceMode::Speed ? "Speed" : "Fixed"});
        out.push_back({p + ".slow", num(r.slow)});
        out.push_back({p + ".fast", num(r.fast)});
        out.push_back({p + ".fixed", num(r.fixed)});
    };
    ride("ride_distance", c.ride_distance);
    ride("ride_distance_high", c.ride_distance_high);
    return out;
}

bool is_number(const std::string& v) { return !v.empty() && (std::isdigit(static_cast<unsigned char>(v[0])) || v[0] == '-'); }

std::string json_value(const std::string& v) { return (is_number(v) || v == "true" || v == "false") ? v : "\"" + v + "\""; }

// Nested JSON from dotted paths (consecutive paths share their prefix, which flatten() guarantees).
std::string to_json(const std::vector<Pair>& pairs) {
    std::string out = "{";
    std::string open; // current group
    bool first_in_root = true, first_in_group = true;
    for (const Pair& p : pairs) {
        const auto dot = p.first.find('.');
        const std::string group = dot == std::string::npos ? "" : p.first.substr(0, dot);
        const std::string key = dot == std::string::npos ? p.first : p.first.substr(dot + 1);
        if (group != open) {
            if (!open.empty()) out += "}";
            open = group;
            if (!open.empty()) {
                out += std::string(first_in_root ? "\n" : ",\n") + "  \"" + open + "\": {";
                first_in_root = false;
                first_in_group = true;
            }
        }
        if (group.empty()) {
            out += std::string(first_in_root ? "\n" : ",\n") + "  \"" + key + "\": " + json_value(p.second);
            first_in_root = false;
        } else {
            out += std::string(first_in_group ? "\n" : ",\n") + "    \"" + key + "\": " + json_value(p.second);
            first_in_group = false;
        }
    }
    if (!open.empty()) out += "}";
    return out + "\n}\n";
}

// ---------------------------------------------------------------- scenario plumbing

using Ray = std::function<std::optional<GroundHit>(const Vec3&, const Vec3&)>;

struct Scenario {
    std::string name;
    std::string note;
    float duration = 6.0f;
    float fps = 60.0f;
    float base_fov = 60.0f;
    bool jitter = false; // frame times vary +-40% around 1/fps (deterministic), the subject is sampled at the accumulated time
    CameraSettings settings;
    std::function<SubjectSnapshot(float)> at;
    Ray ray;
};

struct RecordedRay {
    Vec3 from, to;
    bool hit;
    GroundHit result;
};

// The camera's world query: forwards to the scenario's world and records every call, in order.
struct Recorder {
    const Ray* world;
    std::vector<RecordedRay>* log;
    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) noexcept {
        std::optional<GroundHit> r = (*world)(from, to);
        log->push_back({from, to, r.has_value(), r ? *r : GroundHit{}});
        return r;
    }
};

void put_vec(std::string& s, const char* key, const Vec3& v) {
    char buf[160];
    std::snprintf(buf, sizeof buf, " %s_x=%s %s_y=%s %s_z=%s", key, num(v[0]).c_str(), key, num(v[1]).c_str(), key, num(v[2]).c_str());
    s += buf;
}
void put(std::string& s, const char* key, double v) { s += std::string(" ") + key + "=" + num(v); }
void put_bool(std::string& s, const char* key, bool v) { s += std::string(" ") + key + "=" + (v ? "1" : "0"); }

struct Totals {
    int frames = 0, rays = 0, hits = 0;
};

Totals run(const Scenario& sc, const fs::path& dir) {
    CameraMan cam;
    if (!cam.set_settings(sc.settings)) {
        std::printf("scenario %s: settings rejected\n", sc.name.c_str());
        std::exit(1);
    }
    std::vector<RecordedRay> log;
    Ray world = sc.ray;
    Recorder recorder{&world, &log};

    const std::vector<Pair> all = flatten(sc.settings);
    const std::vector<Pair> defaults = flatten(CameraSettings{});

    std::string text;
    text += "dyncam-trace 1\n";
    text += "scenario " + sc.name + "\n";
    text += "note " + sc.note + "\n";
    text += "fps " + num(sc.fps) + "\n";
    for (std::size_t i = 0; i < all.size(); ++i)
        if (all[i].second != defaults[i].second) text += "set " + all[i].first + " " + all[i].second + "\n";

    const int count = static_cast<int>(std::lround(sc.duration * sc.fps));
    text += "frames " + std::to_string(count) + "\n";

    static const float jitter_pattern[8] = {0.8f, 1.2f, 1.0f, 0.9f, 1.1f, 1.4f, 0.6f, 1.0f};
    Totals totals;
    float t = 0.0f;
    for (int i = 0; i < count; ++i) {
        float dt = 1.0f / sc.fps;
        if (sc.jitter) dt *= jitter_pattern[i % 8];
        if (i > 0) t += dt;
        else if (sc.jitter) dt = 1.0f / sc.fps;
        const SubjectSnapshot s = sc.at(t);
        FrameExtras extras;
        extras.base_fov_deg = sc.base_fov;
        log.clear();
        const Frame& f = cam.update(dt, s, recorder, extras);

        char buf[512];
        std::string line;
        std::snprintf(buf, sizeof buf, "F %d dt=%s t=%s base_fov=%s", i, num(dt).c_str(), num(s.time).c_str(), num(extras.base_fov_deg).c_str());
        line += buf;
        put_vec(line, "position", s.position);
        put_vec(line, "forward", s.forward);
        put_vec(line, "velocity", s.velocity);
        put(line, "physics_state", s.physics_state);
        put_bool(line, "onboard", s.onboard);
        put_bool(line, "bailing", s.bailing);
        put_bool(line, "manual", s.manual);
        put(line, "grind_side", s.grind_side);
        put_bool(line, "switch_stance", s.switch_stance);
        put_vec(line, "board_position", s.board_position);
        put_bool(line, "board_valid", s.board_valid);
        put_vec(line, "ground_normal", s.ground_normal);
        put(line, "ground_clearance", s.ground_clearance);
        put_bool(line, "valid", s.valid);
        text += line + "\n";

        for (const RecordedRay& r : log) {
            std::string rl = "R";
            put_vec(rl, "from", r.from);
            put_vec(rl, "to", r.to);
            put_bool(rl, "hit", r.hit);
            if (r.hit) {
                put_vec(rl, "point", r.result.point);
                put_vec(rl, "normal", r.result.normal);
            }
            text += rl + "\n";
            ++totals.rays;
            totals.hits += r.hit ? 1 : 0;
        }

        const FrameDebug& d = f.debug;
        std::string ol = "O";
        put_bool(ol, "valid", f.valid);
        ol += std::string(" shot=") + std::string(d.shot_name);
        put_vec(ol, "pos", f.pos);
        put_vec(ol, "right", f.right);
        put_vec(ol, "up", f.up);
        put_vec(ol, "back", f.back);
        put(ol, "fov_deg", f.fov_deg);
        put_bool(ol, "reset", d.reset);
        put_bool(ol, "held", d.held);
        put(ol, "steps", d.steps);
        put(ol, "accumulator", d.accumulator);
        put_bool(ol, "airborne", d.airborne);
        put_bool(ol, "landing_active", d.landing_active);
        put_bool(ol, "transitioning", d.transitioning);
        put(ol, "shot_fraction", d.shot_fraction);
        put(ol, "chase_blend", d.chase_blend);
        put_bool(ol, "prediction_valid", d.prediction_valid);
        put(ol, "predicted_max_height", d.predicted_max_height);
        put(ol, "predicted_air_time", d.predicted_air_time);
        put(ol, "predicted_landing_delta", d.predicted_landing_delta);
        put(ol, "heading", d.heading);
        put(ol, "elevation", d.elevation);
        put(ol, "distance", d.distance);
        put(ol, "speed", d.speed);
        put(ol, "fov_base", d.fov_base);
        put(ol, "fov_extra", d.fov_extra);
        put(ol, "shoulder", d.shoulder);
        put(ol, "follow_strength", d.follow_strength);
        put(ol, "collision_pull", d.collision_pull);
        put(ol, "trick_yaw", d.trick_yaw);
        put(ol, "keep_weight", d.keep_weight);
        put(ol, "focus_weight", d.focus_weight);
        put(ol, "board_weight", d.board_weight);
        put(ol, "floor_weight", d.floor_weight);
        put(ol, "height_offset", d.height_offset);
        put(ol, "follow_weight", d.follow_weight);
        put(ol, "view_heading", d.view_heading);
        put(ol, "ramp_side", d.ramp_side);
        put(ol, "collision_rays", d.collision_rays);
        put_vec(ol, "orbit_anchor", d.orbit_anchor);
        put_vec(ol, "skater_anchor", d.skater_anchor);
        put_vec(ol, "look_target", d.look_target);
        text += ol + "\n";
        ++totals.frames;
    }

    // The trace as a Luau data module (the offline runner has no io library: it can only require() .lua files).
    {
        std::FILE* out = std::fopen((dir / ("trace_" + sc.name + ".lua")).string().c_str(), "wb");
        if (!out) {
            std::printf("cannot write into %s\n", dir.string().c_str());
            std::exit(1);
        }
        std::fputs("-- generated by tools/trace/trace_gen.exe: do not edit. Format: tools/trace/FORMAT.md\nreturn [==[\n", out);
        std::fwrite(text.data(), 1, text.size(), out);
        std::fputs("]==]\n", out);
        std::fclose(out);
    }
    {
        std::FILE* out = std::fopen((dir / ("settings_" + sc.name + ".json")).string().c_str(), "wb");
        const std::string json = to_json(all);
        std::fwrite(json.data(), 1, json.size(), out);
        std::fclose(out);
    }
    return totals;
}

// ---------------------------------------------------------------- scenario catalogue

Scenario base(const std::string& name, float duration, std::function<SubjectSnapshot(float)> at, Ray ray) {
    Scenario s;
    s.name = name;
    s.duration = duration;
    s.at = std::move(at);
    s.ray = std::move(ray);
    return s;
}

Ray flat_world() { return [w = std::make_shared<BoxWorld>()](const Vec3& a, const Vec3& b) { return (*w)(a, b); }; }

Scenario from_timeline(const std::string& name, float duration, Timeline tl, BoxWorld world = {}) {
    world.ground.drop_z = tl.drop_z;
    world.ground.drop_to = tl.drop_to;
    for (const Timeline::Rail& r : tl.rails) world.boxes.push_back({{-0.5f * r.w, 0.0f, r.z0}, {0.5f * r.w, r.h, r.z1}});
    tl.finalize();
    auto shared = std::make_shared<BoxWorld>(world);
    return base(name, duration, [tl](float t) { return tl.at(t); }, [shared](const Vec3& a, const Vec3& b) { return (*shared)(a, b); });
}

// ollie, manual, ollie with a flip-trick board orbit: the shared ride for the settings variants.
Timeline trick_ride() {
    Timeline tl;
    tl.ollie(1.2f, 3.5f);
    tl.manuals.push_back({2.4f, 3.8f});
    tl.ollie(4.2f, 4.0f);
    tl.orbits.push_back({4.25f, 4.95f, 0.35f, 3.0f});
    return tl;
}

CarvePath* carve_path(float speed) {
    auto* path = new CarvePath(); // lives for the whole run
    path->speed = speed;
    path->build(8.0f, [](float t) {
        if (t < 1.0f) return 0.0f;
        return 40.0f * degrees * std::sin(tau * (t - 1.0f) / 3.0f);
    });
    return path;
}
Scenario carve(const std::string& name, float speed, float fps = 60.0f) {
    CarvePath* path = carve_path(speed);
    Scenario s = base(name, 7.0f, [path](float t) { return path->at(t); }, flat_world());
    s.fps = fps;
    return s;
}

std::vector<Scenario> catalogue() {
    std::vector<Scenario> list;
    const auto add = [&](Scenario s, const char* note) {
        s.note = note;
        list.push_back(std::move(s));
    };

    // ---- the plan's scenarios at the default settings, 60 fps
    {
        Timeline tl;
        tl.speed = 3.0f;
        Scenario s = from_timeline("flat_slow", 5.0f, tl);
        s.base_fov = 0.0f; // the game's lens unknown: the chase lens
        add(s, "flat ride at 3 m/s, base fov unknown (0)");
    }
    {
        Timeline tl;
        tl.speed = 9.0f;
        add(from_timeline("flat_fast", 5.0f, tl), "flat ride at 9 m/s");
    }
    {
        Timeline tl;
        tl.speed = 40.0f;
        add(from_timeline("flat_40", 5.0f, tl), "flat ride at 40 m/s");
    }
    add(base("ride_stop", 6.0f, stop_at, flat_world()), "8 m/s then stopping dead at 3 s");
    {
        Scenario s = base("start_wall_behind", 6.0f, launch_at, [w = std::make_shared<PoleOrWall>()](const Vec3& a, const Vec3& b) { return (*w)(a, b); });
        add(s, "standing 1.2 m from a wall behind, pushing off: collision pull in then release");
    }
    {
        Timeline tl;
        tl.ollie(1.0f, 3.0f);
        tl.ollie(2.4f, 3.5f);
        tl.ollie(3.8f, 2.5f);
        tl.ollie(5.0f, 4.0f);
        add(from_timeline("hops", 7.0f, tl), "four ollies of different heights");
    }
    add(carve("carving", 7.0f), "slalom carve at 7 m/s");
    {
        DownhillRun run;
        auto plane = std::make_shared<DownhillPlane>(DownhillPlane{run.tan_t()});
        Scenario s = base("downhill", 6.0f, [run](float t) { return run.at(t); }, [plane](const Vec3& a, const Vec3& b) { return (*plane)(a, b); });
        add(s, "15 degree plane, 9 m/s, carving +-20 degrees, normal noise");
    }
    {
        Timeline tl;
        tl.drop_z = tl.speed * 2.4f;
        tl.drop_to = 0.6f;
        tl.hop(1.9f, 2.9f);
        add(from_timeline("step_up_landing", 6.0f, tl), "hop onto a 0.6 m step-up ledge, ride on");
    }
    {
        Timeline tl;
        tl.drop_z = tl.speed * 2.4f;
        tl.drop_to = -3.0f;
        tl.hop(1.9f, 2.9f);
        add(from_timeline("drop_off", 6.0f, tl), "ride off a 3 m drop, land on the lower level");
    }
    {
        // A corridor: walls on both sides at x = +-1.4 over a slalom carve, so the camera meets walls beside it.
        CarvePath* path = carve_path(5.0f);
        auto world = std::make_shared<BoxWorld>();
        world->boxes.push_back({{1.4f, 0.0f, 3.0f}, {3.4f, 5.0f, 60.0f}});
        world->boxes.push_back({{-3.4f, 0.0f, 3.0f}, {-1.4f, 5.0f, 60.0f}});
        Scenario s = base("wall_beside", 7.0f, [path](float t) { return path->at(t); }, [world](const Vec3& a, const Vec3& b) { return (*world)(a, b); });
        add(s, "slalom carve at 5 m/s between two walls 2.8 m apart");
    }
    add(base("drop_in", 6.0f, drop_in_at, [w = std::make_shared<QuarterPipe>()](const Vec3& a, const Vec3& b) { return (*w)(a, b); }), "drop-in from the coping of a 3 m quarter pipe");
    {
        Timeline tl;
        tl.ollie(1.5f, 9.0f);
        tl.orbits.push_back({1.6f, 2.4f, 0.35f, 2.0f});
        add(from_timeline("big_air", 6.0f, tl), "a 4 m high ollie with a flip, landing, riding on");
    }
    {
        Timeline tl;
        tl.manuals.push_back({1.5f, 5.0f});
        tl.speed = 5.0f;
        add(from_timeline("manual_regular", 6.0f, tl), "manual from 1.5 to 5 s, regular stance");
    }
    {
        Timeline tl;
        tl.manuals.push_back({1.5f, 5.0f});
        tl.switched.push_back({0.0f, 7.0f});
        tl.speed = 5.0f;
        add(from_timeline("manual_switch", 6.0f, tl), "manual from 1.5 to 5 s, switch stance");
    }
    {
        Timeline tl;
        tl.rails.push_back({16.0f, 28.0f, 0.4f, 0.15f, 0, 1});
        tl.rails.push_back({40.0f, 50.0f, 0.45f, 0.4f, 1, -1});
        tl.hop(1.9f, 2.7f);
        tl.hop(5.5f, 6.3f);
        add(from_timeline("grind", 8.0f, tl), "a rail (grind side +1) and a ledge (grind side -1), each landed by a hop");
    }
    {
        Timeline tl;
        tl.ollie(1.2f, 3.5f);
        tl.bail_t = 3.4f;
        add(from_timeline("bail", 6.0f, tl), "ollie, then a bail at 3.4 s (wipeout shot)");
    }

    // ---- settings variants on the shared trick ride (ollie, manual, flip ollie), 6 s
    const auto mixed = [&](const std::string& name, float fps, const char* note, const std::function<void(Scenario&)>& change, bool jitter = false) {
        Scenario s = from_timeline(name, 6.0f, trick_ride());
        s.fps = fps;
        s.jitter = jitter;
        change(s);
        add(s, note);
    };
    mixed("mixed_low_60", 60.0f, "defaults (Low), 60 fps", [](Scenario&) {});
    mixed("mixed_low_144", 144.0f, "defaults (Low), 144 fps", [](Scenario&) {});
    mixed("mixed_jitter_144", 144.0f, "defaults (Low), uneven frame times around 144 fps", [](Scenario&) {}, true);
    mixed("mixed_high_60", 60.0f, "High angle, 60 fps", [](Scenario& s) {
        s.settings.angle = CameraAngle::High;
        s.base_fov = 65.0f;
    });
    mixed("mixed_high_144", 144.0f, "High angle, 144 fps", [](Scenario& s) { s.settings.angle = CameraAngle::High; });
    mixed("mixed_fixed_low", 60.0f, "Low, ride distance Fixed 3.2 m", [](Scenario& s) {
        s.settings.ride_distance.mode = DistanceMode::Fixed;
        s.settings.ride_distance.fixed = 3.2f;
    });
    mixed("mixed_speed_high", 60.0f, "High, ride distance Speed 2.4 to 5.5 m", [](Scenario& s) {
        s.settings.angle = CameraAngle::High;
        s.settings.ride_distance_high.mode = DistanceMode::Speed;
        s.settings.ride_distance_high.slow = 2.4f;
        s.settings.ride_distance_high.fast = 5.5f;
    });
    mixed("mixed_fixed_high_144", 144.0f, "High, ride distance Fixed 4 m, 144 fps", [](Scenario& s) {
        s.settings.angle = CameraAngle::High;
        s.settings.ride_distance_high.mode = DistanceMode::Fixed;
        s.settings.ride_distance_high.fixed = 4.0f;
    });
    mixed("mixed_follow1", 60.0f, "follow.strength 1, dynamic boost off", [](Scenario& s) { s.settings.follow.dynamic = false; });
    mixed("mixed_follow4_dynamic", 60.0f, "follow.strength 4 with the dynamic speed boost", [](Scenario& s) {
        s.settings.follow.strength = 4.0f;
        s.settings.follow.dynamic = true;
        s.settings.follow.dynamic_boost = 1.5f;
    });

    // ---- follow strength and horizontal follow on the carve (heading changes are what they act on)
    const auto carved = [&](const std::string& name, float fps, const char* note, const std::function<void(Scenario&)>& change) {
        Scenario s = carve(name, 10.0f, fps);
        change(s);
        add(s, note);
    };
    carved("carve_follow1", 60.0f, "carve at 10 m/s, follow.strength 1, boost off", [](Scenario& s) { s.settings.follow.dynamic = false; });
    carved("carve_follow4", 60.0f, "carve at 10 m/s, follow.strength 4 with the dynamic boost", [](Scenario& s) {
        s.settings.follow.strength = 4.0f;
        s.settings.follow.dynamic = true;
    });
    carved("carve_horizontal0", 60.0f, "carve at 10 m/s, follow.horizontal 0", [](Scenario& s) { s.settings.follow.horizontal = 0.0f; });
    carved("carve_horizontal10", 60.0f, "carve at 10 m/s, follow.horizontal 10", [](Scenario& s) { s.settings.follow.horizontal = 10.0f; });
    carved("carve_horizontal10_144", 144.0f, "carve at 10 m/s, follow.horizontal 10, 144 fps", [](Scenario& s) { s.settings.follow.horizontal = 10.0f; });
    carved("carve_h5_follow4", 60.0f, "carve at 10 m/s, follow.horizontal 5, follow.strength 4", [](Scenario& s) {
        s.settings.follow.horizontal = 5.0f;
        s.settings.follow.strength = 4.0f;
    });

    // ---- shoulder, close-up and framing options on the grind/manual rides
    {
        Timeline tl = trick_ride();
        Scenario s = from_timeline("mixed_shoulder_auto", 6.0f, tl);
        s.settings.shoulder.mode = ShoulderSide::Auto;
        s.settings.shoulder.goofy = true;
        add(s, "shoulder Auto (goofy), the rest default");
    }
    {
        Timeline tl;
        tl.rails.push_back({16.0f, 28.0f, 0.4f, 0.15f, 0, 1});
        tl.hop(1.9f, 2.7f);
        tl.manuals.push_back({4.6f, 6.5f});
        Scenario s = from_timeline("grind_manual_high", 7.0f, tl);
        s.settings.angle = CameraAngle::High;
        add(s, "High angle: a rail then a manual (the close-up exits)");
    }
    return list;
}

} // namespace

int main(int argc, char** argv) {
    fs::path dir = argc > 1 ? fs::path(argv[1]) : fs::path("out");
    fs::create_directories(dir);
    std::vector<Scenario> list = catalogue();
    std::string index = "-- generated by trace_gen.exe\nreturn {\n";
    int frames = 0, rays = 0, hits = 0;
    for (const Scenario& sc : list) {
        if (!sc.settings.valid()) {
            std::printf("scenario %s: invalid settings\n", sc.name.c_str());
            return 1;
        }
        const Totals t = run(sc, dir);
        frames += t.frames;
        rays += t.rays;
        hits += t.hits;
        std::printf("%-26s %5d frames %6d rays (%d hits)  %s\n", sc.name.c_str(), t.frames, t.rays, t.hits, sc.note.c_str());
        index += "  \"trace_" + sc.name + "\",\n";
    }
    index += "}\n";
    std::FILE* f = std::fopen((dir / "trace_index.lua").string().c_str(), "wb");
    std::fwrite(index.data(), 1, index.size(), f);
    std::fclose(f);
    std::printf("%zu scenarios, %d frames, %d rays (%d hits) -> %s\n", list.size(), frames, rays, hits, dir.string().c_str());
    return 0;
}
