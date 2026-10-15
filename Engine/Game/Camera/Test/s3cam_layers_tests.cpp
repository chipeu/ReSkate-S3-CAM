#include "Engine/Game/Camera/s3_camera.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// The Alpha 2 layers of CameraMan (docs/s3cam/PHASE2.md): FOV model, pitch prediction (landing look,
// slope look, vertical follow), shoulder offset, follow strength, speed shake and collision. Each test
// drives the camera with a scripted skater and a small analytic world (a step-down platform and an
// optional wall), at 60 fps unless a test says otherwise.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool close_to(float a, float b, float tolerance) { return std::abs(a - b) <= tolerance; }
bool all_finite_frame(const Frame& f) {
    for (const Vec3* v : {&f.right, &f.up, &f.back, &f.pos})
        for (const float c : *v)
            if (!std::isfinite(c)) return false;
    return std::isfinite(f.fov_deg);
}
bool is_orthonormal(const Frame& f) {
    return close_to(length(f.right), 1.0f, 1e-4f) && close_to(length(f.up), 1.0f, 1e-4f) && close_to(length(f.back), 1.0f, 1e-4f) &&
           close_to(dot(f.right, f.up), 0.0f, 1e-4f) && close_to(dot(f.right, f.back), 0.0f, 1e-4f) &&
           length(sub(cross(f.right, f.up), f.back)) <= 1e-4f;
}
// Degrees the view looks up (+) or down (-).
float view_pitch_deg(const Frame& f) { return std::asin(std::clamp(-f.back[1], -1.0f, 1.0f)) / degrees; }
// Sideways position of `point` as the camera sees it: negative = left of the view axis.
float lateral_of(const Frame& f, const Vec3& point) { return dot(sub(point, f.pos), f.right); }

constexpr float gravity_ms2 = 10.1f;
constexpr float root_height = 0.95f; // root above the ground riding
constexpr float one_frame = 1.0f / 60.0f;

// ---------------------------------------------------------------- analytic world

// The ground is a two-level height field (upper level until z = drop_z, then drop_to) plus an optional
// wall plane at z = wall_z. The query is a generic segment test: the first contact along the segment.
// It counts its calls so a test can check the ray budget.
struct World {
    float upper_y = 0.0f;
    float drop_z = 1.0e9f, drop_to = -2.5f;
    bool has_wall = false;
    float wall_z = 0.0f;
    mutable int calls = 0;

    float surface(float z) const noexcept { return z < drop_z ? upper_y : drop_to; }

    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        ++calls;
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

// ---------------------------------------------------------------- scripted skaters

// A rider on a straight line along +Z. `at(t)` is a pure function of time so every frame rate samples
// the same skater.
struct Rider {
    float speed = 6.0f;
    float slope_degrees = 0.0f;   // + uphill, - downhill (the ground tilts along the direction of travel)
    // Optional step-down: the rider leaves the upper level at edge_z and lands drop_height lower.
    bool has_drop = false;
    float edge_z = 10.0f, drop_height = 2.5f;
    // Optional ollie on the flat.
    bool has_ollie = false;
    float ollie_time = 1.0f, ollie_speed = 3.5f;
    float jump_speed = 0.0f;      // vertical speed of a big jump when has_ollie (overrides ollie_speed if > 0)
    bool switch_stance = false;
    float stop_after = -1.0f;     // t >= this: the rider is standing still (speed 0)

    float edge_time() const { return edge_z / std::max(speed, 1e-3f); }
    float fall_time() const { return std::sqrt(2.0f * drop_height / gravity_ms2); }
    float air_time_ollie() const { return 2.0f * (jump_speed > 0.0f ? jump_speed : ollie_speed) / gravity_ms2; }

    SubjectSnapshot at(float t) const {
        SubjectSnapshot s;
        s.valid = true;
        s.time = t;
        s.switch_stance = switch_stance;
        const float run_speed = (stop_after >= 0.0f && t >= stop_after) ? 0.0f : speed;
        const float travelled = stop_after >= 0.0f ? speed * std::min(t, stop_after) : speed * t;
        const float angle = slope_degrees * degrees;
        // Direction of travel along the slope, and the matching surface normal.
        const Vec3 along{0.0f, std::sin(angle), std::cos(angle)};
        s.forward = along;
        s.ground_normal = {0.0f, std::cos(angle), -std::sin(angle)};
        s.velocity = scale(along, run_speed);
        s.position = {0.0f, root_height + travelled * std::sin(angle), travelled * std::cos(angle)};
        s.ground_clearance = root_height;
        s.physics_state = physics_state::ride;
        if (has_drop) {
            const float tau_flight = t - edge_time();
            if (tau_flight >= 0.0f && tau_flight < fall_time()) {
                s.position = {0.0f, root_height - 0.5f * gravity_ms2 * tau_flight * tau_flight, speed * t};
                s.velocity = {0.0f, -gravity_ms2 * tau_flight, speed};
                s.physics_state = physics_state::air;
                s.ground_clearance = s.position[1] - (-drop_height);
            } else if (tau_flight >= fall_time()) {
                s.position = {0.0f, root_height - drop_height, speed * t};
                s.ground_clearance = root_height;
            }
        }
        if (has_ollie) {
            const float vy0 = jump_speed > 0.0f ? jump_speed : ollie_speed;
            const float since = t - ollie_time;
            if (since >= 0.0f && since < air_time_ollie()) {
                s.position[1] = root_height + vy0 * since - 0.5f * gravity_ms2 * since * since;
                s.velocity[1] = vy0 - gravity_ms2 * since;
                s.physics_state = since < 0.08f ? physics_state::pop : physics_state::air;
                s.ground_clearance = s.position[1];
            }
        }
        return s;
    }
};

struct Run {
    std::vector<Frame> frames;
    float fps = 60.0f;
};

template <class Query>
Run drive(CameraMan& cam, const Rider& rider, Query& world, float seconds, float fps = 60.0f, const FrameExtras& extras = {}) {
    Run run;
    run.fps = fps;
    const int count = static_cast<int>(std::lround(seconds * fps));
    for (int i = 0; i < count; ++i) {
        const float t = static_cast<float>(i) / fps;
        run.frames.push_back(cam.update(1.0f / fps, rider.at(t), world, extras));
    }
    return run;
}

CameraMan make_camera(const CameraSettings& settings) {
    CameraMan cam;
    expect(cam.set_settings(settings), "settings accepted");
    return cam;
}

// ---------------------------------------------------------------- 1. FOV

void test_fov_speed_term() {
    Rider rider;
    rider.speed = 12.0f; // speed term: 6 deg * (12 - 5) / (15 - 5) = 4.2 deg
    World world;
    world.upper_y = -1000.0f;
    FrameExtras extras;
    extras.base_fov_deg = 60.0f;
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraMan cam;
        const Run run = drive(cam, rider, world, 4.0f, fps, extras);
        float worst_jump = 0.0f;
        bool monotone = true;
        for (std::size_t i = 1; i < run.frames.size(); ++i) {
            const float change = run.frames[i].fov_deg - run.frames[i - 1].fov_deg;
            worst_jump = std::max(worst_jump, std::abs(change));
            monotone = monotone && change >= -1e-4f;
        }
        const std::string tag = "fov speed @" + std::to_string(static_cast<int>(fps)) + " fps: ";
        expect(close_to(run.frames.front().fov_deg, 60.0f, 0.01f), tag + "the first frame is the supplied base (the extras ease in from the cut)");
        expect(close_to(run.frames.back().fov_deg, 64.2f, 0.05f), tag + "settles at base + the speed term (60 + 4.2)");
        // The filter closes 1 - exp(-1/60 / 0.35) = 4.6% of 4.2 deg per step: 0.2 deg a step, two steps a 30 fps frame.
        expect(worst_jump <= (fps < 59.0f ? 0.42f : 0.21f), tag + "no frame moves the fov by more than 0.21 deg per fixed step");
        expect(monotone, tag + "the fov rises monotonically toward the target");
        const FrameDebug& d = run.frames.back().debug;
        expect(close_to(d.fov_base, 60.0f, 1e-4f) && close_to(d.fov_extra, 4.2f, 0.05f), tag + "debug reports base and extra");
    }
    // Time constant: after one smoothing_time the extra has covered 63% of the way.
    CameraMan cam;
    const Run run = drive(cam, rider, world, 1.0f, 60.0f, extras);
    const float at_tc = run.frames[static_cast<std::size_t>(std::lround(0.35f * 60.0f))].debug.fov_extra;
    expect(close_to(at_tc, 4.2f * (1.0f - std::exp(-1.0f)), 0.15f), "fov: one smoothing_time covers 1 - 1/e of the way");

