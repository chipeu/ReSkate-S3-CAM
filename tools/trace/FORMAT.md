# Golden traces: format and commands

The C++ camera (F:\Dev\ReSkate, read only) is run through scripted scenarios by `trace_gen.cpp`. Each scenario becomes one
trace the Luau camera is replayed against (`tests\replay.lua`).

## Commands

Regenerate (builds `trace_gen.exe` against F:\Dev\ReSkate with MSVC, clears `out\`, runs every scenario):

    powershell -NoProfile -ExecutionPolicy Bypass -File F:\Dev\DynCam-Plugin\tools\trace\regen.ps1

Run the parity test (from F:\Dev\DynCam-Plugin):

    tools\luau_run.exe -I Dynamic_Camera\plugin -I tests -I tools\trace\out tests\run_parity.lua
    tools\luau_run.exe -I Dynamic_Camera\plugin -I tests -I tools\trace\out tests\run_parity.lua only mixed_high
    tools\luau_run.exe -I Dynamic_Camera\plugin -I tests -I tools\trace\out tests\run_parity.lua strict all

Harness self-test (no camera.lua needed; uses `tests\fake_camera.lua`):

    tools\luau_run.exe -I tests -I tools\trace\out tests\run_parity.lua self

## Files in `out\`

- `trace_<scenario>.lua`: the trace, as a Luau module: `return [==[ ...text... ]==]`. The offline runner has no `io` library,
  only `require`, so the data is wrapped as a module. `replay.load("trace_hops")` requires it and parses the text.
- `trace_index.lua`: `return { "trace_...", ... }`, the list of scenarios.
- `settings_<scenario>.json`: the full `CameraSettings` of the scenario (the player-facing groups, with the C++ field names,
  enums as their names), for reading and for checking `settings.lua` defaults. `rig`, `graph`, `air`, `shake` are not dumped
  (no scenario changes them).

## Trace text

Line oriented; `key=value` pairs split on spaces. Floats are written with 9 significant digits (they round-trip the C++ float
exactly). Booleans are `1` / `0`.

    dyncam-trace 1
    scenario <name>
    note <one line>
    fps <nominal frame rate>
    set <dotted.path> <value>          zero or more: the settings that differ from CameraSettings{} defaults
    frames <N>
    F <i> dt= t= base_fov= position_x/_y/_z= forward_* velocity_* physics_state= onboard= bailing= manual= grind_side=
        switch_stance= board_position_* board_valid= ground_normal_* ground_clearance= valid=
    R from_x/_y/_z= to_x/_y/_z= hit=<0|1> [point_x/_y/_z= normal_x/_y/_z=]     zero or more per frame, in call order
    O valid= shot=<name> pos_* right_* up_* back_* fov_deg= <FrameDebug fields> orbit_anchor_* skater_anchor_* look_target_*

Per frame there is one `F` line (the inputs of `CameraMan::update`), then its `R` lines (every world query the camera made during
that update, in order; a frame that ran no fixed step has none), then one `O` line (the returned frame).

- `F`: `dt` = the frame time handed to `update`; `t` = `SubjectSnapshot.time`; `base_fov` = `FrameExtras.base_fov_deg`
  (`aspect` is the default 16/9, `native` is not used: FullS3 only). The rest are the `SubjectSnapshot` fields, same names.
- `R`: `from` / `to` are the segment the camera asked about, `hit=1` carries the contact point and the surface normal the
  recorded world answered. The Luau query receives `(from, to)` and returns `point, normal` (the normal is a second return
  value; ports that do not read it can ignore it).
- `O`: `pos`, `right`, `up`, `back`, `fov_deg` are the `Frame`. The `FrameDebug` fields written: `reset held steps accumulator
  airborne landing_active transitioning shot_fraction chase_blend prediction_valid predicted_max_height predicted_air_time
  predicted_landing_delta heading elevation distance speed fov_base fov_extra shoulder follow_strength collision_pull trick_yaw
  keep_weight focus_weight board_weight floor_weight height_offset follow_weight view_heading ramp_side collision_rays` and the
  vectors `orbit_anchor skater_anchor look_target`; `shot` is `FrameDebug.shot_name`.

### Settings (`set` lines)

`set follow.strength 4` means `settings.follow.strength = 4`. Names are the C++ field names (snake_case). Values: numbers,
`true` / `false`, or the enumerator name as a string: `preset` (`FullS3`), `angle` (`Low` / `High`), `shoulder.mode`
(`Off` / `Manual` / `Auto`), `ride_distance.mode` and `ride_distance_high.mode` (`Fixed` / `Speed`),
`framing.manual_mode` (`Fixed` / `Speed`). The replay builds the table as `require("settings").defaults()` (or `.new()`) when a
`settings` module exists, with the overrides laid over it field by field; otherwise the table holds the overrides only.

## Replay rules (tests\replay.lua)

- The camera gets `cam:update(dt, snapshot, query, { base_fov_deg = base_fov })` with the snapshot as a table of the plan's fields
  (vectors for the positions).
- `query(from, to)` answers from the recording in order. A ray that was not recorded, a recorded ray not cast, or a `from` / `to`
  more than 1e-3 m off is a port divergence: the scenario fails at that frame and ray index and the replay stops.
- Output tolerances: position 5 mm, `right` / `up` / `back` 0.1 deg (angle between the vectors), fov 0.05 deg.
- The debug fields (distance, elevation, anchors, ...) are compared with their own tolerances and reported as a note; they fail
  the scenario only with `strict`.

## Scenarios (35, 15,744 frames, ~43,000 rays)

Plan list: flat rides at 3, 9 and 40 m/s; stop dead; start with a wall 1.2 m behind; four hops; slalom carve; downhill (15
degree plane, carving); hop onto a 0.6 m step-up ledge; ride off a 3 m drop; carve between two walls; drop-in from a 3 m quarter
pipe; big air (4 m flip); manual regular and switch; a rail and a ledge grind; bail. Settings variants on a shared trick ride
(ollie, manual, flip ollie): Low and High at 60 and 144 fps, uneven frame times around 144 fps, ride distance Fixed and Speed
(Low and High), follow strength 1 (boost off) and 4 (with the dynamic boost), shoulder Auto. Follow variants on a 10 m/s carve:
strength 1 and 4, horizontal 0, 5 and 10 (also at 144 fps). A High angle rail-then-manual run. A half pipe is not included (the
quarter pipe drop-in stands in for ramps).

The generator's scenarios, worlds and subjects are small copies of the ones in
`Engine/Game/Camera/Test/s3cam_layers_tests.cpp` (GPL-3.0-only, same project).
