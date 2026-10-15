#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/manager.rs (CameraMan::prepare / update order), manager_state.rs
// (update_air, update_incline), manager_subject.rs, manager_rig.rs (bind_shot: shot -> rig),
// manager_blends.rs, manager_frame.rs (lens_field_of_view), manager_output.rs (finish_frame: shake
// after orientation), frame_composer.rs (reference point framing, maximum pitch, roll response),
// rig_orientation.rs (pan/tilt trackers, smoothing derived from the shot) and shot_manager.rs
// (transition: previous = interpolated at the change, eased by elapsed / duration). Semantics are
// ported; the bit-exact VMX constants and quaternion round trips are replaced by ordinary float
// arithmetic (CLAUDE.md hard rule 6). Deviations from the Rust are listed in docs/s3cam/GATE1_NOTES.md.
#include "Engine/Game/Camera/s3_air.h"
#include "Engine/Game/Camera/s3_graph.h"
#include "Engine/Game/Camera/s3_math.h"
#include "Engine/Game/Camera/s3_rig.h"
#include "Engine/Game/Camera/s3_settings.h"
#include "Engine/Game/Camera/s3_shake.h"
#include "Engine/Game/Camera/s3_shot.h"
#include "Engine/Game/Camera/s3_subject.h"
#include "Engine/Game/Camera/s3_tracker.h"
#include "Engine/Game/Camera/s3_trajectory.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <optional>
#include <string_view>

// CameraMan (card T6): turns a SubjectSnapshot stream into a camera Frame. Pure and header-only, no
// heap allocation, update() is noexcept.
//
// Order of operations per FIXED step (CLAUDE.md hard rule 4):
//   prepare (air / landing, then incline) -> graph select -> shot blend -> rig -> orientation and
//   framing -> shake -> write.
// Alpha 2 layers inside those stages (FullS3 unless noted): fov extras after the shot blend (both presets), follow
// strength k around the rig, look layers (landing look, slope look, vertical follow) building the look target,
// shoulder shift of the camera (both presets), collision after the shoulder, speed shake rebuilding the shake
// settings before shake.update (both presets).
// Alpha 3 layers: the framing (distance / height scale on every shot, the manual close-up) is applied where the
// shot is resolved, so shot blends and settings changes ease it (FullS3; the pitch offset also in NativePlus); the
// trick yaw swings the rig heading round to the side during airs / grinds / manuals (FullS3).
// update() takes the real frame dt, runs as many fixed 1/60 s steps (s3_math.h fixed_step, the Rust
// camera STEP) as the accumulator holds (CLAUDE.md hard rule 5; the subject is interpolated between
// the previous and current snapshot across them) and returns the pose interpolated between the last two steps. Trackers, blends and shake never
// see the frame dt.
//
// Conventions: world is Y up. Heading 0 looks down +Z and grows toward -X (heading = atan2(-x, z)).
// Frame rows are right, up, back, position with right x up = +back (handedness +1, measured in game
// by the Gate 0 probe), so the camera looks along -back. Roll > 0 turns right toward up.
namespace dingosdk::s3cam {

// The game's own camera pose (NativePlus input), same row convention as Frame.
struct NativePose {
    Vec3 right{1, 0, 0};
    Vec3 up{0, 1, 0};
    Vec3 back{0, 0, 1};
    Vec3 position{0, 0, 0};
    float fov_deg = 0.0f; // > 0: the base fov unless FrameExtras::base_fov_deg or fov_override_deg is set
};

struct FrameExtras {
    float aspect = 16.0f / 9.0f;       // width / height; a non-finite or non-positive value keeps the last good one
    const NativePose* native = nullptr; // required each update in NativePlus, ignored in FullS3
    // The game camera's own vertical FOV in degrees; 0 (or non-finite) = unknown. The caller supplies a
    // SMOOTH value: CameraMan adds its eased extra terms on top and never smooths the base itself.
    float base_fov_deg = 0.0f;
};

struct FrameDebug {
    std::string_view shot_name{"chase"};
    bool reset = false;        // this frame is a cut (spawn, teleport, preset change, resume after a long gap)
    bool held = false;         // the input was unusable; the previous frame is returned unchanged
    CameraPreset preset = CameraPreset::FullS3;
    int steps = 0;             // fixed steps run by this update
    float accumulator = 0.0f;  // s left over after those steps
    bool airborne = false;
    bool landing_active = false;
    bool transitioning = false;
    float shot_fraction = 1.0f;       // 0..1 progress of the current shot transition
    float chase_blend = 0.0f;         // slow -> fast blend value
    bool prediction_valid = false;    // the last trajectory prediction landed
    float predicted_max_height = 0.0f; // m above takeoff
    float predicted_air_time = 0.0f;   // s, takeoff to landing
    float predicted_landing_delta = 0.0f; // m, landing surface minus takeoff surface
    float air_hold_delta = 0.0f;       // m, held reference height minus the actual anchor height (<= 0 while rising)
    float anchor_lag = 0.0f;           // m
    float heading = 0.0f, elevation = 0.0f, distance = 0.0f; // rig, radians / metres (elevation includes the big-air rise)
    float impulse = 0.0f;              // shake landing impulse
    float landing_dip = 0.0f;          // m below the native pose (NativePlus)
    float speed = 0.0f;                // m/s, |velocity . forward| on the ground; held at the last grounded value in the air
    float incline_degrees = 0.0f;
    float forward_acceleration = 0.0f; // m/s^2, filtered; feeds pump / push
    bool push_state = false;
    bool push_kick = false;
    // Alpha 2 layers (docs/s3cam/PHASE2.md).
    float fov_base = 0.0f;             // deg, the base the extras ride on (override, else base_fov_deg, else the native / chase lens)
    float fov_extra = 0.0f;            // deg, the eased shot + speed + air terms
    float landing_look_weight = 0.0f;  // 0..1, how far the look target has moved toward the predicted landing
    float look_pitch_offset = 0.0f;    // rad, the eased slope look added to the pitch
    float shoulder = 0.0f;             // m, signed sideways offset applied to the camera (+ = along the camera's right)
    float follow_strength = 1.0f;      // k after the dynamic boost and the [0.2, 7] clamp
    float collision_pull = 0.0f;       // m the camera was pulled in toward the look target
    // Alpha 3.
    float trick_yaw = 0.0f;            // rad, the camera's swing round the skater (+ = toward the skater's right; FullS3)
    // Alpha 4.
    float air_follow_weight = 0.0f;    // 0..1, the eased "in the air" weight that scales air_camera.follow_height
    float air_reference_height = 0.0f; // m, the reference height after follow_height (what the rig / hold uses)
    float air_rise = 0.0f;             // rad, the eased extra elevation of the big-air rise
    float keep_pitch_offset = 0.0f;    // rad, the keep-in-frame pitch added to the view (+ looks up)
    float focus_weight = 1.0f;         // 0..1, how far the look target sits from the board toward the usual point (manual / grind focus)
    Vec3 look_target{0, 0, 0};         // FullS3: the point the view aims at, after the focus and the look layers
};

struct Frame {
    Vec3 right{1, 0, 0};
    Vec3 up{0, 1, 0};
    Vec3 back{0, 0, 1};
    Vec3 pos{0, 0, 0};
    float fov_deg = 0.0f;
    ShotId shot = ShotId::Chase;
    FrameDebug debug;
    bool valid = false; // false until the first usable snapshot has produced a pose
};

// manager_frame.rs lens_field_of_view: the angle subtended by a 35 mm frame at `lens` mm, in
// degrees, scaled by 1 / sqrt(aspect + 1). Non-finite or non-positive input gives 0.
inline float lens_field_of_view_degrees(float lens_length, float aspect) noexcept {
    if (!std::isfinite(lens_length) || !std::isfinite(aspect) || !(lens_length > 0.0f) || !(aspect > 0.0f)) return 0.0f;
    const float degrees_full = std::atan(35.0f / (lens_length * 2.0f)) * (2.0f * 180.0f / pi);
    return std::sqrt(degrees_full * degrees_full / (aspect + 1.0f));
}

namespace camera_detail {
inline bool finite3(const Vec3& v) noexcept { return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]); }
inline Vec3 rotate_about(const Vec3& v, const Vec3& axis, float angle) noexcept {
    const float c = std::cos(angle), s = std::sin(angle);
    return add(add(scale(v, c), scale(cross(axis, v), s)), scale(axis, dot(axis, v) * (1.0f - c)));
}
// Right-handed orthonormal rows with right x up = back, from loosely orthogonal input.
inline void orthonormalize(Vec3& right, Vec3& up, Vec3& back) noexcept {
    right = normalized(right, {1, 0, 0});
    Vec3 u = sub(up, scale(right, dot(up, right)));
    if (length(u) < 1e-4f) { // up parallel to right: pick any perpendicular
        u = std::abs(right[1]) < 0.9f ? Vec3{0, 1, 0} : Vec3{0, 0, 1};
        u = sub(u, scale(right, dot(u, right)));
    }
    up = normalized(u, {0, 1, 0});
    back = cross(right, up);
}
// Rows for a camera looking along (yaw, pitch) with roll about the view axis. Positive pitch looks up.
inline void basis_from_angles(float yaw, float pitch, float roll, Vec3& right, Vec3& up, Vec3& back) noexcept {
    const float limit = 89.0f * degrees;
    const float p = std::clamp(pitch, -limit, limit);
    const float cp = std::cos(p);
    const Vec3 look{-std::sin(yaw) * cp, std::sin(p), std::cos(yaw) * cp};
    back = scale(look, -1.0f);
    right = normalized(cross({0, 1, 0}, back), {1, 0, 0});
    up = cross(back, right);
    const float c = std::cos(roll), s = std::sin(roll);
    const Vec3 r = add(scale(right, c), scale(up, s));
    const Vec3 u = sub(scale(up, c), scale(right, s));
    right = r;
    up = u;
}
inline float lerp_f(float a, float b, float t) noexcept { return a + (b - a) * t; }
// Per-step share of the gap an exponential filter with `time_constant` closes (0 = take it all).
// The floor keeps the division visibly non-zero for MSVC's C4723 on inlined paths.
inline float ease_rate(float time_constant, float step_time) noexcept {
    return time_constant > 0.0f ? 1.0f - std::exp(-step_time / std::max(time_constant, 1e-6f)) : 1.0f;
}
inline float ease_to(float value, float target, float time_constant, float step_time) noexcept {
    return value + (target - value) * ease_rate(time_constant, step_time);
}
} // namespace camera_detail

