#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-game/src/camera/graph.rs and graph_conditions.rs (the priority state machine and the
// conditions IsWipingOut, IsInOnBoardAir, SkaterIsGrinding, IsGrindLedgeLeft/Right, IsInManual,
// PredictedMaxHeight, CameraSubjectSpeed, InclineAngle), crates/skate-core/src/camera/
// shot_manager.rs (blend tree: filter_blend_value, blend_interval, the sine-eased fraction) and
// docs/hails-additions/21-low-camera.md (Low vs High branch). The stock graph is binary setup data
// that is not shipped here (CLAUDE.md hard rule 7); this is a hand-written priority selector with
// the same order, and every threshold is a // TUNE default.
#include "Engine/Game/Camera/s3_math.h"
#include "Engine/Game/Camera/s3_shot.h"
#include "Engine/Game/Camera/s3_shots_default.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string_view>

// Shot selector (card T6). Priority, highest first:
//   Wipeout > Landing (window after touchdown) > Air (big / normal by predicted max height) >
//   Grind (ledge L / R / flat) > Manual (far / close by speed) > Chase (slow-fast blend by speed;
//   up / down by incline).
// Stateful only where the stock graph is: the landing timer, the speed blend filter and a little
// hysteresis so a value hovering on a threshold does not flicker the shot. Pure, no allocation.
namespace dingosdk::s3cam {

enum class ShotId : std::uint8_t {
    Wipeout,
    Landing,
    AirBig,
    AirNormal,
    GrindLedgeL,
    GrindLedgeR,
    GrindFlat,
    ManualFar,
    ManualClose,
    Chase,     // slow / fast blend by speed
    ChaseUp,   // riding uphill
    ChaseDown, // riding downhill
};
inline constexpr std::size_t shot_id_count = 12;

inline constexpr std::string_view shot_id_name(ShotId id) noexcept {
    switch (id) {
    case ShotId::Wipeout: return "wipeout";
    case ShotId::Landing: return "landing";
    case ShotId::AirBig: return "air_big";
    case ShotId::AirNormal: return "air_normal";
    case ShotId::GrindLedgeL: return "grind_ledge_l";
    case ShotId::GrindLedgeR: return "grind_ledge_r";
    case ShotId::GrindFlat: return "grind_flat";
    case ShotId::ManualFar: return "manual_far";
    case ShotId::ManualClose: return "manual_close";
    case ShotId::Chase: return "chase";
    case ShotId::ChaseUp: return "chase_up";
    case ShotId::ChaseDown: return "chase_down";
    }
    return "?";
}

struct GraphSettings {
    float landing_window = 0.25f;          // s after touchdown the Landing shot holds (the card)
    float landing_min_air_time = 0.1f;     // s of air before a touchdown counts as a landing; TUNE (skips a curb bump)
    float big_air_height = 1.5f;           // m predicted max height at/above which the air shot is "big"; TUNE
    float big_air_hysteresis = 0.3f;       // m; once big, stays big until height < big_air_height - this; TUNE
    float manual_far_speed = 5.0f;         // m/s at/above which a manual uses the far shot; TUNE
    float manual_speed_hysteresis = 0.75f; // m/s; TUNE
    float chase_slow_speed = 3.0f;         // m/s; chase is the slow shot at/below this (blend tree point 0); TUNE
    float chase_fast_speed = 9.0f;         // m/s; chase is the fast shot at/above this (blend tree point 1); TUNE
    float chase_blend_smoothing = 0.85f;   // 0..1 filter_blend_value smoothing, applied per fixed step; TUNE
    float incline_up_degrees = 8.0f;       // riding uphill steeper than this uses ChaseUp; TUNE
    float incline_down_degrees = 8.0f;     // riding downhill steeper than this (magnitude) uses ChaseDown; TUNE
    float incline_hysteresis_degrees = 3.0f; // TUNE
    // Seconds to ease into each shot (shot_manager.rs transition_time; the Rust default is 0.5).
    // All TUNE. Index with static_cast<size_t>(ShotId).
    std::array<float, shot_id_count> transition_time{
        0.30f, // Wipeout
        0.15f, // Landing
        0.40f, // AirBig
        0.40f, // AirNormal
        0.40f, // GrindLedgeL
        0.40f, // GrindLedgeR
        0.40f, // GrindFlat
        0.40f, // ManualFar
        0.40f, // ManualClose
        0.60f, // Chase
        0.60f, // ChaseUp
        0.60f, // ChaseDown
    };

