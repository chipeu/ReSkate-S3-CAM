#include "Engine/Game/Camera/s3_tracker.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string_view>

// s3_tracker.h: scalar and angle trackers against the Rust tracker.rs / angle_tracker.rs semantics.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-5f) { return std::abs(a - b) <= tolerance; }

ScalarTracker::Settings base() {
    ScalarTracker::Settings s;
    s.delta_umbra = 0.1f;
    s.delta_penumbra = 1.0f;
    s.speed_clamp = 4.0f;
    s.acceleration_min = 10.0f;
    s.acceleration_max = 40.0f;
    s.smoothing_min = 0.2f;
    s.smoothing_max = 0.6f;
    return s;
}

void convergence() {
    const float dt = fixed_step;
    ScalarTracker t;
    t.reset(0);
    const auto s = base(); // overshoot_zeroes_velocity is on
    float peak = 0;
    for (int i = 0; i < 2000; ++i) peak = std::max(peak, t.update(5.0f, dt, s));
    expect(near(t.position(), 5.0f, 1e-3f), "converges on the target");
    expect(peak <= 5.0f + 1e-4f, "no overshoot with overshoot_zeroes_velocity");
    // A moving target reversed mid-flight must not carry velocity past it.
    ScalarTracker u;
    u.reset(0);
    for (int i = 0; i < 60; ++i) u.update(5.0f, dt, s);
    expect(u.position() > 1.5f && u.velocity() > 0, "moving past the new target before the reversal");
    float low = u.position();
    for (int i = 0; i < 2000; ++i) low = std::min(low, u.update(1.0f, dt, s));
    expect(low >= 1.0f - 1e-3f, "reversal does not undershoot");
    expect(near(u.position(), 1.0f, 1e-3f), "reversal converges");
}

void clamps() {
    const float dt = fixed_step;
    ScalarTracker t;
    t.reset(0);
    auto s = base();
    s.smoothing_min = s.smoothing_max = 0.0f;
    float max_speed = 0, max_accel = 0, last_v = 0;
    for (int i = 0; i < 400; ++i) {
        t.update(100.0f, dt, s); // far away: penumbra exceeded, min acceleration applies
        max_speed = std::max(max_speed, std::abs(t.velocity()));
        max_accel = std::max(max_accel, std::abs((t.velocity() - last_v) / dt));
        last_v = t.velocity();
    }
    expect(max_speed <= s.speed_clamp + 1e-4f, "speed never exceeds the clamp");
    expect(near(max_speed, s.speed_clamp, 1e-3f), "speed reaches the clamp on a long run");
    expect(max_accel <= s.acceleration_min + 1e-2f, "acceleration never exceeds the far (min) clamp");
    expect(near(t.acceleration_clamp(), s.acceleration_min), "far from target the min acceleration clamp is used");
    // Braking is unclamped: the decelerating step may exceed the acceleration limit.
    ScalarTracker b;
    b.reset(0);
    for (int i = 0; i < 200; ++i) b.update(100.0f, dt, s);
    const float v0 = b.velocity();
    b.update(b.position() + 0.0f, dt, s); // target jumps onto the position
    expect(std::abs(b.velocity()) < v0 * 0.01f, "braking toward the target is not acceleration-limited");
}

void umbra_penumbra() {
    const float dt = fixed_step;
    const auto s = base();
    ScalarTracker inside;
    inside.reset(0);
    inside.update(0.05f, dt, s); // error < umbra: fraction 1 -> the "max" end of every pair
    expect(near(inside.smoothing(), s.smoothing_max), "inside the umbra uses the max (fraction 1) smoothing");
    expect(near(inside.acceleration_clamp(), s.acceleration_max), "inside the umbra uses the max acceleration clamp");
    ScalarTracker outside;
    outside.reset(0);
    outside.update(3.0f, dt, s);
    expect(near(outside.smoothing(), s.smoothing_min), "past the penumbra uses the min smoothing");
    expect(near(outside.acceleration_clamp(), s.acceleration_min), "past the penumbra uses the min acceleration clamp");
    ScalarTracker mid;
    mid.reset(0);
    mid.update(0.55f, dt, s); // halfway between umbra 0.1 and penumbra 1.0 -> fraction 0.5
    expect(near(mid.smoothing(), 0.4f, 1e-4f), "inside the penumbra smoothing ramps linearly");
    expect(near(mid.acceleration_clamp(), 25.0f, 1e-3f), "inside the penumbra the clamp ramps linearly");
    // Equal min/max ignores the fraction (tracker.rs interpolate).
    auto flat = base();
    flat.smoothing_min = flat.smoothing_max = 0.3f;
    ScalarTracker f;
    f.reset(0);
    f.update(0.55f, dt, flat);
    expect(near(f.smoothing(), 0.3f), "equal min and max give that value");
}

