Dynamic Camera
==============

Build 1.2.33 for ReSkate 2.1.4-4. Check this line to confirm the installed release. Import the patch ZIP in Mod Manager and choose Replace for aescher-Dynamic_Camera.
The archive retains the existing installation folder so saved camera settings and presets remain in place; no folder renaming is needed.
The game's Controls page still prefixes actions with that folder name, which may clip the short action labels.
Enable the changed plugin in ReSkate's Plugin Manager when prompted. Keep the same installed mod folder name to retain settings.
Offline validation is recorded with this release; gameplay validation is pending. Built with Codex assistance; original credits and licence are retained below.

This is an experimental test build. Use DynamicCamera-1.2.18-TEST.zip for manual testing.
The product remains Dynamic Camera; gameplay acceptance is pending.

Tracking clearance now releases as a separate damped offset, with the retained
position collision-tested each frame. Collision decisions use the actual displayed
camera path. This targets edge pumping and unintended recovery jolts. Authored
landing shake, rattle and dip retain their jolt and ease-out; they are not passed
through the clearance damper. Working manuals and saved controls are unchanged.

Vert and air recovery keep one horizontal aim reference through ramp, landing
and riding transitions. Sudden aim changes retain snap protection. Pop and Crouch
retain their vertical controls. When a
recovering camera needs a small floor-clearance lift, it first validates that local
move, including width and headroom, before using a core-pose fallback. Blocked travel
and limited ray budgets retain safety priority. Floor contact keeps tangential
recovery moving instead of stopping every direction. Working manuals are unchanged.

Bounded camera logging now records horizontal jolts, recovery and collision decisions,
body position in view, local lift/rejection evidence, and callback costs. Joint reads are shared within each frame;
shortcut parsing and flight diagnostic data reuse existing storage. No extra diagnostic
files or per-frame log dumps are written.

ReSkate 2.1.4-4 compatibility: the camera now yields while the pause menu,
ReSkate menu or replay editor is open, including when a menu is already open at
startup. Camera stick clicks are suppressed on those screens. Closing them resumes
the camera through its existing handoff. The custom controls still open only on
request, and older API 1 hosts retain their pause-menu fallback. The restored trick
name feed uses the existing manual detector alongside the working gamepad fallback.

Recovery keeps one pitch reference across takeoff, ramps and landing, with gradual
changes in correction speed when the aim reverses. During measured ordinary riding,
a clear previous camera position can ease through a distance change; actual blocked
movement keeps collision priority. The working gamepad manual activation is retained.

Tracking uses the skater API position and the head/hip joint envelope. Render-sampled
motion is timed separately from physics-stepped motion. During ordinary riding, extra
room needed to frame the measured rider eases through the camera distance path;
Low/High and saved distance settings remain available. Collision can shorten that
room where geometry requires it. Small-ramp floor clearance preserves horizontal
tracking and shares the existing view-angle recovery budget. Pop, Crouch, manuals,
rails, vert framing and offboard cameras retain their separate controls.

Drag the grip on the right edge to resize horizontally. Width is saved on release,
clamped to the current viewport, and stored independently of camera presets. Content text
scales from approximately 17 to 23 design pixels and reflows as the panel changes width.
Blue selection states, dark section cards, original line icons, wider 12-pixel slider bars,
handles and value badges follow the supplied visual reference. Native host fonts are used;
the preview font is approximate. Menu/tab/hover/switch/slider motion uses bounded easing.
Close releases input immediately while a short noninteractive fade finishes.

Press number-row 0 to open or close the custom menu. Its left sidebar uses the same eight
existing tabs, with the same camera controls, ranges and settings. Change the dedicated
shortcut in Advanced settings > Menu shortcut, then press a key or modifier combo.
The shortcut is saved outside presets and survives camera resets. Esc and Close release
the screen. Tab focuses controls, arrows adjust values, and the mouse wheel or page buttons
scroll. Dropdowns open a list; sliders support dragging and arrow-key adjustment.
The existing ReSkate plugin page remains available, including an Open custom menu button.
A separate, initially unbound Open camera menu action can be assigned on ReSkate's Binds page
as an additional way to open the menu; Esc always closes it. Existing camera binds are retained.

The custom menu stays closed at startup, including on first installation and upgrades.
Open it manually with 0, its assigned shortcut, or Open custom menu on the ReSkate page.
Both the native ReSkate page and the custom menu edit the same camera settings and presets.

