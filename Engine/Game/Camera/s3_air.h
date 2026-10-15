#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/manager_air.rs (ManagerState::update_air: height_transition_start /
// end / duration / weight, the -3 m drop cutoff, the landing-height change flag, the landing
// response that reads the PREVIOUS velocity and normal) and rig_tracking.rs
// (ReferenceHeightTracking::update, the transition and hold branches). Semantics are ported; the
// bit-exact VMX constants are replaced by ordinary float constants (CLAUDE.md hard rule 6).
#include "Engine/Game/Camera/s3_math.h"
#include "Engine/Game/Camera/s3_trajectory.h"

#include <algorithm>
#include <cmath>
#include <optional>

// The "air trick" feel of S3Cam (card T5). While the board is airborne the camera must not chase it
// upward: its reference height eases from the takeoff height to the predicted landing height over
// the remaining flight time. On touchdown the previous frame's velocity and ground normal are
// handed to the shake. Pure, header-only, no allocation; call update() once per fixed step, in the
// "prepare" stage, before the incline update (CLAUDE.md hard rule 4).
namespace dingosdk::s3cam {

struct AirSettings {
    float max_ignored_drop = 3.0f;      // m. A landing more than this below takeoff gets no transition (manager_air.rs)
    float change_threshold = 0.001f;    // m. A landing-height change above this recomputes the transition (1 mm)
    float min_remaining_time = fixed_step; // s. Do not arm a transition with less flight than this left
    bool hold_height_in_air = true;     // true: the reference height does not rise with the board (Rust height mode 1)

    bool valid() const noexcept {
        return std::isfinite(max_ignored_drop) && max_ignored_drop > 0.0f && max_ignored_drop <= 100.0f && //
               std::isfinite(change_threshold) && change_threshold > 0.0f && change_threshold <= 1.0f && //
               std::isfinite(min_remaining_time) && min_remaining_time >= 0.0f && min_remaining_time <= 1.0f;
    }
};

struct AirInput {
    bool grounded = true;          // physics says the board is on the ground (not the 200/201 air states)
    bool trajectory_valid = false; // a prediction exists and it landed (TrajectoryPrediction::landed())
    // Predicted landing height minus takeoff height, both at the SAME datum. A prediction launched
    // from a point `c` above the surface under it reports landing - launch = surface drop - c, so
    // set_prediction() adds that clearance back.
    float landing_height_delta = 0.0f;
    float trajectory_time = 0.0f;     // s since takeoff
    float trajectory_duration = 0.0f; // s, predicted air time
    Vec3 velocity{0, 0, 0};           // subject velocity this step
    Vec3 ground_normal{0, 1, 0};      // ground normal under the subject this step
    float anchor_height = 0.0f;      // world Y the reference height follows on the ground
    bool follow_anchor_in_air = false; // the active shot has follow_subject_in_air
    bool snap_height = false;          // jump straight to the anchor height this step (a cut)

    // Fills the trajectory fields from a T3 prediction. `launch_clearance` is how far the launch
    // point sat above the surface beneath it (0 when launched from the surface). A Miss or Invalid
    // prediction clears trajectory_valid.
    void set_prediction(const TrajectoryPrediction& prediction, float launch_clearance = 0.0f) noexcept {
        trajectory_valid = prediction.landed();
        landing_height_delta = trajectory_valid ? prediction.predicted_landing_height + launch_clearance : 0.0f;
        trajectory_duration = trajectory_valid ? prediction.predicted_air_time : 0.0f;
    }
};

// What the shake's landing_impulse(normal, velocity, ...) takes (manager_air.rs returns the pair).
struct LandingEvent {
    Vec3 normal{0, 1, 0};
    Vec3 velocity{0, 0, 0};
};

struct AirOutput {
    float reference_height = 0.0f;
    float transition_weight = 0.0f; // trajectory_time / duration, 0 on the ground; the compass reads it too
    bool transitioning = false;
    bool prediction_moved = false;
    std::optional<LandingEvent> landing; // set on the single step that touches down
};

class AirHeight {
public:
    // Teleport / respawn: snap the height, drop any transition and forget the previous frame.
    void reset(float height, bool grounded = true) noexcept {
        *this = AirHeight{};
        if (!std::isfinite(height)) return;
        height_ = height;
        initialized_ = true;
        prev_grounded_ = grounded;
    }

