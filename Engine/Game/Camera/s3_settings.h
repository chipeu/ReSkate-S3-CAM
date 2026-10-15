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

    bool valid() const noexcept {
        return std::isfinite(fov_override_deg) && fov_override_deg >= 0.0f && fov_override_deg < 180.0f && rig.valid() && orientation.valid() && air.valid() &&
               shake.valid() && trajectory.valid() && graph.valid() && points.valid() && native_plus.valid() &&
               pipeline.valid();
    }
};

} // namespace dingosdk::s3cam
