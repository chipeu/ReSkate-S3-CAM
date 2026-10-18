#include "Engine/Game/Camera/s3_camera.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// The Alpha 2 layers of CameraMan: FOV model, pitch prediction (landing look,
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
    // Two first-order stages of smoothing_time / 2 each (ease2_to): after one smoothing_time the response
    // to a step is 1 - e^-2 (1 + 2) = 1 - 3 e^-2.
    expect(close_to(at_tc, 4.2f * (1.0f - 3.0f * std::exp(-2.0f)), 0.15f), "fov: one smoothing_time covers 1 - 3/e^2 of the way (two-stage ease)");

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
    // Measure the landing look alone: the big-air rise (on by default) already tilts both cameras down
    // toward a drop, which would hide most of the difference.
    for (CameraSettings* c : {&on, &off}) {
        c->air_camera.rise_degrees = 0.0f;
        c->air_camera.follow_height = 0.0f;
        c->air_camera.keep_in_frame = false;
    }
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
    expect(close_to(pitch_by_follow[0], 7.41f, 0.2f), "vertical follow 1: the standing pitch is the reference value (+7.4 deg)");
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
    // Alpha 4: the big-air layers move the camera too; this helper measures the shake alone.
    np.air_camera.follow_height = 0.0f;
    np.air_camera.rise_degrees = 0.0f;
    np.air_camera.keep_in_frame = false;
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
    // Alpha 6: the collision's minimum is distance.min (default 1.2 m). This test is about the pull-in geometry with a
    // wall 0.65 m away, which the default minimum would (rightly) not follow, so it runs with the old 0.5 m minimum.
    // The default minimum and the lift over a close wall are tested in test_distance_limits.
    CameraSettings narrow;
    narrow.distance.min = 0.5f;

    CameraSettings off = narrow;
    off.collision.enabled = false;
    CameraMan c_off = make_camera(off);
    const Run free_run = drive(c_off, rider, world, 2.0f);
    expect(free_run.frames.back().pos[2] < world.wall_z, "collision off: the camera sits behind the wall");
    expect(free_run.frames.back().debug.collision_pull == 0.0f, "collision off: no pull");
    const float free_distance = length(sub(free_run.frames.back().pos, pivot));

    CameraMan cam = make_camera(narrow);
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
    CameraMan cut = make_camera(narrow);
    const Frame& first = cut.update(one_frame, rider.at(0.0f), world);
    expect(first.debug.reset && first.pos[2] > world.wall_z, "collision: a cut is already in front of the wall (no ease from outside it)");

    // Pull-in is near instant: the camera is in front of the wall within a few frames of it appearing.
    World clear;
    CameraMan c2 = make_camera(narrow);
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
    // Alpha 6: the minimum is DistanceLimits::min (collision.min_distance is unused). 0.5 m here, as before.
    CameraSettings narrow;
    narrow.distance.min = 0.5f;
    CameraMan cam = make_camera(narrow);
    const Run run = drive(cam, rider, world, 2.0f);
    const float distance = length(sub(run.frames.back().pos, pivot));
    expect(distance >= 0.5f - 0.01f, "collision: the camera never gets closer than distance.min (0.5 m) to the pivot");
    expect(distance < 0.7f, "collision: and sits near distance.min when the wall is that close (lifted a little over it)");
    CameraSettings wide;
    wide.distance.min = 1.2f;
    wide.collision.min_distance = 0.1f; // ignored
    CameraMan c2 = make_camera(wide);
    const Run r2 = drive(c2, rider, world, 2.0f);
    expect(length(sub(r2.frames.back().pos, pivot)) >= 1.2f - 0.01f, "collision: distance.min is the setting, collision.min_distance is ignored");

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
    high_clearance.collision.automatic = false; // a hand-set ground gap
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

// ================================================================ Alpha 3 core
// Speed that does not swing in tricks, the framing (distance / height / pitch / manual close-up), the
// trick yaw and the landing shake from the in-game log.

// Degrees the view points to the side: 0 looks down +Z, positive turns toward -X (the camera's heading convention).
float view_yaw_deg(const Frame& f) { return std::atan2(f.back[0], -f.back[2]) / degrees; }

// A rider plus windows in which the physics state is overridden (air / grind) or the manual flag is set.
struct Window {
    float begin = 0.0f, end = 0.0f;
    bool holds(float time) const { return time >= begin && time < end; }
};
struct Script {
    Rider rider;
    std::vector<Window> airs, grinds, manuals;
    SubjectSnapshot at(float time) const {
        SubjectSnapshot snap = rider.at(time);
        for (const Window& w : airs)
            if (w.holds(time)) snap.physics_state = physics_state::air;
        for (const Window& w : grinds)
            if (w.holds(time)) snap.physics_state = physics_state::grind_first;
        for (const Window& w : manuals)
            if (w.holds(time)) snap.manual = true;
        return snap;
    }
};

// Runs frames [from, to) seconds at `fps` (frame i is at time i / fps) and appends them. A caller can change
// the camera's settings between two calls.
template <class Source, class Query>
void drive_between(CameraMan& cam, const Source& source, Query& world, float from, float to, float fps, std::vector<Frame>& frames) {
    const int first = static_cast<int>(std::lround(from * fps)), last = static_cast<int>(std::lround(to * fps));
    for (int i = first; i < last; ++i) frames.push_back(cam.update(1.0f / fps, source.at(static_cast<float>(i) / fps), world));
}
const Frame& frame_at(const std::vector<Frame>& frames, float time, float fps) {
    return frames[static_cast<std::size_t>(std::lround(time * fps))];
}
std::string fps_tag(const char* name, float fps) { return std::string(name) + " @" + std::to_string(static_cast<int>(fps)) + " fps: "; }

// ---------------------------------------------------------------- task 1: speed that does not swing

// 8 m/s along +Z, constant velocity; riding for 1 s, then airborne for 1.9 s with the entity forward spinning a
// full turn every 0.5 s (a yaw spin, or a flip about the board's side axis), then riding again. The world is far
// below so the flight never lands in the middle.
struct SpinFlight {
    int mode = 0;                // 0: forward spins about Y (a 360), 1: about the side axis (a flip)
    float air_begin = 1.0f, air_end = 3.0f; // 2 s = four whole turns: the forward is back on +Z at the landing
    SubjectSnapshot at(float time) const {
        SubjectSnapshot snap;
        snap.valid = true;
        snap.time = time;
        snap.velocity = {0.0f, 0.0f, 8.0f};
        snap.position = {0.0f, root_height, 8.0f * time};
        snap.ground_clearance = root_height;
        if (time >= air_begin && time < air_end) {
            snap.physics_state = physics_state::air;
            const float spin = tau * (time - air_begin) / 0.5f;
            snap.forward = mode == 0 ? Vec3{std::sin(spin), 0.0f, std::cos(spin)} : Vec3{0.0f, std::sin(spin), std::cos(spin)};
        }
        return snap;
    }
};

void test_speed_holds_in_air() {
    World world;
    world.upper_y = -1000.0f;
    FrameExtras extras;
    extras.base_fov_deg = 60.0f;
    for (const int mode : {0, 1}) {
        for (const float fps : {60.0f, 144.0f}) {
            SpinFlight flight;
            flight.mode = mode;
            CameraMan cam;
            std::vector<Frame> frames;
            for (int i = 0, count = static_cast<int>(std::lround(4.0f * fps)); i < count; ++i)
                frames.push_back(cam.update(1.0f / fps, flight.at(static_cast<float>(i) / fps), world, extras));
            float worst_fov_step = 0.0f, fov_low = 1e9f, fov_high = -1e9f, follow_low = 1e9f, follow_high = -1e9f;
            float speed_low = 1e9f, speed_high = -1e9f, accel_worst = 0.0f;
            bool kicked = false;
            for (std::size_t i = 1; i < frames.size(); ++i) {
                const float t = static_cast<float>(i) / fps;
                worst_fov_step = std::max(worst_fov_step, std::abs(frames[i].fov_deg - frames[i - 1].fov_deg));
                if (t > 2.3f && t < flight.air_end) { // in the air, once the fov ease-in from the cut (0.35 s constant) is done
                    fov_low = std::min(fov_low, frames[i].fov_deg);
                    fov_high = std::max(fov_high, frames[i].fov_deg);
                    follow_low = std::min(follow_low, frames[i].debug.follow_strength);
                    follow_high = std::max(follow_high, frames[i].debug.follow_strength);
                    speed_low = std::min(speed_low, frames[i].debug.speed);
                    speed_high = std::max(speed_high, frames[i].debug.speed);
                }
                if (t > 1.0f) {
                    accel_worst = std::max(accel_worst, std::abs(frames[i].debug.forward_acceleration));
                    kicked = kicked || frames[i].debug.push_kick;
                }
            }
            const std::string tag = fps_tag(mode == 0 ? "spin 360" : "flip", fps);
            expect(worst_fov_step < 0.2f, tag + "no frame changes the fov by 0.2 deg");
            expect(fov_high - fov_low < 0.01f, tag + "the fov holds still through the spin (horizontal speed 8 m/s is constant)");
            expect(follow_high - follow_low < 1e-4f, tag + "the dynamic follow strength holds still");
            expect(speed_high - speed_low < 1e-4f && close_to(speed_low, 8.0f, 1e-3f), tag + "the speed stays at the last grounded value (8 m/s)");
            expect(accel_worst < 1.0f, tag + "the spin and the landing give no forward acceleration (|a| < 1 m/s^2)");
            expect(!kicked, tag + "and no push kick at the landing");
            // The speed fov term at 8 m/s: 6 * (8 - 5) / 10 = 1.8 deg, so the settled fov is 61.8.
            expect(close_to(frames.back().fov_deg, 61.8f, 0.05f), tag + "the settled fov is the base + the horizontal speed term");
        }
    }
    // A landing that is NOT aligned: the flight ends 0.3 turns round and the entity forward jumps back to +Z on the
    // touchdown step (the forward speed goes from 2.5 to 8 m/s). The first grounded step re-seeds the previous
    // forward speed, so that jump is not an acceleration spike and not a push.
    {
        SpinFlight flight;
        flight.air_end = 2.9f;
        CameraMan cam;
        bool kicked = false;
        float accel_worst = 0.0f;
        for (int i = 0; i < 240; ++i) {
            const float t = static_cast<float>(i) / 60.0f;
            const FrameDebug& d = cam.update(one_frame, flight.at(t), world, extras).debug;
            if (t > 1.0f) {
                accel_worst = std::max(accel_worst, std::abs(d.forward_acceleration));
                kicked = kicked || d.push_kick;
            }
        }
        expect(accel_worst < 1.0f && !kicked, "speed: a landing with the forward vector 0.3 turns off gives no acceleration spike or push");
    }
    // The speed FOV and the follow boost use the horizontal speed also on the ground: a climb with the same
    // forward speed has less horizontal speed, hence less of both.
    Rider flat, climb;
    flat.speed = climb.speed = 12.0f;
    climb.slope_degrees = 30.0f;
    World ground;
    CameraMan c_flat, c_climb;
    const Run r_flat = drive(c_flat, flat, ground, 4.0f, 60.0f, extras);
    const Run r_climb = drive(c_climb, climb, ground, 4.0f, 60.0f, extras);
    expect(close_to(r_flat.frames.back().debug.fov_extra, 6.0f * 0.7f, 0.05f), "speed fov: flat at 12 m/s = 4.2 deg");
    expect(close_to(r_climb.frames.back().debug.fov_extra, 6.0f * (12.0f * std::cos(30.0f * degrees) - 5.0f) / 10.0f, 0.05f),
           "speed fov: on a 30 degree climb the horizontal speed (10.4 m/s) drives it, not the speed along the slope");
}

// ---------------------------------------------------------------- task 2: framing

// Settled rig values after `seconds` of riding at `speed`.
FrameDebug settled_debug(const CameraSettings& cs, float speed, bool manual, float seconds = 5.0f) {
    Script script;
    script.rider.speed = speed;
    if (manual) script.manuals.push_back({0.0f, 100.0f});
    World world;
    world.upper_y = -1000.0f;
    CameraMan cam = make_camera(cs);
    std::vector<Frame> frames;
    drive_between(cam, script, world, 0.0f, seconds, 60.0f, frames);
    return frames.back().debug;
}

void test_framing_distance_height_pitch() {
    CameraSettings base;
    const FrameDebug plain = settled_debug(base, 6.0f, false);
    expect(plain.distance > 1.5f && plain.distance < 2.6f, "framing: the unscaled chase distance is the shot's (1.8 - 2.5 m)");
    CameraSettings wide_cam = base;
    wide_cam.framing.distance_scale = 1.5f;
    expect(close_to(settled_debug(wide_cam, 6.0f, false).distance, plain.distance * 1.5f, 0.02f), "framing: distance_scale multiplies the chase distance");
    CameraSettings narrow_cam = base;
    narrow_cam.framing.distance_scale = 0.8f;
    expect(close_to(settled_debug(narrow_cam, 6.0f, false).distance, plain.distance * 0.8f, 0.02f), "framing: and shortens it");
    CameraSettings high = base;
    high.framing.height_degrees = 12.0f;
    expect(close_to((settled_debug(high, 6.0f, false).elevation - plain.elevation) / degrees, 12.0f, 0.2f), "framing: height_degrees adds to the elevation");
    CameraSettings low = base;
    low.framing.height_degrees = -4.0f;
    expect(close_to((settled_debug(low, 6.0f, false).elevation - plain.elevation) / degrees, -4.0f, 0.2f), "framing: and can lower it");
    // The distance scale reaches every shot: a standing rider is in the slow chase shot, a fast one in the fast shot.
    expect(close_to(settled_debug(wide_cam, 0.0f, false).distance, settled_debug(base, 0.0f, false).distance * 1.5f, 0.02f), "framing: also at standstill");

    // Pitch: the view looks up by the offset, after the look offsets, and the clamp still holds.
    Script script;
    World world;
    world.upper_y = -1000.0f;
    CameraSettings tilt = base;
    tilt.framing.pitch_degrees = 8.0f;
    CameraMan c_plain = make_camera(base), c_tilt = make_camera(tilt);
    std::vector<Frame> f_plain, f_tilt;
    drive_between(c_plain, script, world, 0.0f, 4.0f, 60.0f, f_plain);
    drive_between(c_tilt, script, world, 0.0f, 4.0f, 60.0f, f_tilt);
    expect(close_to(view_pitch_deg(f_tilt.back()) - view_pitch_deg(f_plain.back()), 8.0f, 0.3f), "framing: pitch_degrees tilts the view up by that angle");
    CameraSettings extreme = base;
    extreme.framing.pitch_degrees = 30.0f; // the largest the settings allow
    CameraMan c_ext = make_camera(extreme);
    std::vector<Frame> f_ext;
    drive_between(c_ext, script, world, 0.0f, 4.0f, 60.0f, f_ext);
    expect(all_finite_frame(f_ext.back()) && is_orthonormal(f_ext.back()) &&
               close_to(view_pitch_deg(f_ext.back()) - view_pitch_deg(f_plain.back()), 30.0f, 0.6f),
           "framing: the largest pitch offset (30 deg) is applied in full and stays finite");
    CameraSettings down = base;
    down.framing.pitch_degrees = -30.0f;
    CameraMan c_down = make_camera(down);
    std::vector<Frame> f_down;
    drive_between(c_down, script, world, 0.0f, 4.0f, 60.0f, f_down);
    expect(close_to(view_pitch_deg(f_down.back()) - view_pitch_deg(f_plain.back()), -30.0f, 0.6f), "framing: and a negative one looks down");

    // NativePlus: the pitch offset only. It eases in from 0 after the cut and is the delta over the native pose.
    CameraSettings native = base;
    native.preset = CameraPreset::NativePlus;
    native.native_plus.shake = false;
    native.native_plus.air_hold = false;
    native.framing.distance_scale = 2.0f; // must not move a native camera
    native.framing.height_degrees = 20.0f;
    CameraSettings native_tilt = native;
    native_tilt.framing.pitch_degrees = 10.0f;
    const auto native_view = [&](const CameraSettings& cs) {
        CameraMan cam = make_camera(cs);
        Rider rider;
        std::vector<Frame> frames;
        for (int i = 0; i < 240; ++i) {
            const SubjectSnapshot s = rider.at(static_cast<float>(i) / 60.0f);
            NativePose pose;
            pose.right = {-1, 0, 0};
            pose.back = {0, 0, -1};
            pose.position = {0.0f, 1.4f, s.position[2] - 2.0f};
            FrameExtras ex;
            ex.native = &pose;
            frames.push_back(cam.update(one_frame, s, world, ex));
        }
        return frames;
    };
    const std::vector<Frame> n_plain = native_view(native), n_tilt = native_view(native_tilt);
    expect(close_to(view_pitch_deg(n_tilt.back()) - view_pitch_deg(n_plain.back()), 10.0f, 0.3f), "framing: NativePlus gets the pitch offset");
    const Rider native_rider;
    const Vec3 expected_pos{0.0f, 1.4f, native_rider.at(239.0f / 60.0f).position[2] - 2.0f};
    expect(length(sub(n_plain.back().pos, expected_pos)) < 0.05f && length(sub(n_tilt.back().pos, expected_pos)) < 0.05f,
           "framing: NativePlus ignores the distance and height scales (the game's pose is kept)");
    float first_step = std::abs(view_pitch_deg(n_tilt[1]) - view_pitch_deg(n_plain[1]));
    expect(first_step < 1.0f, "framing: the NativePlus pitch offset eases in after a cut (no pop on the first frames)");
}

