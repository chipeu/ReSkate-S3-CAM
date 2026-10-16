# S3Cam Phase 2: the alpha build (T7 + T9)

T7 (reading the skater) and T9 (owning the camera) ship together as one playable build, so the
camera core from Phase 1 can be felt in game before collision (T8) and the settings page
(T10/T11) are built on top of it.

## What the alpha does

- **`s3cam 1`** turns it on. S3Cam takes the view through Freecam's mode-1 path (the same path
  first person uses) when the skater is on the board, and drives it with `CameraMan`
  (`Engine/Game/Camera/s3_camera.h`) every frame.
- **Hand-back.** The game's own camera comes back:
  - **on foot**: 0.25 s after the skater steps off (physics state 504 without the ragdoll flag);
  - **in menus, the replay editor and loading**: the first tick the debug tick loses control,
    as long as the camera phase is still verified. If the phase is already lost, S3Cam holds its
    last pose and hands back on the first verified tick.
- **Taking it back**: 0.15 s after the skater is on the board again (or bailing), with control and
  a verified phase. Each take is a camera cut (`request_reset`).
- **Bails** keep S3Cam (the Wipeout shot) while the offboard state's ragdoll flag is set
  (`skater_state.h` `ragdoll_offset`, as Hall of Meat reads it). Getting up and walking hands back.
- Freecam or first person turn S3Cam off (it keeps the owned camera and hands it to them).
  Noclip and the Park Editor only pause it.

## Skater reading (T7)

| Field | Source |
|---|---|
| position | entity root (`debug_skater`) |
| forward | entity row 2 |
| velocity | board root body +0x70 on board; the hips body (skeleton 23) off the board |
| physics_state | context +0x1414 |
| onboard / bailing | state != 504 / state 504 and ragdoll flag |
| switch_stance | context +0x13c4 bit 5 |
| ground clearance, normal | a down-ray from root + 0.1 m to root − 10 m; the normal from two more rays 0.25 m to the side |
| manual, grind side | not read yet: manuals use the chase shot, grinds the flat grind shot |

## Rays (part of T8)

`cast_surface_once` with no ignore list, so the glue never allocates per ray. A hit within 2 cm
of a chord's start is skipped by casting again from 3 cm along: the trajectory's first chord starts
on the takeoff surface (Gate 1 carried item). Wall and pole collision for the camera itself is still
T8.

## Console

| Command | Effect |
|---|---|
| `s3cam 0\|1` | off / on |
| `s3cam_preset full\|native` | full Skate 3 camera, or the game's camera plus S3 air hold, landing dip and shake |
| `s3cam_angle low\|high` | Skate 3's Low or High shot set |
| `s3cam_shake 0\|1` | landing and speed shake |
| `s3cam_fov N` | vertical FOV override, 30–120 (0 = off) |
| `s3cam_shotfov 0\|1` | write each shot's FOV (default 0: the FreeCamera keeps its own) |
| `s3cam_log 0\|1` | state/shot changes and a line per landing in the log (default 1) |
| `s3cam_dump` | settings and what the camera is doing now |

Settings are not saved between launches yet (T10).

## Log lines

- `s3cam flow: client state S, control yes/no, camera phase verified/lost, camera mode M, S3Cam owns/handed back`:
  logged whenever any of these changes. This is the T9 hand-back spike: what the pause menu and the
  replay editor look like from the tick.
- `s3cam t=…`: once a second while S3Cam drives the view: frames, fixed steps, held frames, update
  cost, rays, whether the game camera still moves underneath, shot, speed, clearance, rig distance and
  elevation.
- `s3cam shot a -> b`, `s3cam state a -> b`: transitions (with `s3cam_log 1`).
- `s3cam landing #n: air … (predicted …), drop … (predicted …), apex …, speed …, shake impulse peak …`:
  one per landing, for tuning the landing shake against how heavy the landing was.

## Alpha test (Gate 2 dry run)

