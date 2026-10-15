#include "Engine/Game/Camera/s3_shake.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string_view>

// s3_shake.h: landing impulse, decay, speed shake, distance fade and the procedural sample bank.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-5f) { return std::abs(a - b) <= tolerance; }

const Vec3 up{0, 1, 0};
Vec3 head_on(float speed) { return {0, -speed, 0}; }
float landing(float speed, const ShakeSettings& s = {}) {
    Shake shake;
    shake.landing_impulse(up, head_on(speed), s);
    return shake.impulse();
}
// Largest rotation/translation magnitude over one second of fixed updates.
float peak(float distance, float speed = 15.0f, float impulse_speed = 0.0f) {
    const ShakeSettings s;
    Shake shake;
    if (impulse_speed > 0) shake.landing_impulse(up, head_on(impulse_speed), s);
    float best = 0;
    for (int i = 0; i < 120; ++i) {
        const ShakeOutput o = shake.update(1.0f / 120, speed, distance, true, s);
        best = std::max({best, std::abs(o.pitch), std::abs(o.yaw), std::abs(o.roll), std::abs(o.translation[0]),
                         std::abs(o.translation[1]), std::abs(o.translation[2])});
    }
    return best;
}

void settings_validity() {
    expect(ShakeSettings{}.valid(), "defaults are valid");
    ShakeSettings s;
    s.one_shot_max_velocity = s.one_shot_min_velocity;
    expect(!s.valid(), "max velocity must exceed min velocity");
    s = {};
    s.one_shot_decay = 1.5f;
    expect(!s.valid(), "decay above 1 is invalid");
    s = {};
    s.distance_zero = s.distance_full;
    expect(!s.valid(), "fade end must be beyond fade start");
    s = {};
    s.rotation_multiplier = NAN;
    expect(!s.valid(), "non-finite is invalid");
    s = {};
    s.amplitude_curve.points[1][0] = 0.9f; // x goes backwards (0.9 then 0.667)
    expect(!s.valid(), "curve x must be non-decreasing");
}

void impulse_scaling() {
    const ShakeSettings s;
    expect(landing(s.one_shot_min_velocity, s) == 0.0f, "at the minimum velocity there is no impulse");
    expect(landing(1.0f, s) == 0.0f, "a slow landing gives no impulse");
    expect(near(landing(s.one_shot_max_velocity, s), s.one_shot_magnitude), "full speed gives the full magnitude");
    expect(near(landing(100.0f, s), s.one_shot_magnitude), "faster than the maximum is clamped");
    const float mid = 0.5f * (s.one_shot_min_velocity + s.one_shot_max_velocity); // fraction 0.5
    expect(near(landing(mid, s), 0.25f * s.one_shot_magnitude), "impulse is proportional to fraction squared");
    const float q = s.one_shot_min_velocity + 0.25f * (s.one_shot_max_velocity - s.one_shot_min_velocity);
    expect(near(landing(q, s) * 4, landing(mid, s)), "half the fraction gives a quarter of the impulse");
    expect(!Shake{}.landing_impulse(up, {0, 0, 0}, s), "no velocity does nothing");
    Shake bone;
    bone.landing_impulse(up, head_on(s.one_shot_max_velocity), s, s.broken_bone_scale);
    expect(near(bone.impulse(), 20 * s.one_shot_magnitude), "broken-bone landing is x20");
}

void grazing() {
    const ShakeSettings s;
    const float v = 12.0f; // full impulse head on
    const float head = landing(v, s);
    Shake a;
    a.landing_impulse(up, {v * std::sin(45 * degrees), -v * std::cos(45 * degrees), 0}, s);
    // 45 degrees keeps half the speed: v' = 6, fraction = (6-4)/8 = 0.25
    expect(near(a.impulse(), 0.0625f * s.one_shot_magnitude, 1e-4f), "45 degrees off the normal halves the speed");
    expect(a.impulse() < head, "grazing gives less than head on");
    Shake b;
    b.landing_impulse(up, {v * std::sin(80 * degrees), -v * std::cos(80 * degrees), 0}, s);
    expect(b.impulse() < a.impulse(), "more grazing gives less");
    Shake c;
    const bool raised = c.landing_impulse(up, {v, 0, 0}, s);
    expect(!raised && c.impulse() == 0.0f, "sliding along the surface (90 degrees) gives zero");
    Shake d;
    d.landing_impulse(up, {v * std::sin(10 * degrees), -v * std::cos(10 * degrees), 0}, s);
    expect(d.impulse() < head && d.impulse() > a.impulse(), "10 degrees is slightly less than head on");
}