    // smoothing_time 0 = immediate; every term can be switched off; the override is a base too.
    CameraSettings instant;
    instant.fov.smoothing_time = 0.0f;
    CameraMan c2 = make_camera(instant);
    const Run r2 = drive(c2, rider, world, 0.5f, 60.0f, extras);
    expect(close_to(r2.frames[10].fov_deg, 64.2f, 0.01f), "fov: smoothing_time 0 applies the extras at once");
    CameraSettings none;
    none.fov.speed_fov = none.fov.air_fov = none.fov.shot_fov = false;
    CameraMan c3 = make_camera(none);
    const Run r3 = drive(c3, rider, world, 2.0f, 60.0f, extras);
    expect(close_to(r3.frames.back().fov_deg, 60.0f, 1e-4f) && r3.frames.back().debug.fov_extra == 0.0f, "fov: all terms off leaves the base alone");
    CameraSettings over;
    over.fov_override_deg = 75.0f;
    CameraMan c4 = make_camera(over);
    const Run r4 = drive(c4, rider, world, 4.0f, 60.0f, extras);
    expect(close_to(r4.frames.back().fov_deg, 79.2f, 0.05f) && close_to(r4.frames.back().debug.fov_base, 75.0f, 1e-4f),
           "fov: fov_override_deg is the base (it wins over base_fov_deg) and the extras ride on it");
    // No base supplied: the chase lens, as before. The stock shots share one lens, so the shot term is 0.
    CameraSettings lens_only;
    lens_only.fov.speed_fov = lens_only.fov.air_fov = false;
    CameraMan c5 = make_camera(lens_only);
    Rider ollie;
    ollie.has_ollie = true;
    World flat;
    const Run r5 = drive(c5, ollie, flat, 3.0f);
    float worst_extra = 0.0f;
    for (const Frame& f : r5.frames) worst_extra = std::max(worst_extra, std::abs(f.debug.fov_extra));
    expect(worst_extra < 1e-3f, "fov: stock shots share a lens, so the shot term is 0 through every shot change");
    expect(close_to(r5.frames.back().fov_deg, lens_field_of_view_degrees(12.0f, 16.0f / 9.0f), 1e-3f), "fov: with no base the chase lens fov is the base");
}

void test_fov_air_term() {
    Rider rider;
    rider.has_ollie = true;
    rider.ollie_time = 1.0f;
    rider.jump_speed = 8.0f; // apex 8^2 / (2 * 10.1) = 3.2 m: the air term is full (8 deg)
    World world;
    CameraSettings cs;
    cs.fov.speed_fov = false; // isolate the air term
    CameraMan cam = make_camera(cs);
    FrameExtras extras;
    extras.base_fov_deg = 60.0f;
    const Run run = drive(cam, rider, world, 7.0f, 60.0f, extras);
    const float land = rider.ollie_time + rider.air_time_ollie();
    float before = 0.0f, peak = 0.0f, worst_jump = 0.0f;
    for (std::size_t i = 0; i < run.frames.size(); ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const float extra = run.frames[i].debug.fov_extra;
        if (t < rider.ollie_time) before = std::max(before, std::abs(extra));
        peak = std::max(peak, extra);
        if (i > 0) worst_jump = std::max(worst_jump, std::abs(run.frames[i].fov_deg - run.frames[i - 1].fov_deg));
    }
    const float after_landing = run.frames[static_cast<std::size_t>((land + 3.0f) * 60.0f)].debug.fov_extra;
    expect(before < 1e-4f, "air fov: no extra on the ground before the jump");
    if (peak < 4.0f) std::printf("  air fov peak %.2f deg\n", static_cast<double>(peak));
    expect(peak > 4.0f && peak <= 8.01f, "air fov: rises toward air_fov_degrees (8) in a big air");
    expect(after_landing < 0.05f, "air fov: decays back to 0 after landing (through the ease)");
    expect(worst_jump <= 0.45f, "air fov: never jumps more than 0.45 deg a frame");
    // A small ollie (0.6 m apex) only gets 8 * 0.6 / 2.5 = about 1.9 deg.
    Rider small;
    small.has_ollie = true;
    CameraMan c2 = make_camera(cs);
    const Run r2 = drive(c2, small, world, 3.0f, 60.0f, extras);
    float small_peak = 0.0f;
    for (const Frame& f : r2.frames) small_peak = std::max(small_peak, f.debug.fov_extra);
    expect(small_peak > 0.2f && small_peak < 2.0f, "air fov: scales with the predicted height (a small ollie widens a little)");
}

