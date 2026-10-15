#include "Engine/Game/Camera/s3_probe_pose.h"

#include <cmath>
#include <cstdio>
#include <string_view>

// Spike S1 (s3_probe_pose.h): the probe's chase pose must be a valid camera rotation in either
// handedness, sit behind the skater and look at it.
namespace {
using namespace dingosdk::s3cam::probe;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-4f) { return std::abs(a - b) <= tolerance; }
bool orthonormal(const std::array<float, 16>& m) {
    for (std::size_t i = 0; i < 3; ++i) {
        if (!near(length(row(m, i)), 1)) return false;
        for (std::size_t k = i + 1; k < 3; ++k)
            if (!near(dot(row(m, i), row(m, k)), 0)) return false;
    }
    return true;
}

void hands() {
    std::array<float, 16> right_handed{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    std::array<float, 16> left_handed{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1};
    std::array<float, 16> sheared{1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    expect(handedness(right_handed) == 1, "right x up = backward reads as +1");
    expect(handedness(left_handed) == -1, "right x up = -backward reads as -1");
    expect(handedness(sheared) == 0, "a matrix that is not a rotation is refused");
}

void chase() {
    for (const int hand : {1, -1}) {
        std::array<float, 16> m{};
        m[3] = 7; m[7] = 8; m[11] = 9; m[15] = 1;
        const Vec3 root{10, 2, -5};
        const Vec3 heading{0, 0, 1};
        expect(chase_pose(m, root, heading, hand), "a level chase pose is built");
        expect(orthonormal(m), "the pose is a rotation");
        expect(handedness(m) == hand, "the pose keeps the live camera's handedness");
        expect(near(m[12], 10) && near(m[13], 2.6f) && near(m[14], -7), "eye 2 m behind and 0.6 m above the root");
        // Looking at the skater: -backward points from the eye to the aim point.
        const Vec3 view = scaled(row(m, 2), -1);
        const Vec3 to = sub({10, 2.3f, -5}, row(m, 3));
        expect(near(dot(view, scaled(to, 1 / length(to))), 1), "the camera looks at the aim point");
        expect(row(m, 1)[1] > 0.9f, "up stays up");
        expect(m[3] == 7 && m[7] == 8 && m[11] == 9 && m[15] == 1, "each row's fourth lane is kept");
    }
}

void degenerate() {
    std::array<float, 16> m{};
    m[0] = 42;
    expect(!look_at(m, {0, 5, 0}, {0, 0, 0}, 1), "straight down has no right axis");
    expect(!look_at(m, {0, 0, 0}, {0, 0, 0}, 1), "zero distance is refused");
    expect(!look_at(m, {0, 0, 0}, {1, 0, 0}, 0), "unknown handedness is refused");
    expect(m[0] == 42, "a refused pose leaves the matrix untouched");
}

void heading() {
    const auto still = horizontal({0.2f, 5, 0.1f}, 1.0f);
    expect(still[0] == 0 && still[2] == 0, "vertical motion or crawling gives no heading");
    const auto east = horizontal({4, -3, 0}, 1.0f);
    expect(near(east[0], 1) && east[1] == 0 && near(east[2], 0), "heading ignores vertical speed");
    const auto half = turn_toward({0, 0, 1}, {1, 0, 0}, 0.5f);
    expect(near(length(half), 1) && half[0] > 0 && half[2] > 0, "easing turns part way and stays unit length");
    const auto reverse = turn_toward({0, 0, 1}, {0, 0, -1}, 0.5f);
    expect(near(length(reverse), 1), "a reversal turns through the side instead of collapsing");
}
} // namespace

int main() {
    hands();
    chase();
    degenerate();
    heading();
    if (failures) {
        std::printf("%d s3cam probe pose test(s) failed\n", failures);
        return 1;
    }
    std::printf("s3cam probe pose tests passed\n");
    return 0;
}
