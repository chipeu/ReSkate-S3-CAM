#include "Engine/Game/Camera/s3_rig.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string_view>

// s3_rig.h: anchor push/pump lag, heading/elevation/distance trackers, compass lineup and reset.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-4f) { return std::abs(a - b) <= tolerance; }

constexpr float dt = rig_step;

void lag_curve() {
    LagCurve c;
    expect(c.valid(), "default curve is valid");
    expect(near(c.evaluate(-1.0f), c.y[0]) && near(c.evaluate(5.0f), c.y[7]), "curve clamps outside its range");
    expect(near(c.evaluate(0.075f), 0.5f * (c.y[0] + c.y[1])), "curve is linear between points");
    LagCurve bad = c;
    bad.x[3] = 0.1f;
    expect(!bad.valid(), "descending x is invalid");
    expect(AnchorSettings{}.valid(), "default anchor settings are valid");
}

// Runs the anchor on a target moving at `speed` m/s along +X. `push_until` seconds of push.
struct LagRun {
    float lag_early = 0.0f, lag_peak = 0.0f, lag_late = 0.0f;
};
LagRun run_push(float speed, float push_seconds, const AnchorSettings& set) {
    AnchorTracker a;
    a.reset({0, 0, 0}, 0.0f);
    LagRun r;
    for (int i = 1; i <= 480; ++i) { // 4 s
        const float t = static_cast<float>(i) * dt;
        AnchorInput in;
        in.position = {speed * t, 0, 0};
        in.velocity = {speed, 0, 0};
        in.push_state = t <= push_seconds;
        in.push_kick = i == 1;
        a.update(dt, in, set);
        const float lag = in.position[0] - a.position()[0];
        r.lag_peak = std::max(r.lag_peak, lag);
        if (i == 24) r.lag_early = lag; // 0.2 s in
        if (i == 480) r.lag_late = lag;
    }
    return r;
}

void push_lags_then_catches_up() {
    AnchorSettings set;
    set.push_max_smoothing = 0.8f;
    const LagRun pushed = run_push(3.0f, 0.4f, set);
    AnchorSettings none = set;
    none.push_max_smoothing = 0.0f;
    const LagRun plain = run_push(3.0f, 0.4f, none);
    expect(pushed.lag_early > plain.lag_early * 3.0f, "a push makes the anchor trail the subject");
    expect(pushed.lag_peak > plain.lag_peak * 3.0f, "peak push lag is well above the unlatched lag");
    expect(pushed.lag_late < plain.lag_late + 0.01f, "the anchor catches up once the latch decays");
    expect(pushed.lag_late < pushed.lag_peak * 0.3f, "late lag is a small share of the peak");

    // Latch bookkeeping: held while push_state stays up, released when it drops.
    AnchorTracker a;
    a.reset({0, 0, 0}, 0.0f);
    AnchorInput in;
    in.push_state = in.push_kick = true;
    a.update(dt, in, set);
    in.push_kick = false;
    a.update(dt, in, set);
    expect(a.latched(), "latch stays set while the push window is open");
    in.push_state = false;
    a.update(dt, in, set);
    expect(!a.latched(), "latch releases with the push window");
}