void only_raises() {
    const ShakeSettings s;
    Shake shake;
    expect(shake.landing_impulse(up, head_on(10), s), "first landing raises");
    const float first = shake.impulse();
    expect(!shake.landing_impulse(up, head_on(7), s), "a weaker landing reports no change");
    expect(shake.impulse() == first, "a weaker landing does not lower the impulse");
    expect(!shake.landing_impulse(up, head_on(10), s), "an equal landing is not a raise");
    expect(shake.landing_impulse(up, head_on(12), s), "a stronger landing raises");
    expect(shake.impulse() > first, "and the value goes up");
}

void decay() {
    const ShakeSettings s;
    Shake shake;
    shake.landing_impulse(up, head_on(12), s);
    shake.update(1.0f / 120, 0, 1, true, s);
    expect(near(shake.impulse(), s.one_shot_magnitude * (1 - s.one_shot_decay), 1e-5f), "one update multiplies by (1 - decay)");
    // decay is per update: a different dt must not change it
    Shake slow;
    slow.landing_impulse(up, head_on(12), s);
    slow.update(1.0f / 30, 0, 1, true, s);
    expect(near(slow.impulse(), shake.impulse(), 1e-6f), "decay is not scaled by dt");
    float previous = shake.impulse();
    bool monotone = true;
    int updates = 1;
    while (shake.impulse() > 0.0f && updates < 5000) {
        shake.update(1.0f / 120, 0, 1, true, s);
        ++updates;
        if (shake.impulse() > previous) monotone = false;
        previous = shake.impulse();
    }
    expect(monotone, "impulse never grows while decaying");
    expect(shake.impulse() == 0.0f && updates < 5000, "decay reaches exactly 0");
    Shake snap;
    snap.landing_impulse(up, head_on(12), s);
    ShakeSettings fast = s;
    fast.one_shot_magnitude = 0.0051f; // just above the snap threshold
    Shake tiny;
    tiny.landing_impulse(up, head_on(12), fast);
    tiny.update(1.0f / 120, 0, 1, true, fast);
    expect(tiny.impulse() == 0.0f, "values under 0.005 snap to 0");
}

void frequency_and_curves() {
    ShakeSettings s;
    Shake quiet;
    quiet.update(0.1f, 0, 1, true, s);
    expect(near(quiet.time(), s.data_fps * s.frequency_min * 0.1f, 1e-4f), "at rest the speed curve gives frequency_min");
    Shake fast;
    fast.update(0.1f, 100, 1, true, s);
    expect(near(fast.time(), s.data_fps * s.frequency_max * 0.1f, 1e-3f), "above top speed gives frequency_max");
    Shake hit;
    hit.landing_impulse(up, head_on(12), s);
    hit.update(0.1f, 100, 1, true, s);
    expect(near(hit.time(), s.data_fps * s.one_shot_frequency * 0.1f, 1e-4f), "an active impulse forces the one-shot frequency");
    // curve: linear default maps x to y; a flat one holds
    const ShakeCurve linear;
    expect(near(linear.sample(0), 0, 1e-3f) && near(linear.sample(1), 1, 1e-3f) && near(linear.sample(0.5f), 0.5f, 1e-3f),
           "default curve is the identity");
    ShakeCurve ease;
    ease.points = {{{0, 0}, {0.5f, 0}, {0.5f, 1}, {1, 1}}};
    expect(ease.sample(0.25f) < 0.25f && ease.sample(0.75f) > 0.75f, "an s-curve is slow at the start and fast after");
    // amplitude follows speed: faster rumbles harder
    expect(peak(1, 15) > peak(1, 3), "more speed gives more shake");
    ShakeSettings none = s;
    none.amplitude_top_speed = 0;
    Shake flat;
    float best = 0;
    for (int i = 0; i < 120; ++i) best = std::max(best, std::abs(flat.update(1.0f / 120, 15, 1, true, none).pitch));
    expect(best == 0.0f, "top speed 0 means amplitude_min (0 by default)");
}

void roll_axis() {
    ShakeSettings s;
    s.amplitude_min = s.amplitude_max = 1;
    Shake a, b;
    ShakeSettings doubled = s;
    doubled.dutch_multiplier = 2 * s.dutch_multiplier;
    float roll_a = 0, roll_b = 0, pitch_a = 0, pitch_b = 0;
    for (int i = 0; i < 60; ++i) {
        const ShakeOutput x = a.update(1.0f / 60, 5, 1, true, s), y = b.update(1.0f / 60, 5, 1, true, doubled);
        roll_a = std::max(roll_a, std::abs(x.roll));
        roll_b = std::max(roll_b, std::abs(y.roll));
        pitch_a = std::max(pitch_a, std::abs(x.pitch));
        pitch_b = std::max(pitch_b, std::abs(y.pitch));
    }
    expect(roll_a > 0 && near(roll_b, 2 * roll_a, 1e-6f), "the dutch multiplier scales roll");
    expect(near(pitch_a, pitch_b, 1e-9f), "the dutch multiplier leaves pitch alone");
}

