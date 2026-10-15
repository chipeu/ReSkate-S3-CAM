# S3Cam Phase 0: spike findings

Status: **first in-game run done (2026-10-15, log `ReSkate.log` 19:55–20:01).** S1 and S3 answered;
S4 needs a rerun (see the 10 Hz bug under S1). Code reading is done (below). Every
cell marked _pending_ needs a log line from Aescher's PC. Gate 0 is decided from this file.

How the work is split: a Linux cloud session writes code and checks it (pure-math tests with g++ and
clang, plus a MinGW syntax-only pass over the Windows sources: `docs/s3cam/linux_syntax_check.sh`).
Aescher builds with MSVC, plays, and sends back `logs\ReSkate.log`.

---

## S0. Fork and baseline build

The commands in `CLAUDE.md` were missing one thing: **the unit tests are off by default.** Every test
`add_executable` sits behind `DINGOSDK_BUILD_MULTIPLAYER_TESTS AND WIN32` (CMakeLists.txt:165), and
that option is `OFF`. Without it, `ctest` finds nothing and "tests green" means nothing.

```powershell
cmake --preset vs2022-x64 -DDINGOSDK_BUILD_MULTIPLAYER_TESTS=ON
cmake --build --preset release
ctest --test-dir build/vs2022-x64 -C Release --output-on-failure
```

- Tests that need the game files (`physics_tuning`, `game_textures`, `park_editor_ui`) take
  `-DDINGOSDK_TEST_GAME_ROOT=<skate. folder>`. Without it they skip their game half and still pass.
- The build uses `/W4 /WX`: any new warning fails it.
- New tests in this branch: `s3cam_gravity_fit`, `s3cam_probe_pose`. Both pass on Linux under g++
  (with `-Wconversion -Wsign-conversion -Wshadow`, and again under ASan/UBSan) and clang.

| Check | Result |
|---|---|
| Release build, no warnings | yes (after fixing the Spotify configure step, `cmake/Runtime.cmake`) |
| `ctest` all green (count) | _pending: Aescher to paste the summary line_ |
| Game launches with the new DLL, `ReSkate.log` clean | yes |

## S1. Ownership: B1 (full override) or B2 (post-process)

**From the code (settled):**

- Ownership is the camera controller's mode switch. `camera_mode_switch` 0x2f2c360 is controller
  vtable slot +0xb8: mode 0 is the game's camera, mode 1 is the FreeCamera. The controller lives at
  local player manager +0x710; `source_camera_snapshot` verifies the whole chain every tick.
- First person, Freecam, party spectate and the Park Editor all use this same mode-1 path, so taking
  the view this way is proven. The probe uses it unchanged.
- **The selector keeps both cameras.** In mode 0 the view's active camera (view +0x2b0) has
  `engine::camera_vtable` 0x6255870. It is the game's director-driven camera, and its matrix is at
  +0x50 (`debug_view_matrix`). The probe records that pointer before switching to mode 1 and keeps
  reading it. **If it keeps moving with the skater, the native onboard camera still runs underneath
  us, so B2 is possible and B1 can fall back to it per state. If it freezes, the director stops when
  it loses the view: B2 is impossible and B1 must handle every onboard state itself.**
- The FOV is the FreeCamera's +0xac; first person's save and restore carries over as-is.
- Known probe limitation, not a verdict input: the probe writes its pose in the client tick, which
  runs before this frame's animation, so it trails the skater by one frame and may judder slightly
  at speed. T9 writes at the render-pose handoff, as first person does.

**What the probe logs** (`s3cam_probe 1`, `Channel::skater`, grep `s3cam_probe`):

| Line | Meaning |
|---|---|
| `armed: native camera 0x…, handedness ±1` | the game camera being watched; ±1 is the matrix convention (right × up = ±backward), which S3Cam needs |
| `t=… native moved N/M … dist D m` (every second) | the native camera changed on N of M ticks; D is its mean distance from the skater root. Moving with D steady (~2–4 m) means it is still tracking. Frozen, or D growing as you skate away, means it stopped |
| `summary (…)` | totals when the probe stops |