class CameraMan {
public:
    // Replaces the settings. Invalid settings are rejected (returns false, old ones kept). Changing
    // the preset cuts the camera on the next update; changing the angle blends through a shot transition.
    bool set_settings(const CameraSettings& settings) noexcept {
        if (!settings.valid()) return false;
        settings_ = settings;
        return true;
    }
    const CameraSettings& settings() const noexcept { return settings_; }

    // Cut on the next update: spawn, teleport, respawn after a bail, taking ownership.
    void request_reset() noexcept { reset_requested_ = true; }

    const Frame& frame() const noexcept { return frame_; }

    // One rendered frame. `dt` is the real frame time in seconds; `ground` is the world query the
    // trajectory prediction rays through (segment start, end -> optional GroundHit, see s3_trajectory.h).
    // Returns the new frame, or the previous one with debug.held set when `dt`, the snapshot or (in
    // NativePlus) the native pose is unusable, or when the skater is off the board and not bailing.
    template <GroundQuery Query>
    const Frame& update(float dt, const SubjectSnapshot& subject, Query&& ground, const FrameExtras& extras = {}) noexcept {
        const bool native_mode = settings_.preset == CameraPreset::NativePlus;
        const bool dt_ok = std::isfinite(dt) && dt >= 0.0f;
        const bool native_ok = !native_mode || (extras.native != nullptr && native_usable(*extras.native));
        if (!dt_ok || !native_ok || !usable(subject) || (!subject.onboard && !subject.bailing)) {
            if (dt_ok) invalid_time_ += dt;
            return hold();
        }
        if (std::isfinite(extras.aspect) && extras.aspect > 0.0f) aspect_ = extras.aspect;
        if (native_mode) native_distance_ = length(sub(extras.native->position, subject.position));
        // What the steps need of the extras: the keep-in-frame layer reads the lens (fov_base_deg) and the native pose.
        extras_base_fov_ = extras.base_fov_deg;
        native_fov_ = native_mode ? extras.native->fov_deg : 0.0f;
        if (native_mode) native_pose_ = *extras.native;

        const PipelineSettings& pipe = settings_.pipeline;
        const bool cut = reset_requested_ || !initialized_ || last_preset_ != settings_.preset ||
                         invalid_time_ > pipe.resume_reset_time ||
                         length(sub(subject.position, cur_snap_.position)) > pipe.teleport_distance;
        invalid_time_ = 0.0f;

        FrameDebug dbg;
        kick_in_update_ = false;
        if (cut) {
            reset_requested_ = false;
            initialized_ = true;
            last_preset_ = settings_.preset;
            cut_to(subject, ground);
            dbg.reset = true;
        } else {
            const float step = fixed_step;
            const float carry = acc_;
            // Clamp BEFORE the int cast: a huge dt would overflow it (undefined) and freeze the camera.
            const float limit = static_cast<float>(pipe.max_steps_per_update + 1) * step;
            const bool capped = carry + dt >= limit; // a long stall: the steps are capped below
            acc_ = std::min(carry + dt, limit);
            int steps = static_cast<int>(std::floor(acc_ / step));
            if (steps > pipe.max_steps_per_update) { // drop the surplus rather than spiral
                const float fraction = std::max(0.0f, acc_ - static_cast<float>(steps) * step);
                steps = pipe.max_steps_per_update;
                acc_ = static_cast<float>(steps) * step + fraction;
            }
            for (int i = 1; i <= steps; ++i) {
                // Where in this frame's interval the step lands: the sim clock lags the snapshot clock
                // by the accumulator carried in, so the subject is interpolated, never extrapolated.
                // When the cap dropped steps the survivors cover (0, 1] evenly instead of stopping short.
                const float f = capped ? static_cast<float>(i) / static_cast<float>(steps)
                                       : dt > 0.0f ? clamp01((static_cast<float>(i) * step - carry) / std::max(dt, 1e-9f)) : 1.0f;
                const SubjectSnapshot sub_snap = blend_snapshot(cur_snap_, subject, f);
                step_once(sub_snap, ground, false);
            }
            acc_ -= static_cast<float>(steps) * step;
            if (acc_ < 0.0f) acc_ = 0.0f;
            dbg.steps = steps;
            cur_snap_ = subject;
        }
        dbg.accumulator = acc_;
        publish(dbg, extras);
        return frame_;
    }

private:
    // One fixed step's result. FullS3: the absolute camera pose, shake included. NativePlus: offsets to
    // lay over the native pose (world position offset, angle deltas, camera-local shake translation).
    struct StepOut {
        Vec3 pos{0, 0, 0};
        float yaw = 0.0f, pitch = 0.0f, roll = 0.0f;
        Vec3 local{0, 0, 0};
        float fov_extra = 0.0f; // deg, added to the base fov at publish
        float shoulder = 0.0f;  // m along the camera's right. Already folded into `pos` in FullS3; NativePlus adds it at publish
        bool finite() const noexcept {
            return camera_detail::finite3(pos) && camera_detail::finite3(local) && std::isfinite(yaw) && std::isfinite(pitch) &&
                   std::isfinite(roll) && std::isfinite(fov_extra) && std::isfinite(shoulder);
        }
    };

    static bool native_usable(const NativePose& n) noexcept {
        using camera_detail::finite3;
        return finite3(n.right) && finite3(n.up) && finite3(n.back) && finite3(n.position) && std::isfinite(n.fov_deg) &&
               length(n.right) > 1e-4f && length(n.up) > 1e-4f && length(n.back) > 1e-4f;
    }

    const Frame& hold() noexcept {
        frame_.debug.held = true;
        frame_.debug.reset = false;
        frame_.debug.steps = 0;
        return frame_;
    }

    // The snapshot `f` of the way from `a` to `b`. Continuous fields interpolate; discrete ones switch at
    // the midpoint so a state change lands roughly where the position says it happened.
    static SubjectSnapshot blend_snapshot(const SubjectSnapshot& a, const SubjectSnapshot& b, float f) noexcept {
        SubjectSnapshot out = f >= 0.5f ? b : a;
        out.time = camera_detail::lerp_f(a.time, b.time, f);
        out.position = lerp(a.position, b.position, f);
        out.velocity = lerp(a.velocity, b.velocity, f);
        out.forward = normalized(lerp(a.forward, b.forward, f), b.forward);
        out.ground_normal = normalized(lerp(a.ground_normal, b.ground_normal, f), b.ground_normal);
        out.ground_clearance = camera_detail::lerp_f(a.ground_clearance, b.ground_clearance, f);
        out.valid = true;
        return out;
    }

    // The ten reference points (Head, Hips, Grind, COM, Board, Trajectory, Anchor, Feet, DampedCOM,
    // unnamed) from the root position. The snapshot has no skeleton, so these are fixed offsets.
    std::array<Vec3, 10> reference_points(const SubjectSnapshot& s) const noexcept {
        const SubjectPointSettings& p = settings_.points;
        const Vec3 root = s.position;
        const Vec3 board = add(root, {0, -p.board_drop, 0});
        Vec3 trajectory = board;
        if (s.air()) {
            const float t = p.trajectory_lookahead;
            trajectory = add(board, {s.velocity[0] * t, s.velocity[1] * t - 0.5f * settings_.trajectory.gravity * t * t,
                                     s.velocity[2] * t});
        }
        const Vec3 com = add(root, {0, p.com_height, 0});
        return {add(root, {0, p.head_height, 0}), root, board, com, board, trajectory, root, board, com, root};
    }
    // The point the rig orbits (Rust: subject.anchors[shot.anchor], manager.rs bind_anchor). It does not
    // depend on the shot's reference weights, so a shot change cannot move the camera's height; the
    // weighted reference point below only feeds the framing.
    Vec3 anchor_point(const SubjectSnapshot& s) const noexcept {
        const SubjectPointSettings& p = settings_.points;
        return add(s.position, {0.0f, p.anchor_height - p.board_drop, 0.0f});
    }
    // Weighted mean of the reference points (reference_point() in shot.rs); the board if the weights vanish.
    static Vec3 weighted_point(const std::array<Vec3, 10>& points, const Shot& shot) noexcept {
        Vec3 sum{0, 0, 0};
        float total = 0.0f;
        for (std::size_t i = 0; i < points.size(); ++i) {
            const float w = shot.reference_weights[i];
            if (!(w > 0.0f)) continue;
            sum = add(sum, scale(points[i], w));
            total += w;
        }
        return total > 1e-4f ? scale(sum, 1.0f / total) : points[4];
    }

