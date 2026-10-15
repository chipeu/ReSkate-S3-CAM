#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/trajectory_query.rs (segment walk, first-contact time),
// crates/skate-core/src/camera/manager_air.rs (apex/landing deltas, launch and landing incline) and
// crates/skate-game/src/camera/trajectory.rs, graph_conditions.rs (PredictedAirTime, MaxHeight,
// LandingHeight, HeightDistanceRatio, Launch/LandingInclineAngle). Semantics are ported; the
// variable-step VMX walk is replaced by a fixed step (CLAUDE.md hard rule 6).
#include "Engine/Game/Camera/s3_math.h"

#include <algorithm>
#include <cmath>
#include <concepts>
#include <optional>
#include <type_traits>

// Ballistic prediction for the S3Cam air/landing logic (card T3). From the launch position and
// velocity it walks the parabola in fixed steps, ray-tests every chord against the world through an
// injected callable, and reports what the camera graph reads. Pure, header-only, no allocation.
namespace dingosdk::s3cam {

// What the world query returns for one segment: the first contact and the surface normal there.
struct GroundHit {
    Vec3 point{0, 0, 0};
    Vec3 normal{0, 1, 0};
};

// The injected world query: segment start and end (world space, Y up) -> first contact, if any.
// The game backs it with a physics ray (Rust: world_query::line); tests back it with analytic ground.
template <class Query>
concept GroundQuery = std::invocable<Query&, const Vec3&, const Vec3&> &&
                      std::is_nothrow_invocable_v<Query&, const Vec3&, const Vec3&> && // CameraMan::update is noexcept
                      std::convertible_to<std::invoke_result_t<Query&, const Vec3&, const Vec3&>, std::optional<GroundHit>>;

struct TrajectorySettings {
    float gravity = 10.1f;     // m/s2, positive; measured in-game (SPIKES.md Gate 0), tunable air.gravity
    float step = 1.0f / 60.0f; // s, chord length; the physics tick
    float max_time = 3.0f;     // s, prediction horizon; a miss past this is "no landing"

    static constexpr int max_steps_limit = 4096; // bounds the loop for any valid settings
    bool valid() const noexcept {
        return std::isfinite(gravity) && gravity > 0.0f && gravity <= 100.0f && //
               std::isfinite(step) && step >= 1.0f / 480.0f && step <= 0.25f && //
               std::isfinite(max_time) && max_time > 0.0f && max_time <= 30.0f && //
               max_time / step <= static_cast<float>(max_steps_limit);
    }
};

enum class TrajectoryStatus {
    Invalid, // bad input or settings: nothing else in the result is meaningful
    Landed,  // a ground contact was found within max_time
    Miss,    // no contact within max_time (Rust: collision time -1, trajectory not valid)
};

struct TrajectoryPrediction {
    TrajectoryStatus status = TrajectoryStatus::Invalid;

    // Graph values, in the units the stock conditions use before their degree conversion.
    float predicted_air_time = 0.0f;       // s, launch -> landing (Miss: max_time)
    float predicted_max_height = 0.0f;     // m, apex above the launch point, >= 0 (PredictedMaxHeight)
    float predicted_landing_height = 0.0f; // m, landing minus launch height, negative = lower (PredictedLandingHeight)
    float height_distance_ratio = 0.0f;    // max height / camera distance; 0 if no distance was given
    float launch_incline = 0.0f;           // rad, acos(launch normal . up) (LaunchInclineAngle / degrees)
    float landing_incline = 0.0f;          // rad, acos(landing normal . up) (LandingInclineAngle / degrees)

    // Supporting geometry.
    float apex_time = 0.0f;     // s after launch; 0 when launched level or downward
    Vec3 apex_position{0, 0, 0};
    Vec3 landing_position{0, 0, 0}; // Miss: the parabola at max_time
    Vec3 landing_normal{0, 1, 0};   // Miss: up
    int segments_tested = 0;

