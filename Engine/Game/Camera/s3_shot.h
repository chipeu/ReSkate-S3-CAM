#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/shot.rs (Shot, interpolate_from, blend_interval) and
// crates/skate-game/src/camera/shot_data.rs (field set and units). Semantics are ported; the
// bit-exact VMX constants are replaced by ordinary float constants (CLAUDE.md hard rule 6).
#include "Engine/Game/Camera/s3_math.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <optional>

// One authored camera shot and the maths to blend two of them. Pure and header-only; the stock
// table lives in s3_shots_default.h.
namespace dingosdk::s3cam {

// All angles are radians (shot_data.rs converts the authored degrees on load; we do the same at
// table build time). Distances are metres.
struct Shot {
    float distance = 2.0f;
    float lens_length = 12.0f; // 12 for every stock shot
    // Direction, elevation, yaw, pitch smoothing. 0 = none, 1 = hold. Rust Shot::new uses 0.8.
    std::array<float, 4> smoothing{0.8f, 0.8f, 0.8f, 0.8f};
    // Weights of the ten subject reference points (Head, Hips, Grind, COM, Board, Trajectory,
    // Anchor, Feet, DampedCOM, one unnamed). Shot::new weights the board only.
    std::array<float, 10> reference_weights{0, 0, 0, 0, 1, 0, 0, 0, 0, 0};
    float board_offset = 0.0f;
    float position_heading = pi; // behind the subject; not blended (see interpolate)
    float position_elevation = 0.0f;
    std::array<float, 3> framing{0, 0, 0}; // roll, yaw, pitch

    // Discrete options: never blended, they come from the target shot.
    bool follow_subject_in_air = true;
    bool mirror_for_stance = true;
    bool snap_to_reference_point = false;
    bool use_previous_shot = false;
    bool use_drop_predictor = false;
    bool use_free_camera_stick = false;
    bool avoidance_override = false;
};

namespace detail {
inline bool finite(float v) { return std::isfinite(v); }
template <std::size_t N> bool all_finite(const std::array<float, N>& values) {
    for (const float v : values)
        if (!finite(v)) return false;
    return true;
}
} // namespace detail

// True when the shot is safe to hand to the rig: every float finite, a positive distance and lens,
// smoothing in [0, 1] (above 1 would make the filter in filter_blend_value overshoot), elevation
// short of straight up/down, and non-negative reference weights that sum above the Rust
// reference_point cutoff (otherwise the reference point falls back to the subject).
inline bool valid(const Shot& s) {
    using namespace detail;
    if (!finite(s.distance) || !(s.distance > 0.0f)) return false;
    if (!finite(s.lens_length) || !(s.lens_length > 0.0f)) return false;
    if (!all_finite(s.smoothing) || !all_finite(s.reference_weights) || !all_finite(s.framing)) return false;
    if (!finite(s.board_offset) || !finite(s.position_heading) || !finite(s.position_elevation)) return false;
    for (const float v : s.smoothing)
        if (v < 0.0f || v > 1.0f) return false;
    float weight_sum = 0.0f;
    for (const float w : s.reference_weights) {
        if (w < 0.0f) return false;
        weight_sum += w;
    }
    if (!(weight_sum > 1e-4f)) return false;
    const float limit = pi / 2;
    return s.position_elevation > -limit && s.position_elevation < limit;
}

// Blend two shots (shot.rs interpolate_from). Floats ease with sine_blend(fraction) through
// interpolate_float style 0; discrete options come from `to` even at fraction 0. Heading is not
// blended (Rust leaves it to the shot's own evaluation), so the result carries `to`'s heading.
// The caller owns clamping `fraction` to [0, 1].
inline Shot interpolate(const Shot& from, const Shot& to, float fraction) {
    const auto blend = [fraction](float a, float b) { return interpolate_float(a, b, 0, fraction); };
    Shot out = to; // discrete flags and heading from the target
    out.distance = blend(from.distance, to.distance);
    out.lens_length = blend(from.lens_length, to.lens_length);
    for (std::size_t i = 0; i < out.smoothing.size(); ++i) out.smoothing[i] = blend(from.smoothing[i], to.smoothing[i]);
    for (std::size_t i = 0; i < out.reference_weights.size(); ++i)
        out.reference_weights[i] = blend(from.reference_weights[i], to.reference_weights[i]);
    out.board_offset = blend(from.board_offset, to.board_offset);
    out.position_elevation = blend(from.position_elevation, to.position_elevation);
    for (std::size_t i = 0; i < out.framing.size(); ++i) out.framing[i] = blend(from.framing[i], to.framing[i]);
    return out;
}

// Which two children of a blend tree a value falls between (shot.rs blend_interval, TU3 82E07240).
struct BlendInterval {
    std::size_t lower = 0;
    std::size_t upper = 0;
    float fraction = 1.0f; // 0 = all `lower`, 1 = all `upper`; feed it to interpolate()
};

// `present[i]` says whether child i exists; the list stops at the first absent child. Returns
// nullopt with no children. A value below the first point picks child 0 outright, one at/above the
// last point picks the last child outright; `lower`/`upper` may be equal at the ends. Points are
// expected ascending. A NaN value matches no point and so lands on the last child.
inline std::optional<BlendInterval> blend_interval(const std::array<float, 3>& points,
                                                   const std::array<bool, 3>& present, float value) {
    std::size_t count = 0;
    while (count < present.size() && present[count]) ++count;
    if (count == 0) return std::nullopt;
    for (std::size_t i = 0; i < count; ++i) {
        if (!(points[i] > value)) continue;
        if (i == 0) return BlendInterval{0, 0, 1.0f};
        return BlendInterval{i - 1, i, (value - points[i - 1]) / (points[i] - points[i - 1])};
    }
    return BlendInterval{count >= 2 ? count - 2 : 0, count - 1, 1.0f};
}
} // namespace dingosdk::s3cam
