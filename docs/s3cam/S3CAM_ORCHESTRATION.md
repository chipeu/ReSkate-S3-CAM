# S3Cam — Skate 3 camera engine for ReSkate

**Orchestration plan.** Opus 5.5 orchestrates and reviews. Sonnet 5.5 writes the code.
Version 1 · 2026-10-15 · Owner: Aescher

Goal: an adjustable third-person camera for ReSkate (skate., Steam build `25414733`) that reproduces
how Skate 3's camera behaves on tricks, air and landings: lag and inertia while riding, steady
framing in the air, and a heavy impact on landing. It should match Skate 3 closely by default, and
every behaviour should be tunable in game.

Companion file: **`CLAUDE.md`**, placed at the root of the ReSkate fork. Claude Code reads it on start.
This work **requires Claude Code on the Windows PC**: building with MSVC, running the game and checking
logs all happen there. §9 covers the switch.

---

## 1. What the research found

### 1.1 The example mod (SunJay's Low Cam 1.1.2) is data-only

- Layout: `manifest.json`, `.reskate-studio-patch` (`skate_sha256=fbce74d5…b8f9`), `layout.toc`,
  `Win32/globals.toc`, per-level `.toc`, two `cas_01.cas` (51 MB + 13 MB), `initfs_win32`.
- It is a native Frostbite patch built with ReSkate Studio and contains no code. It retunes the
  game's own camera assets and adds options to the game's **Advanced Camera Settings** menu.
- The camera asset names in its CAS show how skate.'s camera is built. All of it is data:
  - Directors (an ESM state tree): `gameplay/cameras/dingoesmcameradirector_onboard_high` / `_low`,
    `dingocameradirector_onboardmastercamera`, `…_onboardgrinding`,
    `…_onboardairinclineperspectivecamera`, `…_onboardairinclineabovelandingperspectivecamera`,
    `…_offboardwipeoutcamera`
  - Framing sets: `gameplay/cameras/framingsets/onboardhighcameraframing`, `onboardlowcameraframing`,
    `…collisionframing`, `…megaparkframing` (fields include `GlobalScale`, `Yaw`, `Pitch`,
    `SideBiasFactor`, `SkaterMirrored`, `BoomOffsets`)
  - Rigs: `gameplay/cameras/rigs/camerarig_onboardfov`, `camerarig_offboard…`
  - Shakes: `gameplay/cameras/shakes/camerashake_onboard_landing`, `camerashake_onboard_speed`
  - Variables: `cameravariable_boomoffset`, `…_boommoverate`, `…_pitchbias`, `…_yawbias`,
    `…_maxanchordistancepersecond`, `…_followboard`, `…_fov`, and others
  - Settings updater: `camera_esmstate_camerasettingsupdater_class` (FOV, pitch, side bias,
    follow strength, shake, sensitivity)
- **What a data mod can't do:** add behaviour the native node types lack. That includes Skate 3's
  trajectory-aware air height, predictive landing framing, umbra/penumbra trackers and impulse
  shake shaping. Those need code.

### 1.2 ReSkate: mods can't carry code, but the DLL can own the camera

- Mods are data only. Custom Lua (`scripts/Custom`) is **switched off** in this version, and
  plugin DLLs aren't supported. **Native camera behaviour therefore has to live in `ReSkate.dll`**,
  through a fork or an upstream PR. Both repos are GPL-3.
- **Precedent:** first-person mode (`Extension/Skater/client_first_person.cpp`,
  `Engine/Game/Skater/first_person_spring.h`) already does what S3Cam needs:
  - Takes camera ownership through the Freecam path (`camera_mode_switch` 0x2f2c360, transform setter
    `camera_transform_setter` 0x2f8fa90, FOV at camera +`camera_fov_offset`).
  - Writes a full camera matrix every frame on the engine thread, at the render-pose handoff
    (`set_render_pose_listener`), so the camera matches the body being drawn.
  - Keeps its pure math in a testable header-only file (`first_person_spring.h`: springs, One-Euro
    filters) with unit tests in `Engine/Game/Skater/Test`.
  - Has a settings UI in the ImGui overlay (`Extension/UI/Overlay/skate_menu_skater.cpp`) and
    persists to the profile through `saved::` keys.
  - Already interacts with the game's camera-height cycle (R3 writes `UseHighCam`;
    `first_person_cycle.h`).
