#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/shake.rs (ShakeEffect::landing_impulse), shake_update.rs
// (ShakeEffect::update), shake_curve.rs (Bezier inversion) and skate-game camera/shake_data.rs +
// settings.rs (shake tunable names). Semantics are ported; VMX rounding constants are not. The
// recorded .shk sample files are EA data and are NOT used: the sample bank is generated here.
#include "Engine/Game/Camera/s3_math.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

// Camera shake for S3Cam: a landing impulse plus a speed-driven rumble, both read from one
// procedurally generated, mean-removed sample bank. Pure and header-only, no allocation per frame.
namespace dingosdk::s3cam {

// Cubic Bezier through 4 control points (x, y). `x` is the input axis and must be non-decreasing.
struct ShakeCurve {
    std::array<std::array<float, 2>, 4> points{{{0.0f, 0.0f}, {1.0f / 3, 1.0f / 3}, {2.0f / 3, 2.0f / 3}, {1.0f, 1.0f}}};

    bool valid() const {
        float previous = 0.0f;
        for (const auto& p : points) {
            if (!std::isfinite(p[0]) || !std::isfinite(p[1])) return false;
            if (p[0] < previous || p[0] > 1.0f) return false;
            previous = p[0];
        }
        return true;
    }
    // y at input x (shake_curve.rs sample): Newton inversion of the x polynomial, 10 steps from
    // t = 0.5, stopping early once x is within tolerance. `t` is kept in [0, 1].
    float sample(float input) const {
        float cx[4], cy[4];
        const auto coefficients = [&](std::size_t axis, float (&c)[4]) {
            const float p0 = points[0][axis], p1 = points[1][axis], p2 = points[2][axis], p3 = points[3][axis];
            c[0] = -p0 + 3 * p1 - 3 * p2 + p3;
            c[1] = 3 * p0 - 6 * p1 + 3 * p2;
            c[2] = -3 * p0 + 3 * p1;
            c[3] = p0;
        };
        coefficients(0, cx);
        coefficients(1, cy);
        float t = 0.5f;
        for (int iteration = 0; iteration < 10; ++iteration) {
            const float t2 = t * t;
            const float x = cx[0] * t2 * t + cx[1] * t2 + cx[2] * t + cx[3];
            const float residual = input - x;
            const float derivative = 3 * cx[0] * t2 + 2 * cx[1] * t + cx[2];
            if (iteration == 9 || !(std::abs(residual) > 1e-4f && std::abs(derivative) > 1.2e-7f)) break;
            t = clamp01(t + residual / derivative);
        }
        const float t2 = t * t;
        return cy[0] * t2 * t + cy[1] * t2 + cy[2] * t + cy[3];
    }
};

inline constexpr std::size_t shake_bank_size = 256;

// Procedural stand-in for the stock .shk files: band-limited noise, shake_bank_size samples,
// loops seamlessly, each of the 6 channels has its mean removed and its peak scaled to 1.
struct ShakeBank {
    std::array<Vec3, shake_bank_size> rotation{};    // pitch, yaw, roll
    std::array<Vec3, shake_bank_size> translation{}; // x, y, z (camera local)
};

inline constexpr std::uint32_t shake_bank_seed = 0x5C3A11EDu;

inline ShakeBank make_shake_bank(std::uint32_t seed = shake_bank_seed) {
    constexpr std::size_t n = shake_bank_size;
    std::uint32_t state = seed != 0 ? seed : 1u; // xorshift32
    const auto next_noise = [&state]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return static_cast<float>(state >> 8) * (2.0f / 16777216.0f) - 1.0f; // [-1, 1)
    };
    ShakeBank bank;
    for (std::size_t channel = 0; channel < 6; ++channel) {
        std::array<float, n> a{}, b{};
        for (auto& v : a) v = next_noise();
        // Two circular box filters (width 9, a triangular low-pass): band-limited and seamless.
        constexpr std::size_t half = 4;
        for (int pass = 0; pass < 2; ++pass) {
            for (std::size_t i = 0; i < n; ++i) {
                float sum = 0.0f;
                for (std::size_t k = 0; k < 2 * half + 1; ++k) sum += a[(i + n + k - half) % n];
                b[i] = sum / static_cast<float>(2 * half + 1);
            }
            a = b;
        }
        float mean = 0.0f;
        for (float v : a) mean += v;
        mean /= static_cast<float>(n);
        float peak = 0.0f;
        for (float& v : a) {
            v -= mean;
            peak = std::max(peak, std::abs(v));
        }
        const float gain = peak > 1e-9f ? 1.0f / peak : 0.0f;
        for (std::size_t i = 0; i < n; ++i) {
            Vec3& target = channel < 3 ? bank.rotation[i] : bank.translation[i];
            target[channel % 3] = a[i] * gain;
        }
    }
    return bank;
}
// Built once on first use (thread-safe), then read-only.
inline const ShakeBank& default_shake_bank() {
    static const ShakeBank bank = make_shake_bank();
    return bank;
}

