#include "Engine/Game/Camera/s3_trajectory.h"

#include <cmath>
#include <cstdio>
#include <limits>
#include <string_view>

// s3_trajectory.h: ballistic prediction against analytic parabolas and analytic ground shapes.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-5f) { return std::abs(a - b) <= tolerance; }

constexpr float g = 10.1f;

// Test ground: `solid(p)` says whether a point is inside the ground, `normal_at(p)` its surface
// normal. A segment hits when it goes from free to solid; the crossing is bisected to ~1e-6 m.
template <class Solid, class Normal>
struct Ground {
    Solid solid;
    Normal normal_at;
    int calls = 0;
    std::optional<GroundHit> operator()(const Vec3& a, const Vec3& b) noexcept {
        ++calls;
        if (solid(a) || !solid(b)) return std::nullopt;
        Vec3 lo = a, hi = b;
        for (int i = 0; i < 40; ++i) {
            const Vec3 mid = lerp(lo, hi, 0.5f);
            (solid(mid) ? hi : lo) = mid;
        }
        return GroundHit{hi, normal_at(hi)};
    }
};
template <class Solid, class Normal>
Ground(Solid, Normal) -> Ground<Solid, Normal>;

void settings_validation() {
    expect(TrajectorySettings{}.valid(), "defaults are valid");
    TrajectorySettings s;
    s.gravity = 0.0f;
    expect(!s.valid(), "zero gravity rejected");
    s = {};
    s.gravity = std::numeric_limits<float>::quiet_NaN();
    expect(!s.valid(), "NaN gravity rejected");
    s = {};
    s.step = 0.0f;
    expect(!s.valid(), "zero step rejected");
    s = {};
    s.max_time = -1.0f;
    expect(!s.valid(), "negative horizon rejected");
    s = {};
    s.step = 1.0f / 480.0f;
    s.max_time = 30.0f;
    expect(!s.valid(), "too many steps rejected");
}

void flat_ground() {
    // Launch 0.5 m above a flat floor at y=0: y(t) = 0.5 + 4t - g t^2 / 2.
    Ground ground{[](const Vec3& p) { return p[1] <= 0.0f; }, [](const Vec3&) { return Vec3{0, 1, 0}; }};
    const TrajectoryLaunch launch{{1, 0.5f, 2}, {3, 4, 0}, {0, 1, 0}, 4.0f};
    const TrajectoryPrediction p = predict_trajectory(launch, ground);
    const float apex_t = 4.0f / g;
    const float apex_h = 4.0f * 4.0f / (2 * g);
    const float land_t = (4.0f + std::sqrt(16.0f + 2 * g * 0.5f)) / g;
    expect(p.status == TrajectoryStatus::Landed && p.landed(), "flat: landed");
    expect(near(p.apex_time, apex_t, 1e-5f), "flat: apex time is vy/g");
    expect(near(p.predicted_max_height, apex_h, 1e-4f), "flat: apex height is vy^2/2g");
    expect(near(p.predicted_air_time, land_t, 2e-3f), "flat: landing time matches the quadratic");
    expect(near(p.predicted_landing_height, -0.5f, 1e-4f), "flat: landing height is the drop to the floor");
    expect(near(p.landing_position[0], 1 + 3 * land_t, 1e-2f) && near(p.landing_position[2], 2, 1e-4f),
           "flat: landing x follows the horizontal velocity");
    expect(near(p.landing_normal[1], 1) && near(p.landing_incline, 0, 1e-4f), "flat: level landing");
    expect(near(p.launch_incline, 0, 1e-4f), "flat: level launch");
    expect(near(p.height_distance_ratio, apex_h / 4.0f, 1e-4f), "flat: ratio is apex height over camera distance");
    expect(p.segments_tested == static_cast<int>(std::ceil(land_t * 60.0f)), "flat: one query per 1/60 s segment");
    expect(p.segments_tested == ground.calls, "flat: segments_tested matches query calls");

    const TrajectoryLaunch no_cam{{0, 0.5f, 0}, {0, 4, 0}, {0, 1, 0}, 0.0f};
    expect(predict_trajectory(no_cam, ground).height_distance_ratio == 0.0f, "flat: no camera distance gives ratio 0");

    // Gravity is a parameter: weaker gravity flies longer, and still follows the closed forms.
    TrajectorySettings moon;
    moon.gravity = 5.0f;
    const TrajectoryPrediction m = predict_trajectory(launch, ground, moon);
    expect(near(m.apex_time, 4.0f / 5.0f, 1e-5f), "gravity parameter drives the apex time");
    expect(near(m.predicted_air_time, (4.0f + std::sqrt(16.0f + 2 * 5.0f * 0.5f)) / 5.0f, 2e-3f),
           "gravity parameter drives the landing time");
}

