# CLAUDE.md: ReSkate fork, S3Cam (Skate 3 camera engine)

Claude Code reads this file at the start of every session. Keep it current.

## Mission

Build **S3Cam**, a native third-person camera for ReSkate that reproduces Skate 3's camera
behaviour on tricks, air and landings, with every behaviour tunable live. The full plan, research and
task cards are in **`docs/s3cam/S3CAM_ORCHESTRATION.md`**. Read it before doing anything. Work strictly
card by card (S0–S4, T1–T19).

## Roles and models

- **Main session: Opus 5.5 (orchestrator).**
  - Runs the Phase 0 spikes and owns the Gates.
  - Writes and refines task cards, and reviews every diff against the card's acceptance criteria.
  - Reviews numerics against the Rust reference.
  - Doesn't write large feature code itself; it delegates.
- **Implementer: Sonnet 5.5**, through the subagent `.claude/agents/s3cam-implementer.md` (below).
  - One card per subagent run.
  - T1–T5 may run in parallel because they touch disjoint files.
- **Reviewer:** the `.claude/agents/s3cam-reviewer.md` subagent (Opus) gives a second opinion at each
  Gate, without having seen the implementation conversation.
- Opus's loop for each card:
  1. Post the card.
  2. Spawn the implementer.
  3. Read its report and the diff.
  4. Run the tests yourself.
  5. Approve, or send back a numbered fix list.
  6. On approval, commit `s3cam(<ID>): <summary>`.
- Stop and ask Aescher at every **Gate**, and before anything irreversible (force-push, deleting
  branches, publishing a release, opening an upstream PR).

## Repository layout (what matters for S3Cam)

| Path | Role |
|---|---|
| `Engine/Game/Camera/` | **new**: pure header-only S3 camera math + `Test/` |
| `Engine/Game/Build/20260929/` | every native address/offset, per game build. New ones go in `s3cam.h` |
| `Engine/Game/Skater/first_person_spring.h` | pattern for pure, testable camera math |
| `Extension/Skater/client_first_person.cpp` | **the reference** for owning the camera, the render-pose handoff, SEH-guarded reads, FOV write/restore |
| `Extension/Skater/client_debug.cpp` | arm/disarm wiring, `saved::` settings keys, debug actions |
| `Extension/Skater/client_source_spawn_internal.h` | `SourceCameraTransform`, `FirstPersonArm`, shared helpers |
| `Engine/Game/Build/20260929/skater_state.h` | physics state (200/201 air), board/rig body velocity offsets |
| `Engine/Game/Build/20260929/park_editor.h` | physics surface/ray probe (collision) |
| `Extension/UI/Overlay/skate_menu_skater.cpp` | overlay UI row helpers (`toggle_row`, sliders) |
| `Extension/Camera/` | **new**: S3Cam game glue |
| `Extension/UI/Overlay/skate_menu_camera.cpp` | **new**: S3 CAMERA page |
| `docs/s3cam/` | plan, `SPIKES.md`, tuning notes |

