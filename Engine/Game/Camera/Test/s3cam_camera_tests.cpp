#include "Engine/Game/Camera/s3_camera.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// s3_camera.h: the CameraMan pipeline driven by scripted skaters. The card's session (ride -> ollie ->
// land -> grind -> manual -> bail, 10 s = 600 ticks at 60 fps) runs at 30, 60 and 144 fps.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(float a, float b, float tolerance = 1e-4f) { return std::abs(a - b) <= tolerance; }
bool near3(const Vec3& a, const Vec3& b, float tolerance) { return length(sub(a, b)) <= tolerance; }
bool finite_frame(const Frame& f) {
    for (const Vec3* v : {&f.right, &f.up, &f.back, &f.pos})
        for (float c : *v)
            if (!std::isfinite(c)) return false;
    return std::isfinite(f.fov_deg);
}
// right, up, back are unit, mutually perpendicular, right x up = +back.
bool orthonormal(const Frame& f, float tolerance = 1e-4f) {
    return near(length(f.right), 1.0f, tolerance) && near(length(f.up), 1.0f, tolerance) &&
           near(length(f.back), 1.0f, tolerance) && near(dot(f.right, f.up), 0.0f, tolerance) &&
           near(dot(f.right, f.back), 0.0f, tolerance) && near(dot(f.up, f.back), 0.0f, tolerance) &&
           near3(cross(f.right, f.up), f.back, tolerance);
}

// ---------------------------------------------------------------- analytic world and skater

constexpr float g = 10.1f;
constexpr float ride_height = 0.95f; // root above the ground riding
constexpr float ride_speed = 6.0f;

// Flat ground at y = 0: the segment crosses it going down.
std::optional<GroundHit> flat_ground(const Vec3& a, const Vec3& b) noexcept {
    if (a[1] >= 0.0f && b[1] < 0.0f) {
        const float f = a[1] / (a[1] - b[1]);
        return GroundHit{lerp(a, b, f), {0, 1, 0}};
    }
    return std::nullopt;
}

// The card's session as a function of time, so any frame rate samples the same skater:
//   0.0-1.6 ride   1.6 ollie (pop 0.08 s, then air)   land   3.2-4.4 grind right ledge   post-grind 0.1 s
//   5.0-7.0 manual   7.5 bail (velocity decays to rest over 1 s, offboard)   10.0 end
struct Session {
    float jump_time = 1.6f;
    float jump_speed = 3.5f; // vertical m/s at takeoff
    float grind_start = 3.2f, grind_end = 4.4f;
    float manual_start = 5.0f, manual_end = 7.0f;
    float bail_time = 7.5f;
    float length = 10.0f;
    bool bail_offboard = true;

    float air_duration() const { return 2.0f * jump_speed / g; }
    float land_time() const { return jump_time + air_duration(); }

    SubjectSnapshot at(float t) const {
        SubjectSnapshot s;
        s.valid = true;
        s.time = t;
        s.forward = {0, 0, 1};
        s.ground_normal = {0, 1, 0};
        float vz = ride_speed, z;
        if (t < bail_time) {
            z = ride_speed * t;
        } else {
            const float u = std::min(t - bail_time, 1.0f);
            vz = ride_speed * (1.0f - u);
            z = ride_speed * bail_time + ride_speed * (u - 0.5f * u * u) + (t - bail_time - u) * 0.0f;
        }
        float y = ride_height, vy = 0.0f;
        std::uint32_t state = physics_state::ride;
        if (t >= jump_time && t < land_time()) {
            const float since_jump = t - jump_time;
            y = ride_height + jump_speed * since_jump - 0.5f * g * since_jump * since_jump;
            vy = jump_speed - g * since_jump;
            state = since_jump < 0.08f ? physics_state::pop : physics_state::air;
        }
        if (t >= grind_start && t < grind_end) {
            state = 400;
            s.grind_side = 1;
        } else if (t >= grind_end && t < grind_end + 0.1f) {
            state = physics_state::post_grind;
        }
        s.manual = t >= manual_start && t < manual_end;
        if (t >= bail_time) {
            s.bailing = true;
            if (bail_offboard) {
                state = physics_state::offboard;
                s.onboard = false;
            }
        }
        s.position = {0, y, z};
        s.velocity = {0, vy, vz};
        s.physics_state = state;
        s.ground_clearance = y; // ground is y = 0
        return s;
    }
};

struct Recording {
    std::vector<Frame> frames;
    std::vector<ShotId> sequence; // consecutive duplicates collapsed
    float max_step = 0.0f;        // largest position change between consecutive non-reset frames
    bool all_finite = true, all_orthonormal = true;
    int resets = 0;
    float min_height = 1e9f;
};

Recording record(CameraMan& cam, const Session& session, float fps, float aspect = 16.0f / 9.0f) {
    Recording r;
    const int count = static_cast<int>(std::lround(session.length * fps));
    const float dt = 1.0f / fps;
    FrameExtras extras;
    extras.aspect = aspect;
    for (int i = 0; i < count; ++i) {
        const float t = static_cast<float>(i) * dt;
        const Frame& f = cam.update(dt, session.at(t), flat_ground, extras);
        if (f.debug.reset) ++r.resets;
        else if (!r.frames.empty()) r.max_step = std::max(r.max_step, length(sub(f.pos, r.frames.back().pos)));
        r.all_finite = r.all_finite && finite_frame(f);
        r.all_orthonormal = r.all_orthonormal && orthonormal(f);
        r.min_height = std::min(r.min_height, f.pos[1]);
        if (r.sequence.empty() || r.sequence.back() != f.shot) r.sequence.push_back(f.shot);
        r.frames.push_back(f);
    }
    return r;
}

const std::vector<ShotId>& expected_sequence() {
    static const std::vector<ShotId> seq{ShotId::Chase,       ShotId::AirNormal, ShotId::Landing,  ShotId::Chase,
                                          ShotId::GrindLedgeR, ShotId::Chase,     ShotId::ManualFar, ShotId::Chase,
                                          ShotId::Wipeout};
    return seq;
}
std::string describe(const std::vector<ShotId>& seq) {
    std::string out;
    for (const ShotId id : seq) {
        out += shot_id_name(id);
        out += ' ';
    }
    return out;
}

