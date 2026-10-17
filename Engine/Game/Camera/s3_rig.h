#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/rig_tracking.rs (AnchorRigTracking latch/input smoothing,
// AngularRigTracking heading and elevation, wrap_vmx), vector_tracker.rs (VectorTracker),
// rig_positioning.rs and positioner.rs (distance tracker parameters), compass.rs and
// compass_movement.rs (movement compass, dead-zone, auto-lineup), and crates/skate-game
// camera/settings.rs (tunable names: SubjectTrackerMaxSpeed/MaxAcceleration, PumpingMinAcceleration,
// push/pump lag profiles, TimeBeforeAutoLineup, AutoLineupSpeed, Avoidance*Smoothing). Semantics are
// ported; the bit-exact VMX constants and fused multiply-adds are replaced by ordinary float
// arithmetic, and the defaults below are hand-picked (no EA data).
#include "Engine/Game/Camera/s3_math.h"
#include "Engine/Game/Camera/s3_tracker.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

// The S3Cam rig: where the camera orbits (anchor, with push/pump lag), which way it looks
// from (heading, elevation) and how far (distance). Pure, header-only, no allocation. Call
// Rig::update() on the fixed rig step (60 Hz, as the Rust runs it); the lag and tracker settings
// are per-step quantities (per 1/60 s, as in the Rust). World is Y up; heading 0 looks down +Z and grows
// toward -X (heading(v) = atan2(-x, z), compass.rs).
namespace dingosdk::s3cam {

inline constexpr float rig_step = fixed_step;

// ---------------------------------------------------------------- lag curve (PointGraph<8>)

// Eight (x, y) points, x ascending; evaluate() clamps outside the range and is linear between
// (point_graph.rs PointGraph::evaluate). The anchor lag curves are read at x = 1 - 2 * time left,
// so x = 0 is the instant the latch fires and x = 1 is half a second later.
struct LagCurve {
    static constexpr std::size_t size = 8;
    std::array<float, size> x{0.0f, 0.15f, 0.3f, 0.45f, 0.6f, 0.75f, 0.9f, 1.0f};
    std::array<float, size> y{1.0f, 0.85f, 0.65f, 0.45f, 0.28f, 0.14f, 0.05f, 0.0f}; // TUNE

