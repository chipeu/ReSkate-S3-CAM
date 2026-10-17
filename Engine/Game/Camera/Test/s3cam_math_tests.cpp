#include "Engine/Game/Camera/s3_math.h"

#include <cmath>
#include <cstdio>
#include <string_view>

// s3_math.h: the helpers every S3Cam camera file shares, against the Rust reference semantics.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-5f) { return std::abs(a - b) <= tolerance; }

void wrapping() {
    expect(near(wrap_angle(0), 0), "0 stays 0");
    expect(near(wrap_angle(pi / 2), pi / 2), "inside the range is unchanged");
    expect(near(wrap_angle(3 * pi / 2), -pi / 2), "270 degrees wraps to -90");
    expect(near(wrap_angle(-3 * pi / 2), pi / 2), "-270 degrees wraps to 90");
    expect(near(wrap_angle(5 * tau + 0.25f), 0.25f, 1e-4f), "whole turns are removed");
    expect(near(wrap_angle(pi), -pi), "pi maps to the lower bound");
    expect(std::isnan(wrap_angle(NAN)), "non-finite passes through for the caller to reject");
    for (float a = -20; a < 20; a += 0.37f) {
        const float w = wrap_angle(a);
        expect(w >= -pi && w < pi, "always in [-pi, pi)");
    }
}

void angle_blending() {
    const float from = 170 * degrees, to = -170 * degrees;
    const float half = blend_angle(from, to, 0.5f);
    expect(near(std::abs(half), pi, 1e-4f), "blending across +-180 goes the short way (through 180)");
    expect(near(blend_angle(0.1f, 0.5f, 1), 0.5f), "weight 1 reaches the target");
    expect(near(blend_angle(0.1f, 0.5f, 0), 0.1f), "weight 0 stays");
}

void easing() {
    expect(near(sine_blend(0), 0), "ease starts at 0");
    expect(near(sine_blend(0.5f), 0.5f), "ease is half way at half time");
    expect(near(sine_blend(1), 1), "ease ends at 1");
    expect(sine_blend(0.01f) < 0.01f && sine_blend(0.99f) > 0.99f, "ease is slow at both ends");
    expect(near(interpolate_float(2, 4, 0, 0.5f), 3), "style 0 eases");
    expect(near(interpolate_float(2, 4, 1, 0.1f), 4), "style 1 jumps to the target");
    expect(near(interpolate_float(2, 4, 7, 0.9f), 2), "other styles keep the source");
}

void blend_filter() {
    expect(near(filter_blend_value(0, 10, 0, -100, 100), 10), "no smoothing takes the raw value");
    expect(near(filter_blend_value(0, 10, 0.5f, -100, 100), 2.5f), "smoothing 0.5 moves (0.5)^2 of the gap");
    expect(near(filter_blend_value(0, 10, 1, -100, 100), 0), "smoothing 1 holds");
    expect(near(filter_blend_value(0, 10, 0, -1, 1), 1), "clamped to the maximum");
    expect(near(filter_blend_value(0, -10, 0, -1, 1), -1), "clamped to the minimum");
    float value = 0;
    for (int i = 0; i < 400; ++i) value = filter_blend_value(value, 5, 0.8f, 0, 10); // 4% of the gap per update
    expect(near(value, 5, 1e-3f), "repeated updates converge on the raw value");
}

void vectors() {
    expect(near(length({3, 4, 0}), 5), "length");
    const auto n = normalized({0, 0, 2});
    expect(near(n[2], 1), "normalized");
    const auto f = normalized({0, 0, 0}, {1, 0, 0});
    expect(near(f[0], 1), "a zero vector takes the fallback");
    const auto c = cross({1, 0, 0}, {0, 1, 0});
    expect(near(c[2], 1), "x cross y is z");
    const auto m = lerp({0, 0, 0}, {2, 4, 6}, 0.5f);
    expect(near(m[1], 2), "lerp");
    const std::array<float, 16> right_handed{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    const std::array<float, 16> left_handed{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1};
    const std::array<float, 16> sheared{1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1};
    expect(handedness(right_handed) == 1, "right x up = backward reads as +1");
    expect(handedness(left_handed) == -1, "right x up = -backward reads as -1");
    expect(handedness(sheared) == 0, "a matrix that is not a rotation is refused");
}
} // namespace

int main() {
    wrapping();
    angle_blending();
    easing();
    blend_filter();
    vectors();
    if (failures) {
        std::printf("%d s3cam math test(s) failed\n", failures);
        return 1;
    }
    std::printf("s3cam math tests passed\n");
    return 0;
}