    // Low and High have their own camera position (CameraSettings::framing / framing_high). The angle in use is
    // the one the shots are resolved with (settings_.angle), so a switch blends through the shot transition.
    const FramingSettings& active_framing() const noexcept {
        return settings_.angle == CameraAngle::High ? settings_.framing_high : settings_.framing;
    }

    // The shot with the player's framing applied (FullS3): distance scale and elevation offset on every shot,
    // plus the manual close-up on the two manual shots. NativePlus keeps the game's own distance and height.
    Shot framed(Shot shot, ShotId id, float chase_blend) const noexcept {
        if (settings_.preset == CameraPreset::NativePlus) return shot;
        const FramingSettings& fr = active_framing();
        float elevation_degrees = fr.height_degrees;
        if (fr.manual_camera && (id == ShotId::ManualFar || id == ShotId::ManualClose)) {
            // The manual close-up is relative to the chase distance at this speed (FramingSettings:
            // "relative to the chase"), not to the manual shots' own table distances: the table's
            // close manual (1.1 m) is nearer than the grind shots, which the player found too close.
            shot.distance = blend_shots(lookup_shots(ShotId::Chase, settings_.angle), chase_blend).distance *
                            fr.manual_distance_scale;
            elevation_degrees += fr.manual_height_degrees;
        }
        shot.distance *= fr.distance_scale;
        const float limit = 85.0f * degrees; // short of straight up / down; the rig clamps tighter
        shot.position_elevation = std::clamp(shot.position_elevation + elevation_degrees * degrees, -limit, limit);
        return shot;
    }

    // The slope of the direction of travel along the ground, degrees, + uphill (manager_state.rs update_incline).
    static float incline_of(const SubjectSnapshot& s, const Vec3& normal) noexcept {
        Vec3 along = sub(s.forward, scale(normal, dot(s.forward, normal)));
        if (dot(s.velocity, s.forward) < 0.0f) along = scale(along, -1.0f);
        const float l = length(along);
        if (!(l > 1e-4f)) return 0.0f;
        return std::asin(std::clamp(along[1] / l, -1.0f, 1.0f)) / degrees;
    }

    // Where the look target sits between the board (0) and the shot's usual point (1): manuals and grinds
    // frame the lower body (LookSettings::manual_focus / grind_focus), every other shot is 1.
    float focus_of(ShotId id) const noexcept {
        switch (id) {
        case ShotId::ManualFar:
        case ShotId::ManualClose: return settings_.look.manual_focus;
        case ShotId::GrindFlat:
        case ShotId::GrindLedgeL:
        case ShotId::GrindLedgeR: return settings_.look.grind_focus;
        default: return 1.0f;
        }
    }

    // Pitch of the line camera -> point, radians (+ above the camera). 0 when they coincide.
    static float elevation_to(const Vec3& from_pos, const Vec3& to_pos) noexcept {
        const Vec3 line = sub(to_pos, from_pos);
        const float span = length(line);
        return span > 1e-3f ? std::asin(std::clamp(line[1] / std::max(span, 1e-3f), -1.0f, 1.0f)) : 0.0f;
    }

    // Keep the skater inside the vertical view while airborne (air_camera.keep_in_frame). `view_pitch` is the
    // view's pitch BEFORE this offset; the points are the skater's reference point, root and board. The goal is
    // the pitch that brings a point that is beyond ~70% of the half vertical FOV back to that edge; the offset
    // eases toward it (no snap). A last guard keeps every point within 90% of the half FOV even when the ease
    // is behind (it is a clamp of a continuous quantity, so it never jumps). Returns the offset, radians.
    float update_keep_in_frame(const Vec3& cam_pos, float view_pitch, const std::array<Vec3, 3>& points, bool air, bool snap) noexcept {
        const float half_fov = 0.5f * std::clamp(fov_base_deg() + fov_extra_, 1.0f, 170.0f) * degrees;
        const float soft = 0.7f * half_fov, hard = 0.9f * half_fov;
        const bool active = settings_.air_camera.keep_in_frame && air && !snap;
        float goal_up = 0.0f, goal_down = 0.0f, range_lo = -1.0e3f, range_hi = 1.0e3f;
        for (const Vec3& point : points) {
            const float error = elevation_to(cam_pos, point) - view_pitch; // + the point is above the view axis
            goal_up = std::max(goal_up, error - soft);
            goal_down = std::max(goal_down, -error - soft);
            range_lo = std::max(range_lo, error - hard);
            range_hi = std::min(range_hi, error + hard);
        }
        if (snap) keep_off_ = 0.0f;
        else keep_off_ = camera_detail::ease_to(keep_off_, active ? goal_up - goal_down : 0.0f, keep_response_time, fixed_step);
        if (active) {
            // range_lo > range_hi: the points cannot all fit, aim between the limits. Only while the layer is
            // active: after the landing the offset just eases out (a clamp would pin it).
            keep_off_ = range_lo <= range_hi ? std::clamp(keep_off_, range_lo, range_hi) : 0.5f * (range_lo + range_hi);
        }
        return keep_off_;
    }

    // The trick-yaw state machine (one fixed step). Tricking = airborne for min_air_time, grinding or in a
    // manual, each only if its switch is on. The target is angle * side while tricking and for hold_time
    // after the last trick step (a new trick inside it keeps the angle, there is no dip), then 0. Out uses
    // in_time, back uses return_time; both are sine eases, so the angular velocity starts at 0. A bail is
    // not a trick and cancels the hold. Disabled eases back to 0; a cut snaps to 0.
    void update_trick_yaw(const SubjectSnapshot& s, bool snap, float dt) noexcept {
        const TrickYawSettings& ty = settings_.trick_yaw;
        TrickYawState& st = trick_yaw_;
        if (snap) {
            st = TrickYawState{};
            return;
        }
        const bool tricking = ty.enabled && !s.bailing &&
                              ((ty.in_air && s.air() && air_time_ >= ty.min_air_time) || (ty.on_grinds && s.grinding()) ||
                               (ty.on_manuals && s.manual));
        float goal = 0.0f;
        if (tricking) {
            // Same rule as the shoulder's Auto side: +1 regular (toes to the right), -1 goofy XOR switch.
            int side = ty.side;
            if (side == 0)
                side = settings_.shoulder.mode == ShoulderSide::Manual ? settings_.shoulder.side
                                                                       : ((settings_.shoulder.goofy != s.switch_stance) ? -1 : 1);
            st.hold_left = ty.hold_time;
            goal = ty.angle_degrees * degrees * static_cast<float>(side);
        } else {
            st.hold_left = (ty.enabled && !s.bailing) ? std::max(0.0f, st.hold_left - dt) : 0.0f;
            goal = st.hold_left > 0.0f ? st.target : 0.0f;
        }
        if (goal != st.target) { // retarget: ease from wherever the value is now
            st.start = st.value;
            st.target = goal;
            st.elapsed = 0.0f;
            st.duration = goal == 0.0f ? ty.return_time : ty.in_time;
        }
        st.elapsed += dt;
        const float fraction = st.duration > 1e-4f ? clamp01(st.elapsed / std::max(st.duration, 1e-4f)) : 1.0f;
        st.value = st.start + (st.target - st.start) * sine_blend(fraction);
    }

    // Camera cut: every tracker lands on this frame's targets with zero velocity, shake and dip clear.
    template <class Query>
    void cut_to(const SubjectSnapshot& s, Query& ground) noexcept {
        cur_snap_ = s;
        acc_ = 0.0f;
        graph_.reset();
        shake_.reset();
        dip_x_ = dip_v_ = 0.0f;
        accel_ready_ = false;
        accel_filtered_ = prev_accel_ = 0.0f;
        push_timer_ = 0.0f;
        was_air_ = false;
        air_time_ = 0.0f;
        prediction_ = {};
        // Layers: the FOV extras and look offsets restart from 0 and ease in (the handover from the game
        // camera must not pop); the shoulder side and the collision state land on this frame's targets.
        fov_extra_ = landing_w_ = look_pitch_ = native_pitch_ = 0.0f;
        air_w_ = rise_w_ = keep_off_ = framing_pitch_ = last_shake_pitch_ = 0.0f;
        coll_pull_ = coll_lift_ = 0.0f;
        trick_yaw_ = TrickYawState{};
        layers_ = {};
        no_lag_timer_ = settings_.pipeline.no_lag_after_reset;
        step_once(s, ground, true);
        prev_out_ = curr_out_;
    }