// A change of the framing settings in the middle of a ride moves the camera smoothly to the new framing.
void test_framing_change_is_smooth() {
    Script script;
    World world;
    world.upper_y = -1000.0f;
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraSettings before;
        CameraMan cam = make_camera(before);
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 3.0f, fps, frames);
        const float anchor_before = frames.back().debug.distance;
        CameraSettings after = before;
        after.framing.distance_scale = 1.8f;
        after.framing.height_degrees = 20.0f;
        after.framing.pitch_degrees = 6.0f;
        expect(cam.set_settings(after), "framing: settings accepted mid-ride");
        drive_between(cam, script, world, 3.0f, 8.0f, fps, frames);
        // Relative to the skater: the camera's offset from the rider changes continuously.
        float worst_offset_step = 0.0f, worst_pitch_step = 0.0f;
        for (std::size_t i = 1; i < frames.size(); ++i) {
            const Vec3 o_now = sub(frames[i].pos, script.at(static_cast<float>(i) / fps).position);
            const Vec3 o_prev = sub(frames[i - 1].pos, script.at(static_cast<float>(i - 1) / fps).position);
            worst_offset_step = std::max(worst_offset_step, length(sub(o_now, o_prev)));
            worst_pitch_step = std::max(worst_pitch_step, std::abs(view_pitch_deg(frames[i]) - view_pitch_deg(frames[i - 1])));
        }
        const std::string tag = fps_tag("framing change", fps);
        // The rig's distance tracker (6 m/s, 20 m/s^2) and the elevation tracker do the easing; nothing snaps.
        expect(worst_offset_step < 7.5f / fps, tag + "the camera moves at most 7.5 m/s relative to the skater");
        // Alpha 5: the +20 degrees of height is now an offset eased over ~0.3 s after the rig's elevation tracker (it
        // crawled through the tracker at ~3.6 deg/s before), so the view pitch turns faster while it settles: the bound was
        // 30 deg/s, now ~36 deg/s with the +6 degree pitch change on top. Still a smooth turn, no snap.
        expect(worst_pitch_step < 45.0f / fps, tag + "and the view pitch turns at most 45 deg/s");
        expect(close_to(frames.back().debug.distance, anchor_before * 1.8f, 0.03f), tag + "it settles at the new distance");
    }
}

// SubjectSnapshot::manual selects the manual shots, and the close-up scales their distance.
void test_framing_manual() {
    CameraSettings base;
    const FrameDebug chase_fast = settled_debug(base, 7.0f, false);
    const FrameDebug chase_slow = settled_debug(base, 3.0f, false);
    expect(std::string(chase_fast.shot_name) == "chase" && std::string(chase_slow.shot_name) == "chase", "manual: without the flag the shot is the chase");
    const FrameDebug far_shot = settled_debug(base, 7.0f, true);
    const FrameDebug close_shot = settled_debug(base, 3.0f, true);
    expect(std::string(far_shot.shot_name) == "manual_far", "manual: SubjectSnapshot::manual at 7 m/s selects the far manual shot");
    expect(std::string(close_shot.shot_name) == "manual_close", "manual: at 3 m/s the close manual shot");
    // Beta feedback: the close-up has its own distance (manual_distance, metres), the same at any speed, and the main
    // camera's distance scale, height and limits do not apply to it.
    expect(close_to(far_shot.distance, base.framing.manual_distance, 0.03f), "manual: far manual distance = manual_distance");
    expect(close_to(close_shot.distance, base.framing.manual_distance, 0.03f), "manual: close manual distance = manual_distance too");
    expect(far_shot.distance < chase_fast.distance - 0.3f, "manual: shorter than the chase at the same speed");
    for (const float metres : {0.8f, 1.6f, 2.5f, 4.0f}) {
        CameraSettings cs = base;
        cs.framing.manual_distance = metres;
        expect(close_to(settled_debug(cs, 7.0f, true).distance, metres, 0.03f), "manual: the distance follows manual_distance, below the main minimum too");
    }
    // Off: manual shots keep their own table distance and elevation.
    CameraSettings off = base;
    off.framing.manual_camera = false;
    off.framing.manual_distance = 0.8f;
    off.framing.manual_height_degrees = 20.0f;
    const FrameDebug off_far = settled_debug(off, 7.0f, true);
    expect(close_to(off_far.distance, 2.35f, 0.02f) && close_to(off_far.elevation, 13.0f * degrees, 0.2f * degrees), "manual: manual_camera off applies no close-up");
    // The manual height is its own: the main height_degrees does not add to it.
    CameraSettings tall = base;
    tall.framing.manual_height_degrees = 10.0f;
    tall.framing.height_degrees = 3.0f;
    expect(close_to(settled_debug(tall, 7.0f, true).elevation, (13.0f + 10.0f) * degrees, 0.3f * degrees), "manual: manual_height_degrees only, not + height_degrees");
    expect(close_to(settled_debug(tall, 7.0f, false).elevation - chase_fast.elevation, 3.0f * degrees, 0.3f * degrees), "manual: the chase gets height_degrees");
    // The main distance scale does not change the close-up.
    CameraSettings both = base;
    both.framing.distance_scale = 1.2f;
    expect(close_to(settled_debug(both, 7.0f, true).distance, base.framing.manual_distance, 0.04f), "manual: distance_scale leaves the close-up alone");

    // Entering and leaving a manual blends over the shot transition (no jump of the camera).
    Script script;
    script.rider.speed = 7.0f;
    script.manuals.push_back({2.0f, 4.0f});
    World world;
    world.upper_y = -1000.0f;
    CameraMan cam;
    std::vector<Frame> frames;
    drive_between(cam, script, world, 0.0f, 7.0f, 60.0f, frames);
    float worst = 0.0f;
    bool saw_manual = false;
    for (std::size_t i = 1; i < frames.size(); ++i) {
        worst = std::max(worst, std::abs(frames[i].debug.distance - frames[i - 1].debug.distance));
        saw_manual = saw_manual || std::string(frames[i].debug.shot_name) == "manual_far";
    }
    // 0.8 m (chase 2.4 -> manual 1.6) over the 0.4 s sine transition peaks near 3.1 m/s = 5.2 cm a frame (6.5 measured).
    std::printf("  manual: worst rig distance step %.3f m\n", worst);
    expect(saw_manual && worst < 0.07f, "manual: entering / leaving the manual moves the rig distance by less than 7 cm a frame");
    expect(std::string(frames.back().debug.shot_name) == "chase", "manual: back to the chase afterwards");
}

// A jump and a step-down with all the framing on stays continuous at every frame rate: the camera's worst
// frame-to-frame step is no more than the distance scale (1.4) times that of the unframed camera.
void test_framing_continuity() {
    Rider rider;
    rider.has_drop = true;
    World world;
    world.drop_z = rider.edge_z;
    world.drop_to = -rider.drop_height;
    CameraSettings cs;
    cs.framing.distance_scale = 1.4f;
    cs.framing.height_degrees = 8.0f;
    cs.framing.pitch_degrees = -3.0f;
    const auto worst_step_of = [&](const CameraSettings& settings, float fps, bool& ok) {
        CameraMan cam = make_camera(settings);
        const Run run = drive(cam, rider, world, 6.0f, fps);
        float worst = 0.0f;
        for (std::size_t i = 0; i < run.frames.size(); ++i) {
            ok = ok && all_finite_frame(run.frames[i]) && is_orthonormal(run.frames[i]);
            if (i > 0) worst = std::max(worst, length(sub(run.frames[i].pos, run.frames[i - 1].pos)));
        }
        return worst;
    };
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        bool ok = true;
        const float framed_step = worst_step_of(cs, fps, ok);
        const float plain_step = worst_step_of(CameraSettings{}, fps, ok);
        expect(ok, fps_tag("framing drop", fps) + "finite and orthonormal");
        expect(framed_step < plain_step * 1.5f + 0.02f, fps_tag("framing drop", fps) + "the framed camera's worst step stays in proportion to the plain one");
        expect(framed_step < 0.7f, fps_tag("framing drop", fps) + "and no frame moves it by 0.7 m");
    }
}

// ---------------------------------------------------------------- task 3: trick yaw

float yaw_deg(const Frame& f) { return f.debug.trick_yaw / degrees; }

Script air_script(float begin, float end) {
    Script script;
    script.airs.push_back({begin, end});
    return script;
}

void test_trick_yaw_long_air() {
    World world;
    world.upper_y = -1000.0f;
    const Script script = air_script(2.0f, 4.0f);
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraMan cam;
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 8.0f, fps, frames);
        const std::string tag = fps_tag("trick yaw", fps);
        float before = 0.0f, worst_yaw_step = 0.0f, worst_view_step = 0.0f;
        for (std::size_t i = 0; i < frames.size(); ++i) {
            const float t = static_cast<float>(i) / fps;
            if (t < 2.2f) before = std::max(before, std::abs(yaw_deg(frames[i])));
            if (i > 0) {
                worst_yaw_step = std::max(worst_yaw_step, std::abs(yaw_deg(frames[i]) - yaw_deg(frames[i - 1])));
                worst_view_step = std::max(worst_view_step, std::abs(view_yaw_deg(frames[i]) - view_yaw_deg(frames[i - 1])));
            }
        }
        expect(before < 1e-4f, tag + "no swing before the air has lasted min_air_time (0.2 s)");
        expect(yaw_deg(frame_at(frames, 2.3f, fps)) > 0.0f && yaw_deg(frame_at(frames, 2.3f, fps)) < 5.0f, tag + "the swing starts gently (sine ease, no velocity jump)");
        // Out by 2.2 + 0.6 = 2.8 s; held to the landing at 4.0 and for 0.5 s after it.
        expect(close_to(yaw_deg(frame_at(frames, 2.9f, fps)), 25.0f, 0.1f), tag + "it has swung out to angle_degrees (25) after in_time");
        float hold_low = 1e9f, hold_high = -1e9f;
        for (float t = 2.9f; t < 4.45f; t += 0.01f) {
            const float v = yaw_deg(frame_at(frames, t, fps));
            hold_low = std::min(hold_low, v);
            hold_high = std::max(hold_high, v);
        }
        expect(hold_low > 24.99f && hold_high < 25.01f, tag + "and holds through the rest of the air and hold_time");
        expect(yaw_deg(frame_at(frames, 5.0f, fps)) < 24.0f && yaw_deg(frame_at(frames, 5.0f, fps)) > 5.0f, tag + "then recentres gradually");
        expect(close_to(yaw_deg(frame_at(frames, 6.6f, fps)), 0.0f, 0.05f), tag + "and is centred again after return_time");
        // Per frame: the ease peaks at angle * pi / 2 / in_time = 65 deg/s, the return is slower.
        // (debug.trick_yaw is the value of the latest fixed step, so it moves in 1/60 s increments above 60 fps.)
        expect(worst_yaw_step <= 70.0f / std::min(fps, 60.0f), tag + "the swing never changes faster than 70 deg/s");
        // The view follows the camera's orbit (the pan tracker keeps it on the skater): bounded too.
        expect(worst_view_step <= 110.0f / fps, tag + "and the view yaw never turns faster than 110 deg/s");
        // The skater stays in the frame the whole time, and the camera is on the skater's right (-X).
        const Frame& held = frame_at(frames, 3.8f, fps);
        const Vec3 rider_pos = script.at(3.8f).position;
        expect(held.pos[0] < rider_pos[0] - 0.5f, tag + "side +1 puts the camera on the skater's right (-X when riding +Z)");
        expect(std::abs(lateral_of(held, rider_pos)) < 0.25f, tag + "the view keeps aiming at the skater");
        for (const Frame& f : frames) expect(all_finite_frame(f) && is_orthonormal(f), tag + "finite and orthonormal");
    }
    // A hop shorter than min_air_time stays centred.
    CameraMan cam;
    std::vector<Frame> frames;
    drive_between(cam, air_script(2.0f, 2.15f), world, 0.0f, 5.0f, 60.0f, frames);
    float worst = 0.0f;
    for (const Frame& f : frames) worst = std::max(worst, std::abs(f.debug.trick_yaw));
    expect(worst == 0.0f, "trick yaw: a 0.15 s hop (under min_air_time) never swings");
}

void test_trick_yaw_back_to_back() {
    World world;
    world.upper_y = -1000.0f;
    // Air 2.0-3.0, 0.2 s on the ground, air 3.2-4.2. The second air counts as a trick from 3.4 s, inside the
    // 0.5 s hold that began at 3.0.
    Script script;
    script.airs = {{2.0f, 3.0f}, {3.2f, 4.2f}};
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraMan cam;
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 9.0f, fps, frames);
        const std::string tag = fps_tag("trick yaw back to back", fps);
        float lowest = 1e9f;
        for (float t = 2.85f; t < 4.65f; t += 0.01f) lowest = std::min(lowest, yaw_deg(frame_at(frames, t, fps)));
        expect(lowest > 24.99f, tag + "no dip between the two airs (held at 25 deg from 2.85 to 4.65 s)");
        expect(yaw_deg(frame_at(frames, 5.3f, fps)) < 25.0f - 0.5f, tag + "it recentres after the last one (hold ends at 4.7)");
        expect(close_to(yaw_deg(frame_at(frames, 6.4f, fps)), 0.0f, 0.1f), tag + "and is centred by 4.7 + 1.5 s");
    }
    // The same two airs with the hold shortened to 0.1 s: it does dip back (the hold is what bridges the gap).
    CameraSettings short_hold;
    short_hold.trick_yaw.hold_time = 0.1f;
    CameraMan cam = make_camera(short_hold);
    std::vector<Frame> frames;
    drive_between(cam, script, world, 0.0f, 5.0f, 60.0f, frames);
    float lowest = 1e9f;
    for (float t = 3.1f; t < 3.9f; t += 0.01f) lowest = std::min(lowest, yaw_deg(frame_at(frames, t, 60.0f)));
    expect(lowest < 24.0f, "trick yaw: with hold_time 0.1 the gap between the airs lets it start back");
}

void test_trick_yaw_retrigger_while_recentring() {
    World world;
    world.upper_y = -1000.0f;
    Script script;
    script.airs = {{2.0f, 3.0f}, {4.0f, 5.0f}}; // hold ends at 3.5, the return runs to 5.0: the second air starts it out again at 4.2
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraMan cam;
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 9.0f, fps, frames);
        const std::string tag = fps_tag("trick yaw retrigger", fps);
        const float at_4_2 = yaw_deg(frame_at(frames, 4.2f, fps));
        expect(at_4_2 > 5.0f && at_4_2 < 24.0f, tag + "a trick starting mid-recentre finds it part way back");
        float worst_step = 0.0f;
        for (std::size_t i = 1; i < frames.size(); ++i) worst_step = std::max(worst_step, std::abs(yaw_deg(frames[i]) - yaw_deg(frames[i - 1])));
        expect(worst_step <= 70.0f / std::min(fps, 60.0f), tag + "no snap anywhere: at most 70 deg/s");
        expect(close_to(yaw_deg(frame_at(frames, 5.0f, fps)), 25.0f, 0.2f), tag + "it eases back out to the full angle");
        expect(close_to(yaw_deg(frame_at(frames, 8.5f, fps)), 0.0f, 0.1f), tag + "and recentres at the end");
    }
}

void test_trick_yaw_side_rules() {
    World world;
    world.upper_y = -1000.0f;
    const auto swing = [&](const CameraSettings& cs, bool switch_stance) {
        Script script = air_script(1.0f, 3.0f);
        script.rider.switch_stance = switch_stance;
        CameraMan cam = make_camera(cs);
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 2.8f, 60.0f, frames);
        return yaw_deg(frames.back());
    };
    CameraSettings regular;
    expect(close_to(swing(regular, false), 25.0f, 0.1f), "side: regular stance swings to the right (+25)");
    expect(close_to(swing(regular, true), -25.0f, 0.1f), "side: regular riding switch swings to the left (-25)");
    CameraSettings goofy;
    goofy.shoulder.goofy = true;
    expect(close_to(swing(goofy, false), -25.0f, 0.1f), "side: goofy swings to the left");
    expect(close_to(swing(goofy, true), 25.0f, 0.1f), "side: goofy riding switch swings to the right");
    CameraSettings auto_mode = goofy; // the shoulder Auto rule is the same
    auto_mode.shoulder.mode = ShoulderSide::Auto;
    expect(close_to(swing(auto_mode, false), -25.0f, 0.1f), "side: shoulder Auto uses the same stance rule");
    CameraSettings manual_left;
    manual_left.shoulder.mode = ShoulderSide::Manual;
    manual_left.shoulder.side = -1;
    expect(close_to(swing(manual_left, false), -25.0f, 0.1f), "side: shoulder Manual -1 swings to the left");
    manual_left.shoulder.side = 1;
    manual_left.shoulder.goofy = true; // ignored in Manual
    expect(close_to(swing(manual_left, false), 25.0f, 0.1f), "side: shoulder Manual +1 swings to the right, whatever the stance");
    CameraSettings forced = manual_left;
    forced.trick_yaw.side = -1;
    expect(close_to(swing(forced, false), -25.0f, 0.1f), "side: trick_yaw.side overrides the shoulder and the stance");
    forced.trick_yaw.side = 1;
    forced.shoulder.mode = ShoulderSide::Manual;
    forced.shoulder.side = -1;
    expect(close_to(swing(forced, true), 25.0f, 0.1f), "side: trick_yaw.side +1 wins");
    CameraSettings wide;
    wide.trick_yaw.angle_degrees = 40.0f;
    expect(close_to(swing(wide, false), 40.0f, 0.1f), "side: angle_degrees is the size of the swing");
}

