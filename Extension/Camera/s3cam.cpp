#include "s3cam.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Game/Build/20260929/engine.h"
#include "Engine/Game/Build/20260929/grind_exit.h"
#include "Engine/Game/Build/20260929/no_bail.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include "Engine/Game/Camera/s3_camera.h"
#include "Engine/Game/Skater/skater_body.h"
#include "Extension/Objects/ParkEditor/park_editor_surface.h"
#include "Extension/Objects/local_placements_runtime.h"
#include "Extension/Skater/free_flight.h"
#include <algorithm>
#include <cmath>
#include <format>
#include <mutex>
#include <optional>
#include <vector>

namespace dingosdk::client_source::detail {
namespace {
namespace state_addr = addr::skater_state;
using logging::Channel;
using logging::Level;
using s3cam::Vec3;

constexpr std::uint32_t no_state = 0xffffffff;
// debug_noclip_bodies' parts: board bodies 0..8, then skeleton body n at 8 + n.
constexpr std::size_t hips_part = 8 + skater_body::index(skater_body::Bone::hips);
constexpr std::uintptr_t client_flow_state_offset = 0xc4; // Runtime/client_tick.cpp update_model
// Ground under the skater: cast from just above the root (riding, the root is ~0.95 m over the
// deck) to well below anything the camera cares about.
constexpr float ground_ray_above = 0.1f, ground_ray_below = 10.0f;
// The trajectory's first chord starts on the takeoff surface and touches it at once: a hit this
// close to the start of a chord that RISES is skipped by casting again from a little further along.
// Only rising chords: the first in-game run skipped a falling chord that started just above the
// floor, cast the next one from below it and predicted landings 8-9 m down on flat ollies.
constexpr float start_hit_skip = 0.02f, start_hit_restart = 0.03f;
constexpr float falling_chord_lift = 0.25f; // m (ground_query)
// The slope under the skater: a normal flatter than this is a probe that hit something else. It is
// smoothed over normal_smooth_time, so a faceted ramp (ported maps) reads as one slope, not a flicker.
constexpr float min_normal_up = 0.1f;
// The smoothing time shrinks with speed so the slope never trails by more than ~normal_smooth_distance of travel:
// at 15 m/s on a curved ramp a fixed 0.08 s trailed ~20 deg, which the manual detector read as a tilted board.
constexpr double normal_smooth_distance = 0.25; // m
constexpr float steep_ground_y = 0.866f; // normal.y below this (slopes over 30 deg): the ground ray follows the slope
constexpr double normal_smooth_time = 0.08;
// The skater's root moves once per physics step (60 Hz). Rendering faster, the frames between two
// steps would see it stand still and then jump, which reads as a choppy camera at speed and in big
// airs: between steps the root is carried forward along its velocity, at most this long.
constexpr double max_extrapolation = 1.0 / 30.0;
constexpr float extrapolation_gravity = 10.1f; // m/s2, measured in game
// The camera's degree FOV (client_source_spawn.h camera_fov_init: "the camera's degree FOV at
// +0xac"). Read from the game's own camera too; used only while it looks like a FOV.
constexpr std::uintptr_t camera_fov_field = 0xac;
constexpr float plausible_fov_min = 10.0f, plausible_fov_max = 150.0f;
// The game's camera this far from the skater while S3Cam owns the view: the game has moved it to a
// screen of its own (map, customisation); S3Cam hands back at once and does not take it again there.
constexpr float native_away_distance = 25.0f;
// Manual detection (no native signal found): the board's pitch against the ground under
// it, from its frontmost and rearmost physics bodies (debug_noclip_bodies parts 0-8, position at
// +0x50 like the root body's). A manual or nose manual holds one end up. TUNE.
constexpr std::uintptr_t body_position_offset = 0x50;
constexpr std::size_t board_body_count = 9;
constexpr float manual_on_degrees = 7.0f, manual_off_degrees = 4.0f;
constexpr double manual_on_time = 0.15, manual_off_time = 0.1;
constexpr float manual_max_slope_y = 0.94f;  // normal.y: no manuals on slopes steeper than ~20 deg
constexpr double manual_after_landing = 0.35; // s after an air before a manual can start
// The game paused (pause menu, and the replay editor behind it): the client keeps reporting normal
// play (state 13, control yes), but the skater stops moving while its physics still holds a speed,
// or the physics step reads 0. S3Cam hands back at once so the replay editor gets its camera.
constexpr double pause_after = 0.25;
constexpr float pause_min_speed = 0.3f;
// Hippy jumps: the skater leaves the board (state 504, no ragdoll) for 1.1-2.3 s (Beta logs) and lands back on it.
// Off the board from a riding state, S3Cam keeps the view and follows the skater as in an air for up to
// hippy_max_time, and lets go sooner only once the skater has nearly stopped (stood off the board): slower than
// hippy_still_speed for hippy_still_time, after hippy_min_time. In a hippy jump the skater keeps the board's speed.
// Neither the skater's height (Beta 2: "standing" after 0.32 s) nor the board's body speed (Beta 2b: "stopped"
// after 0.4 s in real jumps) told a hippy jump from stepping off.
constexpr double hippy_max_time = 2.5, hippy_min_time = 0.5, hippy_still_time = 0.4;
constexpr float hippy_still_speed = 0.5f; // m/s, horizontal

struct Settings {
    std::mutex mutex;
    s3cam::CameraSettings camera;
    S3CamOptions options;
    std::uint64_t revision{};
};
Settings& settings_store() {
    static auto* value = new Settings;
    return *value;
}

// What the tick sees, kept across camera runs: this tick's reading (s3cam_observe, used by
// s3cam_pose), the hand-back debounce and the flow log's last line.
struct Watch {
    bool observed{};
    s3cam::SubjectSnapshot subject;
    std::uint32_t state = no_state;
    double state_since{};
    bool wants{}, wants_known{};
    double wants_since{};
    // Rays: the physics world of this tick (0 when unresolved: no prediction, default clearance).
    std::uintptr_t base{}, world{};
    std::uint64_t rays{};
    std::uint32_t unreadable{}, root_repeats{};
    Vec3 last_root{};
    // The smoothed ground normal under the skater (normal_smooth_time).
    Vec3 ground_normal{0, 1, 0};
    Vec3 ground_normal_raw{0, 1, 0}; // the last measured one, unsmoothed (manual detection)
    double ground_normal_at{};
    double landed_at{}; // when the skater last left the air (manual detection waits out the landing bounce)
    // Extrapolation between physics steps (max_extrapolation).
    Vec3 physics_root{};
    double root_changed_at{};
    // Pause detection (pause_after).
    bool paused{};
    double step_zero_since{};
    bool step_zero{};
    float physics_step{};
    // Manual detection.
    float board_pitch{};      // degrees against the ground, + front end up
    bool board_pitch_ok{};
    // Hippy jumps (hippy_max_time).
    bool hippy{};
    double hippy_since{}, hippy_slow_since{};
    bool hippy_slow{};
    bool manual{};
    double manual_candidate_since{};
    bool manual_candidate{};
    // s3cam_note_flow
    bool flow_known{};
    std::uint32_t flow_state{}, flow_mode{};
    bool flow_control{}, flow_phase{}, flow_owned{}, flow_view_ours{};
};
Watch& watch() {
    static auto* value = new Watch;
    return *value;
}
// One camera run, from taking the view to handing it back.
struct Run {
    bool running{};
    std::uintptr_t native_camera{};
    double started{}, last_pose{};
    std::uint64_t applied_revision = ~0ull;
    S3CamOptions options;