struct ShakeSettings {
    ShakeCurve amplitude_curve{};  // speed fraction -> 0..1, scales [amplitude_min, amplitude_max]
    ShakeCurve frequency_curve{};  // speed fraction -> 0..1, scales [frequency_min, frequency_max]
    float one_shot_magnitude = 3.0f;      // TUNE: impulse at full landing speed (amplitude units)
    // TUNE: speed INTO the ground (-velocity . normal), m/s. From the in-game log: ollies land at
    // 3-4.5 m/s down, so 2.2 / 5.7 gives a flat ollie (3.5) ~12% of full, a 1 m drop (4.5) ~42%, a 3 m
    // drop (7.8) full; a curb hop (under 2.2) none. The old 4 / 12 was for the Rust's angle-weighted speed.
    float one_shot_min_velocity = 2.2f;   // TUNE: m/s, at or below this a landing gives no impulse
    float one_shot_max_velocity = 5.7f;   // TUNE: m/s, at/above this the impulse is full
    float one_shot_frequency = 2.0f;      // TUNE: playback rate multiplier while an impulse is active
    float one_shot_decay = 0.03f;         // TUNE: impulse *= (1 - decay) per fixed update (not dt-scaled)
    float amplitude_min = 0.0f;           // TUNE: speed rumble at standstill
    float amplitude_max = 0.15f;          // TUNE: speed rumble at top speed
    float amplitude_top_speed = 15.0f;    // TUNE: m/s (0 = always amplitude_min)
    float frequency_min = 0.5f;           // TUNE
    float frequency_max = 1.5f;           // TUNE
    float frequency_top_speed = 15.0f;    // TUNE: m/s (0 = always frequency_min)
    float data_fps = 30.0f;               // TUNE: bank samples per second at frequency 1
    float translation_multiplier = 0.02f; // TUNE: metres per amplitude unit
    float rotation_multiplier = 0.01f;    // TUNE: radians per amplitude unit
    float dutch_multiplier = 0.5f;        // TUNE: extra scale on the roll axis only
    float distance_full = 2.8f;           // m: full shake at or inside this distance
    float distance_zero = 3.4f;           // m: no shake at or beyond this distance
    float weight_rate = 5.0f;             // per second fade in/out
    float broken_bone_scale = 20.0f;      // landing impulse multiplier for a broken-bone landing

    bool valid() const {
        const float all[] = {one_shot_magnitude, one_shot_min_velocity, one_shot_max_velocity, one_shot_frequency,
                             one_shot_decay, amplitude_min, amplitude_max, amplitude_top_speed, frequency_min,
                             frequency_max, frequency_top_speed, data_fps, translation_multiplier,
                             rotation_multiplier, dutch_multiplier, distance_full, distance_zero, weight_rate,
                             broken_bone_scale};
        for (float v : all)
            if (!std::isfinite(v)) return false;
        return amplitude_curve.valid() && frequency_curve.valid() && one_shot_magnitude >= 0 &&
               one_shot_min_velocity >= 0 && one_shot_max_velocity > one_shot_min_velocity &&
               one_shot_frequency >= 0 && one_shot_decay >= 0 && one_shot_decay <= 1 && amplitude_min >= 0 &&
               amplitude_max >= 0 && amplitude_top_speed >= 0 && frequency_min >= 0 && frequency_max >= 0 &&
               frequency_top_speed >= 0 && data_fps > 0 && translation_multiplier >= 0 && rotation_multiplier >= 0 &&
               distance_zero > distance_full && weight_rate >= 0 && broken_bone_scale >= 0;
    }
};

struct ShakeOutput {
    float pitch = 0.0f, yaw = 0.0f, roll = 0.0f; // radians, added to the camera orientation
    Vec3 translation{0, 0, 0};                    // metres, camera-local (x right, y up, z back)
};

