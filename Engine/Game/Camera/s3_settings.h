#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/manager.rs (ManagerSettings: rig, orientation, framing, drop, look,
// shake), rig_orientation.rs (OrientationSettings pan/tilt trackers) and frame_composer.rs
// (FrameSettings: maximum pitch, roll response). Semantics are ported; every default is hand-picked
// and marked // TUNE (CLAUDE.md hard rule 7).
#include "Engine/Game/Camera/s3_air.h"
#include "Engine/Game/Camera/s3_graph.h"
#include "Engine/Game/Camera/s3_rig.h"
#include "Engine/Game/Camera/s3_shake.h"
#include "Engine/Game/Camera/s3_shots_default.h"
#include "Engine/Game/Camera/s3_tracker.h"
#include "Engine/Game/Camera/s3_trajectory.h"

#include <cmath>

// One aggregate holding every S3Cam tunable (card T6, decision 6). Pure data plus valid(); T10 adds
// persistence and the UI, there is no I/O here.
namespace dingosdk::s3cam {

enum class CameraPreset {
    FullS3,     // the whole Skate 3 pipeline owns the camera (default)
    NativePlus, // the game's own pose plus only the S3 layers (air hold, landing dip, shake, roll)
};

// Where the shot's reference weights look and how fast the camera turns to it (rig_orientation.rs).
struct OrientationSettings {
    AngleTrackerSettings pan{0.5f, 20.0f, 720.0f, 1500.0f, 3000.0f, 0.0f, 0.0f, true};  // TUNE; smoothing comes from the shot
    AngleTrackerSettings tilt{0.5f, 15.0f, 360.0f, 1200.0f, 2400.0f, 0.0f, 0.0f, true}; // TUNE
    float max_pitch_degrees = 60.0f; // FrameSettings.maximum_pitch_degrees: the look direction never tilts up past this; TUNE
    float roll_response = 6.0f;      // 1/s, FrameSettings.roll_response: how fast roll follows the shot's framing roll; TUNE
    float smoothing_cap = 0.9f;      // rig_orientation.rs cap_smoothing (0x3f666666)

    bool valid() const noexcept {
        return ::dingosdk::s3cam::valid(pan) && ::dingosdk::s3cam::valid(tilt) && std::isfinite(max_pitch_degrees) &&
               max_pitch_degrees > 0.0f && max_pitch_degrees < 90.0f && std::isfinite(roll_response) &&
               roll_response >= 0.0f && roll_response <= 1000.0f && std::isfinite(smoothing_cap) && smoothing_cap >= 0.0f &&
               smoothing_cap <= 1.0f;
    }
};

// Reference points the shot weights mix, derived from the snapshot's root position (the snapshot
// has no skeleton). All metres, TUNE.
struct SubjectPointSettings {
    float board_drop = 0.9f;           // root -> board (SPIKES.md: board is ~0.9 m below the root riding)
    float anchor_height = 0.32f;       // board -> orbit anchor (Rust: subject.anchors[shot.anchor]); sets the standing camera height (Low ~0.59 m, High ~1.85 m above the ground); TUNE
    float head_height = 0.7f;          // root -> head
    float com_height = 0.05f;          // root -> centre of mass
    float trajectory_lookahead = 0.25f; // s ahead on the ballistic arc the "Trajectory" point sits while airborne

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(board_drop, 0.0f, 3.0f) && ok(anchor_height, -3.0f, 3.0f) && ok(head_height, -3.0f, 3.0f) && ok(com_height, -3.0f, 3.0f) &&
               ok(trajectory_lookahead, 0.0f, 2.0f);
    }
};

// The Native+ layers (decision 5). Everything is toggleable; amplitudes are TUNE.
struct NativePlusSettings {
    bool air_hold = true;          // hold the camera height in the air (s3_air hold delta added to the native Y)
    bool landing_dip = true;       // critically damped dip on touchdown
    bool shake = true;             // impulse + speed shake from s3_shake
    bool roll = true;              // the shot's framing roll (and shake roll)
    float dip_depth = 0.12f;       // m, deepest point of a full-strength landing; TUNE
    float dip_peak_time = 0.12f;   // s, time to the deepest point (the spring's 1/omega); TUNE