void test_fov_native_plus() {
    CameraSettings cs;
    cs.preset = CameraPreset::NativePlus;
    cs.native_plus.air_hold = false;
    cs.native_plus.shake = false;
    cs.fov.air_fov = false;
    Rider rider;
    rider.speed = 12.0f;
    World world;
    const auto run_with = [&](float game_fov, float native_fov) {
        CameraMan cam = make_camera(cs);
        FrameExtras extras;
        extras.base_fov_deg = game_fov;
        float last = 0.0f;
        for (int i = 0; i < 240; ++i) {
            const SubjectSnapshot s = rider.at(static_cast<float>(i) / 60.0f);
            NativePose pose;
            pose.right = {-1, 0, 0};
            pose.back = {0, 0, -1};
            pose.position = {0.0f, 1.4f, s.position[2] - 2.0f};
            pose.fov_deg = native_fov;
            extras.native = &pose;
            last = cam.update(one_frame, s, world, extras).fov_deg;
        }
        return last;
    };
    expect(close_to(run_with(70.0f, 60.0f), 74.2f, 0.05f), "native+: base_fov_deg (70) wins over the pose fov and the speed term rides on it");
    expect(close_to(run_with(0.0f, 60.0f), 64.2f, 0.05f), "native+: without base_fov_deg the pose fov (60) is the base, plus the speed term");
}

// ---------------------------------------------------------------- 2. pitch prediction

void test_landing_look() {
    Rider rider;
    rider.has_drop = true; // 2.5 m step down at z = 10 (t = 1.667 s), 0.70 s of fall
    World world;
    world.drop_z = rider.edge_z;
    world.drop_to = -rider.drop_height;
    CameraSettings on, off;
    off.look.landing_look = false;
    CameraMan cam_on = make_camera(on), cam_off = make_camera(off);
    const Run with_look = drive(cam_on, rider, world, 5.0f);
    const Run without = drive(cam_off, rider, world, 5.0f);
    const float edge = rider.edge_time();
    float lowest_difference = 0.0f, peak_weight = 0.0f, worst_pitch_step = 0.0f, worst_off_weight = 0.0f;
    for (std::size_t i = 0; i < with_look.frames.size(); ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        peak_weight = std::max(peak_weight, with_look.frames[i].debug.landing_look_weight);
        worst_off_weight = std::max(worst_off_weight, without.frames[i].debug.landing_look_weight);
        if (t > edge + 0.2f && t < edge + rider.fall_time()) lowest_difference = std::min(lowest_difference, view_pitch_deg(with_look.frames[i]) - view_pitch_deg(without.frames[i]));
        if (i > 0) worst_pitch_step = std::max(worst_pitch_step, std::abs(view_pitch_deg(with_look.frames[i]) - view_pitch_deg(with_look.frames[i - 1])));
    }
    if (lowest_difference > -4.0f) std::printf("  landing look pitch difference %.2f deg, peak weight %.2f\n", static_cast<double>(lowest_difference), static_cast<double>(peak_weight));
    expect(lowest_difference < -4.0f, "landing look: jumping to a lower platform pitches the view down compared with landing_look off");
    expect(peak_weight > 0.3f && peak_weight <= 0.6f + 1e-3f, "landing look: the weight reaches about strength (0.6) for a full drop");
    expect(worst_off_weight == 0.0f, "landing look: off means weight 0");
    expect(worst_pitch_step < 3.0f, "landing look: the pitch eases in (no jump of more than 3 deg in a frame)");
    // After landing the weight eases out again.
    expect(with_look.frames.back().debug.landing_look_weight < 0.01f, "landing look: the weight is gone a few seconds after landing");
    // Shorter drops give a smaller weight (linear from 0 to full_drop).
    Rider shallow = rider;
    shallow.drop_height = 1.25f;
    World shallow_world;
    shallow_world.drop_z = shallow.edge_z;
    shallow_world.drop_to = -shallow.drop_height;
    CameraMan c2 = make_camera(on);
    const Run r2 = drive(c2, shallow, shallow_world, 4.0f);
    float shallow_peak = 0.0f;
    for (const Frame& f : r2.frames) shallow_peak = std::max(shallow_peak, f.debug.landing_look_weight);
    expect(shallow_peak > 0.1f && shallow_peak < peak_weight * 0.75f, "landing look: half the drop gives about half the weight");

    // A same-level landing does nothing.
    Rider ollie;
    ollie.has_ollie = true;
    World flat;
    CameraMan c3 = make_camera(on), c4 = make_camera(off);
    const Run flat_on = drive(c3, ollie, flat, 4.0f);
    const Run flat_off = drive(c4, ollie, flat, 4.0f);
    float flat_weight = 0.0f, flat_difference = 0.0f;
    for (std::size_t i = 0; i < flat_on.frames.size(); ++i) {
        flat_weight = std::max(flat_weight, flat_on.frames[i].debug.landing_look_weight);
        flat_difference = std::max(flat_difference, std::abs(view_pitch_deg(flat_on.frames[i]) - view_pitch_deg(flat_off.frames[i])));
    }
    expect(flat_weight < 0.02f, "landing look: a same-level ollie leaves the weight at about 0");
    expect(flat_difference < 0.3f, "landing look: a same-level ollie does not change the view pitch");
}