void angle_wrapping() {
    const float dt = fixed_step;
    AngleTracker::Settings s;
    s.speed_clamp_degrees = 720;
    s.acceleration_min_degrees = s.acceleration_max_degrees = 5000;
    s.delta_penumbra_degrees = 20;
    AngleTracker t;
    t.reset(170 * degrees);
    float crossed_far = 0; // furthest the position strays from +-180 while crossing
    for (int i = 0; i < 600; ++i) {
        const float p = t.update(-170 * degrees, dt, s);
        expect(p >= -pi && p < pi, "position stays in [-pi, pi)");
        crossed_far = std::max(crossed_far, pi - std::abs(p));
    }
    expect(crossed_far < 15 * degrees, "170 -> -170 goes the short way, through 180");
    expect(near(t.position(), -170 * degrees, 1e-3f), "converges across the wrap");
    // Target given as more than one turn is wrapped; no spin.
    AngleTracker u;
    u.reset(0);
    for (int i = 0; i < 600; ++i) u.update(tau + 0.5f, dt, s);
    expect(near(u.position(), 0.5f, 1e-3f), "target of 2pi + 0.5 settles at 0.5");
    // Exactly opposite target: the error wraps to -pi, and the tracker still converges.
    AngleTracker v;
    v.reset(0);
    for (int i = 0; i < 1200; ++i) v.update(pi, dt, s);
    expect(near(std::abs(v.position()), pi, 1e-3f), "converges on a target 180 degrees away");
    // Degrees settings are converted: a 90 deg/s clamp moves ~pi/2 rad in a second.
    AngleTracker w;
    w.reset(0);
    AngleTracker::Settings slow;
    slow.speed_clamp_degrees = 90;
    slow.acceleration_min_degrees = slow.acceleration_max_degrees = 100000;
    slow.delta_penumbra_degrees = 10;
    for (int i = 0; i < 60; ++i) w.update(pi - 0.01f, dt, slow);
    expect(near(w.position(), 90 * degrees, 0.05f), "speed clamp is in degrees per second");
}

void dt_stability() {
    const float dts[] = {1.0f / 30, 1.0f / 60, 1.0f / 120, 1.0f / 240};
    for (const float dt : dts) {
        const int steps = static_cast<int>(6.0f / dt);
        ScalarTracker t;
        t.reset(0);
        const auto s = base();
        float peak = 0;
        bool finite = true;
        for (int i = 0; i < steps; ++i) {
            peak = std::max(peak, t.update(5.0f, dt, s));
            finite = finite && std::isfinite(t.position()) && std::isfinite(t.velocity());
        }
        expect(finite, "state stays finite");
        expect(peak <= 5.0f + 1e-3f, "no overshoot at any step size");
        expect(near(t.position(), 5.0f, 5e-3f), "converges at any step size");
        expect(std::abs(t.velocity()) <= s.speed_clamp + 1e-4f, "speed clamp holds at any step size");

        AngleTracker a;
        a.reset(0);
        AngleTracker::Settings as;
        as.delta_penumbra_degrees = 45;
        as.smoothing_max = 0.5f;
        float apeak = 0;
        for (int i = 0; i < steps; ++i) apeak = std::max(apeak, a.update(1.0f, dt, as));
        expect(apeak <= 1.0f + 1e-3f && near(a.position(), 1.0f, 5e-3f), "angle tracker stable at any step size");
    }
}

void resets() {
    ScalarTracker t;
    const auto s = base();
    t.reset(2);
    for (int i = 0; i < 30; ++i) t.update(9, 1.0f / 60, s);
    expect(t.velocity() > 0, "moving before reset");
    t.reset(-3);
    expect(t.position() == -3 && t.target() == -3, "reset sets position and target");
    expect(t.velocity() == 0 && t.acceleration() == 0, "reset clears motion");
    for (int i = 0; i < 30; ++i) t.update(9, 1.0f / 60, s);
    const float v = t.velocity();
    t.snap_keep_motion(0);
    expect(t.position() == 0 && t.velocity() == v, "snap_keep_motion keeps velocity");
    t.reset(NAN);
    expect(t.position() == 0, "non-finite reset is ignored");
    const float before = t.position();
    t.update(NAN, 1.0f / 60, s);
    t.update(1, 0.0f, s);
    t.update(1, -1.0f, s);
    expect(t.position() == before && t.velocity() == v, "bad target or dt leaves the state alone");

    AngleTracker a;
    a.reset(3 * pi / 2);
    expect(near(a.position(), -pi / 2), "angle reset wraps");
}

void invalid_settings() {
    expect(valid(base()), "default-ish settings are valid");
    auto s = base();
    s.speed_clamp = NAN;
    expect(!valid(s), "NaN speed clamp rejected");
    s = base();
    s.speed_clamp = 0;
    expect(!valid(s), "zero speed clamp rejected");
    s = base();
    s.delta_penumbra = 0.05f;
    expect(!valid(s), "penumbra below umbra rejected");
    s = base();
    s.delta_umbra = -1;
    expect(!valid(s), "negative umbra rejected");
    s = base();
    s.smoothing_max = 1.5f;
    expect(!valid(s), "smoothing above 1 rejected");
    s = base();
    s.acceleration_min = INFINITY;
    expect(!valid(s), "infinite acceleration rejected");
    AngleTracker::Settings a;
    expect(valid(a), "default angle settings valid");
    a.delta_penumbra_degrees = 270;
    expect(!valid(a), "angle penumbra above 180 rejected");
    a = {};
    a.acceleration_max_degrees = -5;
    expect(!valid(a), "negative angle acceleration rejected");

    ScalarTracker t;
    t.reset(1);
    s = base();
    s.speed_clamp = NAN;
    t.update(5, 1.0f / 60, s);
    expect(t.position() == 1 && t.velocity() == 0, "update with invalid settings does nothing");
}
} // namespace

int main() {
    convergence();
    clamps();
    umbra_penumbra();
    angle_wrapping();
    dt_stability();
    resets();
    invalid_settings();
    if (failures == 0) std::printf("s3cam_tracker_tests: all passed\n");
    return failures == 0 ? 0 : 1;
}