void weight_fade() {
    const ShakeSettings s;
    Shake shake;
    shake.update(0.1f, 5, 1, true, s);
    expect(near(shake.weight(), 0.5f), "weight fades in at 5 per second");
    shake.update(1.0f, 5, 1, true, s);
    expect(near(shake.weight(), 1), "weight clamps at 1");
    shake.update(0.1f, 5, 1, false, s);
    expect(near(shake.weight(), 0.5f), "weight fades out at 5 per second");
    shake.update(1.0f, 5, 1, false, s);
    expect(shake.weight() == 0.0f, "weight clamps at 0");
    Shake off;
    off.landing_impulse(up, head_on(12), s);
    const ShakeOutput o = off.update(1.0f / 120, 15, 1, false, s);
    expect(o.pitch == 0 && o.yaw == 0 && o.roll == 0 && o.translation[0] == 0, "disabled shake outputs nothing");
}

void distance_fade() {
    const ShakeSettings s;
    const float full = peak(1.0f);
    expect(full > 0, "close shake is non-zero");
    expect(near(peak(s.distance_full), full, 1e-7f), "full strength at the fade start");
    expect(peak(0.0f) == full, "closer than the fade start is still full");
    const float mid = 0.5f * (s.distance_full + s.distance_zero);
    expect(near(peak(mid), 0.5f * full, 1e-6f), "half way through the fade is half strength");
    expect(peak(s.distance_zero) == 0.0f, "zero at the fade end");
    expect(peak(10.0f) == 0.0f, "zero beyond the fade end");
    expect(peak(3.0f) < full && peak(3.0f) > peak(3.3f), "strength falls steadily with distance");
    expect(peak(1.0f, 15, 12) > full, "an impulse adds to the speed shake");
}

void bank() {
    const ShakeBank a = make_shake_bank(), b = make_shake_bank();
    bool same = true, finite = true;
    for (std::size_t i = 0; i < shake_bank_size; ++i)
        for (std::size_t k = 0; k < 3; ++k) {
            same = same && a.rotation[i][k] == b.rotation[i][k] && a.translation[i][k] == b.translation[i][k];
            finite = finite && std::isfinite(a.rotation[i][k]) && std::isfinite(a.translation[i][k]);
        }
    expect(same, "the bank is deterministic");
    expect(finite, "the bank is finite");
    expect(shake_bank_size == 256, "the bank has 256 samples");
    for (std::size_t k = 0; k < 3; ++k) {
        float rot_sum = 0, tra_sum = 0, rot_peak = 0, tra_peak = 0;
        for (std::size_t i = 0; i < shake_bank_size; ++i) {
            rot_sum += a.rotation[i][k];
            tra_sum += a.translation[i][k];
            rot_peak = std::max(rot_peak, std::abs(a.rotation[i][k]));
            tra_peak = std::max(tra_peak, std::abs(a.translation[i][k]));
        }
        expect(std::abs(rot_sum / 256) < 1e-5f, "rotation channel has zero mean");
        expect(std::abs(tra_sum / 256) < 1e-5f, "translation channel has zero mean");
        expect(near(rot_peak, 1, 1e-5f) && near(tra_peak, 1, 1e-5f), "each channel peaks at 1");
    }
    bool differ = false;
    for (std::size_t i = 0; i < shake_bank_size; ++i)
        differ = differ || a.rotation[i][0] != a.translation[i][0] || a.rotation[i][0] != a.rotation[i][1];
    expect(differ, "rotation and translation channels are independent");
    const ShakeBank other = make_shake_bank(1234u);
    bool seed_matters = false;
    for (std::size_t i = 0; i < shake_bank_size; ++i) seed_matters = seed_matters || other.rotation[i][0] != a.rotation[i][0];
    expect(seed_matters, "a different seed gives a different bank");
    // band-limited: neighbouring samples are close compared with the full range
    float max_step = 0;
    for (std::size_t i = 0; i < shake_bank_size; ++i)
        max_step = std::max(max_step, std::abs(a.rotation[(i + 1) % shake_bank_size][0] - a.rotation[i][0]));
    expect(max_step < 0.5f, "samples are smooth (band-limited), including across the loop point");
    expect(&default_shake_bank() == &default_shake_bank(), "the default bank is built once");
    expect(default_shake_bank().rotation[7][1] == a.rotation[7][1], "the default bank is the seeded bank");
}
} // namespace

int main() {
    settings_validity();
    impulse_scaling();
    grazing();
    only_raises();
    decay();
    frequency_and_curves();
    roll_axis();
    weight_fade();
    distance_fade();
    bank();
    if (failures) {
        std::printf("%d s3cam shake test(s) failed\n", failures);
        return 1;
    }
    std::printf("s3cam shake tests passed\n");
    return 0;
}
