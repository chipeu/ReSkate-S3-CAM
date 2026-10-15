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
#include <string_view>

// CameraMan (card T6): turns a SubjectSnapshot stream into a camera Frame. Pure and header-only, no
// heap allocation, update() is noexcept.
//
// Order of operations per FIXED step (CLAUDE.md hard rule 4):
//   prepare (air / landing, then incline) -> graph select -> shot blend -> rig -> orientation and
//   framing -> shake -> write.
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
    float fov_deg = 0.0f; // > 0: reported as the Frame fov unless fov_override_deg is set
};

struct FrameExtras {
    float aspect = 16.0f / 9.0f;       // width / height; a non-finite or non-positive value keeps the last good one
    const NativePose* native = nullptr; // required each update in NativePlus, ignored in FullS3
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
    float heading = 0.0f, elevation = 0.0f, distance = 0.0f; // rig, radians / metres
    float impulse = 0.0f;              // shake landing impulse
    float landing_dip = 0.0f;          // m below the native pose (NativePlus)
    float speed = 0.0f;                // m/s, |velocity . forward|
    float incline_degrees = 0.0f;
    float forward_acceleration = 0.0f; // m/s^2, filtered; feeds pump / push
    bool push_state = false;
    bool push_kick = false;
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
                                       : dt > 0.0f ? clamp01((static_cast<float>(i) * step - carry) / dt) : 1.0f;
                const SubjectSnapshot sub_snap = blend_snapshot(cur_snap_, subject, f);
                step_once(sub_snap, ground, false);
            }
            acc_ -= static_cast<float>(steps) * step;
            if (acc_ < 0.0f) acc_ = 0.0f;
            dbg.steps = steps;
            cur_snap_ = subject;
        }
        dbg.accumulator = acc_;
        publish(dbg, extras.native);
        return frame_;
    }

