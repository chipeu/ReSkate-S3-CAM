#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/tracker.rs (ScalarTracker::update, interpolate),
// angle_tracker.rs (AngleTracker::update) and rig_tracking.rs (bind_angle_settings: degrees ->
// radians). Semantics are ported; the bit-exact VMX constants and fused multiply-adds are replaced
// by ordinary float arithmetic (CLAUDE.md hard rule 6).
#include "Engine/Game/Camera/s3_math.h"

#include <cmath>

// Skate 3's critically-damped-like follower. Each update works out the acceleration that would hit
// the target this step, clamps it (only while it pushes toward the target), clamps the speed, then
// moves the position by the smoothed step. The clamps and smoothing widen/narrow with the error:
// inside the umbra the "max" values apply, past the penumbra the "min" values, with a linear ramp
// between. Run it on the camera's fixed step (CLAUDE.md hard rule 5), not on raw frame dt.
namespace dingosdk::s3cam {

// Effective tracker parameters (ScalarTrackerParameters). Units are the tracked quantity's own
// (metres for ScalarTracker); AngleTracker::Settings uses degrees instead.
struct ScalarTrackerSettings {
    float delta_umbra = 0.0f;       // error below this: full "max" response (fraction 1)
    float delta_penumbra = 1.0f;    // error above this: full "min" response (fraction 0)
    float speed_clamp = 10.0f;      // units / s
    float acceleration_min = 20.0f; // units / s^2, used far from the target
    float acceleration_max = 20.0f; // units / s^2, used inside the umbra
    float smoothing_min = 0.0f;     // 0 = take the whole step, 1 = hold; far from the target
    float smoothing_max = 0.0f;     // inside the umbra
    bool overshoot_zeroes_velocity = true; // drop velocity that points away from the target
};

// Angle settings in degrees, as rig_tracking.rs AngleTrackingSettings stores them; converted to
// radians on use. Smoothing has no unit.
struct AngleTrackerSettings {
    float delta_umbra_degrees = 0.0f;
    float delta_penumbra_degrees = 30.0f;
    float speed_clamp_degrees = 360.0f;           // degrees / s
    float acceleration_min_degrees = 720.0f;      // degrees / s^2
    float acceleration_max_degrees = 720.0f;      // degrees / s^2
    float smoothing_min = 0.0f;
    float smoothing_max = 0.0f;
    bool overshoot_zeroes_velocity = true;
};

namespace tracker_detail {
inline bool finite_in(float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; }
inline bool ordered(float umbra, float penumbra, float speed, float acc_min, float acc_max, float s_min, float s_max) {
    constexpr float big = 1.0e9f;
    return finite_in(umbra, 0.0f, big) && finite_in(penumbra, umbra, big) && finite_in(speed, 1e-6f, big) &&
           finite_in(acc_min, 0.0f, big) && finite_in(acc_max, 0.0f, big) && finite_in(s_min, 0.0f, 1.0f) &&
           finite_in(s_max, 0.0f, 1.0f);
}
// tracker.rs interpolate: min + (max - min) * fraction.
inline float mix(float minimum, float maximum, float fraction) {
    return minimum == maximum ? maximum : minimum + (maximum - minimum) * fraction;
}
// 1 inside the umbra, 0 past the penumbra, linear between (tracker.rs update).
inline float fraction_for(float absolute_delta, float umbra, float penumbra) {
    if (absolute_delta < umbra) return 1.0f;
    if (absolute_delta < penumbra) return 1.0f - (absolute_delta - umbra) / (penumbra - umbra);
    return 0.0f;
}
} // namespace tracker_detail

inline bool valid(const ScalarTrackerSettings& s) {
    return tracker_detail::ordered(s.delta_umbra, s.delta_penumbra, s.speed_clamp, s.acceleration_min,
                                   s.acceleration_max, s.smoothing_min, s.smoothing_max);
}
inline bool valid(const AngleTrackerSettings& s) {
    return tracker_detail::ordered(s.delta_umbra_degrees, s.delta_penumbra_degrees, s.speed_clamp_degrees,
                                   s.acceleration_min_degrees, s.acceleration_max_degrees, s.smoothing_min,
                                   s.smoothing_max) &&
           s.delta_penumbra_degrees <= 180.0f; // the wrapped error never exceeds 180 degrees
}

namespace tracker_detail {
struct State {
    float target = 0.0f, position = 0.0f, velocity = 0.0f, acceleration = 0.0f;
    float acceleration_clamp = 0.0f, smoothing = 0.0f;
};
// Shared body of tracker.rs ScalarTracker::update and angle_tracker.rs AngleTracker::update; they
// differ only in wrapping the error and the position. Returns false (state untouched) on a
// non-positive/non-finite dt or non-finite target, which the Rust does not guard.
template <bool Wrap>
inline bool step(State& s, float target, float dt, float umbra, float penumbra, float speed_clamp, float acc_min,
                 float acc_max, float smoothing_min, float smoothing_max, bool overshoot_zeroes) {
    if (!(dt > 0.0f) || !std::isfinite(dt) || !std::isfinite(target)) return false;
    const float position = s.position;
    const float delta = Wrap ? wrap_angle(target - position) : target - position;
    s.target = target;
    // Multiplying keeps the sign of zero like the native code; the value is 0 either way.
    if (overshoot_zeroes && s.velocity * delta < 0.0f) s.velocity = 0.0f;
    const float velocity = s.velocity;
    // The acceleration that would land on the target this step.
    s.acceleration = ((delta / dt) - velocity) / dt;
    const float fraction = fraction_for(std::abs(delta), umbra, penumbra);
    // Only acceleration toward the target is clamped; braking is never limited.
    if (s.acceleration * delta > 0.0f) {
        const float limit = mix(acc_min, acc_max, fraction);
        s.acceleration_clamp = limit;
        const float magnitude = std::abs(s.acceleration);
        if (magnitude > limit) s.acceleration = (s.acceleration / magnitude) * limit;
    }
    s.velocity = velocity + s.acceleration * dt;
    const float speed = std::abs(s.velocity);
    if (speed > speed_clamp) s.velocity = (s.velocity / speed) * speed_clamp;
    s.smoothing = mix(smoothing_min, smoothing_max, fraction);
    // Smoothing shortens the position step only; velocity is not derived back from it.
    if constexpr (Wrap) {
        const float next = wrap_angle(wrap_angle(s.velocity * dt) + position);
        const float displacement = wrap_angle(next - position);
        s.position = wrap_angle(wrap_angle(displacement * (1.0f - s.smoothing)) + position);
    } else {
        const float step_length = s.velocity * dt;
        s.position = position + step_length * (1.0f - s.smoothing);
    }
    return true;
}
} // namespace tracker_detail

class ScalarTracker {
public:
    using Settings = ScalarTrackerSettings;

