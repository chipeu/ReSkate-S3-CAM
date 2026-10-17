#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// docs/hails-additions/21-low-camera.md (published Low vs High shot values) and
// crates/skate-game/src/camera/shot_data.rs (field set). No EA data: only the values that doc
// publishes are used; everything else is hand-picked and marked // TUNE.
#include "Engine/Game/Camera/s3_shot.h"

#include <array>
#include <cstddef>
#include <string_view>

// Built-in shot table (Low and High), looked up by name. constexpr data, no heap.
namespace dingosdk::s3cam {

enum class CameraAngle { Low, High };

struct NamedShot {
    std::string_view name; // lowercase, as shot_data.rs lowercases stock names
    CameraAngle angle;
    Shot shot;
};

namespace detail {
// Authored units: metres and degrees. Everything not passed here is a shared hand-picked default.
constexpr Shot make_shot(float distance, float elevation_deg, float pitch_deg, float board_offset) {
    Shot s{};
    s.distance = distance;
    s.lens_length = 12.0f; // §1.3: 12 for every stock shot
    s.position_elevation = elevation_deg * degrees;
    s.framing = {0.0f, 0.0f, pitch_deg * degrees};
    s.board_offset = board_offset;
    return s;
}
constexpr Shot with_smoothing(Shot s, float direction, float elevation, float yaw, float pitch) {
    s.smoothing = {direction, elevation, yaw, pitch};
    return s;
}
constexpr Shot with_weights(Shot s, const std::array<float, 10>& weights) {
    s.reference_weights = weights;
    return s;
}
constexpr Shot with_flags(Shot s, bool follow_in_air, bool drop_predictor) {
    s.follow_subject_in_air = follow_in_air;
    s.use_drop_predictor = drop_predictor;
    return s;
}
// Reference-point weight presets (order: Head, Hips, Grind, COM, Board, Trajectory, Anchor, Feet,
// DampedCOM, unnamed). All TUNE: the stock weights are not published.
inline constexpr std::array<float, 10> board_weights{0, 0, 0, 0, 1, 0, 0, 0, 0, 0};
inline constexpr std::array<float, 10> grind_weights{0, 0, 0.5f, 0, 0.5f, 0, 0, 0, 0, 0};   // TUNE
inline constexpr std::array<float, 10> air_weights{0, 0, 0, 0.25f, 0.5f, 0.25f, 0, 0, 0, 0}; // TUNE
inline constexpr std::array<float, 10> body_weights{0, 0.5f, 0, 0.5f, 0, 0, 0, 0, 0, 0};    // TUNE
} // namespace detail

inline constexpr std::size_t default_shot_count = 18;

inline constexpr std::array<NamedShot, default_shot_count> default_shots = [] {
    using namespace detail;
    return std::array<NamedShot, default_shot_count>{{
        // ---- Low camera ------------------------------------------------------------------
        // distance, elevation, pitch, board offset from §1.3 (21-low-camera.md).
        {"chase_flat_slow", CameraAngle::Low, with_smoothing(make_shot(1.8f, 7.0f, -4.0f, 0.9f), 0.85f, 0.85f, 0.8f, 0.8f)}, // smoothing TUNE
        {"chase_flat_fast", CameraAngle::Low, with_smoothing(make_shot(2.5f, 5.0f, -2.0f, 0.9f), 0.8f, 0.8f, 0.8f, 0.8f)},    // smoothing TUNE
        {"chase_up_slow", CameraAngle::Low, with_smoothing(make_shot(2.1f, -5.0f, -10.0f, 0.9f), 0.85f, 0.85f, 0.8f, 0.8f)}, // smoothing TUNE
        // Not published: looking down a slope, a little further back and higher than chase_flat_slow.
        {"chase_down", CameraAngle::Low, with_flags(make_shot(2.3f, 12.0f, 0.0f, 0.9f), true, true)}, // TUNE (all but lens)
        {"grind_flat_slow", CameraAngle::Low, with_weights(make_shot(1.5f, 7.0f, -10.0f, 0.6f), grind_weights)}, // weights TUNE
        // Ledge shots are not published: grind_flat_slow pushed a little to the side (heading offset) and back.
        {"grind_ledge_l", CameraAngle::Low, [] { Shot s = with_weights(make_shot(1.7f, 8.0f, -8.0f, 0.6f), grind_weights); s.position_heading = pi - 25.0f * degrees; return s; }()}, // TUNE
        {"grind_ledge_r", CameraAngle::Low, [] { Shot s = with_weights(make_shot(1.7f, 8.0f, -8.0f, 0.6f), grind_weights); s.position_heading = pi + 25.0f * degrees; return s; }()}, // TUNE
        {"far_manual", CameraAngle::Low, make_shot(2.35f, 13.0f, -2.0f, 0.9f)},
        {"close_manual", CameraAngle::Low, make_shot(1.1f, -5.0f, -8.0f, 0.5f)},
        // Air shots: not published. Low stays close and level; the rig holds height (manager_air.rs).
        {"low_ollie", CameraAngle::Low, with_flags(with_weights(make_shot(2.2f, 6.0f, -3.0f, 0.9f), air_weights), false, false)}, // TUNE
        {"air_high", CameraAngle::Low, with_flags(with_weights(make_shot(3.2f, 14.0f, 0.0f, 0.9f), air_weights), false, false)}, // TUNE: big air
        {"landing", CameraAngle::Low, with_smoothing(make_shot(2.0f, 6.0f, -4.0f, 0.9f), 0.7f, 0.7f, 0.7f, 0.7f)},         // TUNE
        {"wipeout", CameraAngle::Low, with_flags(with_weights(make_shot(3.0f, 15.0f, 0.0f, 0.5f), body_weights), false, false)}, // TUNE
        // ---- High camera -----------------------------------------------------------------
        {"high_chase", CameraAngle::High, make_shot(3.0f, 30.0f, 3.0f, 1.0f)},
        {"high_chase2", CameraAngle::High, make_shot(4.4f, 26.6f, 5.0f, 1.0f)},
        {"high_grind", CameraAngle::High, with_weights(make_shot(2.9f, 17.0f, 5.0f, 1.0f), grind_weights)}, // weights TUNE
        {"high_manual", CameraAngle::High, make_shot(2.25f, 19.0f, 0.0f, 1.0f)},
        {"bl_high_air", CameraAngle::High, with_flags(with_weights(make_shot(4.0f, 25.0f, 3.0f, 1.0f), air_weights), false, false)}, // TUNE
    }};
}();

// The shot called `name`, or nullptr. Linear scan: the table is tiny and this runs on shot change,
// not per frame.
inline const NamedShot* find_named_shot(std::string_view name) {
    for (const NamedShot& entry : default_shots)
        if (entry.name == name) return &entry;
    return nullptr;
}
inline const Shot* find_shot(std::string_view name) {
    const NamedShot* entry = find_named_shot(name);
    return entry ? &entry->shot : nullptr;
}
} // namespace dingosdk::s3cam