**Reference repo (read-only)** in a sibling folder, `..\skate-3-rust-engine\`:

- `crates/skate-core/src/camera/*.rs`: the Skate 3 camera reconstruction. The key files are
  `manager.rs`, `tracker.rs`, `angle_tracker.rs`, `rig*.rs`, `manager_air.rs`, `shake*.rs`,
  `shot*.rs`, `drop_predictor.rs`, `positioner.rs` and `compass*.rs`.
- `crates/skate-game/src/camera/`: `settings.rs` (names of every stock tunable), `graph_conditions.rs`
  (state conditions), `angle.rs`, `shot_data.rs`.
- `docs/hails-additions/21-low-camera.md`: Low vs High shot values.

Example data mod for reference: `F:\Games\ReSkate Mod Items\SunJays_Low_Cam`.

## Build and test (Windows, VS 2022, MSVC v143)

```powershell
cmake --preset vs2022-x64 -DDINGOSDK_BUILD_MULTIPLAYER_TESTS=ON
cmake --build --preset release
ctest --test-dir build/vs2022-x64 -C Release --output-on-failure
```

- **The unit tests are off by default.** Every test target sits behind
  `DINGOSDK_BUILD_MULTIPLAYER_TESTS AND WIN32`. Without the flag above, `ctest` runs nothing.
- Tests that need game files take `-DDINGOSDK_TEST_GAME_ROOT=<skate. folder>`, and skip that part
  without it.
- The build is `/W4 /WX`: a new warning is a failed build.
- Pure-math tests follow the existing pattern in the root `CMakeLists.txt` (around line 173, the
  `first_person_stabilize_tests` block):
  - `add_executable(dingosdk_s3cam_<name>_tests Engine/Game/Camera/Test/s3cam_<name>_tests.cpp)`
  - `target_include_directories(... PRIVATE "${PROJECT_SOURCE_DIR}")`
  - `add_test(NAME s3cam_<name> COMMAND ...)`
- Tests use the repo's own tiny `expect()` + `failures` style, with no test framework, and return
  non-zero on failure.
- Record the exact verified commands here after S0 if they differ.

### Working from a Linux cloud session (no MSVC, no game)

The session that started this branch ran in a Linux container. Code written there is checked
before Aescher builds it:

- Pure headers in `Engine/Game/Camera/` compile and run with g++ and clang:
  `g++ -std=c++20 -Wall -Wextra -Wconversion -Wsign-conversion -Wshadow -I. Engine/Game/Camera/Test/<test>.cpp`
- MSVC-only warnings the Linux pass misses (both seen at Phase 2): **C4459**, a local or parameter that
  shares a name with a namespace-scope one the TU can see (`s3cam::tau`, a test's global `g`, also
  inside templates the test instantiates); and **C4723**, a release-build "potential divide by 0" where
  the optimizer inlines a guarded division. Give guarded divisors a visible floor (`std::max(d, eps)`).
- Windows sources get a syntax-only MinGW pass: `sh docs/s3cam/linux_syntax_check.sh <files…>`
  (needs `g++-mingw-w64-x86-64-posix`). It catches compile errors, not MSVC warnings.
- Aescher then builds with MSVC, runs `ctest`, plays the requested test lines, and sends back
  `logs\ReSkate.log`.
- `/tools/` is in `.gitignore`. T19's importer needs a different home, or a `!/tools/s3cam_import.py`
  exception.

## Run in game

1. Close the game. Copy **both** `ReSkateLauncher.exe` and `ReSkate.dll` from
   `build/vs2022-x64/Release/` into the ReSkate folder (beside `Skate.exe`). Back up the originals
   first (`*.orig`). Both are needed: a release launcher can update `ReSkate.dll` back to the
   official build, while a locally built launcher never replaces anything (README, "Running your build").
2. Launch with `ReSkateLauncher.exe` → PLAY. **Insert** opens the menu; **~** opens the console.
3. Logs: `logs\ReSkate.log` beside `Skate.exe`. Read it after every run, and grep for `s3cam`,
   `error` and `fingerprint`.
4. Only Aescher can play-test feel. Ask for a specific test line (from checklist §6) and what to
   look for. Don't claim feel results you didn't observe.

## Hard rules

1. **Scope.** S3Cam drives only the **onboard gameplay** camera. Offboard, menus, replay editor,
   Park Editor, Freecam, first person, spectate and buildkit stay native. S3Cam hands back
   immediately and restores FOV, using the first-person disarm pattern.
2. **Safety.**
   - Every native memory read or write is SEH-guarded and range-checked, as in
     `first_person_read` / `first_person_write`.
   - Every new address goes in `Engine/Game/Build/20260929/s3cam.h`, with a prefix fingerprint
     checked at start.
   - A failed check disables S3Cam with one clear log line. It never crashes the game.
3. **Threading.** The camera is written **only on the engine thread**, at the render-pose handoff.
   Animation-thread code may only read and snapshot.
4. **Order of operations** (from Skate 3; don't change it):
   prepare(air/landing → incline) → graph select → shot blend → rig (fixed 60 Hz steps) →
   orientation/framing → shake → write.
5. **Fixed timestep of exactly 1/60 s** (the Rust `STEP`, manager_state.rs) for trackers, blends
   and shake, with an accumulator. Interpolate the output. Every per-step constant ported from the
   Rust is per 1/60 s. Never feed the raw frame dt into per-update Skate 3 filters. (Gate 1 found
   the plan's 120 Hz was wrong.)
6. **Port semantics, not PowerPC quirks.** Keep the umbra/penumbra, clamps, sine blends,
   squared-impulse shaping and update order. Drop `from_bits` constants that only reproduce VMX
   rounding, and use normal float constants with a comment naming the Rust source line.
7. **No EA data in the repo.** Stock Skate 3 values, `.shk` samples and lag curves are only
   imported locally by `tools/s3cam_import.py` (T19) from the user's own copy. Ship hand-tuned
   defaults and a procedural shake bank.
8. **Licence and credit.** Ported files carry a GPL-3.0 header noting they're adapted from
   SK8-ENGINE/skate-3-rust-engine (dumbad and contributors, GPL-3.0-only).
9. **Match the house style.** C++20, `namespace dingosdk::...`, `noexcept` on hook paths, no
   exceptions escaping hooks, no per-frame heap allocation, and comments that explain *why*, as
   the existing code does.
10. **Don't touch** unrelated features, `External/`, the launcher updater or networking, unless
    a card says to.

## Definition of done (every card)

- Builds in Release with no new warnings. All `ctest` tests pass, old and new.
- The card's acceptance criteria are met and shown, with test output or a log excerpt.
- New tunables are in `s3_settings.h` with validation, and are exposed in UI and console when the
  card covers UI.
- `docs/s3cam/` is updated if behaviour, addresses or tuning changed.
- One commit per card: `s3cam(<ID>): <summary>`, ending with the attribution trailer the session
  supplies.

## Subagent definitions (create these files)

`.claude/agents/s3cam-implementer.md`

```markdown
---
name: s3cam-implementer
description: Implements exactly one S3Cam task card (T1–T19) in the ReSkate fork, with tests.
model: sonnet
---
You implement ONE task card from docs/s3cam/S3CAM_ORCHESTRATION.md, given to you verbatim.
Read CLAUDE.md hard rules first. Read the Rust reference files named in the card before writing C++.
Write the code + tests, build, run ctest, and stop. Do not start other cards, do not commit.
Reply with: files changed, a 5-line summary, test output (tail), open questions, and any place you
deviated from the card and why.
```

`.claude/agents/s3cam-reviewer.md`

```markdown
---
name: s3cam-reviewer
description: Independent Gate reviewer for S3Cam; checks numerics and safety against the Rust reference and CLAUDE.md.
model: opus
---
You review a diff you did not write. Check: (1) semantics vs the named Rust source (order of
operations, clamps, umbra/penumbra, sine blend, impulse shaping, reset behaviour); (2) CLAUDE.md
hard rules (SEH guards, engine-thread writes, fingerprints, no EA data, fixed timestep, no per-frame
alloc); (3) test coverage of the card's acceptance criteria. Report findings ranked by severity
with file:line and a concrete failure scenario. Do not edit code.
```

## Kickoff prompt (paste as the first message)

> Read CLAUDE.md and docs/s3cam/S3CAM_ORCHESTRATION.md. Create the two subagent files from
> CLAUDE.md. Then run Phase 0, starting with S0 (fork baseline build + tests + game launch).
> Continue through S1–S4, writing findings to docs/s3cam/SPIKES.md. Stop at Gate 0 and report: the
> B1/B2 ownership verdict, the SubjectSnapshot signal table, ray-cast cost, and measured gravity.
> Don't start Phase 1 until I approve.

## Status log (Opus appends one line per card)

- 2026-10-15: plan created (Opus 5.5 in claude.ai). Next: S0.
- 2026-10-15: Phase 0 instrumentation written (cloud session): `s3cam_probe` (S1/S2/S4) and
  `s3cam_ray` (S3) console commands, `s3_gravity_fit.h` and `s3_probe_pose.h` with tests, and
  `docs/s3cam/SPIKES.md` with the code-reading findings. Not yet built with MSVC or run in game.
  Next: Aescher runs S0, then the SPIKES.md session.
- 2026-10-15: Phase 0 done after six in-game runs (SPIKES.md). Gate 0 proposed: B1 via mode 1 with
  early hand-back; mode 2 (overwrite the game camera) ruled out; g ≈ 10.1; rays 0.02 ms/10. Waiting
  for Aescher's Gate 0 approval before Phase 1.
- 2026-10-15: Gate 0 approved (SPIKES.md "Gate 0 decision"): mode 1, targeted RE only; full S3 +
  Native+ presets; separate S3 CAMERA page; T19 shelved (no Skate 3 copy). Shared `s3_math.h` +
  tests written by Opus so T1–T4 can run in parallel. Next: T1–T4.
- 2026-10-15: T1–T4 done (Sonnet implementers, reviewed by Opus against the Rust: umbra semantics and
  the 2.8 m shake fade confirmed, plan text corrected). All pure tests pass under g++/ASan/UBSan and
  clang. Next: T5 (rig + air), then T6 (graph + CameraMan) and Gate 1.
- 2026-10-15: T5 and T6 done and reviewed; 11 pure test suites pass (ASan/UBSan, clang). The
  scripted session gives the same shot sequence at 30/60/144 fps, max step 0.34 m. Next: Gate 1 review.
- 2026-10-15: Gate 1 passed with fixes (independent review); fixes 1–7 in, 11 suites green. Standing
  heights Low 0.589 / High 1.870 m. Next: Phase 2 (T7 subject, T8 collision, T9 ownership, T10, T11).
- 2026-10-15: Phase 2 opened with the S3Cam alpha (T7 skater reader + T9 ownership, written by
  Opus): `s3cam 1` drives the view with CameraMan through mode 1, hands back on foot and the first
  tick without control, logs the flow states (hand-back spike), landings and per-second costs.
  Alloc-free rays with the start-hit skip. Syntax-checked only. Next: Aescher's alpha run
  (docs/s3cam/PHASE2.md), then T8 collision, T10/T11 settings and page.