// ---------------------------------------------------------------- tests

void test_session(float fps, const char* label) {
    CameraMan cam;
    const Recording r = record(cam, Session{}, fps);
    const std::string tag = std::string("session @") + label + " fps: ";
    if (r.sequence != expected_sequence()) std::printf("  got: %s\n  want: %s\n", describe(r.sequence).c_str(), describe(expected_sequence()).c_str());
    expect(r.sequence == expected_sequence(), tag + "shot sequence ride, air, landing, ride, grind, ride, manual, ride, wipeout");
    expect(r.all_finite, tag + "no NaN or inf in any frame");
    expect(r.all_orthonormal, tag + "every frame is orthonormal with right x up = back");
    expect(r.max_step <= 0.5f, tag + "no frame moves more than 0.5 m");
    std::printf("  session @%s fps: %zu frames, max step %.3f m, lowest camera %.2f m\n", label, r.frames.size(),
                static_cast<double>(r.max_step), static_cast<double>(r.min_height));
    expect(r.resets == 1, tag + "only the first frame is a cut");
    expect(r.min_height >= 0.0f, tag + "the camera never goes under the floor");
    expect(r.frames.front().valid && r.frames.back().valid, tag + "frames are valid");
}

void test_session_600_ticks_at_60() {
    CameraMan cam;
    Session session;
    const Recording r = record(cam, session, 60.0f);
    expect(r.frames.size() == 600, "the card's session is 600 ticks at 60 fps");
    expect(r.max_step < 0.2f, "60 fps: steps are small at 6 m/s (well under the 0.5 m bound)");
}

void test_fps_agree() {
    // The same skater at three frame rates: the fixed-step sim makes the camera nearly independent of the frame rate.
    CameraMan a, b, c;
    const Recording r30 = record(a, Session{}, 30.0f);
    const Recording r60 = record(b, Session{}, 60.0f);
    const Recording r144 = record(c, Session{}, 144.0f);
    const auto at = [](const Recording& r, float fps, float t) { return r.frames[static_cast<std::size_t>(std::lround(t * fps))].pos; };
    float worst = 0.0f;
    for (const float t : {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 9.0f}) {
        worst = std::max(worst, length(sub(at(r30, 30.0f, t), at(r60, 60.0f, t))));
        worst = std::max(worst, length(sub(at(r144, 144.0f, t), at(r60, 60.0f, t))));
    }
    if (worst > 0.25f) std::printf("  worst fps disagreement %.3f m\n", static_cast<double>(worst));
    expect(worst <= 0.25f, "camera position agrees across 30 / 60 / 144 fps within 0.25 m");
}

void test_shot_framing_and_air_hold() {
    // Alpha 4: this test checks the Alpha 3 framing and air hold, so the new settings that deliberately change them
    // are neutral here: the grind / manual focus (lower look target), the air height follow and the rise.
    // s3cam_layers_tests covers those settings on their own.
    CameraSettings classic;
    classic.look.manual_focus = classic.look.grind_focus = 1.0f;
    classic.air_camera.follow_height = 0.0f;
    classic.air_camera.rise_degrees = 0.0f;
    CameraMan cam;
    expect(cam.set_settings(classic), "classic settings accepted");
    Session session;
    const Recording r = record(cam, session, 60.0f);
    float worst_angle = 0.0f, ground_y = 0.0f, max_air_rise = -1e9f;
    for (std::size_t i = 0; i < r.frames.size(); ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const SubjectSnapshot s = session.at(t);
        if (t < 1.0f || t > session.bail_time) continue;
        const Frame& f = r.frames[i];
        const Vec3 to_subject = normalized(sub(s.position, f.pos));
        const float angle = std::acos(std::clamp(dot(scale(f.back, -1.0f), to_subject), -1.0f, 1.0f)) / degrees;
        worst_angle = std::max(worst_angle, angle);
        if (t > 1.5f && t < 1.6f) ground_y = std::max(ground_y, f.pos[1]);
        if (t > session.jump_time + 0.15f && t < session.land_time() - 0.05f) max_air_rise = std::max(max_air_rise, f.pos[1]);
    }
    if (worst_angle > 25.0f) std::printf("  worst angle off the subject %.1f deg\n", static_cast<double>(worst_angle));
    expect(worst_angle <= 25.0f, "the skater stays within 25 degrees of the view axis through the session");
    // The 0.6 m ollie: the camera must not follow the board up (the air hold).
    expect(max_air_rise - ground_y < 0.2f, "ollie: the camera height does not chase the board");

    // The rig's debug mirrors the story: a landing prediction exists in the air and is flat.
    CameraMan c2;
    bool saw_prediction = false;
    float landing_delta = 9.0f, predicted_time = 0.0f;
    for (int i = 0; i < 600; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const Frame& f = c2.update(1.0f / 60.0f, session.at(t), flat_ground);
        if (f.debug.airborne && f.debug.prediction_valid && t > session.jump_time + 0.2f) {
            saw_prediction = true;
            landing_delta = f.debug.predicted_landing_delta;
            predicted_time = f.debug.predicted_air_time;
        }
    }
    expect(saw_prediction, "air: a landing prediction is reported");
    expect(std::abs(landing_delta) < 0.01f, "air: a flat ollie predicts a landing delta of about 0 (surface-level datum)");
    expect(std::abs(predicted_time - session.air_duration()) < 0.1f, "air: predicted air time is the real one");
}

void test_big_air_shot() {
    CameraMan cam;
    Session session;
    session.jump_speed = 8.0f; // 3.2 m apex
    session.length = 6.0f;
    session.grind_start = session.grind_end = 100.0f;
    session.manual_start = session.manual_end = 100.0f;
    session.bail_time = 100.0f;
    const Recording r = record(cam, session, 60.0f);
    bool big = false;
    for (const ShotId id : r.sequence) big = big || id == ShotId::AirBig;
    expect(big, "a 3 m jump selects the big air shot");
    expect(r.all_finite && r.all_orthonormal, "big air: frames stay finite and orthonormal");
    expect(r.max_step <= 0.5f, "big air: continuous");
}