void test_trick_yaw_triggers() {
    World world;
    world.upper_y = -1000.0f;
    const auto reach = [&](const Script& script, const CameraSettings& cs, float until) {
        CameraMan cam = make_camera(cs);
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, until, 60.0f, frames);
        float best = 0.0f;
        for (const Frame& f : frames) best = std::max(best, std::abs(yaw_deg(f)));
        return best;
    };
    Script grind;
    grind.grinds.push_back({1.0f, 3.0f});
    Script manual;
    manual.manuals.push_back({1.0f, 3.0f});
    const Script air = air_script(1.0f, 3.0f);
    CameraSettings defaults;
    expect(reach(grind, defaults, 3.0f) == 0.0f, "triggers: grinds do not swing by default");
    expect(reach(manual, defaults, 3.0f) == 0.0f, "triggers: manuals do not swing by default");
    CameraSettings on_grind = defaults;
    on_grind.trick_yaw.on_grinds = true;
    expect(close_to(reach(grind, on_grind, 3.0f), 25.0f, 0.1f), "triggers: on_grinds swings during a grind");
    CameraSettings on_manual = defaults;
    on_manual.trick_yaw.on_manuals = true;
    expect(close_to(reach(manual, on_manual, 3.0f), 25.0f, 0.1f), "triggers: on_manuals swings during a manual");
    expect(reach(air, on_manual, 3.0f) > 24.0f, "triggers: air still swings with the manuals on");
    CameraSettings no_air = on_grind;
    no_air.trick_yaw.in_air = false;
    expect(reach(air, no_air, 3.0f) == 0.0f, "triggers: in_air off keeps the air centred");
    CameraSettings off = defaults;
    off.trick_yaw.enabled = false;
    expect(reach(air, off, 3.0f) == 0.0f && reach(grind, off, 3.0f) == 0.0f, "triggers: disabled never swings");
    CameraSettings native = defaults;
    native.preset = CameraPreset::NativePlus;
    {
        CameraMan cam = make_camera(native);
        float worst = 0.0f;
        for (int i = 0; i < 240; ++i) {
            const SubjectSnapshot s = air.at(static_cast<float>(i) / 60.0f);
            NativePose pose;
            pose.right = {-1, 0, 0};
            pose.back = {0, 0, -1};
            pose.position = {0.0f, 1.4f, s.position[2] - 2.0f};
            FrameExtras ex;
            ex.native = &pose;
            worst = std::max(worst, std::abs(cam.update(one_frame, s, world, ex).debug.trick_yaw));
        }
        expect(worst == 0.0f, "triggers: NativePlus has no trick yaw");
    }
    // A bail is not a trick: it cancels the swing straight away (no hold).
    Script bail = air_script(1.0f, 4.0f);
    CameraMan cam;
    std::vector<Frame> frames;
    drive_between(cam, bail, world, 0.0f, 2.5f, 60.0f, frames);
    const float out = yaw_deg(frames.back());
    SubjectSnapshot hurt = bail.at(2.5f);
    hurt.bailing = true;
    float after_half_second = 0.0f;
    for (int i = 0; i < 30; ++i) after_half_second = yaw_deg(cam.update(one_frame, hurt, world));
    expect(close_to(out, 25.0f, 0.1f) && after_half_second < out - 5.0f, "triggers: a bail starts recentring at once (no hold)");
}

void test_trick_yaw_disable_and_cut() {
    World world;
    world.upper_y = -1000.0f;
    const Script script = air_script(1.0f, 20.0f);
    CameraMan cam;
    std::vector<Frame> frames;
    drive_between(cam, script, world, 0.0f, 3.0f, 60.0f, frames);
    expect(close_to(yaw_deg(frames.back()), 25.0f, 0.1f), "disable: swung out");
    CameraSettings off;
    off.trick_yaw.enabled = false;
    expect(cam.set_settings(off), "disable: settings accepted");
    drive_between(cam, script, world, 3.0f, 6.0f, 60.0f, frames);
    float worst = 0.0f, previous = yaw_deg(frames[179]);
    bool monotone = true;
    for (std::size_t i = 180; i < frames.size(); ++i) {
        worst = std::max(worst, std::abs(yaw_deg(frames[i]) - previous));
        monotone = monotone && yaw_deg(frames[i]) <= previous + 1e-4f;
        previous = yaw_deg(frames[i]);
    }
    expect(worst < 1.2f && monotone, "disable: eases to 0 (no snap, monotone)");
    expect(close_to(yaw_deg(frames.back()), 0.0f, 0.01f), "disable: centred after return_time");
    // Back on, still in the air: swings out again from where it is.
    CameraSettings on;
    expect(cam.set_settings(on), "re-enable: settings accepted");
    drive_between(cam, script, world, 6.0f, 8.0f, 60.0f, frames);
    expect(close_to(yaw_deg(frames.back()), 25.0f, 0.1f), "re-enable: swings out again");
    // A cut snaps it to 0 on that frame.
    cam.request_reset();
    const Frame& cut = cam.update(one_frame, script.at(8.0f), world);
    expect(cut.debug.reset && cut.debug.trick_yaw == 0.0f, "cut: the trick yaw snaps to 0");
    // And a degenerate setting set is rejected.
    CameraSettings bad;
    bad.trick_yaw.angle_degrees = 120.0f;
    expect(!cam.set_settings(bad), "validation: an angle over 90 degrees is rejected");
    CameraSettings bad_framing;
    bad_framing.framing.distance_scale = 0.1f;
    expect(!cam.set_settings(bad_framing), "validation: a distance scale under 0.4 is rejected");
}

// ---------------------------------------------------------------- task 4: landing shake from the in-game log

void test_landing_impulse_in_game() {
    // 6.6 m/s forward: a plain flat ollie, a 1 m drop and a 3 m drop, through the whole camera.
    const auto landing_share = [](bool ollie, float drop) {
        Rider rider;
        rider.speed = 6.6f;
        World world;
        if (ollie) {
            rider.has_ollie = true;
        } else {
            rider.has_drop = true;
            rider.drop_height = drop;
            world.drop_z = rider.edge_z;
            world.drop_to = -drop;
        }
        CameraMan cam;
        const Run run = drive(cam, rider, world, 5.0f);
        float before = 0.0f, best = 0.0f;
        const float land = ollie ? rider.ollie_time + rider.air_time_ollie() : rider.edge_time() + rider.fall_time();
        for (std::size_t i = 0; i < run.frames.size(); ++i) {
            const float t = static_cast<float>(i) / 60.0f;
            if (t < land - 0.1f) before = std::max(before, run.frames[i].debug.impulse);
            if (t >= land - 0.05f && t < land + 0.3f) best = std::max(best, run.frames[i].debug.impulse);
        }
        expect(before == 0.0f, "landing log: no impulse before the touchdown");
        return best / CameraSettings{}.shake.one_shot_magnitude;
    };
    const float ollie = landing_share(true, 0.0f);
    const float one_m = landing_share(false, 1.0f);
    const float three_m = landing_share(false, 3.0f);
    std::printf("  landing impulse through the camera, share of full: ollie %.3f, 1 m drop %.3f, 3 m drop %.3f\n", static_cast<double>(ollie),
                static_cast<double>(one_m), static_cast<double>(three_m));
    // Alpha 5: the strength comes from the fall height now (LandingShakeSettings: 0.5 m / 2.5 m, speed weight 0.1), so a
    // flat ollie (a fall of ~0.4 m) is lighter than the old velocity weighting gave (4-22% -> 0-12%) and a 1 m drop is
    // ~0.25 (was 0.38); the 3 m drop is unchanged.
    expect(ollie >= 0.0f && ollie < 0.12f, "landing log: a plain flat ollie gives at most a light impulse (under 12% of full)");
    expect(one_m >= 0.15f && one_m <= 0.5f, "landing log: a 1 m drop at 6.6 m/s gives a clear but moderate impulse (15-50%)");
    expect(three_m >= 0.9f, "landing log: a 3 m drop is near full");
    expect(ollie < one_m && one_m < three_m, "landing log: and they rise with the drop");
}

} // namespace


// ---------------------------------------------------------------- Alpha 4: big airs, focus, Low / High framing

// A native camera that follows the skater: 2 m behind, 0.5 m above the root, aimed at the root.
NativePose air_native_pose(const SubjectSnapshot& s) {
    NativePose pose;
    pose.position = {s.position[0], s.position[1] + 0.5f, s.position[2] - 2.0f};
    const Vec3 look = normalized(sub(s.position, pose.position));
    pose.back = scale(look, -1.0f);
    pose.right = normalized(cross({0.0f, 1.0f, 0.0f}, pose.back));
    pose.up = cross(pose.back, pose.right);
    pose.fov_deg = 60.0f;
    return pose;
}

// Angle in degrees between the view direction and the line camera -> point.
float angle_to_point_deg(const Frame& f, const Vec3& point) {
    return std::acos(std::clamp(dot(scale(f.back, -1.0f), normalized(sub(point, f.pos))), -1.0f, 1.0f)) / degrees;
}

struct AirTrace {
    std::vector<Frame> frames;
    std::vector<SubjectSnapshot> subjects;
    float fps = 60.0f;
};
// kind 0: a 4 m high jump on the flat; kind 1: a 3 m step-down. The native pose is used in NativePlus.
AirTrace run_air(const CameraSettings& settings, int kind, float fps, float apex_height = 4.0f) {
    Rider rider;
    World world;
    if (kind == 0) {
        rider.has_ollie = true;
        rider.jump_speed = std::sqrt(2.0f * gravity_ms2 * apex_height);
        rider.ollie_time = 1.0f;
    } else {
        rider.has_drop = true;
        rider.drop_height = 3.0f;
        world.drop_z = rider.edge_z;
        world.drop_to = -rider.drop_height;
    }
    AirTrace trace;
    trace.fps = fps;
    CameraMan cam = make_camera(settings);
    const int count = static_cast<int>(std::lround(5.0f * fps));
    for (int i = 0; i < count; ++i) {
        const SubjectSnapshot s = rider.at(static_cast<float>(i) / fps);
        const NativePose pose = air_native_pose(s);
        FrameExtras extras;
        extras.base_fov_deg = 60.0f;
        extras.native = &pose;
        trace.frames.push_back(cam.update(1.0f / fps, s, world, extras));
        trace.subjects.push_back(s);
    }
    return trace;
}

CameraSettings classic_air(CameraPreset preset) {
    CameraSettings cs;
    cs.preset = preset;
    cs.air_camera.follow_height = 0.0f;
    cs.air_camera.rise_degrees = 0.0f;
    cs.air_camera.keep_in_frame = false;
    return cs;
}

void test_air_camera_in_frame() {
    for (const CameraPreset preset : {CameraPreset::FullS3, CameraPreset::NativePlus}) {
        for (const int kind : {0, 1}) {
            for (const float fps : {30.0f, 60.0f, 144.0f}) {
                CameraSettings cs;
                cs.preset = preset;
                const AirTrace trace = run_air(cs, kind, fps);
                float worst_ratio = 0.0f, worst_step = 0.0f;
                bool frames_ok = true;
                for (std::size_t i = 0; i < trace.frames.size(); ++i) {
                    const Frame& f = trace.frames[i];
                    frames_ok = frames_ok && all_finite_frame(f) && is_orthonormal(f);
                    const Vec3 root = trace.subjects[i].position;
                    const Vec3 board = add(root, {0.0f, -cs.points.board_drop, 0.0f});
                    worst_ratio = std::max({worst_ratio, angle_to_point_deg(f, root) / (0.5f * f.fov_deg), angle_to_point_deg(f, board) / (0.5f * f.fov_deg)});
                    if (i > 0) worst_step = std::max(worst_step, length(sub(f.pos, trace.frames[i - 1].pos)));
                }
                float classic_step = 0.0f;
                {
                    const AirTrace before = run_air(classic_air(preset), kind, fps);
                    for (std::size_t i = 1; i < before.frames.size(); ++i) classic_step = std::max(classic_step, length(sub(before.frames[i].pos, before.frames[i - 1].pos)));
                }
                const std::string tag = fps_tag(preset == CameraPreset::FullS3 ? (kind == 0 ? "FullS3 4 m air" : "FullS3 3 m drop") : (kind == 0 ? "NativePlus 4 m air" : "NativePlus 3 m drop"), fps);
                std::printf("  %sworst angle %.0f%% of the half vertical fov, max camera step %.2f m\n", tag.c_str(), static_cast<double>(worst_ratio * 100.0f), static_cast<double>(worst_step));
                expect(frames_ok, tag + "frames are frames_ok and orthonormal");
                expect(worst_ratio <= 1.0f, tag + "the skater and the board stay inside the vertical view in every frame");
                // The camera follows the skater more now, so it moves more than the held one, but never in a jump.
                expect(worst_step < 1.6f * classic_step + 0.1f, tag + "and the camera's biggest step stays under 1.6x the Alpha 3 one + 10 cm");
            }
        }
    }
}

// Worst angle of the skater (root and board) from the view axis over a trace, as a share of the half fov.
float worst_frame_ratio(const AirTrace& trace, const CameraSettings& cs) {
    float worst_ratio = 0.0f;
    for (std::size_t i = 0; i < trace.frames.size(); ++i) {
        const Frame& f = trace.frames[i];
        const Vec3 root = trace.subjects[i].position;
        const Vec3 board = add(root, {0.0f, -cs.points.board_drop, 0.0f});
        worst_ratio = std::max({worst_ratio, angle_to_point_deg(f, root) / (0.5f * f.fov_deg), angle_to_point_deg(f, board) / (0.5f * f.fov_deg)});
    }
    return worst_ratio;
}
// Frame index nearest `time` in a trace.
std::size_t index_at(const AirTrace& trace, float time) { return static_cast<std::size_t>(std::lround(time * trace.fps)); }