1. Load a park, `s3cam 1`. Ride: the view should switch to the S3 chase camera.
2. Ollies and airs off flat, small drops, and a big gap or stair set. Look for the camera holding
   its height in the air, framing the landing, and a shake that scales with how hard you land.
3. Grind a rail and a ledge. Manual (expected: plain chase for now).
4. Bail hard. The camera should stay on you through the bail. Get up and walk: the game camera and
   the right stick come back. Get on the board: S3Cam comes back.
5. Pause menu, then resume. Open the replay editor: it must work as normal. Leave it.
6. `s3cam_angle high`, `s3cam_preset native`, `s3cam_shake 0`, `s3cam_fov 70`, `s3cam_dump`.
7. `firstperson 1` (S3Cam turns off), `firstperson 0`, `s3cam 1`, `freecam 1`, `freecam 0`.
8. Send `logs\ReSkate.log`.

## Alpha 2 (from the alpha run's feedback)

| Feedback | Change |
|---|---|
| Snaps taking / handing back the view (board, bails), FOV snaps | Crossfade with the game camera both ways (Transitions: take 0.5 s, release 0.4 s); the FOV starts and ends at the game camera's own (+0xac, used only while it reads as 10–150°) |
| Choppy big airs / off ramps | The root is carried along its velocity between 60 Hz physics steps (≤ 1/30 s); big-air FOV widening |
| Pitch prediction on drops, stairs and downhill | LOOK: landing look (toward a lower predicted landing), slope look, vertical follow |
| Shoulder offset, side switching | SHOULDER: Off / Manual / Auto (stance toe side), offset, smooth slide; L3 via the bind "S3Cam: swap shoulder side" |
| R3 High / Low | S3 Low / High follows the game's camera height button (option "R3 picks Low/High") |
| Follow strength, dynamic follow, speed FOV | FOLLOW and FIELD OF VIEW cards |
| Shaky downhill / speed cam | SHAKE: speed rumble strength, top speed, downhill boost (landing shake separate) |
| Camera in walls / ground | COLLISION: pull-in along the skater-to-camera ray, slow release, ground clearance under the camera |
| Map / customisation menus show gameplay | Hand back when the game moves its camera > 25 m from the skater; the flow log now names the reason. Needs the next log to confirm |
| Own tab | S3 CAMERA page in the ReSkate menu; every setting saved (`S3Cam.*` keys) |

### Alpha 2 test

1. S3 CAMERA tab: turn S3Cam on there. Step off and on the board, and bail: the switch should
   crossfade, not snap, and the zoom should not jump.
2. Big airs off a ramp and a stair set / gap to a lower level: smooth tracking, the view tilts down
   toward the landing, the FOV widens a little in the air and comes back after.
3. Ride down a steep ramp: the view tilts down with it.
4. Shoulder: Manual, then bind "S3Cam: swap shoulder side" to L3 (binds) and swap while riding. Try Auto.
5. R3 while riding: S3 Low / High switches.
6. Ride along a wall and into a corner: the camera stays out of the wall.
7. Open the map and the skater appearance menu with S3Cam on. Note what shows.
8. Restart the game: S3Cam and its settings come back.
9. Send `logs\ReSkate.log`.

## Alpha 3 (from the Alpha 2 log and feedback)

Log findings: the game camera's FOV at +0xac is real (70°, and it moves by itself in bails); 60 fps
with no repeated roots, so stair-stepping was not the problem; ~2/3 of landings were predicted 8–9 m
down (the start-hit skip on falling chords), which swung the landing look every 0.1 s; speed measured
along the spinning entity forward made the speed FOV and dynamic follow twitch in tricks; every
landing had a shake impulse of 0 (angle weighting); the map / customisation hand-back worked.