Advanced settings > Changelogs displays approved public release notes only. No release notes
are currently approved for inclusion. Internal test-build history stays outside the in-game
changelogs. Approval is required before adding public entries; opening the page does not
acknowledge an internal build. Existing acknowledgment data is preserved.

The dedicated shortcut uses raw-key and focus APIs. Reserved keys and existing Dynamic
Camera shortcuts are excluded. Choose a different binding if a conflict occurs.
Only the UI is changed here: camera logic, presets, storage identity and existing controls
are carried forward from 1.2.7. In-game appearance, input coexistence and camera stability
still need manual verification. Offline previews use an approximate font, not a game capture.

Design review followed Unslop by Damir Sokolovsky (@heydamir), CC BY 4.0:
https://heydamir.design/unslop .

Camera behavior carried forward from 1.2.5
------------------------------------------
1.2.5 extends body framing to low vert airs. Head movement during a spin contributes to
framing without steering camera yaw. High-air overhead lift still depends on achieved rise.
When snap recovery moves the airborne eye, its aim is reprojected into the rider envelope.
Airborne pitch recovery handles added safety corrections without delaying the core twice;
core and correction share the existing 120 degrees/second ramp pitch budget.

Level support at low speed retires old ramp context before the next flat pop.
Manuals use current score confirmation with named trick events when the score HUD is unavailable.
Full crouch clearance easing also covers
Pop On when body compression is measured. Saved tuning, controls and preset keys are retained.

Offline regressions compare these cases against the shipped 1.2.4 payload. The new low-air
fixture includes 180/360 body spins and a moving head, but its lower body is still estimated.
Gameplay confirmation, including custom animation and the reported jitter, remains pending.

Full crouch with Pop Off now recovers the airborne body reference gradually, rather than retaining the
crouched reference until landing. Takeoff depth uses the same 3D support measurement as crouch follow;
vert follow does not inherit a separate flat-ground eye lift. The base tilt is not reseeded from a composed
full-crouch view. Low camera targets approach existing floor clearance smoothly at maximum crouch.
100% still follows body lowering where space permits; no FOV formula or saved values are changed.

Pop On and Pop Off now share the Classic ramp safety path in Low and High: body-relative crouch measurement,
signed descent alignment, predictive floor clearance and a single finished-target motion limiter. The render
layer validates floor clearance in both modes and avoids a second Fixed-radius adjustment on ramps.
Ramp pitch is owned by the bounded core aim, without delayed angular recovery overriding it. The Pop height
and crouch settings keep their saved values and framing functions. Gameplay confirmation remains pending.

Pop Off vert landings release the air-framing build at touchdown without cutting the displayed pose.
Slope elevation accounts for the anchor height and required camera clearance. Horizontal landing recovery
uses the existing orbit limiter instead of passing through two turn filters. Camera style labels Joint lock
as Experimental; saved style and joint settings keep their existing keys.

Turn-follow strength now controls travel yaw independently of the animated compass. At 10, cruising follows
travel direction directly. During a flat trick the travel heading stays stable; Trick turn still applies its
separate saved orbit. Follow responsiveness controls position and shot easing, without scaling cruising yaw.
After a verified vert ascent, Pop Off uses the existing downhill elevation controller during the return, including
airborne descent. Collision-constrained motion stops at its checked target instead of overshooting into walls.
Airborne floor corrections use the rider's viewing distance. Compact motion summaries stay once per second;
long verbose status reports are spaced five seconds apart. Gameplay verification remains pending.

Ramp collision lookahead now follows the requested camera path, excluding previous avoidance and landing-dip
corrections. Ramp clearance checks use the requested shoulder rather than feeding the last avoidance back.
With Pop Off, confirmed descending fakie travel starts the normal ramp turn before touchdown, including
returns with horizontal speed. During that turn the anchor sheds push lag; saved turn strength and settings remain.
Geometry still has priority in tight spaces. Offline checks passed; gameplay verification is pending.

Pop Off measures body-to-board compression in 3D, so leaning up a ramp is not mistaken for crouching.
Only the vertical part of actual body compression adjusts camera height. It keeps one support reference throughout riding. Ramp confidence no longer switches
between ground and board measurements. A valid support handoff carries its neutral reference continuously.
Ramp collision searches retain their side when enclosed. Gameplay ticks keep compact summaries without
per-frame diagnostic capture or synchronous diagnostic file writes. In-game verification is pending.