    bool landed() const noexcept { return status == TrajectoryStatus::Landed; }
};

struct TrajectoryLaunch {
    Vec3 position{0, 0, 0};
    Vec3 velocity{0, 0, 0};
    Vec3 launch_normal{0, 1, 0}; // ground normal under the launch; feeds launch_incline
    float camera_distance = 0.0f; // m, the rig distance the ratio divides by (manager_air trajectory_camera_distance)
};

namespace trajectory_detail {
inline bool finite(const Vec3& v) { return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]); }
// Position at time t under constant gravity along -Y.
inline Vec3 at(const Vec3& p, const Vec3& v, float g, float t) {
    return {p[0] + v[0] * t, p[1] + v[1] * t - 0.5f * g * t * t, p[2] + v[2] * t};
}
inline float incline_of(const Vec3& normal) {
    const float y = std::clamp(normal[1], -1.0f, 1.0f);
    return std::acos(y);
}
} // namespace trajectory_detail

// Walks the parabola and ray-tests each chord, first contact wins. Callers should launch from a point
// that is not already inside the ground (the game's board sits ~0.9 m above the root-level surface).
// Time is refined inside the hit chord to the parabola point closest to the contact, as the Rust
// time_at_contact does, so the chord-vs-arc error (g*dt^2/8 ~ 0.4 mm) does not leak into the air time.
template <GroundQuery Query>
TrajectoryPrediction predict_trajectory(const TrajectoryLaunch& launch, Query&& query,
                                        const TrajectorySettings& settings = {}) {
    using namespace trajectory_detail;
    TrajectoryPrediction out;
    if (!settings.valid() || !finite(launch.position) || !finite(launch.velocity) || !finite(launch.launch_normal) ||
        !std::isfinite(launch.camera_distance))
        return out;

    const float gravity = settings.gravity;
    const Vec3& p0 = launch.position;
    const Vec3& v0 = launch.velocity;
    const int steps = static_cast<int>(std::ceil(settings.max_time / settings.step));

    float hit_time = -1.0f;
    GroundHit hit;
    Vec3 start = p0;
    for (int i = 0; i < steps; ++i) {
        const float t0 = static_cast<float>(i) * settings.step;
        const float t1 = std::min(static_cast<float>(i + 1) * settings.step, settings.max_time);
        const Vec3 end = at(p0, v0, gravity, t1);
        ++out.segments_tested;
        if (const std::optional<GroundHit> found = query(start, end)) {
            if (finite(found->point)) {
                hit = *found;
                // Start from the contact's projection on the chord, then a few Newton steps on the
                // distance to the contact along the parabola; clamped to this segment.
                const Vec3 chord = sub(end, start);
                const float chord2 = dot(chord, chord);
                float frac = chord2 > 1e-12f ? clamp01(dot(sub(found->point, start), chord) / chord2) : 0.0f;
                float t = t0 + (t1 - t0) * frac;
                for (int k = 0; k < 3; ++k) {
                    const Vec3 p = at(p0, v0, gravity, t);
                    const Vec3 v{v0[0], v0[1] - gravity * t, v0[2]};
                    const Vec3 d = sub(p, found->point);
                    const float slope = dot(v, v) - gravity * d[1];
                    if (!(std::abs(slope) > 1e-6f)) break;
                    t = std::clamp(t - dot(d, v) / slope, t0, t1);
                }
                hit_time = t;
                break;
            }
        }
        start = end;
    }

    const bool landed = hit_time >= 0.0f;
    const float end_time = landed ? hit_time : settings.max_time;
    out.status = landed ? TrajectoryStatus::Landed : TrajectoryStatus::Miss;
    out.predicted_air_time = end_time;

    // Apex: closed form, clipped to the part of the flight that happened (a ceiling or an early
    // landing can end the climb before vy/gravity).
    out.apex_time = v0[1] > 0.0f ? std::min(v0[1] / gravity, end_time) : 0.0f;
    out.apex_position = at(p0, v0, gravity, out.apex_time);
    out.predicted_max_height = out.apex_position[1] - p0[1];

    if (landed) {
        out.landing_position = hit.point;
        out.landing_normal = normalized(hit.normal, {0, 1, 0});
    } else {
        out.landing_position = at(p0, v0, gravity, end_time);
        out.landing_normal = {0, 1, 0};
    }
    out.predicted_landing_height = out.landing_position[1] - p0[1];
    out.height_distance_ratio = launch.camera_distance > 0.0f ? out.predicted_max_height / launch.camera_distance : 0.0f;
    out.launch_incline = incline_of(normalized(launch.launch_normal, {0, 1, 0}));
    out.landing_incline = incline_of(out.landing_normal);
    return out;
}

} // namespace dingosdk::s3cam