**The 5-minute session (Aescher):** `s3cam_probe 1`, then ride, push, carve, ollie, flip, grind a
rail and a ledge, manual, bail, walk (off board), get back on, and press R3 twice. Then
`s3cam_probe 0`. Note:

| Question | Answer |
|---|---|
| HUD (trick names, score popups, minimap) intact? | **yes** (Aescher) |
| Trick scoring still counts? | **yes** (Aescher) |
| Replay editor afterwards: recorded clip and its cameras OK? | **yes**, the replay shows the skater moving smoothly (Aescher) |
| R3 height: does `native … dist` change after R3? | **yes**: the native camera's mean distance from the root went from ~1.8 m to ~2.3–2.8 m partway through the session and stayed there. The game's height setting kept working underneath the probe |
| Native camera kept moving (`moved N/M` with N ≈ M)? | **yes: 1516 of 1517 ticks**, 0 unreadable, over 168.7 s |
| Anything stuck, black, or crashing on `s3cam_probe 0`? | **no** (Aescher; log shows `summary (camera restored)`) |
| Feel | choppy camera, stuttering skater: **a probe bug, fixed** (below) |

**The 10 Hz bug.** `Runtime/client_tick.cpp` runs the debug tick every frame only while
`free_camera`, `first_person` or `noclip` is set; otherwise it runs every 100 ms. The probe is kept
out of `free_camera` so it does not capture keyboard and mouse input, so it ran at about 10 Hz:
about 10 ticks a second against 60 Hz physics (`dt_phys=0.0167`). Fixed by adding
`debug_model.s3cam_probe` to that condition. This is not an ownership problem: the replay, which
doesn't use the probe, looked smooth.

**Verdict (proposed for Gate 0): B1, with B2 available.** Taking mode 1 broke nothing
(HUD, scoring and replay were intact, and hand-back was clean). The game's own camera keeps running
underneath, including R3 height changes, so its matrix is a live fallback: S3Cam can own every
onboard state (B1) and can still read or blend the native pose for states it does not handle yet,
or during hand-overs. Retest the smoothness after the 10 Hz fix before freezing this.

## S2. Signals for `SubjectSnapshot`

Already known from the repo, plus what the probe logs:

| Signal | Source | Verified | Fallback |
|---|---|---|---|
| Skater root position / transform | `debug_skater`: entity transform collection, rows {right, up, ?, pos} | used by noclip, Freecam | n/a |
| Skater forward axis | entity row 2 is **forward** (`row2.travel` mean **+0.85** over 1077 samples; +1.00 riding straight; lower while carving, grinding and spinning) | **yes** | direction of travel |
| Board root velocity / spin | board physics body 0 +0x70 / +0x90 (`skater_state.h`) | used by boosts | n/a |
| Board root height | board body 0 +0x54 (noclip's "board altitude") | used by noclip | n/a |
| Board root full position | board body 0 +0x50..+0x58: **confirmed**. Within ~0.3 m of the root horizontally, and ~0.9 m below it while riding (root y 201.0, board y 200.1) | **yes** | skater root |
| Physics state | context +0x1414. Seen live: **100 riding**, 103 crouch, 200 pop, 201 air, 400–404 grind, **701** (~0.12 s right after a grind, then 100 or 201), **601** (~0.23 s between two airborne stretches; not a manual), **504 offboard: bails and walking both** (300 never appeared) | **yes** | n/a |
| **Manual** | not seen in run 1: either no manual was held, or a manual stays in state 100. Rerun with a held manual | _pending_ | treat as chase |
| `IsPreparingToJump` | state 103 (crouch) | grind_exit.h | n/a |
| Grind / ledge side | state 400–499 for grinding. The side isn't known yet; candidates: launch side in grind_exit, or the rail direction vs the skater's right | grinding: yes, side: _pending_ | frame from the skater's right |
| Stance | context +0x13c4 bit 5: 1 = riding switch (verified for a goofy skater only). Run 1: stayed 0 the whole session | partial | assume regular |
| Ground contact normal | **3 down-rays work**: flat 0.7°, ramps 41.3° and 59.6°. The entity up row stays near vertical (≤2°) while riding, so it is **not** the ground normal | **yes (rays)** | n/a |
| Launch trajectory | `set_trajectory` 0x4752aa0 (trainer_jump), called at pops with the launch velocity | trainer | board velocity at state 200 |
| Trick in progress / pushing input / camera reset input | not found in the repo yet | _pending_ | timers on state; pad read |

## S3. Collision probe

**From the code:** the park editor's surface probe (`Extension/Objects/ParkEditor/park_editor_surface.h`)
wraps the game's own **camera ray query** 0x26afdc0 (filter 0x40080303), with fingerprints in
`park_editor.h` `surface_contracts`. The client physics world comes from
`placements_runtime().context` on the client update (the server context's world is null). Things to
note for T8:

- The result gives a hit **fraction only, with no normal**, so the normal comes from three rays.
- The dropper's **sphere query** 0x26c0fd0 shares the implementation, but there's no signature or
  fingerprint for it in the repo. Fat-line casts need it fingerprinted, or several rays instead.
- `cast_surface` allocates a `std::vector` per call. T8 needs an allocation-free variant (hard rule:
  no per-frame allocation).

**Run:** stand somewhere flat, `s3cam_ray`. Then on a ramp, and beside a wall. Each run logs ground
distance, normal and tilt, and times 30 batches of 10 casts at 2.5 m (camera-like rays).

| Where | ground / normal | 10 casts mean / max (ms) | budget 0.3 ms |
|---|---|---|---|
| flat | 0.950 m below root, 0.7° | 0.020 / 0.024 | 15× under |
| ramp | 1.008 m below root, 41.3° | 0.017 / 0.025 | 12× under |
| steep ramp / by a wall | 1.075 m below root, 59.6° | 0.017 / 0.023 | 13× under |

About 2 µs per ray. Collision is cheap enough for a full positioner and drop predictor every
frame. In the timing batches, 0 of 300 rays hit on flat ground and 60–120 of 300 hit near
slopes, as expected. The skater root is ~0.95–1.08 m above the ground: the camera anchor should
use the root or a fixed offset from it, not the board.

## S4. Gravity and units

The probe records the board root's height on every new physics step while airborne (state 200/201).
On touchdown it fits a parabola (`Engine/Game/Camera/s3_gravity_fit.h`, which trims 3 samples at
each end) and logs `air: … g=… rms=…`. The summary prints the median over all arcs.

- The plan asked for 1 kHz sampling. The tick gives one sample per frame (60–144 Hz). The tests show
  that's plenty: a clean arc at 30 Hz recovers g to 1e-4.
- Samples are timed by wall clock. If `rms` is over ~1 cm, the physics step and frame timing are
  beating: cap the game at 60 fps and repeat.
- Do 5 or more flat ollies and a couple of drops (stairs, a gap) so the fit covers different airtimes.

| Measurement | Value |
|---|---|
| g (median of N arcs) | _pending: run 1 sampled at 10 Hz (the bug above), so every arc had 2–13 samples and none could be fitted. Rerun_ |
| rms of a typical arc | _pending_ |
| physics dt (`dt_phys` in the log) | **0.0167 s (60 Hz)** |
| board root vs skater root height (`board_h` − `root.y`) | **≈ −0.9 m** riding |

---

## Gate 0 report (filled in after the run)

- B1/B2 verdict: **B1 with a live native fallback** (proposed; recheck smoothness after the fix)
- Frozen `SubjectSnapshot` fields: _pending manual + gravity rerun_
- Ray-cast cost: **~0.02 ms per 10 casts** (budget 0.3)
- Measured gravity: _pending rerun_
- Camera matrix convention: rows {right, up, backward, position}, right × up = **+backward**
- Card changes: T3 should also read `skate-game/src/camera/trajectory.rs` and
  `skate-core/src/camera/trajectory_query.rs` (gravity is a query input there). T8 should read
  `skate-game/src/camera/collision.rs` and `world_query.rs`. None of these are named in the plan.
