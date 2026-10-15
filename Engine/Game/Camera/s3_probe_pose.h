#pragma once
#include <array>
#include <cmath>
#include <cstddef>

namespace dingosdk::s3cam::probe {
// Phase 0 spike S1 (throwaway): a fixed chase camera behind the skater, used only to learn what
// owning the gameplay view breaks. Pure math so it is testable off the game.
using Vec3 = std::array<float, 3>;

inline Vec3 sub(const Vec3& a, const Vec3& b) { return {a[0] - b[0], a[1] - b[1], a[2] - b[2]}; }
inline Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
inline float dot(const Vec3& a, const Vec3& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline float length(const Vec3& a) { return std::sqrt(dot(a, a)); }
inline Vec3 scaled(const Vec3& a, float s) { return {a[0] * s, a[1] * s, a[2] * s}; }
inline Vec3 row(const std::array<float, 16>& m, std::size_t r) { return {m[r * 4], m[r * 4 + 1], m[r * 4 + 2]}; }

// The game's camera matrices are rows {right, up, backward, position} (first person writes them
// that way). Whether right x up is +backward or -backward is read off the live camera when the
// probe arms instead of assumed: +1 or -1, 0 if the matrix is not a rotation.
inline int handedness(const std::array<float, 16>& camera) {
    const float h = dot(cross(row(camera, 0), row(camera, 1)), row(camera, 2));
    return h > 0.9f ? 1 : h < -0.9f ? -1 : 0;
}

// Unit horizontal direction of `v` (Y is up), or nullopt-like {0,0,0} when |v_h| < `minimum`.
inline Vec3 horizontal(const Vec3& v, float minimum) {
    const float l = std::sqrt(v[0] * v[0] + v[2] * v[2]);
    if (!std::isfinite(l) || l < minimum) return {0, 0, 0};
    return {v[0] / l, 0, v[2] / l};
}

// Eases `heading` toward `target` (both horizontal unit vectors) by `amount` in [0, 1] and
// renormalises. A reversal (target opposite heading) turns through the side rather than
// collapsing through zero.
inline Vec3 turn_toward(const Vec3& heading, const Vec3& target, float amount) {
    Vec3 next{heading[0] + (target[0] - heading[0]) * amount, 0, heading[2] + (target[2] - heading[2]) * amount};
    float l = length(next);
    if (l < 1e-3f) { next = {-heading[2], 0, heading[0]}; l = 1; }
    return scaled(next, 1 / l);
}

// Writes rows {right, up, backward, position} of a camera at `eye` looking at `target`, keeping
// each row's fourth lane from `matrix` (native metadata, as first person keeps it). Returns false
// and leaves `matrix` untouched when the pose is degenerate (looking straight up or down).
inline bool look_at(std::array<float, 16>& matrix, const Vec3& eye, const Vec3& target, int hand) {
    if (hand != 1 && hand != -1) return false;
    const Vec3 to = sub(target, eye);
    const float distance = length(to);
    if (!std::isfinite(distance) || distance < 1e-3f) return false;
    const Vec3 back = scaled(to, -1 / distance);
    Vec3 right = scaled(cross({0, 1, 0}, back), static_cast<float>(hand));
    const float r = length(right);
    if (r < 1e-3f) return false;
    right = scaled(right, 1 / r);
    const Vec3 up = scaled(cross(back, right), static_cast<float>(hand));
    for (std::size_t i = 0; i < 3; ++i) {
        matrix[i] = right[i];
        matrix[4 + i] = up[i];
        matrix[8 + i] = back[i];
        matrix[12 + i] = eye[i];
    }
    return true;
}

// The spike's fixed framing: `back` metres behind along `heading`, `rise` above the skater's
// root, looking at a point `aim` above the root.
struct Framing {
    float back = 2.0f, rise = 0.6f, aim = 0.3f;
};
inline bool chase_pose(std::array<float, 16>& matrix, const Vec3& root, const Vec3& heading, int hand,
    const Framing& framing = {}) {
    const Vec3 eye{root[0] - heading[0] * framing.back, root[1] + framing.rise, root[2] - heading[2] * framing.back};
    return look_at(matrix, eye, {root[0], root[1] + framing.aim, root[2]}, hand);
}
} // namespace dingosdk::s3cam::probe