| Change | Where |
|---|---|
| Start-hit skip only for rising chords | glue |
| Speed held in the air; horizontal speed for FOV and follow | core |
| Landing shake weighted by the speed into the ground, 2.2–5.7 m/s | core (`s3_shake.h`) |
| Manual detector: board pitch vs ground from the extreme board bodies (7° on / 4° off) | glue, logged |
| Manual close-up: 0.75 × the chase distance, adjustable | core + MANUAL card |
| Trick yaw: swing to the side while tricking, hold, recentre | core + TRICK YAW card |
| Camera distance, height, view pitch | core + CAMERA POSITION card |
| Named presets, import / export (clipboard and files) | PRESETS card |
| Per-air jitter numbers in the landing line | glue |

### Alpha 3 test

1. Big airs and gaps: FOV and camera smooth? Landing lines now end with the air's FOV range,
   largest FOV step, turn and jerk; send them.
2. Manual and nose manual on flat ground: the camera moves closer (log: `s3cam manual on`). Ride up
   and down ramps without a manual: there must be no `manual on` lines.
3. Trick yaw: a flip trick in a big air swings the camera round, chain tricks, then let it recentre.
4. CAMERA POSITION sliders while riding.
5. Presets: save one, change things, load it back; export, then import from the clipboard.
6. Send `logs\ReSkate.log`.

## Alpha 4 (Alpha 3 feedback)

- Replay editor stuck: the pause menu and replay editor report normal play, so S3Cam now detects a
  pause (skater frozen with speed, or a 0 physics step) and hands back at once.
- Big airs: the camera follows the skater's height partly (Big air: follow height), swings up to
  look down at the landing (Big air: camera rise), and keeps the skater on screen (Keep skater on
  screen); Native+ gets the same, fixing "camera stays on the ground".
- Manual / grind focus aims at the board (lower body) instead of the hips.
- Separate camera position for Low and High.
- Page: plain names, tabs, Enabled / Disabled off board status, FOV override, Landing bounce,
  blend times; presets: "Skate 3" and "Close & low" built in, newer and older preset files load.

### Alpha 4 test

1. Ride on board, pause, open the replay editor: it must work without stepping off. Resume riding.
2. Big airs and drops, in Full and Native+: the skater stays on screen and the camera ends up above,
   looking down at the landing.
3. Manual and grind: the camera aims lower (board / legs).
4. Low and High with different positions; R3 switches between them smoothly.
5. Send `logs\ReSkate.log` (look for `s3cam game paused`).

## Alpha 5 (Alpha 4 run)

Worked in game: replay editor, phone menu and quick drop on board; quarter-pipe airs.
Changes: landing shake from how far the skater fell (peak to landing) plus a little speed, not the
board's touchdown velocity (a flat nollie no longer shakes fully); horizontal follow 0-10; exits from
manual / grind close-ups blend over ~0.9 s; camera kept 0.3 m above the board in manuals and grinds;
camera height changes show within ~0.5 s; manual and grind close-ups per Low / High; plain tooltips.
The landing log line now shows the fall and the shake percentage.

## Alpha 6 (Alpha 5 feedback)

- Manual and grind close-ups anchor to the real board (root board body), not an estimate from the
  hips: the camera orbits the board + 0.3 m, and the close-up pitch tilts the camera around the board,
  so the board keeps its place on screen. Eases in over 0.3 s and out over 0.45 s (Camera tab,
  "Follow the board").
- One distance rule: Minimum / Maximum distance (Collision tab) replace "Closest to you". The camera
  is never closer than the minimum or further than the maximum; a wall closer than the minimum lifts
  the camera over it instead of pulling it into the skater. Fixes close-ups ending up in the face.

### Alpha 6 test

1. Manual and nose manual, then grinds on a rail and a ledge: the board stays in the same place on
   screen; change the manual / grind pitch while in one.
2. Minimum distance 2 m, manual and grind next to a wall: the camera rises over the wall, never
   inside the skater. Maximum distance 3 m on a fast line: the camera never trails further.
3. Send `logs\ReSkate.log`.