void pump_and_fade() {
    AnchorSettings set;
    AnchorTracker a;
    a.reset({0, 0, 0}, 0.0f);
    AnchorInput in;
    in.pump_acceleration = set.pump_min_acceleration - 0.1f;
    a.update(dt, in, set);
    expect(near(a.smoothing(), 0.0f), "pump below the threshold gives no lag");
    in.pump_acceleration = set.pump_min_acceleration + 1.0f;
    a.update(dt, in, set);
    expect(near(a.smoothing(), set.pump_curve.y[0] * set.pump_max_smoothing), "pump above the threshold lags at the curve start");
    in.velocity = {set.lag_off_above_speed + 1.0f, 0, 0};
    a.update(dt, in, set);
    expect(near(a.smoothing(), 0.0f), "lag fades out at speed");
    in.velocity = {0.5f * (set.lag_full_below_speed + set.lag_off_above_speed), 0, 0};
    a.update(dt, in, set);
    const float full = set.pump_curve.evaluate(0.0f) * set.pump_max_smoothing;
    expect(a.smoothing() > 0.0f && a.smoothing() < full + 1e-4f, "lag is partial between the fade speeds");
    in.no_lag = true;
    a.update(dt, in, set);
    expect(near(a.smoothing(), 0.0f), "no_lag forces zero smoothing");

    // The anchor follows the reference height, not the subject's Y.
    AnchorTracker b;
    b.reset({0, 0, 0}, 1.0f);
    AnchorInput up;
    up.position = {0, 5.0f, 0};
    up.reference_height = 1.0f;
    for (int i = 0; i < 120; ++i) b.update(dt, up, set);
    expect(near(b.position()[1], 1.0f), "anchor Y is the reference height");
}

void heading_tracker() {
    const AngleRigSettings set = AngleRigSettings::heading_defaults();
    expect(set.valid(), "heading defaults are valid");
    HeadingTracker h;
    h.reset(0.0f);
    HeadingInput in;
    in.target = 90.0f * degrees;
    for (int i = 0; i < 600; ++i) h.update(dt, in, set);
    expect(near(h.current(), in.target, 0.01f), "heading converges on its target");

    // Takes the short way across +-pi.
    HeadingTracker w;
    w.reset(170.0f * degrees);
    HeadingInput across;
    across.target = -170.0f * degrees;
    float widest = 0.0f;
    for (int i = 0; i < 60; ++i) {
        w.update(dt, across, set);
        widest = std::max(widest, std::abs(wrap_angle(w.current() - 180.0f * degrees)));
    }
    expect(widest < 30.0f * degrees, "heading crosses +-pi the short way");

    // Boost doubles the acceleration clamp, so it covers more ground early.
    HeadingTracker slow, fast;
    slow.reset(0.0f);
    fast.reset(0.0f);
    HeadingInput go;
    go.target = 120.0f * degrees;
    HeadingInput go_boost = go;
    go_boost.boost = true;
    for (int i = 0; i < 12; ++i) {
        slow.update(dt, go, set);
        fast.update(dt, go_boost, set);
    }
    expect(fast.current() > slow.current() * 1.2f, "boost raises the heading's acceleration");

    // Inactive without boost: frozen. The offset still applies.
    HeadingTracker idle;
    idle.reset(0.0f);
    HeadingInput off;
    off.target = 1.0f;
    off.active = false;
    off.offset = 0.25f;
    for (int i = 0; i < 60; ++i) idle.update(dt, off, set);
    expect(near(idle.tracked(), 0.0f) && near(idle.current(), 0.25f), "inactive heading holds; offset is added");
    AngleRigSettings bad = set;
    bad.avoidance_smoothing = 2.0f;
    expect(!bad.valid(), "avoidance smoothing above 1 is invalid");
}

void elevation_tracker() {
    const AngleRigSettings set = AngleRigSettings::elevation_defaults();
    ElevationTracker e;
    e.reset(0.0f);
    for (int i = 0; i < 600; ++i) e.update(dt, 10.0f * degrees, set);
    expect(near(e.position(), 10.0f * degrees, 0.01f), "elevation converges");
    for (int i = 0; i < 1200; ++i) e.update(dt, 89.0f * degrees, set);
    expect(e.position() <= set.max_elevation_degrees * degrees + 1e-4f, "elevation target is clamped to the limit");
    expect(e.position() > 70.0f * degrees, "elevation reaches the clamp");
}