- **Skater signals ReSkate can already read** (`Engine/Game/Build/20260929/skater_state.h`,
  `client_noclip.cpp`, `no_bail.h`, `grind_exit.h`, `park_editor.h`):

  | Signal | Source |
  |---|---|
  | Physics state | context +0x1414. `200` PHYSICS_AIR, `201` KNOWN_AIR, offboard state from `no_bail` |
  | Board root body velocity / spin | board physics +0x20, body 0, +0x70 / +0x90 (m/s, rad/s) |
  | 26 rig bodies | ragdoll positions and velocity |
  | 395-joint animation pose | `AITrajectory` joint 1 = world placement; head chain known |
  | Bail / ragdoll flag | offboard state +0x18c; in-air +0x180 |
  | Grind state / exits | `grind_exit.h` |
  | Physics-world ray query | park editor surface probe (`park_editor.h`) |

- **Not yet known** (Phase 0 spikes): ground contact normal, manual state, stance
  (regular/goofy), trick-in-progress flag, and whether the native onboard camera keeps running
  while Freecam owns the view.

### 1.3 Skate 3 Rust Engine: the reverse-engineered camera to port

`SK8-ENGINE/skate-3-rust-engine` (GPL-3.0-only, by dumbad and contributors). The relevant code:

- `crates/skate-core/src/camera/` (~4.5k lines): a reconstruction of the TU3 Xbox 360
  CameraMan, with native addresses noted in comments.
- `crates/skate-game/src/camera/` (~2k lines): graph runtime, settings binding, stock shot data,
  Low/High angle.
- `docs/hails-additions/21-low-camera.md`: Low vs High shots, with measured values.

How the Skate 3 camera works, pipeline order per frame (`manager.rs`):

1. **prepare**: timing → **air/landing update** (`manager_air.rs`) → incline. The landing response
   reads the *previous* velocity and normal before incline overwrites them. **The order matters.**
2. **Camera graph** (data `Default_cameragraph` → `cameragraph_low.xml` / `_high.xml`). A
   priority state machine evaluates conditions and **selects a shot by name**. Conditions include
   `IsInOnBoardAir`, `SkaterIsGrinding`, `IsInManual`, `IsWipingOut`, `IsPreparingToJump`,
   `PredictedAirTime`, `PredictedLandingHeight`, `PredictedMaxHeight`, `LaunchInclineAngle`,
   `LandingInclineAngle`, `CameraSubjectSpeed` and `TimeSinceLastPlayerInput`
   (`graph_conditions.rs`).
3. **Shot blend** (`shot.rs`, `shot_manager.rs`, `manager_blends.rs`):
   - Shot fields: `distance`, `lens_length` (12 for every shot), `position_elevation`,
     `position_heading`, `framing[roll,yaw,pitch]`, `board_offset`, `smoothing[dir,elev,yaw,pitch]`,
     10 reference-point weights, and flags (`follow_subject_in_air`, `mirror_for_stance`,
     `use_drop_predictor`, `use_free_camera_stick`, …).
   - Transitions use a **sine ease**: `0.5 + 0.5·sin(π·t − π/2)`.
   - Blend trees choose between child shots by a subject value (for example speed). The value is
     filtered with `prev + (1−s)²·(raw−prev)`, clamped, and **not scaled by dt**.
4. **Rig** (`rig*.rs`):
   - **Anchor tracking** (`AnchorRigTracking`) gives **inertia and lag**. It follows the subject
     with a speed and acceleration clamp (`SubjectTrackerMaxSpeed/MaxAcceleration`), shaped by two
     lag curves: **push** (latch on push acceleration) and **pump** (input when acceleration exceeds
     `PumpingMinAcceleration`).
   - **Heading/elevation angle trackers** (`AngleTracker`) are critically-damped-like followers
     with a speed clamp, an acceleration clamp, and an **umbra/penumbra dead-zone**: inside the
     umbra the *max* acceleration clamp and smoothing apply (heavy smoothing near the target: the
     dead-zone feel), blending linearly to the *min* values at the penumbra (verified in tracker.rs, T1). Heading doubles its acceleration clamp in some states.
   - **Distance tracker** has normal and fast parameter sets; min distance tightens during a
     wipeout.
   - **Compass** (`compass*.rs`) auto-lines-up behind the direction of travel after
     `TimeBeforeAutoLineup`, with a speed-dependent dead-zone.
   - **Avoidance / positioner / drop predictor** handle collision lookahead, fat-line casts, and
     terrain-drop elevation before rolling off ledges.
