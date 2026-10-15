#include "Engine/Game/Camera/s3_air.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string_view>

// s3_air.h: the launch -> landing height transition and touchdown detection.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-4f) { return std::abs(a - b) <= tolerance; }

constexpr float dt = 1.0f / 120.0f;
constexpr float g = 10.1f;
constexpr float board_clearance = 0.9f; // the anchor rides this far above the surface

// A scripted jump: leave a surface at y = 0 with vertical speed `vy` and land on a surface at
// `landing_surface_y` (0 = flat, -2 = a stair set). The anchor is the board, 0.9 m up.
struct Jump {
    float vy = 3.5f;
    float landing_surface_y = 0.0f;
    float forward_speed = 5.0f;

    TrajectoryPrediction predict() const {
        TrajectoryLaunch launch;
        launch.position = {0, 0, 0}; // surface level; the anchor adds board_clearance
        launch.velocity = {0, vy, forward_speed};
        const float surface = landing_surface_y;
        const auto ground = [surface](const Vec3& a, const Vec3& b) -> std::optional<GroundHit> {
            if (a[1] >= surface && b[1] < surface) {
                const float f = (a[1] - surface) / (a[1] - b[1]);
                return GroundHit{lerp(a, b, f), {0, 1, 0}};
            }
            return std::nullopt;
        };
        TrajectorySettings ts;
        ts.gravity = g;
        return predict_trajectory(launch, ground, ts);
    }
    // Anchor height t seconds after takeoff.
    float anchor_height(float t) const { return board_clearance + vy * t - 0.5f * g * t * t; }
    Vec3 velocity(float t) const { return {0, vy - g * t, forward_speed}; }
};

struct Flight {
    float max_height = -1e9f;
    float final_height = 0.0f;
    float end_gap = 0.0f;     // reference height minus anchor height on the step before touchdown
    int landings = 0;
    int steps_in_air = 0;
    bool monotonic_descent = true;
    bool transitioned = false;
    std::optional<LandingEvent> landing;
    AirHeight air;
};

// Rides on the ground for a while, flies the jump, lands, then rides on. Calls `tweak` each air step.
template <class Tweak>
Flight fly(const Jump& jump, const AirSettings& set, Tweak&& tweak) {
    Flight f;
    const TrajectoryPrediction p = jump.predict();
    expect(p.landed(), "the scripted jump lands");
    const float air_time = p.predicted_air_time;
    f.air.reset(board_clearance);
    // 0.25 s of riding.
    for (int i = 0; i < 30; ++i) {
        AirInput in;
        in.anchor_height = board_clearance;
        in.velocity = {0, 0, jump.forward_speed};
        f.air.update(dt, in, set);
    }
    const float start_height = f.air.height();
    float previous_height = start_height;
    for (int i = 0; i < 400; ++i) {
        const float t = static_cast<float>(i) * dt;
        const bool grounded = t >= air_time;
        AirInput in;
        in.grounded = grounded;
        in.set_prediction(p);
        in.trajectory_time = t;
        in.anchor_height = grounded ? jump.landing_surface_y + board_clearance : jump.anchor_height(t);
        in.velocity = grounded ? Vec3{0, 0, jump.forward_speed} : jump.velocity(t);
        in.ground_normal = {0, 1, 0};
        if (!grounded) tweak(in, t);
        const AirOutput out = f.air.update(dt, in, set);
        if (out.landing) {
            ++f.landings;
            f.landing = out.landing;
        }
        if (!grounded) {
            ++f.steps_in_air;
            f.max_height = std::max(f.max_height, out.reference_height);
            if (out.transitioning) f.transitioned = true;
            if (out.reference_height > previous_height + 1e-5f) f.monotonic_descent = false;
            f.end_gap = out.reference_height - in.anchor_height;
        }
        previous_height = out.reference_height;
        f.final_height = out.reference_height;
    }
    return f;
}
auto no_tweak = [](AirInput&, float) {};