    template <class Query>
    void step_once(const SubjectSnapshot& s, Query& ground, bool snap) noexcept {
        using camera_detail::finite3;
        const CameraSettings& cs = settings_;
        const float dt = fixed_step;
        const bool native = cs.preset == CameraPreset::NativePlus;
        const bool air = s.air();
        const bool grounded = !air;
        const Vec3 up_world{0, 1, 0};
        const Vec3 normal = normalized(s.ground_normal, up_world);
        const float clearance_now = std::clamp(s.ground_clearance, 0.0f, 3.0f);
        const float forward_speed = dot(s.velocity, normalized(s.forward, {0, 0, 1}));
        const float horizontal_speed = length({s.velocity[0], 0.0f, s.velocity[2]});
        // The camera speed (graph blend, debug): |velocity . forward| on the ground. In the air the entity
        // forward spins through flips and 360s, which would swing a forward-projected speed between +v and
        // -v, so the last grounded value is held. A cut in mid-air has none yet and seeds the horizontal speed.
        if (grounded) held_speed_ = std::abs(forward_speed);
        else if (snap) held_speed_ = horizontal_speed;
        const float speed = held_speed_;

        if (snap) {
            // A cut has no previous shot, but the framing below needs this frame's shot: resolve the
            // one the graph would pick first.
            graph_.reset();
            const GraphOutput first = graph_.select(graph_input(s, dt, false, 0.0f, speed, normal), cs.graph);
            graph_.reset();
            angle_ = cs.angle;
            id_ = first.shot;
            shots_ = lookup_shots(id_, angle_);
            leaf_ = framed(blend_shots(shots_, first.chase_blend), first.shot, first.chase_blend);
            current_ = from_ = leaf_;
        }
        const std::array<Vec3, 10> points = reference_points(s);
        const Vec3 anchor_pt = anchor_point(s);

        // ---- forward acceleration -> pump / push (decision 2)
        // Grounded only: the in-air forward vector spins with the trick, so its projection is not a speed. The
        // first grounded step after the air re-seeds the previous value, so landing is not an acceleration spike.
        if (!accel_ready_) {
            prev_forward_speed_ = forward_speed;
            accel_filtered_ = prev_accel_ = 0.0f;
            accel_ready_ = true;
        } else if (grounded && was_air_) {
            prev_forward_speed_ = forward_speed;
        }
        const float raw_accel = grounded ? (forward_speed - prev_forward_speed_) / dt : 0.0f;
        if (grounded) prev_forward_speed_ = forward_speed;
        const float smoothing_time = cs.pipeline.accel_smoothing_time;
        const float blend = smoothing_time > 0.0f ? 1.0f - std::exp(-dt / std::max(smoothing_time, 1e-6f)) : 1.0f;
        accel_filtered_ += (raw_accel - accel_filtered_) * blend;
        const bool push_kick = grounded && !s.grinding() && prev_accel_ < cs.pipeline.push_accel_threshold &&
                               accel_filtered_ >= cs.pipeline.push_accel_threshold;
        prev_accel_ = accel_filtered_;
        push_timer_ = push_kick ? cs.pipeline.push_window : std::max(0.0f, push_timer_ - dt);
        const bool push_state = push_timer_ > 0.0f;
        if (!snap) no_lag_timer_ = std::max(0.0f, no_lag_timer_ - dt);
        const bool no_lag = s.bailing || no_lag_timer_ > 0.0f;

        // ---- prepare 1: air / landing (CLAUDE.md hard rule 4: before the incline)
        if (grounded) {
            last_clearance_ = clearance_now;
            last_ground_normal_ = normal;
        } else if (snap) {
            last_clearance_ = clearance_now; // reset mid-air: the surface under the skater is the datum
            last_ground_normal_ = normal;
        }
        const bool entered_air = air && (!was_air_ || snap);
        if (entered_air) {
            air_time_ = 0.0f;
            flight_max_height_ = 0.0f;
            takeoff_surface_y_ = s.position[1] - last_clearance_;
            repredict_timer_ = 0.0f;
            predict(s, ground);
        } else if (air) {
            air_time_ += dt;
            repredict_timer_ += dt;
            if (cs.pipeline.repredict_interval > 0.0f && repredict_timer_ >= cs.pipeline.repredict_interval) {
                repredict_timer_ = 0.0f;
                predict(s, ground);
            }
        }
        const bool touchdown = !snap && was_air_ && grounded && air_time_ >= cs.graph.landing_min_air_time;

        AirInput air_in;
        air_in.grounded = grounded;
        air_in.set_prediction(prediction_, prediction_offset_);
        if (air_in.trajectory_valid) air_in.trajectory_duration += prediction_time_base_;
        air_in.trajectory_time = air_time_;
        air_in.velocity = s.velocity;
        air_in.ground_normal = normal;
        air_in.anchor_height = anchor_pt[1];
        air_in.follow_anchor_in_air = current_.follow_subject_in_air;
        air_in.snap_height = snap;
        if (snap) air_.reset(anchor_pt[1], grounded);
        const AirOutput air_out = air_.update(dt, air_in, cs.air);
        if (air_out.landing) {
            shake_.landing_impulse(air_out.landing->normal, air_out.landing->velocity, cs.shake);
            kick_dip(air_out.landing->normal, air_out.landing->velocity);
        }
        // ---- prepare 2: incline (after the landing response has read the previous normal)
        incline_degrees_ = incline_of(s, normal);

        // ---- graph select
        // The apex is latched over the flight: after the apex a re-prediction reports the current
        // height as its apex, which would flip Big back to Normal on the way down.
        if (air && prediction_.status != TrajectoryStatus::Invalid)
            flight_max_height_ = std::max(flight_max_height_, prediction_.predicted_max_height + prediction_offset_);
        const float max_height = air ? flight_max_height_ : 0.0f;
        const GraphOutput pick = graph_.select(graph_input(s, dt, touchdown, max_height, speed, normal), cs.graph);

        // ---- air camera (Alpha 4, both presets). air_w_ is the eased "in the air" weight, so the height
        // follow starts and ends smoothly. The reference height blends from the held one toward the live
        // anchor: ref = held + follow_height * air_w * (anchor - held); follow_height 0 leaves it untouched.
        // The rise is up to rise_degrees of extra elevation, scaled by how big the air is (the higher of the
        // predicted apex above the takeoff and the predicted drop below it); it eases in and, after the
        // landing, back out with the same time.
        const AirCameraSettings& ac = cs.air_camera;
        float rise_goal = 0.0f;
        if (air && ac.rise_degrees > 0.0f) {
            const float drop_below = prediction_.landed() ? -(prediction_.predicted_landing_height + prediction_offset_) : 0.0f;
            rise_goal = clamp01(std::max(flight_max_height_, drop_below) / std::max(ac.rise_full_height, 0.1f));
        }
        if (!snap) {
            air_w_ = camera_detail::ease_to(air_w_, air ? 1.0f : 0.0f, ac.ease_time, dt);
            rise_w_ = camera_detail::ease_to(rise_w_, rise_goal, ac.ease_time, dt);
        }
        const float rise_rad = rise_w_ * ac.rise_degrees * degrees;
        // The keep-in-frame layer stays on while the air weight is still easing out: the camera is still
        // settling after a landing (a low camera can have the board below the view for a few frames).
        const bool in_air_layer = air || air_w_ > 0.02f;
        // The published frame is up to a step behind the skater (the pose is interpolated between steps), so the
        // keep-in-frame layer looks 1.5 steps ahead along his velocity.
        const Vec3 keep_lead = scale(s.velocity, 1.5f * dt);
        const float held_ref = air_out.reference_height;
        const float ref_y = held_ref + ac.follow_height * air_w_ * (anchor_pt[1] - held_ref);

        // ---- shot blend (shot_manager.rs: previous = interpolated at the change, eased by elapsed/duration)
        const bool changed = snap || pick.shot != id_ || cs.angle != angle_;
        if (changed) shots_ = lookup_shots(pick.shot, cs.angle); // cached until the selection changes
        // The player's framing is part of the resolved shot, every step: a shot change blends old -> new with it
        // baked into both, and a settings change moves only the target, which the rig's distance / elevation
        // trackers then ease (nothing snaps).
        leaf_ = framed(blend_shots(shots_, pick.chase_blend), pick.shot, pick.chase_blend);
        if (changed) {
            chase_lens_ = resolve_shot(ShotId::Chase, cs.angle, 0.0f).lens_length; // the fov shot term's zero
            from_ = snap ? leaf_ : current_;
            shot_elapsed_ = 0.0f;
            shot_duration_ = snap ? 0.0f : cs.graph.transition_time[static_cast<std::size_t>(pick.shot)];
            id_ = pick.shot;
            angle_ = cs.angle;
        }
        shot_elapsed_ += dt;
        shot_fraction_ = shot_duration_ <= 0.0f ? 1.0f : clamp01(shot_elapsed_ / std::max(shot_duration_, 1e-6f));
        current_ = interpolate(from_, leaf_, shot_fraction_);
        current_.position_heading = blend_angle(from_.position_heading, leaf_.position_heading, sine_blend(shot_fraction_));
        const Vec3 reference_now = weighted_point(points, current_); // the blended weights: framing only

        // Manual / grind focus: eased with the shot transition (from the value at the change to the new
        // shot's), then with the look response time if a setting moves. Every other shot is 1.
        const float focus_goal = focus_of(pick.shot);
        if (snap) {
            focus_value_ = focus_from_ = focus_goal;
        } else {
            if (changed) focus_from_ = focus_value_;
            focus_value_ = shot_fraction_ < 1.0f ? camera_detail::lerp_f(focus_from_, focus_goal, sine_blend(shot_fraction_))
                                                 : camera_detail::ease_to(focus_value_, focus_goal, cs.look.response_time, dt);
        }

        // ---- FOV extras (both presets): shot, speed and air terms, eased by one exponential filter.
        // The base (override / game / lens) is added at publish and is never smoothed here. A cut starts
        // the extras at 0 and eases them in.
        const FovSettings& fv = cs.fov;
        float fov_target = 0.0f;
        if (fv.shot_fov)
            fov_target += lens_field_of_view_degrees(current_.lens_length, aspect_) - lens_field_of_view_degrees(chase_lens_, aspect_);
        if (fv.speed_fov)
            fov_target += fv.speed_fov_degrees * clamp01((horizontal_speed - fv.speed_fov_min) / std::max(fv.speed_fov_max - fv.speed_fov_min, 1e-3f));
        if (fv.air_fov && air)
            fov_target += fv.air_fov_degrees * clamp01(flight_max_height_ / std::max(fv.air_fov_full_height, 1e-3f));
        if (!snap) fov_extra_ = camera_detail::ease_to(fov_extra_, fov_target, fv.smoothing_time, dt);

        // ---- shoulder side (both presets): a sine ease over switch_time from wherever the side value is
        // now, so a change of mind mid-slide starts from the current value (position stays continuous).
        const ShoulderSettings& sh_set = cs.shoulder;
        float side_target = 0.0f;
        if (sh_set.mode == ShoulderSide::Manual) side_target = static_cast<float>(sh_set.side);
        else if (sh_set.mode == ShoulderSide::Auto) side_target = (sh_set.goofy != s.switch_stance) ? -1.0f : 1.0f;
        if (snap) {
            shoulder_value_ = shoulder_start_ = shoulder_target_ = side_target;
            shoulder_elapsed_ = sh_set.switch_time;
        } else {
            if (side_target != shoulder_target_) {
                shoulder_start_ = shoulder_value_;
                shoulder_target_ = side_target;
                shoulder_elapsed_ = 0.0f;
            }
            shoulder_elapsed_ += dt;
            const float slide = sh_set.switch_time > 1e-4f ? clamp01(shoulder_elapsed_ / std::max(sh_set.switch_time, 1e-4f)) : 1.0f;
            shoulder_value_ = shoulder_start_ + (shoulder_target_ - shoulder_start_) * sine_blend(slide);
        }
        const float shoulder_metres = shoulder_value_ * sh_set.offset;

        // ---- rig (FullS3) / native layers (NativePlus), orientation and framing
        StepOut out;
        RigOutput rig_out;
        float shake_distance = native_distance_;
        const float roll_step = std::min(1.0f, cs.orientation.roll_response * dt);
        float follow_k = 1.0f;
        if (!native) {
            // Follow strength: k scales the shot's smoothing (s -> s^k, k > 1 tighter) and shortens the
            // anchor lag (below). Boosted with speed when follow.dynamic.
            const FollowSettings& fo = cs.follow;
            follow_k = std::clamp(fo.strength + (fo.dynamic ? fo.dynamic_boost * clamp01(horizontal_speed / std::max(fo.dynamic_speed, 0.5f)) : 0.0f),
                                  0.2f, 7.0f);
            const auto follow_smoothing = [follow_k](float shot_smoothing) { return std::pow(clamp01(shot_smoothing), follow_k); };

            RigInput ri;
            ri.anchor.position = anchor_pt;
            ri.anchor.reference_height = ref_y;
            ri.anchor.velocity = s.velocity;
            ri.anchor.push_state = push_state;
            ri.anchor.push_kick = push_kick;
            ri.anchor.pump_acceleration = accel_filtered_;
            ri.anchor.no_lag = no_lag;
            ri.compass.position = s.position;
            ri.compass.forward = s.forward;
            const Vec3 flat_velocity{s.velocity[0], 0.0f, s.velocity[2]};
            ri.compass.grind_direction = horizontal_speed > 0.5f ? normalized(flat_velocity, s.forward) : s.forward;
            ri.compass.grinding = s.grinding();
            ri.compass.wiping_out = s.bailing;
            ri.compass.crouching = s.physics_state == physics_state::crouch;
            ri.heading_from_compass = true;
            ri.shot_heading = current_.position_heading;
            ri.heading_smoothing = follow_smoothing(current_.smoothing[0]);   // manager_rig.rs bind_shot: direction smoothing
            ri.elevation_target = current_.position_elevation;
            ri.elevation_smoothing = follow_smoothing(current_.smoothing[1]); // and elevation smoothing
            ri.distance.target = current_.distance;
            ri.distance.fast = air || pick.landing_active || s.bailing; // TUNE: the fast set where the view must keep up
            ri.distance.wipeout = s.bailing;
            ri.distance.snap = snap;
            if (snap) rig_.reset(ri, cs.rig);
            rig_out = rig_.update(dt, ri, cs.rig);

            // Anchor lag / follow_k, on the OUTPUT only: the rig's own tracker (its latch timers, velocity
            // and position) runs untouched, so nothing feeds back and k can change every step without a
            // kink. Only X and Z are scaled: the Y of the rig anchor is the air-held reference height, and
            // shrinking that "lag" would make the camera chase the board up in a jump.
            const float follow_inverse = 1.0f / std::max(follow_k, 0.2f);
            rig_out.anchor[0] = anchor_pt[0] + (rig_out.anchor[0] - anchor_pt[0]) * follow_inverse;
            rig_out.anchor[2] = anchor_pt[2] + (rig_out.anchor[2] - anchor_pt[2]) * follow_inverse;
            rig_out.anchor_lag = length(sub({anchor_pt[0], ref_y, anchor_pt[2]}, rig_out.anchor));

            // Trick yaw: orbit the anchor by the swing angle. The heading grows toward -X and the skater's right
            // is -X when the camera looks along +Z, so swinging to the skater's right DEcreases the heading.
            // The pan tracker below keeps the view aimed at the skater.
            update_trick_yaw(s, snap, dt);
            const float heading_used = rig_out.heading - trick_yaw_.value;
            // The big-air rise rides on the rig's tracked elevation (not its target): the elevation tracker is slow
            // (it takes seconds to move a few degrees), so a rise fed through it would hardly show in an air.
            const float elevation_used = std::clamp(rig_out.elevation + rise_rad, -85.0f * degrees, 85.0f * degrees);
            last_elevation_used_ = elevation_used;
            const float cos_e = std::cos(elevation_used), sin_e = std::sin(elevation_used);
            const Vec3 offset_dir{-std::sin(heading_used), 0.0f, std::cos(heading_used)};
            Vec3 camera = add(rig_out.anchor, add(scale(offset_dir, rig_out.distance * cos_e), {0, rig_out.distance * sin_e, 0}));
            // Only while the ground under the skater is measured: clearance_now is clamped to 3 m, so in a
            // higher air the floor would sit above the real ground and hold the camera up (hiding the rise).
            // The collision layer's own ground ray covers the camera there.
            if (cs.pipeline.floor_clearance > 0.0f && s.ground_clearance < 3.0f)
                camera[1] = std::max(camera[1], s.position[1] - clearance_now + cs.pipeline.floor_clearance);

            // ---- look target. The shot's board_offset lifts the base above the weighted point (Rust: along
            // the subject's board-offset direction, here world up): the Low camera sits near the board and
            // looks up at the skater. `look_base` is where the skater is; the layers below bend the point
            // the VIEW aims at, but the collision pivot stays on the skater (a camera that looks down at a
            // landing must not be pulled in by the ledge it jumps off).
            const Vec3 look_base = add(reference_now, {0.0f, current_.board_offset, 0.0f});

            // a) landing look: while a prediction says the landing is below the takeoff surface (same datum
            // as debug.predicted_landing_delta), the target moves toward where the BOARD will touch down.
            // The root rests last_clearance_ above the surface and the board hangs board_drop below it, so the
            // aim point is the landing surface point + (last_clearance_ - board_drop): it matches the
            // look_base convention (the board region), so a same-level landing would aim at the same spot.
            // The weight eases with look.response_time, and the point is held when the prediction ends, so
            // a re-prediction that misses fades the look out instead of jerking it.
            const LookSettings& lk = cs.look;
            const bool landing_known = air && prediction_.landed();
            float landing_goal = 0.0f;
            if (landing_known) {
                landing_point_ = add(prediction_.landing_position, {0.0f, last_clearance_ - cs.points.board_drop, 0.0f});
                const float drop = prediction_.predicted_landing_height + prediction_offset_;
                if (lk.landing_look && drop < 0.0f)
                    landing_goal = lk.landing_look_strength * clamp01(-drop / std::max(lk.landing_look_full_drop, 0.1f));
            }
            // b) slope look: on the ground the pitch follows the incline (+ uphill, so downhill looks down).
            const float slope_goal = (lk.slope_look && grounded) ? lk.slope_look_strength * incline_degrees_ * degrees : 0.0f;
            if (!snap) {
                landing_w_ = camera_detail::ease_to(landing_w_, landing_goal, lk.response_time, dt);
                look_pitch_ = camera_detail::ease_to(look_pitch_, slope_goal, lk.response_time, dt);
            }
            const Vec3 focused_base = focus_value_ >= 1.0f ? look_base : lerp(points[4], look_base, focus_value_);
            Vec3 look_target = lerp(focused_base, landing_point_, landing_w_);
            // c) vertical follow: 1 = the pitch follows the skater's height, 0 = it stays level with the
            // air-held reference height (applied last, so it also limits the landing look's vertical part).
            const float held_y = ref_y;
            look_target[1] = held_y + lk.vertical_follow * (look_target[1] - held_y);

            // ---- shoulder: slide the camera along its own right. The yaw is the camera's current one (the
            // pan tracker before this step's update; on a cut, the yaw it is about to snap to), so the
            // shift is along the right of the final camera basis to within one step of pan motion.
            const Vec3 to_pre = sub(look_target, camera);
            float yaw_pre = pan_.position();
            if (to_pre[0] * to_pre[0] + to_pre[2] * to_pre[2] > 1e-8f) yaw_pre = std::atan2(-to_pre[0], to_pre[2]);
            const float yaw_now = snap ? wrap_angle(yaw_pre + current_.framing[1]) : pan_.position();
            const Vec3 shift = scale(Vec3{-std::cos(yaw_now), 0.0f, -std::sin(yaw_now)}, shoulder_metres);
            camera = add(camera, shift);

            // ---- collision (card T8, simplified): the pivot moves with the shoulder so the ray stays
            // parallel to the unshifted one. Pulling the camera in along the pivot -> camera line keeps
            // its direction, and the aim below is taken from the FINAL camera position, so the orientation
            // and the position always agree.
            const float pulled = collide(ground, add(look_base, shift), camera, snap);

            // Look at the actual reference point (not the lagged anchor): the camera holds its height
            // in the air while the skater rises through the frame. The up-tilt is capped (frame_composer.rs).
            const Vec3 to_ref = sub(add(look_target, shift), camera);
            const float to_len = length(to_ref);
            float yaw_target = pan_.position();
            float pitch_target = tilt_.position();
            if (to_len > 1e-4f) {
                const float horizontal = std::sqrt(to_ref[0] * to_ref[0] + to_ref[2] * to_ref[2]);
                if (horizontal > 1e-4f) yaw_target = std::atan2(-to_ref[0], to_ref[2]);
                const float ceiling = std::sin(cs.orientation.max_pitch_degrees * degrees);
                pitch_target = std::asin(std::min(to_ref[1] / std::max(to_len, 1e-4f), ceiling));
            }
            yaw_target = wrap_angle(yaw_target + current_.framing[1]);
            // frame_composer.rs: pitch = -framing[2] is applied in the look basis (columns right, up, at),
            // which tilts the view DOWN by that angle, so a positive authored pitch looks up from the
            // camera-to-reference line and a negative one (the Low shots) looks down.
            // The player's pitch offset goes in after the look offsets and before the clamp; the tilt tracker
            // below eases a change of it.
            // Low and High each have their own pitch; it eases (look.response_time) so an angle switch is smooth.
            const float framing_pitch_goal = active_framing().pitch_degrees * degrees;
            framing_pitch_ = snap ? framing_pitch_goal : camera_detail::ease_to(framing_pitch_, framing_pitch_goal, lk.response_time, dt);
            pitch_target = std::clamp(pitch_target + current_.framing[2] + look_pitch_ + framing_pitch_,
                                      -89.0f * degrees, 89.0f * degrees);
            if (snap) {
                pan_.reset(yaw_target);
                tilt_.reset(pitch_target);
                roll_ = current_.framing[0];
            } else {
                pan_.update(yaw_target, dt, orientation_tracker(cs.orientation.pan, follow_smoothing(current_.smoothing[2]), cs.orientation));
                tilt_.update(pitch_target, dt, orientation_tracker(cs.orientation.tilt, follow_smoothing(current_.smoothing[3]), cs.orientation));
                roll_ += (current_.framing[0] - roll_) * roll_step;
            }
            // Keep the skater in the vertical view in the air (an offset on the eased view pitch, so it also
            // works past the max-pitch ceiling above).
            const float keep_pitch = update_keep_in_frame(camera, tilt_.position() + last_shake_pitch_,
                                                       {add(look_base, keep_lead), add(points[4], keep_lead), add(s.position, keep_lead)}, in_air_layer, snap);
            out.pos = camera;
            out.yaw = pan_.position();
            out.pitch = tilt_.position() + keep_pitch;
            out.roll = roll_;
            layers_.look_target = look_target;
            shake_distance = length(sub(camera, rig_out.anchor));
            layers_.collision_pull = pulled;
        } else {
            if (snap) roll_ = current_.framing[0];
            else roll_ += (current_.framing[0] - roll_) * roll_step;
            const float hold = cs.native_plus.air_hold ? ref_y - anchor_pt[1] : 0.0f;
            // Critically damped spring, semi-implicit Euler (stable: omega * dt << 1).
            const float omega = 1.0f / std::max(cs.native_plus.dip_peak_time, 1e-3f);
            dip_v_ += (-2.0f * omega * dip_v_ - omega * omega * dip_x_) * dt;
            dip_x_ += dip_v_ * dt;
            // The rise: swing the camera up over the skater by raising the native position by distance * sin(rise)
            // and pitching the view down so the skater stays in the same screen spot. The pitch is the change of
            // the camera -> skater elevation the lift causes (about `rise` when the skater is level with the
            // view, less when he is far above or below it, where a flat `rise` would push him off the axis).
            const float dip_now = cs.native_plus.landing_dip ? dip_x_ : 0.0f;
            const Vec3 unraised = add(native_pose_.position, {0.0f, hold - dip_now, 0.0f});
            const float lift = native_distance_ * std::sin(rise_rad);
            const float rise_pitch = elevation_to(add(unraised, {0.0f, lift, 0.0f}), s.position) - elevation_to(unraised, s.position);
            out.pos = {0.0f, hold - dip_now + lift, 0.0f};
            out.roll = cs.native_plus.roll ? roll_ : 0.0f;
            // Framing pitch (the only framing NativePlus has): a cut eases it in from 0 like the other layers.
            if (!snap) native_pitch_ = camera_detail::ease_to(native_pitch_, active_framing().pitch_degrees * degrees, cs.look.response_time, dt);
            const float native_view_pitch = std::asin(std::clamp(-native_pose_.back[1] / std::max(length(native_pose_.back), 1e-4f), -1.0f, 1.0f)) +
                                            native_pitch_ + rise_pitch + last_shake_pitch_;
            const Vec3 head_point = add(s.position, {0.0f, cs.points.head_height, 0.0f});
            const float keep_pitch = update_keep_in_frame(add(native_pose_.position, out.pos), native_view_pitch,
                                                          {add(s.position, keep_lead), add(points[4], keep_lead), add(head_point, keep_lead)}, in_air_layer, snap);
            out.pitch = native_pitch_ + rise_pitch + keep_pitch;
            layers_.collision_pull = 0.0f;
            trick_yaw_ = TrickYawState{};
        }
        out.shoulder = shoulder_metres;
        out.fov_extra = fov_extra_;
        layers_.landing_look_weight = native ? 0.0f : landing_w_;
        layers_.look_pitch_offset = native ? 0.0f : look_pitch_;
        layers_.follow_strength = follow_k;
        layers_.trick_yaw = trick_yaw_.value;
        layers_.air_follow_weight = air_w_;
        layers_.air_reference_height = ref_y;
        layers_.air_rise = rise_rad;
        layers_.keep_pitch_offset = keep_off_;
        layers_.focus_weight = focus_value_;

        // ---- shake. Speed shake (both presets): the rumble is rebuilt per step from a copy of the
        // settings, so the landing impulse (separate fields) is untouched. When the rumble is off its
        // amplitude is 0; otherwise amplitude_max scales with strength and the downhill factor, and the
        // speed that gives the full rumble (amplitude and frequency) is speed_shake.top_speed.
        ShakeSettings shake_cfg = cs.shake;
        const SpeedShakeSettings& rumble = cs.speed_shake;
        if (!rumble.enabled) {
            shake_cfg.amplitude_min = shake_cfg.amplitude_max = 0.0f;
        } else {
            float downhill = 1.0f;
            if (rumble.downhill_boost && incline_degrees_ < 0.0f)
                downhill = 1.0f + (rumble.downhill_scale - 1.0f) * clamp01(-incline_degrees_ / std::max(rumble.downhill_full_degrees, 1.0f));
            shake_cfg.amplitude_max *= rumble.strength * downhill;
            shake_cfg.amplitude_top_speed = shake_cfg.frequency_top_speed = rumble.top_speed;
        }
        const bool shake_on = cs.shake_enabled && (!native || cs.native_plus.shake);
        const ShakeOutput sh = shake_.update(dt, horizontal_speed, shake_distance * cs.pipeline.shake_distance_scale,
                                             shake_on && !s.bailing, shake_cfg);
        out.yaw += sh.yaw;
        out.pitch += sh.pitch;
        last_shake_pitch_ = sh.pitch; // the next step's keep-in-frame counts it (the shake is computed after)
        out.roll += sh.roll;
        out.local = sh.translation;

        // ---- write (a non-finite step is dropped: the previous output stays)
        was_air_ = air;
        last_pick_ = pick;
        last_speed_ = speed;
        last_rig_ = rig_out;
        last_push_state_ = push_state;
        last_push_kick_ = push_kick;
        kick_in_update_ = kick_in_update_ || push_kick;
        last_hold_ = ref_y - anchor_pt[1];
        if (out.finite()) {
            prev_out_ = curr_out_;
            curr_out_ = out;
        }
    }