void test_slope_look() {
    World world;
    world.upper_y = -1.0e6f;
    CameraSettings on, off;
    off.look.slope_look = false;
    for (const float slope : {-15.0f, 15.0f}) {
        Rider rider;
        rider.slope_degrees = slope;
        CameraMan cam_on = make_camera(on), cam_off = make_camera(off);
        const Run with_look = drive(cam_on, rider, world, 4.0f);
        const Run without = drive(cam_off, rider, world, 4.0f);
        const float difference = view_pitch_deg(with_look.frames.back()) - view_pitch_deg(without.frames.back());
        const float offset_deg = with_look.frames.back().debug.look_pitch_offset / degrees;
        const std::string tag = slope < 0.0f ? "slope look downhill: " : "slope look uphill: ";
        // strength 0.5 of the 15 degree incline = 7.5 degrees; the tilt tracker adds a little lag only.
        expect(close_to(offset_deg, slope * 0.5f, 0.2f), tag + "the eased pitch offset is strength * incline");
        expect(close_to(difference, slope * 0.5f, 1.2f), tag + "the view pitch moves by about 7.5 degrees (down when riding downhill)");
        expect(without.frames.back().debug.look_pitch_offset == 0.0f, tag + "off means no offset");
        // It eases in: the first frames are not a step.
        float worst_step = 0.0f;
        for (std::size_t i = 1; i < with_look.frames.size(); ++i)
            worst_step = std::max(worst_step, std::abs(with_look.frames[i].debug.look_pitch_offset - with_look.frames[i - 1].debug.look_pitch_offset) / degrees);
        expect(worst_step < 0.7f, tag + "the offset changes by less than 0.7 deg a frame");
    }
    // In the air the slope look eases out.
    Rider hill;
    hill.slope_degrees = -15.0f;
    hill.has_ollie = true;
    hill.ollie_time = 3.0f;
    hill.jump_speed = 4.0f;
    CameraMan cam = make_camera(on);
    const Run run = drive(cam, hill, world, 5.0f);
    const float before_jump = run.frames[170].debug.look_pitch_offset;
    float lowest_in_air = -1.0f;
    for (std::size_t i = 0; i < run.frames.size(); ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        if (t > hill.ollie_time + 0.6f && t < hill.ollie_time + hill.air_time_ollie() - 0.05f) lowest_in_air = std::max(lowest_in_air, std::abs(run.frames[i].debug.look_pitch_offset) / degrees);
    }
    expect(before_jump < -0.1f, "slope look: riding downhill before the jump has an offset");
    expect(lowest_in_air >= 0.0f && lowest_in_air < 7.5f, "slope look: in the air the offset eases out toward 0");
}

void test_vertical_follow() {
    // A standing Low camera: anchor y 0.37, camera y 0.5894, 1.7866 m back. Looking at the anchor
    // height (vertical_follow 0) is -7.0 degrees to the line, plus the -4 degree framing = -11.0.
    Rider rider;
    rider.speed = 0.0f;
    World world;
    float pitch_by_follow[2] = {};
    int slot = 0;
    for (const float follow : {1.0f, 0.0f}) {
        CameraSettings cs;
        cs.look.vertical_follow = follow;
        CameraMan cam = make_camera(cs);
        const Run run = drive(cam, rider, world, 3.0f);
        pitch_by_follow[slot++] = view_pitch_deg(run.frames.back());
    }
    expect(close_to(pitch_by_follow[0], 7.41f, 0.2f), "vertical follow 1: the standing pitch is the Gate 1 value (+7.4 deg)");
    expect(close_to(pitch_by_follow[1], -11.0f, 0.3f), "vertical follow 0: the pitch is level with the anchor height (-7 deg line - 4 deg framing)");
    // In a big jump the pitch with follow 0 stays down on the held anchor while the skater rises.
    Rider jump;
    jump.has_ollie = true;
    jump.jump_speed = 6.0f;
    float apex_pitch[2] = {};
    slot = 0;
    for (const float follow : {1.0f, 0.0f}) {
        CameraSettings cs;
        cs.look.vertical_follow = follow;
        CameraMan cam = make_camera(cs);
        const Run run = drive(cam, jump, world, 3.0f);
        apex_pitch[slot++] = view_pitch_deg(run.frames[static_cast<std::size_t>((jump.ollie_time + jump.air_time_ollie() * 0.5f) * 60.0f)]);
    }
    expect(apex_pitch[1] < apex_pitch[0] - 5.0f, "vertical follow 0: at the apex the view stays lower than the one that follows the skater");
}

// ---------------------------------------------------------------- 3. shoulder

