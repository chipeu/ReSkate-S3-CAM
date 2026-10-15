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
- ~~Compass blend weights are converted from per-1/60 s to the 120 Hz step.~~ Superseded: the step is now 60 Hz, so the weights apply directly.
- The distance target is clamped to the minimum distance (in Rust only collision uses it).
- The anchor roles (`push_state`, `push_kick`, `pump_acceleration`, `no_lag`) are names given by
  the implementer to unnamed native getters. T6 binds them to SubjectSnapshot.

## T6 graph and CameraMan (`s3_graph.h`, `s3_camera.h`, `s3_settings.h`, `s3_subject.h`)
- **Hand-written selector:** the stock graph is binary setup data. It keeps the card's priority
  order. Hysteresis, `landing_min_air_time` (0.1 s), the transition times and the thresholds are
  TUNE. High has no up/down, landing or ledge shots: High Landing reuses `high_chase`.
- **Subject:** interpolated between snapshots and never extrapolated, so it lags by up to one fixed step.
- **Orientation:** looks at the weighted reference point (framing only; since Gate 1 the orbit anchor is separate, root − board_drop + `anchor_height` 0.32); pan/tilt via AngleTracker with smoothing
  `1-(1-s)^2` capped at 0.9. The two-quaternion slerp, the pan umbra curve and the minimum pan
  smoothing are not ported. ~~Negative authored pitch looks up.~~ Fixed at Gate 1: positive authored pitch looks up, as in `frame_composer.rs`.
- **`board_offset`:** the implementer's reading is that it lifts only the look target (without it
  the head is cut off). It is the main framing assumption; check it in game.
- **Heading:** `position_heading` is blended in transitions (Rust doesn't, which would pop on ledge shots).
- **Prediction:** launched from the surface datum and re-run every 0.1 s in the air.
  `launch_clearance` carries the current-to-takeoff datum offset.
- **Landing shot:** fires on any air-to-ground change after 0.1 s of air (also on a landing into a grind).
- **Floor clamp** 0.15 m above the ground stands in for the T8 positioner.
- **Shake:** off while bailing; the translation isn't fed back into the rig. Fade distance:
  camera to anchor (FullS3), native camera to subject (NativePlus).
- **Distance fast set:** in the air, during the landing window and while bailing (a guess for native flag 668).
- **Not ported:** stance mirror, drop predictor, look stick, heading boost, positioner/avoidance,
  slow motion, blur/opacity, special and observer modes.
- **NativePlus:** roll is shot roll + shake roll; the air hold shifts world Y only; FOV passes through.
- **FOV formula** `2·atan(35/(2·lens))/sqrt(aspect+1)` gives 66.6° at 16:9 (`manager_frame.rs`).
  Whether the game's +0xac wants vertical degrees is still to check at T9.
- ~~Measured: about 0.12 m bounce around landing from the weights.~~ Gone since Gate 1: the anchor no longer depends on the weights (test `test_anchor_independent_of_weights`).

## Gate 1 review (independent reviewer, 2026-10-15): pass with fixes
No blockers. Core ports were checked line by line against the Rust and found faithful. Fixes
applied in the Gate 1 fix commit:
1. Framing pitch sign was inverted (`frame_composer.rs:95` `pitch = -framing[2]`).
2. Heading/elevation smoothing now comes from the shot (`manager_rig.rs:73-76`) instead of a
   global constant.
3. The air transition base is taken once per flight (a prediction Miss re-based it mid-air).
4. The predicted max height is latched per flight (big air flipped back to normal on the way down).
5. Huge dt overflowed the step cast and froze the camera.
6. A separate orbit anchor (the camera sat ~0.3 m low against the published standing heights).
7. The fixed step is now exactly 60 Hz (the Rust `STEP` = 1/60); the plan's 120 Hz was wrong.

Carried into later cards as acceptance items:
- **T7:** is state 601 airborne? (If it is, each one fires a false landing.) Make the air-state set
  data-driven. Interpolate snapshots on the publisher's physics time, not the frame fraction; add a
  stair-step (60 Hz physics at 144 fps) session test.
- **T8:** a physics ray may hit the takeoff surface at t≈0. Lift the launch point (~5 cm, via
  `launch_clearance`) or ignore a first-segment hit while v·n > 0.

### Gate 1 fixes: results
- All 11 suites pass (g++ strict, clang, ASan/UBSan) with regression tests for findings 1–7.
- Standing camera height: **Low 0.589 m, High 1.870 m** (published: 0.59, 1.85).
- Scripted session (shot sequence unchanged at 30/60/144 fps): max step 0.300 / 0.167 / 0.069 m;
  lowest camera 0.56 m (was 0.26).
- Heading and elevation now use the shot's own smoothing (about 0.98 near the target for the chase
  shots, as in the Rust): much heavier than before. The authored smoothing values are TUNE; check
  the feel first at T12.