    // Jump to `value` with no motion (a camera cut). Non-finite values are ignored.
    void reset(float value) noexcept {
        if (!std::isfinite(value)) return;
        s_ = {};
        s_.target = s_.position = value;
    }
    void snap(float value) noexcept { reset(value); }
    // Jump to `value` but keep the current velocity (rig_tracking.rs reset_* with clear_motion=false).
    void snap_keep_motion(float value) noexcept {
        if (!std::isfinite(value)) return;
        s_.target = s_.position = value;
    }

    // Returns the new position. A bad dt/target or invalid settings leaves the tracker unchanged.
    float update(float target, float dt, const Settings& set) noexcept {
        if (valid(set))
            tracker_detail::step<false>(s_, target, dt, set.delta_umbra, set.delta_penumbra, set.speed_clamp,
                                        set.acceleration_min, set.acceleration_max, set.smoothing_min,
                                        set.smoothing_max, set.overshoot_zeroes_velocity);
        return s_.position;
    }

    float position() const noexcept { return s_.position; }
    float velocity() const noexcept { return s_.velocity; }
    float target() const noexcept { return s_.target; }
    float acceleration() const noexcept { return s_.acceleration; }
    float acceleration_clamp() const noexcept { return s_.acceleration_clamp; }
    float smoothing() const noexcept { return s_.smoothing; } // smoothing used by the last update

private:
    tracker_detail::State s_{};
};

// Radians throughout the state; position stays in [-pi, pi) and the error takes the short way round.
class AngleTracker {
public:
    using Settings = AngleTrackerSettings;

    void reset(float radians) noexcept {
        if (!std::isfinite(radians)) return;
        s_ = {};
        s_.target = s_.position = wrap_angle(radians);
    }
    void snap(float radians) noexcept { reset(radians); }
    void snap_keep_motion(float radians) noexcept {
        if (!std::isfinite(radians)) return;
        s_.target = s_.position = wrap_angle(radians);
    }

    // `target` in radians (any turn count; it is wrapped). Returns the new position.
    float update(float target, float dt, const Settings& set) noexcept {
        if (valid(set))
            tracker_detail::step<true>(s_, wrap_angle(target), dt, set.delta_umbra_degrees * degrees,
                                       set.delta_penumbra_degrees * degrees, set.speed_clamp_degrees * degrees,
                                       set.acceleration_min_degrees * degrees,
                                       set.acceleration_max_degrees * degrees, set.smoothing_min,
                                       set.smoothing_max, set.overshoot_zeroes_velocity);
        return s_.position;
    }

    float position() const noexcept { return s_.position; }
    float velocity() const noexcept { return s_.velocity; }
    float target() const noexcept { return s_.target; }
    float acceleration() const noexcept { return s_.acceleration; }
    float acceleration_clamp() const noexcept { return s_.acceleration_clamp; }
    float smoothing() const noexcept { return s_.smoothing; }

private:
    tracker_detail::State s_{};
};
} // namespace dingosdk::s3cam