    // Pan / tilt smoothing from the shot (rig_orientation.rs bind_shot): 1 - (1 - s)^2 where
    // s is the shot's smoothing... derived as in manager_rig.rs, then capped.
    static AngleTrackerSettings orientation_tracker(AngleTrackerSettings base, float shot_smoothing,
                                                    const OrientationSettings& set) noexcept {
        const float inverse = 1.0f - std::clamp(shot_smoothing, 0.0f, 1.0f);
        const float smoothing = std::min(1.0f - inverse * inverse, set.smoothing_cap);
        base.smoothing_min = base.smoothing_max = clamp01(smoothing);
        return base;
    }

    GraphInput graph_input(const SubjectSnapshot& s, float dt, bool touchdown, float max_height, float speed,
                           const Vec3& normal) const noexcept {
        GraphInput g;
        g.dt = dt;
        g.bailing = s.bailing;
        g.air = s.air();
        g.grinding = s.grinding();
        g.grind_side = s.grind_side;
        g.manual = s.manual;
        g.touchdown = touchdown;
        g.speed = speed;
        g.predicted_max_height = max_height;
        g.incline_degrees = incline_of(s, normal);
        return g;
    }

    // Ballistic prediction from the surface-level point (position - up * clearance, decision 3).
    template <class Query>
    void predict(const SubjectSnapshot& s, Query& ground) noexcept {
        TrajectoryLaunch launch;
        const float surface_y = s.position[1] - last_clearance_;
        launch.position = {s.position[0], surface_y, s.position[2]};
        launch.velocity = s.velocity;
        launch.launch_normal = last_ground_normal_;
        launch.camera_distance = current_.distance;
        prediction_ = predict_trajectory(launch, ground, settings_.trajectory);
        // Express everything against the takeoff surface: set_prediction's launch_clearance adds
        // (this launch point - takeoff surface), so a re-prediction mid-flight reports the same datum.
        prediction_offset_ = surface_y - takeoff_surface_y_;
        prediction_time_base_ = air_time_;
    }