class Shake {
public:
    // Landing response (ShakeEffect::landing_impulse). `normal` is the ground normal, `velocity` the
    // pre-landing velocity. `magnitude_scale` is 1 normally, broken_bone_scale for a broken-bone
    // landing. Returns true when it raised the impulse; it never lowers it.
    //
    // Deviation from the Rust (from the in-game log): the Rust weights the speed by how head-on the hit
    // is, speed * (1 - angle / 90 degrees), where the angle is between the velocity and the surface
    // normal. A skater lands with a large forward speed and a small downward one (an ollie at 6.6 m/s
    // forward and 3.5 m/s down is 62 degrees off the normal), so that weighting keeps only about a third
    // of the speed and every normal landing fell under one_shot_min_velocity: the impulse was always
    // 0.000. It also made the same drop shake LESS the faster the skater rode. The weighted speed here is
    // the speed INTO the surface, -velocity . normal (the same as the Rust for a head-on hit, 0 when
    // sliding along the surface or moving away from it), so it depends on how hard the board hits, not on
    // how fast it was travelling sideways. CameraMan::kick_dip mirrors this.
    bool landing_impulse(const Vec3& normal, const Vec3& velocity, const ShakeSettings& s, float magnitude_scale = 1.0f) {
        const float speed = length(velocity);
        if (!std::isfinite(speed) || speed < 1e-5f) return false;
        const float weighted = -dot(normalized(normal, {0.0f, 1.0f, 0.0f}), velocity);
        if (!(weighted > 0.0f)) return false;
        const float fraction =
            clamp01((weighted - s.one_shot_min_velocity) / (s.one_shot_max_velocity - s.one_shot_min_velocity));
        const float impulse = fraction * fraction * s.one_shot_magnitude * magnitude_scale;
        if (!(impulse > impulse_)) return false;
        impulse_ = impulse;
        return true;
    }

    // Landing impulse from a 0..1 fraction of how hard the landing was (CameraMan measures it from
    // the fall height instead of the board's velocity, which flip tricks spike). Same squared shaping as
    // landing_impulse; one_shot_magnitude is the full-strength amount. Never lowers the impulse.
    bool landing_impulse_fraction(float fraction, const ShakeSettings& s, float magnitude_scale = 1.0f) {
        if (!std::isfinite(fraction)) return false;
        const float f = clamp01(fraction);
        const float impulse = f * f * s.one_shot_magnitude * magnitude_scale;
        if (!(impulse > impulse_)) return false;
        impulse_ = impulse;
        return true;
    }

    // One fixed update (ShakeEffect::update). `speed` is skater speed in m/s, `distance` the camera
    // distance to the subject in metres, `enabled` fades the whole effect in/out.
    ShakeOutput update(float dt, float speed, float distance, bool enabled, const ShakeSettings& s,
                       const ShakeBank& bank = default_shake_bank()) {
        weight_ = clamp01(weight_ + (enabled ? dt : -dt) * s.weight_rate);
        float amplitude = s.amplitude_min;
        if (s.amplitude_top_speed != 0.0f)
            amplitude = s.amplitude_min +
                        s.amplitude_curve.sample(clamp01(speed / s.amplitude_top_speed)) * (s.amplitude_max - s.amplitude_min);
        amplitude = (impulse_ + amplitude) * weight_;
        float frequency = s.frequency_min;
        if (s.frequency_top_speed != 0.0f)
            frequency = s.frequency_min +
                        s.frequency_curve.sample(clamp01(speed / s.frequency_top_speed)) * (s.frequency_max - s.frequency_min);
        if (impulse_ > 0.0f) frequency = s.one_shot_frequency;
        constexpr float count = static_cast<float>(shake_bank_size);
        time_ = std::fmod(time_ + s.data_fps * frequency * dt, count); // wrapped: the bank loops
        if (time_ < 0.0f) time_ += count;
        const float whole = std::floor(time_);
        const float fraction = time_ - whole;
        const std::size_t left = static_cast<std::size_t>(whole) % shake_bank_size;
        const std::size_t right = (left + 1) % shake_bank_size;
        const float fade = clamp01((s.distance_zero - distance) / (s.distance_zero - s.distance_full));
        const Vec3 rot = lerp(bank.rotation[left], bank.rotation[right], fraction);
        const Vec3 tra = lerp(bank.translation[left], bank.translation[right], fraction);
        const float rot_gain = amplitude * fade * s.rotation_multiplier;
        ShakeOutput out;
        out.pitch = rot[0] * rot_gain;
        out.yaw = rot[1] * rot_gain;
        out.roll = rot[2] * rot_gain * s.dutch_multiplier;
        out.translation = scale(tra, s.translation_multiplier * amplitude * fade);
        impulse_ *= 1.0f - s.one_shot_decay; // per update, not dt-scaled
        if (impulse_ < 0.005f) impulse_ = 0.0f;
        return out;
    }

    void reset() { *this = Shake{}; }
    float impulse() const { return impulse_; }
    float weight() const { return weight_; }
    float time() const { return time_; }

private:
    float time_ = 0.0f;
    float impulse_ = 0.0f;
    float weight_ = 0.0f;
};
} // namespace dingosdk::s3cam