void distance_tracker() {
    const DistanceSettings set;
    DistanceTracker d;
    d.reset(2.0f);
    DistanceInput in;
    in.target = 4.0f;
    float first = 0.0f;
    for (int i = 0; i < 12; ++i) first = d.update(dt, in, set);
    expect(first > 2.0f && first < 4.0f, "distance eases toward a farther target");
    for (int i = 0; i < 1200; ++i) d.update(dt, in, set);
    expect(near(d.position(), 4.0f, 0.01f), "distance converges");

    DistanceTracker slow, quick;
    slow.reset(2.0f);
    quick.reset(2.0f);
    DistanceInput fast_in = in;
    fast_in.fast = true;
    for (int i = 0; i < 24; ++i) {
        slow.update(dt, in, set);
        quick.update(dt, fast_in, set);
    }
    expect(quick.position() > slow.position(), "the fast parameter set closes the gap sooner");

    DistanceInput tiny;
    tiny.target = 0.1f;
    tiny.snap = true;
    d.update(dt, tiny, set);
    expect(near(d.position(), set.min_distance), "target is held at the minimum distance");
    tiny.wipeout = true;
    d.update(dt, tiny, set);
    expect(near(d.position(), set.min_distance_wipeout), "wipeout tightens the minimum distance");
    DistanceSettings bad = set;
    bad.normal.speed_clamp = 0.0f;
    expect(!bad.valid(), "zero speed clamp is invalid");
}

void compass_lineup() {
    const CompassSettings set;
    expect(set.valid(), "compass defaults are valid");
    // Travelling along +X: heading_of(+X) = -pi/2.
    Compass c;
    CompassInput in;
    in.forward = {0, 0, 1};
    c.update(dt, in, set); // initialises
    for (int i = 1; i <= 480; ++i) {
        in.position = {6.0f * static_cast<float>(i) * dt, 0, 0};
        c.update(dt, in, set);
    }
    expect(near(c.heading(), -pi / 2, 0.05f), "compass follows the direction of travel");

    // Stopped, still facing +Z: nothing happens until time_before_lineup, then it lines up.
    in.position = {6.0f * 480.0f * dt, 0, 0};
    float before = 0.0f;
    const int delay_steps = static_cast<int>(set.time_before_lineup / dt);
    for (int i = 0; i < delay_steps - 10; ++i) c.update(dt, in, set);
    before = c.heading();
    expect(near(before, -pi / 2, 0.06f), "compass holds its heading during the delay");
    for (int i = 0; i < 30; ++i) c.update(dt, in, set);
    expect(std::abs(wrap_angle(c.heading() - 0.0f)) < std::abs(wrap_angle(before - 0.0f)) - 1e-3f,
           "compass starts lining up after the delay");
    for (int i = 0; i < 1200; ++i) c.update(dt, in, set);
    expect(near(c.heading(), 0.0f, 0.02f), "compass ends up behind the subject's forward");

    // Crouching (state 103) blocks the lineup; wiping out resets the stopped timer.
    Compass k;
    CompassInput held;
    held.forward = {1, 0, 0};
    k.reset(held.position, {0, 0, 1});
    held.crouching = true;
    for (int i = 0; i < 1200; ++i) k.update(dt, held, set);
    expect(near(k.heading(), 0.0f), "no lineup while crouching");
    held.crouching = false;
    held.wiping_out = true;
    for (int i = 0; i < 1200; ++i) k.update(dt, held, set);
    expect(near(k.heading(), 0.0f) && near(k.stopped_time(), 0.0f), "no lineup while wiping out");

    // Grinding takes the rail direction outright.
    held.wiping_out = false;
    held.grinding = true;
    held.grind_direction = {-1, 0, 0};
    k.update(dt, held, set);
    expect(near(k.heading(), heading_of({-1, 0, 0})), "grinding takes the rail heading");
    CompassSettings bad = set;
    bad.max_deadzone_speed = bad.min_deadzone_speed;
    expect(!bad.valid(), "dead-zone speeds must be ordered");
}

void deadzone() {
    // Jitter smaller than the dead-zone radius must not turn the compass at low speed.
    const CompassSettings set;
    Compass c;
    c.reset({0, 0, 0}, {0, 0, 1});
    CompassInput in;
    in.forward = {0, 0, 1};
    for (int i = 0; i < 240; ++i) {
        in.position = {0.02f * ((i & 1) ? 1.0f : -1.0f), 0, 0};
        c.update(dt, in, set);
    }
    expect(near(c.heading(), 0.0f, 0.1f), "small jitter stays inside the dead-zone");
}