void test_bail_while_onboard_flag() {
    // Bailing but still flagged onboard works the same as the offboard bail.
    CameraMan cam;
    Session session;
    session.bail_offboard = false;
    const Recording r = record(cam, session, 60.0f);
    expect(r.sequence == expected_sequence(), "onboard bail: same sequence");
}

void test_low_vs_high() {
    CameraSettings low, high;
    high.angle = CameraAngle::High;
    CameraMan a, b;
    expect(a.set_settings(low) && b.set_settings(high), "settings accepted");
    const Recording rl = record(a, Session{}, 60.0f);
    const Recording rh = record(b, Session{}, 60.0f);
    expect(rh.sequence.size() >= 5, "High runs the same graph");
    // On the opening ride, the High camera sits farther back and higher.
    const SubjectSnapshot s = Session{}.at(1.0f);
    const Frame& fl = rl.frames[60];
    const Frame& fh = rh.frames[60];
    const float dl = length(sub(fl.pos, s.position)), dh = length(sub(fh.pos, s.position));
    expect(dh > dl + 0.8f, "High camera is farther from the skater than Low");
    expect(fh.pos[1] > fl.pos[1] + 0.5f, "High camera is higher than Low");
    expect(rh.max_step <= 0.5f && rh.all_finite && rh.all_orthonormal, "High session is continuous and orthonormal");
    // Switching the angle live blends through a transition, not a cut.
    CameraMan c;
    Session session;
    int resets = 0;
    float max_step = 0.0f;
    Vec3 previous{0, 0, 0};
    for (int i = 0; i < 240; ++i) {
        if (i == 120) {
            CameraSettings s2;
            s2.angle = CameraAngle::High;
            c.set_settings(s2);
        }
        const Frame& f = c.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground);
        if (f.debug.reset) ++resets;
        else max_step = std::max(max_step, length(sub(f.pos, previous)));
        previous = f.pos;
    }
    expect(resets == 1, "live angle switch is not a cut");
    expect(max_step <= 0.5f, "live angle switch keeps the camera continuous");
}

void test_reset_snaps() {
    CameraMan cam;
    Session session;
    for (int i = 0; i < 120; ++i) cam.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground);
    // Teleport 100 m away: a cut, with the camera landing at its shot distance behind the skater.
    SubjectSnapshot s = session.at(2.0f);
    s.position = {100.0f, ride_height, -40.0f};
    s.forward = {1, 0, 0};
    s.velocity = {ride_speed, 0, 0};
    s.physics_state = physics_state::ride;
    s.ground_clearance = ride_height;
    const Frame& f = cam.update(1.0f / 60.0f, s, flat_ground);
    expect(f.debug.reset, "a teleport is reported as a reset");
    const float distance = length(sub(f.pos, s.position));
    expect(distance > 1.0f && distance < 3.5f, "after the cut the camera is at its shot distance from the skater");
    expect(f.pos[0] < s.position[0] - 0.5f, "after the cut the camera is behind the new heading (+X travel)");
    // The following frames are not a catch-up from the old place.
    s.position[0] += 0.1f;
    const Frame prev = f;
    const Frame& f2 = cam.update(1.0f / 60.0f, s, flat_ground);
    expect(!f2.debug.reset && length(sub(f2.pos, prev.pos)) < 0.3f, "no catch-up motion after a cut");

    // request_reset snaps to the subject without a teleport.
    CameraMan c2;
    for (int i = 0; i < 60; ++i) c2.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground);
    c2.request_reset();
    const Frame& f3 = c2.update(1.0f / 60.0f, session.at(1.0f), flat_ground);
    expect(f3.debug.reset, "request_reset cuts on the next update");
    expect(c2.update(1.0f / 60.0f, session.at(1.02f), flat_ground).debug.reset == false, "and only once");
    // Preset change cuts.
    CameraSettings np;
    np.preset = CameraPreset::NativePlus;
    c2.set_settings(np);
    NativePose pose;
    FrameExtras ex;
    ex.native = &pose;
    expect(c2.update(1.0f / 60.0f, session.at(1.04f), flat_ground, ex).debug.reset, "changing the preset cuts");

    // A long gap with no usable data also cuts when data returns.
    CameraMan c3;
    for (int i = 0; i < 60; ++i) c3.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground);
    SubjectSnapshot bad = session.at(1.0f);
    bad.valid = false;
    for (int i = 0; i < 60; ++i) c3.update(1.0f / 60.0f, bad, flat_ground);
    expect(c3.update(1.0f / 60.0f, session.at(2.0f), flat_ground).debug.reset, "data returning after 1 s cuts");
}

void test_invalid_holds() {
    CameraMan cam;
    Session session;
    Frame last;
    for (int i = 0; i < 100; ++i) last = cam.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground);
    SubjectSnapshot bad = session.at(2.0f);
    bad.valid = false;
    const auto same = [&](const Frame& f) {
        return f.right == last.right && f.up == last.up && f.back == last.back && f.pos == last.pos && f.fov_deg == last.fov_deg &&
               f.shot == last.shot;
    };
    Frame f = cam.update(1.0f / 60.0f, bad, flat_ground);
    expect(f.debug.held && same(f), "valid = false holds the last frame");
    SubjectSnapshot nan = session.at(2.0f);
    nan.position[1] = std::nanf("");
    f = cam.update(1.0f / 60.0f, nan, flat_ground);
    expect(f.debug.held && same(f), "a NaN position holds the last frame");
    SubjectSnapshot degenerate = session.at(2.0f);
    degenerate.forward = {0, 0, 0};
    f = cam.update(1.0f / 60.0f, degenerate, flat_ground);
    expect(f.debug.held && same(f), "a zero forward holds the last frame");
    f = cam.update(std::nanf(""), session.at(2.0f), flat_ground);
    expect(f.debug.held && same(f), "a NaN dt holds the last frame");
    f = cam.update(-0.01f, session.at(2.0f), flat_ground);
    expect(f.debug.held && same(f), "a negative dt holds the last frame");
    SubjectSnapshot off = session.at(2.0f);
    off.onboard = false;
    f = cam.update(1.0f / 60.0f, off, flat_ground);
    expect(f.debug.held && same(f), "off the board and not bailing holds (the game camera owns that case)");
    // Recovery: valid data resumes without a cut after a short gap.
    f = cam.update(1.0f / 60.0f, session.at(100.0f / 60.0f + 0.05f), flat_ground);
    expect(!f.debug.held && !f.debug.reset && finite_frame(f), "data resuming after a short gap continues smoothly");
    // Never-valid camera: a default frame flagged invalid.
    CameraMan fresh;
    const Frame& e = fresh.update(1.0f / 60.0f, bad, flat_ground);
    expect(!e.valid && e.debug.held, "before any usable snapshot the frame is not valid");
    // dt = 0 re-publishes without stepping.
    Frame before = cam.frame();
    const Frame& z = cam.update(0.0f, session.at(2.0f), flat_ground);
    expect(z.debug.steps == 0 && !z.debug.held && near3(z.pos, before.pos, 0.2f), "dt = 0 runs no steps");
}

