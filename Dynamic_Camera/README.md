Dynamic Camera
==============

A Skate 3 style riding camera for ReSkate, as a plugin. While you ride (and through bails) it takes over the camera and
follows your movement: it lags and catches up with your speed, turns to show tricks, moves in close for manuals and grinds,
rises over you in big airs and tilts to show the landing, shakes with speed and landings, and widens the field of view with
speed. Off the board it stays with you too: an orbit camera for walking, running and bails that you steer with the right stick, with a close
over-the-shoulder style. In menus and in the Replay Editor the game's own camera is used.

Install
-------
* From the ReSkate launcher: GET MODS, search "Dynamic Camera", install.
* Or from Thunderstore: download the zip and install it with the launcher / r2modman as for any ReSkate mod.
* Or by hand: copy the Dynamic_Camera folder (the one holding reskate-plugin.json) into <game>\Mods\.

Switch the mod on in the mod list, start the game, and ride. Open the ReSkate menu, PLUGINS, "Dynamic Camera" for the settings:
PRESETS, CAMERA, FOLLOW & MOVEMENT, TRICKS & CLOSE-UPS, AIR & LANDING, CAMERA EFFECTS, ADVANCED. Every change applies at once and
is saved.

Controls
--------
* Settings > Binds > PLUGINS: "Dynamic_Camera: camera on / off" (Ctrl+Shift+D) and "Dynamic_Camera: switch shoulder side" (Ctrl+Shift+S, the L3 swap of Skate 3). Record another key or clear either there.
* R3 switches between the Low and High camera views (setting: Switch camera view with R3).
* Console: dyncam 0|1|toggle, dyncam_angle, dyncam_shake, dyncam_fov, dyncam_shotfov, dyncam_shoulder, dyncam_side, dyncam_log,
  dyncam_dump, dyncam_presets. The s3cam names work as well.

Presets
-------
Presets are .json files in the plugin's data folder (Mods\.reskate_plugin_data\Dynamic_Camera\presets). "Open preset folder"
shows it. The built-in presets are "Skate 3" and "Close & low". "Manage presets..." saves, loads, renames and deletes presets and
imports a preset file. The format is the one of the Dynamic Camera build for the ReSkate DLL, so a preset file can be copied
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
  recentres. R3 swings it behind you at once.
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
* Manuals (also nose manuals) are found from the game's trick list: the close-up starts as the manual is named and ends with its landing note, or when you leave the ground, grind, get off the board or start another trick. Reverts and powerslides do not give it. The board's tilt (the deck's rotation when the game gives it, else the angle between your feet) only places the close-up.
* The camera casts at most about 60 world rays a tick (the plugin limit is 64); in a long jump a landing prediction can be
  cut short.
* Whatever the cause, a sudden jump of the view (position, direction or field of view in a single frame) is eased over about a third of a second instead of shown, and the camera log counts them.
* Camera logging (dyncam_log 1) writes the full detail to the data folder (diag/camera_log.txt); the event lines and a summary
  a second also go to the ReSkate log.

Credits and licence
-------------------
Adapted from SK8-ENGINE and the skate-3-rust-engine research of the Skate 3 camera, and from the Dynamic Camera for ReSkate
(chipeu/ReSkate-S3-CAM). Licensed under the GNU General Public License v3.0 (see LICENSE).