void reset_snaps_everything() {
    const RigSettings set;
    expect(set.valid(), "default rig settings are valid");
    Rig rig;
    RigInput in;
    in.compass.forward = {0, 0, 1};
    in.anchor.velocity = {5, 0, 0};
    in.elevation_target = 10.0f * degrees;
    in.distance.target = 2.5f;
    rig.reset(in, set);
    RigOutput out = rig.update(dt, in, set);
    expect(near(out.distance, 2.5f, 0.01f) && near(out.anchor[0], 0.0f, 0.01f), "rig starts settled");

    // Fling the subject, turn it, change every target: the rig is mid-motion everywhere.
    for (int i = 1; i <= 90; ++i) {
        const float t = static_cast<float>(i) * dt;
        in.anchor.position = {10.0f * t, 0.5f, -4.0f * t};
        in.anchor.reference_height = 0.5f;
        in.anchor.push_state = in.anchor.push_kick = true;
        in.compass.position = in.anchor.position;
        in.elevation_target = 40.0f * degrees;
        in.distance.target = 9.0f;
        out = rig.update(dt, in, set);
    }
    expect(out.anchor_lag > 0.0f, "the rig is lagging before the reset");
    expect(!near(out.distance, 9.0f, 0.05f), "distance is still moving before the reset");
    expect(std::abs(rig.elevation().velocity()) > 0.0f || std::abs(rig.heading().velocity()) > 0.0f, "angles carry velocity");

    // Reset onto a new pose: no lag, no velocity, every tracker on its target.
    in.anchor.position = {-30.0f, 2.0f, 8.0f};
    in.anchor.reference_height = 2.0f;
    in.anchor.push_state = in.anchor.push_kick = false;
    in.compass.position = in.anchor.position;
    in.compass.forward = {1, 0, 0};
    in.elevation_target = -5.0f * degrees;
    in.distance.target = 3.0f;
    rig.reset(in, set);
    out = rig.update(dt, in, set);
    expect(near(out.anchor[0], -30.0f, 0.01f) && near(out.anchor[1], 2.0f, 0.01f) && near(out.anchor[2], 8.0f, 0.01f),
           "reset snaps the anchor");
    expect(near(out.anchor_lag, 0.0f, 0.01f), "reset leaves no anchor lag");
    expect(length(rig.anchor().velocity()) < 0.5f, "reset zeroes the anchor velocity");
    expect(near(out.compass_heading, heading_of({1, 0, 0}), 0.01f), "reset puts the compass on the forward direction");
    expect(near(out.heading, wrap_angle(heading_of({1, 0, 0}) + pi), 0.02f), "reset snaps the heading behind the subject");
    expect(near(out.elevation, -5.0f * degrees, 0.01f), "reset snaps the elevation");
    expect(near(out.distance, 3.0f, 0.01f), "reset snaps the distance");
    expect(near(rig.heading().velocity(), 0.0f, 0.05f) && near(rig.elevation().velocity(), 0.0f, 0.05f),
           "reset zeroes the angular velocities");

    // Invalid settings are refused without touching state.
    RigSettings bad = set;
    bad.anchor.speed_clamp = -1.0f;
    const RigOutput kept = rig.update(dt, in, bad);
    expect(near(kept.distance, out.distance) && near(kept.anchor[0], out.anchor[0]), "invalid settings leave the rig alone");
}

} // namespace

int main() {
    lag_curve();
    push_lags_then_catches_up();
    pump_and_fade();
    heading_tracker();
    elevation_tracker();
    distance_tracker();
    compass_lineup();
    deadzone();
    reset_snaps_everything();
    if (failures == 0) std::printf("s3cam_rig_tests: all passed\n");
    return failures == 0 ? 0 : 1;
}