    bool valid() const noexcept {
        return std::isfinite(dip_depth) && dip_depth >= 0.0f && dip_depth <= 2.0f && std::isfinite(dip_peak_time) &&
               dip_peak_time >= 0.02f && dip_peak_time <= 2.0f;
    }
};

// Plumbing that is not a Skate 3 tunable but still must not be a magic number.
struct PipelineSettings {
    float accel_smoothing_time = 0.05f; // s, low-pass on the forward acceleration feeding pump/push; TUNE
    float push_accel_threshold = 3.0f;  // m/s^2, forward acceleration that counts as a push kick (upward crossing, on the ground); TUNE
    float push_window = 0.5f;           // s, push_state stays set this long after a kick; TUNE
    float repredict_interval = 0.1f;    // s between trajectory re-predictions while airborne (0: only at takeoff); TUNE
    float floor_clearance = 0.15f;      // m, the camera never sits lower than ground beneath the subject + this (0: off); TUNE. T8 adds real collision
    float teleport_distance = 10.0f;    // m, a snapshot farther than this from the last one is a cut: the camera resets; TUNE
    float resume_reset_time = 0.5f;     // s, after this long without a usable snapshot the camera resets when data returns; TUNE
    float no_lag_after_reset = 0.2f;    // s, the anchor follows with no lag this long after a reset (decision 2: "just reset"); TUNE
    int max_steps_per_update = 16;      // fixed (1/60 s) steps one update may run; extra time is dropped (spiral-of-death guard)
    float shake_distance_scale = 1.0f;  // multiplies the camera distance fed to the shake fade; 1 = the real distance

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(accel_smoothing_time, 0.0f, 5.0f) && ok(push_accel_threshold, 0.0f, 100.0f) && ok(push_window, 0.0f, 5.0f) &&
               ok(repredict_interval, 0.0f, 5.0f) && ok(floor_clearance, 0.0f, 5.0f) && ok(teleport_distance, 0.1f, 1.0e5f) &&
               ok(resume_reset_time, 0.0f, 60.0f) && ok(no_lag_after_reset, 0.0f, 5.0f) && max_steps_per_update >= 1 &&
               max_steps_per_update <= 240 && ok(shake_distance_scale, 0.0f, 100.0f);
    }
};

// ---- Player layers (Aescher's alpha feedback, docs/s3cam/PHASE2.md "Alpha 2"). FullS3 only unless
// a field says otherwise. Not Skate 3 tunables: S3Cam's own, every default is TUNE.

// Pitch prediction: where the camera looks, on top of the shot's framing.
struct LookSettings {
    bool landing_look = true;          // in the air, look down toward a landing below the takeoff (stairs, gaps to a lower level)
    float landing_look_strength = 0.6f; // 0..1: share of the way the look target moves toward the predicted landing point
    float landing_look_full_drop = 2.5f; // m the landing is below the takeoff for the full strength (scales linearly from 0)
    bool slope_look = true;            // on the ground, pitch with the slope: down when riding downhill, up uphill
    float slope_look_strength = 0.5f;  // 0..1: share of the incline angle added to the pitch
    float vertical_follow = 1.0f;      // 0..1: how much the pitch follows the skater's height (0: the pitch stays level with the anchor)
    float response_time = 0.25f;       // s: the look offsets ease in and out with this time constant

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(landing_look_strength, 0.0f, 1.0f) && ok(landing_look_full_drop, 0.1f, 50.0f) &&
               ok(slope_look_strength, 0.0f, 1.0f) && ok(vertical_follow, 0.0f, 1.0f) && ok(response_time, 0.0f, 5.0f);
    }
};