void test_fixed_step_accumulator() {
    CameraMan cam;
    Session session;
    cam.update(1.0f / 60.0f, session.at(0.0f), flat_ground);
    int total = 0;
    for (int i = 1; i <= 144; ++i) total += cam.update(1.0f / 144.0f, session.at(static_cast<float>(i) / 144.0f), flat_ground).debug.steps;
    expect(total == 60 || total == 59, "1 s of 144 fps frames runs 60 fixed steps");
    CameraMan c30;
    c30.update(1.0f / 30.0f, session.at(0.0f), flat_ground);
    total = 0;
    for (int i = 1; i <= 30; ++i) total += c30.update(1.0f / 30.0f, session.at(static_cast<float>(i) / 30.0f), flat_ground).debug.steps;
    expect(total == 60 || total == 59, "1 s of 30 fps frames runs 60 fixed steps");
    // A stall is capped, not spiralled.
    const Frame& stalled = cam.update(5.0f, session.at(7.0f), flat_ground);
    expect(stalled.debug.steps <= cam.settings().pipeline.max_steps_per_update, "a 5 s stall runs at most max_steps_per_update steps");
    expect(stalled.debug.accumulator < 1.0f / 59.0f, "and leaves less than one step in the accumulator");
    // The step rate is the Rust camera STEP, exactly 1/60 s, and not a tunable.
    expect(fixed_hz == 60.0f && fixed_step == 1.0f / 60.0f && rig_step == fixed_step, "the fixed step is exactly 60 Hz (manager_state.rs STEP)");
    CameraMan c60;
    c60.update(1.0f / 60.0f, session.at(0.0f), flat_ground);
    total = 0;
    for (int i = 1; i <= 60; ++i) total += c60.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground).debug.steps;
    expect(total == 60 || total == 59, "60 fps frames run one fixed step each");
}

void test_fov() {
    CameraMan cam;
    const SubjectSnapshot s = Session{}.at(0.5f);
    FrameExtras ex;
    ex.aspect = 16.0f / 9.0f;
    const float fov169 = cam.update(1.0f / 60.0f, s, flat_ground, ex).fov_deg;
    expect(near(fov169, lens_field_of_view_degrees(12.0f, 16.0f / 9.0f), 1e-3f), "fov follows lens_length 12 and the aspect (manager_frame.rs)");
    expect(fov169 > 55.0f && fov169 < 80.0f, "fov for lens 12 at 16:9 is the usual 60s");
    ex.aspect = 4.0f / 3.0f;
    CameraMan c2;
    const float fov43 = c2.update(1.0f / 60.0f, s, flat_ground, ex).fov_deg;
    expect(fov43 > fov169, "a narrower aspect gives a larger fov value (the Rust divides by aspect + 1)");
    expect(near(lens_field_of_view_degrees(12.0f, 1.0f), std::sqrt((2.0f * std::atan(35.0f / 24.0f) / degrees) * (2.0f * std::atan(35.0f / 24.0f) / degrees) / 2.0f), 1e-3f),
           "fov formula at aspect 1");
    expect(lens_field_of_view_degrees(0.0f, 1.0f) == 0.0f && lens_field_of_view_degrees(12.0f, std::nanf("")) == 0.0f, "bad fov inputs give 0");
    // A bad aspect keeps the last good one.
    ex.aspect = std::nanf("");
    const float kept = c2.update(1.0f / 60.0f, s, flat_ground, ex).fov_deg;
    // Alpha 2: the speed term of the fov extras eases in from the cut (0.6 deg at 6 m/s, about 0.03 deg
    // after one step), so this compares with a tolerance that covers it, still far below the
    // difference between the two aspects (which is several degrees).
    expect(near(kept, fov43, 0.05f), "a NaN aspect keeps the last good aspect");
    // Override.
    CameraSettings o;
    o.fov_override_deg = 72.5f;
    CameraMan c3;
    c3.set_settings(o);
    expect(near(c3.update(1.0f / 60.0f, s, flat_ground).fov_deg, 72.5f, 1e-4f), "fov_override_deg wins");
}

void test_settings() {
    CameraSettings s;
    expect(s.valid(), "default CameraSettings are valid");
    expect(s.preset == CameraPreset::FullS3 && s.angle == CameraAngle::Low, "defaults: FullS3, Low");
    CameraSettings bad = s;
    bad.rig.distance.min_distance = std::nanf("");
    expect(!bad.valid(), "a NaN rig setting makes the aggregate invalid");
    bad = s;
    bad.shake.distance_zero = bad.shake.distance_full;
    expect(!bad.valid(), "a bad shake setting makes the aggregate invalid");
    bad = s;
    bad.trajectory.gravity = -1.0f;
    expect(!bad.valid(), "a bad trajectory setting makes the aggregate invalid");
    bad = s;
    bad.air.max_ignored_drop = 0.0f;
    expect(!bad.valid(), "a bad air setting makes the aggregate invalid");
    bad = s;
    bad.graph.landing_window = -0.1f;
    expect(!bad.valid(), "a bad graph setting makes the aggregate invalid");
    bad = s;
    bad.orientation.pan.delta_penumbra_degrees = -1.0f;
    expect(!bad.valid(), "a bad orientation tracker makes the aggregate invalid");
    bad = s;
    bad.fov_override_deg = 200.0f;
    expect(!bad.valid(), "an absurd fov override is invalid");
    CameraMan cam;
    expect(!cam.set_settings(bad), "set_settings rejects invalid settings");
    expect(cam.settings().fov_override_deg == 0.0f, "and keeps the old ones");
    // A frame with invalid settings never appears: the camera still produces finite frames.
    const Frame& f = cam.update(1.0f / 60.0f, Session{}.at(0.5f), flat_ground);
    expect(finite_frame(f) && f.valid, "frames are valid after a rejected settings change");
}