private:
    // One fixed step's result. FullS3: the absolute camera pose, shake included. NativePlus: offsets to
    // lay over the native pose (world position offset, angle deltas, camera-local shake translation).
    struct StepOut {
        Vec3 pos{0, 0, 0};
        float yaw = 0.0f, pitch = 0.0f, roll = 0.0f;
        Vec3 local{0, 0, 0};
        float fov = 0.0f;
        bool finite() const noexcept {
            return camera_detail::finite3(pos) && camera_detail::finite3(local) && std::isfinite(yaw) && std::isfinite(pitch) &&
                   std::isfinite(roll) && std::isfinite(fov);
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

    // The slope of the direction of travel along the ground, degrees, + uphill (manager_state.rs update_incline).
    static float incline_of(const SubjectSnapshot& s, const Vec3& normal) noexcept {
        Vec3 along = sub(s.forward, scale(normal, dot(s.forward, normal)));
        if (dot(s.velocity, s.forward) < 0.0f) along = scale(along, -1.0f);
        const float l = length(along);
        if (!(l > 1e-4f)) return 0.0f;
        return std::asin(std::clamp(along[1] / l, -1.0f, 1.0f)) / degrees;
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
        const float speed = std::abs(forward_speed);
        const float horizontal_speed = length({s.velocity[0], 0.0f, s.velocity[2]});

        if (snap) {
            // A cut has no previous shot, but the framing below needs this frame's shot: resolve the
            // one the graph would pick first.
            graph_.reset();
            const GraphOutput first = graph_.select(graph_input(s, dt, false, 0.0f, speed, normal), cs.graph);
            graph_.reset();
            angle_ = cs.angle;
            id_ = first.shot;
            shots_ = lookup_shots(id_, angle_);
            leaf_ = blend_shots(shots_, first.chase_blend);
            current_ = from_ = leaf_;
        }
        const std::array<Vec3, 10> points = reference_points(s);
        const Vec3 anchor_pt = anchor_point(s);

        // ---- forward acceleration -> pump / push (decision 2)
        if (!accel_ready_) {
            prev_forward_speed_ = forward_speed;
            accel_filtered_ = prev_accel_ = 0.0f;
            accel_ready_ = true;
        }
        const float raw_accel = (forward_speed - prev_forward_speed_) / dt;
        prev_forward_speed_ = forward_speed;
        const float smoothing_time = cs.pipeline.accel_smoothing_time;
        const float blend = smoothing_time > 0.0f ? 1.0f - std::exp(-dt / smoothing_time) : 1.0f;
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

        // ---- shot blend (shot_manager.rs: previous = interpolated at the change, eased by elapsed/duration)
        const bool changed = snap || pick.shot != id_ || cs.angle != angle_;
        if (changed) shots_ = lookup_shots(pick.shot, cs.angle); // cached until the selection changes
        leaf_ = blend_shots(shots_, pick.chase_blend);
        if (changed) {
            from_ = snap ? leaf_ : current_;
            shot_elapsed_ = 0.0f;
            shot_duration_ = snap ? 0.0f : cs.graph.transition_time[static_cast<std::size_t>(pick.shot)];
            id_ = pick.shot;
            angle_ = cs.angle;
        }
        shot_elapsed_ += dt;
        shot_fraction_ = shot_duration_ <= 0.0f ? 1.0f : clamp01(shot_elapsed_ / shot_duration_);
        current_ = interpolate(from_, leaf_, shot_fraction_);
        current_.position_heading = blend_angle(from_.position_heading, leaf_.position_heading, sine_blend(shot_fraction_));
        const Vec3 reference_now = weighted_point(points, current_); // the blended weights: framing only

        // ---- rig (FullS3) / native layers (NativePlus), orientation and framing
        StepOut out;
        RigOutput rig_out;
        float shake_distance = native_distance_;
        const float roll_step = std::min(1.0f, cs.orientation.roll_response * dt);
        if (!native) {
            RigInput ri;
            ri.anchor.position = anchor_pt;
            ri.anchor.reference_height = air_out.reference_height;
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
            ri.heading_smoothing = current_.smoothing[0];   // manager_rig.rs bind_shot: direction smoothing
            ri.elevation_target = current_.position_elevation;
            ri.elevation_smoothing = current_.smoothing[1]; // and elevation smoothing
            ri.distance.target = current_.distance;
            ri.distance.fast = air || pick.landing_active || s.bailing; // TUNE: the fast set where the view must keep up
            ri.distance.wipeout = s.bailing;
            ri.distance.snap = snap;
            if (snap) rig_.reset(ri, cs.rig);
            rig_out = rig_.update(dt, ri, cs.rig);

            const float cos_e = std::cos(rig_out.elevation), sin_e = std::sin(rig_out.elevation);
            const Vec3 offset_dir{-std::sin(rig_out.heading), 0.0f, std::cos(rig_out.heading)};
            Vec3 camera = add(rig_out.anchor, add(scale(offset_dir, rig_out.distance * cos_e), {0, rig_out.distance * sin_e, 0}));
            if (cs.pipeline.floor_clearance > 0.0f)
                camera[1] = std::max(camera[1], s.position[1] - clearance_now + cs.pipeline.floor_clearance);

            // Look at the actual reference point (not the lagged anchor): the camera holds its height
            // in the air while the skater rises through the frame. The up-tilt is capped (frame_composer.rs).
            // The shot's board_offset lifts the look target above the weighted point (Rust: along the
            // subject's board-offset direction, here world up): the Low camera sits near the board and
            // looks up at the skater.
            const Vec3 look_target = add(reference_now, {0.0f, current_.board_offset, 0.0f});
            const Vec3 to_ref = sub(look_target, camera);
            const float to_len = length(to_ref);
            float yaw_target = pan_.position();
            float pitch_target = tilt_.position();
            if (to_len > 1e-4f) {
                const float horizontal = std::sqrt(to_ref[0] * to_ref[0] + to_ref[2] * to_ref[2]);
                if (horizontal > 1e-4f) yaw_target = std::atan2(-to_ref[0], to_ref[2]);
                const float ceiling = std::sin(cs.orientation.max_pitch_degrees * degrees);
                pitch_target = std::asin(std::min(to_ref[1] / to_len, ceiling));
            }
            yaw_target = wrap_angle(yaw_target + current_.framing[1]);
            // frame_composer.rs: pitch = -framing[2] is applied in the look basis (columns right, up, at),
            // which tilts the view DOWN by that angle, so a positive authored pitch looks up from the
            // camera-to-reference line and a negative one (the Low shots) looks down.
            pitch_target = std::clamp(pitch_target + current_.framing[2], -89.0f * degrees, 89.0f * degrees);
            if (snap) {
                pan_.reset(yaw_target);
                tilt_.reset(pitch_target);
                roll_ = current_.framing[0];
            } else {
                pan_.update(yaw_target, dt, orientation_tracker(cs.orientation.pan, current_.smoothing[2], cs.orientation));
                tilt_.update(pitch_target, dt, orientation_tracker(cs.orientation.tilt, current_.smoothing[3], cs.orientation));
                roll_ += (current_.framing[0] - roll_) * roll_step;
            }
            out.pos = camera;
            out.yaw = pan_.position();
            out.pitch = tilt_.position();
            out.roll = roll_;
            shake_distance = length(sub(camera, rig_out.anchor));
        } else {
            if (snap) roll_ = current_.framing[0];
            else roll_ += (current_.framing[0] - roll_) * roll_step;
            const float hold = cs.native_plus.air_hold ? air_out.reference_height - anchor_pt[1] : 0.0f;
            // Critically damped spring, semi-implicit Euler (stable: omega * dt << 1).
            const float omega = 1.0f / cs.native_plus.dip_peak_time;
            dip_v_ += (-2.0f * omega * dip_v_ - omega * omega * dip_x_) * dt;
            dip_x_ += dip_v_ * dt;
            out.pos = {0.0f, hold - (cs.native_plus.landing_dip ? dip_x_ : 0.0f), 0.0f};
            out.roll = cs.native_plus.roll ? roll_ : 0.0f;
        }

        // ---- shake
        const bool shake_on = cs.shake_enabled && (!native || cs.native_plus.shake);
        const ShakeOutput sh = shake_.update(dt, horizontal_speed, shake_distance * cs.pipeline.shake_distance_scale,
                                             shake_on && !s.bailing, cs.shake);
        out.yaw += sh.yaw;
        out.pitch += sh.pitch;
        out.roll += sh.roll;
        out.local = sh.translation;
        out.fov = lens_field_of_view_degrees(current_.lens_length, aspect_);

        // ---- write (a non-finite step is dropped: the previous output stays)
        was_air_ = air;
        last_pick_ = pick;
        last_speed_ = speed;
        last_rig_ = rig_out;
        last_push_state_ = push_state;
        last_push_kick_ = push_kick;
        kick_in_update_ = kick_in_update_ || push_kick;
        last_hold_ = air_out.reference_height - anchor_pt[1];
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
        const float speed = length(velocity);
        if (!(speed > 1e-5f)) return;
        const Vec3 direction = scale(velocity, 1.0f / speed);
        const float cosine = std::clamp(dot(scale(normal, -1.0f), direction), -1.0f, 1.0f);
        const float angle = std::acos(cosine) * (2.0f / pi);
        const float weighted = speed * (1.0f - clamp01(angle));
        const ShakeSettings& sk = settings_.shake;
        const float fraction = clamp01((weighted - sk.one_shot_min_velocity) / (sk.one_shot_max_velocity - sk.one_shot_min_velocity));
        const float peak = np.dip_depth * fraction * fraction;
        const float omega = 1.0f / np.dip_peak_time;
        constexpr float e = 2.71828182845905f;
        dip_v_ = std::max(dip_v_, peak * omega * e); // x(t) = v0 t exp(-omega t) peaks at v0 / (omega e)
    }

    // The frame from the last two steps, interpolated by the accumulator.
    void publish(FrameDebug dbg, const NativePose* native_pose) noexcept {
        using namespace camera_detail;
        const float alpha = clamp01(acc_ * fixed_hz);
        StepOut o;
        o.pos = lerp(prev_out_.pos, curr_out_.pos, alpha);
        o.yaw = blend_angle(prev_out_.yaw, curr_out_.yaw, alpha);
        o.pitch = lerp_f(prev_out_.pitch, curr_out_.pitch, alpha);
        o.roll = lerp_f(prev_out_.roll, curr_out_.roll, alpha);
        o.local = lerp(prev_out_.local, curr_out_.local, alpha);
        o.fov = lerp_f(prev_out_.fov, curr_out_.fov, alpha);

        Vec3 right, up, back, position;
        float fov = o.fov;
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
                           add(add(scale(right, o.local[0]), scale(up, o.local[1])), scale(back, o.local[2])));
            if (native_pose->fov_deg > 0.0f) fov = native_pose->fov_deg;
        }
        if (settings_.fov_override_deg > 0.0f) fov = settings_.fov_override_deg;
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
        dbg.elevation = last_rig_.elevation;
        dbg.distance = last_rig_.distance;
        dbg.impulse = shake_.impulse();
        dbg.landing_dip = dip_x_;
        dbg.speed = last_speed_;
        dbg.incline_degrees = incline_degrees_;
        dbg.forward_acceleration = accel_filtered_;
        dbg.push_state = last_push_state_;
        dbg.push_kick = kick_in_update_;
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

    // diagnostics from the last step (kick is sticky over one update: a frame can hold several steps)
    bool kick_in_update_ = false;
    GraphOutput last_pick_{};
    RigOutput last_rig_{};
    float last_speed_ = 0.0f, last_hold_ = 0.0f, incline_degrees_ = 0.0f;
    bool last_push_state_ = false, last_push_kick_ = false;
};

} // namespace dingosdk::s3cam
