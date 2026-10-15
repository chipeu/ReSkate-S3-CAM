# Gate 1 review notes (Phase 1, pure math)

Things for the Gate 1 reviewer (the s3cam-reviewer subagent) to weigh: deviations from the Rust
reference that an implementer made on purpose, and the reasons given.

## T1 trackers (`s3_tracker.h`)
- Inside the umbra the max clamp and smoothing apply, as in `tracker.rs`. The plan text was wrong
  and has been corrected.
- Added guards: a non-finite target or dt, or invalid settings, leaves the state unchanged. `snap_keep_motion` ports
  the `clear_motion=false` reset branch.

## T2 shots (`s3_shot.h`, `s3_shots_default.h`)
- Not ported: blur, opacity, collision hint, quaternions and `reference_point()` (later cards).
  Heading is not blended (as in Rust). Options are `bool`, not `u8`.

## T3 trajectory (`s3_trajectory.h`)
- Fixed 1/60 s walk (the card), not Rust's variable step. A miss reports `status = Miss`, so callers
  check `landed()`. No back-face or start-point hit filtering.

## T4 shake (`s3_shake.h`)
- Distance fade 2.8 → 3.4 m (the Rust constants); the plan said 2.65 and has been corrected.
- Translation is camera-local; T6 rotates it into the camera basis.
- The x20 broken-bone impulse is a setting passed as `magnitude_scale` (not in `slow_motion.rs`).

## T5 rig and air (`s3_rig.h`, `s3_air.h`)
- **Recompute when the landing prediction moves by more than 1 mm:** restarts the transition and
  also keeps the Rust flag pull. The end height is takeoff height + delta (Rust uses the current
  reference height).
- **The transition is cut on touchdown** (Rust lets it finish). Check this one in game: it could
  show as a snap on landing.
- Not ported: the `flags&2` snap branch (replaced by an explicit `snap_height`), the `flag_656`
  smoothing, the `flag_608` offset decay, positioner/avoidance (T8), the 9-heading compass array,
  and the landing gate `positioner.flags & 0x80`.
- Compass blend weights are converted from per-1/60 s to the 120 Hz step.
- The distance target is clamped to the minimum distance (in Rust only collision uses it).
- The anchor roles (`push_state`, `push_kick`, `pump_acceleration`, `no_lag`) are names given by
  the implementer to unnamed native getters. T6 binds them to SubjectSnapshot.