void stair_set() {
    // A platform at y=2 for x<3, ground at y=0 beyond: a 2 m drop, as a stair set.
    auto height = [](float x) { return x < 3.0f ? 2.0f : 0.0f; };
    Ground ground{[&](const Vec3& p) { return p[1] <= height(p[0]); }, [](const Vec3&) { return Vec3{0, 1, 0}; }};
    const TrajectoryLaunch launch{{2, 2.05f, 0}, {4, 3, 0}, {0, 1, 0}, 5.0f};
    const TrajectoryPrediction p = predict_trajectory(launch, ground);
    const float land_t = (3.0f + std::sqrt(9.0f + 2 * g * 2.05f)) / g;
    expect(p.landed(), "stairs: landed");
    expect(near(p.apex_time, 3.0f / g, 1e-5f), "stairs: apex time");
    expect(near(p.predicted_max_height, 9.0f / (2 * g), 1e-4f), "stairs: apex height");
    expect(near(p.predicted_air_time, land_t, 2e-3f), "stairs: landing time includes the extra fall");
    expect(p.predicted_air_time > 2 * 3.0f / g, "stairs: longer than a level-ground flight");
    expect(near(p.predicted_landing_height, -2.05f, 1e-3f), "stairs: landing is about 2 m lower");
    expect(p.landing_position[0] > 3.0f, "stairs: clears the platform edge");
    expect(p.predicted_air_time < 3.0f, "stairs: inside the horizon");
}

void quarter_pipe() {
    // Quarter pipe of radius R=3 about (0,3): floor y=0 for x<0, curve y = 3 - sqrt(9-x^2) on [0,3], deck
    // at y=3 beyond. Leaving the lip moving back over the transition lands on the curve (re-entry).
    constexpr float R = 3.0f;
    auto surface = [](float x) {
        if (x < 0.0f) return 0.0f;
        if (x > R) return R;
        return R - std::sqrt(R * R - x * x);
    };
    Ground ground{[&](const Vec3& p) { return p[1] <= surface(p[0]); },
                  [&](const Vec3& p) {
                      if (p[0] <= 0.0f) return Vec3{0, 1, 0};
                      return normalized({-p[0], R - p[1], 0}, {0, 1, 0});
                  }};
    const TrajectoryLaunch launch{{3.0f, 3.05f, 0}, {-1, 6, 0}, {0, 1, 0}, 3.0f};
    const TrajectoryPrediction p = predict_trajectory(launch, ground);
    expect(p.landed(), "pipe: re-entry lands");
    expect(near(p.apex_time, 6.0f / g, 1e-5f), "pipe: apex time");
    expect(near(p.predicted_max_height, 36.0f / (2 * g), 1e-4f), "pipe: apex height");
    expect(p.landing_position[0] > 0.0f && p.landing_position[0] < R, "pipe: lands on the curved transition");
    expect(near(std::hypot(p.landing_position[0], p.landing_position[1] - R), R, 5e-3f), "pipe: landing point is on the arc");
    const Vec3 on_path = trajectory_detail::at(launch.position, launch.velocity, g, p.predicted_air_time);
    expect(length(sub(on_path, p.landing_position)) < 1e-2f, "pipe: landing time puts the parabola on the landing point");
    expect(p.predicted_air_time > 2 * p.apex_time, "pipe: lands below the lip, after the symmetric time");
    expect(p.predicted_landing_height < -2.0f, "pipe: landing is well below the lip");
    expect(p.landing_normal[1] > 0.0f && p.landing_normal[1] < 0.99f && p.landing_normal[0] < 0.0f,
           "pipe: landing normal leans back toward the arc centre");
    expect(near(p.landing_incline, std::acos(p.landing_normal[1])) && p.landing_incline > 20.0f * degrees,
           "pipe: landing incline is the angle of the transition");
}