void ollie_stays_low() {
    const AirSettings set;
    expect(set.valid(), "default air settings are valid");
    const Jump jump;
    const TrajectoryPrediction p = jump.predict();
    const float apex = p.predicted_max_height;
    expect(near(apex, jump.vy * jump.vy / (2 * g), 0.01f), "predicted apex matches the physics");
    Flight f = fly(jump, set, no_tweak);
    const float launch_height = board_clearance;
    expect(f.max_height < launch_height + 0.35f * apex, "ollie: camera max height stays under launch + 0.35 apex");
    expect(f.max_height <= launch_height + 1e-3f, "ollie: on flat ground the camera does not rise at all");
    expect(f.transitioned, "ollie: a transition was armed");
    expect(near(f.final_height, launch_height, 1e-3f), "ollie: back on the anchor after landing");
    // Without the hold the camera would chase the board all the way up.
    AirSettings follow = set;
    follow.hold_height_in_air = false;
    Flight chase = fly(jump, follow, no_tweak);
    // (the transition still governs while it lasts, so the follow flag is checked directly)
    AirHeight a;
    a.reset(board_clearance);
    AirInput in;
    in.grounded = false;
    in.anchor_height = board_clearance + 0.5f;
    a.update(dt, in, follow);
    expect(near(a.height(), board_clearance + 0.5f), "without the hold the height follows the anchor up");
    expect(chase.landings == 1, "follow variant still lands once");
    // A shot that follows the subject in air does the same.
    AirHeight b;
    b.reset(board_clearance);
    in.follow_anchor_in_air = true;
    b.update(dt, in, set);
    expect(near(b.height(), board_clearance + 0.5f), "follow_anchor_in_air tracks the anchor");
}

void stair_drop_eases_down() {
    Jump jump;
    jump.landing_surface_y = -2.0f;
    jump.vy = 2.0f;
    const AirSettings set;
    const Flight f = fly(jump, set, no_tweak);
    expect(f.transitioned, "stairs: transition armed for a 2 m drop");
    expect(f.monotonic_descent, "stairs: the reference height only ever eases down");
    expect(near(f.final_height, -2.0f + board_clearance, 1e-3f), "stairs: ends on the lower landing");
    expect(std::abs(f.end_gap) < 0.15f, "stairs: the reference is within 15 cm of the board at touchdown");
    expect(f.landings == 1, "stairs: one landing");

    // Midway the camera is partway down and above the final height (ease, not a pop).
    const TrajectoryPrediction p = jump.predict();
    AirHeight a;
    a.reset(board_clearance);
    float mid = 0.0f;
    for (int i = 0; i < static_cast<int>(p.predicted_air_time / dt); ++i) {
        const float t = static_cast<float>(i) * dt;
        AirInput in;
        in.grounded = false;
        in.set_prediction(p);
        in.trajectory_time = t;
        in.anchor_height = jump.anchor_height(t);
        in.velocity = jump.velocity(t);
        const AirOutput out = a.update(dt, in, set);
        if (i == static_cast<int>(0.5f * p.predicted_air_time / dt)) mid = out.reference_height;
    }
    const float final_h = -2.0f + board_clearance;
    expect(mid < board_clearance - 0.2f && mid > final_h + 0.2f, "stairs: halfway through the flight the camera is halfway down");
}

void deep_drop_is_ignored() {
    Jump jump;
    jump.landing_surface_y = -3.5f;
    jump.vy = 2.0f;
    const AirSettings set;
    Flight f = fly(jump, set, no_tweak);
    expect(!f.transitioned, "deep drop: no transition for a 3.5 m drop");
    expect(f.max_height <= board_clearance + 1e-3f, "deep drop: the height still does not rise");
    expect(f.landings == 1, "deep drop: one landing");
    expect(near(f.final_height, -3.5f + board_clearance, 1e-3f), "deep drop: follows the anchor down after touchdown");
    // Just inside the limit does transition.
    Jump inside = jump;
    inside.landing_surface_y = -2.9f;
    expect(fly(inside, set, no_tweak).transitioned, "a 2.9 m drop does transition");
}