Ramp entry and release use continuous height, pitch and render-alignment weights, including when terrain labels change.
Flat takeoffs retain the ongoing release instead of resetting the camera blend in one frame.

With Pop height follow Off, ordinary flat tricks keep their selected eye height, pitch and reach while following
horizontally. Verified vert, raised landing surfaces, steep rails and big drops blend toward the normal Pop On
height/view target. The saved toggle stays Off. Two bounded forward surface probes (.15/.35 seconds ahead, up to
5 metres) check for a higher landing before contact; this does not wait for the camera to hit the ledge. Geometry
must be loaded and detected. A high flat ollie without a higher surface does not enable follow.

Terrain context retires on confirmed flat contact. A fresh flat trick uses its new takeoff height, not an old
ledge datum. Stair clearance is anticipated within the core collision response; the retired side/up escape
search remains disabled in Classic. A render correction that moves beneath a nearby ledge returns to the safe
core eye instead of adding a false vertical lift. Genuine buried-core clearance also corrects the view direction.

Saved settings, presets, bindings, crouch strength/types, lens/effects, Joint Lock and offboard features remain.
Only supported terrain contacts use the board/body gap for crouch compensation; airborne travel uses the physics
event history, not the drawn board pose. Tight spaces can still require arm contraction. No host physics rate,
watchdog or plugin limit is changed. Offline validation passed; in-game verification is pending.

CAMERA > Camera style offers Classic and Joint lock (Experimental). Classic keeps its saved Pop height follow, crouch, shake and
landing controls. Joint Lock uses the chosen Head, Chest, Feet, Knee, Hips or Skateboard point for vertical camera
translation, with Joint damping from immediate to a finite smooth follow. Its vertical motion reads world joint
positions without copying joint or board rotation into the camera. Missing joint reads fall back safely; changing
styles does not erase Classic tuning. Joint Lock suppresses the plugin's landing dip and shake.

The grind camera now retains more room while riding a downhill rail, including at low speed. Pop Off from a rail
eases into airborne and landing framing. Walls, ceilings and floor clearance can still require camera movement,
and the game physics rate and FPS cap are unchanged.

CAMERA > POP HEIGHT FOLLOW has its own On/Off control, strength and follow type. Camera height retains the previous
airborne follow by default; Camera pitch applies the selected follow through the view angle. Off keeps flat trick pops
level and holds the pre-flight FOV. Large descending drops restore downward landing visibility and follow the skater
vertically. Follow crouching Off removes the remaining grounded crouch response; saved crouch values are retained.

While riding, grinding or moving slowly in the air, the camera checks a bounded nearby future path from actual movement.
When a clear local route is available, it eases sideways or upward before the obstruction reaches the normal camera arm.
The choice is held to avoid searching back and forth, then eased out when space clears. Ordinary collision and final
floor/wall clearance remain authoritative; enclosed spaces can still require arm retraction.
Landing dip builds over several frames while retaining its existing depth, recovery and shake controls. Same-level
landings also ease the airborne eye into the riding height; descending steps and drops retain their collision response.
No game physics rate or FPS cap is changed.

Manual close-ups use current named HUD state and fresh manual/nose-manual trick events.
Blank or internal HUD labels cannot veto a named manual. When labels are unavailable,
a held partial right-stick input must overlap a sustained rolling deck pose before
it can start a close-up. Tilt alone, stick drift, full flicks, crouches, reverts, air and
grinds do not qualify. This controller fallback releases when its input or support ends;
its timing and behavior still need gameplay confirmation. No game input is consumed.


CAMERA > Crouch follow mode: Camera height keeps the previous body-height follow. Camera pitch keeps the eye height steady
and tilts down with the crouch. Follow crouching and Crouch follow strength apply to both modes. Old profiles default to
Camera height with Follow trick pop On, preserving their previous behavior.

Camera easing now uses the supplied render-frame time instead of callback dispatch gaps. This removes a reproduced timing
jitter case; it does not alter the game's physics rate or skater animation. ReSkate 2.1.4-2 excludes bounded file-loading and
compilation time from its execution deadline, but still enforces execution/average/raycast limits. Staged startup and bounded
ray work remain. No promise of zero crashes/timeouts or elimination of native animation/network jitter is made.

