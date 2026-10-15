#include "s3cam_probe.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Game/Build/20260929/engine.h"
#include "Engine/Game/Build/20260929/grind_exit.h"
#include "Engine/Game/Build/20260929/no_bail.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include "Engine/Game/Camera/s3_gravity_fit.h"
#include "Engine/Game/Camera/s3_probe_pose.h"
#include "Extension/Objects/ParkEditor/park_editor_surface.h"
#include "Extension/Objects/local_placements_runtime.h"
#include "Extension/Skater/camera_observer.h"
#include "Extension/Skater/free_flight.h"
#include <algorithm>
#include <cmath>
#include <format>

namespace dingosdk::client_source::detail {
namespace {
namespace pose = s3cam::probe;
namespace state_addr = addr::skater_state;
using logging::Channel;
using logging::Level;

// Board root body (board physics body 0): noclip reads its +0x54 as the board's altitude.
// Whether +0x50..+0x58 is the whole position is a guess this spike checks against the skater root.
constexpr std::uintptr_t board_body_position_offset = 0x50;
constexpr std::uint32_t no_state = 0xffffffff;

struct Probe {
    bool armed{};
    // Mode 2 (S1b): instead of selecting the FreeCamera (mode 1), overwrite the game's own camera
    // after its update. Counters say whether the write stuck and when it was skipped.
    // Run 3: written after the debug tick, the pose never showed (the view had already taken the
    // camera). Now the tick only computes it, and the native camera update's listener writes it
    // right after the game's own update (S1c), one frame behind the skater.
    bool overlay{}, overlay_written{};
    std::array<float, 16> overlay_last{};
    double overlay_at{};
    DWORD overlay_thread{};
    std::uint64_t overlay_writes{}, overlay_held{}, overlay_offboard{}, overlay_other_camera{}, overlay_failed{};
    std::uint64_t updates_seen{}, updates_other_thread{}, updates_stale{};
    double overlay_report_at{};
    // S1e. Run 5: the update's output never held the view, but the camera keeps a second copy of
    // its view rows at +0x10 (identical to +0x50 at the tick). Both are written, in the update's
    // listener and again at the tick, and the tick counts which still hold our pose.
    std::uint64_t held_10{}, held_50{}, tick_writes{};
    std::uintptr_t native_camera{};
    int hand{};
    pose::Vec3 heading{0, 0, 1};
    double armed_at{}, last_tick{}, report_at{};
    // S1: does the native gameplay camera keep updating while mode 1 owns the view?
    std::array<float, 16> native_last{};
    bool native_seen{};
    std::uint32_t ticks{}, native_moved{}, native_unreadable{};
    double native_distance{};
    std::uint32_t native_distance_samples{};
    std::uint64_t total_ticks{}, total_moved{}, total_unreadable{};
    // S2: is the entity transform's third row the skater's forward (+1) or backward (-1)?
    double forward_dot{};
    std::uint64_t forward_samples{};
    std::uint32_t state{no_state};
    double state_since{};
    int stance_switch{-1}; // grind_exit.h stance flag: 1 riding switch (verified for goofy only)
    // S4: one gravity fit per airborne arc, of the board root and of the skater root (the samples
    // live in arc() and root_arc(), below). Only state 201 (KNOWN_AIR) is recorded: run 2 showed
    // that arcs that include the pop (200) fit anywhere from 2 to 28 m/s2, because the feet still
    // push the board then.
    bool airborne{};
    float arc_last_height{}, launch_height{}, apex{};
    std::array<double, 64> root_fits{};
    std::size_t root_fit_count{};
    std::array<double, 64> fits{};
    std::size_t fit_count{};
};
Probe& probe() {
    static auto* value = new Probe;
    return *value;
}
s3cam::ArcRecorder& arc() {
    static auto* value = new s3cam::ArcRecorder; // 16 KB: kept off the engine thread's stack
    return *value;
}
s3cam::ArcRecorder& root_arc() {
    static auto* value = new s3cam::ArcRecorder;
    return *value;
}

bool read_native_view(std::uintptr_t base, std::uintptr_t camera, std::array<float, 16>& view) noexcept {
    std::uintptr_t vtable{};
    // A level change can destroy the camera while mode 1 owns the view: check its type every
    // time, through the guarded reader.
    if (!first_person_read(camera, &vtable, 8) || vtable != base + addr::engine::camera_vtable) return false;
    return first_person_read(camera + 0x50, view.data(), sizeof(view)) && valid_flight_transform(view);
}
bool write_bytes(std::uintptr_t address, const void* data, std::size_t size) noexcept {
    if (address < 0x10000 || size > 0x10000 || address > source_highest - size) return false;
    __try { std::memcpy(reinterpret_cast<void*>(address), data, size); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
// The camera's two copies of its view rows (+0x10 and +0x50): rows replaced, fourth lanes kept.
constexpr std::array<std::uintptr_t, 2> view_copies{0x10, 0x50};
bool write_view_rows(std::uintptr_t camera, std::uintptr_t offset, const std::array<float, 16>& view) noexcept {
    std::array<float, 16> rows{};
    if (!first_person_read(camera + offset, rows.data(), sizeof(rows))) return false;
    for (const std::size_t i : {0u, 1u, 2u, 4u, 5u, 6u, 8u, 9u, 10u, 12u, 13u, 14u}) rows[i] = view[i];
    return write_bytes(camera + offset, rows.data(), sizeof(rows));
}
bool holds_rows(std::uintptr_t camera, std::uintptr_t offset, const std::array<float, 16>& view) noexcept {
    std::array<float, 16> rows{};
    if (!first_person_read(camera + offset, rows.data(), sizeof(rows))) return false;
    for (const std::size_t i : {0u, 1u, 2u, 4u, 5u, 6u, 8u, 9u, 10u, 12u, 13u, 14u})
        if (rows[i] != view[i]) return false;
    return true;
}
bool view_changed(const std::array<float, 16>& a, const std::array<float, 16>& b) {
    for (const std::size_t i : {0u, 1u, 2u, 4u, 5u, 6u, 8u, 9u, 10u})
        if (std::abs(a[i] - b[i]) > 1e-5f) return true;
    for (const std::size_t i : {12u, 13u, 14u})
        if (std::abs(a[i] - b[i]) > 1e-4f) return true;
    return false;
}
double median(std::array<double, 64> values, std::size_t count) {
    if (!count) return 0;
    std::sort(values.begin(), values.begin() + static_cast<std::ptrdiff_t>(count));
    return count % 2 ? values[count / 2] : (values[count / 2 - 1] + values[count / 2]) / 2;
}
void log_arc(Probe& p, float landing_height) {
    const auto fit = arc().fit();
    if (const auto root = root_arc().fit()) {
        if (p.root_fit_count < p.root_fits.size()) p.root_fits[p.root_fit_count++] = root->gravity;
        logging::log(Level::info, Channel::skater, "s3cam_probe air root: {:.3f} s, g={:.3f} m/s2 rms={:.4f} m over {} samples",
            root->duration, root->gravity, root->rms, root->samples);
    }
    if (!fit) {
        logging::log(Level::info, Channel::skater,
            "s3cam_probe air: {} samples, too short to fit; apex {:+.2f} m, landed {:+.2f} m",
            arc().size(), p.apex - p.launch_height, landing_height - p.launch_height);
        return;
    }
    if (p.fit_count < p.fits.size()) p.fits[p.fit_count++] = fit->gravity;
    logging::log(Level::info, Channel::skater,
        "s3cam_probe air: {:.3f} s, apex {:+.2f} m, landed {:+.2f} m, g={:.3f} m/s2 rms={:.4f} m over {} samples",
        fit->duration, p.apex - p.launch_height, landing_height - p.launch_height, fit->gravity, fit->rms, fit->samples);
}
}

bool s3cam_probe_armed() noexcept { return probe().armed; }

void s3cam_probe_arm(const SourceTrial& trial, const SourceCameraSnapshot& native, const std::array<float, 16>& view, bool overlay) {
    SourceReader reader;
    source_require(native.mode == 0 && reader.pointer(native.active) == trial.base + addr::engine::camera_vtable,
        "The S3Cam probe needs the game's own camera (turn off Freecam, first person and spectate first).");
    const int hand = pose::handedness(view);
    source_require(hand != 0, "The game camera's matrix is not a rotation; probe not armed.");
    auto& p = probe();
    p = {};
    arc().clear();
    root_arc().clear();
    p.native_camera = native.active;
    p.hand = hand;
    // Start behind the skater exactly where the game's camera was looking.
    const auto look = pose::horizontal(pose::scaled(pose::row(view, 2), -1), 0.1f);
    if (look[0] || look[2]) p.heading = look;
    p.armed_at = p.last_tick = p.state_since = source_flight_now();
    p.report_at = p.armed_at + 1;
    p.native_last = view;
    p.native_seen = true;
    p.overlay = overlay;
    if (overlay) set_camera_updated_listener(&s3cam_camera_updated);
    p.overlay_report_at = p.armed_at + 5;
    p.armed = true;
    logging::log(Level::info, Channel::skater,
        "s3cam_probe armed ({}): native camera 0x{:x}, handedness {:+d} (right x up = {}backward)",
        overlay ? "mode 2, writes the game's camera" : "mode 1, takes the FreeCamera", native.active, hand, hand > 0 ? "" : "-");
}

std::array<float, 16> s3cam_probe_pose(const SourceTrial& trial, std::uintptr_t client, const std::array<float, 16>& previous) {
    auto& p = probe();
    source_require(p.armed, "The S3Cam probe is not armed.");
    const auto now = source_flight_now();
    const auto dt = std::clamp(now - p.last_tick, 0.0, 0.1);
    p.last_tick = now;

    // S1 first: sample the native camera every tick, even ones where the skater is unreadable.
    ++p.ticks;
    ++p.total_ticks;
    std::array<float, 16> native{};
    const bool native_readable = read_native_view(trial.base, p.native_camera, native);
    if (native_readable) {
        if (p.native_seen && view_changed(native, p.native_last)) { ++p.native_moved; ++p.total_moved; }
        p.native_last = native;
        p.native_seen = true;
    } else { ++p.native_unreadable; ++p.total_unreadable; }

    overlay::DebugModel skater;
    const auto entity = debug_skater(trial.base, client, skater);
    const auto bodies = debug_noclip_bodies(trial.base, client, skater.skater_identity);
    std::uint32_t state{};
    std::array<float, 3> velocity{}, board{};
    source_require(first_person_read(bodies.context + state_addr::physics_state_offset, &state, 4) &&
        first_person_read(bodies.parts[state_addr::board_root_body] + state_addr::body_velocity_offset, velocity.data(), sizeof(velocity)),
        "Skater physics is unreadable.");
    std::uint8_t stance_flags{};
    const int stance_switch = first_person_read(bodies.context + addr::grind_exit::stance_flags_offset, &stance_flags, 1)
        ? ((stance_flags & addr::grind_exit::stance_switch_mask) ? 1 : 0) : -1;
    const bool board_readable =
        first_person_read(bodies.parts[state_addr::board_root_body] + board_body_position_offset, board.data(), sizeof(board));
    const auto root = skater.skater_position;
    if (native_readable) {
        p.native_distance += pose::length(pose::sub(pose::row(native, 3), root));
        ++p.native_distance_samples;
    }

    // Heading: follow the direction of travel once moving, hold it when slow (standing, a stall,
    // straight up a quarter pipe). Only for the probe's framing; S3Cam proper uses the Skate 3
    // trackers.
    const auto travel = pose::horizontal(velocity, 1.0f);
    if (travel[0] || travel[2]) {
        p.heading = pose::turn_toward(p.heading, travel, static_cast<float>(1 - std::exp(-4.0 * dt)));
        const auto row2 = pose::horizontal(pose::row(entity, 2), 0.1f);
        if (row2[0] || row2[2]) { p.forward_dot += pose::dot(row2, travel); ++p.forward_samples; }
    }

    // S2/S4: state changes and airborne arcs.
    if (state != p.state) {
        logging::log(Level::info, Channel::skater, "s3cam_probe state {} -> {} after {:.2f} s",
            p.state == no_state ? 0u : p.state, state, now - p.state_since);
        p.state = state;
        p.state_since = now;
    }
    if (stance_switch != p.stance_switch) {
        logging::log(Level::info, Channel::skater, "s3cam_probe stance flag {} -> {} in state {}", p.stance_switch, stance_switch, state);
        p.stance_switch = stance_switch;
    }
    const bool air = state == state_addr::board_air_states[1]; // KNOWN_AIR only, see Probe
    if (air && !p.airborne) {
        p.airborne = true;
        arc().clear();
        root_arc().clear();
        p.launch_height = p.apex = p.arc_last_height = bodies.board_height;
        arc().add(now, bodies.board_height);
        root_arc().add(now, root[1]);
    } else if (air) {
        // A frame without a new physics step repeats the height; only real steps are samples.
        if (bodies.board_height != p.arc_last_height) {
            arc().add(now, bodies.board_height);
            root_arc().add(now, root[1]);
        }
        p.arc_last_height = bodies.board_height;
        p.apex = std::max(p.apex, bodies.board_height);
    } else if (p.airborne) {
        p.airborne = false;
        log_arc(p, bodies.board_height);
    }

    if (now >= p.report_at) {
        p.report_at = now + 1;
        const auto up = pose::row(entity, 1), row2 = pose::row(entity, 2);
        const float speed = pose::length(velocity);
        logging::log(Level::info, Channel::skater,
            "s3cam_probe t={:.1f} state={} switch={} speed={:.2f} | native moved {}/{} unreadable {} dist {:.2f} m | "
            "entity up=({:+.3f},{:+.3f},{:+.3f}) row2=({:+.3f},{:+.3f},{:+.3f}) row2.travel={:+.2f} | "
            "root=({:.2f},{:.2f},{:.2f}) board+0x50={}({:.2f},{:.2f},{:.2f}) board_h={:.3f} dt_phys={:.4f}",
            now - p.armed_at, state, stance_switch, speed, p.native_moved, p.ticks, p.native_unreadable,
            p.native_distance_samples ? p.native_distance / p.native_distance_samples : 0.0,
            up[0], up[1], up[2], row2[0], row2[1], row2[2],
            p.forward_samples ? p.forward_dot / static_cast<double>(p.forward_samples) : 0.0,
            root[0], root[1], root[2], board_readable ? "" : "unreadable", board[0], board[1], board[2],
            bodies.board_height, bodies.seconds);
        p.ticks = p.native_moved = p.native_unreadable = p.native_distance_samples = 0;
        p.native_distance = 0;
    }

    auto matrix = previous;
    source_require(pose::chase_pose(matrix, root, p.heading, p.hand) && valid_flight_transform(matrix),
        "The S3Cam probe pose is degenerate.");
    return matrix;
}

void s3cam_overlay_tick(const SourceTrial& trial, std::uintptr_t client, bool ready) {
    auto& p = probe();
    // Menus, the replay editor and loading leave the tick unready: write nothing, so whichever
    // camera the game selected shows as it would without ReSkate.
    if (!p.armed || !p.overlay || !ready) return;
    const auto camera = source_camera_snapshot(trial, client);
    std::array<float, 16> view{};
    if (camera.mode != 0 || camera.active != p.native_camera || !read_native_view(trial.base, p.native_camera, view)) {
        // Freecam, first person, spectate, the Park Editor or a new level's camera is showing.
        ++p.overlay_other_camera;
        p.overlay_written = false;
        return;
    }
    // Still exactly our last write: nothing updated the game's camera since (it may only
    // recompute on some frames, or keep our pose as its state).
    if (p.overlay_written && view == p.overlay_last) ++p.overlay_held;
    if (p.overlay_written) {
        // Which copy still holds the pose written in this frame's camera update?
        if (holds_rows(p.native_camera, 0x10, p.overlay_last)) ++p.held_10;
        if (holds_rows(p.native_camera, 0x50, p.overlay_last)) ++p.held_50;
    }
    const auto matrix = s3cam_probe_pose(trial, client, view);
    const auto now = source_flight_now();
    p.overlay_thread = GetCurrentThreadId();
    if (p.state == addr::no_bail::offboard_physics_state) {
        // On foot or bailing: the game's camera, right stick included, is left alone.
        ++p.overlay_offboard;
        p.overlay_written = false;
    } else {
        // Published for the next native camera update (s3cam_camera_updated), and written now too:
        // whichever copy the frame is drawn from after this point gets it.
        p.overlay_last = matrix;
        p.overlay_at = now;
        p.overlay_written = true;
        bool written = true;
        for (const auto offset : view_copies) written = write_view_rows(p.native_camera, offset, matrix) && written;
        if (written) ++p.tick_writes;
        else ++p.overlay_failed;
    }
    if (now >= p.overlay_report_at) {
        p.overlay_report_at = now + 5;
        logging::log(Level::info, Channel::skater,
            "s3cam_probe overlay: {} writes in the camera update ({} seen, {} other thread, {} stale), "
            "{} tick writes; still ours at the tick: +0x10 {}, +0x50 {}; {} skipped off board, {} other camera, {} failed",
            p.overlay_writes, p.updates_seen, p.updates_other_thread, p.updates_stale, p.tick_writes, p.held_10, p.held_50,
            p.overlay_offboard, p.overlay_other_camera, p.overlay_failed);
    }
}

void s3cam_camera_updated(std::uintptr_t camera, std::uintptr_t) noexcept {
    auto& p = probe();
    if (!p.armed || !p.overlay || camera != p.native_camera) return;
    ++p.updates_seen;
    // The probe's state belongs to the debug tick's thread; anything else only counts.
    if (GetCurrentThreadId() != p.overlay_thread) { ++p.updates_other_thread; return; }
    if (!p.overlay_written || source_flight_now() - p.overlay_at > 0.1) { ++p.updates_stale; return; }
    bool written = true;
    for (const auto offset : view_copies) written = write_view_rows(camera, offset, p.overlay_last) && written;
    if (written) ++p.overlay_writes;
    else ++p.overlay_failed;
}

void s3cam_probe_disarm(const char* reason) noexcept {
    auto& p = probe();
    if (!p.armed) return;
    p.armed = false;
    set_camera_updated_listener(nullptr);
    try {
        if (p.overlay)
            logging::log(Level::info, Channel::skater,
                "s3cam_probe overlay total: {} writes in the camera update ({} seen, {} other thread, {} stale), "
                "{} tick writes; still ours at the tick: +0x10 {}, +0x50 {}; {} skipped off board, {} other camera, {} failed",
                p.overlay_writes, p.updates_seen, p.updates_other_thread, p.updates_stale, p.tick_writes, p.held_10, p.held_50,
                p.overlay_offboard, p.overlay_other_camera, p.overlay_failed);
        logging::log(Level::info, Channel::skater,
            "s3cam_probe summary ({}): {:.1f} s, native camera moved on {}/{} ticks, unreadable {}; "
            "entity row2.travel mean {:+.2f} over {} samples; gravity median board {:.3f} over {} arcs, root {:.3f} over {} arcs",
            reason ? reason : "stopped", source_flight_now() - p.armed_at, p.total_moved, p.total_ticks,
            p.total_unreadable, p.forward_samples ? p.forward_dot / static_cast<double>(p.forward_samples) : 0.0,
            p.forward_samples, median(p.fits, p.fit_count), p.fit_count, median(p.root_fits, p.root_fit_count), p.root_fit_count);
    } catch (...) {}
}

std::string s3cam_ray_report(const SourceTrial& trial, std::uintptr_t client) {
    // Fingerprints are checked once per process, as the park editor does at its start.
    static const auto api = editor::surface_api(trial.base);
    source_require(api.ready, "The physics ray query does not match this game build; S3 is unavailable.");
    auto& placements = profile_runtime::placements_runtime();
    source_require(placements.context != nullptr, "The physics world context is not resolved yet.");
    // The dropper queries the client physics world, resolved on the client update.
    std::array<std::uintptr_t, 2> context{};
    placements.context(context.data());
    source_require(source_object(context[0]), "No client context for the physics world.");
    const auto world = api.world(context[0]);
    source_require(world != 0, "The client physics world is unavailable.");
    overlay::DebugModel skater;
    (void)debug_skater(trial.base, client, skater);
    const auto root = skater.skater_position;
    const auto down = [&](float dx, float dz) {
        return editor::cast_surface(api, world, {root[0] + dx, root[1] + 1, root[2] + dz}, {root[0] + dx, root[1] - 10, root[2] + dz});
    };
    std::string report;
    const auto ground = down(0, 0), x = down(0.25f, 0), z = down(0, 0.25f);
    if (ground) {
        report += std::format("ground {:+.3f} m below root", (*ground)[1] - root[1]);
        if (x && z) {
            auto normal = pose::cross(pose::sub(*z, *ground), pose::sub(*x, *ground));
            if (normal[1] < 0) normal = pose::scaled(normal, -1);
            const float l = pose::length(normal);
            if (l > 1e-6f)
                report += std::format(", normal ({:+.3f},{:+.3f},{:+.3f}) {:.1f} deg", normal[0] / l, normal[1] / l, normal[2] / l,
                    std::acos(std::clamp(normal[1] / l, -1.0f, 1.0f)) * 57.2957795f);
        }
    } else report += "no ground within 10 m";

    // Cost: batches of 10 casts like a camera frame would make (anchor -> camera candidates at
    // 2.5 m around the skater, chest height), timed with the performance counter.
    LARGE_INTEGER frequency{};
    QueryPerformanceFrequency(&frequency);
    constexpr int batches = 30, per_batch = 10;
    double total = 0, fastest = 1e9, slowest = 0;
    int hits = 0;
    for (int batch = 0; batch < batches; ++batch) {
        LARGE_INTEGER begin{}, end{};
        QueryPerformanceCounter(&begin);
        for (int i = 0; i < per_batch; ++i) {
            const float angle = 6.2831853f * static_cast<float>(i) / static_cast<float>(per_batch);
            const editor::Vec3 from{root[0], root[1] + 1, root[2]};
            const editor::Vec3 to{root[0] + 2.5f * std::cos(angle), root[1] + 1.5f, root[2] + 2.5f * std::sin(angle)};
            if (editor::cast_surface(api, world, from, to)) ++hits;
        }
        QueryPerformanceCounter(&end);
        const double ms = 1000.0 * static_cast<double>(end.QuadPart - begin.QuadPart) / static_cast<double>(frequency.QuadPart);
        total += ms;
        fastest = std::min(fastest, ms);
        slowest = std::max(slowest, ms);
    }
    report += std::format(" | 10 casts: mean {:.3f} ms, min {:.3f}, max {:.3f} (budget 0.3) | {} of {} rays hit",
        total / batches, fastest, slowest, hits, batches * per_batch);
    logging::log(Level::info, Channel::skater, "s3cam_ray {}", report);
    return report;
}
}