void test_shoulder() {
    Rider rider;
    rider.speed = 0.0f;
    World world;
    const Vec3 skater = rider.at(0.0f).position;

    // Manual side +1: the camera sits to the skater's right, so the skater is left of the view axis.
    CameraSettings cs;
    cs.shoulder.mode = ShoulderSide::Manual;
    cs.shoulder.side = 1;
    CameraMan cam = make_camera(cs);
    Run run = drive(cam, rider, world, 1.0f);
    expect(close_to(lateral_of(run.frames.back(), skater), -0.45f, 0.02f), "shoulder +1: the skater sits 0.45 m left of the view axis");
    expect(close_to(run.frames.back().debug.shoulder, 0.45f, 1e-4f), "shoulder +1: debug.shoulder is +0.45");
    expect(is_orthonormal(run.frames.back()), "shoulder: the frame stays orthonormal");
    // The view direction is unchanged: the camera slid sideways, it did not turn.
    CameraSettings centred;
    CameraMan c0 = make_camera(centred);
    const Run base = drive(c0, rider, world, 1.0f);
    expect(close_to(dot(run.frames.back().back, base.frames.back().back), 1.0f, 1e-3f), "shoulder: the camera slides, the view direction stays");
    expect(close_to(lateral_of(base.frames.back(), skater), 0.0f, 0.01f), "shoulder off: the skater is centred");

    // The slide across: smooth, bounded per frame, ends on the other side.
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraMan c1 = make_camera(cs);
        std::vector<float> lateral;
        const int total = static_cast<int>(2.0f * fps);
        for (int i = 0; i < total; ++i) {
            if (i == static_cast<int>(fps)) {
                CameraSettings flipped = cs;
                flipped.shoulder.side = -1;
                expect(c1.set_settings(flipped), "shoulder: live side change accepted");
            }
            const Frame& f = c1.update(1.0f / fps, rider.at(static_cast<float>(i) / fps), world);
            lateral.push_back(lateral_of(f, skater));
        }
        float worst_step = 0.0f;
        for (std::size_t i = 1; i < lateral.size(); ++i) worst_step = std::max(worst_step, std::abs(lateral[i] - lateral[i - 1]));
        const std::size_t start = static_cast<std::size_t>(fps);
        const float first_move = std::abs(lateral[start + 1] - lateral[start - 1]);
        const std::string tag = "shoulder switch @" + std::to_string(static_cast<int>(fps)) + " fps: ";
        // 0.9 m over 0.45 s with a sine ease peaks at pi/2 * 2 m/s = 3.14 m/s.
        expect(worst_step <= 3.2f / fps + 0.003f, tag + "the lateral step per frame is bounded by the sine ease's peak speed");
        expect(first_move < 0.03f, tag + "no velocity jump at the start of the slide");
        expect(close_to(lateral.back(), 0.45f, 0.02f), tag + "ends 0.45 m right of the view axis (camera on the left)");
        expect(close_to(lateral[start + static_cast<std::size_t>(0.225f * fps)], 0.0f, 0.1f), tag + "halfway through the slide the skater is centred");
    }

    // switch_time 0 is immediate.
    CameraSettings instant = cs;
    instant.shoulder.switch_time = 0.0f;
    CameraMan c2 = make_camera(instant);
    drive(c2, rider, world, 0.5f);
    CameraSettings flipped = instant;
    flipped.shoulder.side = -1;
    c2.set_settings(flipped);
    c2.update(one_frame, rider.at(0.5f), world); // the published pose lerps between the last two steps
    const Frame& after = c2.update(one_frame, rider.at(0.5f), world);
    expect(close_to(lateral_of(after, skater), 0.45f, 0.03f), "shoulder: switch_time 0 jumps to the other side at once");

    // Auto: regular stance puts the camera on the right, goofy or switch on the left, both = right again.
    const auto auto_side = [&](bool goofy, bool switch_stance) {
        CameraSettings a;
        a.shoulder.mode = ShoulderSide::Auto;
        a.shoulder.goofy = goofy;
        Rider r = rider;
        r.switch_stance = switch_stance;
        CameraMan c = make_camera(a);
        const Run rr = drive(c, r, world, 1.5f);
        return lateral_of(rr.frames.back(), skater);
    };
    expect(close_to(auto_side(false, false), -0.45f, 0.03f), "auto: regular, riding regular: camera on the right");
    expect(close_to(auto_side(false, true), 0.45f, 0.03f), "auto: regular, riding switch: camera on the left");
    expect(close_to(auto_side(true, false), 0.45f, 0.03f), "auto: goofy, riding goofy: camera on the left");
    expect(close_to(auto_side(true, true), -0.45f, 0.03f), "auto: goofy, riding switch: camera on the right");
    // The side flips smoothly when the stance changes mid-ride.
    CameraSettings a;
    a.shoulder.mode = ShoulderSide::Auto;
    CameraMan c3 = make_camera(a);
    float worst = 0.0f, previous = 0.0f;
    for (int i = 0; i < 180; ++i) {
        Rider r = rider;
        r.switch_stance = i >= 60;
        const Frame& f = c3.update(one_frame, r.at(0.0f), world);
        const float lat = lateral_of(f, skater);
        if (i > 0) worst = std::max(worst, std::abs(lat - previous));
        previous = lat;
    }
    expect(worst < 0.06f && close_to(previous, 0.45f, 0.03f), "auto: a switch_stance change slides the camera across smoothly");

    // NativePlus: the shift follows the native right.
    CameraSettings np;
    np.preset = CameraPreset::NativePlus;
    np.shoulder.mode = ShoulderSide::Manual;
    np.shoulder.side = 1;
    np.shake_enabled = false;
    np.native_plus.air_hold = false;
    CameraMan cn = make_camera(np);
    NativePose pose;
    pose.right = {-1, 0, 0};
    pose.back = {0, 0, -1};
    pose.position = {0.0f, 1.4f, -2.0f};
    FrameExtras extras;
    extras.native = &pose;
    const Frame* last = nullptr;
    for (int i = 0; i < 90; ++i) last = &cn.update(one_frame, rider.at(0.0f), world, extras);
    expect(close_to(dot(sub(last->pos, pose.position), pose.right), 0.45f, 0.01f), "native+: the camera moves 0.45 m along the native right");
    expect(close_to(last->debug.shoulder, 0.45f, 1e-4f), "native+: debug.shoulder reports it");
}

// ---------------------------------------------------------------- 4. follow strength

void test_follow_strength() {
    // A standing start with a push: the anchor lags behind the skater (below 4 m/s). Dynamic boost off,
    // so strength is the only difference.
    const auto lag_for = [](float strength, float& mean_distance_error) {
        CameraSettings cs;
        cs.follow.strength = strength;
        cs.follow.dynamic = false;
        CameraMan cam = make_camera(cs);
        World world;
        world.upper_y = -1000.0f;
        float speed = 0.0f, z = 0.0f, peak = 0.0f, error_sum = 0.0f;
        int counted = 0;
        for (int i = 0; i < 240; ++i) {
            const float t = static_cast<float>(i) / 60.0f;
            speed += ((t > 0.5f && t < 1.0f) ? 8.0f : 0.0f) / 60.0f;
            z += speed / 60.0f;
            SubjectSnapshot s;
            s.valid = true;
            s.position = {0.0f, root_height, z};
            s.velocity = {0.0f, 0.0f, speed};
            const Frame& f = cam.update(one_frame, s, world);
            peak = std::max(peak, f.debug.anchor_lag);
            if (t > 0.6f) {
                error_sum += std::abs(length(sub(f.pos, s.position)) - 2.0f);
                ++counted;
            }
            expect(all_finite_frame(f) && is_orthonormal(f), "follow: finite, orthonormal");
        }
        mean_distance_error = error_sum / static_cast<float>(std::max(counted, 1));
        return peak;
    };
    float e1 = 0.0f, e2 = 0.0f, e_half = 0.0f;
    const float lag1 = lag_for(1.0f, e1), lag2 = lag_for(2.0f, e2), lag_half = lag_for(0.5f, e_half);
    std::printf("  anchor lag: strength 0.5 -> %.3f m, 1 -> %.3f m, 2 -> %.3f m\n", static_cast<double>(lag_half), static_cast<double>(lag1), static_cast<double>(lag2));
    expect(lag1 > 0.02f, "follow: a push produces a measurable anchor lag at strength 1");
    expect(lag2 < lag1 * 0.7f, "follow: strength 2 gives less anchor lag than strength 1");
    expect(close_to(lag2, lag1 * 0.5f, lag1 * 0.15f), "follow: the lag is about 1 / k");
    expect(lag_half > lag1 * 1.4f, "follow: strength 0.5 follows looser (more lag)");

    // The dynamic boost and the clamp, read from the debug field.
    CameraSettings dyn;
    dyn.follow.strength = 1.0f;
    dyn.follow.dynamic = true;
    dyn.follow.dynamic_speed = 12.0f;
    dyn.follow.dynamic_boost = 0.5f;
    World world;
    world.upper_y = -1000.0f;
    const auto k_at = [&](const CameraSettings& settings, float speed) {
        CameraMan cam = make_camera(settings);
        Rider r;
        r.speed = speed;
        const Run run = drive(cam, r, world, 0.5f);
        return run.frames.back().debug.follow_strength;
    };
    expect(close_to(k_at(dyn, 0.0f), 1.0f, 1e-4f), "follow: k is the strength at a standstill");
    expect(close_to(k_at(dyn, 12.0f), 1.5f, 1e-3f), "follow: k = strength + dynamic_boost at dynamic_speed");
    expect(close_to(k_at(dyn, 6.0f), 1.25f, 1e-3f), "follow: the boost rises linearly with speed");
    expect(close_to(k_at(dyn, 40.0f), 1.5f, 1e-3f), "follow: the boost stops at dynamic_speed");
    CameraSettings big = dyn;
    big.follow.strength = 4.0f;
    big.follow.dynamic_boost = 3.0f;
    expect(close_to(k_at(big, 40.0f), 7.0f, 1e-4f), "follow: k is clamped to 7");
    CameraSettings loose = dyn;
    loose.follow.strength = 0.2f;
    loose.follow.dynamic = false;
    expect(close_to(k_at(loose, 6.0f), 0.2f, 1e-4f), "follow: k = 0.2 is allowed (the lower clamp)");
}