// ---------------------------------------------------------------- Gate 1 fix card

SubjectSnapshot standing() {
    SubjectSnapshot s;
    s.valid = true;
    s.position = {0.0f, ride_height, 0.0f};
    s.ground_clearance = ride_height;
    return s;
}
float elevation_angle_degrees(const Vec3& direction) { return std::asin(std::clamp(normalized(direction)[1], -1.0f, 1.0f)) / degrees; }

// Standing camera heights above the ground (the ground is y = 0): 21-low-camera.md / hails §1.3
// give Low about 0.59 m and High about 1.85 m. The orbit anchor is root - board_drop + anchor_height
// and does not depend on the shot's reference weights.
void test_standing_camera_heights() {
    float heights[2] = {};
    int k = 0;
    for (const CameraAngle angle : {CameraAngle::Low, CameraAngle::High}) {
        CameraSettings cs;
        cs.angle = angle;
        CameraMan cam;
        cam.set_settings(cs);
        float y = 0.0f;
        for (int i = 0; i < 240; ++i) y = cam.update(1.0f / 60.0f, standing(), flat_ground).pos[1];
        heights[k++] = y;
    }
    std::printf("  standing camera height: Low %.3f m, High %.3f m above the ground\n", static_cast<double>(heights[0]),
                static_cast<double>(heights[1]));
    expect(near(heights[0], 0.59f, 0.1f), "standing Low camera is about 0.59 m above the ground (21-low-camera.md)");
    expect(near(heights[1], 1.85f, 0.1f), "standing High camera is about 1.85 m above the ground (21-low-camera.md)");
    // The anchor height setting moves the camera one for one, whatever the shot.
    CameraSettings raised;
    raised.points.anchor_height += 0.2f;
    CameraMan cam;
    cam.set_settings(raised);
    float y = 0.0f;
    for (int i = 0; i < 240; ++i) y = cam.update(1.0f / 60.0f, standing(), flat_ground).pos[1];
    expect(near(y, heights[0] + 0.2f, 0.01f), "anchor_height raises the camera one for one");
}

// frame_composer.rs single(): pitch = -framing[2] is applied in the look basis (columns right, up,
// at). The at column of the framing basis is (0, -sin pitch, cos pitch), so a framing pitch of -4
// degrees (chase_flat_slow) tilts the view 4 degrees DOWN from the camera -> reference line and a
// positive one (high_chase, +3 degrees) tilts it UP.
// Hand-computed for a standing skater (root y = 0.95, board 0.9 below, anchor 0.32 above the board):
//   Low : anchor y 0.37, camera 1.8 m back at 7 degrees: y = 0.37 + 1.8 sin7 = 0.5894, 1.7866 m behind.
//         Reference = board (0.05) + board_offset 0.9 = 0.95. Line pitch = atan((0.95-0.5894)/1.7866) = +11.41 deg.
//         View pitch = 11.41 - 4 = +7.41 deg.
//   High: camera y = 0.37 + 3.0 sin30 = 1.87, 2.598 m behind; reference = 0.05 + 1.0 = 1.05.
//         Line pitch = atan((1.05-1.87)/2.598) = -17.52 deg. View pitch = -17.52 + 3 = -14.52 deg.
void test_framing_pitch_sign() {
    const SubjectSnapshot s = standing();
    for (const CameraAngle angle : {CameraAngle::Low, CameraAngle::High}) {
        CameraSettings cs;
        cs.angle = angle;
        CameraMan cam;
        cam.set_settings(cs);
        const Frame f = cam.update(1.0f / 60.0f, s, flat_ground); // the cut frame: every tracker on its target
        const bool low = angle == CameraAngle::Low;
        const float authored = low ? -4.0f : 3.0f;
        const Vec3 look_target = {0.0f, low ? 0.95f : 1.05f, 0.0f}; // reference point + board offset
        const Vec3 line = sub(look_target, f.pos);
        const Vec3 view = scale(f.back, -1.0f);
        const float line_pitch = elevation_angle_degrees(line);
        const float view_pitch = elevation_angle_degrees(view);
        const char* name = low ? "Low" : "High";
        if (!near(view_pitch, line_pitch + authored, 0.15f))
            std::printf("  %s: line %.2f view %.2f authored %.2f\n", name, static_cast<double>(line_pitch), static_cast<double>(view_pitch), static_cast<double>(authored));
        expect(near(line_pitch, low ? 11.41f : -17.52f, 0.1f), std::string(name) + ": camera -> reference line matches the hand computation");
        expect(near(view_pitch, low ? 7.41f : -14.52f, 0.15f), std::string(name) + ": view pitch = line pitch + authored framing pitch (frame_composer.rs)");
        expect((view_pitch < line_pitch) == low, std::string(name) + ": negative authored pitch looks down, positive looks up");
        expect(near(f.pos[0], 0.0f, 1e-3f), std::string(name) + ": no sideways drift");
    }
}

