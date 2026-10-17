#include "Engine/Game/Camera/s3_graph.h"

#include <cmath>
#include <cstdio>
#include <set>
#include <string_view>

// s3_graph.h: the priority selector, the landing window, hysteresis, the chase blend tree and the
// Low / High shot lookup.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}

constexpr float dt = fixed_step; // the camera's 60 Hz step

GraphInput ride(float speed = 6.0f) {
    GraphInput in;
    in.dt = dt;
    in.speed = speed;
    return in;
}

// Runs the same input for `steps` steps and returns the last output.
GraphOutput run(ShotGraph& g, const GraphInput& in, const GraphSettings& s, int steps = 1) {
    GraphOutput out;
    for (int i = 0; i < steps; ++i) out = g.select(in, s);
    return out;
}

void test_priority_order() {
    const GraphSettings s;
    // Every combination of the five condition flags: the highest-priority true one wins.
    for (int mask = 0; mask < 32; ++mask) {
        ShotGraph g;
        GraphInput in = ride();
        in.bailing = (mask & 1) != 0;
        in.touchdown = (mask & 2) != 0;
        in.air = (mask & 4) != 0;
        in.grinding = (mask & 8) != 0;
        in.manual = (mask & 16) != 0;
        const GraphOutput out = g.select(in, s);
        ShotId want = ShotId::Chase;
        if (in.manual) want = ShotId::ManualFar;
        if (in.grinding) want = ShotId::GrindFlat;
        if (in.air) want = ShotId::AirNormal;
        if (in.touchdown) want = ShotId::Landing;
        if (in.bailing) want = ShotId::Wipeout;
        expect(out.shot == want, "priority: Wipeout > Landing > Air > Grind > Manual > Chase for every flag mask");
    }
}

void test_every_shot_reachable() {
    const GraphSettings s;
    std::set<ShotId> seen;
    const auto note = [&](ShotGraph& g, const GraphInput& in) { seen.insert(g.select(in, s).shot); };
    ShotGraph g;
    GraphInput in = ride();
    note(g, in);                                   // Chase
    in.incline_degrees = 15.0f;  note(g, in);      // ChaseUp
    in.incline_degrees = -15.0f; note(g, in);      // ChaseDown
    in.incline_degrees = 0.0f;
    in.manual = true;  in.speed = 8.0f; note(g, in);  // ManualFar
    in.speed = 1.0f;   note(g, in);                    // ManualClose
    in.manual = false; in.speed = 6.0f;
    in.grinding = true;
    in.grind_side = -1; note(g, in);               // GrindLedgeL
    in.grind_side = 1;  note(g, in);               // GrindLedgeR
    in.grind_side = 0;  note(g, in);               // GrindFlat
    in.grinding = false;
    in.air = true;
    in.predicted_max_height = 0.5f; note(g, in);   // AirNormal
    in.predicted_max_height = 3.0f; note(g, in);   // AirBig
    in.air = false;
    in.touchdown = true; note(g, in);              // Landing
    in.touchdown = false;
    in.bailing = true; note(g, in);                // Wipeout
    expect(seen.size() == shot_id_count, "all 12 shots are reachable");
    for (std::size_t i = 0; i < shot_id_count; ++i) expect(seen.count(static_cast<ShotId>(i)) == 1, "each ShotId was selected");
}

// The cached shot lookup (CameraMan resolves the table once per shot change) blends exactly like resolve_shot.
void test_cached_shot_lookup() {
    for (const CameraAngle angle : {CameraAngle::Low, CameraAngle::High}) {
        for (std::size_t i = 0; i < shot_id_count; ++i) {
            const ShotId id = static_cast<ShotId>(i);
            const ResolvedShots shots = lookup_shots(id, angle);
            expect(shots.a != nullptr && shots.b != nullptr, "every shot id resolves to table shots in both angles");
            for (const float blend : {0.0f, 0.37f, 1.0f}) {
                const Shot cached = blend_shots(shots, blend);
                const Shot direct = resolve_shot(id, angle, blend);
                expect(cached.distance == direct.distance && cached.position_elevation == direct.position_elevation &&
                           cached.smoothing == direct.smoothing && cached.framing == direct.framing,
                       "cached lookup + blend equals resolve_shot");
            }
        }
    }
}