void recompute_on_1mm() {
    Jump jump;
    jump.landing_surface_y = -2.0f;
    jump.vy = 3.0f;
    const AirSettings set;
    // Sub-millimetre jitter in the predicted landing height: nothing is recomputed.
    float end_before = 0.0f, end_after = 0.0f;
    Flight small = fly(jump, set, [&](AirInput& in, float t) {
        in.landing_height_delta += (t > 0.2f) ? 0.0005f : 0.0f;
    });
    expect(!small.air.prediction_moved(), "0.5 mm change does not flag the prediction as moved");

    // Capture the transition end around a 1 cm change halfway through.
    AirHeight a;
    a.reset(board_clearance);
    const TrajectoryPrediction p = jump.predict();
    int moved_steps = 0;
    for (int i = 0; i < static_cast<int>(p.predicted_air_time / dt) - 2; ++i) {
        const float t = static_cast<float>(i) * dt;
        AirInput in;
        in.grounded = false;
        in.set_prediction(p);
        if (t > 0.5f * p.predicted_air_time) in.landing_height_delta -= 0.05f; // landing 5 cm lower
        in.trajectory_time = t;
        in.anchor_height = jump.anchor_height(t);
        in.velocity = jump.velocity(t);
        const float before_end = a.transition_end();
        const float before_dur = a.transition_duration();
        const AirOutput out = a.update(dt, in, set);
        if (i == static_cast<int>(0.5f * p.predicted_air_time / dt) - 1) end_before = a.transition_end();
        if (out.prediction_moved) ++moved_steps;
        if (t > 0.5f * p.predicted_air_time && end_after == 0.0f && a.transition_end() != before_end) {
            end_after = a.transition_end();
            expect(a.transition_time() < dt * 1.5f, "recompute restarts the transition clock");
            expect(a.transition_duration() < before_dur, "recompute spans only the remaining flight");
        }
    }
    expect(end_before != 0.0f && end_after != 0.0f, "recompute happened after the 5 cm change");
    expect(near(end_before - end_after, 0.05f, 2e-3f), "the new end is the takeoff height plus the new landing delta");
    expect(moved_steps > 0, "a >1 mm change flags the prediction as moved");

    // Exactly one recompute: a constant new prediction does not keep restarting the transition.
    int restarts = 0;
    AirHeight b;
    b.reset(board_clearance);
    float last_time = 0.0f;
    for (int i = 0; i < static_cast<int>(p.predicted_air_time / dt) - 2; ++i) {
        const float t = static_cast<float>(i) * dt;
        AirInput in;
        in.grounded = false;
        in.set_prediction(p);
        if (t > 0.5f * p.predicted_air_time) in.landing_height_delta -= 0.05f;
        in.trajectory_time = t;
        in.anchor_height = jump.anchor_height(t);
        in.velocity = jump.velocity(t);
        b.update(dt, in, set);
        if (b.transition_time() < last_time) ++restarts;
        last_time = b.transition_time();
    }
    expect(restarts == 1, "a settled new prediction restarts the transition exactly once");
}

void landing_fires_once() {
    const AirSettings set;
    const Jump jump;
    const Flight f = fly(jump, set, no_tweak);
    expect(f.landings == 1, "landing fires exactly one event");
    expect(f.landing.has_value(), "the landing carried a payload");
    if (!f.landing) return;
    const TrajectoryPrediction p = jump.predict();
    // The event holds the PREVIOUS step's velocity and normal, not the grounded step's.
    const int steps = static_cast<int>(std::ceil(p.predicted_air_time / dt));
    const Vec3 expected = jump.velocity(static_cast<float>(steps - 1) * dt);
    expect(near(f.landing->velocity[1], expected[1], 1e-3f) && f.landing->velocity[1] < -3.0f, "event velocity is the previous (airborne) velocity");
    expect(near(f.landing->velocity[2], jump.forward_speed), "event velocity keeps the forward component");
    expect(near(f.landing->normal[1], 1.0f), "event normal is the ground normal");
}