ADVANCED > Stability test aligns the final camera translation with the sampled body, removing the varying prediction lead
that could make the skater jitter against the view. The camera rig handles easing; no extra offset filter feeds corrections back into it.
It retains counted physics steps and continuous snap recovery. Turn it off to compare the legacy timing path.
The switch is saved; old presets default to On. Fixed chase fixes and Camera Sway are independent of this switch.
For a clean comparison, temporarily turn Camera shake off. Intentional shake and walking bob remain separate effects.
The plugin does not change the game's physics rate, FPS cap or skater transforms. Native animation, network jitter and
frame stalls may need a game-side fix. The log now records render timing, physics event rate and sample age during the test.

OFF THE BOARD > Camera Sway now controls the smooth recovery motion previously felt after a slam, replacing the added banking overlay.
On enables that camera momentum in Orbit or Shoulder without needing a crash, including during bails. Off clears it on the next
shown frame without a marker reset; ordinary body-following/bob and safe bail framing remain separate settings.
The saved toggle is retained. Marker returns reset momentum; remounting uses the normal transition and ends continuous sway.
Collision can override the lagged position. Stability test does not control whether Camera Sway is enabled.

CAMERA > Fixed distance now locks ordinary riding/pushing to the body's camera anchor, with no automatic speed FOV increase.
High/Low changes use the same render interpolation for distance and pose. Walls and floor clearance can still adjust distance. Manual, grind and air views retain their own controls. Speed-based mode
still uses its saved distance/FOV settings; those values are not reset when Fixed mode overrides them.

Settings use shorter labels and descriptions. Existing controls and saved preset keys are retained.
Valid older preset values are preserved, including values outside the menu's editing range.
Missing settings use current defaults; invalid settings fall back individually while other valid settings are retained.

Grinds keep the camera behind rail travel, without downhill terrain lift or slope-look tilt pulling the view overhead.
The automatic grind view limits downward aim to 25 degrees, adjusted by your existing grind pitch setting.
Collision protection and your saved distance, height and pitch controls remain active.

Marker returns recenter immediately, clearing velocity history, camera tracking and transition smoothing.
Long returns (8 m or more) briefly cover the cut in black, then fade back over 0.25 s. Allow the new overlay permission
for this visual transition. This is a plugin overlay; ReSkate's native fade cannot be triggered through the plugin API.

CAMERA > CROUCH: Crouch follow strength controls how much the camera dips with your body while preparing a trick.
100% keeps the original behavior, 50% follows half the body lowering, and 0% or Follow crouching Off keeps the framing level
with the riding surface. Off removes grounded body-height animation, including movement before the trick-setup state and body rebound.
Changes blend smoothly; the amount is remembered while off. Existing settings and presets start at 100%.
The camera first needs an upright riding sample: enabling it while already crouched takes effect after you stand up once.
Missing ground data or very steep surfaces fade the correction out; walls and ground clearance remain authoritative.

A Skate 3 style riding camera for ReSkate, as a plugin. While you ride (and through bails) it takes over the camera and
follows your movement: it lags and catches up with your speed, turns to show tricks, moves in close for manuals and grinds,
rises over you in big airs and tilts to show the landing, shakes, rattles and drops when you land (the camera kicks and shudders at the touchdown, and the Landing bounce drops it on impact and eases it back up), rumbles with speed, and widens the field of view with
speed. Off the board it stays with you too: an orbit camera for walking, running and bails that you steer with the right stick, with a close
over-the-shoulder style. In menus and in the Replay Editor the game's own camera is used.

Install
-------
* From the ReSkate launcher: GET MODS, search "Dynamic Camera", install.
* Or from Thunderstore: download the zip and install it with the launcher / r2modman as for any ReSkate mod.
* Or by hand: copy the Dynamic_Camera folder (the one holding reskate-plugin.json) into <game>\Mods\.

Switch the mod on in the mod list, start the game, and ride. Open the ReSkate menu, PLUGINS, "Dynamic Camera" for the settings:
PRESETS, CAMERA, FOLLOW & MOVEMENT, TRICKS & CLOSE-UPS, AIR & LANDING, CAMERA EFFECTS, OFF THE BOARD, ADVANCED. Every change
applies at once and is saved. A fresh install starts from the built-in "Default" preset.

