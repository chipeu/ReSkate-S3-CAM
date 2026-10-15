# S3Cam Phase 0: spike findings

Status: **three in-game runs done (2026-10-15).** S2, S3 and **S4 (g ≈ 10.1 m/s²)** answered.
Ownership: mode 1 shows the pose but freezes the replay editor; mode 2 (run 3) keeps everything
native, but its write came too late to show. Run 4: the write inside the update is replaced
by the caller (it applies the update's output). Run 5: the output does not carry the view; the camera holds a
second copy at +0x10. Next: run 6 = **S1e**, write both copies. `ctest`: **46/46 passed** (MSVC, Release). Code reading is done (below). Every
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
| `ctest` all green (count) | **46/46 passed** (run 3 build) |
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

**Run 2 (every-frame tick):** Aescher: "Character is now smooth, camera probe also smooth." The native
camera updated on 9887/9999 ticks. Two problems, both caused by **taking mode 1**:

- **The right stick does nothing off board.** Mode 1 shows the FreeCamera, so the game camera's stick
  orbit is not what the player sees.
- **The replay editor froze (no movement, no tracking).** In the log, from 20:11:09 to 20:11:27,
  "Freecam and Noclip unavailable: Waiting for a verified local camera update". The tick is not
  ready, so the probe stops writing, but mode 1 stays selected and holds the last pose. Handing
  back needs that same verified phase, so it cannot happen there either. First person takes mode 1
  the same way and most likely has the same problem upstream.

### S1b. Own the pose, not the selection (`s3cam_probe 2`)

Run 1 showed the game's camera keeps updating under mode 1. So instead of switching to the
FreeCamera, mode 2 leaves mode 0 selected and **overwrites the game camera's view rows (+0x50)
after its update**, in the same place in the tick where Freecam writes. It writes nothing when the
tick is not ready (menus, replay editor, loading), when another camera is showing (Freecam, first
person, spectate, Park Editor) or when the skater is off board (504). In each of those cases the
game's camera, right stick included, is simply what you see.

The log line `s3cam_probe overlay: N writes, H found unchanged next tick, …` every 5 s says how
it goes. If the view follows the probe's chase pose, the write sticks. H ≈ N would mean the game
does not recompute its camera every frame (it keeps our pose as state). If the view stays the
game's own, the renderer copies the camera before our tick, and the write must move to the
render-pose handoff, as first person does.

| Run 3 question | Answer |
|---|---|
| Does the view follow the probe pose, smoothly? | **no: the view stayed the game's own camera** |
| Off board: is the game's camera back, right stick working? | **yes** |
| Replay editor while mode 2 is on: normal? | **yes**: free camera and clip playback as in vanilla |
| Freecam / first person on and off while mode 2 is on: clean? | **yes** |
| `writes` vs `found unchanged next tick` | 7095 writes, 0 failed, **0 unchanged**: the game recomputes its camera every frame, and the view had already taken it before the debug tick wrote |

### S1c. Write inside the game's camera update

The camera observer already hooks the native camera callback (0x178b690, `camera_observer.cpp`).
Its evaluator holds the game camera at +0x138, the same object as the view's mode-0 camera. A
listener (`set_camera_updated_listener`) now runs right after that callback returns, from the
verified native caller only. Mode 2's tick computes the pose and the listener writes it, inside
the game's own update and before anything later in the frame copies the camera. The pose is one
tick old (constant lag, as run 1's 60 Hz chase). Unit test: `camera_observer_recovery` →
`updated_listener`.

Log: `s3cam_probe overlay: W writes in the camera update (S seen, T other thread, X stale), H
still ours at the tick, …`. S≈W means every update was overwritten. H≈W means nothing later in
the native update overwrote it again. If the view still doesn't follow, the copy happens inside
the callback (in its `output`), and the next spike looks at that buffer.

| Run 4 question | Answer |
|---|---|
| Does the view follow the probe pose, smoothly? | **no**: still the game's camera (smooth) |
| Off board, replay editor, Freecam, first person still vanilla? | **yes** |
| W / S / H counters | 3728 writes / 5974 seen / **0 still ours at the tick**, 0 failed. The listener ran on every update and the write was replaced every time, later in the same update |

### S1d. Write the update's output, not the camera

The native caller (return 0x1728bd5) applies the callback's `output` buffer to the camera after
the callback returns, so a write to the camera inside the callback is always too early. The
listener now receives `output` too. Mode 2 first **learns** where the view rows are: for 120
updates it keeps a guarded copy of the first 0x400 bytes of `output` and, at the tick, matches
them against the camera's final view. Nothing is written while learning. If one offset matches
≥90% of updates, it logs `s3cam_probe now writes the pose at output+0x…` and writes the probe pose
there (rows only, keeping the output's own fourth lanes). Either way it logs `output scan …`,
with the best matrix and position offsets and any other copy of the view inside the camera object.

| Run 5 question | Answer |
|---|---|
| `output scan` line: offset and hits | **0 hits anywhere in 0x400 bytes**: `output` does not carry the view. **But the camera object has a second copy of its view rows at +0x10** |
| After ~2 s riding: does the view switch to the chase pose? | no (nothing was written: no offset learned) |
| Everything else still vanilla? | yes. Aescher also re-ran **mode 1: the chase view shows**, as in runs 1–2 |

### S1e. Write both copies, +0x10 and +0x50

The camera keeps its view rows twice. Run 4 wrote only +0x50, and that write was gone by the
tick. Mode 2 now writes the rows to **both** copies (fourth lanes kept), in the update's listener
and again at the tick. At the tick it counts which copy still holds the pose from the listener:
`still ours at the tick: +0x10 A, +0x50 B`. A copy that survives is the one the game keeps; one
that is rebuilt every frame is derived from the other (or from data further back).

| Run 6 question | Answer |
|---|---|
| Does the view switch to the chase pose? | **no** |
| `+0x10` / `+0x50` survival counts | **0 / 0** of 11 620 writes. Both copies are rebuilt every frame from state the camera keeps elsewhere. Off board, the replay editor, Freecam and first person stayed vanilla |

**S1b–S1e conclusion:** the game's camera can't be steered by overwriting its output. Runs 3 to 6
wrote after the tick, inside the update, into the update's output, and into both view copies.
None of it showed: the camera rebuilds its view every frame from internal state (director rig,
trackers) that isn't mapped. Steering it would mean reverse-engineering that state or the
render-view copy (0x3f8b2b0, which risks culling mismatch). Neither is a spike-sized job.

Run 6 also showed a probe bug, not a game one: `firstperson 0` ran `debug_restore_camera`, which
disarmed mode 2's probe while `s3cam_overlay` stayed set. A later `s3cam_probe 2` was then ignored
until `s3cam_probe 0`. It's throwaway code, so this is noted, not fixed.

**Fallback if S1e fails:** mode 1 is proven to show the pose (runs 1, 2, 5). What it lacks is
hand-back before the replay editor and menus take the verified phase away. Phase 0 would then end
on B1 through mode 1, with one more signal to find (the game flow state that `client_tick.cpp`
checks as `state == 13 || state == 21`: hand back the moment it leaves gameplay, while the
phase is still verified).

**Verdict (proposed for Gate 0, revised after run 2): own the pose, not the selection.** If S1b
works, S3Cam writes the game's camera (B1's full control of the pose, without B1's mode switch),
and the replay editor, menus, Freecam, first person and off-board play stay native with nothing to
hand back. If it does not, B1 through mode 1 needs a replay/menu signal to hand back *before* the
phase is lost. That signal is not known yet.

~~Verdict after run 1: B1, with B2 available.~~ Taking mode 1 broke nothing
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
| g (median of N arcs) | **≈ 10.1 m/s²** from the skater root on the five long arcs of run 3 (0.87–1.15 s of free air, state 201 only): **10.19, 10.38, 10.07, 10.13, 9.80**, rms 0.4–1.7 cm. Short ollies (0.27–0.42 s) scatter from 7.4 to 15.6 (too short, and the body still moves through the trick); the board root scatters more (3–25). Use 10.1, tunable. Earlier runs: run 1 sampled at 10 Hz: nothing fittable. Run 2: 31 fits, **1.8 to 28 m/s² (median 17.2), rms 1–7 cm**, which is not ballistic. Ollie-sized arcs (0.33–0.45 s) fit 15–28. The long drops (0.77–1.03 s, 1.9–3.4 m down) fit **10.3, 11.7, 12.9**. Cause: the arc started at state 200, while the pop is still pushing the board, and the board root is flipped and caught during tricks. Run 3 records only state 201 and fits the skater root too (`air root:` lines). The data-defined `GravityAcceleration` 9.81 (trainer_classes.inc) sits with the on-foot values and may not be the board's air gravity |
| rms of a typical arc | _pending_ |
| physics dt (`dt_phys` in the log) | **0.0167 s (60 Hz)** |
| board root vs skater root height (`board_h` − `root.y`) | **≈ −0.9 m** riding |

---

## Gate 0 report (2026-10-15, after six runs)

**Ownership: B1 through mode 1, with early hand-back** (proposed; Aescher decides).

- Mode 1 (FreeCamera, the path first person, Freecam, spectate and the Park Editor use) **shows
  the pose, smoothly** (runs 1, 2, 5). HUD, trick names and scoring are intact.
- Its one gap: the **replay editor froze** and **the right stick off board** did nothing (run 2).
  T9 hands the camera back to the game (mode 0):
  - **off board** (state 504): proven safe; the camera phase is verified while walking;
  - **before the replay editor / menus**: the game flow leaves gameplay (`client_tick.cpp` checks
    `state == 13 || state == 21`) and the debug tick goes unready. T9 has to hand back on that
    transition, while the phase is still verified. **That's the one remaining unknown**, so T9
    starts with a small spike: log the flow state and the phase on the frames around opening the
    replay editor and the pause menu.
  - Fallback if the phase is already gone by then: keep writing the last pose, so the view
    doesn't freeze mid-motion, and hand back on the first verified frame after.
- Mode 2 (steer the game's own camera without taking it) is ruled out for now (S1b–S1e above).
- The game's camera keeps running under mode 1 (1516/1517, 9887/9999 ticks), R3 height included,
  so its pose stays readable as a reference or blend target during hand-overs.

**SubjectSnapshot (frozen for Phase 1):**

| Field | Source |
|---|---|
| position, transform | entity transform (`debug_skater`); row 2 = forward, Y up |
| velocity, spin | board body 0 +0x70 / +0x90 |
| board position | board body 0 +0x50 (≈0.9 m below the root while riding) |
| physics state | context +0x1414: 100 ride, 101 (brief, after air), 103 crouch, 200 pop, 201 air, 400–406 grind, 504 offboard/bail, 601, 701 post-grind |
| stance (switch) | context +0x13c4 bit 5 (flips in state 100 as expected) |
| ground normal | 3 down-rays from the root (0.02 ms per 10 rays) |
| manual | **not a separate state**: not seen in three runs that included manuals. T7 must detect it some other way (board pitch from the board body's rotation, or a native flag). It's open, and until then manual falls back to the chase shot |
| launch velocity / predicted air | board velocity at 200→201, with g below |

- Ray-cast cost: **~0.02 ms per 10 casts** (budget 0.3).
- Gravity: **≈ 10.1 m/s²** (skater root, long arcs; runs 3 and 6 medians 10.4–10.6 including
  short ollies; tunable `air.gravity`).
- Camera matrix: rows {right, up, backward, position}, right × up = **+backward**.
- Card changes: T3 also reads `skate-game/src/camera/trajectory.rs` and
  `skate-core/src/camera/trajectory_query.rs`. T8 also reads `skate-game/src/camera/collision.rs`
  and `world_query.rs`. T7 adds the manual signal hunt. T9 opens with the hand-back spike above
  and writes at the render-pose handoff, as first person does.
- Phase 1 (T1–T6) is pure math and doesn't depend on any of the open items.