    float evaluate(float input) const noexcept {
        if (input < x[0]) return y[0];
        if (!(input < x[size - 1])) return y[size - 1]; // also catches NaN
        for (std::size_t upper = 1; upper < size; ++upper) {
            if (!(input < x[upper])) continue;
            const std::size_t lower = upper - 1;
            const float width = x[upper] - x[lower];
            if (width <= 0.0f) return y[upper];
            return y[lower] + (y[upper] - y[lower]) / width * (input - x[lower]);
        }
        return y[0];
    }
    bool valid() const noexcept {
        for (std::size_t i = 0; i < size; ++i) {
            if (!std::isfinite(x[i]) || !std::isfinite(y[i])) return false;
            if (i > 0 && x[i] < x[i - 1]) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------- vector tracker

struct VectorTrackerSettings {
    float speed_clamp = 25.0f;        // m/s
    float acceleration_clamp = 120.0f; // m/s^2
    float smoothing = 0.0f;            // 0 = take the whole step, 1 = hold
};

// vector_tracker.rs VectorTracker::update with min == max clamps and smoothing, which is how
// AnchorRigTracking binds it. Acceleration is clamped only while it pushes toward the target.
class VectorTracker {
public:
    void reset(const Vec3& value) noexcept {
        if (!std::isfinite(value[0]) || !std::isfinite(value[1]) || !std::isfinite(value[2])) return;
        target_ = position_ = value;
        velocity_ = acceleration_ = {0, 0, 0};
    }
    const Vec3& update(const Vec3& target, float dt, const VectorTrackerSettings& set) noexcept {
        if (!(dt > 0.0f) || !std::isfinite(dt) || !std::isfinite(target[0]) || !std::isfinite(target[1]) ||
            !std::isfinite(target[2]))
            return position_;
        target_ = target;
        const Vec3 delta = sub(target, position_);
        if (dot(delta, velocity_) < 0.0f) velocity_ = {0, 0, 0}; // overshoot_zeroes_velocity
        acceleration_ = scale(sub(scale(delta, 1.0f / dt), velocity_), 1.0f / dt);
        if (dot(acceleration_, delta) > 0.0f) acceleration_ = clamp_length(acceleration_, set.acceleration_clamp);
        velocity_ = clamp_length(add(velocity_, scale(acceleration_, dt)), set.speed_clamp);
        position_ = add(position_, scale(velocity_, dt * (1.0f - set.smoothing)));
        return position_;
    }
    const Vec3& position() const noexcept { return position_; }
    const Vec3& velocity() const noexcept { return velocity_; }
    const Vec3& target() const noexcept { return target_; }
    const Vec3& acceleration() const noexcept { return acceleration_; }

private:
    static Vec3 clamp_length(const Vec3& v, float limit) noexcept {
        const float magnitude = length(v);
        return magnitude > limit ? scale(v, limit / magnitude) : v;
    }
    Vec3 target_{0, 0, 0}, position_{0, 0, 0}, velocity_{0, 0, 0}, acceleration_{0, 0, 0};
};

// ---------------------------------------------------------------- anchor tracking (push / pump lag)

struct AnchorSettings {
    LagCurve push_curve;  // lag after a push starts (camera_lag_profile "push")
    LagCurve pump_curve;  // lag after a pump (camera_lag_profile "pump")
    float push_max_smoothing = 0.6f;   // push MaxSmoothing; TUNE
    float pump_max_smoothing = 0.4f;   // pump MaxSmoothing; TUNE
    float pump_min_acceleration = 4.0f; // PumpingMinAcceleration, m/s^2; TUNE
    float speed_clamp = 25.0f;          // SubjectTrackerMaxSpeed, m/s; TUNE
    float acceleration_clamp = 120.0f;  // SubjectTrackerMaxAcceleration, m/s^2; TUNE
    float lag_full_below_speed = 4.0f;  // m/s. Lag at full strength at or below this anchor speed (Rust: 8 - speed over 4)
    float lag_off_above_speed = 8.0f;   // m/s. No lag at or above it
    float lag_hold_time = 0.5f;         // s. How long a latch decays over (the curves' x axis spans it)

    bool valid() const noexcept {
        const auto frac = [](float v) { return std::isfinite(v) && v >= 0.0f && v <= 1.0f; };
        return push_curve.valid() && pump_curve.valid() && frac(push_max_smoothing) && frac(pump_max_smoothing) &&
               std::isfinite(pump_min_acceleration) && std::isfinite(speed_clamp) && speed_clamp > 0.0f &&
               std::isfinite(acceleration_clamp) && acceleration_clamp > 0.0f && std::isfinite(lag_full_below_speed) &&
               lag_full_below_speed >= 0.0f && std::isfinite(lag_off_above_speed) &&
               lag_off_above_speed > lag_full_below_speed && std::isfinite(lag_hold_time) && lag_hold_time > 0.0f &&
               lag_hold_time <= 5.0f;
    }
};

struct AnchorInput {
    Vec3 position{0, 0, 0};       // the anchor point the camera orbits; only X and Z are used
    float reference_height = 0.0f; // world Y to track instead of position[1] (AirHeight::height())
    Vec3 velocity{0, 0, 0};        // anchor velocity, for the lag fade-out at speed
    // rig_tracking.rs AnchorTrackingSubject. Native names are flag_584 / flag_588 / value_476 /
    // flag_548; the roles below are inferred from how the latch and input timers use them.
    bool push_state = false;        // flag_584: the push window is open; clearing it releases the latch
    bool push_kick = false;         // flag_588: a push acceleration just started; sets the latch
    float pump_acceleration = 0.0f; // value_476: acceleration measure compared with pump_min_acceleration
    bool no_lag = false;            // flag_548 (and the bypass bit): follow with zero smoothing
};

class AnchorTracker {
public:
    void reset(const Vec3& position, float reference_height) noexcept {
        tracker_.reset({position[0], reference_height, position[2]});
        latch_time_ = input_time_ = smoothing_ = 0.0f;
        latched_ = false;
    }
    // Returns the tracked anchor position.
    const Vec3& update(float dt, const AnchorInput& in, const AnchorSettings& set) noexcept {
        if (!(dt > 0.0f) || !std::isfinite(dt) || !set.valid()) return tracker_.position();
        // latch_smoothing (82E04360): decay, set while latched, read the curve at 1 - time / hold.
        latch_time_ = std::max(0.0f, latch_time_ - dt);
        if (!in.push_state) latched_ = false;
        else if (in.push_kick) latched_ = true;
        if (latched_) latch_time_ = set.lag_hold_time;
        const float latch = clamp01(set.push_curve.evaluate(1.0f - latch_time_ / set.lag_hold_time)) * set.push_max_smoothing;
        // input_smoothing (82E04478): same, triggered by pump acceleration over the threshold.
        input_time_ = std::max(0.0f, input_time_ - dt);
        if (in.pump_acceleration > set.pump_min_acceleration) input_time_ = set.lag_hold_time;
        const float input = clamp01(set.pump_curve.evaluate(1.0f - input_time_ / set.lag_hold_time)) * set.pump_max_smoothing;
        // The larger of the two, faded out as the anchor speeds up (82E041B8).
        const float speed = length(in.velocity);
        const float fade = clamp01((set.lag_off_above_speed - speed) / (set.lag_off_above_speed - set.lag_full_below_speed));
        smoothing_ = in.no_lag ? 0.0f : std::max(latch, input) * fade;
        VectorTrackerSettings ts;
        ts.speed_clamp = set.speed_clamp;
        ts.acceleration_clamp = set.acceleration_clamp;
        ts.smoothing = smoothing_;
        return tracker_.update({in.position[0], in.reference_height, in.position[2]}, dt, ts);
    }
    const Vec3& position() const noexcept { return tracker_.position(); }
    const Vec3& velocity() const noexcept { return tracker_.velocity(); }
    const Vec3& acceleration() const noexcept { return tracker_.acceleration(); }
    const Vec3& target() const noexcept { return tracker_.target(); }
    float smoothing() const noexcept { return smoothing_; } // lag applied by the last update
    bool latched() const noexcept { return latched_; }

private:
    VectorTracker tracker_;
    float latch_time_ = 0.0f, input_time_ = 0.0f, smoothing_ = 0.0f;
    bool latched_ = false;
};

// ---------------------------------------------------------------- heading and elevation

// The tracker smoothing the rig derives from a shot's direction / elevation smoothing
// (manager_rig.rs bind_shot + rig_tracking.rs update_heading / update_elevation): with h = 1 - s the
// rig field is h * h, and the tracker is bound to 1 - h * h. 0 = take the whole step, 1 = hold.
// Per 1/60 s step, like every other smoothing constant here.
inline float rig_angle_smoothing(float shot_smoothing) noexcept {
    const float h = 1.0f - clamp01(shot_smoothing);
    return 1.0f - h * h;
}
inline constexpr float default_shot_smoothing = 0.8f; // Shot::new (s3_shot.h)

struct AngleRigSettings {
    AngleTrackerSettings tracker;      // smoothing_min/max here are ignored: they come from the shot (rig_angle_smoothing)
    float max_elevation_degrees = 80.0f; // elevation target clamp (rig_positioning.rs clamp_elevation)

    bool valid() const noexcept {
        return ::dingosdk::s3cam::valid(tracker) && std::isfinite(max_elevation_degrees) && max_elevation_degrees > 0.0f &&
               max_elevation_degrees < 90.0f;
    }

    static AngleRigSettings heading_defaults() {
        AngleRigSettings s; // TUNE: all values hand-picked
        s.tracker.delta_umbra_degrees = 3.0f;
        s.tracker.delta_penumbra_degrees = 40.0f;
        s.tracker.speed_clamp_degrees = 200.0f;
        s.tracker.acceleration_min_degrees = 400.0f;
        s.tracker.acceleration_max_degrees = 900.0f;
        return s;
    }
    static AngleRigSettings elevation_defaults() {
        AngleRigSettings s; // TUNE
        s.tracker.delta_umbra_degrees = 1.0f;
        s.tracker.delta_penumbra_degrees = 20.0f;
        s.tracker.speed_clamp_degrees = 60.0f;
        s.tracker.acceleration_min_degrees = 200.0f;
        s.tracker.acceleration_max_degrees = 400.0f;
        return s;
    }
};

struct HeadingInput {
    float target = 0.0f;       // radians, any turn count
    float offset = 0.0f;       // radians added on top of the tracked heading (stick offset)
    bool active = true;        // rig flags_517 bit 0x20: heading update enabled
    bool boost = false;        // heading_acceleration_state > 0: acceleration clamp doubled, update enabled
    float shot_smoothing = default_shot_smoothing; // the blended shot's smoothing[0] (direction), 0..1
};

class HeadingTracker {
public:
    void reset(float radians) noexcept { tracker_.reset(radians); }
    // The tracked heading plus offset (current_heading in rig_tracking.rs).
    float update(float dt, const HeadingInput& in, const AngleRigSettings& set) noexcept {
        offset_ = std::isfinite(in.offset) ? in.offset : 0.0f;
        if (!set.valid() || !(dt > 0.0f) || !std::isfinite(in.target)) return current();
        if (!in.active && !in.boost) return current();
        const float error = std::abs(wrap_angle(wrap_angle(in.target) - current()));
        // The shot sets the smoothing for a small error; it is capped at 0.8 for big errors, so the
        // camera hurries when it is far off and settles gently (82E03C18).
        const float base = rig_angle_smoothing(in.shot_smoothing);
        const float capped = std::min(base, 0.8f);
        const float quarter_turn = pi / 4;
        const float smoothing = error < quarter_turn ? base + (capped - base) * (error / quarter_turn) : capped;
        AngleTrackerSettings ts = set.tracker;
        ts.smoothing_min = ts.smoothing_max = clamp01(smoothing);
        if (in.boost) {
            ts.acceleration_min_degrees *= 2.0f;
            ts.acceleration_max_degrees *= 2.0f;
        }
        ts.overshoot_zeroes_velocity = false; // the heading carries its velocity through the target
        tracker_.update(in.target, dt, ts);
        return current();
    }
    float current() const noexcept { return wrap_angle(tracker_.position() + offset_); }
    float tracked() const noexcept { return tracker_.position(); }
    float velocity() const noexcept { return tracker_.velocity(); }

private:
    AngleTracker tracker_;
    float offset_ = 0.0f;
};

class ElevationTracker {
public:
    void reset(float radians) noexcept { tracker_.reset(radians); }
    // `shot_smoothing` is the blended shot's smoothing[1] (elevation), 0..1.
    float update(float dt, float target, const AngleRigSettings& set,
                 float shot_smoothing = default_shot_smoothing) noexcept {
        if (!set.valid() || !(dt > 0.0f) || !std::isfinite(target)) return tracker_.position();
        const float limit = set.max_elevation_degrees * degrees;
        AngleTrackerSettings ts = set.tracker;
        ts.smoothing_min = ts.smoothing_max = clamp01(rig_angle_smoothing(shot_smoothing));
        return tracker_.update(std::clamp(wrap_angle(target), -limit, limit), dt, ts);
    }
    float position() const noexcept { return tracker_.position(); }
    float velocity() const noexcept { return tracker_.velocity(); }

private:
    AngleTracker tracker_;
};

// ---------------------------------------------------------------- distance

struct DistanceParams {
    float speed_clamp = 6.0f;          // m/s
    float acceleration_clamp = 20.0f;  // m/s^2
    float smoothing = 0.0f;            // 0 = take the whole step, 1 = hold
};
struct DistanceSettings {
    DistanceParams normal{6.0f, 20.0f, 0.1f};   // camera_tracker "distance" SpeedClamp / AccelerationClampMax; TUNE
    DistanceParams fast{14.0f, 60.0f, 0.05f};   // FastSpeedClamp / FastAccelerationClampMax; TUNE
    float min_distance = 0.6f;          // MinDistance, m; TUNE
    float min_distance_wipeout = 0.3f;  // MinDistanceDuringWipeout, m; TUNE
    float near_distance = 1.05f;        // below this the acceleration clamp is raised (positioner.rs 0x3f866666)
    float near_acceleration = 100.0f;   // m/s^2 used below near_distance (positioner.rs)

    bool valid() const noexcept {
        const auto good = [](const DistanceParams& p) {
            return std::isfinite(p.speed_clamp) && p.speed_clamp > 0.0f && std::isfinite(p.acceleration_clamp) &&
                   p.acceleration_clamp > 0.0f && std::isfinite(p.smoothing) && p.smoothing >= 0.0f && p.smoothing <= 1.0f;
        };
        return good(normal) && good(fast) && std::isfinite(min_distance) && min_distance >= 0.0f &&
               std::isfinite(min_distance_wipeout) && min_distance_wipeout >= 0.0f && std::isfinite(near_distance) &&
               near_distance >= 0.0f && std::isfinite(near_acceleration) && near_acceleration > 0.0f;
    }
};
struct DistanceInput {
    float target = 2.0f;   // m, the shot's distance
    bool fast = false;     // use the fast parameter set (rig subject flag 668)
    bool wipeout = false;  // the minimum distance tightens (subject flag 548)
    bool snap = false;     // bypass_distance_tracker: jump to the target
};

class DistanceTracker {
public:
    void reset(float distance) noexcept { tracker_.reset(distance); }
    float update(float dt, const DistanceInput& in, const DistanceSettings& set) noexcept {
        if (!set.valid() || !(dt > 0.0f) || !std::isfinite(in.target)) return tracker_.position();
        const float minimum = in.wipeout ? set.min_distance_wipeout : set.min_distance;
        const float target = std::max(in.target, minimum);
        if (in.snap) {
            tracker_.reset(target);
            return tracker_.position();
        }
        const DistanceParams& p = in.fast ? set.fast : set.normal;
        ScalarTrackerSettings ts;
        ts.speed_clamp = p.speed_clamp;
        ts.acceleration_min = ts.acceleration_max = tracker_.position() < set.near_distance ? set.near_acceleration : p.acceleration_clamp;
        ts.smoothing_min = ts.smoothing_max = p.smoothing;
        return tracker_.update(target, dt, ts);
    }
    float position() const noexcept { return tracker_.position(); }
    float velocity() const noexcept { return tracker_.velocity(); }

private:
    ScalarTracker tracker_;
};

// ---------------------------------------------------------------- compass

// Heading of a direction: 0 along +Z, growing toward -X. A direction pointing straight up has no
// heading and gives 0 (compass.rs heading).
inline float heading_of(const Vec3& direction) noexcept {
    if (direction[1] > 0.99999f) return 0.0f;
    return std::atan2(-direction[0], direction[2]);
}

struct CompassSettings {
    float heading_response = 0.08f;     // HeadingChangeResponseSpeed: share of the gap closed per 1/60 s while moving; TUNE
    float time_before_lineup = 1.5f;    // TimeBeforeAutoLineup, s; TUNE
    float lineup_speed = 0.03f;         // AutoLineupSpeed: share of the gap closed per 1/60 s once lining up; TUNE
    float stopped_speed = 0.5f;         // m/s. Slower than this counts as stopped (compass_movement.rs)
    float min_deadzone_speed = 1.0f;    // m/s. At or below it the dead-zone is full size
    float max_deadzone_speed = 6.0f;    // m/s. At or above it the dead-zone is gone
    float max_deadzone_size = 0.3f;     // m, the dead-zone radius at low speed; TUNE
    float deadzone_smoothing = 0.9f;    // 0..1, how slowly the dead-zone radius changes per 1/60 s step (the fixed step); TUNE

    bool valid() const noexcept {
        const auto frac = [](float v) { return std::isfinite(v) && v >= 0.0f && v <= 1.0f; };
        return frac(heading_response) && frac(lineup_speed) && frac(deadzone_smoothing) &&
               std::isfinite(time_before_lineup) && time_before_lineup >= 0.0f && std::isfinite(stopped_speed) &&
               stopped_speed >= 0.0f && std::isfinite(min_deadzone_speed) && min_deadzone_speed >= 0.0f &&
               std::isfinite(max_deadzone_speed) && max_deadzone_speed > min_deadzone_speed &&
               std::isfinite(max_deadzone_size) && max_deadzone_size >= 0.0f;
    }
};

struct CompassInput {
    Vec3 position{0, 0, 0};        // subject root position
    Vec3 forward{0, 0, 1};         // subject forward (entity row 2)
    Vec3 grind_direction{0, 0, 1}; // rail direction, used while grinding
    bool grinding = false;
    bool wiping_out = false;       // keeps the stopped timer at zero
    bool crouching = false;        // physics state 103: no auto-lineup
    bool reset = false;            // teleport / respawn
};

// The movement compass: heading follows the dead-zoned travel direction while moving and lines up
// behind the subject's forward once it has been stopped for time_before_lineup (Compass::update_movement).
class Compass {
public:
    void reset(const Vec3& position, const Vec3& forward) noexcept {
        *this = Compass{};
        previous_position_ = position;
        deadzone_position_ = {position[0], position[2]};
        heading_ = heading_of(forward);
        initialized_ = true;
    }
    float update(float dt, const CompassInput& in, const CompassSettings& set) noexcept {
        if (!(dt > 0.0f) || !std::isfinite(dt) || !set.valid() || !finite3(in.position) || !finite3(in.forward))
            return heading_;
        if (in.reset || !initialized_) {
            reset(in.position, in.forward);
            return heading_;
        }
        velocity_ = scale(sub(in.position, previous_position_), 1.0f / dt);
        const float speed = length({velocity_[0], 0.0f, velocity_[2]});
        const float gap = set.max_deadzone_speed - set.min_deadzone_speed;
        const float fraction = clamp01((speed - set.max_deadzone_speed) / -gap);
        deadzone_size_ += (fraction * set.max_deadzone_size - deadzone_size_) * (1.0f - set.deadzone_smoothing);
        update_deadzone(dt, in.position[0], in.position[2]);
        previous_position_ = in.position;

        if (in.grinding) {
            heading_ = heading_of(in.grind_direction);
            return heading_;
        }
        stopped_time_ = in.wiping_out || speed > set.stopped_speed ? 0.0f : stopped_time_ + dt;
        if (speed > set.stopped_speed) {
            const Vec3 travel = normalized(damped_velocity_);
            if (length(travel) > 0.0f)
                heading_ = blend_angle(heading_, heading_of(travel), set.heading_response); // per 1/60 s step
        } else if (!in.crouching && stopped_time_ >= set.time_before_lineup) {
            heading_ = blend_angle(heading_, heading_of(in.forward), set.lineup_speed); // per 1/60 s step
        }
        return heading_;
    }
    float heading() const noexcept { return heading_; }
    float stopped_time() const noexcept { return stopped_time_; }
    float deadzone_size() const noexcept { return deadzone_size_; }

private:
    static bool finite3(const Vec3& v) noexcept { return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]); }
    // compass_movement.rs update_deadzone: the point trails the subject, staying within the radius.
    void update_deadzone(float dt, float x, float z) noexcept {
        const float old_x = deadzone_position_[0], old_z = deadzone_position_[1];
        const float dx = x - old_x, dz = z - old_z;
        const float distance = std::sqrt(dx * dx + dz * dz);
        if (distance > deadzone_size_ && distance > 0.0f) {
            const float move = (distance - deadzone_size_) / distance;
            deadzone_position_ = {old_x + dx * move, old_z + dz * move};
        }
        damped_velocity_ = {(deadzone_position_[0] - old_x) / dt, 0.0f, (deadzone_position_[1] - old_z) / dt};
    }

    float heading_ = 0.0f;
    Vec3 velocity_{0, 0, 0}, damped_velocity_{0, 0, 0}, previous_position_{0, 0, 0};
    std::array<float, 2> deadzone_position_{0, 0};
    float deadzone_size_ = 0.0f, stopped_time_ = 0.0f;
    bool initialized_ = false;
};

// ---------------------------------------------------------------- the rig

struct RigSettings {
    AnchorSettings anchor;
    AngleRigSettings heading = AngleRigSettings::heading_defaults();
    AngleRigSettings elevation = AngleRigSettings::elevation_defaults();
    DistanceSettings distance;
    CompassSettings compass;

