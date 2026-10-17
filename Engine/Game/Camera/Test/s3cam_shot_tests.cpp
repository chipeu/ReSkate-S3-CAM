#include "Engine/Game/Camera/s3_shots_default.h"

#include <cmath>
#include <cstdio>
#include <string_view>

// s3_shot.h / s3_shots_default.h: shot blending, the blend-interval chooser and the stock table.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-5f) { return std::abs(a - b) <= tolerance; }

Shot shot_a() {
    Shot s;
    s.distance = 2.0f;
    s.lens_length = 12.0f;
    s.smoothing = {0.5f, 0.6f, 0.7f, 0.8f};
    s.reference_weights = {1, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    s.board_offset = 1.0f;
    s.position_elevation = 0.1f;
    s.framing = {0.0f, 0.2f, 0.4f};
    s.follow_subject_in_air = true;
    s.mirror_for_stance = false;
    s.use_drop_predictor = false;
    s.use_free_camera_stick = false;
    s.position_heading = 1.0f;
    return s;
}
Shot shot_b() {
    Shot s = shot_a();
    s.distance = 4.0f;
    s.lens_length = 20.0f;
    s.smoothing = {0.1f, 0.2f, 0.3f, 0.4f};
    s.reference_weights = {0, 0, 0, 0, 1, 0, 0, 0, 0, 0};
    s.board_offset = 3.0f;
    s.position_elevation = 0.5f;
    s.framing = {0.2f, 0.6f, 1.0f};
    s.follow_subject_in_air = false;
    s.mirror_for_stance = true;
    s.use_drop_predictor = true;
    s.use_free_camera_stick = true;
    s.position_heading = 2.0f;
    return s;
}

void blend_endpoints() {
    const Shot a = shot_a(), b = shot_b();
    const Shot at0 = interpolate(a, b, 0.0f);
    expect(near(at0.distance, 2.0f) && near(at0.lens_length, 12.0f), "t=0 floats are the source");
    expect(near(at0.smoothing[3], 0.8f) && near(at0.board_offset, 1.0f), "t=0 smoothing and offset are the source");
    expect(near(at0.reference_weights[0], 1.0f) && near(at0.reference_weights[4], 0.0f), "t=0 weights are the source");
    expect(near(at0.framing[2], 0.4f) && near(at0.position_elevation, 0.1f), "t=0 framing and elevation are the source");

    const Shot mid = interpolate(a, b, 0.5f);
    expect(near(mid.distance, 3.0f), "t=0.5 distance is the midpoint (sine ease is 0.5 at 0.5)");
    expect(near(mid.lens_length, 16.0f), "t=0.5 lens");
    expect(near(mid.smoothing[0], 0.3f) && near(mid.smoothing[3], 0.6f), "t=0.5 smoothing");
    expect(near(mid.reference_weights[0], 0.5f) && near(mid.reference_weights[4], 0.5f), "t=0.5 weights");
    expect(near(mid.board_offset, 2.0f) && near(mid.position_elevation, 0.3f), "t=0.5 offset and elevation");
    expect(near(mid.framing[0], 0.1f) && near(mid.framing[1], 0.4f) && near(mid.framing[2], 0.7f), "t=0.5 framing");

    const Shot at1 = interpolate(a, b, 1.0f);
    expect(near(at1.distance, 4.0f) && near(at1.lens_length, 20.0f), "t=1 floats are the target");
    expect(near(at1.smoothing[2], 0.3f) && near(at1.framing[1], 0.6f), "t=1 smoothing and framing are the target");
    expect(near(at1.reference_weights[4], 1.0f) && near(at1.board_offset, 3.0f), "t=1 weights and offset are the target");

    const Shot quarter = interpolate(a, b, 0.25f);
    expect(quarter.distance < 2.0f + 2.0f * 0.25f, "the ease is slower than linear early on");
    expect(near(quarter.distance, 2.0f + 2.0f * sine_blend(0.25f)), "uses sine_blend");
}

void discrete_flags() {
    const Shot a = shot_a(), b = shot_b();
    for (const float t : {0.0f, 0.5f, 1.0f}) {
        const Shot r = interpolate(a, b, t);
        expect(r.follow_subject_in_air == b.follow_subject_in_air, "follow_subject_in_air from the target");
        expect(r.mirror_for_stance == b.mirror_for_stance, "mirror_for_stance from the target");
        expect(r.use_drop_predictor == b.use_drop_predictor, "use_drop_predictor from the target");
        expect(r.use_free_camera_stick == b.use_free_camera_stick, "use_free_camera_stick from the target");
        expect(near(r.position_heading, b.position_heading), "heading is not blended: it stays the target's");
    }
    const Shot back = interpolate(b, a, 0.0f); // even at t = 0 the flags are already the target's
    expect(back.follow_subject_in_air && !back.use_drop_predictor, "flags switch at t=0 when the target differs");
    expect(valid(interpolate(a, b, 0.37f)), "a blend of valid shots is valid");
}

void interval() {
    const std::array<float, 3> p{1.0f, 5.0f, 10.0f};
    const std::array<bool, 3> all{true, true, true};
    const auto none = blend_interval(p, {false, true, true}, 3.0f);
    expect(!none.has_value(), "no first child: nothing is published");

    const auto below = blend_interval(p, all, 0.0f);
    expect(below && below->lower == 0 && below->upper == 0 && near(below->fraction, 1.0f), "below the first point is child 0");
    const auto at_first = blend_interval(p, all, 1.0f);
    expect(at_first && at_first->lower == 0 && at_first->upper == 1 && near(at_first->fraction, 0.0f), "at the first point starts the first span");
    const auto in_first = blend_interval(p, all, 3.0f);
    expect(in_first && in_first->lower == 0 && in_first->upper == 1 && near(in_first->fraction, 0.5f), "mid first span");
    const auto in_second = blend_interval(p, all, 7.5f);
    expect(in_second && in_second->lower == 1 && in_second->upper == 2 && near(in_second->fraction, 0.5f), "mid second span");
    const auto at_last = blend_interval(p, all, 10.0f);
    expect(at_last && at_last->lower == 1 && at_last->upper == 2 && near(at_last->fraction, 1.0f), "at the last point is the last child");
    const auto above = blend_interval(p, all, 99.0f);
    expect(above && above->lower == 1 && above->upper == 2 && near(above->fraction, 1.0f), "above the last point is the last child");

    const auto one_low = blend_interval(p, {true, false, true}, 0.0f);
    expect(one_low && one_low->lower == 0 && one_low->upper == 0 && near(one_low->fraction, 1.0f), "one child, below");
    const auto one_high = blend_interval(p, {true, false, false}, 50.0f);
    expect(one_high && one_high->lower == 0 && one_high->upper == 0 && near(one_high->fraction, 1.0f), "one child, above: no underflow");
    const auto two = blend_interval(p, {true, true, false}, 3.0f);
    expect(two && two->lower == 0 && two->upper == 1 && near(two->fraction, 0.5f), "two children");
    const auto two_above = blend_interval(p, {true, true, false}, 50.0f);
    expect(two_above && two_above->lower == 0 && two_above->upper == 1 && near(two_above->fraction, 1.0f), "two children, above");
    const auto nan = blend_interval(p, all, std::nanf(""));
    expect(nan && nan->upper == 2 && near(nan->fraction, 1.0f), "NaN lands on the last child");
    const auto gap = blend_interval(p, {true, false, true}, 5.0f); // list stops at the first absent child
    expect(gap && gap->upper == 0, "children after a gap are ignored");
}

void validity() {
    expect(valid(Shot{}), "the default Shot is valid");
    Shot s;
    s.distance = 0; expect(!valid(s), "zero distance"); s = Shot{};
    s.distance = std::nanf(""); expect(!valid(s), "NaN distance"); s = Shot{};
    s.lens_length = -1; expect(!valid(s), "negative lens"); s = Shot{};
    s.smoothing[2] = 1.5f; expect(!valid(s), "smoothing above 1"); s = Shot{};
    s.reference_weights = {}; expect(!valid(s), "all-zero weights"); s = Shot{};
    s.reference_weights[1] = -0.5f; expect(!valid(s), "negative weight"); s = Shot{};
    s.position_elevation = 2.0f; expect(!valid(s), "elevation past straight up"); s = Shot{};
    s.framing[0] = INFINITY; expect(!valid(s), "infinite framing");
}

void table() {
    expect(default_shots.size() == default_shot_count, "table size");
    for (const NamedShot& entry : default_shots) {
        expect(valid(entry.shot), "every default shot is valid");
        expect(near(entry.shot.lens_length, 12.0f), "lens 12 for every shot");
        const Shot* found = find_shot(entry.name);
        expect(found == &entry.shot, "every default shot is findable by name");
        for (const NamedShot& other : default_shots)
            expect(&other == &entry || other.name != entry.name, "names are unique");
    }
    expect(find_shot("no_such_shot") == nullptr && find_shot("") == nullptr, "unknown names give nullptr");
    expect(find_shot("Chase_Flat_Slow") == nullptr, "names are lowercase and exact");
    for (const std::string_view name :
         {"chase_flat_slow", "chase_flat_fast", "chase_up_slow", "chase_down", "grind_flat_slow", "grind_ledge_l",
          "grind_ledge_r", "far_manual", "close_manual", "low_ollie", "air_high", "landing", "wipeout", "high_chase",
          "high_chase2", "high_grind", "high_manual", "bl_high_air"})
        expect(find_shot(name) != nullptr, "shot name present");
}

struct Published {
    std::string_view name;
    CameraAngle angle;
    float distance, elevation_deg, pitch_deg, board_offset;
};

void section_1_3() {
    const Published rows[] = {
        {"chase_flat_slow", CameraAngle::Low, 1.8f, 7.0f, -4.0f, 0.9f},
        {"chase_flat_fast", CameraAngle::Low, 2.5f, 5.0f, -2.0f, 0.9f},
        {"chase_up_slow", CameraAngle::Low, 2.1f, -5.0f, -10.0f, 0.9f},
        {"high_chase", CameraAngle::High, 3.0f, 30.0f, 3.0f, 1.0f},
        {"high_chase2", CameraAngle::High, 4.4f, 26.6f, 5.0f, 1.0f},
        {"grind_flat_slow", CameraAngle::Low, 1.5f, 7.0f, -10.0f, 0.6f},
        {"high_grind", CameraAngle::High, 2.9f, 17.0f, 5.0f, 1.0f},
        {"far_manual", CameraAngle::Low, 2.35f, 13.0f, -2.0f, 0.9f},
        {"close_manual", CameraAngle::Low, 1.1f, -5.0f, -8.0f, 0.5f},
        {"high_manual", CameraAngle::High, 2.25f, 19.0f, 0.0f, 1.0f},
    };
    for (const Published& row : rows) {
        const NamedShot* e = find_named_shot(row.name);
        expect(e != nullptr, "published shot exists");
        if (!e) continue;
        expect(e->angle == row.angle, "published shot is in the right camera");
        expect(near(e->shot.distance, row.distance), "section 1.3 distance");
        expect(near(e->shot.position_elevation, row.elevation_deg * degrees, 1e-5f), "section 1.3 elevation");
        expect(near(e->shot.framing[2], row.pitch_deg * degrees, 1e-5f), "section 1.3 framing pitch");
        expect(near(e->shot.board_offset, row.board_offset), "section 1.3 board offset");
    }
    // The summary the doc draws: Low is closer and nearly level, High is further and looks down on the board.
    float low_max_dist = 0, high_min_dist = 1e9f;
    for (const NamedShot& e : default_shots) {
        const bool chase_like = e.name == "chase_flat_slow" || e.name == "chase_flat_fast" || e.name == "chase_up_slow" ||
                                e.name == "high_chase" || e.name == "high_chase2";
        if (!chase_like) continue;
        if (e.angle == CameraAngle::Low) {
            low_max_dist = std::fmax(low_max_dist, e.shot.distance);
            expect(e.shot.position_elevation <= 7.0f * degrees + 1e-5f && e.shot.position_elevation >= -5.0f * degrees - 1e-5f,
                   "Low chase elevation within -5..+7 degrees");
        } else {
            high_min_dist = std::fmin(high_min_dist, e.shot.distance);
            expect(e.shot.position_elevation >= 26.0f * degrees, "High chase elevation 26.6..30 degrees");
        }
    }
    expect(low_max_dist < high_min_dist, "every Low chase is closer than every High chase");
}
} // namespace

int main() {
    blend_endpoints();
    discrete_flags();
    interval();
    validity();
    table();
    section_1_3();
    if (failures) {
        std::printf("%d s3cam shot test(s) failed\n", failures);
        return 1;
    }
    std::printf("s3cam shot tests passed\n");
    return 0;
}