void test_landing_window() {
    const GraphSettings s; // window 0.25 s
    ShotGraph g;
    GraphInput in = ride();
    run(g, in, s, 10);
    expect(g.shot() == ShotId::Chase, "landing: chase before the touchdown");
    in.touchdown = true;
    GraphOutput out = g.select(in, s);
    expect(out.shot == ShotId::Landing && out.landing_active, "landing: starts on the touchdown step");
    in.touchdown = false;
    int active = 1;
    for (int i = 0; i < 200; ++i) {
        out = g.select(in, s);
        if (out.shot == ShotId::Landing) ++active;
        else break;
    }
    const float seconds = static_cast<float>(active) * dt;
    expect(std::abs(seconds - 0.25f) <= dt * 1.01f, "landing: the window is 0.25 s, to within one step");
    expect(active == 15, "landing: at 60 Hz the 0.25 s window is exactly 15 steps");
    expect(out.shot == ShotId::Chase && !out.landing_active, "landing: back to chase after the window");

    // Priority inside the window: bailing wins, air does not.
    ShotGraph g2;
    in.touchdown = true;
    g2.select(in, s);
    in.touchdown = false;
    in.air = true;
    expect(g2.select(in, s).shot == ShotId::Landing, "landing: outranks air inside the window");
    in.bailing = true;
    expect(g2.select(in, s).shot == ShotId::Wipeout, "landing: wipeout outranks it");
    in.bailing = false;
    in.air = false;
    // A second touchdown restarts the window.
    ShotGraph g3;
    in.touchdown = true;
    g3.select(in, s);
    in.touchdown = false;
    run(g3, in, s, 10);
    in.touchdown = true;
    g3.select(in, s);
    in.touchdown = false;
    run(g3, in, s, 10);
    expect(g3.shot() == ShotId::Landing, "landing: a new touchdown restarts the window");
    // A custom window length.
    GraphSettings longer;
    longer.landing_window = 0.5f;
    ShotGraph g4;
    in.touchdown = true;
    g4.select(in, longer);
    in.touchdown = false;
    run(g4, in, longer, 20);
    expect(g4.shot() == ShotId::Landing, "landing: the window follows the setting (still active at 0.33 s of 0.5)");
    run(g4, in, longer, 15);
    expect(g4.shot() == ShotId::Chase, "landing: and ends after 0.5 s");
}

void test_air_hysteresis() {
    const GraphSettings s; // big at 1.5, falls back below 1.2
    ShotGraph g;
    GraphInput in = ride();
    in.air = true;
    in.predicted_max_height = 1.45f;
    expect(g.select(in, s).shot == ShotId::AirNormal, "air: 1.45 m is normal");
    in.predicted_max_height = 1.55f;
    expect(g.select(in, s).shot == ShotId::AirBig, "air: 1.55 m is big");
    in.predicted_max_height = 1.35f;
    expect(g.select(in, s).shot == ShotId::AirBig, "air: 1.35 m stays big (hysteresis)");
    in.predicted_max_height = 1.1f;
    expect(g.select(in, s).shot == ShotId::AirNormal, "air: 1.1 m drops back to normal");
    in.predicted_max_height = 1.35f;
    expect(g.select(in, s).shot == ShotId::AirNormal, "air: 1.35 m does not re-enter big");
}

void test_manual_hysteresis() {
    const GraphSettings s; // far at 5, back to close below 4.25
    ShotGraph g;
    GraphInput in = ride();
    in.manual = true;
    in.speed = 4.0f;
    expect(g.select(in, s).shot == ShotId::ManualClose, "manual: slow is the close shot");
    in.speed = 5.5f;
    expect(g.select(in, s).shot == ShotId::ManualFar, "manual: fast is the far shot");
    in.speed = 4.5f;
    expect(g.select(in, s).shot == ShotId::ManualFar, "manual: 4.5 m/s stays far (hysteresis)");
    in.speed = 4.0f;
    expect(g.select(in, s).shot == ShotId::ManualClose, "manual: 4 m/s returns to close");
    in.speed = -6.0f; // switch / fakie: the speed is a magnitude
    expect(g.select(in, s).shot == ShotId::ManualFar, "manual: reverse speed counts by magnitude");
}