    bool valid() const noexcept {
        return anchor.valid() && heading.valid() && elevation.valid() && distance.valid() && compass.valid();
    }
};

struct RigInput {
    AnchorInput anchor;
    CompassInput compass;
    // Heading target = compass heading + shot_heading when heading_from_compass (shot position
    // heading, pi = behind the subject), else heading_target as given.
    bool heading_from_compass = true;
    float shot_heading = pi;
    float heading_target = 0.0f;
    float heading_offset = 0.0f;
    bool heading_active = true;
    bool heading_boost = false;
    float heading_smoothing = default_shot_smoothing;   // the blended shot's smoothing[0] (direction)
    float elevation_target = 0.0f; // radians
    float elevation_smoothing = default_shot_smoothing; // the blended shot's smoothing[1] (elevation)
    DistanceInput distance;
};

struct RigOutput {
    Vec3 anchor{0, 0, 0};
    float heading = 0.0f;     // radians
    float elevation = 0.0f;   // radians
    float distance = 0.0f;    // m
    float compass_heading = 0.0f;
    float anchor_lag = 0.0f;  // m, how far the anchor trails its target this step
};

class Rig {
public:
    // Teleport / respawn / take ownership: everything lands on this frame's targets with zero velocity.
    void reset(const RigInput& in, const RigSettings& set) noexcept {
        compass_.reset(in.compass.position, in.compass.forward);
        anchor_.reset(in.anchor.position, in.anchor.reference_height);
        heading_.reset(resolve_heading(in));
        elevation_.reset(std::clamp(wrap_angle(in.elevation_target), -set.elevation.max_elevation_degrees * degrees,
                                    set.elevation.max_elevation_degrees * degrees));
        distance_.reset(std::max(in.distance.target, in.distance.wipeout ? set.distance.min_distance_wipeout : set.distance.min_distance));
    }

