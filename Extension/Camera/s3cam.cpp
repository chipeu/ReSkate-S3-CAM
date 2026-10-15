#include "s3cam.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Game/Build/20260929/engine.h"
#include "Engine/Game/Build/20260929/grind_exit.h"
#include "Engine/Game/Build/20260929/no_bail.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include "Engine/Game/Camera/s3_camera.h"
#include "Engine/Game/Camera/s3_probe_pose.h"
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
// close to a chord's start is skipped by casting again from a little further along.
constexpr float start_hit_skip = 0.02f, start_hit_restart = 0.03f;
// The skater's root moves once per physics step (60 Hz). Rendering faster, the frames between two
// steps would see it stand still and then jump, which reads as a choppy camera at speed and in big
// airs: between steps the root is carried forward along its velocity, at most this long.
constexpr double max_extrapolation = 1.0 / 30.0;
constexpr float extrapolation_gravity = 10.1f; // m/s2, SPIKES.md S4
// The camera's degree FOV (client_source_spawn.h camera_fov_init: "the camera's degree FOV at
// +0xac"). Read from the game's own camera too; used only while it looks like a FOV.
constexpr std::uintptr_t camera_fov_field = 0xac;
constexpr float plausible_fov_min = 10.0f, plausible_fov_max = 150.0f;
// The game's camera this far from the skater while S3Cam owns the view: the game has moved it to a
// screen of its own (map, customisation); S3Cam hands back at once and does not take it again there.
constexpr float native_away_distance = 25.0f;

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
    // Extrapolation between physics steps (max_extrapolation).
    Vec3 physics_root{};
    double root_changed_at{};
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
    float landed_air{}, landed_drop{}, landing_impulse{}, landing_speed{};
    bool landing_pending{};
    std::uint32_t landings{};
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
// the hit (SPIKES.md S3: flat 0.7 deg, ramps 41 and 60 deg measured this way).
Vec3 normal_at(const Vec3& hit) noexcept {
    const auto probe = [&](float dx, float dz) {
        return cast({hit[0] + dx, hit[1] + 0.5f, hit[2] + dz}, {hit[0] + dx, hit[1] - 0.5f, hit[2] + dz});
    };
    const auto x = probe(0.25f, 0), z = probe(0, 0.25f);
    if (!x || !z) return {0, 1, 0};
    auto n = s3cam::cross(s3cam::sub(*z, hit), s3cam::sub(*x, hit));
    if (n[1] < 0) n = s3cam::scale(n, -1);
    return s3cam::normalized(n, {0, 1, 0});
}
std::optional<s3cam::GroundHit> ground_query(const Vec3& from, const Vec3& to) noexcept {
    auto hit = cast(from, to);
    if (hit && s3cam::length(s3cam::sub(*hit, from)) < start_hit_skip) {
        const auto direction = s3cam::normalized(s3cam::sub(to, from));
        const auto restart = s3cam::add(from, s3cam::scale(direction, start_hit_restart));
        if (s3cam::dot(s3cam::sub(to, restart), direction) <= 0) return std::nullopt;
        hit = cast(restart, to);
    }
    if (!hit) return std::nullopt;
    return s3cam::GroundHit{*hit, normal_at(*hit)};
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
        "speed {:.1f} m/s, shake impulse peak {:.3f}",
        r.landings, r.landed_air, predicted(r.predicted_air, "s", false), r.landed_drop, predicted(r.predicted_drop, "m", true),
        predicted(r.predicted_height, "m", false), r.landing_speed, r.landing_impulse);
}

