#pragma once
#include <array>
#include <cmath>
#include <cstddef>
#include <optional>

namespace dingosdk::s3cam {
// Phase 0 spike S4: skate.'s effective gravity, measured from the game rather than assumed.
// While the board is airborne (physics state 200/201) the probe records the board root's height
// each tick; on touchdown it fits y = a + b*t + c*t^2 by least squares, and g = -2c. The
// trajectory predictor (s3_trajectory.h) needs this number; Skate 3's own predictor used the
// physics world's gravity, which skate. may scale.
struct GravityFitResult {
    double gravity{};  // m/s^2, positive downward
    double rms{};      // residual of the fit, metres; a clean ballistic arc is well under 1 cm
    double duration{}; // seconds of the arc that were fitted
    std::size_t samples{};
};

// Fixed storage: the probe runs every frame, so recording must never allocate.
class ArcRecorder {
public:
    static constexpr std::size_t capacity = 1024; // over 7 s at 144 fps; longer arcs keep their start
    // Takeoff and touchdown samples still carry contact forces (the pop, the landing). Trimmed
    // from each end before fitting.
    static constexpr std::size_t trim = 3;
    static constexpr std::size_t minimum_samples = 12;
    static constexpr double minimum_duration = 0.25;

    void clear() noexcept { count_ = 0; }
    std::size_t size() const noexcept { return count_; }
    // Ignores non-finite values and time that does not move forward (a paused or repeated tick).
    void add(double time, double height) noexcept {
        if (!std::isfinite(time) || !std::isfinite(height) || count_ == capacity) return;
        if (count_ && time <= samples_[count_ - 1].time) return;
        samples_[count_++] = {time, height};
    }
    std::optional<GravityFitResult> fit() const noexcept {
        if (count_ < minimum_samples + 2 * trim) return std::nullopt;
        const std::size_t first = trim, last = count_ - trim; // [first, last)
        const auto n = static_cast<double>(last - first);
        const double duration = samples_[last - 1].time - samples_[first].time;
        if (duration < minimum_duration) return std::nullopt;
        // Centre time for conditioning: raw game clocks are large, and t^4 sums lose precision.
        double mean = 0;
        for (std::size_t i = first; i < last; ++i) mean += samples_[i].time;
        mean /= n;
        double s1 = 0, s2 = 0, s3 = 0, s4 = 0, y0 = 0, y1 = 0, y2 = 0;
        for (std::size_t i = first; i < last; ++i) {
            const double t = samples_[i].time - mean, t2 = t * t, y = samples_[i].height;
            s1 += t; s2 += t2; s3 += t2 * t; s4 += t2 * t2;
            y0 += y; y1 += y * t; y2 += y * t2;
        }
        // Normal equations for [a b c], solved by Cramer's rule (3x3, symmetric).
        const double m[3][3]{{n, s1, s2}, {s1, s2, s3}, {s2, s3, s4}};
        const double det = determinant(m);
        if (!std::isfinite(det) || std::abs(det) < 1e-18) return std::nullopt;
        const double mc[3][3]{{n, s1, y0}, {s1, s2, y1}, {s2, s3, y2}};
        const double ma[3][3]{{y0, s1, s2}, {y1, s2, s3}, {y2, s3, s4}};
        const double mb[3][3]{{n, y0, s2}, {s1, y1, s3}, {s2, y2, s4}};
        const double a = determinant(ma) / det, b = determinant(mb) / det, c = determinant(mc) / det;
        double squared = 0;
        for (std::size_t i = first; i < last; ++i) {
            const double t = samples_[i].time - mean;
            const double error = samples_[i].height - (a + b * t + c * t * t);
            squared += error * error;
        }
        GravityFitResult result{-2.0 * c, std::sqrt(squared / n), duration, last - first};
        if (!std::isfinite(result.gravity) || !std::isfinite(result.rms)) return std::nullopt;
        return result;
    }

private:
    struct Sample { double time{}, height{}; };
    static double determinant(const double (&m)[3][3]) noexcept {
        return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
               m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
               m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    }
    std::array<Sample, capacity> samples_{};
    std::size_t count_{};
};
} // namespace dingosdk::s3cam