// ---------------------------------------------------------------- 5. speed shake

// A native camera that follows the skater 2.06 m away (inside the shake's full-strength distance), so
// everything the camera does beyond the native pose is the shake.
NativePose follower_pose(const SubjectSnapshot& s) {
    NativePose pose;
    pose.right = {-1, 0, 0};
    pose.up = {0, 1, 0};
    pose.back = {0, 0, -1};
    pose.position = {s.position[0], s.position[1] + 0.5f, s.position[2] - 2.0f};
    pose.fov_deg = 60.0f;
    return pose;
}

struct ShakeMeasure {
    float max_angle_deg = 0.0f, max_offset = 0.0f, max_impulse = 0.0f;
};
ShakeMeasure measure_shake(const CameraSettings& settings, const Rider& rider, float seconds, float from_time) {
    CameraSettings np = settings;
    np.preset = CameraPreset::NativePlus;
    np.native_plus.air_hold = false;
    np.native_plus.landing_dip = false;
    CameraMan cam = make_camera(np);
    World world;
    world.upper_y = -1000.0f;
    ShakeMeasure m;
    const int count = static_cast<int>(seconds * 60.0f);
    for (int i = 0; i < count; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const SubjectSnapshot s = rider.at(t);
        const NativePose pose = follower_pose(s);
        FrameExtras extras;
        extras.native = &pose;
        const Frame& f = cam.update(one_frame, s, world, extras);
        if (t < from_time) continue;
        m.max_angle_deg = std::max(m.max_angle_deg, std::acos(std::clamp(dot(f.back, pose.back), -1.0f, 1.0f)) / degrees);
        m.max_offset = std::max(m.max_offset, length(sub(f.pos, pose.position)));
        m.max_impulse = std::max(m.max_impulse, f.debug.impulse);
    }
    return m;
}

void test_speed_shake() {
    Rider fast;
    fast.speed = 15.0f;
    const CameraSettings defaults;
    const ShakeMeasure rumble = measure_shake(defaults, fast, 3.0f, 1.0f);
    expect(rumble.max_angle_deg > 0.003f && rumble.max_offset > 1e-4f, "speed shake: riding at top speed rumbles the camera");

    CameraSettings off;
    off.speed_shake.enabled = false;
    const ShakeMeasure quiet = measure_shake(off, fast, 3.0f, 1.0f);
    expect(quiet.max_angle_deg < 1e-4f && quiet.max_offset < 1e-6f, "speed shake off: no rumble at speed");

    CameraSettings double_strength;
    double_strength.speed_shake.strength = 2.0f;
    const ShakeMeasure strong = measure_shake(double_strength, fast, 3.0f, 1.0f);
    expect(close_to(strong.max_angle_deg / rumble.max_angle_deg, 2.0f, 0.1f), "speed shake: strength 2 doubles the rumble");

    // top_speed: half of it is reached at a lower speed. At 7.5 m/s with top_speed 7.5 the amplitude
    // equals the one at 15 m/s with top_speed 15 (the frequency curve moves the same way).
    CameraSettings low_top;
    low_top.speed_shake.top_speed = 7.5f;
    Rider medium;
    medium.speed = 7.5f;
    const ShakeMeasure scaled = measure_shake(low_top, medium, 3.0f, 1.0f);
    expect(close_to(scaled.max_angle_deg, rumble.max_angle_deg, rumble.max_angle_deg * 0.15f), "speed shake: top_speed sets where the full rumble is reached");

    // Downhill: 20 degrees (full) at the same horizontal speed rumbles 1.5x as much.
    Rider downhill = fast;
    downhill.slope_degrees = -20.0f;
    downhill.speed = 15.0f / std::cos(20.0f * degrees); // same horizontal speed as the flat ride
    const ShakeMeasure steep = measure_shake(defaults, downhill, 3.0f, 1.0f);
    expect(close_to(steep.max_angle_deg / rumble.max_angle_deg, 1.5f, 0.1f), "speed shake: riding 20 degrees downhill rumbles 1.5x");
    CameraSettings no_boost;
    no_boost.speed_shake.downhill_boost = false;
    const ShakeMeasure flat_like = measure_shake(no_boost, downhill, 3.0f, 1.0f);
    expect(close_to(flat_like.max_angle_deg / rumble.max_angle_deg, 1.0f, 0.1f), "speed shake: downhill_boost off removes the extra");
    Rider uphill = downhill;
    uphill.slope_degrees = 20.0f;
    const ShakeMeasure climb = measure_shake(defaults, uphill, 3.0f, 1.0f);
    expect(close_to(climb.max_angle_deg / rumble.max_angle_deg, 1.0f, 0.1f), "speed shake: uphill gets no boost");

    // The landing impulse still works with the rumble off (a 14 m/s landing, as in the camera tests),
    // and shake_enabled = false still switches everything off.
    Rider drop;
    drop.has_ollie = true;
    drop.ollie_time = 0.5f;
    drop.jump_speed = 14.0f;
    drop.speed = 2.0f;
    const ShakeMeasure landing_off = measure_shake(off, drop, 5.0f, 0.0f);
    const ShakeMeasure landing_on = measure_shake(defaults, drop, 5.0f, 0.0f);
    expect(landing_off.max_impulse > 0.5f && landing_off.max_angle_deg > 0.02f, "speed shake off: the landing impulse still shakes the camera");
    expect(landing_on.max_impulse > 0.5f, "speed shake on: the landing impulse is the same");
    CameraSettings muted = defaults;
    muted.shake_enabled = false;
    const ShakeMeasure none = measure_shake(muted, drop, 5.0f, 0.0f);
    expect(none.max_angle_deg < 1e-4f && none.max_offset < 1e-6f, "shake_enabled false disables the rumble and the impulse");
}