    // Landing dip: a velocity kick into the critically damped spring whose peak depth is dip_depth * intensity.
    void kick_dip(const Vec3& normal, const Vec3& velocity) noexcept {
        const NativePlusSettings& np = settings_.native_plus;
        if (settings_.preset != CameraPreset::NativePlus || !np.landing_dip) return;
        if (!(length(velocity) > 1e-5f)) return;
        // The speed into the surface, as Shake::landing_impulse weights it (see the deviation noted there).
        const float weighted = -dot(normalized(normal, {0.0f, 1.0f, 0.0f}), velocity);
        if (!(weighted > 0.0f)) return;
        const ShakeSettings& sk = settings_.shake;
        const float fraction = clamp01((weighted - sk.one_shot_min_velocity) / std::max(sk.one_shot_max_velocity - sk.one_shot_min_velocity, 1e-6f));
        const float peak = np.dip_depth * fraction * fraction;
        const float omega = 1.0f / std::max(np.dip_peak_time, 1e-3f);
        constexpr float e = 2.71828182845905f;
        dip_v_ = std::max(dip_v_, peak * omega * e); // x(t) = v0 t exp(-omega t) peaks at v0 / (omega e)
    }

    // Camera collision (card T8, simplified; FullS3). Ray 1 runs pivot -> camera: a hit allows
    // max(min_distance, hit distance - radius) along that line, and the camera sits at
    // pivot + dir * (full - pull). The smoothing runs on the PULL (metres taken off the rig's own
    // distance) rather than on the allowed distance itself: equal while an obstacle is there, but a clear
    // ray then costs nothing, so the rig's distance changes pass through without an extra lag. Pulling in
    // eases with pull_in_time, letting out with release_time. Ray 2 runs from 1 m above the camera down
    // to ground_clearance below it and lifts the camera to the ground + ground_clearance, eased the same
    // way. At most two rays per fixed step. A cut snaps both. Returns the metres pulled in.
    template <class Query>
    float collide(Query& ground, const Vec3& pivot, Vec3& camera, bool snap) noexcept {
        using camera_detail::finite3;
        const CollisionSettings& col = settings_.collision;
        if (!col.enabled) {
            coll_pull_ = coll_lift_ = 0.0f;
            return 0.0f;
        }
        const Vec3 ray = sub(camera, pivot);
        const float full = length(ray);
        float pull_goal = 0.0f;
        if (full > 1e-3f) {
            if (const std::optional<GroundHit> wall = ground(pivot, camera)) {
                if (finite3(wall->point)) {
                    const float allowed = std::max(col.min_distance, length(sub(wall->point, pivot)) - col.radius);
                    pull_goal = std::max(0.0f, full - allowed);
                }
            }
        }
        coll_pull_ = snap ? pull_goal : camera_detail::ease_to(coll_pull_, pull_goal, pull_goal > coll_pull_ ? col.pull_in_time : col.release_time, fixed_step);
        // Never closer than min_distance (a rig distance already shorter than that is left alone).
        const float pull = std::min(coll_pull_, std::max(0.0f, full - col.min_distance));
        if (pull > 0.0f) camera = add(pivot, scale(ray, (full - pull) / std::max(full, 1e-3f)));

        float lift_goal = 0.0f;
        if (const std::optional<GroundHit> floor_hit = ground(add(camera, {0.0f, 1.0f, 0.0f}), sub(camera, {0.0f, col.ground_clearance, 0.0f}))) {
            if (finite3(floor_hit->point)) lift_goal = std::max(0.0f, floor_hit->point[1] + col.ground_clearance - camera[1]);
        }
        coll_lift_ = snap ? lift_goal : camera_detail::ease_to(coll_lift_, lift_goal, lift_goal > coll_lift_ ? col.pull_in_time : col.release_time, fixed_step);
        camera[1] += coll_lift_;
        return pull;
    }