// Shot changes, takeoffs and landings, from the frame's debug values.
void watch_frame(Run& r, const Watch& w, const s3cam::Frame& frame, double now) {
    const auto& d = frame.debug;
    if (r.options.verbose && d.shot_name != r.shot)
        logging::log(Level::info, Channel::skater, "s3cam shot {} -> {} (state {}, speed {:.1f})",
            r.shot.empty() ? std::string_view("none") : r.shot, d.shot_name, w.state, d.speed);
    r.shot = d.shot_name;
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
    logging::log(Level::info, Channel::skater,
        "s3cam t={:.0f} {} fps, {} steps, {} held, {} resets, {} failed, {} unreadable, root repeated on {}, "
        "game camera moved on {} (unreadable {}) | "
        "update {:.3f} ms mean, {:.3f} max, {} rays | state {} shot {} speed {:.1f} clearance {:.2f} normal.y {:.3f} | "
        "dist {:.2f} elev {:.1f} deg lag {:.2f} | fov {:.1f} (game camera {:.1f}, FreeCamera at take {:.1f}) | "
        "game camera {:.1f} m from the skater | blend {:.2f}",
        now - r.started, r.frames, r.steps, r.held, r.resets, r.failed, w.unreadable, w.root_repeats, r.native_moved,
        r.native_unreadable,
        r.frames ? r.update_ms / r.frames : 0.0, r.update_ms_max, w.rays - r.rays_at_report, w.state, d.shot_name, d.speed,
        w.subject.ground_clearance, w.subject.ground_normal[1], d.distance, d.elevation / s3cam::degrees, d.anchor_lag,
        f.fov_deg, r.native_fov, r.fallback_fov, r.native_distance, r.blend);
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
        // Offboard covers walking and bails alike (SPIKES.md); the offboard state's ragdoll flag
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
        s.forward = s3cam::normalized({entity[8], entity[9], entity[10]}, {0, 0, 1}); // entity row 2 is forward (SPIKES.md S2)
        s.velocity = velocity;
        s.physics_state = state;
        s.onboard = onboard;
        s.bailing = !onboard && ragdoll;
        s.manual = false; // no native signal found yet (SPIKES.md): manuals use the chase shot
        s.grind_side = 0; // which side the ledge is on: not read yet
        s.switch_stance = switch_stance;
        w.world = resolve_world(trial.base);
        if (const auto ground = cast(s3cam::add(s.position, {0, ground_ray_above, 0}),
                s3cam::sub(s.position, {0, ground_ray_below, 0}))) {
            s.ground_clearance = s.position[1] - (*ground)[1];
            s.ground_normal = normal_at(*ground);
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
        result.valid = w.observed;
        result.state = state;
        result.wants_view = onboard || ragdoll;
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
    source_require(s3cam::probe::handedness(view) == 1,
        "S3Cam needs the game camera's right x up = backward rows; this camera differs. Not started.");
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
    source_require(r.running, "S3Cam is not running.");
    const auto now = source_flight_now();
    const auto dt = std::clamp(now - r.last_pose, 0.0, 0.25);
    r.last_pose = now;
    ++r.frames;
    ++r.total_frames;
    report(r, w, now);
    if (!w.observed) {
        ++r.held;
        ++r.total_held;
        source_require(false, "S3Cam: the skater is unreadable; holding the view.");
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
    auto ground = [](const Vec3& from, const Vec3& to) noexcept { return ground_query(from, to); };
    const auto& frame = man.update(static_cast<float>(dt), w.subject, ground, extras);
    QueryPerformanceCounter(&end);
    const double ms = qpc_ms(begin, end);
    r.update_ms += ms;
    r.update_ms_max = std::max(r.update_ms_max, ms);
    r.total_update_ms += ms;
    r.steps += static_cast<std::uint32_t>(std::max(0, frame.debug.steps));
    if (frame.debug.held) { ++r.held; ++r.total_held; }
    if (frame.debug.reset) ++r.resets;
    if (!frame.valid) { ++r.failed; source_require(false, "S3Cam has no pose yet; holding the view."); }
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
    if (!valid_flight_transform(matrix)) { ++r.failed; source_require(false, "S3Cam's pose is invalid; holding the view."); }
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
    std::string text = std::format("S3Cam {} | preset {} | angle {} | shake {} | fov override {:.0f} | shot fov {} | log {}",
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