// ---------------------------------------------------------------- 6. collision

void test_collision_wall() {
    Rider rider;
    rider.speed = 0.0f;
    World world;
    world.has_wall = true;
    world.wall_z = -0.9f; // between the skater (z = 0) and the camera (about 1.79 m behind)
    const Vec3 pivot{0.0f, 0.95f, 0.0f}; // the Low standing look target

    CameraSettings off;
    off.collision.enabled = false;
    CameraMan c_off = make_camera(off);
    const Run free_run = drive(c_off, rider, world, 2.0f);
    expect(free_run.frames.back().pos[2] < world.wall_z, "collision off: the camera sits behind the wall");
    expect(free_run.frames.back().debug.collision_pull == 0.0f, "collision off: no pull");
    const float free_distance = length(sub(free_run.frames.back().pos, pivot));

    CameraMan cam;
    const Run run = drive(cam, rider, world, 2.0f);
    const Frame& settled = run.frames.back();
    const float expected_z = world.wall_z + 0.25f * std::abs(normalized(sub(settled.pos, pivot))[2]);
    expect(settled.pos[2] > world.wall_z, "collision: the camera is pulled in front of the wall");
    expect(close_to(settled.pos[2], expected_z, 0.03f), "collision: it stops one radius (0.25 m) in front of the wall along the ray");
    expect(settled.debug.collision_pull > 0.5f && close_to(settled.debug.collision_pull, free_distance - length(sub(settled.pos, pivot)), 0.02f),
           "collision: debug.collision_pull is the metres pulled in");
    expect(all_finite_frame(settled) && is_orthonormal(settled), "collision: finite, orthonormal");
    // The skater stays framed: the view still points at the pivot.
    const Vec3 to_pivot = normalized(sub(pivot, settled.pos));
    expect(dot(to_pivot, scale(settled.back, -1.0f)) > std::cos(12.0f * degrees), "collision: the skater stays within 12 degrees of the view axis");
    // A cut with the wall already there lands pulled in (the state snaps).
    CameraMan cut;
    const Frame& first = cut.update(one_frame, rider.at(0.0f), world);
    expect(first.debug.reset && first.pos[2] > world.wall_z, "collision: a cut is already in front of the wall (no ease from outside it)");

    // Pull-in is near instant: the camera is in front of the wall within a few frames of it appearing.
    World clear;
    CameraMan c2;
    const Run before = drive(c2, rider, clear, 1.0f);
    expect(before.frames.back().pos[2] < world.wall_z, "collision: without the wall the camera is behind that place");
    float frames_to_clear = -1.0f;
    for (int i = 0; i < 30; ++i) {
        const Frame& f = c2.update(one_frame, rider.at(1.0f), world);
        if (frames_to_clear < 0.0f && f.pos[2] > world.wall_z - 0.02f) frames_to_clear = static_cast<float>(i + 1);
    }
    if (!(frames_to_clear > 0.0f && frames_to_clear <= 6.0f)) std::printf("  pull-in took %.0f frames\n", static_cast<double>(frames_to_clear));
    expect(frames_to_clear > 0.0f && frames_to_clear <= 6.0f, "collision: pull_in_time 0.05 s puts the camera in front of the wall within 6 frames");

    // Release: with the wall gone the camera eases back out with release_time (0.4 s), never in one jump.
    float start_pull = 0.0f;
    {
        const Frame& pulled = c2.update(one_frame, rider.at(1.0f), world);
        start_pull = pulled.debug.collision_pull;
    }
    const Frame* released = nullptr;
    float worst_step = 0.0f;
    Vec3 previous = c2.frame().pos;
    float pull_after_6 = 0.0f, pull_after_180 = 0.0f;
    for (int i = 0; i < 180; ++i) {
        released = &c2.update(one_frame, rider.at(1.0f), clear);
        worst_step = std::max(worst_step, length(sub(released->pos, previous)));
        previous = released->pos;
        if (i == 5) pull_after_6 = released->debug.collision_pull;
        if (i == 179) pull_after_180 = released->debug.collision_pull;
    }
    // After 0.1 s about 1 - exp(-0.25) = 22% of the pull is gone; after 3 s all of it.
    expect(pull_after_6 > start_pull * 0.6f, "collision: release is slow (most of the pull remains after 0.1 s)");
    expect(pull_after_180 < 0.01f, "collision: and the camera is back out after 3 s");
    expect(worst_step < 0.1f, "collision: release moves the camera by less than 0.1 m a frame");
}