void test_air_camera_layers() {
    constexpr float takeoff = 1.0f;
    const float apex_time = takeoff + std::sqrt(2.0f * 4.0f / gravity_ms2); // 4 m jump: 0.89 s up
    for (const CameraPreset preset : {CameraPreset::FullS3, CameraPreset::NativePlus}) {
        const std::string name = preset == CameraPreset::FullS3 ? "FullS3: " : "NativePlus: ";
        const CameraSettings plain = classic_air(preset);
        const AirTrace classic = run_air(plain, 0, 60.0f);
        const std::size_t apex = index_at(classic, apex_time);

        // All three off = the Alpha 3 camera: the layers report nothing, and the skater does leave the view.
        float worst_report = 0.0f;
        for (const Frame& f : classic.frames) worst_report = std::max({worst_report, std::abs(f.debug.air_rise), std::abs(f.debug.keep_pitch_offset)});
        expect(worst_report == 0.0f, name + "rise 0 and keep off report 0");
        expect(worst_frame_ratio(classic, plain) > 1.0f, name + "without the air camera the skater leaves the view in a 4 m air (the reported problem)");

        // keep_in_frame alone.
        CameraSettings keep = plain;
        keep.air_camera.keep_in_frame = true;
        const AirTrace kept = run_air(keep, 0, 60.0f), kept_drop = run_air(keep, 1, 60.0f);
        expect(worst_frame_ratio(kept, keep) <= 1.0f && worst_frame_ratio(kept_drop, keep) <= 1.0f, name + "keep_in_frame alone keeps a 4 m air and a 3 m drop in view");
        float worst_keep = 0.0f, worst_keep_step = 0.0f;
        for (std::size_t i = 0; i < kept.frames.size(); ++i) {
            worst_keep = std::max(worst_keep, std::abs(kept.frames[i].debug.keep_pitch_offset));
            if (i > 0) worst_keep_step = std::max(worst_keep_step, std::abs(kept.frames[i].debug.keep_pitch_offset - kept.frames[i - 1].debug.keep_pitch_offset));
        }
        expect(worst_keep > 5.0f * degrees, name + "keep_in_frame steers the pitch in a 4 m air");
        expect(worst_keep_step < 5.0f * degrees, name + "and eases it (under 5 deg a frame, no snap)");
        expect(kept.frames.front().debug.keep_pitch_offset == 0.0f && std::abs(kept.frames.back().debug.keep_pitch_offset) < 0.1f * degrees,
               name + "it is 0 on the ground before the jump and eased out after the landing");

        // follow_height alone: the reference rises with the skater, without a jump at takeoff or landing.
        CameraSettings follow = plain;
        follow.air_camera.follow_height = 1.0f;
        const AirTrace followed = run_air(follow, 0, 60.0f);
        const float ref_follow = followed.frames[apex].debug.air_reference_height, ref_plain = classic.frames[apex].debug.air_reference_height;
        const float anchor_apex = followed.subjects[apex].position[1] - follow.points.board_drop + follow.points.anchor_height;
        expect(ref_follow > ref_plain + 2.0f && anchor_apex - ref_follow < 0.6f, name + "follow_height 1 puts the reference height near the live anchor at the apex");
        float worst_ref_step = 0.0f;
        for (std::size_t i = 1; i < followed.frames.size(); ++i)
            worst_ref_step = std::max(worst_ref_step, std::abs(followed.frames[i].debug.air_reference_height - followed.frames[i - 1].debug.air_reference_height));
        expect(worst_ref_step < 0.2f, name + "the reference height has no jump at takeoff or landing (under 20 cm a frame)");
        if (preset == CameraPreset::NativePlus)
            expect(followed.frames[apex].debug.air_hold_delta > -0.6f && classic.frames[apex].debug.air_hold_delta < -3.0f,
                   name + "the air hold offset shrinks with follow_height (scaled by 1 - follow)");
        CameraSettings half = plain;
        half.air_camera.follow_height = 0.5f;
        const float ref_half = run_air(half, 0, 60.0f).frames[apex].debug.air_reference_height;
        expect(ref_half > ref_plain + 0.3f * (ref_follow - ref_plain) && ref_half < ref_plain + 0.7f * (ref_follow - ref_plain), name + "follow_height 0.5 is in between");

        // rise_degrees alone: the camera is higher and the elevation eases in and out.
        CameraSettings rise = plain;
        rise.air_camera.rise_degrees = 15.0f;
        rise.air_camera.rise_full_height = 2.0f; // the scaling check below assumes full at 2 m (default is 1.5)
        const AirTrace risen = run_air(rise, 0, 60.0f);
        const float rise_at_apex = risen.frames[apex].debug.air_rise / degrees;
        expect(rise_at_apex > 10.0f && rise_at_apex <= 15.0f, name + "a 4 m air rises about rise_degrees at the apex");
        const std::size_t early = index_at(classic, takeoff + 0.3f); // before the engine's floor clearance (3 m max) lifts both cameras
        expect(risen.frames[early].pos[1] > classic.frames[early].pos[1] + 0.2f, name + "and the camera is higher there");
        expect(std::abs(risen.frames.back().debug.air_rise) < 0.1f * degrees, name + "the rise is back to 0 after the landing");
        float worst_rise_step = 0.0f;
        for (std::size_t i = 1; i < risen.frames.size(); ++i) worst_rise_step = std::max(worst_rise_step, std::abs(risen.frames[i].debug.air_rise - risen.frames[i - 1].debug.air_rise));
        // The rise builds about 2x faster than it releases (Alpha 4 tuning: a slow build left the camera
        // below the rising skater, looking up), through the two-stage ease, so it starts gently: ~1.05
        // deg/frame at most for 15 deg.
        expect(worst_rise_step < 1.5f * degrees, name + "the rise eases (under 1.5 deg a frame)");
        // The rise scales with the size of the air: a 1 m jump (rise_full_height 2) gets about half of a 4 m one.
        float small_peak = 0.0f, big_peak = 0.0f;
        for (const Frame& f : run_air(rise, 0, 60.0f, 1.0f).frames) small_peak = std::max(small_peak, f.debug.air_rise);
        for (const Frame& f : risen.frames) big_peak = std::max(big_peak, f.debug.air_rise);
        expect(small_peak > 0.1f * big_peak && small_peak < 0.6f * big_peak, name + "a 1 m jump rises about half as much as a 4 m one");
        if (preset == CameraPreset::NativePlus) {
            const Vec3 root = risen.subjects[apex].position;
            expect(std::abs(angle_to_point_deg(risen.frames[apex], root) - angle_to_point_deg(classic.frames[apex], root)) < 2.0f,
                   name + "the skater stays in the same screen spot while the native camera rises");
        }

        // Above the skater looking down near the apex (follow 1 so the rig keeps up) and near the landing of a drop.
        CameraSettings above = plain;
        above.air_camera.follow_height = 1.0f;
        above.air_camera.rise_degrees = 30.0f;
        const AirTrace over = run_air(above, 0, 60.0f);
        const Frame& top = over.frames[apex];
        expect(top.pos[1] > over.subjects[apex].position[1] && view_pitch_deg(top) < -3.0f, name + "near the apex the camera is above the skater and looks down");
        const AirTrace over_drop = run_air(above, 1, 60.0f);
        const std::size_t touch = index_at(over_drop, 10.0f / 6.0f + std::sqrt(2.0f * 3.0f / gravity_ms2) - 0.05f);
        expect(view_pitch_deg(over_drop.frames[touch]) < -3.0f && over_drop.frames[touch].pos[1] > over_drop.subjects[touch].position[1] - 0.3f,
               name + "near the landing of a 3 m drop the camera is high and looks down");
    }
}

// ---- manual / grind focus

// Height of the look target in a manual or a grind for a given focus, FullS3.
struct FocusRun {
    std::vector<Frame> frames;
    float look_y_manual = 0.0f, look_y_grind = 0.0f, board_y = 0.0f;
    float worst_look_step = 0.0f;
    std::string manual_shot, grind_shot;
};
FocusRun run_focus(float manual_focus, float grind_focus, float fps) {
    CameraSettings cs;
    cs.look.manual_focus = manual_focus;
    cs.look.grind_focus = grind_focus;
    Script script;
    script.rider.speed = 7.0f;
    script.manuals.push_back({2.0f, 6.0f});
    script.grinds.push_back({9.0f, 12.0f});
    World world;
    world.upper_y = -1000.0f;
    CameraMan cam = make_camera(cs);
    FocusRun run;
    drive_between(cam, script, world, 0.0f, 15.0f, fps, run.frames);
    run.board_y = root_height - cs.points.board_drop;
    run.look_y_manual = frame_at(run.frames, 5.5f, fps).debug.look_target[1];
    run.look_y_grind = frame_at(run.frames, 11.5f, fps).debug.look_target[1];
    run.manual_shot = std::string(frame_at(run.frames, 5.5f, fps).debug.shot_name);
    run.grind_shot = std::string(frame_at(run.frames, 11.5f, fps).debug.shot_name);
    for (std::size_t i = 1; i < run.frames.size(); ++i)
        run.worst_look_step = std::max(run.worst_look_step, std::abs(run.frames[i].debug.look_target[1] - run.frames[i - 1].debug.look_target[1]));
    return run;
}

void test_manual_grind_focus() {
    const FocusRun low = run_focus(0.0f, 0.0f, 60.0f), high = run_focus(1.0f, 1.0f, 60.0f), mid = run_focus(0.5f, 0.5f, 60.0f);
    expect(low.manual_shot.rfind("manual", 0) == 0 && low.grind_shot.rfind("grind", 0) == 0, "focus: the script reaches a manual shot and a grind shot");
    expect(close_to(low.look_y_manual, low.board_y, 0.05f), "focus: manual_focus 0 aims the look target at the board");
    expect(close_to(low.look_y_grind, low.board_y, 0.05f), "focus: grind_focus 0 aims the look target at the board in a grind");
    expect(high.look_y_manual > low.look_y_manual + 0.4f && high.look_y_grind > low.look_y_grind + 0.4f, "focus: 1 is the usual (hips / upper body) target, well above the board");
    expect(close_to(mid.look_y_manual, 0.5f * (low.look_y_manual + high.look_y_manual), 0.05f), "focus: 0.5 is halfway in a manual");
    expect(close_to(mid.look_y_grind, 0.5f * (low.look_y_grind + high.look_y_grind), 0.05f), "focus: 0.5 is halfway in a grind");
    // The off-the-board shots are unaffected by the focus settings.
    expect(close_to(frame_at(low.frames, 1.0f, 60.0f).debug.look_target[1], frame_at(high.frames, 1.0f, 60.0f).debug.look_target[1], 1e-4f) &&
               frame_at(low.frames, 1.0f, 60.0f).debug.focus_weight == 1.0f,
           "focus: the chase ignores both settings (focus weight 1)");
    // Entering and leaving ease with the shot transition: no frame moves the target by more than a few cm.
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        const FocusRun run = run_focus(0.0f, 0.0f, fps);
        const std::string tag = fps_tag("focus", fps);
        expect(run.worst_look_step < 0.1f * std::max(1.0f, 60.0f / fps), tag + "entering and leaving a manual / grind moves the look target smoothly (under 10 cm per 1/60 s)");
        expect(close_to(run.frames.back().debug.focus_weight, 1.0f, 0.02f), tag + "back in the chase the focus weight is 1 again");
        bool partial = false;
        for (const Frame& f : run.frames) partial = partial || (f.debug.focus_weight > 0.1f && f.debug.focus_weight < 0.9f);
        expect(partial, tag + "the weight passes through intermediate values (an ease, not a switch)");
    }
}

// ---- separate framing for the Low and the High angle

void test_framing_per_angle() {
    CameraSettings both;
    both.framing.distance_scale = 1.0f;
    both.framing_high.distance_scale = 1.0f;
    const FrameDebug low_ref = settled_debug(both, 6.0f, false);
    both.angle = CameraAngle::High;
    const FrameDebug high_ref = settled_debug(both, 6.0f, false);
    expect(std::abs(high_ref.distance - low_ref.distance) > 0.05f || std::abs(high_ref.elevation - low_ref.elevation) > 0.01f, "angles: High and Low are different shots");

    CameraSettings cs;
    cs.framing.distance_scale = 0.7f;      // Low
    cs.framing_high.distance_scale = 1.6f; // High
    cs.framing.height_degrees = 0.0f;
    cs.framing_high.height_degrees = 12.0f;
    cs.angle = CameraAngle::Low;
    const FrameDebug low = settled_debug(cs, 6.0f, false);
    cs.angle = CameraAngle::High;
    const FrameDebug high = settled_debug(cs, 6.0f, false);
    expect(close_to(low.distance, low_ref.distance * 0.7f, 0.03f), "angles: Low uses framing (distance_scale 0.7)");
    expect(close_to(high.distance, high_ref.distance * 1.6f, 0.03f), "angles: High uses framing_high (distance_scale 1.6)");
    expect(close_to(high.elevation - high_ref.elevation, 12.0f * degrees, 0.3f * degrees) && close_to(low.elevation, low_ref.elevation, 0.3f * degrees),
           "angles: height_degrees is per angle");
    // framing does not leak into High and framing_high not into Low.
    CameraSettings only_low;
    only_low.framing.distance_scale = 2.0f;
    only_low.angle = CameraAngle::High;
    expect(close_to(settled_debug(only_low, 6.0f, false).distance, high_ref.distance, 0.02f), "angles: framing does not change the High camera");
    CameraSettings only_high;
    only_high.framing_high.distance_scale = 2.0f;
    expect(close_to(settled_debug(only_high, 6.0f, false).distance, low_ref.distance, 0.02f), "angles: framing_high does not change the Low camera");
    // The manual close-up is per angle too.
    CameraSettings manual_cs;
    manual_cs.framing.manual_distance = 1.0f;
    manual_cs.framing_high.manual_distance = 2.5f;
    manual_cs.angle = CameraAngle::Low;
    const float manual_low = settled_debug(manual_cs, 7.0f, true).distance;
    manual_cs.angle = CameraAngle::High;
    const float manual_high = settled_debug(manual_cs, 7.0f, true).distance;
    expect(close_to(manual_low, 1.0f, 0.05f) && close_to(manual_high, 2.5f, 0.05f), "angles: manual_distance is per angle");

    // Pitch per angle, and switching the angle in the middle of a ride is smooth (distance, height and pitch ease).
    CameraSettings pitched;
    pitched.framing.pitch_degrees = 0.0f;
    pitched.framing_high.pitch_degrees = 10.0f;
    pitched.framing_high.distance_scale = 1.4f;
    pitched.framing_high.height_degrees = 8.0f;
    World world;
    world.upper_y = -1000.0f;
    Script script;
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        CameraSettings start = pitched;
        start.angle = CameraAngle::Low;
        CameraMan cam = make_camera(start);
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 3.0f, fps, frames);
        const std::size_t switch_index = frames.size();
        CameraSettings after = pitched;
        after.angle = CameraAngle::High;
        expect(cam.set_settings(after), "angles: switching the angle mid-ride is accepted");
        drive_between(cam, script, world, 3.0f, 9.0f, fps, frames);
        float worst_offset_step = 0.0f, worst_pitch_step = 0.0f;
        for (std::size_t i = switch_index; i < frames.size(); ++i) {
            const Vec3 o_now = sub(frames[i].pos, script.at(static_cast<float>(i) / fps).position);
            const Vec3 o_prev = sub(frames[i - 1].pos, script.at(static_cast<float>(i - 1) / fps).position);
            worst_offset_step = std::max(worst_offset_step, length(sub(o_now, o_prev)));
            worst_pitch_step = std::max(worst_pitch_step, std::abs(view_pitch_deg(frames[i]) - view_pitch_deg(frames[i - 1])));
        }
        const std::string tag = fps_tag("angle switch", fps);
        expect(worst_offset_step < 7.5f / fps, tag + "the camera moves at most 7.5 m/s relative to the skater");
        expect(worst_pitch_step < 30.0f / fps, tag + "and the view pitch turns at most 30 deg/s");
        // The same switch with a flat High pitch: the settled views differ by the 10 degrees asked (the rig's
        // elevation tracker is slow, so the reference makes the same switch instead of starting on High).
        CameraSettings flat_high = after;
        flat_high.framing_high.pitch_degrees = 0.0f;
        CameraMan reference = make_camera(start);
        std::vector<Frame> ref_frames;
        drive_between(reference, script, world, 0.0f, 3.0f, fps, ref_frames);
        expect(reference.set_settings(flat_high), "angles: the reference switch is accepted");
        drive_between(reference, script, world, 3.0f, 9.0f, fps, ref_frames);
        expect(close_to(view_pitch_deg(frames.back()) - view_pitch_deg(ref_frames.back()), 10.0f, 0.5f), tag + "framing_high.pitch_degrees tilts the High view by about 10 deg");
    }
}

// ================================================================ Alpha 5

// Allocation counter for the "nothing allocates" check: the global operator new counts its calls. The test reads
// the counter around the camera updates only (the vectors that script the run are filled before).
std::size_t alloc_count = 0;
// GCC -O2 inlines these into the vector code and then warns that free() meets memory from operator new (a false
// positive, the pair is ours); keeping them out of line avoids it. MSVC has no such warning.
#if defined(__GNUC__)
#define S3CAM_TEST_NOINLINE __attribute__((noinline))
#else
#define S3CAM_TEST_NOINLINE
#endif
S3CAM_TEST_NOINLINE void* operator new(std::size_t bytes) {
    ++alloc_count;
    if (void* block = std::malloc(bytes != 0 ? bytes : 1)) return block;
    throw std::bad_alloc();
}
S3CAM_TEST_NOINLINE void operator delete(void* block) noexcept { std::free(block); }
S3CAM_TEST_NOINLINE void operator delete(void* block, std::size_t) noexcept { std::free(block); }



// ---------------------------------------------------------------- task 1: landing strength from the fall

// A rider on the flat at `speed` m/s along +Z that hops (air_begin .. air_begin + air_time, a parabola peaking
// `hop_height` above the takeoff root) or steps down `drop` metres, with the board-velocity spikes the log showed
// in the last frames of an air (and optionally zero velocity at the touchdown).
struct HopRider {
    float speed = 6.0f;
    float air_begin = 1.0f;
    float hop_height = 0.114f;   // 0.3 s of air: the log's light quick nollie
    float drop = 0.0f;           // > 0: the landing is this much lower than the takeoff (fall = hop_height + drop)
    bool spikes = false;         // the last 0.08 s of the air report a wild board velocity
    bool lost_velocity = false;  // the touchdown step reports zero velocity
    // Time in the air: rise to the peak, then fall hop_height + drop.
    float rise_time() const { return std::sqrt(2.0f * hop_height / gravity_ms2); }
    float fall_time() const { return std::sqrt(2.0f * (hop_height + drop) / gravity_ms2); }
    float air_time() const { return rise_time() + fall_time(); }
    SubjectSnapshot at(float time) const {
        SubjectSnapshot s;
        s.valid = true;
        s.time = time;
        s.velocity = {0.0f, 0.0f, speed};
        s.position = {0.0f, root_height, speed * time};
        s.ground_clearance = root_height;
        const float since = time - air_begin;
        if (since >= air_time()) {
            s.position[1] = root_height - drop;
            if (lost_velocity && since < air_time() + 0.1f) s.velocity = {0.0f, 0.0f, 0.0f};
        } else if (since >= 0.0f) {
            const float vy0 = std::sqrt(2.0f * gravity_ms2 * hop_height);
            s.position[1] = root_height + vy0 * since - 0.5f * gravity_ms2 * since * since;
            s.velocity[1] = vy0 - gravity_ms2 * since;
            s.physics_state = physics_state::air;
            s.ground_clearance = s.position[1] + drop;
            if (spikes && since > air_time() - 0.08f) s.velocity = {7.0f, -14.0f, -9.0f};
        }
        return s;
    }
};

struct LandingResult {
    float impulse_share = 0.0f; // peak shake impulse / one_shot_magnitude
    float fraction = 0.0f, fall = 0.0f;
    float dip = 0.0f;           // NativePlus: deepest dip, m
};
LandingResult run_landing(const HopRider& rider, CameraPreset preset, float fps = 60.0f) {
    CameraSettings cs;
    cs.preset = preset;
    World world;
    world.upper_y = -1000.0f;
    CameraMan cam = make_camera(cs);
    LandingResult result;
    const int count = static_cast<int>(std::lround(4.0f * fps));
    for (int i = 0; i < count; ++i) {
        const SubjectSnapshot s = rider.at(static_cast<float>(i) / fps);
        const NativePose pose = air_native_pose(s);
        FrameExtras extras;
        extras.base_fov_deg = 60.0f;
        extras.native = &pose;
        const Frame& f = cam.update(1.0f / fps, s, world, extras);
        result.impulse_share = std::max(result.impulse_share, f.debug.impulse / cs.shake.one_shot_magnitude);
        result.dip = std::max(result.dip, f.debug.landing_dip);
        result.fraction = f.debug.landing_fraction;
        result.fall = f.debug.landing_fall;
    }
    return result;
}

