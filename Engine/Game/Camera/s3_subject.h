#pragma once
// SPDX-License-Identifier: GPL-3.0-only
// Adapted from SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only):
// crates/skate-core/src/camera/manager_subject.rs (ManagerSubject) and
// crates/skate-game/src/camera/graph_subject.rs (CameraGraphSubject). The field set is the
// SubjectSnapshot frozen at Gate 0 (docs/s3cam/SPIKES.md); the native sources are read by
// Extension/Camera (T7/T8), this header is only the plain data they fill in.
#include "Engine/Game/Camera/s3_math.h"

#include <cmath>
#include <cstdint>

// What the camera knows about the skater on one frame. Pure data, no game types, so the camera core
// is unit-testable with scripted subjects.
namespace dingosdk::s3cam {

// skate. physics state values (context +0x1414), SPIKES.md Gate 0.
namespace physics_state {
inline constexpr std::uint32_t ride = 100;
inline constexpr std::uint32_t brief_after_air = 101;
inline constexpr std::uint32_t crouch = 103;
inline constexpr std::uint32_t pop = 200;
inline constexpr std::uint32_t air = 201;
inline constexpr std::uint32_t grind_first = 400;
inline constexpr std::uint32_t grind_last = 499;
inline constexpr std::uint32_t offboard = 504;
inline constexpr std::uint32_t brief = 601;
inline constexpr std::uint32_t post_grind = 701;
} // namespace physics_state

inline constexpr bool is_air_state(std::uint32_t state) noexcept {
    return state == physics_state::pop || state == physics_state::air;
}
inline constexpr bool is_grind_state(std::uint32_t state) noexcept {
    return state >= physics_state::grind_first && state <= physics_state::grind_last;
}

struct SubjectSnapshot {
    float time = 0.0f;                 // s, publisher clock (diagnostics only; the camera uses its own dt)
    Vec3 position{0, 0, 0};            // skater root, Y up
    Vec3 forward{0, 0, 1};             // unit, entity row 2
    Vec3 velocity{0, 0, 0};            // m/s
    std::uint32_t physics_state = physics_state::ride;
    bool onboard = true;               // false off the board (state 504); the camera then holds unless bailing
    bool bailing = false;              // the wipeout shot
    bool manual = false;               // native source still unknown (T7): may always be false in game
    int grind_side = 0;                // -1 ledge on the left, 0 unknown/flat, +1 on the right
    bool switch_stance = false;        // carried for the glue; no shot uses it yet
    Vec3 board_position{0, 0, 0};      // the board's real centre (its root physics body), when board_valid
    bool board_valid = false;          // false: use the estimate (root - board_drop)
    Vec3 ground_normal{0, 1, 0};
    float ground_clearance = 0.95f;    // m, root height above the ground beneath it (~0.95 riding)
    bool valid = false;                // false: the publisher had no trustworthy data this frame

    bool air() const noexcept { return is_air_state(physics_state); }
    bool grinding() const noexcept { return is_grind_state(physics_state); }
};

namespace subject_detail {
inline bool finite3(const Vec3& v) noexcept { return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]); }
} // namespace subject_detail

// True when the snapshot can drive the camera: flagged valid, every float finite, a forward with a
// direction, a ground normal with a direction.
inline bool usable(const SubjectSnapshot& s) noexcept {
    using subject_detail::finite3;
    return s.valid && std::isfinite(s.time) && finite3(s.position) && finite3(s.forward) && finite3(s.velocity) &&
           finite3(s.ground_normal) && finite3(s.board_position) && std::isfinite(s.ground_clearance) && length(s.forward) > 1e-4f &&
           length(s.ground_normal) > 1e-4f && s.grind_side >= -1 && s.grind_side <= 1;
}
} // namespace dingosdk::s3cam