enum class ShoulderSide { Off, Manual, Auto }; // Off: centred. Manual: `side`, swapped by the player (L3). Auto: the stance's toe side
// Over-the-shoulder offset: the camera slides sideways along its own right axis, so the skater sits
// left or right of the screen centre. Applies in both presets.
struct ShoulderSettings {
    ShoulderSide mode = ShoulderSide::Off;
    float offset = 0.45f;   // m sideways when on a side
    int side = 1;           // Manual: +1 the camera sits to the skater's right (skater left of centre), -1 left
    bool goofy = false;     // Auto: the player's stance; regular rides with the toes to the right. Riding switch flips it
    float switch_time = 0.45f; // s for the camera to slide across to the other side (sine ease)

    bool valid() const noexcept {
        return std::isfinite(offset) && offset >= 0.0f && offset <= 3.0f && (side == 1 || side == -1) &&
               std::isfinite(switch_time) && switch_time >= 0.0f && switch_time <= 5.0f;
    }
};

// How tightly the camera follows: the anchor lag and the heading / elevation / pan / tilt smoothing.
struct FollowSettings {
    float strength = 1.0f;       // 1 = Skate 3. Above 1 follows tighter (less lag), below 1 looser
    bool dynamic = true;         // follow tighter as speed rises
    float dynamic_speed = 12.0f; // m/s where the dynamic boost is full
    float dynamic_boost = 0.5f;  // added to strength at that speed

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(strength, 0.2f, 4.0f) && ok(dynamic_speed, 0.5f, 60.0f) && ok(dynamic_boost, 0.0f, 3.0f);
    }
};

// Field of view on top of the base FOV (the game camera's own, or fov_override_deg). Every term eases
// with smoothing_time, so nothing snaps.
struct FovSettings {
    bool shot_fov = true;          // the shot's lens relative to the chase shot's (stock shots all share one lens: 0 today)
    bool speed_fov = true;         // widen with speed
    float speed_fov_degrees = 6.0f; // extra degrees at speed_fov_max
    float speed_fov_min = 5.0f;    // m/s where widening starts
    float speed_fov_max = 15.0f;   // m/s where it is full
    bool air_fov = true;           // widen in big airs (Skate 3's high-air feel)
    float air_fov_degrees = 8.0f;  // extra degrees at air_fov_full_height
    float air_fov_full_height = 2.5f; // m: predicted apex above takeoff for the full air FOV
    float smoothing_time = 0.35f;  // s, time constant of the FOV ease

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(speed_fov_degrees, 0.0f, 40.0f) && ok(speed_fov_min, 0.0f, 60.0f) && speed_fov_max > speed_fov_min &&
               ok(speed_fov_max, 0.1f, 80.0f) && ok(air_fov_degrees, 0.0f, 40.0f) && ok(air_fov_full_height, 0.1f, 50.0f) &&
               ok(smoothing_time, 0.0f, 5.0f);
    }
};

// The speed rumble ("shaky downhill / speed cam"), on top of the landing shake. Scales ShakeSettings'
// speed terms; the landing impulse is separate (shake_enabled switches both off).
struct SpeedShakeSettings {
    bool enabled = true;
    float strength = 1.0f;     // multiplies amplitude_max
    float top_speed = 15.0f;   // m/s for the full rumble (replaces amplitude_top_speed / frequency_top_speed)
    bool downhill_boost = true; // more rumble riding downhill
    float downhill_scale = 1.5f; // multiplier at downhill_full_degrees
    float downhill_full_degrees = 20.0f;

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(strength, 0.0f, 10.0f) && ok(top_speed, 0.5f, 80.0f) && ok(downhill_scale, 1.0f, 10.0f) &&
               ok(downhill_full_degrees, 1.0f, 80.0f);
    }
};

// Camera collision (T8 positioner): walls, poles and the ground between the skater and the camera.
struct CollisionSettings {
    bool enabled = true;
    float radius = 0.25f;        // m kept between the camera and a hit surface (pulled in along the ray)
    float min_distance = 0.5f;   // m: never closer to the look target than this
    float pull_in_time = 0.05f;  // s: how fast the camera moves in front of an obstacle (near instant)
    float release_time = 0.4f;   // s: how fast it eases back out once clear
    float ground_clearance = 0.3f; // m above the ground under the camera itself

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(radius, 0.0f, 2.0f) && ok(min_distance, 0.0f, 5.0f) && ok(pull_in_time, 0.0f, 2.0f) &&
               ok(release_time, 0.0f, 5.0f) && ok(ground_clearance, 0.0f, 3.0f);
    }
};