// The shot's apex is latched over the flight: after the apex a re-prediction reports the current
// height as its apex, which used to flip AirBig back to AirNormal on the way down.
void test_big_air_latched() {
    for (const float apex : {1.7f, 3.2f}) {
        for (const float fps : {60.0f, 144.0f}) {
            Session session;
            session.jump_speed = std::sqrt(2.0f * g * apex);
            session.length = session.land_time() + 1.0f;
            session.grind_start = session.grind_end = 100.0f;
            session.manual_start = session.manual_end = 100.0f;
            session.bail_time = 100.0f;
            CameraMan cam;
            const Recording r = record(cam, session, fps);
            int big_runs = 0, normal_after_big = 0;
            bool seen_big = false, seen_landing = false;
            float latched_max = 0.0f, latch_dip = 0.0f;
            for (const Frame& f : r.frames) {
                if (f.shot == ShotId::AirBig) {
                    if (!seen_big) ++big_runs;
                    seen_big = true;
                    if (f.debug.airborne) {
                        latch_dip = std::max(latch_dip, latched_max - f.debug.predicted_max_height);
                        latched_max = std::max(latched_max, f.debug.predicted_max_height);
                    }
                } else if (seen_big && f.shot == ShotId::AirNormal) {
                    ++normal_after_big;
                }
                if (f.shot == ShotId::Landing) seen_landing = true;
            }
            const std::string tag = "apex " + std::to_string(apex).substr(0, 3) + " m @" + std::to_string(static_cast<int>(fps)) + " fps: ";
            std::size_t air_big = 0, air_normal = 0;
            for (const ShotId id : r.sequence) {
                air_big += id == ShotId::AirBig;
                air_normal += id == ShotId::AirNormal;
            }
            expect(big_runs == 1 && air_big == 1, tag + "AirBig is selected exactly once");
            expect(normal_after_big == 0 && air_normal == 0, tag + "AirBig never drops to AirNormal before Landing");
            expect(seen_landing, tag + "the flight ends in the Landing shot");
            expect(latch_dip < 1e-4f, tag + "the reported apex (debug.predicted_max_height) never decreases during the flight");
            expect(near(latched_max, apex, 0.15f), tag + "the latched apex is the real one");
        }
    }
}

// A huge dt used to overflow the int cast of acc_ / step and freeze the camera forever.
void test_huge_dt_resumes() {
    for (const float huge : {1.0e9f, 3.0e38f, 20000000.0f}) {
        CameraMan cam;
        const Session session;
        for (int i = 0; i < 60; ++i) cam.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground);
        // The skater moved 6 m in the stall; the camera takes the capped steps and catches up.
        const SubjectSnapshot later = session.at(2.0f);
        const Frame& stalled = cam.update(huge, later, flat_ground);
        expect(!stalled.debug.held && finite_frame(stalled) && orthonormal(stalled), "huge dt: a finite, orthonormal frame");
        expect(stalled.debug.steps >= 1 && stalled.debug.steps <= cam.settings().pipeline.max_steps_per_update, "huge dt: the steps are capped, not zero");
        expect(stalled.debug.accumulator >= 0.0f && stalled.debug.accumulator < 2.0f / 60.0f, "huge dt: the accumulator is bounded");
        const float stalled_distance = length(sub(stalled.pos, later.position));
        // The capped steps spread over (0, 1] of the subject interpolation, so the last one sees the
        // new position; without that the camera would stay at the old place.
        expect(stalled_distance < 5.0f, "huge dt: the capped steps reach the new subject position");
        int steps = 0;
        float distance = 0.0f;
        for (int i = 1; i <= 120; ++i) {
            const float t = 2.0f + static_cast<float>(i) / 60.0f;
            const Frame& f = cam.update(1.0f / 60.0f, session.at(t), flat_ground);
            steps += f.debug.steps;
            distance = length(sub(f.pos, session.at(t).position));
            expect(finite_frame(f), "huge dt: frames after the stall are finite");
        }
        expect(steps >= 118 && steps <= 121, "huge dt: normal frames run one step each again (the camera resumed)");
        expect(distance > 1.0f && distance < 3.5f, "huge dt: the camera is back at its shot distance behind the skater");
    }
    // A merely long stall (5 s) also spreads its capped steps over the whole frame interval.
    CameraMan cam;
    const Session session;
    for (int i = 0; i < 60; ++i) cam.update(1.0f / 60.0f, session.at(static_cast<float>(i) / 60.0f), flat_ground);
    const Frame& f = cam.update(5.0f, session.at(2.0f), flat_ground);
    expect(f.debug.steps == cam.settings().pipeline.max_steps_per_update, "a 5 s stall runs exactly max_steps_per_update steps");
    expect(length(sub(f.pos, session.at(2.0f).position)) < 5.0f, "a 5 s stall still lands near the new subject position");
}

// With the anchor independent of the shot weights, landing from a flat ollie leaves no height bounce
// (the Gate 1 notes measured about 0.12 m while the air / landing weights moved the weighted point).
void test_anchor_independent_of_weights() {
    CameraMan cam;
    const Session session;
    const float anchor_y = ride_height - 0.9f + 0.32f; // root - board_drop + anchor_height
    float worst = 0.0f, worst_ground = 0.0f;
    for (int i = 0; i < 480; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const Frame& f = cam.update(1.0f / 60.0f, session.at(t), flat_ground);
        if (t < 1.0f) continue;
        if (t > session.land_time() + 0.0f && t < session.land_time() + 1.5f) {
            const float orbit_y = f.pos[1] - f.debug.distance * std::sin(f.debug.elevation); // anchor the rig orbits
            worst = std::max(worst, std::abs(orbit_y - anchor_y));
        }
        if (t < session.jump_time - 0.05f) worst_ground = std::max(worst_ground, std::abs(f.pos[1] - f.debug.distance * std::sin(f.debug.elevation) - anchor_y));
    }
    expect(worst_ground < 0.01f, "riding: the orbit anchor sits at root - board_drop + anchor_height");
    if (worst > 0.03f) std::printf("  landing anchor deviation %.3f m\n", static_cast<double>(worst));
    expect(worst < 0.03f, "landing from an ollie: no height bounce from the shot weights changing (anchor within 3 cm)");
}

// ---------------------------------------------------------------- shake and landing impulse

// A big drop: the skater leaves the ground at 14 m/s up, so it lands at about 14 m/s down.
Session big_drop() {
    Session s;
    s.jump_time = 0.5f;
    s.jump_speed = 14.0f;
    s.grind_start = s.grind_end = 100.0f;
    s.manual_start = s.manual_end = 100.0f;
    s.bail_time = 100.0f;
    s.length = 6.0f;
    return s;
}