    bool valid() const noexcept {
        const auto fin = [](float v) { return std::isfinite(v); };
        if (!fin(landing_window) || landing_window < 0.0f || landing_window > 5.0f) return false;
        if (!fin(landing_min_air_time) || landing_min_air_time < 0.0f || landing_min_air_time > 5.0f) return false;
        if (!fin(big_air_height) || big_air_height < 0.0f) return false;
        if (!fin(big_air_hysteresis) || big_air_hysteresis < 0.0f || big_air_hysteresis > big_air_height) return false;
        if (!fin(manual_far_speed) || manual_far_speed < 0.0f) return false;
        if (!fin(manual_speed_hysteresis) || manual_speed_hysteresis < 0.0f || manual_speed_hysteresis > manual_far_speed)
            return false;
        if (!fin(chase_slow_speed) || chase_slow_speed < 0.0f || !fin(chase_fast_speed) ||
            !(chase_fast_speed > chase_slow_speed))
            return false;
        if (!fin(chase_blend_smoothing) || chase_blend_smoothing < 0.0f || chase_blend_smoothing > 1.0f) return false;
        if (!fin(incline_up_degrees) || incline_up_degrees <= 0.0f || incline_up_degrees >= 90.0f) return false;
        if (!fin(incline_down_degrees) || incline_down_degrees <= 0.0f || incline_down_degrees >= 90.0f) return false;
        if (!fin(incline_hysteresis_degrees) || incline_hysteresis_degrees < 0.0f ||
            incline_hysteresis_degrees >= incline_up_degrees || incline_hysteresis_degrees >= incline_down_degrees)
            return false;
        for (const float t : transition_time)
            if (!fin(t) || t < 0.0f || t > 10.0f) return false;
        return true;
    }
};

// The conditions, already reduced from the subject by the caller (CameraMan).
struct GraphInput {
    float dt = fixed_step;         // s, the fixed step (60 Hz)
    bool bailing = false;          // IsWipingOut
    bool air = false;              // IsInOnBoardAir (physics state 200 / 201)
    bool grinding = false;         // SkaterIsGrinding (state 400-499)
    int grind_side = 0;            // -1 IsGrindLedgeLeft, +1 IsGrindLedgeRight, 0 flat
    bool manual = false;           // IsInManual
    bool touchdown = false;        // this step is the first one after leaving the air (starts the landing window)
    float speed = 0.0f;            // m/s, |velocity . forward| (CameraSubjectSpeed)
    float predicted_max_height = 0.0f; // m above takeoff (PredictedMaxHeight)
    float incline_degrees = 0.0f;  // slope of the travel direction, + uphill (InclineAngle)
};

struct GraphOutput {
    ShotId shot = ShotId::Chase;
    float chase_blend = 0.0f;  // 0 = slow shot, 1 = fast shot; the sine-eased tree fraction (Chase only is meaningful)
    bool landing_active = false;
};

class ShotGraph {
public:
    void reset() noexcept { *this = ShotGraph{}; }

    // One fixed step. Invalid settings keep the previous selection.
    GraphOutput select(const GraphInput& in, const GraphSettings& set) noexcept {
        GraphOutput out;
        out.shot = shot_;
        out.chase_blend = chase_blend_;
        out.landing_active = landing_active_;
        if (!set.valid() || !(in.dt > 0.0f) || !std::isfinite(in.dt)) return out;

        // Landing window: restarts on a touchdown, otherwise counts up. "Active while elapsed is
        // under the window minus half a step" makes it exactly window / dt steps long and keeps float
        // drift from adding or dropping one.
        if (in.touchdown) since_touchdown_ = 0.0f;
        else if (since_touchdown_ >= 0.0f) since_touchdown_ += in.dt;
        landing_active_ = since_touchdown_ >= 0.0f && since_touchdown_ < set.landing_window - 0.5f * in.dt;

        // Chase blend tree: the speed is filtered per fixed step and not scaled by dt (shot.rs
        // filter_blend_value), then mapped through blend_interval and eased once (shot_manager.rs).
        const float speed = std::isfinite(in.speed) ? std::abs(in.speed) : 0.0f;
        if (!blend_valid_) {
            blend_value_ = std::clamp(speed, set.chase_slow_speed, set.chase_fast_speed);
            blend_valid_ = true;
        }
        blend_value_ = filter_blend_value(blend_value_, speed, set.chase_blend_smoothing, set.chase_slow_speed,
                                          set.chase_fast_speed);
        chase_blend_ = chase_weight(blend_value_, set);

        shot_ = pick(in, set, speed);
        out.shot = shot_;
        out.chase_blend = chase_blend_;
        out.landing_active = landing_active_;
        return out;
    }

    ShotId shot() const noexcept { return shot_; }
    bool landing_active() const noexcept { return landing_active_; }
    float seconds_since_touchdown() const noexcept { return since_touchdown_; }

private:
    static float chase_weight(float value, const GraphSettings& set) noexcept {
        const std::array<float, 3> points{set.chase_slow_speed, set.chase_fast_speed, 0.0f};
        const auto interval = blend_interval(points, {true, true, false}, value);
        if (!interval || interval->lower == interval->upper) return 0.0f; // below the first point: all slow
        return sine_blend(clamp01(interval->fraction));
    }