void test_collision_min_distance_and_budget() {
    Rider rider;
    rider.speed = 0.0f;
    World world;
    world.has_wall = true;
    world.wall_z = -0.1f; // almost touching the skater: radius would put the camera at the pivot
    const Vec3 pivot{0.0f, 0.95f, 0.0f};
    CameraMan cam;
    const Run run = drive(cam, rider, world, 2.0f);
    const float distance = length(sub(run.frames.back().pos, pivot));
    expect(distance >= 0.5f - 0.01f, "collision: the camera never gets closer than min_distance (0.5 m) to the pivot");
    expect(distance < 0.55f, "collision: and sits at min_distance when the wall is that close");
    CameraSettings wide;
    wide.collision.min_distance = 1.2f;
    CameraMan c2 = make_camera(wide);
    const Run r2 = drive(c2, rider, world, 2.0f);
    expect(length(sub(r2.frames.back().pos, pivot)) >= 1.2f - 0.01f, "collision: min_distance is a setting");

    // Ray budget: at most two rays per fixed step on the ground.
    World counting;
    counting.upper_y = -1000.0f;
    Rider ride;
    CameraMan c3;
    c3.update(one_frame, ride.at(0.0f), counting);
    counting.calls = 0;
    int steps = 0;
    for (int i = 1; i <= 120; ++i) steps += c3.update(one_frame, ride.at(static_cast<float>(i) / 60.0f), counting).debug.steps;
    expect(steps >= 119 && counting.calls <= 2 * steps, "collision: at most 2 rays per fixed step");
    CameraSettings quiet;
    quiet.collision.enabled = false;
    CameraMan c4 = make_camera(quiet);
    c4.update(one_frame, ride.at(0.0f), counting);
    counting.calls = 0;
    for (int i = 1; i <= 60; ++i) c4.update(one_frame, ride.at(static_cast<float>(i) / 60.0f), counting);
    expect(counting.calls == 0, "collision disabled: no rays on the ground");
}

void test_collision_ground_lift() {
    Rider rider;
    rider.speed = 0.0f;
    World world;
    CameraSettings high_clearance;
    high_clearance.collision.ground_clearance = 0.8f; // the standing Low camera is 0.59 m up
    CameraMan cam = make_camera(high_clearance);
    const Run run = drive(cam, rider, world, 2.0f);
    expect(close_to(run.frames.back().pos[1], 0.8f, 0.01f), "ground lift: the camera is lifted to the ground + ground_clearance");
    CameraSettings off = high_clearance;
    off.collision.enabled = false;
    CameraMan c2 = make_camera(off);
    const Run r2 = drive(c2, rider, world, 2.0f);
    expect(close_to(r2.frames.back().pos[1], 0.589f, 0.01f), "ground lift: collision off leaves the rig's height");

    // The lift eases away with release_time when the ground drops (a ramp edge under the camera).
    Rider mover;
    mover.speed = 3.0f;
    World step_world;
    step_world.drop_z = 3.0f;
    step_world.drop_to = -0.6f; // from z = 3 on the ground is 0.6 m lower: the lift is no longer needed
    CameraMan c3 = make_camera(high_clearance);
    const Run r3 = drive(c3, mover, step_world, 4.0f);
    float worst_step = 0.0f;
    for (std::size_t i = 1; i < r3.frames.size(); ++i) worst_step = std::max(worst_step, std::abs(r3.frames[i].pos[1] - r3.frames[i - 1].pos[1]));
    expect(worst_step < 0.1f, "ground lift: a ground that drops away does not snap the camera down");
    for (const Frame& f : r3.frames) expect(all_finite_frame(f), "ground lift: finite");
}

// ---------------------------------------------------------------- everything at once

void test_layers_together() {
    // All layers on at 30 / 60 / 144 fps over a step-down: continuous, finite, orthonormal, and the
    // settled camera agrees across frame rates.
    Rider rider;
    rider.has_drop = true;
    World world;
    world.drop_z = rider.edge_z;
    world.drop_to = -rider.drop_height;
    CameraSettings cs;
    cs.shoulder.mode = ShoulderSide::Manual;
    cs.look.vertical_follow = 0.5f;
    std::vector<Vec3> settled;
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraMan cam = make_camera(cs);
        FrameExtras extras;
        extras.base_fov_deg = 65.0f;
        const Run run = drive(cam, rider, world, 6.0f, fps, extras);
        float worst_step = 0.0f, worst_fov = 0.0f;
        bool ok = true;
        for (std::size_t i = 0; i < run.frames.size(); ++i) {
            ok = ok && all_finite_frame(run.frames[i]) && is_orthonormal(run.frames[i]);
            if (i > 0) {
                worst_step = std::max(worst_step, length(sub(run.frames[i].pos, run.frames[i - 1].pos)));
                worst_fov = std::max(worst_fov, std::abs(run.frames[i].fov_deg - run.frames[i - 1].fov_deg));
            }
        }
        const std::string tag = "layers @" + std::to_string(static_cast<int>(fps)) + " fps: ";
        expect(ok, tag + "finite and orthonormal");
        expect(worst_step < 0.5f, tag + "no frame moves the camera by 0.5 m");
        expect(worst_fov < 0.45f, tag + "no frame changes the fov by more than 0.45 deg");
        // Relative to where the skater is at that frame's own time (the rider keeps moving at 6 m/s).
        const float last_time = static_cast<float>(run.frames.size() - 1) / fps;
        settled.push_back(sub(run.frames.back().pos, rider.at(last_time).position));
    }
    std::printf("  settled camera offset: 30 fps (%.3f %.3f %.3f) 60 fps (%.3f %.3f %.3f) 144 fps (%.3f %.3f %.3f)\n", static_cast<double>(settled[0][0]), static_cast<double>(settled[0][1]), static_cast<double>(settled[0][2]), static_cast<double>(settled[1][0]), static_cast<double>(settled[1][1]), static_cast<double>(settled[1][2]), static_cast<double>(settled[2][0]), static_cast<double>(settled[2][1]), static_cast<double>(settled[2][2]));
    expect(length(sub(settled[0], settled[1])) < 0.1f && length(sub(settled[2], settled[1])) < 0.1f, "layers: the settled camera agrees across 30 / 60 / 144 fps");
}

} // namespace

int main() {
    test_fov_speed_term();
    test_fov_air_term();
    test_fov_native_plus();
    test_landing_look();
    test_slope_look();
    test_vertical_follow();
    test_shoulder();
    test_follow_strength();
    test_speed_shake();
    test_collision_wall();
    test_collision_min_distance_and_budget();
    test_collision_ground_lift();
    test_layers_together();
    if (failures == 0) std::printf("s3cam_layers_tests: all passed\n");
    return failures == 0 ? 0 : 1;
}