void landing_edge_cases() {
    const AirSettings set;
    // Velocity moving away from the surface (a skim or a bounce up) is not a landing.
    AirHeight a;
    a.reset(1.0f, false);
    AirInput in;
    in.grounded = false;
    in.anchor_height = 1.0f;
    in.velocity = {0, 2.0f, 0};
    a.update(dt, in, set);
    in.grounded = true;
    expect(!a.update(dt, in, set).landing, "no event when the previous velocity points away from the ground");

    // Ground to ground never fires; the first step never fires.
    AirHeight b;
    AirInput ride;
    ride.velocity = {0, -5.0f, 0};
    expect(!b.update(dt, ride, set).landing, "first step on the ground does not fire");
    expect(!b.update(dt, ride, set).landing, "riding does not fire");

    // Two separate jumps fire twice.
    int count = 0;
    AirHeight c;
    c.reset(0.0f);
    for (int jump_index = 0; jump_index < 2; ++jump_index) {
        AirInput up;
        up.grounded = false;
        up.velocity = {0, -4.0f, 0};
        for (int i = 0; i < 10; ++i) c.update(dt, up, set);
        up.grounded = true;
        for (int i = 0; i < 10; ++i)
            if (c.update(dt, up, set).landing) ++count;
    }
    expect(count == 2, "each touchdown fires once");

    // The slope: previous velocity against the previous normal, not the current one.
    AirHeight d;
    d.reset(0.0f, false);
    AirInput slope;
    slope.grounded = false;
    slope.velocity = {0, -3.0f, 4.0f};
    slope.ground_normal = normalized({0, 1, -0.5f});
    d.update(dt, slope, set);
    AirInput touch = slope;
    touch.grounded = true;
    touch.ground_normal = {0, 1, 0}; // incline has already moved on
    const AirOutput out = d.update(dt, touch, set);
    expect(out.landing.has_value() && near(out.landing->normal[2], slope.ground_normal[2]),
           "the event carries the previous step's normal");
}

void miss_and_invalid() {
    const AirSettings set;
    // A Miss prediction: hold, never transition.
    AirInput in;
    TrajectoryPrediction miss;
    miss.status = TrajectoryStatus::Miss;
    in.set_prediction(miss);
    expect(!in.trajectory_valid, "a Miss prediction is not usable");
    AirHeight a;
    a.reset(1.0f);
    in.grounded = false;
    in.anchor_height = 2.0f;
    const AirOutput out = a.update(dt, in, set);
    expect(!out.transitioning && near(out.reference_height, 1.0f) && near(out.transition_weight, 0.0f), "miss: holds, no transition");
    in.anchor_height = 0.5f;
    expect(near(a.update(dt, in, set).reference_height, 0.5f), "miss: still comes down with the board");

    AirInput bad;
    bad.anchor_height = std::nanf("");
    expect(near(a.update(dt, bad, set).reference_height, 0.5f), "non-finite anchor is ignored");
    expect(near(a.update(0.0f, in, set).reference_height, 0.5f), "zero dt is ignored");
    AirSettings broken = set;
    broken.change_threshold = 0.0f;
    expect(!broken.valid(), "zero threshold is invalid");
    expect(near(a.update(dt, in, broken).reference_height, 0.5f), "invalid settings leave the height alone");
}

void reset_snaps() {
    const AirSettings set;
    Jump jump;
    jump.landing_surface_y = -1.0f;
    const TrajectoryPrediction p = jump.predict();
    AirHeight a;
    a.reset(board_clearance);
    AirInput in;
    in.grounded = false;
    in.set_prediction(p);
    in.anchor_height = board_clearance + 0.3f;
    in.trajectory_time = 0.1f;
    in.velocity = {0, 1, 3};
    a.update(dt, in, set);
    expect(a.transitioning(), "mid-flight transition is live");
    a.reset(7.0f);
    expect(near(a.height(), 7.0f) && !a.transitioning() && !a.prediction_moved(), "reset snaps the height and drops the transition");
    AirInput ride;
    ride.anchor_height = 7.0f;
    ride.velocity = {0, -9, 0};
    expect(!a.update(dt, ride, set).landing, "reset forgets the previous frame");
    // snap_height jumps to the anchor even mid-transition.
    a.reset(1.0f);
    in.anchor_height = 4.0f;
    a.update(dt, in, set);
    in.snap_height = true;
    expect(near(a.update(dt, in, set).reference_height, 4.0f), "snap_height cuts to the anchor");
}

} // namespace

int main() {
    ollie_stays_low();
    stair_drop_eases_down();
    deep_drop_is_ignored();
    recompute_on_1mm();
    landing_fires_once();
    landing_edge_cases();
    miss_and_invalid();
    reset_snaps();
    if (failures == 0) std::printf("s3cam_air_tests: all passed\n");
    return failures == 0 ? 0 : 1;
}