    // Crossfade with the game's own camera (0 = the game's pose, 1 = S3Cam's): in when taking the
    // view, out before handing it back on foot, so neither switch snaps. Eased with sine_blend.
    float blend{}, blend_target = 1.0f;
    bool native_ok{};
    // FOV: the game camera's own (when its +0xac reads as a FOV), else the FreeCamera's at take.
    float native_fov{}, fallback_fov{}, base_fov{};
    float native_distance = -1.0f; // m, game camera to skater, -1 unknown

    // Diagnostics, one line a second.
    double report_at{};
    std::uint32_t frames{}, steps{}, held{}, resets{}, failed{};
    // Whether the game's own camera keeps moving under ours (it did in run 1). A frozen one while
    // S3Cam still owns the view would say the game has switched to a screen of its own.
    std::uint32_t native_moved{}, native_unreadable{};
    Vec3 native_last{};
    double update_ms{}, update_ms_max{};
    std::uint64_t rays_at_report{};
    std::uint64_t total_frames{}, total_held{};
    double total_update_ms{};

    // Shot changes and landings.
    std::string_view shot{};
    bool airborne{};
    double takeoff_at{};
    float takeoff_y{};
    float predicted_air{}, predicted_drop{}, predicted_height{};
    bool predicted{};
    double landed_at{};
    float landed_air{}, landed_drop{}, landing_impulse{}, landing_speed{}, landing_fall{}, landing_fraction{};
    bool landing_pending{};
    std::uint32_t landings{};
    // Per flight: the largest frame-to-frame changes, to find what twitches in big airs.
    bool frame_seen{};
    float prev_fov{};
    Vec3 prev_back{}, prev_pos{}, prev_step{};
    float flight_fov_jump{}, flight_turn{}, flight_jerk{}, flight_look{}, flight_pull{}, flight_fov_min{}, flight_fov_max{};
    float flight_yaw_trick{};
};
Run& run() {
    static auto* value = new Run;
    return *value;
}
s3cam::CameraMan& camera_man() {
    static auto* value = new s3cam::CameraMan; // a few KB: kept off the engine thread's stack
    return *value;
}
const editor::NativeSurfaceApi& surface(std::uintptr_t base) {
    // Fingerprints are checked once per process, as the park editor does at its start.
    static const auto api = editor::surface_api(base);
    return api;
}

// One physics ray, closest hit. No ignore list and no owner filter, so nothing is discovered and
// no vector ever allocates (the editor's cast_surface copies its ignore list per call).
std::optional<Vec3> cast(const Vec3& from, const Vec3& to) noexcept {
    auto& w = watch();
    if (!w.world || !w.base) return std::nullopt;
    try {
        const auto& api = surface(w.base);
        if (!api.ready) return std::nullopt;
        std::vector<editor::SurfaceBody> discovered;
        ++w.rays;
        return editor::cast_surface_once(api, w.world, from, to, nullptr, {}, nullptr, {}, discovered, nullptr);
    } catch (...) { return std::nullopt; }
}
// The ray query gives a hit fraction only: the normal comes from two more short down-rays beside
// the hit (measured in game: flat 0.7 deg, ramps 41 and 60 deg measured this way). They reach 1 m up and
// down, so a 0.25 m step still finds ramps up to ~75 deg, and a side that misses (an edge, a gap in a
// ported map's collision) is tried on the other side. No answer is "unknown", not flat: on steep
// transitions the old +-0.5 m probes missed and the slope flicked between the ramp and flat.
std::optional<Vec3> try_normal_at(const Vec3& hit) noexcept {
    constexpr float reach = 1.0f, side = 0.25f;
    const auto probe = [&](float dx, float dz) {
        return cast({hit[0] + dx, hit[1] + reach, hit[2] + dz}, {hit[0] + dx, hit[1] - reach, hit[2] + dz});
    };
    auto x = probe(side, 0);
    if (!x) x = probe(-side, 0);
    auto z = probe(0, side);
    if (!z) z = probe(0, -side);
    if (!x || !z) return std::nullopt;
    auto n = s3cam::cross(s3cam::sub(*z, hit), s3cam::sub(*x, hit));
    if (n[1] < 0) n = s3cam::scale(n, -1);
    n = s3cam::normalized(n, {0, 1, 0});
    if (n[1] < min_normal_up) return std::nullopt; // a probe hit a different surface (a wall, coping)
    return n;
}
Vec3 normal_at(const Vec3& hit) noexcept { return try_normal_at(hit).value_or(Vec3{0, 1, 0}); }
std::optional<s3cam::GroundHit> ground_query(const Vec3& from, const Vec3& to, bool want_normal) noexcept {
    // A falling trajectory chord is cast from falling_chord_lift higher: a re-prediction just before touchdown starts
    // at the skater's surface level, at or a little under the landing surface, and its rays passed through it and found
    // the ground metres below (Beta log: 20 of 331 landings predicted 3-9 m too low).
    if (want_normal && to[1] < from[1]) {
        auto hit = cast({from[0], from[1] + falling_chord_lift, from[2]}, to);
        if (!hit) return std::nullopt;
        return s3cam::GroundHit{*hit, normal_at(*hit)};
    }
    auto hit = cast(from, to);
    if (hit && to[1] > from[1] && s3cam::length(s3cam::sub(*hit, from)) < start_hit_skip) {
        const auto direction = s3cam::normalized(s3cam::sub(to, from));
        const auto restart = s3cam::add(from, s3cam::scale(direction, start_hit_restart));
        if (s3cam::dot(s3cam::sub(to, restart), direction) <= 0) return std::nullopt;
        hit = cast(restart, to);
    }
    if (!hit) return std::nullopt;
    // The normal costs two more rays: only the trajectory's landing reads it, not the collision rays.
    return s3cam::GroundHit{*hit, want_normal ? normal_at(*hit) : Vec3{0, 1, 0}};
}
std::uintptr_t resolve_world(std::uintptr_t base) noexcept {
    try {
        if (!surface(base).ready) return 0;
        auto& placements = profile_runtime::placements_runtime();
        if (!placements.context) return 0;
        // The dropper queries the client physics world, resolved on the client update.
        std::array<std::uintptr_t, 2> context{};
        placements.context(context.data());
        if (!source_object(context[0])) return 0;
        return surface(base).world(context[0]);
    } catch (...) { return 0; }
}

bool read_native(std::uintptr_t base, std::uintptr_t camera, s3cam::NativePose& pose) noexcept {
    std::uintptr_t vtable{};
    std::array<float, 16> view{};
    // A level change can destroy the camera while S3Cam owns the view: check its type every time.
    if (!first_person_read(camera, &vtable, 8) || vtable != base + addr::engine::camera_vtable ||
        !first_person_read(camera + 0x50, view.data(), sizeof(view)) || !valid_flight_transform(view))
        return false;
    pose.right = {view[0], view[1], view[2]};
    pose.up = {view[4], view[5], view[6]};
    pose.back = {view[8], view[9], view[10]};
    pose.position = {view[12], view[13], view[14]};
    pose.fov_deg = 0; // the gameplay camera's FOV field is not mapped: Native+ keeps the FreeCamera's
    return true;
}

const char* preset_name(s3cam::CameraPreset preset) {
    return preset == s3cam::CameraPreset::NativePlus ? "native+" : "full";
}
const char* angle_name(s3cam::CameraAngle angle) { return angle == s3cam::CameraAngle::High ? "high" : "low"; }

void log_landing(const Run& r) {
    const auto predicted = [&](float value, const char* unit, bool sign) {
        if (!r.predicted) return std::string("none");
        return sign ? std::format("{:+.2f} {}", value, unit) : std::format("{:.2f} {}", value, unit);
    };
    logging::log(Level::info, Channel::skater,
        "s3cam landing #{}: air {:.2f} s (predicted {}), drop {:+.2f} m (predicted {}), apex {}, "
        "speed {:.1f} m/s, fell {:.2f} m (shake {:.0f}%), shake impulse peak {:.3f} | in the air: fov {:.1f}-{:.1f} (largest step {:.2f}), "
        "largest turn {:.2f} deg/frame, largest jerk {:.3f} m, landing look {:.2f}, collision pull {:.2f} m",
        r.landings, r.landed_air, predicted(r.predicted_air, "s", false), r.landed_drop, predicted(r.predicted_drop, "m", true),
        predicted(r.predicted_height, "m", false), r.landing_speed, r.landing_fall, r.landing_fraction * 100.0f, r.landing_impulse, r.flight_fov_min, r.flight_fov_max,
        r.flight_fov_jump, r.flight_turn, r.flight_jerk, r.flight_look, r.flight_pull);
}

// Shot changes, takeoffs and landings, from the frame's debug values.
void watch_frame(Run& r, const Watch& w, const s3cam::Frame& frame, double now) {
    const auto& d = frame.debug;
    if (r.options.verbose && d.shot_name != r.shot)
        logging::log(Level::info, Channel::skater, "s3cam shot {} -> {} (state {}, speed {:.1f})",
            r.shot.empty() ? std::string_view("none") : r.shot, d.shot_name, w.state, d.speed);
    r.shot = d.shot_name;
    // Frame-to-frame motion of the output, tracked through each flight.
    const Vec3 step_now = r.frame_seen ? s3cam::sub(frame.pos, r.prev_pos) : Vec3{0, 0, 0};
    if (d.airborne && !r.airborne) {
        r.flight_fov_jump = r.flight_turn = r.flight_jerk = r.flight_look = r.flight_pull = 0.0f;
        r.flight_fov_min = r.flight_fov_max = frame.fov_deg;
    }
    if (d.airborne && r.frame_seen) {
        r.flight_fov_jump = std::max(r.flight_fov_jump, std::abs(frame.fov_deg - r.prev_fov));
        r.flight_fov_min = std::min(r.flight_fov_min, frame.fov_deg);
        r.flight_fov_max = std::max(r.flight_fov_max, frame.fov_deg);
        r.flight_turn = std::max(r.flight_turn,
            std::acos(std::clamp(s3cam::dot(frame.back, r.prev_back), -1.0f, 1.0f)) / s3cam::degrees);
        r.flight_jerk = std::max(r.flight_jerk, s3cam::length(s3cam::sub(step_now, r.prev_step)));
        r.flight_look = std::max(r.flight_look, d.landing_look_weight);
        r.flight_pull = std::max(r.flight_pull, d.collision_pull);
    }
    r.prev_fov = frame.fov_deg;
    r.prev_back = frame.back;
    r.prev_step = step_now;
    r.prev_pos = frame.pos;
    r.frame_seen = true;
    if (d.airborne && !r.airborne) {
        r.takeoff_at = now;
        r.takeoff_y = w.subject.position[1];
        r.predicted = false;
        r.landing_pending = false;
    }
    if (d.airborne && d.prediction_valid) {
        // The last prediction before touchdown: the one the camera was working from.
        r.predicted = true;
        r.predicted_air = d.predicted_air_time;
        r.predicted_drop = d.predicted_landing_delta;
        r.predicted_height = d.predicted_max_height;
    }
    if (!d.airborne && r.airborne) {
        ++r.landings;
        r.landed_at = now;
        r.landed_air = static_cast<float>(now - r.takeoff_at);
        r.landed_drop = w.subject.position[1] - r.takeoff_y;
        r.landing_speed = s3cam::length(w.subject.velocity);
        r.landing_impulse = d.impulse;
        r.landing_fall = d.landing_fall;
        r.landing_fraction = d.landing_fraction;
        r.landing_pending = true;
    }
    r.airborne = d.airborne;
    if (r.landing_pending) {
        // The shake's impulse builds over the steps after touchdown: report its peak.
        r.landing_impulse = std::max(r.landing_impulse, d.impulse);
        if (now - r.landed_at >= 0.3) {
            r.landing_pending = false;
            if (r.options.verbose) log_landing(r);
        }
    }
}

void report(Run& r, Watch& w, double now) {
    if (now < r.report_at) return;
    r.report_at = now + 1;
    const auto& f = camera_man().frame();
    const auto& d = f.debug;
    // The once-a-second status line is detailed logging (s3cam_log 1, off by default); the counters reset either way.
    if (r.options.verbose)
    logging::log(Level::info, Channel::skater,
        "s3cam t={:.0f} {} fps, {} steps, {} held, {} resets, {} failed, {} unreadable, root repeated on {}, "
        "game camera moved on {} (unreadable {}) | "
        "update {:.3f} ms mean, {:.3f} max, {} rays | state {} shot {} speed {:.1f} clearance {:.2f} normal.y {:.3f} | "
        "dist {:.2f} elev {:.1f} deg lag {:.2f} | fov {:.1f} (game camera {:.1f}, FreeCamera at take {:.1f}) | "
        "game camera {:.1f} m from the skater | blend {:.2f} | board pitch {} manual {} | physics step {:.4f}",
        now - r.started, r.frames, r.steps, r.held, r.resets, r.failed, w.unreadable, w.root_repeats, r.native_moved,
        r.native_unreadable,
        r.frames ? r.update_ms / r.frames : 0.0, r.update_ms_max, w.rays - r.rays_at_report, w.state, d.shot_name, d.speed,
        w.subject.ground_clearance, w.subject.ground_normal[1], d.distance, d.elevation / s3cam::degrees, d.anchor_lag,
        f.fov_deg, r.native_fov, r.fallback_fov, r.native_distance, r.blend,
        w.board_pitch_ok ? std::format("{:+.1f} deg", w.board_pitch) : std::string("unreadable"), w.manual ? "on" : "off", w.physics_step);
    r.frames = r.steps = r.held = r.resets = r.failed = r.native_moved = r.native_unreadable = 0;
    w.unreadable = w.root_repeats = 0;
    r.update_ms = r.update_ms_max = 0;
    r.rays_at_report = w.rays;
}

double qpc_ms(const LARGE_INTEGER& begin, const LARGE_INTEGER& end) {
    LARGE_INTEGER frequency{};
    QueryPerformanceFrequency(&frequency);
    return frequency.QuadPart
        ? 1000.0 * static_cast<double>(end.QuadPart - begin.QuadPart) / static_cast<double>(frequency.QuadPart) : 0.0;
}
}

S3CamObservation s3cam_observe(const SourceTrial& trial, std::uintptr_t client) noexcept {
    auto& w = watch();
    w.observed = false;
    S3CamObservation result;
    double now{};
    try {
        now = source_flight_now();
        w.base = trial.base;
        overlay::DebugModel skater;
        const auto entity = debug_skater(trial.base, client, skater);
        const auto bodies = debug_noclip_bodies(trial.base, client, skater.skater_identity);
        std::uint32_t state{};
        source_require(first_person_read(bodies.context + state_addr::physics_state_offset, &state, 4), "Skater physics is unreadable.");
        const bool onboard = state != addr::no_bail::offboard_physics_state;
        // Riding: the board's root body. Off the board the board flies on alone: follow the hips.
        Vec3 velocity{};
        source_require(first_person_read((onboard ? bodies.parts[state_addr::board_root_body] : bodies.parts[hips_part]) +
            state_addr::body_velocity_offset, velocity.data(), sizeof(velocity)), "Skater velocity is unreadable.");
        // Offboard covers walking and bails alike (measured in game); the offboard state's ragdoll flag
        // tells a bail (hall_of_meat_skater.cpp read_offboard).
        bool ragdoll = false;
        if (!onboard) {
            std::uintptr_t trick_state{}, offboard{};
            std::uint8_t flag{};
            if (first_person_read(bodies.core + state_addr::trick_state_offset, &trick_state, 8) &&
                first_person_read(trick_state + state_addr::offboard_state_offset, &offboard, 8) &&
                first_person_read(offboard + state_addr::ragdoll_offset, &flag, 1))
                ragdoll = flag != 0;
        }
        std::uint8_t stance_flags{};
        const bool switch_stance = first_person_read(bodies.context + addr::grind_exit::stance_flags_offset, &stance_flags, 1) &&
            (stance_flags & addr::grind_exit::stance_switch_mask) != 0;

        s3cam::SubjectSnapshot s;
        s.time = static_cast<float>(now);
        s.position = skater.skater_position;
        s.forward = s3cam::normalized({entity[8], entity[9], entity[10]}, {0, 0, 1}); // entity row 2 is forward (measured in game)
        s.velocity = velocity;
        s.physics_state = state;
        s.onboard = onboard;
        s.bailing = !onboard && ragdoll;
        s.manual = false; // no native signal found yet: manuals use the chase shot
        s.grind_side = 0; // which side the ledge is on: not read yet
        s.switch_stance = switch_stance;
        w.world = resolve_world(trial.base);
        // On a steep ramp (vert, quarter pipes) a straight-down ray misses the ramp and finds the floor metres
        // below, which put the takeoff height and the camera floor at the bottom of the ramp. There the ray runs
        // along the last slope's normal instead, and the clearance is the distance along it.
        const bool steep = w.ground_normal[1] < steep_ground_y;
        const Vec3 down = steep ? s3cam::scale(w.ground_normal, -1.0f) : Vec3{0, -1, 0};
        auto ground = cast(s3cam::sub(s.position, s3cam::scale(down, ground_ray_above)), s3cam::add(s.position, s3cam::scale(down, ground_ray_below)));
        bool along_slope = steep && ground.has_value();
        if (!ground && steep) ground = cast(s3cam::add(s.position, {0, ground_ray_above, 0}), s3cam::sub(s.position, {0, ground_ray_below, 0}));
        if (ground) {
            s.ground_clearance = along_slope ? s3cam::length(s3cam::sub(s.position, *ground)) : s.position[1] - (*ground)[1];
            if (const auto n = try_normal_at(*ground)) {
                w.ground_normal_raw = *n;
                const double gap = std::clamp(now - w.ground_normal_at, 0.0, 0.25);
                const double smooth = std::min(normal_smooth_time, normal_smooth_distance / std::max(0.1, static_cast<double>(s3cam::length(velocity))));
                const auto rate = static_cast<float>(1.0 - std::exp(-gap / smooth));
                w.ground_normal = s3cam::normalized(s3cam::lerp(w.ground_normal, *n, rate), *n);
            }
        }
        w.ground_normal_at = now;
        s.ground_normal = w.ground_normal;
        // The board's real centre (its root body, +0x50 like the others): manuals and grinds aim at it.
        {
            Vec3 board{};
            s.board_valid = first_person_read(bodies.parts[state_addr::board_root_body] + body_position_offset, board.data(), sizeof(board)) &&
                std::isfinite(board[0] + board[1] + board[2]) && s3cam::length(s3cam::sub(board, s.position)) < 2.5f;
            if (s.board_valid) s.board_position = board;
        }
        // Board pitch against the ground: the extreme bodies along the skater's forward.
        {
            const Vec3 axis = s3cam::normalized({s.forward[0], 0.0f, s.forward[2]}, {0, 0, 1});
            Vec3 front{}, back{};
            float most = -1e9f, least = 1e9f;
            bool any = false;
            for (std::size_t i = 0; i < board_body_count; ++i) {
                Vec3 p{};
                if (!first_person_read(bodies.parts[i] + body_position_offset, p.data(), sizeof(p)) ||
                    !std::isfinite(p[0] + p[1] + p[2]))
                    continue;
                const float along = s3cam::dot(p, axis);
                if (along > most) { most = along; front = p; }
                if (along < least) { least = along; back = p; }
                any = true;
            }
            const Vec3 span = s3cam::sub(front, back);
            w.board_pitch_ok = any && s3cam::length(span) > 0.3f && s3cam::length(span) < 2.0f;
            if (w.board_pitch_ok) {
                const float up = s3cam::dot(s3cam::normalized(span), s3cam::normalized(w.ground_normal_raw, {0, 1, 0}));
                w.board_pitch = std::asin(std::clamp(up, -1.0f, 1.0f)) / s3cam::degrees;
            }
            // No manuals on steep ground (ramps, transitions: the board follows a curve there) or in the landing bounce:
            // the Beta log had 186 manual detections in 30 min, most right after landings or at 13-32 m/s on ramps.
            if (s3cam::is_air_state(w.state) && !s3cam::is_air_state(state)) w.landed_at = now;
            const bool rolling = onboard && !s3cam::is_air_state(state) && !s3cam::is_grind_state(state) &&
                w.ground_normal_raw[1] >= manual_max_slope_y && now - w.landed_at >= manual_after_landing;
            const bool tilted = w.board_pitch_ok && rolling &&
                std::abs(w.board_pitch) >= (w.manual ? manual_off_degrees : manual_on_degrees);
            if (tilted != w.manual) {
                if (!w.manual_candidate) { w.manual_candidate = true; w.manual_candidate_since = now; }
                if (now - w.manual_candidate_since >= (w.manual ? manual_off_time : manual_on_time)) {
                    w.manual = tilted;
                    w.manual_candidate = false;
                    if (s3cam_options().verbose)
                        logging::log(Level::info, Channel::skater, "s3cam manual {} (board pitch {:+.1f} deg, state {})",
                            w.manual ? (w.board_pitch > 0 ? "on (nose up)" : "on (nose down)") : "off", w.board_pitch, state);
                }
            } else w.manual_candidate = false;
            s.manual = w.manual;
        }
        // Hippy jump: off the board from a riding state, without a ragdoll.
        {
            const bool riding_before = w.state != no_state && w.state != addr::no_bail::offboard_physics_state &&
                (w.state < 700 || w.state == s3cam::physics_state::post_grind);
            if (onboard || ragdoll) w.hippy = false;
            else if (state != w.state && riding_before) {
                w.hippy = true;
                w.hippy_since = now;
                w.hippy_slow = false;
                if (s3cam_options().verbose)
                    logging::log(Level::info, Channel::skater, "s3cam hippy jump: off the board from state {}, keeping the view", w.state);
            }
            if (w.hippy) {
                const bool moving = std::hypot(velocity[0], velocity[2]) > hippy_still_speed; // the hips, off the board
                if (moving) w.hippy_slow = false;
                else if (!w.hippy_slow) { w.hippy_slow = true; w.hippy_slow_since = now; }
                const bool stopped = w.hippy_slow && now - w.hippy_since >= hippy_min_time && now - w.hippy_slow_since >= hippy_still_time;
                if (stopped || now - w.hippy_since >= hippy_max_time) {
                    w.hippy = false;
                    if (s3cam_options().verbose)
                        logging::log(Level::info, Channel::skater, "s3cam hippy jump over after {:.2f} s ({})", now - w.hippy_since,
                            stopped ? "standing still off the board" : "time limit");
                }
            }
            // In the jump the camera treats the skater as in the air (air camera, landing prediction).
            if (w.hippy) s.physics_state = s3cam::physics_state::air;
        }
        s.valid = true;
        if (s.position == w.last_root) ++w.root_repeats;
        w.last_root = s.position;
        if (s.position != w.physics_root) {
            w.physics_root = s.position;
            w.root_changed_at = now;
        } else {
            const auto ahead = static_cast<float>(std::clamp(now - w.root_changed_at, 0.0, max_extrapolation));
            s.position = s3cam::add(s.position, s3cam::scale(s.velocity, ahead));
            if (s3cam::is_air_state(state)) s.position[1] -= 0.5f * extrapolation_gravity * ahead * ahead;
        }
        w.subject = s;
        w.observed = s3cam::usable(s);

        if (state != w.state) {
            if (s3cam_options().verbose)
                logging::log(Level::info, Channel::skater, "s3cam state {} -> {} after {:.2f} s{}{}",
                    w.state == no_state ? 0u : w.state, state, now - w.state_since, ragdoll ? " (ragdoll)" : "",
                    switch_stance ? " (switch)" : "");
            w.state = state;
            w.state_since = now;
        }
        // Paused: the root has not moved for a while though the body still has speed, or the physics
        // step is 0.
        w.physics_step = bodies.seconds;
        if (bodies.seconds <= 0.0f) {
            if (!w.step_zero) { w.step_zero = true; w.step_zero_since = now; }
        } else w.step_zero = false;
        const bool frozen = now - w.root_changed_at >= pause_after && s3cam::length(velocity) > pause_min_speed;
        const bool paused = frozen || (w.step_zero && now - w.step_zero_since >= pause_after);
        if (paused != w.paused && s3cam_options().verbose)
            logging::log(Level::info, Channel::skater, "s3cam game {} (physics step {:.4f} s, speed {:.1f} m/s)",
                paused ? "paused" : "running", bodies.seconds, s3cam::length(velocity));
        w.paused = paused;
        result.valid = w.observed;
        result.state = state;
        result.paused = paused;
        result.bailing = !onboard && ragdoll;
        result.wants_view = (onboard || ragdoll || w.hippy) && !paused;
    } catch (...) {
        ++w.unreadable;
        w.subject.valid = false;
        return result;
    }
    if (!w.wants_known || result.wants_view != w.wants) {
        w.wants_known = true;
        w.wants = result.wants_view;
        w.wants_since = now;
    }
    result.wants_for = now - w.wants_since;
    return result;
}

void s3cam_begin(const SourceTrial& trial, std::uintptr_t native_camera, const std::array<float, 16>& view) {
    source_require(s3cam::handedness(view) == 1,
        "Dynamic Camera needs the game camera's right x up = backward rows; this camera differs. Not started.");
    auto& r = run();
    const auto landings = r.landings;
    r = {};
    r.landings = landings;
    r.native_camera = native_camera;
    r.started = r.last_pose = source_flight_now();
    r.report_at = r.started + 1;
    r.rays_at_report = watch().rays;
    r.blend = 0.0f;
    r.blend_target = 1.0f;
    r.running = true;
    camera_man().request_reset();
    const auto settings = s3cam_settings();
    logging::log(Level::info, Channel::skater,
        "s3cam on: preset {}, angle {}, shake {}, fov override {:.0f}, shot fov {}; native camera 0x{:x}, rays {}",
        preset_name(settings.preset), angle_name(settings.angle), settings.shake_enabled ? "on" : "off",
        settings.fov_override_deg, s3cam_options().shot_fov ? "on" : "off", native_camera,
        surface(trial.base).ready ? "ready" : "unavailable (no landing prediction)");
}

std::array<float, 16> s3cam_pose(const SourceTrial& trial, const std::array<float, 16>& previous, float& fov) {
    auto& r = run();
    auto& w = watch();
    fov = 0;
    source_require(r.running, "Dynamic Camera is not running.");
    const auto now = source_flight_now();
    const auto dt = std::clamp(now - r.last_pose, 0.0, 0.25);
    r.last_pose = now;
    ++r.frames;
    ++r.total_frames;
    report(r, w, now);
    if (!w.observed) {
        ++r.held;
        ++r.total_held;
        source_require(false, "Dynamic Camera: the skater is unreadable; holding the view.");
    }
    auto& man = camera_man();
    {
        auto& store = settings_store();
        std::lock_guard lock(store.mutex);
        if (store.revision != r.applied_revision) {
            r.applied_revision = store.revision;
            r.options = store.options;
            if (!man.set_settings(store.camera))
                logging::write(Level::warning, Channel::skater, "s3cam: settings rejected (out of range); the previous ones stay.");
        }
    }
    s3cam::NativePose native;
    s3cam::FrameExtras extras;
    r.native_ok = read_native(trial.base, r.native_camera, native);
    if (r.native_ok) {
        extras.native = &native;
        if (native.position != r.native_last) ++r.native_moved;
        r.native_last = native.position;
        r.native_distance = s3cam::length(s3cam::sub(native.position, w.subject.position));
        float value{};
        r.native_fov = first_person_read(r.native_camera + camera_fov_field, &value, 4) && std::isfinite(value) &&
            value >= plausible_fov_min && value <= plausible_fov_max ? value : 0.0f;
    } else {
        ++r.native_unreadable;
        r.native_distance = -1.0f;
        r.native_fov = 0.0f;
    }
    r.base_fov = r.native_fov > 0 ? r.native_fov : r.fallback_fov;
    native.fov_deg = r.base_fov;
    extras.base_fov_deg = r.base_fov; // the camera core's speed / big-air FOV terms ride on the game's own FOV

    LARGE_INTEGER begin{}, end{};
    QueryPerformanceCounter(&begin);
    auto ground = [](const Vec3& from, const Vec3& to, bool want_normal = true) noexcept { return ground_query(from, to, want_normal); };
    const auto& frame = man.update(static_cast<float>(dt), w.subject, ground, extras);
    QueryPerformanceCounter(&end);
    const double ms = qpc_ms(begin, end);
    r.update_ms += ms;
    r.update_ms_max = std::max(r.update_ms_max, ms);
    r.total_update_ms += ms;
    r.steps += static_cast<std::uint32_t>(std::max(0, frame.debug.steps));
    if (frame.debug.held) { ++r.held; ++r.total_held; }
    if (frame.debug.reset) ++r.resets;
    if (!frame.valid) { ++r.failed; source_require(false, "Dynamic Camera has no pose yet; holding the view."); }
    watch_frame(r, w, frame, now);

    // Crossfade with the game's camera. Without a readable game camera there is nothing to fade
    // with: S3Cam's pose shows as it is (and a release completes at once).
    const float blend_time = r.blend_target > r.blend ? r.options.take_blend_time : r.options.release_blend_time;
    const float blend_step = blend_time > 0.0f ? static_cast<float>(dt) / std::max(blend_time, 1e-3f) : 1.0f;
    r.blend = r.blend_target > r.blend ? std::min(r.blend_target, r.blend + blend_step) : std::max(r.blend_target, r.blend - blend_step);
    if (!r.native_ok) r.blend = r.blend_target;
    const float mix = r.native_ok ? s3cam::sine_blend(r.blend) : 1.0f;
    Vec3 right = frame.right, up = frame.up, back = frame.back, pos = frame.pos;
    if (mix < 1.0f) {
        right = s3cam::lerp(native.right, right, mix);
        up = s3cam::lerp(native.up, up, mix);
        back = s3cam::lerp(native.back, back, mix);
        pos = s3cam::lerp(native.position, pos, mix);
        s3cam::camera_detail::orthonormalize(right, up, back);
    }
    auto matrix = previous;
    const std::array<const Vec3*, 4> rows{&right, &up, &back, &pos};
    for (std::size_t row = 0; row < 4; ++row)
        for (std::size_t lane = 0; lane < 3; ++lane) matrix[row * 4 + lane] = (*rows[row])[lane];
    if (!valid_flight_transform(matrix)) { ++r.failed; source_require(false, "Dynamic Camera's pose is invalid; holding the view."); }
    if (r.options.shot_fov || man.settings().fov_override_deg > 0) {
        // The game's FOV at either end of the crossfade, so taking and handing back keep the zoom.
        fov = r.base_fov > 0 ? r.base_fov + (frame.fov_deg - r.base_fov) * mix : frame.fov_deg;
    }
    return matrix;
}

void s3cam_end(const char* reason) noexcept {
    auto& r = run();
    if (!r.running) return;
    r.running = false;
    try {
        if (r.landing_pending && r.options.verbose) log_landing(r);
        r.landing_pending = false;
        logging::log(Level::info, Channel::skater,
            "s3cam off ({}): {:.1f} s, {} frames, {} held, update {:.3f} ms mean, {} landings so far",
            reason ? reason : "stopped", source_flight_now() - r.started, r.total_frames, r.total_held,
            r.total_frames ? r.total_update_ms / static_cast<double>(r.total_frames) : 0.0, r.landings);
    } catch (...) {}
}

bool s3cam_running() noexcept { return run().running; }

void s3cam_release(bool release) noexcept { run().blend_target = release ? 0.0f : 1.0f; }
bool s3cam_released() noexcept {
    const auto& r = run();
    return !r.running || (r.blend_target <= 0.0f && (r.blend <= 0.0f || !r.native_ok));
}
void s3cam_set_fallback_fov(float fov) noexcept {
    run().fallback_fov = std::isfinite(fov) && fov >= plausible_fov_min && fov <= plausible_fov_max ? fov : 0.0f;
}
bool s3cam_game_camera_away() noexcept {
    const auto& r = run();
    return r.running && r.native_ok && r.native_distance > native_away_distance;
}
bool s3cam_game_camera_near(std::uintptr_t base, std::uintptr_t native_camera) noexcept {
    s3cam::NativePose native;
    const auto& w = watch();
    if (!w.observed || !read_native(base, native_camera, native)) return true; // unknown: do not block
    return s3cam::length(s3cam::sub(native.position, w.subject.position)) <= native_away_distance;
}
void s3cam_game_height(bool high) noexcept {
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    if (!store.options.follow_game_height) return;
    const auto angle = high ? s3cam::CameraAngle::High : s3cam::CameraAngle::Low;
    if (store.camera.angle == angle) return;
    store.camera.angle = angle;
    ++store.revision;
}
void s3cam_toggle_height() noexcept {
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    if (!store.options.follow_game_height) return;
    store.camera.angle = store.camera.angle == s3cam::CameraAngle::High ? s3cam::CameraAngle::Low : s3cam::CameraAngle::High;
    ++store.revision;
}
void s3cam_swap_side(int side) noexcept {
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    auto& shoulder = store.camera.shoulder;
    // Swapping from Off or Auto takes manual control: the swap is the player's choice.
    const int current = shoulder.mode == s3cam::ShoulderSide::Off ? -1 : shoulder.side;
    shoulder.side = side == 0 ? -current : (side > 0 ? 1 : -1);
    shoulder.mode = s3cam::ShoulderSide::Manual;
    ++store.revision;
}
std::uint64_t s3cam_settings_revision() noexcept {
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    return store.revision;
}

void s3cam_note_flow(std::uintptr_t client, bool can_control, bool phase, const SourceCameraSnapshot* camera, bool owned) noexcept {
    auto& w = watch();
    std::uint32_t flow{};
    (void)first_person_read(client + client_flow_state_offset, &flow, 4);
    const std::uint32_t mode = camera ? camera->mode : 0xff;
    const bool ours = camera && camera->active == camera->identity.camera;
    if (w.flow_known && flow == w.flow_state && can_control == w.flow_control && phase == w.flow_phase &&
        owned == w.flow_owned && mode == w.flow_mode && ours == w.flow_view_ours)
        return;
    w.flow_known = true;
    w.flow_state = flow;
    w.flow_control = can_control;
    w.flow_phase = phase;
    w.flow_owned = owned;
    w.flow_mode = mode;
    w.flow_view_ours = ours;
    if (!s3cam_options().verbose) return; // detailed logging only (s3cam_log 1)
    try {
        logging::log(Level::info, Channel::skater,
            "s3cam flow: client state {}, control {}, camera phase {}, camera mode {}{}, S3Cam {}",
            flow, can_control ? "yes" : "no", phase ? "verified" : "lost", mode == 0xff ? std::string("?") : std::to_string(mode),
            ours ? " (FreeCamera active)" : "", owned ? "owns the view" : "handed back");
    } catch (...) {}
}

void s3cam_note(const char* what) noexcept {
    try { logging::log(Level::info, Channel::skater, "s3cam: {}", what ? what : ""); } catch (...) {}
}

s3cam::CameraSettings s3cam_settings() noexcept {
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    return store.camera;
}
bool s3cam_set_settings(const s3cam::CameraSettings& settings) noexcept {
    if (!settings.valid()) return false;
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    store.camera = settings;
    ++store.revision;
    return true;
}
S3CamOptions s3cam_options() noexcept {
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    return store.options;
}
void s3cam_set_options(const S3CamOptions& options) noexcept {
    auto& store = settings_store();
    std::lock_guard lock(store.mutex);
    store.options = options;
    ++store.revision;
}

std::string s3cam_dump() {
    const auto settings = s3cam_settings();
    const auto options = s3cam_options();
    std::string text = std::format("Dynamic Camera {} | preset {} | angle {} | shake {} | fov override {:.0f} | shot fov {} | log {}",
        run().running ? "owns the view" : "idle", preset_name(settings.preset), angle_name(settings.angle),
        settings.shake_enabled ? "on" : "off", settings.fov_override_deg, options.shot_fov ? "on" : "off",
        options.verbose ? "on" : "off");
    if (run().running) {
        const auto& f = camera_man().frame();
        const auto& d = f.debug;
        text += std::format("\nshot {} ({:.0f}%) | speed {:.1f} m/s | dist {:.2f} m | elev {:.1f} deg | heading {:.1f} deg | "
                            "anchor lag {:.2f} m | air hold {:+.2f} m | impulse {:.3f} | fov {:.1f} | incline {:.1f} deg",
            d.shot_name, d.shot_fraction * 100, d.speed, d.distance, d.elevation / s3cam::degrees, d.heading / s3cam::degrees,
            d.anchor_lag, d.air_hold_delta, d.impulse, f.fov_deg, d.incline_degrees);
    }
    return text;
}
}