    // Base fov: the override, else the game camera's own (extras.base_fov_deg, then the native pose's), else
    // the chase shot's lens. The shot term in the extras is relative to the chase lens, so the current shot's
    // lens is counted once. The base is not smoothed here.
    float fov_base_deg() const noexcept {
        float base_fov = lens_field_of_view_degrees(chase_lens_, aspect_);
        if (settings_.preset == CameraPreset::NativePlus && native_fov_ > 0.0f) base_fov = native_fov_;
        if (std::isfinite(extras_base_fov_) && extras_base_fov_ > 0.0f) base_fov = extras_base_fov_;
        if (settings_.fov_override_deg > 0.0f) base_fov = settings_.fov_override_deg;
        return base_fov;
    }

    // The frame from the last two steps, interpolated by the accumulator.
    void publish(FrameDebug dbg, const FrameExtras& extras) noexcept {
        const NativePose* native_pose = extras.native;
        using namespace camera_detail;
        const float alpha = clamp01(acc_ * fixed_hz);
        StepOut o;
        o.pos = lerp(prev_out_.pos, curr_out_.pos, alpha);
        o.yaw = blend_angle(prev_out_.yaw, curr_out_.yaw, alpha);
        o.pitch = lerp_f(prev_out_.pitch, curr_out_.pitch, alpha);
        o.roll = lerp_f(prev_out_.roll, curr_out_.roll, alpha);
        o.local = lerp(prev_out_.local, curr_out_.local, alpha);
        o.fov_extra = lerp_f(prev_out_.fov_extra, curr_out_.fov_extra, alpha);
        o.shoulder = lerp_f(prev_out_.shoulder, curr_out_.shoulder, alpha);

        Vec3 right, up, back, position;
        // Base fov: the override, else the game camera's own (extras.base_fov_deg, then the native pose's),
        // else the chase shot's lens. The shot term in the extras is relative to the chase lens, so the
        // current shot's lens is counted once. The base is not smoothed here.
        const float fov_base = fov_base_deg();
        if (settings_.preset == CameraPreset::FullS3) {
            basis_from_angles(o.yaw, o.pitch, o.roll, right, up, back);
            position = add(o.pos, add(add(scale(right, o.local[0]), scale(up, o.local[1])), scale(back, o.local[2])));
        } else {
            right = native_pose->right;
            up = native_pose->up;
            back = native_pose->back;
            orthonormalize(right, up, back);
            // Camera-local rotations: yaw about -up, pitch about right, roll about back.
            const auto spin = [&](const Vec3& axis, float angle) {
                right = rotate_about(right, axis, angle);
                up = rotate_about(up, axis, angle);
                back = rotate_about(back, axis, angle);
            };
            spin(scale(up, -1.0f), o.yaw);
            spin(right, o.pitch);
            spin(back, o.roll);
            orthonormalize(right, up, back);
            position = add(add(native_pose->position, o.pos),
                           add(add(scale(right, o.local[0] + o.shoulder), scale(up, o.local[1])), scale(back, o.local[2])));
        }
        const float fov = std::clamp(fov_base + o.fov_extra, 1.0f, 170.0f);
        if (!finite3(right) || !finite3(up) || !finite3(back) || !finite3(position) || !std::isfinite(fov)) {
            hold();
            return;
        }
        frame_.right = right;
        frame_.up = up;
        frame_.back = back;
        frame_.pos = position;
        frame_.fov_deg = fov;
        frame_.shot = id_;
        frame_.valid = true;

        dbg.shot_name = shot_id_name(id_);
        dbg.preset = settings_.preset;
        dbg.airborne = was_air_;
        dbg.landing_active = last_pick_.landing_active;
        dbg.transitioning = shot_fraction_ < 1.0f;
        dbg.shot_fraction = shot_fraction_;
        dbg.chase_blend = last_pick_.chase_blend;
        dbg.prediction_valid = prediction_.landed();
        dbg.predicted_max_height = was_air_ ? flight_max_height_ : 0.0f;
        dbg.predicted_air_time = prediction_.landed() ? prediction_time_base_ + prediction_.predicted_air_time : 0.0f;
        dbg.predicted_landing_delta = prediction_.landed() ? prediction_.predicted_landing_height + prediction_offset_ : 0.0f;
        dbg.air_hold_delta = last_hold_;
        dbg.anchor_lag = last_rig_.anchor_lag;
        dbg.heading = last_rig_.heading;
        dbg.elevation = settings_.preset == CameraPreset::FullS3 ? last_elevation_used_ : last_rig_.elevation; // with the rise, so camera = anchor + distance * sin(elevation)
        dbg.distance = last_rig_.distance;
        dbg.impulse = shake_.impulse();
        dbg.landing_dip = dip_x_;
        dbg.speed = last_speed_;
        dbg.incline_degrees = incline_degrees_;
        dbg.forward_acceleration = accel_filtered_;
        dbg.push_state = last_push_state_;
        dbg.push_kick = kick_in_update_;
        dbg.fov_base = fov_base;
        dbg.fov_extra = o.fov_extra;
        dbg.landing_look_weight = layers_.landing_look_weight;
        dbg.look_pitch_offset = layers_.look_pitch_offset;
        dbg.shoulder = o.shoulder;
        dbg.follow_strength = layers_.follow_strength;
        dbg.collision_pull = layers_.collision_pull;
        dbg.trick_yaw = layers_.trick_yaw;
        dbg.air_follow_weight = layers_.air_follow_weight;
        dbg.air_reference_height = layers_.air_reference_height;
        dbg.air_rise = layers_.air_rise;
        dbg.keep_pitch_offset = layers_.keep_pitch_offset;
        dbg.focus_weight = layers_.focus_weight;
        dbg.look_target = layers_.look_target;
        frame_.debug = dbg;
    }