    // One fixed step (pass rig_step). Order follows the Rust rig: compass, anchor, heading,
    // elevation, distance. Invalid settings or dt leave everything as it was.
    RigOutput update(float dt, const RigInput& in, const RigSettings& set) noexcept {
        if (set.valid() && dt > 0.0f && std::isfinite(dt)) {
            compass_.update(dt, in.compass, set.compass);
            anchor_.update(dt, in.anchor, set.anchor);
            HeadingInput h;
            h.target = resolve_heading(in);
            h.offset = in.heading_offset;
            h.active = in.heading_active;
            h.boost = in.heading_boost;
            h.shot_smoothing = in.heading_smoothing;
            heading_.update(dt, h, set.heading);
            elevation_.update(dt, in.elevation_target, set.elevation, in.elevation_smoothing);
            distance_.update(dt, in.distance, set.distance);
        }
        RigOutput out;
        out.anchor = anchor_.position();
        out.heading = heading_.current();
        out.elevation = elevation_.position();
        out.distance = distance_.position();
        out.compass_heading = compass_.heading();
        out.anchor_lag = length(sub(anchor_.target(), anchor_.position()));
        return out;
    }

    const AnchorTracker& anchor() const noexcept { return anchor_; }
    const HeadingTracker& heading() const noexcept { return heading_; }
    const ElevationTracker& elevation() const noexcept { return elevation_; }
    const DistanceTracker& distance() const noexcept { return distance_; }
    const Compass& compass() const noexcept { return compass_; }

private:
    float resolve_heading(const RigInput& in) const noexcept {
        return in.heading_from_compass ? wrap_angle(compass_.heading() + in.shot_heading) : in.heading_target;
    }
    AnchorTracker anchor_;
    HeadingTracker heading_;
    ElevationTracker elevation_;
    DistanceTracker distance_;
    Compass compass_;
};

} // namespace dingosdk::s3cam