void test_full_s3_landing_shake() {
    CameraMan cam;
    const Session session = big_drop();
    float impulse_after = 0.0f, impulse_before = 0.0f;
    float max_wobble = 0.0f;
    Vec3 previous{0, 0, 0};
    for (int i = 0; i < 360; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const Frame& f = cam.update(1.0f / 60.0f, session.at(t), flat_ground);
        if (t < session.land_time() - 0.1f) impulse_before = std::max(impulse_before, f.debug.impulse);
        if (t > session.land_time() && t < session.land_time() + 0.3f) impulse_after = std::max(impulse_after, f.debug.impulse);
        if (i > 0) max_wobble = std::max(max_wobble, length(sub(f.pos, previous)));
        previous = f.pos;
        expect(finite_frame(f) && orthonormal(f), "big drop: finite, orthonormal");
    }
    expect(impulse_before == 0.0f, "big drop: no shake impulse before landing");
    expect(impulse_after > 0.5f, "big drop: the landing raises the shake impulse");
    expect(max_wobble < 0.5f, "big drop: continuous");
}

// ---------------------------------------------------------------- NativePlus

// A native pose that follows the skater: 2 m behind and 0.5 m above the root, looking at the root
// from a fixed pitch. Optionally static.
NativePose native_for(const SubjectSnapshot& s, bool follow_height) {
    NativePose p;
    const float base_y = follow_height ? s.position[1] : ride_height;
    p.position = {s.position[0], base_y + 0.5f, s.position[2] - 2.0f};
    p.right = {1, 0, 0};
    p.up = {0, 1, 0};
    p.back = {0, 0, -1}; // looks along +Z
    // right x up must be +back: (1,0,0) x (0,1,0) = (0,0,1), so flip to the +Z-looking row set:
    p.right = {-1, 0, 0};
    p.back = {0, 0, -1};
    p.up = {0, 1, 0};
    // check: (-1,0,0) x (0,1,0) = (0,0,-1) = back. Good.
    p.fov_deg = 60.0f;
    return p;
}

void test_native_plus_follows_native() {
    CameraSettings np;
    np.preset = CameraPreset::NativePlus;
    // Alpha 2: the speed and air fov terms ride on top of the native fov (covered in s3cam_layers_tests);
    // they are off here so this test keeps checking the pass-through of the native value itself.
    np.fov.speed_fov = false;
    np.fov.air_fov = false;
    // Alpha 4: the big-air layers (height follow, rise, keep-in-frame) are off here so this test keeps checking
    // the Alpha 1 native layers on their own; s3cam_layers_tests covers the air camera in both presets.
    np.air_camera.follow_height = 0.0f;
    np.air_camera.rise_degrees = 0.0f;
    np.air_camera.keep_in_frame = false;
    CameraMan cam;
    expect(cam.set_settings(np), "NativePlus settings accepted");
    const Session session;
    float worst_pos = 0.0f, worst_angle = 0.0f;
    float min_hold = 0.0f, ground_hold = 0.0f;
    bool saw_air_hold = false;
    for (int i = 0; i < 360; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const SubjectSnapshot s = session.at(t);
        const NativePose pose = native_for(s, true);
        FrameExtras ex;
        ex.native = &pose;
        const Frame& f = cam.update(1.0f / 60.0f, s, flat_ground, ex);
        expect(finite_frame(f) && orthonormal(f), "native+: finite and orthonormal");
        expect(near(f.fov_deg, 60.0f, 1e-4f), "native+: the native fov is passed through");
        const bool in_air = t > session.jump_time + 0.05f && t < session.land_time();
        const bool settled = t < session.jump_time - 0.1f || t > session.land_time() + 1.0f;
        if (in_air) {
            min_hold = std::min(min_hold, f.pos[1] - pose.position[1]);
            if (f.debug.air_hold_delta < -0.1f) saw_air_hold = true;
        }
        if (settled && t > 0.2f) {
            worst_pos = std::max(worst_pos, length(sub(f.pos, pose.position)));
            worst_angle = std::max(worst_angle, std::acos(std::clamp(dot(f.back, pose.back), -1.0f, 1.0f)) / degrees);
            ground_hold = std::max(ground_hold, std::abs(f.pos[1] - pose.position[1]));
        }
    }
    expect(worst_pos < 0.02f, "native+: on the ground the output stays within 2 cm of the native pose (no drift)");
    expect(worst_angle < 1.0f, "native+: on the ground the output stays within 1 degree of the native orientation");
    expect(saw_air_hold, "native+: the air hold reports a negative delta while the board rises");
    expect(min_hold < -0.3f, "native+: in the air the camera is held below where the native camera followed the board");
    expect(ground_hold < 0.02f, "native+: the hold is gone on the ground");
}