// The player's framing on top of every shot: distance, camera height and view pitch, and the
// manual close-up (Alpha 3 feedback).
struct FramingSettings {
    float distance_scale = 1.0f;        // multiplies every shot's camera distance
    float height_degrees = 0.0f;        // added to every shot's elevation: the camera sits higher (+) or lower around the skater
    float pitch_degrees = 0.0f;         // added to the view pitch: + looks up, - looks down
    bool manual_camera = true;          // manuals / nose manuals use the manual close-up
    float manual_distance_scale = 0.75f; // the manual shots' distance relative to the chase (a grind-like close-up, not too close)
    float manual_height_degrees = 0.0f; // added to the manual shots' elevation

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(distance_scale, 0.4f, 3.0f) && ok(height_degrees, -30.0f, 45.0f) && ok(pitch_degrees, -30.0f, 30.0f) &&
               ok(manual_distance_scale, 0.3f, 1.5f) && ok(manual_height_degrees, -30.0f, 45.0f);
    }
};

// Trick yaw: while the skater tricks, the camera swings round to the side to show the trick, holds that
// angle while tricks keep coming, and recentres behind after landing. Nothing snaps.
struct TrickYawSettings {
    bool enabled = true;
    float angle_degrees = 25.0f;  // how far round the camera swings
    int side = 0;                 // 0: auto (the shoulder side when Manual, else the stance's toe side), +1 right, -1 left
    bool in_air = true;           // airs and flip tricks
    bool on_grinds = false;
    bool on_manuals = false;
    float min_air_time = 0.2f;    // s in the air before the swing starts (a plain ollie stays centred)
    float in_time = 0.6f;         // s to swing out
    float hold_time = 0.5f;       // s after the trick before recentring; a new trick in this time keeps the angle
    float return_time = 1.5f;     // s to recentre behind

    bool valid() const noexcept {
        const auto ok = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
        return ok(angle_degrees, 0.0f, 90.0f) && side >= -1 && side <= 1 && ok(min_air_time, 0.0f, 3.0f) &&
               ok(in_time, 0.0f, 5.0f) && ok(hold_time, 0.0f, 5.0f) && ok(return_time, 0.0f, 10.0f);
    }
};

struct CameraSettings {
    CameraPreset preset = CameraPreset::FullS3;
    CameraAngle angle = CameraAngle::Low; // S3 Low / S3 High (the shot set)
    float fov_override_deg = 0.0f;        // > 0 replaces the computed (or native) field of view; 0 = off
    bool shake_enabled = true;            // master switch for the shake layer in both presets

    RigSettings rig;
    OrientationSettings orientation;
    AirSettings air;
    ShakeSettings shake;
    TrajectorySettings trajectory;
    GraphSettings graph;
    SubjectPointSettings points;
    NativePlusSettings native_plus;
    PipelineSettings pipeline;
    LookSettings look;
    ShoulderSettings shoulder;
    FollowSettings follow;
    FovSettings fov;
    SpeedShakeSettings speed_shake;
    CollisionSettings collision;
    FramingSettings framing;
    TrickYawSettings trick_yaw;

    bool valid() const noexcept {
        return std::isfinite(fov_override_deg) && fov_override_deg >= 0.0f && fov_override_deg < 180.0f && rig.valid() && orientation.valid() && air.valid() &&
               shake.valid() && trajectory.valid() && graph.valid() && points.valid() && native_plus.valid() &&
               pipeline.valid() && look.valid() && shoulder.valid() && follow.valid() && fov.valid() &&
               speed_shake.valid() && collision.valid() && framing.valid() && trick_yaw.valid();
    }
};

} // namespace dingosdk::s3cam