5. **Air height transition** (`manager_air.rs`) is the core of the "air trick" feel:
   - At takeoff, while the trajectory is valid, the camera **does not chase the board upward**.
   - It interpolates its reference height from launch height to **predicted landing height** over
     the remaining trajectory time:
     `height_transition_{start,end,duration}`, with weight = `trajectory_time / duration`.
   - It ignores drops deeper than −3 m. It flags a change in the landing prediction when it moves
     by more than 1 mm.
   - The Rust test asserts the camera stays **below 2.8 m** on a flick while the air shot is
     selected.
6. **Orientation and framing** (`rig_orientation.rs`, `frame_composer.rs`): pan/tilt trackers with
   a pan umbra/penumbra and a smoothing curve, a max pitch, and dutch (roll) interpolation speed.
7. **Shake** (`shake.rs`, `shake_update.rs`) gives the **heavy landing**:
   - **Landing impulse** is `((clamp((v′ − vMin)/(vMax − vMin), 0, 1))²) × OneShotMagnitude`.
   - `v′` is the landing speed, attenuated by the grazing angle between velocity and −normal: an
     angle of 0 keeps the full value, and 90° gives zero.
   - The impulse only raises, never lowers, the current value. It decays by `(1 − OneShotDecay)`
     every update and snaps to 0 below 0.005.
   - While an impulse is active, frequency becomes `OneShotFrequency`.
   - **Speed shake**: amplitude and frequency curves (4×4 Bézier) over skater speed relative to
     `…TopSkaterSpeed`.
   - Rotation and translation come from recorded `.shk` samples (mean removed), scaled by
     distance: full at ≤ 2.8 m, fading to 0 by 3.4 m (shake_update.rs constants; T4).
   - The roll axis uses its own `DutchMultiplier`. The weight fades in and out at 5/s.
   - **Broken-bone slow-mo** fires a ×20 impulse.
8. **Lens**: `fov = f(lens_length, aspect)` (`manager_frame.rs`). Lens 12 for all stock shots.

**Stock shots** (Low vs High, from `21-low-camera.md`; distance m, angles °):

| shot | cam | dist | elev | pitch | board off | lens |
|---|---|---|---|---|---|---|
| chase_flat_slow | Low | 1.8 | 7 | −4 | 0.9 | 12 |
| chase_flat_fast | Low | 2.5 | 5 | −2 | 0.9 | 12 |
| chase_up_slow | Low | 2.1 | −5 | −10 | 0.9 | 12 |
| high_chase | High | 3.0 | 30 | 3 | 1.0 | 12 |
| high_chase2 | High | 4.4 | 26.6 | 5 | 1.0 | 12 |
| grind_flat_slow | Low | 1.5 | 7 | −10 | 0.6 | 12 |
| high_grind | High | 2.9 | 17 | 5 | 1.0 | 12 |
| far_manual / close_manual | Low | 2.35 / 1.1 | 13 / −5 | −2 / −8 | 0.9 / 0.5 | 12 |
| high_manual | High | 2.25 | 19 | 0 | 1.0 | 12 |

Measured standing camera height: **High 1.85 m, Low 0.59 m**.

**The rest of the stock tuning (tracker clamps, lag curves, shake magnitudes, `.shk` samples) is in
Skate 3's own data and isn't in either repo.** It can only come from the user's own Skate 3 copy,
converted by the Rust engine's setup (`camera`, `camera_tracker`, `camera_lag_profile`,
`camera_shake`, `camera_shots`, `camera_positioner`, `camera_droppredictor`, `camera_compass`
collections). The plan ships hand-tuned defaults and an optional local import (Phase 5). It never
redistributes EA data.

---

## 2. Approach

Three tracks. Track A ships early. Track B is the real engine.

| Track | What | Where | Gets you |
|---|---|---|---|
| **A: data retune** (optional, parallel) | Retune skate.'s own framing sets, boom, pitch, shakes and directors toward Skate 3 values | ReSkate Studio patch, like SunJay's mod | Skate 3 distances and angles, a stronger landing shake. No code, Thunderstore-shippable. No air or inertia logic. |
| **B: S3Cam native engine** (main) | Port the Skate 3 camera pipeline to C++ in a ReSkate fork. It owns the view through the proven first-person ownership path. | `ReSkate.dll` fork → upstream PR | The full behaviour: inertia, the air height transition, predicted landing, impulse shake and shot blending, all tunable live |
| **C: presets** | JSON presets plus an optional "import from my Skate 3 copy" tool | fork + tiny Python tool | Exact stock values for owners of Skate 3. Shareable tunes. |