Controls
--------
* L3 switches shoulder side automatically, on and off the board. R3 switches Low / High on the board (setting: Switch camera view with R3, enabled by default). No manual controller binding is needed.
* Settings > Binds > PLUGINS defaults: Shoulder switch = L3; High low switch = R3. Existing custom bindings remain available; direct stick clicks also work. A press seen by both routes acts once.
* Toggle mod remains Ctrl+Shift+D; Offboard view remains Ctrl+Shift+V. On foot, R3 recentres and double R3 switches Orbit / Shoulder automatically.
* Controller support follows ReSkate's controller mapping, including Xbox/XInput and supported PlayStation pads. Other controllers need to be recognised by ReSkate or mapped through Steam Input/XInput.
* Console: dyncam 0|1|toggle, dyncam_angle, dyncam_shake, dyncam_fov, dyncam_shotfov, dyncam_shoulder, dyncam_side, dyncam_log,
  dyncam_dump, dyncam_presets. The s3cam names work as well.

Presets
-------
Presets are .json files in the plugin's data folder (Mods\.reskate_plugin_data\<the plugin's folder name>\presets). "Open preset
folder" shows it. The built-in preset is "Default": the tuned baseline the camera starts with, and what "Reset to defaults" goes
back to. "Manage presets..." saves, loads, renames and deletes presets and imports a preset file. The format is the one of the Dynamic Camera build for the ReSkate DLL, so a preset file can be copied
between them.

Settings do not carry over from the DLL version by themselves: export a preset there (it is a file in
%LOCALAPPDATA%\ReSkate\Dynamic Camera Presets) and import it here.

Off the board
-------------
Off-board camera (OFF THE BOARD tab) is Dynamic by default: the camera keeps the view when you step off the board, walk, run, bail
or land a hippy jump, and the right stick looks around. Board to foot and back is a smooth blend (Board / foot transition time).
* Style: Orbit (behind and above, 2.8 m) or Shoulder (close, over one shoulder, like the Arkham games). A style fills the sliders,
  which you can then change. The shoulder side is the riding one (Switch shoulder side).
* Distance, Height, Look height, Horizontal offset and Field of view frame the shot; Follow smoothing and Turn smoothing set how
  softly it moves. Level with the body keeps steps and stairs from bobbing the camera; Bobbing strength puts a walking bob back.
* Recentre after: while you move and leave the right stick alone, the camera swings behind you (0 = never). Standing still never
  recentres. R3 swings it behind you at once; double-click R3 to switch Orbit / Shoulder (each keeps its own sliders).
* Match walking to the view: the game steers walking with a hidden camera of its own that the plugin cannot read, so it estimates
  where that faces from how you walk and slowly turns the view toward it, so "forward" on the left stick is forward on the screen.
* Bails are framed whole and further out (Bail distance).
* Game gives the old behaviour: the game's own camera on foot, reached with an eased hand-back.

Known differences from the DLL version
--------------------------------------
* The Native+ style is not included (only the Full style).
* With Off-board camera set to Game, the plugin cannot see the game's camera while it holds the view, so stepping off the board eases to where the game's camera is expected to be (learned while you are on foot; setting: Hand-back blend time) and then hands it back. Menus, pause and having no skater hand it back at once; switching off on foot eases out.
* The mouse does not turn the off-board view (the plugin API reads it only with the right mouse button held and moves the cursor), and the walking-direction match needs a gamepad.
* The game's field of view and camera are read just before the camera is taken; changing the game's FOV while riding applies
  at the next take.
* Manuals (also nose manuals) use the current score HUD state. A current named non-manual releases the close-up; blank HUD labels are treated as unknown. A partial-stick hold corroborated by a sustained rolling deck pose also works when HUD labels are unavailable. Named trick events provide another fallback: the close-up starts as the manual is named and ends with its landing note, or when you leave the ground, grind, get off the board or start another trick, or when the board has lain level for 0.4 s once the manual has run for half a second (the game writes the landing note only when the whole trick line ends). Reverts and powerslides do not give it. The board's tilt (the deck's rotation when the game gives it, else the angle between your feet) places the close-up and tells when the board is level.
* The camera casts at most about 60 world rays a tick (the plugin limit is 64); in a long jump a landing prediction can be
  cut short.
* Whatever the cause, a sudden jump of the view (position, direction or field of view in a single frame) is eased over about a third of a second instead of shown, and the camera log counts them.
* Camera logging (dyncam_log 1) records compact events and summaries in ReSkate.log. Gameplay no longer captures frame histories or writes diagnostic files.

Credits and licence
-------------------
Adapted from SK8-ENGINE and the skate-3-rust-engine research of the Skate 3 camera, and from the Dynamic Camera for ReSkate
(chipeu/ReSkate-S3-CAM). Licensed under the GNU General Public License v3.0 (see LICENSE).