void test_landing_from_fall() {
    for (const CameraPreset preset : {CameraPreset::FullS3, CameraPreset::NativePlus}) {
        const std::string name = preset == CameraPreset::FullS3 ? "FullS3: " : "NativePlus: ";
        // The light quick nollie: 0.3 s in the air, +0.01 m at the landing, with and without board spikes.
        for (const bool spiked : {false, true}) {
            HopRider nollie;
            nollie.spikes = spiked;
            nollie.drop = -0.01f;
            const LandingResult r = run_landing(nollie, preset);
            const std::string tag = name + (spiked ? "nollie with velocity spikes: " : "nollie: ");
            expect(close_to(r.fall, 0.114f + 0.01f, 0.03f), tag + "the fall is the ~0.1 m the root dropped");
            expect(r.impulse_share == 0.0f && r.fraction == 0.0f, tag + "no landing shake");
            expect(r.dip == 0.0f, tag + "no landing dip");
        }
        // Real drops, whatever the snapshot's velocity does at the touchdown.
        float shares[3] = {0, 0, 0};
        int slot = 0;
        for (const float drop : {1.0f, 3.0f}) {
            for (const int mode : {0, 1, 2}) {
                HopRider hop;
                hop.hop_height = 0.05f;
                hop.drop = drop;
                hop.spikes = mode == 1;
                hop.lost_velocity = mode == 2;
                const LandingResult r = run_landing(hop, preset);
                if (mode == 0) shares[slot++] = r.impulse_share;
                const std::string tag = name + std::to_string(static_cast<int>(drop)) + " m drop (" + (mode == 0 ? "clean" : mode == 1 ? "spiked" : "velocity lost") + "): ";
                expect(close_to(r.fall, drop + 0.05f, 0.05f), tag + "the fall is the height lost");
                if (drop == 1.0f) {
                    expect(r.impulse_share > 0.12f && r.impulse_share < 0.45f, tag + "a moderate landing shake");
                    if (preset == CameraPreset::NativePlus) expect(r.dip > 0.005f && r.dip < 0.5f * CameraSettings{}.native_plus.dip_depth, tag + "a moderate dip");
                } else {
                    expect(r.impulse_share > 0.9f, tag + "near the full landing shake");
                    if (preset == CameraPreset::NativePlus) expect(r.dip > 0.7f * CameraSettings{}.native_plus.dip_depth, tag + "near the full dip");
                }
            }
        }
        std::printf("  landing from the fall (%s): 1 m drop %.3f, 3 m drop %.3f of full\n", preset == CameraPreset::FullS3 ? "FullS3" : "NativePlus",
                    static_cast<double>(shares[0]), static_cast<double>(shares[1]));
    }
    // The mapping: the settings' min_fall and full_fall are the edges, the speed adds a little.
    {
        CameraSettings cs;
        cs.landing_shake.min_fall = 1.0f;
        cs.landing_shake.full_fall = 2.0f;
        cs.landing_shake.speed_weight = 0.0f;
        const auto share_for = [&cs](float drop) {
            HopRider hop;
            hop.hop_height = 0.02f;
            hop.drop = drop - 0.02f;
            hop.speed = 0.0f;
            World world;
            world.upper_y = -1000.0f;
            CameraMan cam = make_camera(cs);
            float best = 0.0f;
            for (int i = 0; i < 240; ++i) best = std::max(best, cam.update(1.0f / 60.0f, hop.at(static_cast<float>(i) / 60.0f), world).debug.landing_fraction);
            return best;
        };
        expect(share_for(0.95f) == 0.0f, "landing map: just under min_fall gives nothing");
        expect(close_to(share_for(2.05f), 1.0f, 1e-4f), "landing map: past full_fall is full");
        const float mid = (std::sqrt(2.0f * 10.1f * 1.5f) - std::sqrt(2.0f * 10.1f * 1.0f)) / (std::sqrt(2.0f * 10.1f * 2.0f) - std::sqrt(2.0f * 10.1f * 1.0f));
        expect(close_to(share_for(1.5f), mid, 0.03f), "landing map: between them the fraction follows sqrt(2 g h)");
        cs.landing_shake.speed_weight = 0.5f;
        expect(share_for(1.0f) == 0.0f, "landing map: and without forward speed the speed weight adds nothing");
    }
    // A speed term: the same fall lands a little harder at speed.
    {
        HopRider slow, fast;
        slow.hop_height = fast.hop_height = 0.05f;
        slow.drop = fast.drop = 1.0f;
        slow.speed = 1.0f;
        fast.speed = 12.0f;
        expect(run_landing(fast, CameraPreset::FullS3).fraction > run_landing(slow, CameraPreset::FullS3).fraction + 0.05f,
               "landing: the same fall lands harder at speed (speed_weight)");
    }
    // The cut flag and a mid-air cut: no landing is measured from a reset.
    {
        CameraMan cam;
        HopRider hop;
        hop.drop = 1.0f;
        World world;
        world.upper_y = -1000.0f;
        for (int i = 0; i < 20; ++i) cam.update(1.0f / 60.0f, hop.at(static_cast<float>(i) / 60.0f), world);
        cam.request_reset();
        float worst = 0.0f;
        for (int i = 20; i < 40; ++i) worst = std::max(worst, cam.update(1.0f / 60.0f, hop.at(static_cast<float>(i) / 60.0f), world).debug.impulse);
        expect(worst == 0.0f, "landing: a cut does not shake");
    }
    // Nothing allocates, the landing included.
    {
        HopRider hop;
        hop.hop_height = 0.5f;
        hop.drop = 2.0f;
        CameraMan cam;
        World world;
        world.upper_y = -1000.0f;
        std::vector<SubjectSnapshot> script;
        for (int i = 0; i < 240; ++i) script.push_back(hop.at(static_cast<float>(i) / 60.0f));
        const std::size_t before = alloc_count;
        float peak_impulse = 0.0f;
        for (const SubjectSnapshot& s : script) peak_impulse = std::max(peak_impulse, cam.update(1.0f / 60.0f, s, world).debug.impulse);
        expect(alloc_count == before, "landing: the camera update allocates nothing, landings included");
        expect(peak_impulse > 0.5f, "landing: (and the allocation run did land hard)");
    }
}

// ---------------------------------------------------------------- task 2: horizontal follow

// A rider that rides straight, turns at a constant rate between `turn_begin` and `turn_end`, then rides straight again.
struct Turner {
    float speed = 6.0f, turn_dps = 25.0f, turn_begin = 1.0f, turn_end = 6.0f;
    float heading_at(float time) const { return turn_dps * degrees * std::clamp(time - turn_begin, 0.0f, turn_end - turn_begin); }
    Vec3 dir_of(float theta) const { return {-std::sin(theta), 0.0f, std::cos(theta)}; }
    SubjectSnapshot at(float time) const {
        SubjectSnapshot s;
        s.valid = true;
        s.time = time;
        const float omega = std::max(turn_dps * degrees, 1e-4f);
        const float theta = heading_at(time);
        float x = 0.0f, z = speed * std::min(time, turn_begin);
        if (time > turn_begin) { // the arc
            x += speed / omega * (std::cos(theta) - 1.0f);
            z += speed / omega * std::sin(theta);
        }
        if (time > turn_end) { // straight again along the final heading
            const Vec3 d = dir_of(theta);
            x += d[0] * speed * (time - turn_end);
            z += d[2] * speed * (time - turn_end);
        }
        s.position = {x, root_height, z};
        s.forward = dir_of(theta);
        s.velocity = scale(s.forward, speed);
        s.ground_clearance = root_height;
        return s;
    }
};
// Degrees between the camera's horizontal offset from the rider and straight behind the direction of travel.
float behind_error_deg(const Frame& f, const SubjectSnapshot& s) {
    const Vec3 offset = normalized({f.pos[0] - s.position[0], 0.0f, f.pos[2] - s.position[2]}, {0, 0, -1});
    const Vec3 behind = scale(normalized({s.velocity[0], 0.0f, s.velocity[2]}, {0, 0, 1}), -1.0f);
    return std::acos(std::clamp(dot(offset, behind), -1.0f, 1.0f)) / degrees;
}

void test_horizontal_follow() {
    World world;
    world.upper_y = -1000.0f;
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        const std::string tag = fps_tag("horizontal follow", fps);
        Turner turner;
        CameraSettings tied;
        tied.follow.horizontal = 10.0f;
        CameraMan cam10 = make_camera(tied);
        CameraMan cam0 = make_camera(CameraSettings{});
        std::vector<Frame> f10, f0;
        drive_between(cam10, turner, world, 0.0f, 9.0f, fps, f10);
        drive_between(cam0, turner, world, 0.0f, 9.0f, fps, f0);
        float worst10 = 0.0f, worst0 = 0.0f, worst_step = 0.0f, worst_yaw_step = 0.0f;
        for (std::size_t i = 0; i < f10.size(); ++i) {
            const float t = static_cast<float>(i) / fps;
            if (t < 2.0f) continue;
            const SubjectSnapshot s = turner.at(t);
            worst10 = std::max(worst10, behind_error_deg(f10[i], s));
            worst0 = std::max(worst0, behind_error_deg(f0[i], s));
            const Vec3 o_now = sub(f10[i].pos, s.position), o_prev = sub(f10[i - 1].pos, turner.at(static_cast<float>(i - 1) / fps).position);
            worst_step = std::max(worst_step, length(sub(o_now, o_prev)));
            worst_yaw_step = std::max(worst_yaw_step, std::abs(wrap_angle((view_yaw_deg(f10[i]) - view_yaw_deg(f10[i - 1])) * degrees)) / degrees);
        }
        std::printf("  %sworst angle off straight-behind while turning: 10 -> %.2f deg, 0 -> %.2f deg; camera step %.3f m, yaw step %.2f deg\n", tag.c_str(),
                    static_cast<double>(worst10), static_cast<double>(worst0), static_cast<double>(worst_step), static_cast<double>(worst_yaw_step));
        expect(worst10 < 6.0f, tag + "at 10 a turning rider keeps the camera within 6 degrees of straight behind");
        expect(worst0 > 2.0f * worst10 && worst0 > 12.0f, tag + "at 0 the camera swings lazily behind (well off straight behind in the same turn)");
        expect(worst_step < 8.0f / fps, tag + "no snaps: the camera moves at most 8 m/s relative to the rider");
        expect(worst_yaw_step < 80.0f / fps, tag + "and the view yaw turns at most 80 deg/s");
        expect(f10.back().debug.follow_weight > 0.98f && f0.back().debug.follow_weight == 0.0f, tag + "the follow weight is 1 at 10 and exactly 0 at 0");
    }
    // At 0 the camera is what it was: a run with the setting never touched equals one with 0 set explicitly (and
    // the rig heading passes through untouched; the weight is exactly 0).
    {
        Turner turner;
        CameraSettings explicit_zero;
        explicit_zero.follow.horizontal = 0.0f;
        CameraMan a = make_camera(explicit_zero), b = make_camera(CameraSettings{});
        std::vector<Frame> fa, fb;
        drive_between(a, turner, world, 0.0f, 9.0f, 60.0f, fa);
        drive_between(b, turner, world, 0.0f, 9.0f, 60.0f, fb);
        bool same = true;
        for (std::size_t i = 0; i < fa.size(); ++i) same = same && fa[i].pos == fb[i].pos && fa[i].back == fb[i].back;
        expect(same, "horizontal follow: 0 is the default behaviour (identical frames)");
    }
    // Values in between pull partway, and the setting moves smoothly when it changes mid-ride.
    {
        Turner turner;
        float previous_error = 1.0e9f;
        for (const float level : {0.0f, 3.0f, 6.0f, 10.0f}) {
            CameraSettings cs;
            cs.follow.horizontal = level;
            CameraMan cam = make_camera(cs);
            std::vector<Frame> frames;
            drive_between(cam, turner, world, 0.0f, 6.0f, 60.0f, frames);
            float err = 0.0f;
            for (std::size_t i = 150; i < frames.size(); ++i) err = std::max(err, behind_error_deg(frames[i], turner.at(static_cast<float>(i) / 60.0f)));
            expect(err < previous_error, "horizontal follow: a higher setting keeps the camera closer to straight behind");
            previous_error = err;
        }
        for (const float fps : {30.0f, 60.0f, 144.0f}) {
            CameraSettings before;
            CameraMan cam = make_camera(before);
            std::vector<Frame> frames;
            drive_between(cam, turner, world, 0.0f, 3.0f, fps, frames);
            CameraSettings after = before;
            after.follow.horizontal = 10.0f;
            expect(cam.set_settings(after), "horizontal follow: settings accepted mid-ride");
            drive_between(cam, turner, world, 3.0f, 8.0f, fps, frames);
            float worst_step = 0.0f;
            for (std::size_t i = 1; i < frames.size(); ++i)
                worst_step = std::max(worst_step, length(sub(sub(frames[i].pos, turner.at(static_cast<float>(i) / fps).position),
                                                           sub(frames[i - 1].pos, turner.at(static_cast<float>(i - 1) / fps).position))));
            expect(worst_step < 8.0f / fps, fps_tag("horizontal follow", fps) + "switching 0 -> 10 mid-turn does not snap the camera");
            expect(behind_error_deg(frames.back(), turner.at(7.99f)) < 6.0f, fps_tag("horizontal follow", fps) + "and it ends straight behind");
        }
    }
    // Slower than ~1 m/s the travel heading holds (Beta feedback: fading the follow out there handed the camera to the
    // lazy heading and fading it back in yanked it behind): the weight stays, the camera does not chase the direction.
    {
        Turner crawl;
        crawl.speed = 0.4f;
        CameraSettings cs;
        cs.follow.horizontal = 10.0f;
        CameraMan cam = make_camera(cs);
        std::vector<Frame> frames;
        drive_between(cam, crawl, world, 0.0f, 6.0f, 60.0f, frames);
        const float turned = std::abs(wrap_angle((view_yaw_deg(frames.back()) - view_yaw_deg(frames[60])) * degrees)) / degrees;
        expect(frames.back().debug.follow_weight > 0.98f && turned < 15.0f,
               "horizontal follow: at 0.4 m/s the weight stays and the heading holds (no chasing a crawl)");
    }
    // A slow 180 at 10: ride at 3 m/s, slow to 0.3 m/s, turn round in 1 s, ride back. The camera holds through the turn
    // and then swings round behind the new direction at its capped rate, never snapping.
    {
        struct SlowTurn {
            SubjectSnapshot at(float t) const {
                SubjectSnapshot s;
                s.valid = true;
                s.time = t;
                s.ground_clearance = root_height;
                float speed = 3.0f, theta = 0.0f, z = 0.0f, x = 0.0f;
                if (t < 2.0f) z = 3.0f * t;
                else if (t < 3.0f) { speed = 3.0f - 2.7f * (t - 2.0f); z = 6.0f + 3.0f * (t - 2.0f) - 1.35f * (t - 2.0f) * (t - 2.0f); }
                else if (t < 4.0f) { speed = 0.3f; theta = pi * (t - 3.0f); z = 7.65f; x = 0.0f; }
                else { theta = pi; speed = std::min(3.0f, 0.3f + 2.7f * (t - 4.0f)); z = 7.65f - 3.0f * (t - 4.0f); }
                const Vec3 dir{-std::sin(theta), 0.0f, std::cos(theta)};
                s.position = {x, root_height, z};
                s.forward = dir;
                s.velocity = scale(dir, speed);
                return s;
            }
        } slow_turn;
        CameraSettings cs;
        cs.follow.horizontal = 10.0f;
        CameraMan cam = make_camera(cs);
        std::vector<Frame> frames;
        drive_between(cam, slow_turn, world, 0.0f, 8.0f, 60.0f, frames);
        float worst_rate = 0.0f;
        for (std::size_t i = 1; i < frames.size(); ++i)
            worst_rate = std::max(worst_rate, std::abs(wrap_angle((view_yaw_deg(frames[i]) - view_yaw_deg(frames[i - 1])) * degrees)) / degrees * 60.0f);
        const float held = std::abs(wrap_angle((view_yaw_deg(frames[235]) - view_yaw_deg(frames[180])) * degrees)) / degrees;
        std::printf("  horizontal follow (slow 180 at 10): turned %.1f deg during the turn, fastest %.0f deg/s, %.1f deg off behind at the end\n",
                    held, worst_rate, behind_error_deg(frames.back(), slow_turn.at(7.99f)));
        expect(held < 20.0f, "horizontal follow: a slow 180 at 10 does not swing the camera while turning");
        expect(worst_rate < 280.0f, "horizontal follow: and it never snaps (turn rate capped)");
        expect(behind_error_deg(frames.back(), slow_turn.at(7.99f)) < 10.0f, "horizontal follow: riding away it ends behind the new direction");
    }
    // At 10 a revert on the flat (the skater spins, the direction of travel does not change) does not turn the camera.
    {
        struct Revert {
            SubjectSnapshot at(float t) const {
                SubjectSnapshot s;
                s.valid = true;
                s.time = t;
                s.ground_clearance = root_height;
                const float spin = pi * std::clamp((t - 3.0f) / 0.5f, 0.0f, 1.0f);
                s.position = {0.0f, root_height, 5.0f * t};
                s.velocity = {0.0f, 0.0f, 5.0f};
                s.forward = {-std::sin(spin), 0.0f, std::cos(spin)};
                return s;
            }
        } revert;
        CameraSettings cs;
        cs.follow.horizontal = 10.0f;
        CameraMan cam = make_camera(cs);
        std::vector<Frame> frames;
        drive_between(cam, revert, world, 0.0f, 6.0f, 60.0f, frames);
        float worst = 0.0f;
        for (std::size_t i = 170; i < frames.size(); ++i) worst = std::max(worst, behind_error_deg(frames[i], revert.at(static_cast<float>(i) / 60.0f)));
        expect(worst < 5.0f, "horizontal follow: at 10 a revert on the flat leaves the camera locked behind the direction of travel");
    }
    // Trick yaw goes on top: in a long air on a straight line the camera sits the trick-yaw angle off straight behind.
    {
        Script script;
        script.rider.speed = 6.0f;
        script.airs.push_back({2.0f, 5.0f});
        CameraSettings cs;
        cs.follow.horizontal = 10.0f;
        cs.trick_yaw.enabled = true;
        cs.trick_yaw.angle_degrees = 25.0f;
        cs.trick_yaw.side = 1;
        CameraMan cam = make_camera(cs);
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 4.5f, 60.0f, frames);
        const Frame& held = frame_at(frames, 4.4f, 60.0f);
        const float error = behind_error_deg(held, script.at(4.4f));
        expect(close_to(held.debug.trick_yaw / degrees, 25.0f, 1.0f), "horizontal follow + trick yaw: the swing reached its angle");
        expect(close_to(error, 25.0f, 4.0f), "horizontal follow + trick yaw: the camera sits the trick-yaw angle off straight behind");
        const Frame& rest = frame_at(frames, 1.9f, 60.0f);
        expect(behind_error_deg(rest, script.at(1.9f)) < 4.0f, "horizontal follow + trick yaw: straight behind before the trick");
    }
}