**Ownership strategy for B (decided in Phase 0, spike S1):**

- **B1 (default): full override.** Own the camera like first person does, compute everything, and
  run our own collision (ray casts through the park editor's physics probe). This is proven to
  work. The cost is reimplementing collision.
- **B2 (fallback/hybrid): post-process.** Let the native onboard camera run, read its matrix (the
  observed `camera_callback` 0x178b690 / render view at `skater_render.h` `view_camera_offset`),
  and add S3 layers on top: air height hold, inertia offset, landing impulse and roll. This keeps
  native collision but is less faithful. Use it only if S1 shows B1 breaks something essential.

Scope rule: **S3Cam only drives the onboard gameplay camera.** Offboard, menus, replay editor,
Park Editor, Freecam, first person, spectate and buildkit stay native. It hands the camera back
instantly and cleanly, using the same disarm pattern as first person.

---

## 3. Architecture (Track B)

```
Engine/Game/Camera/                 pure, header-only, no Windows/ABI includes (unit-testable)
  s3_math.h                         vec/quat, wrap_angle, sine_blend, filter_blend_value
  s3_tracker.h                      ScalarTracker, AngleTracker (umbra/penumbra; port of tracker.rs/angle_tracker.rs)
  s3_shot.h                         Shot struct, interpolate(), reference_point()
  s3_shots_default.h                built-in shot table (Low + High), our tuned defaults
  s3_graph.h                        shot selector: priority states over SubjectSnapshot → shot name
  s3_trajectory.h                   ballistic prediction: air time, apex, landing height/normal
  s3_rig.h                          anchor (inertia/lag curves), heading/elevation/distance trackers, compass lineup
  s3_air.h                          height transition (launch→predicted landing), landing detection
  s3_shake.h                        impulse + speed shake, procedural sample bank (no EA .shk)
  s3_camera.h                       CameraMan: prepare → select → blend → rig → orient → shake → Frame
  s3_settings.h                     every tunable + validate() + JSON keys
  Test/s3_*_tests.cpp               unit tests (match the existing Test/ layout)

Engine/Game/Build/20260929/s3cam.h  any NEW addresses/offsets (ground normal, manual, stance…) with fingerprints

Extension/Camera/                   game-facing glue
  s3cam.h / s3cam.cpp               arm/disarm, ownership (reuses Freecam/first-person path), per-frame drive
  s3cam_subject.cpp                 reads skater signals → SubjectSnapshot (all reads SEH-guarded like first_person_read)
  s3cam_collision.cpp               ray/sphere casts via the physics probe → positioner + drop predictor
  s3cam_settings.cpp                saved:: keys, preset load/save (JSON in %LOCALAPPDATA%\ReSkate\camera\)
  console_commands.cpp              `s3cam on|off|preset <name>|set <key> <v>|dump`

Extension/UI/Overlay/skate_menu_camera.cpp   "S3 CAMERA" page: master toggle, Low/High, preset picker,
                                             grouped sliders (Framing, Inertia, Air, Landing, Shake, Collision),
                                             live debug readout (shot name, air prediction, impulse)
```

**Frame data flow:**

```
engine tick ─► animation update (worker) ─► render-pose handoff (engine thread)
                                                │
          s3cam_subject: SubjectSnapshot{pos, vel, spin, state, air, grind, manual, bail,
                          stance, ground normal, AITrajectory transform, board offset dir}
                                                │
          CameraMan::prepare (air/landing FIRST, then incline) ─► graph selects shot
          ─► shot blend (sine) ─► rig update (fixed 120 Hz substeps) ─► orient/frame
          ─► shake ─► Frame{matrix, fov}
                                                │
          SourceCameraTransform(camera, &matrix); write FOV  ─► renderer
```

**Rules that carry over from the Rust port:**

- **Fixed timestep.** Run the rig, trackers and shake at a fixed 120 Hz with an accumulator, and
  interpolate the output. Several Skate 3 filters, including the blend filter and the impulse decay,
  are per-update and not scaled by dt, so variable frame rates would change the feel.
- Run air/landing in `prepare` before the incline update. Landing must consume the previous
  velocity.
- When a transition starts, discrete shot flags come from the target shot. Floats are sine-blended.
- On reset (spawn, teleport, respawn after a bail, taking ownership): snap the trackers, zero the
  velocities, clear the shake, and teleport the rig.
- Port the algorithms, not bit-exact PowerPC quirks. Ignore `from_bits` constants that only exist
  to reproduce VMX rounding. Keep the semantics: umbra/penumbra, clamps, order of operations.

---

## 4. Phases and task cards

Each card is one Sonnet session or PR-sized commit. **Opus** writes or refines the card, then reviews
the diff against its acceptance criteria before the next card starts. Cards in the same phase with no
dependency can run in parallel subagents.

### Phase 0: Spikes (Opus-led, Sonnet assists; answers questions, no feature code)

- **S0. Fork and build baseline.**
  1. Fork `Dingo-Shenanigans/ReSkate` and create branch `feature/s3cam`.
  2. Build with the existing `CMakePresets.json` (MSVC x64).
  3. Run all existing tests, launch through the launcher, and confirm the unmodified build plays.
  - *Accept:* clean build, tests green, game runs, and `logs\ReSkate.log` has no new errors.
    Record the exact build commands in `CLAUDE.md`.
- **S1. Ownership spike (B1 vs B2).** Add a throwaway debug command, `s3cam_probe`:
  1. Take the camera through the first-person ownership path.
  2. Place it at a fixed offset behind `AITrajectory` (2.0 m back, 0.6 m up), looking at the
     board.
  3. Skate for 5 minutes across states: ride, grind, manual, air, bail, offboard.
  - Record: HUD intact? Trick scoring and replay intact? Native camera-height R3 still works? Does
    the native onboard camera keep ticking (read its matrix via the render view)?
  - *Accept:* a written verdict, B1 or B2, with log evidence in `docs/s3cam/SPIKES.md`.
- **S2. Signal hunt.** Find stable reads for: ground contact normal, manual state, stance, grind
  ledge side, trick-in-progress, pushing input, and the camera-reset input
  (`pia_gameplay_camerareset`). Start from `no_bail.cpp`, `grind_exit_control.cpp`,
  `physics_tuning*.cpp`, `hall_of_meat_skater.h` and the skater intent tree. If the ground normal
  can't be found, fall back to a short downward ray from the board root.
  - *Accept:* a table in `SPIKES.md` (signal, address/offset, how it was verified live, fallback),
    plus new constants in `Build/20260929/s3cam.h` with prefix fingerprints in the same style as
    `camera_observer.h`.
- **S3. Collision probe.** Wrap the park editor's physics ray/surface query as
  `cast_ray(from, to) → {hit, point, normal}`, and a fat-line sphere cast if available. Measure its
  cost (budget: < 0.3 ms for 10 casts).
  - *Accept:* a console command `s3cam_ray` prints hits, and the timings go in `SPIKES.md`.
- **S4. Gravity and units.** Measure skate.'s effective gravity and the board-root-to-deck offset.
  To get gravity: record board-root Y at 1 kHz during a flat ollie and fit a parabola.
  - *Accept:* the measured `g` (expected about 9.8 to 12 m/s²) recorded, since `s3_trajectory.h`
    needs it.

**Gate 0 (Opus):** choose B1 or B2, freeze the `SubjectSnapshot` fields, and update the cards below
if anything changed.

### Phase 1: Pure math core (Sonnet; parallel; no game needed, tests only)

- **T1. `s3_math.h` + `s3_tracker.h`.** Port `tracker.rs` / `angle_tracker.rs`.
  - *Tests:* converges with no overshoot when `overshoot_zeroes_velocity` is set; respects the
    speed and acceleration clamps; inside the umbra uses min-clamp smoothing; wraps at ±π; is
    stable with dt from 1/30 to 1/240.
- **T2. `s3_shot.h` + `s3_shots_default.h`.** Shot struct, sine interpolation, `filter_blend_value`
  and a blend-interval chooser. Default table:
  - Low: chase_flat_slow/fast, chase_up_slow, chase_down, grind_flat_slow, grind_ledge_l/r,
    far/close_manual, low_ollie (air), air_high (big air), landing, wipeout
  - High: high_chase, high_chase2, high_grind, high_manual, bl_high_air
  - Use the numbers from §1.3. Where the stock value isn't known, use a value marked `// TUNE`.
  - *Tests:* the blend at t = 0, 0.5 and 1; discrete flags taken from the target.
- **T3. `s3_trajectory.h`.**
  - From launch position, velocity, `g` and a ground-query callback, predict apex time and height,
    landing time, landing height and landing normal. Iterate by stepping the parabola at 1/60 s and
    ray-testing each segment, at most 3 s.
  - Expose `PredictedAirTime`, `PredictedMaxHeight`, `PredictedLandingHeight`,
    `HeightDistanceRatio`, and the launch and landing incline.
  - *Tests:* flat ground, a stair set (landing 2 m lower), a quarter pipe (re-entry), and a miss
    (no landing within 3 s).
- **T4. `s3_shake.h`.** Port `landing_impulse` and `update`.
  - Replace the `.shk` samples with a seeded, procedurally generated bank: band-limited noise,
    256 samples, mean removed, separate rotation and translation channels.
  - Speed curves are 4-point cubic curves in settings.
  - *Tests:* impulse ∝ fraction²; grazing landings give less; decay reaches 0; the impulse only
    raises; distance fade.
- **T5. `s3_rig.h` + `s3_air.h`.** Port these:
  - Anchor tracking with push/pump lag curves (8-point curves in settings)
  - Heading/elevation/distance trackers
  - Compass auto-lineup
  - Air height transition (launch → landing over the remaining time, ignoring drops deeper than
    −3 m, recomputed when the prediction moves by more than 1 mm)
  - Landing detection: air → ground with `dot(prev_vel, ground_normal) < 0` emits
    `(normal, prev_vel)` for the shake
  - *Tests:* a scripted ollie (camera max height stays < launch + 0.35·apex), landing fires one
    impulse, push acceleration lags the anchor then catches up, and a reset snaps everything.
- **T6. `s3_graph.h` + `s3_camera.h`.**
  - Priority selector, in order: Wipeout > Landing (0.25 s window after touchdown) >
    Air (big/normal by PredictedMaxHeight) > Grind (ledge L/R) > Manual (far/close by speed) >
    Chase (slow/fast blend by speed; up/down by incline). Low and High variants.
  - CameraMan pipeline in the order from §3, with the fixed-step accumulator. Output
    `Frame{world matrix rows right/up/back/pos, fov_deg, shot, debug}`.
  - *Tests:* a 600-tick scripted session (ride → ollie → land → grind → manual → bail) asserting
    the shot sequence, no NaNs, and continuous position (no step > 0.5 m per frame except on reset).

**Gate 1 (Opus):** review the numerics against the Rust sources line by line for semantics, and
run all tests in Release and Debug.

### Phase 2: Game integration (Sonnet; needs the PC; serial)

- **T7. `s3cam_subject.cpp`.** Build `SubjectSnapshot` each frame from the reads found in S2.
  Every read is SEH-guarded and validated (finite, sane ranges). Any failure means the snapshot is
  invalid, and the camera holds its last frame and then hands back after 0.5 s.
- **T8. `s3cam_collision.cpp`.** Positioner:
  - Sphere/fat-line cast from the anchor to the desired camera position, pulled in by
    `CollisionOffset`, never closer than MinDistance (tighter during a wipeout).
  - Drop predictor using 10 downward probes ahead along the horizontal velocity.
  - `CollisionInterpolationDuration` easing out.
- **T9. `s3cam.cpp`.** Arm and disarm, mirroring `first_person_*`:
  - Own the camera on the engine thread at the render-pose handoff, and write the transform and FOV.
  - Mutually exclusive with first person, Freecam, the Park Editor, spectate and replay. Disarm
    when any of them activates, restore the native FOV, and re-arm on return.
  - Offboard means hand back to native.
  - Integrate with the R3 height cycle: R3 toggles S3 Low/High when S3Cam is on.
- **T10. Settings and console.** Every `s3_settings.h` field gets a `saved::` key and validation.
  - Console: `s3cam on|off`, `s3cam angle low|high`, `s3cam preset <name>`,
    `s3cam set <key> <value>`, `s3cam dump`.
  - Presets are JSON files in `%LOCALAPPDATA%\ReSkate\camera\presets\`.
  - Built-in presets: `S3 Low` (default), `S3 High`, `Heavy Impact`, `Smooth Cinematic`,
    `skate. Native+` (a mild B2-style layer).
- **T11. Overlay page `skate_menu_camera.cpp`.**
  - **S3 CAMERA** tab: on/off, angle, preset picker, save-as.
  - Collapsible groups: Framing (per-shot distance, elevation, pitch, board offset, FOV), Inertia
    (anchor speed/accel clamps, push/pump curve scale), Air (height hold strength, follow in air,
    big-air threshold), Landing (impulse magnitude, min/max velocity, decay, frequency, landing-shot
    hold time, FOV kick), Shake (speed amplitude/frequency, rotation/translation/dutch multipliers),
    Collision (radius, min distance)
  - A live debug strip showing the current shot, blend %, predicted air time and landing Δh, impulse
    and speed.
  - Use the existing `toggle_row` and slider helpers, and follow the style of the first-person rows.

**Gate 2 (Opus):** in-game review using the checklist in §6. File issues as T-fix cards.

### Phase 3: Feel pass (Opus directs, Sonnet tunes, Aescher judges)

- **T12. Side-by-side capture.** Record the same lines (flat ollie, 7-stair, kickflip to manual,
  rail grind, big quarter-pipe air, bail) in Skate 3, using the Rust engine or a Skate 3 video, and
  in ReSkate with S3Cam. Compare camera height over time, distance, lag on pushes, landing dip and
  shake. Tune the `// TUNE` values. Each iteration changes one group only.
- **T13. Landing "weight" extras** (each toggleable, default on):
  - A short downward anchor dip proportional to the impulse (critically damped spring, about 0.12 s)
  - FOV kick (−2° to −4°, recovers in 0.25 s)
  - Optional ~60 ms hit-stop of camera motion only

  Skate 3 gets this mostly from the impulse shake plus anchor lag. These are labelled as extras,
  not stock behaviour.

### Phase 4: Hardening and release

- **T14.** Multiplayer: local camera only, nothing networked. Spectate and party follow stay native.
  Test hosting and joining.
- **T15.** Perf: under 0.2 ms per frame on average. No allocations per frame.
- **T16.** Build-update resilience: every address goes in `Build/20260929/s3cam.h` with a
  fingerprint check. If a check fails, the feature disables itself with a clear log line. It never
  crashes.
- **T17.** Docs: `Extension/Camera/S3CAM.md` (in the style of `GRIND_EXITS.md`), a README feature
  bullet, and credits: dumbad / SK8-ENGINE for the reverse-engineering, and SunJay for the low-cam
  precedent.
- **T18.** Release: a fork release zip (`ReSkate.dll` + launcher), and/or an upstream PR to
  Dingo-Shenanigans. Licence: Rust source is GPL-3.0-only and ReSkate is GPL-3, so ported code
  keeps the GPL-3 notice and attribution in file headers.

### Phase 5 (optional): Exact Skate 3 preset import

- **T19.** `tools/s3cam_import.py`: point it at the `data` folder produced by the Rust engine's
  setup from the user's own Skate 3 ISO. Read the camera collections and `camera_shots`, and write
  `S3 Stock.json`, including lag curves and shake curves, plus `.shk` samples converted to a local
  sample-bank file. The file stays on the user's PC and is never committed or redistributed.

### Track A (optional, parallel, no code): data retune via ReSkate Studio

- **A1.** Open `framingsets/onboardlowcameraframing`, `rigs/camerarig_onboardfov`,
  `shakes/camerashake_onboard_landing` and `…_speed`, plus the boom and pitch variables. Retune
  toward the §1.3 table: Low distance 1.5–2.5 m, elevation −5° to +7°, pitch −2° to −10°, a stronger
  landing shake.
- **A2.** Package with a stamp, manifest and README, test, then publish to Thunderstore as
  "S3 Framing" (a data mod).
- Track A is useful as an immediate improvement and as a fallback if the native work is
  rejected upstream.

---

## 5. Settings schema (v1, abbreviated; Sonnet completes it in T10)

```json
{
  "schema": 1, "name": "S3 Low", "angle": "low",
  "global": { "fov_deg": 0, "lens_length": 12, "fixed_hz": 120, "enabled_in_multiplayer": true },
  "shots": { "chase_flat_slow": { "distance": 1.8, "elevation": 7, "pitch": -4, "board_offset": 0.9,
             "smoothing": [0.8, 0.8, 0.8, 0.8] } },
  "inertia": { "anchor_max_speed": 0, "anchor_max_accel": 0, "push_curve": [[0,0],[1,1]],
               "pump_curve": [[0,0],[1,1]], "push_scale": 1, "pump_scale": 1, "pump_min_accel": 0 },
  "trackers": { "heading": {"speed_clamp_deg": 0, "accel_min_deg": 0, "accel_max_deg": 0,
                "umbra_deg": 0, "penumbra_deg": 0}, "elevation": {}, "pan": {}, "tilt": {},
                "distance": {"speed_clamp": 0, "smoothing": 0, "accel_clamp": 0} },
  "air": { "hold_height": true, "follow_in_air": true, "ignore_drop_below_m": -3,
           "big_air_height_m": 2.0, "gravity": 0 },
  "landing": { "impulse_magnitude": 0, "min_velocity": 0, "max_velocity": 0, "decay": 0,
               "frequency": 0, "landing_shot_hold_s": 0.25, "dip": true, "fov_kick_deg": -3, "hitstop_ms": 0 },
  "shake": { "amplitude_min": 0, "amplitude_max": 0, "top_speed": 0, "frequency_min": 0,
             "frequency_max": 0, "rotation_mul": 1, "translation_mul": 1, "dutch_mul": 1 },
  "collision": { "radius": 0.2, "min_distance": 0.8, "min_distance_wipeout": 0.5, "ease_out_s": 0.3 }
}
```

Fields shown as `0` are to be tuned in T12 or filled by the T19 import. `validate()` rejects
non-finite or out-of-range values, and the UI clamps sliders to the same ranges.

---

## 6. In-game acceptance checklist (Gate 2 / release)

- [ ] Riding: the camera lags slightly on a push and catches up smoothly. No jitter at 30, 60 or
      144 fps (fixed-step check).
- [ ] Carving: heading follows with a dead-zone, and a small wobble doesn't swing the camera.
- [ ] Ollie on flat: the camera rises much less than the board. The skater moves up in the frame.
- [ ] Gap or stair set: the camera begins easing down toward the predicted landing before
      touchdown.
- [ ] Landing: one sharp impulse sized to impact speed. Grazing landings on a bank are softer. It
      decays in under 0.5 s.
- [ ] Grind: the grind shot is selected; ledge left and right frame from the correct side.
- [ ] Manual: far or close shot by speed.
- [ ] Bail: the wipeout shot, then a clean handback when offboard.
- [ ] Walls and poles: the camera never clips through. It pulls in and eases back out.
- [ ] Toggling in the overlay, R3 Low/High, first person, Freecam, the Park Editor, replay and
      spectate all hand the camera over with no stuck camera.
- [ ] A preset save, reload and console `s3cam set` take effect without a restart.
- [ ] Wrong game build: the feature disables itself with a log line, and the game is unaffected.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| Full override (B1) breaks something native relies on, such as replay or scoring cameras | S1 spike decides. B2 is the fallback. Scope is limited to onboard. |
| Missing signals (ground normal, manual, stance) | Ray-based fallbacks, physics-state heuristics, and keeping the native camera for any state we can't read |
| No stock Skate 3 tuning in the repos | Hand-tuned defaults now; local import (T19) for owners |
| Upstream may not accept a large camera feature | Ship from the fork, and keep Track A as a data-only alternative |
| skate. updates the build | Everything goes behind `Build/20260929/` fingerprints; the feature disables cleanly |
| Frame-rate-dependent feel | Fixed 120 Hz step with interpolation |

---

## 8. Model routing

| Work | Model | Why |
|---|---|---|
| Spikes S1–S4, gate reviews, numerics review against the Rust code, feel direction | **Opus 5.5** | Reverse-engineering judgement, architecture calls |
| T1–T11, T14–T19 implementation, tests, UI | **Sonnet 5.5** | Well-specified cards |
| Parallel T1–T5 | Sonnet subagents, one per card | No shared files |
| T12 tuning loop | Sonnet edits values; Aescher judges feel; Opus arbitrates | Feel is subjective |

Hand-off protocol for each card:

1. Opus posts the card, quoted from this file, with any Gate updates.
2. Sonnet implements it, runs the tests, and replies with a summary, the diff stat and the test
   output.
3. Opus reviews and either approves or returns a fix list.
4. Commit with the card ID in the subject (`s3cam(T5): rig + air height transition`).

---

## 9. Switching to Claude Code

The work needs the Windows PC (MSVC build, game, logs), so it runs in **Claude Code**, not this chat.

1. On the PC, clone the fork, for example `F:\Dev\ReSkate`. Copy **`CLAUDE.md`** to the repo root,
   and this file to `docs/s3cam/S3CAM_ORCHESTRATION.md`.
2. Clone the reference repo next to it, read-only: `F:\Dev\skate-3-rust-engine`.
3. Unzip SunJay's mod to `F:\Games\ReSkate Mod Items\SunJays_Low_Cam` for reference.
4. Start Claude Code in the fork with **Opus 5.5** as the main model (`/model` → Opus). It
   delegates cards to Sonnet 5.5 subagents, as configured in `CLAUDE.md`.
5. First prompt:

   > Read CLAUDE.md and docs/s3cam/S3CAM_ORCHESTRATION.md. Run Phase 0, starting with S0. Stop at
   > Gate 0 and report the B1/B2 verdict and the signal table before starting Phase 1.
