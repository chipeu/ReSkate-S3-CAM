#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/shot.rs (sine_blend, interpolate_float, filter_blend_value),
// rig_tracking.rs (wrap_vmx) and compass.rs (blend). Semantics are ported; the bit-exact VMX
// constants are replaced by ordinary float constants (CLAUDE.md hard rule 6).
#include <array>
#include <cmath>
#include <cstddef>

// Shared math for the S3Cam camera core (Engine/Game/Camera). Pure and header-only: no Windows,
// no game ABI, so every file built on it is unit-testable off the game.
namespace dingosdk::s3cam {
inline constexpr float pi = 3.14159265358979f;
inline constexpr float tau = 6.28318530717959f;
inline constexpr float degrees = pi / 180.0f; // multiply degrees by this for radians

using Vec3 = std::array<float, 3>;
inline Vec3 add(const Vec3& a, const Vec3& b) { return {a[0] + b[0], a[1] + b[1], a[2] + b[2]}; }
inline Vec3 sub(const Vec3& a, const Vec3& b) { return {a[0] - b[0], a[1] - b[1], a[2] - b[2]}; }
inline Vec3 scale(const Vec3& a, float s) { return {a[0] * s, a[1] * s, a[2] * s}; }
inline float dot(const Vec3& a, const Vec3& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
inline float length(const Vec3& a) { return std::sqrt(dot(a, a)); }
// Unit vector, or `fallback` when `a` is too short (or not finite) to have a direction.
inline Vec3 normalized(const Vec3& a, const Vec3& fallback = {0, 0, 0}) {
    const float l = length(a);
    return std::isfinite(l) && l > 1e-6f ? scale(a, 1 / l) : fallback;
}
inline Vec3 lerp(const Vec3& a, const Vec3& b, float t) { return add(a, scale(sub(b, a), t)); }

// Angle reduced to [-pi, pi) (wrap_vmx). Non-finite input passes through so callers can reject it.
inline float wrap_angle(float angle) {
    if (!std::isfinite(angle)) return angle;
    float reduced = angle - std::trunc(angle / tau) * tau; // (-tau, tau)
    if (reduced < -pi) reduced += tau;
    if (reduced >= pi) reduced -= tau;
    return reduced;
}
// Moves angle `from` toward `to` by `weight` along the shorter way round (compass.rs blend).
inline float blend_angle(float from, float to, float weight) {
    return wrap_angle(from + wrap_angle(to - from) * weight);
}

// Skate 3's transition ease: 0.5 + 0.5 sin(pi t - pi/2). 0 -> 0, 0.5 -> 0.5, 1 -> 1, zero slope at
// both ends. The caller owns clamping `fraction` (shot.rs sine_blend).
inline float sine_blend(float fraction) { return 0.5f + 0.5f * std::sin(pi * fraction - pi / 2); }

// Shot field interpolation styles (shot.rs interpolate_float): 0 eases with sine_blend, 1 jumps to
// the target, anything else keeps the source.
inline float interpolate_float(float from, float to, unsigned style, float fraction) {
    if (style == 0) return from + (to - from) * sine_blend(fraction);
    if (style == 1) return to;
    return from;
}

// Blend-tree input filter (shot.rs filter_blend_value): moves `previous` toward `raw` by
// (1 - smoothing)^2 of the gap, then clamps to [minimum, maximum]. Deliberately NOT scaled by dt:
// Skate 3 ran it once per camera update, so S3Cam runs it on the fixed step only.
inline float filter_blend_value(float previous, float raw, float smoothing, float minimum, float maximum) {
    const float response = 1.0f - smoothing;
    const float next = previous + response * response * (raw - previous);
    const float lower = minimum - next >= 0.0f ? minimum : next;
    return maximum - lower >= 0.0f ? lower : maximum;
}

inline float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
} // namespace dingosdk::s3cam