// ---------------------------------------------------------------- task 3: leaving a manual / grind close-up

struct ExitRun {
    std::vector<Frame> frames;
    float fps = 60.0f, exit_time = 5.0f;
};
// A rider at 7 m/s in a manual (kind 0) or a grind (kind 1) from 2 s to 5 s that then ollies out.
ExitRun run_exit(const CameraSettings& cs, int kind, float fps) {
    Script script;
    script.rider.speed = 7.0f;
    script.rider.has_ollie = true;
    script.rider.ollie_time = 5.0f;
    (kind == 0 ? script.manuals : script.grinds).push_back({2.0f, 5.0f});
    World world;
    world.upper_y = -1000.0f;
    CameraMan cam = make_camera(cs);
    ExitRun run;
    run.fps = fps;
    drive_between(cam, script, world, 0.0f, 9.0f, fps, run.frames);
    return run;
}

void test_exit_closeup_is_smooth() {
    for (const int kind : {0, 1}) {
        for (const float fps : {30.0f, 60.0f, 144.0f}) {
            CameraSettings cs;
            // A pronounced close-up so that the distance change leaving it is clearly bigger than 1 m.
            cs.framing.manual_distance = 1.2f;
            cs.framing.grind_distance = 1.2f;
            const ExitRun run = run_exit(cs, kind, fps);
            const std::string tag = fps_tag(kind == 0 ? "manual exit" : "grind exit", fps);
            const float before = frame_at(run.frames, 4.9f, fps).debug.distance;
            // The distance the exit settles at: where the camera is 3 s after the ollie (back in the chase / landing).
            const float settled = frame_at(run.frames, 8.5f, fps).debug.distance;
            expect(std::abs(settled - before) > 0.8f, tag + "the script changes the distance by more than 0.8 m");
            // 10% to 90% of the way from `before` to `settled`, searched in the first 2 s after the exit.
            float t10 = -1.0f, t90 = -1.0f, worst_step = 0.0f;
            for (std::size_t i = static_cast<std::size_t>(std::lround(4.9f * fps)); i < static_cast<std::size_t>(std::lround(7.0f * fps)); ++i) {
                const float d = run.frames[i].debug.distance;
                const float t = static_cast<float>(i) / fps;
                const float progress = (d - before) / (settled - before);
                if (t10 < 0.0f && progress >= 0.1f) t10 = t;
                if (t90 < 0.0f && progress >= 0.9f) t90 = t;
                worst_step = std::max(worst_step, std::abs(d - run.frames[i - 1].debug.distance));
            }
            std::printf("  %s%s: distance %.2f -> %.2f m, 10%% at +%.2f s, 90%% at +%.2f s (%.2f s between), worst step %.3f m\n", tag.c_str(),
                        kind == 0 ? "manual" : "grind", static_cast<double>(before), static_cast<double>(settled), static_cast<double>(t10 - 5.0f),
                        static_cast<double>(t90 - 5.0f), static_cast<double>(t90 - t10), static_cast<double>(worst_step));
            expect(t10 >= 0.0f && t90 >= 0.0f, tag + "the distance gets there");
            expect(t10 - 5.0f >= 0.2f, tag + "and it starts gently: not 10% of the way in the first 0.2 s after the ollie");
            expect(t90 - t10 >= 0.6f, tag + "the distance change takes at least 0.6 s from 10% to 90%");
            expect(worst_step < 0.05f * std::max(1.0f, 60.0f / fps), tag + "no frame moves the distance by more than 5 cm (per 1/60 s)");
            // The camera itself: no frame step of the camera relative to the rider above a small bound.
            Script script;
            script.rider.speed = 7.0f;
            script.rider.has_ollie = true;
            script.rider.ollie_time = 5.0f;
            float worst_camera = 0.0f;
            for (std::size_t i = static_cast<std::size_t>(std::lround(4.5f * fps)); i < static_cast<std::size_t>(std::lround(7.0f * fps)); ++i) {
                const Vec3 o_now = sub(run.frames[i].pos, script.at(static_cast<float>(i) / fps).position);
                const Vec3 o_prev = sub(run.frames[i - 1].pos, script.at(static_cast<float>(i - 1) / fps).position);
                worst_camera = std::max(worst_camera, length(sub(o_now, o_prev)));
            }
            expect(worst_camera < 8.0f / fps, tag + "the camera moves at most 8 m/s relative to the rider through the exit");
        }
    }
    // The transition itself is at least 0.9 s when leaving a close-up and unchanged for other shots.
    {
        CameraSettings cs;
        const ExitRun run = run_exit(cs, 0, 60.0f);
        bool long_transition = false;
        float first_air = -1.0f, done = -1.0f;
        for (std::size_t i = 290; i < run.frames.size(); ++i) {
            const float t = static_cast<float>(i) / 60.0f;
            if (first_air < 0.0f && std::string(run.frames[i].debug.shot_name).rfind("air", 0) == 0) first_air = t;
            if (first_air >= 0.0f && done < 0.0f && run.frames[i].debug.exit_blend >= 1.0f) done = t;
        }
        long_transition = first_air > 0.0f && done - first_air >= 0.85f;
        expect(long_transition, "exit: the distance ease after leaving the manual runs at least 0.9 s");
    }
}

// ---------------------------------------------------------------- task 4: manual / grind floor, grind settings

void test_manual_grind_floor() {
    for (const int kind : {0, 1}) {
        for (const float fps : {30.0f, 60.0f, 144.0f}) {
            CameraSettings cs;
            // A low camera that would sit below the board: a steep negative height on the close-up shots.
            cs.framing.manual_height_degrees = -30.0f;
            cs.framing.grind_height_degrees = -30.0f;
            cs.framing.height_degrees = -20.0f;
            cs.framing.manual_distance = 2.4f;
            cs.framing.grind_distance = 2.1f;
            Script script;
            script.rider.speed = 7.0f;
            (kind == 0 ? script.manuals : script.grinds).push_back({2.0f, 7.0f});
            World world;
            world.upper_y = -1000.0f;
            CameraMan cam = make_camera(cs);
            std::vector<Frame> frames;
            drive_between(cam, script, world, 0.0f, 9.0f, fps, frames);
            const std::string tag = fps_tag(kind == 0 ? "manual floor" : "grind floor", fps);
            const float board_y = root_height - cs.points.board_drop;
            float lowest = 1.0e9f, highest_pitch = -1.0e9f, worst_y_step = 0.0f, worst_pitch_step = 0.0f;
            for (std::size_t i = 1; i < frames.size(); ++i) {
                const float t = static_cast<float>(i) / fps;
                worst_y_step = std::max(worst_y_step, std::abs(frames[i].pos[1] - frames[i - 1].pos[1]));
                worst_pitch_step = std::max(worst_pitch_step, std::abs(view_pitch_deg(frames[i]) - view_pitch_deg(frames[i - 1])));
                if (t < 3.5f || t > 7.0f) continue; // settled in the close-up
                lowest = std::min(lowest, frames[i].pos[1] - board_y);
                highest_pitch = std::max(highest_pitch, view_pitch_deg(frames[i]));
            }
            std::printf("  %slowest camera above the board %.3f m, highest view pitch %.2f deg, worst y step %.3f m, worst pitch step %.2f deg\n", tag.c_str(),
                        static_cast<double>(lowest), static_cast<double>(highest_pitch), static_cast<double>(worst_y_step), static_cast<double>(worst_pitch_step));
            expect(lowest >= 0.3f - 0.005f, tag + "the camera stays at least 0.3 m above the board");
            expect(highest_pitch <= 0.5f, tag + "the view does not look up (pitch at most 0.5 deg)");
            expect(frame_at(frames, 6.0f, fps).debug.floor_weight > 0.95f, tag + "the floor is fully on in the close-up");
            expect(frame_at(frames, 8.9f, fps).debug.floor_weight < 0.05f, tag + "and off again afterwards");
            expect(worst_y_step < 4.0f / fps, tag + "no frame lifts the camera by more than 4 m/s (the floor eases)");
            expect(worst_pitch_step < 40.0f / fps, tag + "the view pitch turns at most 40 deg/s");
            // Eased in: right after the shot starts the weight is far from 1.
            expect(frame_at(frames, 2.05f, fps).debug.floor_weight < 0.3f, tag + "the floor weight eases in (not a jump)");
        }
    }
    // Without the floor's reason (a chase) nothing changes: weight 0 on the flat.
    {
        Script script;
        World world;
        world.upper_y = -1000.0f;
        CameraMan cam;
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 3.0f, 60.0f, frames);
        expect(frames.back().debug.floor_weight == 0.0f, "floor: the chase has no floor weight");
    }
}

FrameDebug grind_debug(const CameraSettings& cs) {
    Script script;
    script.rider.speed = 7.0f;
    script.grinds.push_back({0.0f, 100.0f});
    World world;
    world.upper_y = -1000.0f;
    CameraMan cam = make_camera(cs);
    std::vector<Frame> frames;
    drive_between(cam, script, world, 0.0f, 5.0f, 60.0f, frames);
    return frames.back().debug;
}

void test_grind_framing_settings() {
    // Beta feedback: the grind close-up has its own distance (metres), height and pitch; the main framing does not add to it.
    const FrameDebug base = grind_debug(CameraSettings{});
    expect(std::string(base.shot_name) == "grind_flat", "grind framing: the script is a flat grind");
    expect(close_to(base.distance, CameraSettings{}.framing.grind_distance, 0.04f), "grind framing: the distance is grind_distance");
    for (const float metres : {0.7f, 1.6f, 3.0f}) {
        CameraSettings cs;
        cs.framing.grind_distance = metres;
        expect(close_to(grind_debug(cs).distance, metres, 0.04f), "grind framing: the distance follows grind_distance, below the main minimum too");
    }
    CameraSettings tall;
    tall.framing.grind_height_degrees = 15.0f;
    expect(close_to(grind_debug(tall).elevation - base.elevation, 15.0f * degrees, 0.4f * degrees), "grind framing: grind_height_degrees raises the grind camera");
    CameraSettings both;
    both.framing.grind_height_degrees = 10.0f;
    both.framing.height_degrees = 4.0f;
    both.framing.distance_scale = 1.25f;
    const FrameDebug b = grind_debug(both);
    expect(close_to(b.elevation - base.elevation, 10.0f * degrees, 0.4f * degrees), "grind framing: the main height does not add to it");
    expect(close_to(b.distance, base.distance, 0.04f), "grind framing: the main distance scale does not change it");
    // Off: the grind shots keep their own table distance and elevation, with the main framing.
    CameraSettings off;
    off.framing.grind_camera = false;
    off.framing.grind_distance = 4.0f;
    off.framing.grind_height_degrees = 20.0f;
    const FrameDebug o = grind_debug(off);
    expect(std::abs(o.distance - 4.0f) > 1.0f && std::abs(o.elevation - (base.elevation + 20.0f * degrees)) > 5.0f * degrees,
           "grind framing: grind_camera off ignores the grind values");
    // The chase is not touched by the grind settings.
    CameraSettings wide;
    wide.framing.grind_distance = 3.0f;
    expect(close_to(settled_debug(CameraSettings{}, 7.0f, false).distance, settled_debug(wide, 7.0f, false).distance, 1e-3f),
           "grind framing: the chase ignores the grind settings");
    // Per angle: Low uses framing, High uses framing_high.
    CameraSettings angles;
    angles.framing.grind_distance = 1.0f;
    angles.framing_high.grind_distance = 2.8f;
    angles.angle = CameraAngle::Low;
    const FrameDebug low = grind_debug(angles);
    angles.angle = CameraAngle::High;
    const FrameDebug high = grind_debug(angles);
    expect(close_to(low.distance, 1.0f, 0.04f), "grind framing: Low uses framing.grind_distance");
    expect(close_to(high.distance, 2.8f, 0.04f), "grind framing: High uses framing_high.grind_distance");
    // valid() range checks.
    CameraSettings bad;
    bad.framing.grind_distance = 0.1f;
    CameraMan cam;
    expect(!cam.set_settings(bad), "grind framing: a grind_distance below the close-up floor is rejected");
    bad = CameraSettings{};
    bad.framing_high.grind_height_degrees = 90.0f;
    expect(!cam.set_settings(bad), "grind framing: an out-of-range grind_height_degrees is rejected");
}

// ---------------------------------------------------------------- task 5: framing changes show at once

// ---------------------------------------------------------------- Alpha 6: board anchoring, distance limits

// A Script whose snapshots carry the board body's position: the estimate (root - 0.9 m) plus an offset.
struct BoardSource {
    Script script;
    Vec3 board_offset{0, 0, 0};
    bool carries_board = true;
    SubjectSnapshot at(float time) const {
        SubjectSnapshot snap = script.at(time);
        if (carries_board) {
            snap.board_position = add(snap.position, add({0.0f, -0.9f, 0.0f}, board_offset));
            snap.board_valid = true;
        }
        return snap;
    }
    Vec3 board_at(float time) const { return add(add(script.at(time).position, {0.0f, -0.9f, 0.0f}), board_offset); }
};

BoardSource manual_source(float speed, const Vec3& board_offset) {
    BoardSource src;
    src.script.rider.speed = speed;
    src.script.manuals.push_back({0.0f, 100.0f});
    src.board_offset = board_offset;
    return src;
}
BoardSource grind_source(float speed, const Vec3& board_offset) {
    BoardSource src;
    src.script.rider.speed = speed;
    src.script.grinds.push_back({0.0f, 100.0f});
    src.board_offset = board_offset;
    return src;
}
std::vector<Frame> run_board(const CameraSettings& cs, const BoardSource& src, float seconds, float fps = 60.0f) {
    World ground_world;
    ground_world.upper_y = -1000.0f;
    CameraMan cam_man = make_camera(cs);
    std::vector<Frame> out_frames;
    drive_between(cam_man, src, ground_world, 0.0f, seconds, fps, out_frames);
    return out_frames;
}
// Degrees the point sits above (+) the view axis, as the camera sees it.
float board_screen_pitch_deg(const Frame& f, const Vec3& point) {
    const Vec3 line = normalized(sub(point, f.pos));
    return std::asin(std::clamp(dot(line, f.up), -1.0f, 1.0f)) / degrees;
}