void test_incline_hysteresis() {
    const GraphSettings s; // up/down at 8 degrees, release at 5
    ShotGraph g;
    GraphInput in = ride();
    in.incline_degrees = 7.0f;
    expect(g.select(in, s).shot == ShotId::Chase, "incline: 7 degrees is flat chase");
    in.incline_degrees = 9.0f;
    expect(g.select(in, s).shot == ShotId::ChaseUp, "incline: 9 degrees is chase up");
    in.incline_degrees = 6.0f;
    expect(g.select(in, s).shot == ShotId::ChaseUp, "incline: 6 degrees stays up (hysteresis)");
    in.incline_degrees = 4.0f;
    expect(g.select(in, s).shot == ShotId::Chase, "incline: 4 degrees is flat again");
    in.incline_degrees = -9.0f;
    expect(g.select(in, s).shot == ShotId::ChaseDown, "incline: -9 degrees is chase down");
    in.incline_degrees = -6.0f;
    expect(g.select(in, s).shot == ShotId::ChaseDown, "incline: -6 degrees stays down");
    in.incline_degrees = -4.0f;
    expect(g.select(in, s).shot == ShotId::Chase, "incline: -4 degrees is flat again");
}

void test_chase_blend() {
    const GraphSettings s; // slow 3 m/s, fast 9 m/s
    const auto settled = [&](float speed) {
        ShotGraph g;
        return run(g, ride(speed), s, 2000).chase_blend;
    };
    expect(settled(0.0f) == 0.0f, "chase blend: standing is the slow shot");
    expect(settled(3.0f) < 0.001f, "chase blend: 3 m/s is the slow shot");
    expect(settled(9.0f) > 0.999f, "chase blend: 9 m/s is the fast shot");
    expect(settled(20.0f) > 0.999f, "chase blend: faster still stays the fast shot");
    const float mid = settled(6.0f);
    expect(std::abs(mid - 0.5f) < 0.01f, "chase blend: the midpoint speed gives 0.5 (the sine ease is symmetric)");
    expect(settled(4.5f) < mid && mid < settled(7.5f), "chase blend: monotonic in speed");

    // The input is filtered per step: a speed jump does not jump the blend, and it arrives eventually.
    ShotGraph g;
    run(g, ride(3.0f), s, 50);
    const float first = g.select(ride(9.0f), s).chase_blend;
    expect(first < 0.1f, "chase blend: a speed jump is filtered, not instant");
    const GraphOutput later = run(g, ride(9.0f), s, 600);
    expect(later.chase_blend > 0.99f, "chase blend: and settles on the fast shot");
    // Not scaled by dt: the filter is per fixed step. (Same step count -> same value whatever the caller's dt says.)
    ShotGraph a, b;
    GraphInput in_a = ride(6.0f), in_b = ride(6.0f);
    in_a.dt = fixed_step;
    in_b.dt = 1.0f / 60.0f;
    run(a, ride(3.0f), s, 10);
    run(b, ride(3.0f), s, 10);
    expect(std::abs(run(a, in_a, s, 5).chase_blend - run(b, in_b, s, 5).chase_blend) < 1e-6f,
           "chase blend: filter_blend_value is per step, not dt scaled");
}

void test_grind_side() {
    const GraphSettings s;
    ShotGraph g;
    GraphInput in = ride();
    in.grinding = true;
    in.grind_side = -1;
    expect(g.select(in, s).shot == ShotId::GrindLedgeL, "grind: side -1 is the left ledge shot");
    in.grind_side = 1;
    expect(g.select(in, s).shot == ShotId::GrindLedgeR, "grind: side +1 is the right ledge shot");
    in.grind_side = 0;
    expect(g.select(in, s).shot == ShotId::GrindFlat, "grind: side 0 is the flat grind shot");
}

