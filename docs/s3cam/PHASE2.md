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