void test_native_plus_dip_and_shake() {
    const Session session = big_drop();
    const auto run_case = [&](bool dip, bool shake, float& lowest, float& settled_error, float& max_shake_angle, float& max_shake_offset) {
        CameraSettings np;
        np.preset = CameraPreset::NativePlus;
        np.native_plus.landing_dip = dip;
        np.native_plus.shake = shake;
        np.native_plus.air_hold = false; // isolate the dip
        // Alpha 4: the big-air layers (height follow, rise, keep-in-frame) are off here so this test keeps checking
        // the Alpha 1 native layers on their own; s3cam_layers_tests covers the air camera in both presets.
        np.air_camera.follow_height = 0.0f;
        np.air_camera.rise_degrees = 0.0f;
        np.air_camera.keep_in_frame = false;
        CameraMan cam;
        cam.set_settings(np);
        lowest = 0.0f;
        settled_error = 0.0f;
        max_shake_angle = 0.0f;
        max_shake_offset = 0.0f;
        for (int i = 0; i < 360; ++i) {
            const float t = static_cast<float>(i) / 60.0f;
            SubjectSnapshot s = session.at(t);
            NativePose pose = native_for(s, false); // a static native camera: any motion is ours
            FrameExtras ex;
            ex.native = &pose;
            const Frame& f = cam.update(1.0f / 60.0f, s, flat_ground, ex);
            expect(finite_frame(f) && orthonormal(f), "native+ drop: finite and orthonormal");
            if (t > session.land_time() && t < session.land_time() + 0.6f) {
                lowest = std::min(lowest, f.pos[1] - pose.position[1]);
                max_shake_angle = std::max(max_shake_angle, std::acos(std::clamp(dot(f.back, pose.back), -1.0f, 1.0f)) / degrees);
                max_shake_offset = std::max(max_shake_offset, std::abs(f.pos[0] - pose.position[0]) + std::abs(f.pos[2] - pose.position[2]));
            }
            if (t > session.land_time() + 3.0f) settled_error = std::max(settled_error, length(sub(f.pos, pose.position)));
        }
    };
    float lowest = 0, settled = 0, angle = 0, offset = 0;
    run_case(true, false, lowest, settled, angle, offset);
    expect(lowest < -0.06f && lowest > -0.2f, "native+: a hard landing dips the camera by roughly dip_depth (6-20 cm)");
    expect(settled < 0.01f, "native+: the dip returns to the native pose (critically damped, no drift)");
    run_case(false, false, lowest, settled, angle, offset);
    expect(lowest > -0.02f, "native+: with the dip toggled off the camera does not dip");
    run_case(false, true, lowest, settled, angle, offset);
    expect(angle > 0.02f, "native+: the landing impulse shakes the camera rotation");
    expect(offset > 0.0005f, "native+: and shakes its position");
    expect(angle < 8.0f, "native+: the shake stays small");

    // The dip scales with the impact: a gentle ollie landing barely dips.
    CameraSettings np;
    np.preset = CameraPreset::NativePlus;
    np.native_plus.air_hold = false;
    CameraMan cam;
    cam.set_settings(np);
    Session gentle;
    float gentle_lowest = 0.0f;
    for (int i = 0; i < 300; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const SubjectSnapshot s = gentle.at(t);
        NativePose pose = native_for(s, false);
        FrameExtras ex;
        ex.native = &pose;
        const Frame& f = cam.update(1.0f / 60.0f, s, flat_ground, ex);
        if (t > gentle.land_time()) gentle_lowest = std::min(gentle_lowest, f.pos[1] - pose.position[1]);
    }
    expect(gentle_lowest > -0.03f, "native+: a gentle landing barely dips (amplitude follows the impulse)");
}

void test_native_plus_guards() {
    CameraSettings np;
    np.preset = CameraPreset::NativePlus;
    CameraMan cam;
    cam.set_settings(np);
    const Session session;
    const SubjectSnapshot s = session.at(0.5f);
    const Frame& none = cam.update(1.0f / 60.0f, s, flat_ground);
    expect(none.debug.held && !none.valid, "native+: without a native pose the frame is held");
    NativePose pose = native_for(s, true);
    FrameExtras ex;
    ex.native = &pose;
    const Frame first = cam.update(1.0f / 60.0f, s, flat_ground, ex);
    expect(first.valid && !first.debug.held, "native+: with a pose it runs");
    pose.position[1] = std::nanf("");
    const Frame& bad = cam.update(1.0f / 60.0f, s, flat_ground, ex);
    expect(bad.debug.held && near3(bad.pos, first.pos, 1e-6f), "native+: a NaN native pose holds the last frame");
    // A slightly skewed native basis still yields an orthonormal output.
    NativePose skew = native_for(s, true);
    skew.right = scale(skew.right, 1.2f);
    skew.up = add(skew.up, scale(skew.right, 0.05f));
    ex.native = &skew;
    const Frame& f = cam.update(1.0f / 60.0f, s, flat_ground, ex);
    expect(orthonormal(f), "native+: a skewed native basis is re-orthonormalised");
}

// ---------------------------------------------------------------- pump / push / no-lag wiring

void test_push_and_lag_wiring() {
    // A standing start then a push: the forward acceleration crosses the kick threshold upward once.
    CameraMan cam;
    int kicks = 0;
    bool push_state_seen = false;
    float v = 0.0f, z = 0.0f;
    for (int i = 0; i < 240; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const float a = (t > 0.5f && t < 1.0f) ? 8.0f : 0.0f; // m/s^2
        v += a / 60.0f;
        z += v / 60.0f;
        SubjectSnapshot s;
        s.valid = true;
        s.position = {0, ride_height, z};
        s.velocity = {0, 0, v};
        const Frame& f = cam.update(1.0f / 60.0f, s, flat_ground);
        if (f.debug.push_kick) ++kicks;
        push_state_seen = push_state_seen || f.debug.push_state;
        expect(finite_frame(f), "push: finite");
    }
    expect(kicks >= 1, "push: the acceleration crossing the threshold fires a kick");
    expect(push_state_seen, "push: push_state is set after the kick");
}

void test_bail_removes_lag_and_keeps_following() {
    // After a bail the camera must keep tracking the sliding skater (no_lag) and stay finite.
    CameraMan cam;
    const Session session;
    float last_distance = 0.0f;
    for (int i = 450; i < 600; ++i) {
        const float t = static_cast<float>(i) / 60.0f;
        const Frame& f = cam.update(1.0f / 60.0f, session.at(t), flat_ground);
        last_distance = length(sub(f.pos, session.at(t).position));
        expect(finite_frame(f), "bail: finite");
    }
    expect(last_distance < 8.0f, "bail: the camera is still near the skater at the end");
}
} // namespace

int main() {
    test_session(30.0f, "30");
    test_session(60.0f, "60");
    test_session(144.0f, "144");
    test_session_600_ticks_at_60();
    test_fps_agree();
    test_shot_framing_and_air_hold();
    test_big_air_shot();
    test_standing_camera_heights();
    test_framing_pitch_sign();
    test_big_air_latched();
    test_huge_dt_resumes();
    test_anchor_independent_of_weights();
    test_bail_while_onboard_flag();
    test_low_vs_high();
    test_reset_snaps();
    test_invalid_holds();
    test_fixed_step_accumulator();
    test_fov();
    test_settings();
    test_full_s3_landing_shake();
    test_native_plus_follows_native();
    test_native_plus_dip_and_shake();
    test_native_plus_guards();
    test_push_and_lag_wiring();
    test_bail_removes_lag_and_keeps_following();
    if (failures == 0) std::printf("s3cam_camera_tests: all passed\n");
    return failures == 0 ? 0 : 1;
}