void test_board_anchor_follows_board() {
    for (const bool grind : {false, true}) {
        const char* tag = grind ? "board anchor (grind): " : "board anchor (manual): ";
        const Vec3 away{0.4f, 0.6f, 0.0f}; // the board body sits well off the estimate
        const BoardSource src = grind ? grind_source(3.0f, away) : manual_source(3.0f, away);
        CameraSettings on;
        on.look.manual_focus = on.look.grind_focus = 0.0f; // aim at the board itself
        on.shake_enabled = false;
        CameraSettings off = on;
        off.look.board_anchor = false;
        const std::vector<Frame> with_anchor = run_board(on, src, 5.0f);
        const std::vector<Frame> without = run_board(off, src, 5.0f);
        const Frame& fa = with_anchor.back();
        const Frame& fo = without.back();
        const Vec3 board = src.board_at(4.99f);
        expect(fa.debug.board_weight > 0.99f && fo.debug.board_weight == 0.0f, std::string(tag) + "the weight is 1 on, 0 off");
        expect(close_to(fa.debug.look_target[0], board[0], 0.03f) && close_to(fa.debug.look_target[1], board[1], 0.05f),
               std::string(tag) + "the look target follows the real board (focus 0)");
        expect(!close_to(fo.debug.look_target[1], board[1], 0.3f), std::string(tag) + "board_anchor off keeps aiming at the estimate");
        // The orbit anchor: board + 0.3 m in height, and the board's side offset (the rig has no sideways lag).
        expect(close_to(fa.debug.orbit_anchor[0], board[0], 0.03f) && close_to(fa.debug.orbit_anchor[1], board[1] + 0.3f, 0.05f),
               std::string(tag) + "the camera orbits the board plus ~0.3 m");
        expect(close_to(fo.debug.orbit_anchor[0], 0.0f, 0.03f), std::string(tag) + "board_anchor off orbits the root-based anchor");
        // The 0.3 m floor is measured from the real board.
        float lowest = 1.0e9f;
        for (std::size_t i = 240; i < with_anchor.size(); ++i) lowest = std::min(lowest, with_anchor[i].pos[1] - src.board_at(static_cast<float>(i) / 60.0f)[1]);
        expect(lowest > 0.3f - 0.02f, std::string(tag) + "the camera stays 0.3 m above the real board");
        // No board_valid: the estimate is used, anchoring changes nothing.
        BoardSource no_board = src;
        no_board.carries_board = false;
        const std::vector<Frame> estimate_run = run_board(on, no_board, 5.0f);
        expect(close_to(estimate_run.back().debug.look_target[1], root_height - on.points.board_drop, 0.05f),
               std::string(tag) + "without board_valid the estimate is the board point");
    }
}

void test_board_anchor_smooth_and_off_unchanged() {
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        BoardSource src;
        src.script.rider.speed = 3.0f;
        src.script.manuals.push_back({2.0f, 4.0f});
        src.board_offset = {0.5f, 0.4f, 0.0f};
        CameraSettings on;
        on.shake_enabled = false;
        on.look.manual_focus = 0.0f;
        const std::vector<Frame> frames_on = run_board(on, src, 7.0f, fps);
        float worst_anchor = 0.0f, worst_camera = 0.0f, worst_look = 0.0f;
        bool saw_partial = false;
        float peak_weight = 0.0f;
        for (std::size_t i = 1; i < frames_on.size(); ++i) {
            // x and y only: z is the ride itself.
            const auto side_step = [&](const Vec3& a_pos, const Vec3& b_pos) { return std::max(std::abs(a_pos[0] - b_pos[0]), std::abs(a_pos[1] - b_pos[1])); };
            worst_anchor = std::max(worst_anchor, side_step(frames_on[i].debug.orbit_anchor, frames_on[i - 1].debug.orbit_anchor));
            worst_camera = std::max(worst_camera, side_step(frames_on[i].pos, frames_on[i - 1].pos));
            worst_look = std::max(worst_look, side_step(frames_on[i].debug.look_target, frames_on[i - 1].debug.look_target));
            const float w = frames_on[i].debug.board_weight;
            saw_partial = saw_partial || (w > 0.1f && w < 0.9f);
            peak_weight = std::max(peak_weight, w);
        }
        const float budget = 0.05f * std::max(1.0f, 60.0f / fps);
        const std::string tag = fps_tag("board anchor", fps);
        expect(worst_anchor < budget && worst_camera < budget && worst_look < budget,
               tag + "entering and leaving moves the anchor, camera and look target by under 5 cm per 1/60 s");
        if (!(worst_anchor < budget && worst_camera < budget && worst_look < budget))
            std::printf("  anchor %.3f camera %.3f look %.3f (budget %.3f)\n", static_cast<double>(worst_anchor), static_cast<double>(worst_camera),
                        static_cast<double>(worst_look), static_cast<double>(budget));
        expect(saw_partial && peak_weight > 0.99f && frames_on.back().debug.board_weight < 0.02f,
               tag + "the weight eases up to 1 and back to 0 (no snap)");
    }
    // board_anchor off: the board position is ignored, whatever the snapshot says (same frames as a snapshot without it).
    BoardSource with_board;
    with_board.script.rider.speed = 7.0f;
    with_board.script.manuals.push_back({1.0f, 3.0f});
    with_board.script.grinds.push_back({4.0f, 5.5f});
    with_board.board_offset = {0.5f, 0.5f, 0.2f};
    BoardSource without_board = with_board;
    without_board.carries_board = false;
    CameraSettings off;
    off.look.board_anchor = false;
    const std::vector<Frame> fa = run_board(off, with_board, 7.0f), fb = run_board(off, without_board, 7.0f);
    float worst_diff = 0.0f;
    for (std::size_t i = 0; i < fa.size(); ++i) worst_diff = std::max(worst_diff, length(sub(fa[i].pos, fb[i].pos)));
    expect(worst_diff < 1e-5f && fa.back().debug.board_weight == 0.0f, "board anchor off: the frames ignore board_position (as before)");
    // And outside manuals / grinds the real board changes nothing even with anchoring on.
    CameraSettings on;
    const std::vector<Frame> ga = run_board(on, with_board, 0.9f), gb = run_board(on, without_board, 0.9f);
    float worst_chase = 0.0f;
    for (std::size_t i = 0; i < ga.size(); ++i) worst_chase = std::max(worst_chase, length(sub(ga[i].pos, gb[i].pos)));
    expect(worst_chase < 1e-5f, "board anchor on: the chase shot is unchanged");
}

void test_board_anchor_pitch_steady() {
    for (const bool grind : {false, true}) {
        const char* tag = grind ? "board pitch (grind): " : "board pitch (manual): ";
        const BoardSource src = grind ? grind_source(3.0f, {0.0f, 0.3f, 0.0f}) : manual_source(3.0f, {0.0f, 0.3f, 0.0f});
        const auto screen_pitch = [&](bool anchored, float pitch_deg) {
            CameraSettings cs;
            cs.shake_enabled = false;
            cs.look.manual_focus = cs.look.grind_focus = 0.0f;
            cs.look.board_anchor = anchored;
            cs.framing.manual_pitch_degrees = cs.framing.grind_pitch_degrees = pitch_deg; // the close-ups have their own pitch
            const std::vector<Frame> got = run_board(cs, src, 6.0f);
            return board_screen_pitch_deg(got.back(), src.board_at(5.99f));
        };
        const float a0 = screen_pitch(true, 0.0f), a_up = screen_pitch(true, 10.0f), a_down = screen_pitch(true, -10.0f);
        const float b0 = screen_pitch(false, 0.0f), b_up = screen_pitch(false, 10.0f);
        std::printf("  %sboard on screen (deg above the axis): anchored 0 -> %.2f, +10 -> %.2f, -10 -> %.2f; not anchored 0 -> %.2f, +10 -> %.2f\n", tag,
                    static_cast<double>(a0), static_cast<double>(a_up), static_cast<double>(a_down), static_cast<double>(b0), static_cast<double>(b_up));
        expect(std::abs(a_up - a0) < 1.0f && std::abs(a_down - a0) < 1.0f, std::string(tag) + "with anchoring the pitch setting keeps the board in the same place on screen");
        expect(std::abs(b_up - b0) > 5.0f, std::string(tag) + "without it the pitch moves the board on screen (as before)");
    }
}

// Distance from the orbit anchor to the published camera over the frames from `first` on.
void distance_range(const std::vector<Frame>& got, std::size_t first, float& lowest, float& highest) {
    lowest = 1.0e9f;
    highest = 0.0f;
    for (std::size_t i = first; i < got.size(); ++i) {
        const float span = length(sub(got[i].pos, got[i].debug.orbit_anchor));
        lowest = std::min(lowest, span);
        highest = std::max(highest, span);
    }
}

void test_distance_limits() {
    // Beta feedback: the close-ups have their own distance, not held by the main camera's minimum (1.2 m): a 0.6 m
    // manual or grind close-up rests at 0.6 m, and nothing comes nearer than the close-up floor (0.5 m).
    for (const bool grind : {false, true}) {
        const char* tag = grind ? "distance (grind close-up): " : "distance (manual close-up): ";
        BoardSource src = grind ? grind_source(3.0f, {0.0f, 0.0f, 0.0f}) : manual_source(3.0f, {0.0f, 0.0f, 0.0f});
        CameraSettings cs;
        cs.shake_enabled = false;
        cs.framing.manual_distance = 0.6f;
        cs.framing.grind_distance = 0.6f;
        for (const bool anchored : {true, false}) {
            cs.look.board_anchor = anchored;
            const std::vector<Frame> got = run_board(cs, src, 5.0f);
            float lowest = 0.0f, highest = 0.0f;
            distance_range(got, 0, lowest, highest);
            expect(lowest >= closeup_min_distance - 1e-3f, std::string(tag) + (anchored ? "never closer than the close-up floor (anchored)" : "never closer than the close-up floor (not anchored)"));
            expect(close_to(got.back().debug.distance, 0.6f, 0.01f), std::string(tag) + "and the rig distance rests at its own 0.6 m, under the main minimum");
        }
        CameraSettings with_shake = cs;
        with_shake.shake_enabled = true;
        float lowest = 0.0f, highest = 0.0f;
        distance_range(run_board(with_shake, src, 5.0f), 0, lowest, highest);
        expect(lowest >= closeup_min_distance - 0.06f, std::string(tag) + "also with the shake on (a few cm of shake translation)");
    }
    // The maximum: a distance scale of 3 asks for 7 m, the limit holds it.
    {
        CameraSettings far_cs;
        far_cs.shake_enabled = false;
        far_cs.framing.distance_scale = 3.0f;
        BoardSource ride_src;
        ride_src.script.rider.speed = 7.0f;
        float lowest = 0.0f, highest = 0.0f;
        distance_range(run_board(far_cs, ride_src, 5.0f), 0, lowest, highest);
        expect(highest <= far_cs.distance.max + 1e-3f && highest > far_cs.distance.max - 0.05f, "distance: never further than distance.max (6 m), and it reaches it");
        far_cs.distance.max = 3.0f;
        distance_range(run_board(far_cs, ride_src, 5.0f), 0, lowest, highest);
        expect(highest <= 3.0f + 1e-3f, "distance: and the maximum is a setting");
    }
    // A wall closer than the minimum: the camera keeps the minimum and goes up over it, eased.
    {
        Rider still;
        still.speed = 0.0f;
        World wall_world;
        wall_world.has_wall = true;
        wall_world.wall_z = -0.3f;
        World clear_world;
        CameraSettings cs;
        cs.shake_enabled = false;
        CameraMan walled = make_camera(cs), open = make_camera(cs);
        const Run walled_run = drive(walled, still, wall_world, 3.0f);
        const Run open_run = drive(open, still, clear_world, 3.0f);
        float lowest = 0.0f, highest = 0.0f;
        distance_range(walled_run.frames, 0, lowest, highest);
        expect(lowest >= cs.distance.min - 1e-3f, "distance: a wall closer than the minimum does not pull the camera inside it");
        expect(walled_run.frames.back().pos[1] > open_run.frames.back().pos[1] + 0.15f, "distance: it lifts the camera up over the obstacle instead");
        // A wall appearing mid-ride: the lift is eased (no jump).
        CameraMan late = make_camera(cs);
        const Run before = drive(late, still, clear_world, 1.0f);
        (void)before;
        Vec3 previous = late.frame().pos;
        float worst_step = 0.0f;
        for (int i = 0; i < 120; ++i) {
            const Frame& f = late.update(one_frame, still.at(1.0f), wall_world);
            worst_step = std::max(worst_step, std::abs(f.pos[1] - previous[1])); // the lift is vertical; the pull-in is near instant by design
            previous = f.pos;
        }
        std::printf("  wall lift worst step %.3f\n", static_cast<double>(worst_step));
        expect(worst_step < 0.12f, "distance: the lift over a close wall moves the camera up by under 12 cm a frame");
    }
    // NativePlus keeps the game's own distance: a 2 m native camera is not pushed out to a 3 m minimum.
    {
        CameraSettings np;
        np.preset = CameraPreset::NativePlus;
        np.shake_enabled = false;
        np.distance.min = 3.0f;
        np.distance.max = 3.5f;
        Rider ride;
        ride.speed = 5.0f;
        World ground_world;
        ground_world.upper_y = -1000.0f;
        CameraMan cam_np = make_camera(np);
        float closest = 1.0e9f;
        for (int i = 0; i < 180; ++i) {
            const SubjectSnapshot snap = ride.at(static_cast<float>(i) / 60.0f);
            const NativePose pose = follower_pose(snap);
            FrameExtras fx;
            fx.native = &pose;
            const Frame& f = cam_np.update(one_frame, snap, ground_world, fx);
            closest = std::min(closest, length(sub(f.pos, snap.position)));
        }
        expect(closest < 2.6f, "distance: NativePlus leaves the native distance alone");
    }
}

void test_framing_changes_apply_quickly() {
    World world;
    world.upper_y = -1000.0f;
    Script script;
    script.rider.speed = 6.0f;
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        const std::string tag = fps_tag("height", fps);
        CameraSettings before;
        CameraMan cam = make_camera(before);
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 4.0f, fps, frames);
        const float rel_before = frames.back().pos[1] - script.at(3.99f).position[1];
        CameraSettings after = before;
        after.framing.height_degrees = 15.0f;
        expect(cam.set_settings(after), tag + "settings accepted mid-ride");
        drive_between(cam, script, world, 4.0f, 9.0f, fps, frames);
        const auto rel = [&](float time) { return frame_at(frames, time, fps).pos[1] - script.at(time).position[1]; };
        const float rel_final = rel(8.9f);
        const float change = rel_final - rel_before;
        std::printf("  %sheight +15 deg: camera %.3f -> %.3f m above the rider; +0.3 s %.0f%%, +0.6 s %.0f%%\n", tag.c_str(), static_cast<double>(rel_before),
                    static_cast<double>(rel_final), static_cast<double>(100.0f * (rel(4.3f) - rel_before) / change),
                    static_cast<double>(100.0f * (rel(4.6f) - rel_before) / change));
        expect(change > 0.4f, tag + "the new height is clearly higher");
        expect(close_to(rel(4.6f), rel_final, 0.1f * change), tag + "within 0.6 s the camera is at the new height (90%)");
        expect(rel(4.05f) - rel_before < 0.3f * change, tag + "and it did not jump at once");
        float worst = 0.0f;
        for (std::size_t i = static_cast<std::size_t>(std::lround(4.0f * fps)); i < frames.size(); ++i)
            worst = std::max(worst, std::abs((frames[i].pos[1] - script.at(static_cast<float>(i) / fps).position[1]) -
                                             (frames[i - 1].pos[1] - script.at(static_cast<float>(i - 1) / fps).position[1])));
        expect(worst < 3.0f / fps, tag + "no frame step above 3 m/s while it moves");
        // The shot's own elevation still goes through the slow tracker: the rig elevation is not what moves.
        expect(close_to(frame_at(frames, 8.9f, fps).debug.height_offset, 15.0f * degrees, 0.1f * degrees), tag + "the offset settles at the setting");
    }
    // Distance and pitch changes also show quickly.
    for (const float fps : {30.0f, 60.0f, 144.0f}) {
        const std::string tag = fps_tag("distance / pitch", fps);
        CameraSettings before;
        CameraMan cam = make_camera(before);
        std::vector<Frame> frames;
        drive_between(cam, script, world, 0.0f, 4.0f, fps, frames);
        const float distance_before = frames.back().debug.distance;
        CameraSettings after = before;
        after.framing.distance_scale = 1.5f;
        expect(cam.set_settings(after), tag + "settings accepted mid-ride");
        drive_between(cam, script, world, 4.0f, 9.0f, fps, frames);
        const float distance_final = frame_at(frames, 8.9f, fps).debug.distance;
        const float d_share = (frame_at(frames, 4.5f, fps).debug.distance - distance_before) / (distance_final - distance_before);
        // The pitch alone, in a second run (the distance change moves the view pitch too).
        CameraMan pitch_cam = make_camera(before);
        std::vector<Frame> pitch_frames;
        drive_between(pitch_cam, script, world, 0.0f, 4.0f, fps, pitch_frames);
        const float pitch_before = view_pitch_deg(pitch_frames.back());
        CameraSettings pitched = before;
        pitched.framing.pitch_degrees = 8.0f;
        expect(pitch_cam.set_settings(pitched), tag + "pitch settings accepted mid-ride");
        drive_between(pitch_cam, script, world, 4.0f, 9.0f, fps, pitch_frames);
        const float pitch_final = view_pitch_deg(frame_at(pitch_frames, 8.9f, fps));
        const float p_share = (view_pitch_deg(frame_at(pitch_frames, 4.5f, fps)) - pitch_before) / (pitch_final - pitch_before);
        const float p_share_1s = (view_pitch_deg(frame_at(pitch_frames, 5.0f, fps)) - pitch_before) / (pitch_final - pitch_before);
        std::printf("  %sdistance %.2f -> %.2f m (%.0f%% at +0.5 s), pitch %.1f -> %.1f deg (%.0f%% at +0.5 s, %.0f%% at +1 s)\n", tag.c_str(),
                    static_cast<double>(distance_before), static_cast<double>(distance_final), static_cast<double>(100.0f * d_share),
                    static_cast<double>(pitch_before), static_cast<double>(pitch_final), static_cast<double>(100.0f * p_share),
                    static_cast<double>(100.0f * p_share_1s));
        expect(d_share > 0.9f, tag + "the distance change shows within 0.5 s (90%)");
        expect(pitch_final - pitch_before > 6.0f, tag + "the pitch setting moves the view by about its amount");
        expect(p_share > 0.6f && p_share_1s > 0.85f, tag + "and the pitch change is well under way within 0.5 s (60%) and nearly done in 1 s (85%)");
    }
}