void miss() {
    // Ground far below: nothing within 3 s. The apex still follows the closed form.
    Ground ground{[](const Vec3& p) { return p[1] <= -1000.0f; }, [](const Vec3&) { return Vec3{0, 1, 0}; }};
    const TrajectoryLaunch launch{{0, 1, 0}, {2, 5, 0}, {0, 1, 0}, 4.0f};
    const TrajectoryPrediction p = predict_trajectory(launch, ground);
    expect(p.status == TrajectoryStatus::Miss && !p.landed(), "miss: status is Miss");
    expect(near(p.predicted_air_time, 3.0f), "miss: air time is the horizon");
    expect(p.segments_tested == 180, "miss: 3 s at 1/60 s is 180 segments");
    expect(near(p.apex_time, 5.0f / g, 1e-5f) && near(p.predicted_max_height, 25.0f / (2 * g), 1e-4f), "miss: apex still predicted");
    expect(near(p.landing_position[1], 1 + 5 * 3.0f - 0.5f * g * 9.0f, 1e-3f), "miss: end point is the parabola at 3 s");
    expect(near(p.landing_normal[1], 1) && p.landing_incline == 0.0f, "miss: no landing normal, level incline");

    // A shorter horizon is honoured.
    TrajectorySettings shorter;
    shorter.max_time = 0.5f;
    expect(predict_trajectory(launch, ground, shorter).segments_tested == 30, "miss: custom horizon");

    // A query that never hits sees no ground at all.
    const TrajectoryPrediction none = predict_trajectory(launch, [](const Vec3&, const Vec3&) noexcept { return std::optional<GroundHit>{}; });
    expect(none.status == TrajectoryStatus::Miss, "miss: plain lambda query works");

    // Launching straight into the ground: the apex is clipped to the part of the flight that happened.
    Ground floor{[](const Vec3& q) { return q[1] <= 0.0f; }, [](const Vec3&) { return Vec3{0, 1, 0}; }};
    const TrajectoryPrediction down = predict_trajectory({{0, 0.5f, 0}, {0, -3, 0}, {0, 1, 0}, 2.0f}, floor);
    expect(down.landed() && down.apex_time == 0.0f && down.predicted_max_height == 0.0f, "downward launch has no climb");
}

// CameraMan::update is noexcept, so a world query that may throw is rejected at compile time.
void query_must_be_nothrow() {
    const auto may_throw = [](const Vec3&, const Vec3&) { return std::optional<GroundHit>{}; };
    const auto no_throw = [](const Vec3&, const Vec3&) noexcept { return std::optional<GroundHit>{}; };
    static_assert(!GroundQuery<decltype(may_throw)>, "a potentially throwing query must not satisfy GroundQuery");
    static_assert(GroundQuery<decltype(no_throw)>, "a noexcept query satisfies GroundQuery");
    expect(true, "GroundQuery requires a noexcept invocable (compile-time)");
}