    ShotId pick(const GraphInput& in, const GraphSettings& set, float speed) noexcept {
        if (in.bailing) return ShotId::Wipeout;
        if (landing_active_) return ShotId::Landing;
        if (in.air) {
            const bool was_big = shot_ == ShotId::AirBig;
            const float threshold = was_big ? set.big_air_height - set.big_air_hysteresis : set.big_air_height;
            return in.predicted_max_height >= threshold ? ShotId::AirBig : ShotId::AirNormal;
        }
        if (in.grinding) {
            if (in.grind_side < 0) return ShotId::GrindLedgeL;
            if (in.grind_side > 0) return ShotId::GrindLedgeR;
            return ShotId::GrindFlat;
        }
        if (in.manual) {
            const bool was_far = shot_ == ShotId::ManualFar;
            const float threshold = was_far ? set.manual_far_speed - set.manual_speed_hysteresis : set.manual_far_speed;
            return speed >= threshold ? ShotId::ManualFar : ShotId::ManualClose;
        }
        // Chase family, with hysteresis on the incline so a bumpy slope does not flicker.
        const float up_threshold = shot_ == ShotId::ChaseUp ? set.incline_up_degrees - set.incline_hysteresis_degrees
                                                            : set.incline_up_degrees;
        const float down_threshold = shot_ == ShotId::ChaseDown ? set.incline_down_degrees - set.incline_hysteresis_degrees
                                                                : set.incline_down_degrees;
        if (in.incline_degrees >= up_threshold) return ShotId::ChaseUp;
        if (in.incline_degrees <= -down_threshold) return ShotId::ChaseDown;
        return ShotId::Chase;
    }

    ShotId shot_ = ShotId::Chase;
    float since_touchdown_ = -1.0f; // < 0: no touchdown yet
    bool landing_active_ = false;
    float blend_value_ = 0.0f;
    float chase_blend_ = 0.0f;
    bool blend_valid_ = false;
};

// ---------------------------------------------------------------- shot lookup (Low / High)

struct ShotPair {
    std::string_view a; // blend tree child 0 (slow)
    std::string_view b; // blend tree child 1 (fast); equal to `a` for everything but Chase
};

// Which table shots a ShotId uses. Low picks the dedicated shots; High has fewer, so several ids
// share one (21-low-camera.md: wipeouts use the same shot in both graphs). Landing has no published
// High shot: it reuses high_chase (TUNE).
inline constexpr ShotPair shot_pair(ShotId id, CameraAngle angle) noexcept {
    if (id == ShotId::Wipeout) return {"wipeout", "wipeout"};
    if (angle == CameraAngle::Low) {
        switch (id) {
        case ShotId::Landing: return {"landing", "landing"};
        case ShotId::AirBig: return {"air_high", "air_high"};
        case ShotId::AirNormal: return {"low_ollie", "low_ollie"};
        case ShotId::GrindLedgeL: return {"grind_ledge_l", "grind_ledge_l"};
        case ShotId::GrindLedgeR: return {"grind_ledge_r", "grind_ledge_r"};
        case ShotId::GrindFlat: return {"grind_flat_slow", "grind_flat_slow"};
        case ShotId::ManualFar: return {"far_manual", "far_manual"};
        case ShotId::ManualClose: return {"close_manual", "close_manual"};
        case ShotId::ChaseUp: return {"chase_up_slow", "chase_up_slow"};
        case ShotId::ChaseDown: return {"chase_down", "chase_down"};
        default: return {"chase_flat_slow", "chase_flat_fast"};
        }
    }
    switch (id) {
    case ShotId::AirBig:
    case ShotId::AirNormal: return {"bl_high_air", "bl_high_air"};
    case ShotId::GrindLedgeL:
    case ShotId::GrindLedgeR:
    case ShotId::GrindFlat: return {"high_grind", "high_grind"};
    case ShotId::ManualFar:
    case ShotId::ManualClose: return {"high_manual", "high_manual"};
    default: return {"high_chase", "high_chase2"}; // Landing, Chase, ChaseUp, ChaseDown
    }
}

// The leaf shot for a selection: the named table shot, or for Chase the slow/fast pair blended by
// `chase_blend` through interpolate() (which eases once more, as the Rust blend tree does). Falls
// back to a default Shot if the table lacks a name (cannot happen with the built-in table).
inline Shot resolve_shot(ShotId id, CameraAngle angle, float chase_blend = 0.0f);

// The two table shots of a selection, looked up once (the table scan is linear) so a caller can
// cache them while the selection stays the same and blend every step with blend_shots().
struct ResolvedShots {
    const Shot* a = nullptr;
    const Shot* b = nullptr; // equal to `a` when the selection has a single shot
};
inline ResolvedShots lookup_shots(ShotId id, CameraAngle angle) {
    const ShotPair pair = shot_pair(id, angle);
    const Shot* a = find_shot(pair.a);
    const Shot* b = pair.a == pair.b ? a : find_shot(pair.b);
    return {a, b};
}
inline Shot blend_shots(const ResolvedShots& shots, float chase_blend = 0.0f) {
    if (!shots.a) return shots.b ? *shots.b : Shot{};
    if (!shots.b || shots.a == shots.b) return *shots.a;
    return interpolate(*shots.a, *shots.b, clamp01(chase_blend));
}
inline Shot resolve_shot(ShotId id, CameraAngle angle, float chase_blend) {
    return blend_shots(lookup_shots(id, angle), chase_blend);
}

} // namespace dingosdk::s3cam