// Beta feedback: riding up a quarter pipe or vert and back down, the camera came close to the skater (into him) and
// then spun round. Scripted vert run along +Z: flat, a curved ramp to vertical, a straight-up air with a 180, back
// down the ramp and away on the flat. Through the transition the camera keeps its heading and its distance.
struct VertRun {
    float nearest = 1e9f;     // m, camera to skater, after the start
    float transition_turn = 0.0f; // deg, largest view yaw change from the start of the ramp until 0.3 s after it
    float fastest_turn = 0.0f; // deg/s of the view yaw, anywhere
    float end_heading = 0.0f;
    float wall_side = -1e9f;  // m, how far the camera got onto the ramp's side of the skater (+Z) coming down
    bool finite = true;
};
VertRun run_vert(float speed, bool trick_180, float horizontal_follow) {
    CameraSettings cs;
    cs.shake_enabled = false;
    cs.collision.enabled = false;
    cs.follow.horizontal = horizontal_follow;
    auto* cam = new CameraMan;
    VertRun out;
    if (!cam->set_settings(cs)) { delete cam; out.finite = false; return out; }
    const auto no_hit = [](const Vec3&, const Vec3&) noexcept { return std::optional<GroundHit>{}; };
    // Phases (s): flat to 1.0, ramp up 1.0-1.5 (incline 0 -> 90 deg), air 1.5-1.5+2v/g, ramp down (90 -> 0) 0.5 s, flat.
    const float up_time = 0.5f, air_time = 2.0f * speed * 0.6f / gravity_ms2;
    const float t_ramp = 1.0f, t_air = t_ramp + up_time, t_down = t_air + air_time, t_flat = t_down + up_time;
    Vec3 pos{0.0f, root_height, 0.0f};
    float yaw_ref = 0.0f, prev_yaw = 0.0f;
    bool have_ref = false, have_prev = false;
    for (int i = 0; i < 420; ++i) {
        const float t = static_cast<float>(i) * one_frame;
        SubjectSnapshot s;
        s.time = t;
        s.valid = true;
        s.ground_clearance = root_height;
        s.forward = {0.0f, 0.0f, 1.0f};
        Vec3 v{0.0f, 0.0f, speed};
        if (t >= t_ramp && t < t_air) {
            const float a = 90.0f * degrees * (t - t_ramp) / up_time, along = speed * (1.0f - 0.4f * (t - t_ramp) / up_time);
            v = {0.0f, along * std::sin(a), along * std::cos(a)};
            s.ground_normal = {0.0f, std::cos(a), -std::sin(a)};
        } else if (t >= t_air && t < t_down) {
            s.physics_state = physics_state::air;
            s.ground_clearance = 3.0f;
            const float vy = 0.6f * speed - gravity_ms2 * (t - t_air);
            v = {0.0f, vy, 0.0f};
            if (trick_180 && t - t_air > 0.3f) s.forward = {0.0f, 0.0f, -1.0f};
        } else if (t >= t_down && t < t_flat) {
            const float a = 90.0f * degrees * (1.0f - (t - t_down) / up_time), along = speed * (0.6f + 0.4f * (t - t_down) / up_time);
            v = {0.0f, -along * std::sin(a), -along * std::cos(a)};
            s.ground_normal = {0.0f, std::cos(a), -std::sin(a)};
            if (trick_180) s.forward = {0.0f, 0.0f, -1.0f};
        } else if (t >= t_flat) {
            v = {0.0f, 0.0f, -speed};
            pos[1] = root_height;
            if (trick_180) s.forward = {0.0f, 0.0f, -1.0f};
        }
        s.velocity = v;
        pos = add(pos, scale(v, one_frame));
        s.position = pos;
        const Frame& f = cam->update(one_frame, s, no_hit);
        out.finite = out.finite && all_finite_frame(f) && is_orthonormal(f);
        if (i > 10) out.nearest = std::min(out.nearest, length(sub(f.pos, s.position)));
        const float yaw = std::atan2(-f.back[0], -f.back[2]);
        if (have_prev) out.fastest_turn = std::max(out.fastest_turn, std::abs(wrap_angle(yaw - prev_yaw)) / degrees / one_frame);
        prev_yaw = yaw;
        have_prev = true;
        if (t >= t_ramp && t < t_flat + 0.3f) {
            if (!have_ref) { yaw_ref = yaw; have_ref = true; }
            out.transition_turn = std::max(out.transition_turn, std::abs(wrap_angle(yaw - yaw_ref)) / degrees);
        }
        if (t >= t_down && t < t_flat) out.wall_side = std::max(out.wall_side, f.pos[2] - s.position[2]);
        out.end_heading = f.debug.heading;
    }
    delete cam;
    return out;
}
void test_transition_vert() {
    for (const float follow : {0.0f, 8.0f})
        for (const bool trick : {false, true})
            for (const float speed : {6.0f, 9.0f}) {
                const VertRun r = run_vert(speed, trick, follow);
                const std::string tag = "vert (follow " + std::to_string(static_cast<int>(follow)) + ", " +
                                        std::to_string(static_cast<int>(speed)) + " m/s" + (trick ? ", 180" : "") + "): ";
                expect(r.finite, tag + "finite, orthonormal frames");
                expect(r.nearest >= CameraSettings{}.distance.min - 0.05f, tag + "never nearer than the minimum distance");
                expect(r.transition_turn < 35.0f, tag + "the view keeps its heading through the transition");
                expect(r.wall_side < 0.0f, tag + "coming down, the camera stays on the open side, not in the ramp");
                expect(std::abs(wrap_angle(r.end_heading - pi)) > 45.0f * degrees, tag + "riding away, it swings round behind");
            }
}

// Beta feedback: in a manual (board anchoring on), a trick out of it snapped the camera. The trick flips and spins
// the board; the camera must not follow that while it eases out of the close-up. Compared with the same run where
// the board stays put under the rider. The ease-out time slider makes the exit quicker or slower.
struct FlipSource {
    Script script;
    bool spin = true;
    SubjectSnapshot at(float time) const {
        SubjectSnapshot snap = script.at(time);
        Vec3 offset{0.0f, -0.9f, 0.0f};
        if (spin && time >= script.rider.ollie_time) {
            const float a = 2.0f * pi * 8.0f * (time - script.rider.ollie_time); // 8 turns a second
            offset = add(offset, {0.45f * std::cos(a), 0.45f * std::sin(a), 0.0f});
        }
        snap.board_position = add(snap.position, offset);
        snap.board_valid = true;
        return snap;
    }
};
float worst_exit_step(const CameraSettings& cs, bool spin, std::vector<Frame>* keep = nullptr) {
    FlipSource src;
    src.spin = spin;
    src.script.rider.speed = 7.0f;
    src.script.rider.has_ollie = true;
    src.script.rider.ollie_time = 5.0f;
    src.script.manuals.push_back({2.0f, 5.0f});
    World world;
    world.upper_y = -1000.0f;
    CameraMan cam = make_camera(cs);
    std::vector<Frame> frames;
    drive_between(cam, src, world, 0.0f, 8.0f, 60.0f, frames);
    float worst = 0.0f;
    for (std::size_t i = 295; i < 400; ++i) {
        const Vec3 o_now = sub(frames[i].pos, src.script.at(static_cast<float>(i) / 60.0f).position);
        const Vec3 o_prev = sub(frames[i - 1].pos, src.script.at(static_cast<float>(i - 1) / 60.0f).position);
        worst = std::max(worst, length(sub(o_now, o_prev)));
    }
    if (keep) *keep = frames;
    return worst;
}
void test_closeup_exit_ignores_flipping_board() {
    CameraSettings cs;
    cs.shake_enabled = false;
    cs.look.board_anchor = true;
    const float steady = worst_exit_step(cs, false), flipping = worst_exit_step(cs, true);
    std::printf("  close-up exit: worst camera step %.3f m (board still), %.3f m (board flipping)\n", steady, flipping);
    expect(flipping <= steady + 0.002f, "close-up exit: a flipping board does not jerk the camera on the way out");
    // The slider: the exit from the close-up ends after about the ease-out time.
    const auto t90 = [](float exit_time) {
        CameraSettings c;
        c.shake_enabled = false;
        c.framing.manual_distance = 1.2f;
        c.look.closeup_exit_time = exit_time;
        std::vector<Frame> frames;
        worst_exit_step(c, false, &frames);
        for (std::size_t i = 301; i < frames.size(); ++i)
            if (frames[i].debug.exit_blend >= 1.0f) return static_cast<float>(i) / 60.0f - 5.0f;
        return 99.0f;
    };
    const float quick = t90(0.3f), slow = t90(2.0f);
    std::printf("  close-up exit: out after %.2f s (0.3 s setting), %.2f s (2.0 s setting)\n", quick, slow);
    expect(close_to(quick, 0.3f, 0.1f) && close_to(slow, 2.0f, 0.1f), "close-up exit: the ease-out time sets how long the exit takes");
}

// Beta feedback: collision should work without setting it up. Automatic collision ignores a pole between the skater
// and the camera (a thin obstacle) but still moves in front of a wall; with Automatic off the pole pulls it in too.
struct PoleOrWall {
    bool wall = false;
    float z = -1.2f; // the pole's centre / the wall's plane, between the skater (z 0) and the camera (behind, -Z)
    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        const Vec3 d = sub(to, from);
        if (wall) {
            if ((from[2] - z) * (to[2] - z) >= 0.0f) return std::nullopt;
            const float t = (z - from[2]) / d[2];
            return GroundHit{add(from, scale(d, t)), {0.0f, 0.0f, 1.0f}};
        }
        // A vertical pole of radius 0.1 m at (0, z): the segment against a circle in XZ.
        constexpr float r = 0.1f;
        const float fx = from[0], fz = from[2] - z, dx = d[0], dz = d[2];
        const float a = dx * dx + dz * dz, b = 2.0f * (fx * dx + fz * dz), c = fx * fx + fz * fz - r * r;
        const float disc = b * b - 4.0f * a * c;
        if (a < 1e-9f || disc < 0.0f) return std::nullopt;
        const float t = (-b - std::sqrt(disc)) / (2.0f * a);
        if (t < 0.0f || t > 1.0f) return std::nullopt;
        return GroundHit{add(from, scale(d, t)), {0.0f, 0.0f, 1.0f}};
    }
};
float pull_with(bool automatic, bool wall) {
    CameraSettings cs;
    cs.shake_enabled = false;
    cs.collision.automatic = automatic;
    CameraMan cam = make_camera(cs);
    PoleOrWall world;
    world.wall = wall;
    Frame f{};
    for (int i = 0; i < 180; ++i) {
        SubjectSnapshot s;
        s.time = static_cast<float>(i) * one_frame;
        s.valid = true;
        s.position = {0.0f, root_height, 0.0f};
        s.forward = {0.0f, 0.0f, 1.0f};
        s.ground_clearance = root_height;
        f = cam.update(one_frame, s, world);
    }
    return f.debug.collision_pull;
}
void test_automatic_collision_thin_obstacles() {
    const float pole_auto = pull_with(true, false), wall_auto = pull_with(true, true), pole_manual = pull_with(false, false);
    std::printf("  automatic collision: pull %.2f m (pole), %.2f m (wall); automatic off: %.2f m (pole)\n", pole_auto, wall_auto, pole_manual);
    expect(pole_auto < 0.01f, "automatic collision: a pole does not pull the camera in");
    expect(wall_auto > 0.3f, "automatic collision: a wall still does");
    expect(pole_manual > 0.3f, "collision with automatic off: the pole pulls it in as before");
}

// Beta feedback: on a drop-in the camera struggled to follow the skater. Scripted drop-in: a 3 m quarter pipe (deck at
// y 3 for z < 0, the curve down to the flat at z 3), the skater stands on the coping for 2 s, drops in (speed from the
// fall), and rides away on the flat. The world is a height field, so collision and prediction see the deck and ramp.
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
struct DropIn {
    // The skater's root on the surface at time t: still on the coping until 2 s, then along the curve and the flat.
    SubjectSnapshot at(float t) const {
        SubjectSnapshot s;
        s.time = t;
        s.valid = true;
        s.forward = {0.0f, 0.0f, 1.0f};
        s.ground_clearance = root_height;
        float z = -0.3f, vz = 0.0f, vy = 0.0f;
        Vec3 n{0.0f, 1.0f, 0.0f};
        if (t > 2.0f) {
            // Angle a along the curve from the coping (a = 0, wall) to the bottom (a = 90 deg): a = 90 deg * min(1, (t-2)/0.75).
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
};
void test_drop_in() {
    CameraSettings cs;
    cs.shake_enabled = false;
    CameraMan cam = make_camera(cs);
    const DropIn src;
    QuarterPipe world;
    bool inside = false;
    float height_after = 0.0f, pull_after = 0.0f, settled_height = 0.0f;
    for (int i = 0; i < 360; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const SubjectSnapshot s = src.at(t);
        const Frame& f = cam.update(1.0f / 60.0f, s, world);
        inside = inside || f.pos[1] < QuarterPipe::height(f.pos[2]);
        if (i == 183) { height_after = f.pos[1] - s.position[1]; pull_after = f.debug.collision_pull; } // 0.3 s on the flat
        if (i == 359) settled_height = f.pos[1] - s.position[1];
    }
    std::printf("  drop-in: camera %.2f m from its settled height and %.2f m pulled in 0.3 s after reaching the flat\n",
                std::abs(height_after - settled_height), pull_after);
    expect(!inside, "drop-in: the camera never goes inside the deck or the ramp");
    expect(std::abs(height_after - settled_height) < 0.25f, "drop-in: 0.3 s after the bottom the camera is (nearly) back at its height");
    expect(pull_after < 0.2f, "drop-in: and has let go of the ramp's pull-in");
}

// Beta 2b log: plain ollies predicted landings 4-20 m down. Near touchdown the skater compresses over the board, the
// re-prediction's launch point (root minus the takeoff clearance) sat under the floor, and rays that start inside a
// surface pass through it. One-sided floors here (hit only from above): the ground at 0 and another 20 m below.
struct OneSidedFloors {
    std::optional<GroundHit> operator()(const Vec3& from, const Vec3& to) const noexcept {
        for (const float y : {0.0f, -20.0f})
            if (from[1] > y && to[1] <= y) {
                const float t = (from[1] - y) / std::max(from[1] - to[1], 1e-6f);
                return GroundHit{lerp(from, to, t), {0.0f, 1.0f, 0.0f}};
            }
        return std::nullopt;
    }
};
void test_prediction_near_touchdown() {
    struct Ollie {
        SubjectSnapshot at(float t) const {
            SubjectSnapshot s;
            s.valid = true;
            s.time = t;
            s.forward = {0.0f, 0.0f, 1.0f};
            const float air_t = t - 1.0f;
            float y = root_height, vy = 0.0f;
            if (air_t > 0.0f && air_t < 0.6f) {
                s.physics_state = physics_state::air;
                y = root_height + 3.0f * air_t - 0.5f * gravity_ms2 * air_t * air_t;
                vy = 3.0f - gravity_ms2 * air_t;
                if (air_t > 0.4f) y -= 0.8f * (air_t - 0.4f) / 0.2f; // compressing for the landing: the root sinks
            }
            s.position = {0.0f, y, 6.0f * t};
            s.velocity = {0.0f, vy, 6.0f};
            s.ground_clearance = y; // the ground at 0 under the skater
            return s;
        }
    } ollie;
    CameraSettings cs;
    cs.shake_enabled = false;
    CameraMan cam = make_camera(cs);
    OneSidedFloors world;
    float worst = 0.0f;
    for (int i = 0; i < 120; ++i) {
        const Frame& f = cam.update(1.0f / 60.0f, ollie.at(static_cast<float>(i) / 60.0f), world);
        if (f.debug.prediction_valid) worst = std::min(worst, f.debug.predicted_landing_delta);
    }
    std::printf("  prediction near touchdown: lowest predicted landing %.2f m (the real one is 0)\n", worst);
    expect(worst > -1.0f, "prediction: a compressed skater near touchdown does not predict the floor 20 m below");
}

int main() {
    test_manual_grind_focus();
    test_framing_per_angle();
    test_air_camera_in_frame();
    test_air_camera_layers();
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
    test_speed_holds_in_air();
    test_framing_distance_height_pitch();
    test_framing_change_is_smooth();
    test_framing_manual();
    test_framing_continuity();
    test_trick_yaw_long_air();
    test_trick_yaw_back_to_back();
    test_trick_yaw_retrigger_while_recentring();
    test_trick_yaw_side_rules();
    test_trick_yaw_triggers();
    test_trick_yaw_disable_and_cut();
    test_landing_impulse_in_game();
    test_landing_from_fall();
    test_horizontal_follow();
    test_exit_closeup_is_smooth();
    test_manual_grind_floor();
    test_grind_framing_settings();
    test_framing_changes_apply_quickly();
    test_board_anchor_follows_board();
    test_board_anchor_smooth_and_off_unchanged();
    test_board_anchor_pitch_steady();
    test_distance_limits();
    test_transition_vert();
    test_closeup_exit_ignores_flipping_board();
    test_automatic_collision_thin_obstacles();
    test_drop_in();
    test_prediction_near_touchdown();
    if (failures == 0) std::printf("s3cam_layers_tests: all passed\n");
    return failures == 0 ? 0 : 1;
}