void invalid_input() {
    int calls = 0;
    auto counting = [&](const Vec3&, const Vec3&) noexcept {
        ++calls;
        return std::optional<GroundHit>{};
    };
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    expect(predict_trajectory({{0, 1, 0}, {nan, 1, 0}, {0, 1, 0}, 1}, counting).status == TrajectoryStatus::Invalid, "NaN velocity is invalid");
    expect(predict_trajectory({{0, 1, 0}, {0, inf, 0}, {0, 1, 0}, 1}, counting).status == TrajectoryStatus::Invalid, "infinite velocity is invalid");
    expect(predict_trajectory({{0, nan, 0}, {0, 1, 0}, {0, 1, 0}, 1}, counting).status == TrajectoryStatus::Invalid, "NaN position is invalid");
    expect(predict_trajectory({{0, 1, 0}, {0, 1, 0}, {nan, 1, 0}, 1}, counting).status == TrajectoryStatus::Invalid, "NaN launch normal is invalid");
    TrajectorySettings bad;
    bad.gravity = -1.0f;
    expect(predict_trajectory({{0, 1, 0}, {0, 1, 0}, {0, 1, 0}, 1}, counting, bad).status == TrajectoryStatus::Invalid, "invalid settings give Invalid");
    expect(calls == 0, "invalid input never reaches the world query");
    const TrajectoryPrediction p = predict_trajectory({{0, 1, 0}, {nan, 0, 0}, {0, 1, 0}, 1}, counting);
    expect(p.predicted_air_time == 0.0f && p.segments_tested == 0, "invalid result is zeroed");

    // A query that returns a non-finite point is ignored rather than poisoning the result.
    const TrajectoryPrediction poisoned = predict_trajectory({{0, 1, 0}, {0, 1, 0}, {0, 1, 0}, 1},
        [&](const Vec3&, const Vec3&) noexcept { return std::optional<GroundHit>{GroundHit{{nan, 0, 0}, {0, 1, 0}}}; });
    expect(poisoned.status == TrajectoryStatus::Miss && std::isfinite(poisoned.predicted_air_time), "non-finite contact is ignored");
}

void incline() {
    // Launch off a 20 degree ramp (normal tilted back), land on a 30 degree downhill slope that falls
    // away in +x: surface y = -x tan30, normal (sin30, cos30, 0).
    const float launch_deg = 20.0f, land_deg = 30.0f;
    const float tl = std::tan(land_deg * degrees);
    Ground ground{[&](const Vec3& p) { return p[1] <= -p[0] * tl; },
                  [&](const Vec3&) { return Vec3{std::sin(land_deg * degrees), std::cos(land_deg * degrees), 0}; }};
    const Vec3 ramp_normal{-std::sin(launch_deg * degrees), std::cos(launch_deg * degrees), 0};
    const TrajectoryLaunch launch{{0, 1, 0}, {3, 2, 0}, ramp_normal, 2.0f};
    const TrajectoryPrediction p = predict_trajectory(launch, ground);
    // 1 + 2t - g t^2/2 = -3t tan30  ->  (g/2) t^2 - (2 + 3 tan30) t - 1 = 0
    const double a = 0.5 * g, b = -(2.0 + 3.0 * std::tan(land_deg * 3.14159265358979 / 180.0)), c = -1.0;
    const double land_t = (-b + std::sqrt(b * b - 4 * a * c)) / (2 * a);
    expect(p.landed(), "incline: landed");
    expect(near(p.launch_incline, launch_deg * degrees, 1e-4f), "incline: launch incline is 20 degrees");
    expect(near(p.landing_incline, land_deg * degrees, 1e-4f), "incline: landing incline is 30 degrees");
    expect(near(p.predicted_air_time, static_cast<float>(land_t), 3e-3f), "incline: landing time on a sloped surface");
    expect(near(p.apex_time, 2.0f / g, 1e-5f) && near(p.predicted_max_height, 4.0f / (2 * g), 1e-4f), "incline: apex");
    expect(p.landing_position[1] < launch.position[1] - 1.0f, "incline: downhill landing is lower than the launch");
    // A non-unit launch normal is normalised; a degenerate one falls back to level.
    const TrajectoryPrediction scaled = predict_trajectory({{0, 1, 0}, {3, 2, 0}, scale(ramp_normal, 5.0f), 2.0f}, ground);
    expect(near(scaled.launch_incline, launch_deg * degrees, 1e-4f), "incline: launch normal is normalised");
    const TrajectoryPrediction zero = predict_trajectory({{0, 1, 0}, {3, 2, 0}, {0, 0, 0}, 2.0f}, ground);
    expect(near(zero.launch_incline, 0.0f), "incline: degenerate launch normal reads as level");
}
} // namespace

int main() {
    settings_validation();
    flat_ground();
    stair_set();
    quarter_pipe();
    miss();
    query_must_be_nothrow();
    invalid_input();
    incline();
    if (failures == 0) std::printf("s3cam trajectory tests passed\n");
    return failures == 0 ? 0 : 1;
}