    CameraSettings settings_{};
    Frame frame_{};

    // pipeline
    ShotGraph graph_;
    AirHeight air_;
    Rig rig_;
    Shake shake_;
    AngleTracker pan_, tilt_;
    float roll_ = 0.0f;

    // shot blend
    Shot from_{}, leaf_{}, current_{};
    ResolvedShots shots_{}; // the table shots of id_ / angle_, looked up on a shot change only
    ShotId id_ = ShotId::Chase;
    CameraAngle angle_ = CameraAngle::Low;
    float shot_elapsed_ = 0.0f, shot_duration_ = 0.0f, shot_fraction_ = 1.0f;

    // fixed-step driver
    SubjectSnapshot cur_snap_{};
    StepOut prev_out_{}, curr_out_{};
    float acc_ = 0.0f;
    float aspect_ = 16.0f / 9.0f;
    float invalid_time_ = 0.0f;
    bool initialized_ = false;
    bool reset_requested_ = false;
    CameraPreset last_preset_ = CameraPreset::FullS3;

    // air / prediction
    bool was_air_ = false;
    float air_time_ = 0.0f, repredict_timer_ = 0.0f;
    float flight_max_height_ = 0.0f; // m above the takeoff surface: the highest predicted apex this flight (latched)
    float takeoff_surface_y_ = 0.0f, last_clearance_ = 0.95f;
    Vec3 last_ground_normal_{0, 1, 0};
    TrajectoryPrediction prediction_{};
    float prediction_offset_ = 0.0f, prediction_time_base_ = 0.0f;

    // acceleration / push
    bool accel_ready_ = false;
    float prev_forward_speed_ = 0.0f, accel_filtered_ = 0.0f, prev_accel_ = 0.0f, push_timer_ = 0.0f;
    float no_lag_timer_ = 0.0f;

    // NativePlus
    float dip_x_ = 0.0f, dip_v_ = 0.0f, native_distance_ = 3.0f;

    // Alpha 2 layers (both presets unless noted)
    float fov_extra_ = 0.0f;            // deg, eased shot + speed + air terms
    float chase_lens_ = 12.0f;          // the chase shot's lens for the current angle (the shot term's zero)
    float landing_w_ = 0.0f, look_pitch_ = 0.0f; // FullS3: eased landing-look weight, slope-look pitch (rad)
    Vec3 landing_point_{0, 0, 0};       // FullS3: where the board will touch down (held when the prediction ends)
    float shoulder_value_ = 0.0f, shoulder_start_ = 0.0f, shoulder_target_ = 0.0f, shoulder_elapsed_ = 0.0f; // side -1..1
    float coll_pull_ = 0.0f, coll_lift_ = 0.0f; // FullS3: smoothed pull-in and ground lift, m
    float native_pitch_ = 0.0f;         // NativePlus: eased framing pitch offset, rad
    // Alpha 4. The eased in-air weight (follow_height), the eased rise weight, the keep-in-frame pitch offset
    // (rad), the eased manual / grind focus and the eased framing pitch (FullS3), plus what the steps need of
    // the frame's extras.
    float air_w_ = 0.0f, rise_w_ = 0.0f, keep_off_ = 0.0f, focus_value_ = 1.0f, focus_from_ = 1.0f, framing_pitch_ = 0.0f;
    float last_elevation_used_ = 0.0f;  // FullS3: the rig elevation plus the rise, rad
    float extras_base_fov_ = 0.0f, native_fov_ = 0.0f, last_shake_pitch_ = 0.0f;
    NativePose native_pose_{};
    static constexpr float keep_response_time = 0.08f; // s, the keep-in-frame ease (TUNE)
    float held_speed_ = 0.0f;           // m/s, |velocity . forward| at the last grounded step (the in-air speed)
    // Trick yaw (FullS3): a sine ease from `start` to `target` over `duration`, restarted from the current
    // value whenever the target changes, so it never jumps. `value` > 0 swings to the skater's right.
    struct TrickYawState {
        float value = 0.0f, start = 0.0f, target = 0.0f, elapsed = 0.0f, duration = 0.0f;
        float hold_left = 0.0f; // s of hold remaining after the last trick step
    } trick_yaw_;
    struct LayerDebug {
        float landing_look_weight = 0.0f, look_pitch_offset = 0.0f, follow_strength = 1.0f, collision_pull = 0.0f, trick_yaw = 0.0f;
        float air_follow_weight = 0.0f, air_reference_height = 0.0f, air_rise = 0.0f, keep_pitch_offset = 0.0f, focus_weight = 1.0f;
        Vec3 look_target{0, 0, 0};
    } layers_;

    // diagnostics from the last step (kick is sticky over one update: a frame can hold several steps)
    bool kick_in_update_ = false;
    GraphOutput last_pick_{};
    RigOutput last_rig_{};
    float last_speed_ = 0.0f, last_hold_ = 0.0f, incline_degrees_ = 0.0f;
    bool last_push_state_ = false, last_push_kick_ = false;
};

} // namespace dingosdk::s3cam