void test_shot_lookup_low_high() {
    for (std::size_t i = 0; i < shot_id_count; ++i) {
        const ShotId id = static_cast<ShotId>(i);
        for (const CameraAngle angle : {CameraAngle::Low, CameraAngle::High}) {
            const ShotPair pair = shot_pair(id, angle);
            expect(find_shot(pair.a) != nullptr && find_shot(pair.b) != nullptr, "lookup: every id resolves to table shots");
            expect(valid(resolve_shot(id, angle, 0.5f)), "lookup: every resolved shot is valid");
        }
    }
    const auto distance = [](ShotId id, CameraAngle a) { return resolve_shot(id, a, 0.0f).distance; };
    const auto elevation = [](ShotId id, CameraAngle a) { return resolve_shot(id, a, 0.0f).position_elevation; };
    expect(distance(ShotId::Chase, CameraAngle::Low) < distance(ShotId::Chase, CameraAngle::High), "Low chase is closer than High");
    expect(elevation(ShotId::Chase, CameraAngle::Low) < elevation(ShotId::Chase, CameraAngle::High), "Low chase is lower than High");
    expect(distance(ShotId::GrindLedgeL, CameraAngle::Low) < distance(ShotId::GrindLedgeL, CameraAngle::High), "Low grind is closer");
    expect(distance(ShotId::ManualFar, CameraAngle::Low) != distance(ShotId::ManualFar, CameraAngle::High), "manual differs");
    expect(distance(ShotId::AirNormal, CameraAngle::Low) < distance(ShotId::AirNormal, CameraAngle::High), "Low air is closer");
    // Wipeout is the same shot in both (21-low-camera.md).
    expect(distance(ShotId::Wipeout, CameraAngle::Low) == distance(ShotId::Wipeout, CameraAngle::High), "wipeout is shared");
    // Low has the published values for the flat chase ends; High blends high_chase -> high_chase2.
    expect(std::abs(resolve_shot(ShotId::Chase, CameraAngle::Low, 0.0f).distance - 1.8f) < 1e-5f, "Low chase slow is 1.8 m");
    expect(std::abs(resolve_shot(ShotId::Chase, CameraAngle::Low, 1.0f).distance - 2.5f) < 1e-5f, "Low chase fast is 2.5 m");
    expect(std::abs(resolve_shot(ShotId::Chase, CameraAngle::High, 0.0f).distance - 3.0f) < 1e-5f, "High chase slow is 3.0 m");
    expect(std::abs(resolve_shot(ShotId::Chase, CameraAngle::High, 1.0f).distance - 4.4f) < 1e-5f, "High chase fast is 4.4 m");
    // Up / down chase differ from flat in Low (no High variants exist).
    expect(distance(ShotId::ChaseUp, CameraAngle::Low) != distance(ShotId::Chase, CameraAngle::Low), "Low chase up has its own shot");
    expect(distance(ShotId::ChaseUp, CameraAngle::High) == distance(ShotId::Chase, CameraAngle::High), "High has no chase up variant");
    // Distinct ids have distinct names.
    std::set<std::string_view> names;
    for (std::size_t i = 0; i < shot_id_count; ++i) names.insert(shot_id_name(static_cast<ShotId>(i)));
    expect(names.size() == shot_id_count, "shot ids have distinct names");
}

void test_settings_and_guards() {
    GraphSettings s;
    expect(s.valid(), "default graph settings are valid");
    GraphSettings bad = s;
    bad.chase_fast_speed = bad.chase_slow_speed;
    expect(!bad.valid(), "chase points must ascend");
    bad = s;
    bad.landing_window = -1.0f;
    expect(!bad.valid(), "negative landing window is rejected");
    bad = s;
    bad.transition_time[3] = std::nanf("");
    expect(!bad.valid(), "NaN transition time is rejected");
    bad = s;
    bad.incline_hysteresis_degrees = 20.0f;
    expect(!bad.valid(), "incline hysteresis must be smaller than the threshold");

    // Invalid settings / dt keep the previous selection.
    ShotGraph g;
    GraphInput in = ride();
    in.manual = true;
    g.select(in, s);
    const GraphOutput kept = g.select(in, bad);
    expect(kept.shot == g.shot() && g.shot() == ShotId::ManualFar, "invalid settings keep the previous selection");
    in.dt = 0.0f;
    in.bailing = true;
    expect(g.select(in, s).shot == ShotId::ManualFar, "zero dt keeps the previous selection");
    in.dt = dt;
    in.speed = std::nanf("");
    in.manual = false;
    in.bailing = false;
    expect(g.select(in, s).shot == ShotId::Chase, "NaN speed is treated as standing");
    const GraphOutput out = g.select(in, s);
    expect(std::isfinite(out.chase_blend), "NaN speed gives a finite blend");
}
} // namespace

int main() {
    test_priority_order();
    test_every_shot_reachable();
    test_cached_shot_lookup();
    test_landing_window();
    test_air_hysteresis();
    test_manual_hysteresis();
    test_incline_hysteresis();
    test_chase_blend();
    test_grind_side();
    test_shot_lookup_low_high();
    test_settings_and_guards();
    if (failures == 0) std::printf("s3cam_graph_tests: all passed\n");
    return failures == 0 ? 0 : 1;
}