    AirOutput update(float dt, const AirInput& in, const AirSettings& set = {}) noexcept {
        AirOutput out;
        if (!(dt > 0.0f) || !std::isfinite(dt) || !std::isfinite(in.anchor_height) || !set.valid()) {
            fill(out);
            return out;
        }
        if (!initialized_) {
            height_ = in.anchor_height;
            initialized_ = true;
        }
        const bool ground = in.grounded;
        float weight = 0.0f;

        if (ground) {
            // Touchdown: the response reads last step's velocity and normal, before this step's
            // incline overwrites them (manager_air.rs). Strictly toward the surface.
            if (!prev_grounded_ && dot(prev_velocity_, prev_normal_) < 0.0f)
                out.landing = LandingEvent{prev_normal_, prev_velocity_};
            // Deviation: Rust lets an unfinished transition run on after landing; cut it so the
            // camera follows the anchor from the touchdown step on.
            in_flight_ = tracking_ = armed_ = moved_ = false;
            transition_time_ = transition_duration_ = 0.0f;
        } else {
            if (!in_flight_) {
                // First airborne step of the flight: the height now is the takeoff reference height
                // every (re)computed end is relative to. Taken once per flight; a later prediction
                // Miss does not re-base it.
                in_flight_ = true;
                base_height_ = height_;
            }
            weight = weight_; // held across a step with no usable prediction
        }
        if (!ground && in.trajectory_valid && std::isfinite(in.landing_height_delta) &&
            std::isfinite(in.trajectory_duration) && in.trajectory_duration > 0.0f &&
            std::isfinite(in.trajectory_time)) {
            weight = clamp01(in.trajectory_time / in.trajectory_duration);
            bool recompute = false;
            if (tracking_) {
                if (std::abs(in.landing_height_delta - previous_delta_) > set.change_threshold) {
                    moved_ = true; // flags_517 |= 8: pull toward the anchor as touchdown nears
                    recompute = true;
                }
            } else {
                tracking_ = true;
                moved_ = false;
            }
            previous_delta_ = in.landing_height_delta;
            const float remaining = in.trajectory_duration - in.trajectory_time;
            if (in.landing_height_delta <= -set.max_ignored_drop) {
                // Too deep to follow down: no transition (a recompute into this range cancels one).
                if (recompute) {
                    armed_ = false;
                    transition_time_ = transition_duration_ = 0.0f;
                }
            } else if ((!armed_ || recompute) && remaining > 0.0f && remaining >= set.min_remaining_time) {
                transition_start_ = height_;
                transition_end_ = base_height_ + in.landing_height_delta;
                transition_duration_ = remaining;
                transition_time_ = 0.0f;
                armed_ = true;
            }
        }
        // No usable prediction this step (a Miss or Invalid): hold the current target. The transition,
        // the tracking state and the base height all carry on until the board is grounded.

        step_height(dt, in, set, ground, weight);
        weight_ = weight;
        prev_grounded_ = ground;
        prev_velocity_ = in.velocity;
        prev_normal_ = in.ground_normal;
        fill(out);
        return out;
    }

    float height() const noexcept { return height_; }
    bool transitioning() const noexcept { return transition_duration_ > 0.0f && transition_time_ < transition_duration_; }
    float transition_start() const noexcept { return transition_start_; }
    float transition_end() const noexcept { return transition_end_; }
    float transition_duration() const noexcept { return transition_duration_; }
    float transition_time() const noexcept { return transition_time_; }
    bool prediction_moved() const noexcept { return moved_; }

private:
    void fill(AirOutput& out) const noexcept {
        out.reference_height = height_;
        out.transition_weight = weight_;
        out.transitioning = transitioning();
        out.prediction_moved = moved_;
    }

    // ReferenceHeightTracking::update, with smoothing 1 (take the whole step).
    void step_height(float dt, const AirInput& in, const AirSettings& set, bool ground, float weight) noexcept {
        const float old_height = height_;
        const float anchor = in.anchor_height;
        float target = old_height;
        const bool blending = !in.snap_height && transitioning();
        if (blending) {
            // transitioning() already means duration > 0; the floor only keeps MSVC's optimizer from
            // seeing a zero divisor on an inlined path (C4723).
            const float fraction = clamp01(transition_time_ / std::max(transition_duration_, 1e-6f));
            target = transition_start_ + fraction * (transition_end_ - transition_start_);
            if (moved_) {
                const float pull = weight * weight; // the prediction is unsettled: lean on the anchor
                target = (1.0f - pull) * target + anchor * pull;
            }
        } else if (ground || in.follow_anchor_in_air || !set.hold_height_in_air) {
            target = anchor;
        } else if (in.snap_height || old_height > anchor) {
            target = anchor; // hold: never rises with the board, still comes down with it
        }
        height_ = target;
        transition_time_ += dt;
    }

    float height_ = 0.0f;
    bool initialized_ = false;
    float transition_start_ = 0.0f, transition_end_ = 0.0f;
    float transition_duration_ = 0.0f, transition_time_ = 0.0f;
    float base_height_ = 0.0f, previous_delta_ = 0.0f, weight_ = 0.0f;
    bool in_flight_ = false;   // an airborne step has happened since the last touchdown (base_height_ is taken)
    bool tracking_ = false, armed_ = false, moved_ = false;
    bool prev_grounded_ = true; // true so the first step cannot report a landing
    Vec3 prev_velocity_{0, 0, 0};
    Vec3 prev_normal_{0, 1, 0};
};

} // namespace dingosdk::s3cam
