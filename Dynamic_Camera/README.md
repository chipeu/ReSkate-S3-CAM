Dynamic Camera
==============

A Skate 3 style riding camera for ReSkate, as a plugin. While you ride (and through bails) it takes over the camera and
follows your movement: it lags and catches up with your speed, turns to show tricks, moves in close for manuals and grinds,
rises over you in big airs and tilts to show the landing, shakes with speed and landings, and widens the field of view with
speed. On foot, in menus and in the Replay Editor the game's own camera is used.

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
* Binds page of ReSkate's settings: "Dynamic Camera on / off" and "Switch shoulder side" (L3 in Skate 3). Both start unbound.
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

Known differences from the DLL version
--------------------------------------
* The Native+ style is not included (only the Full style).
* The camera cannot fade back to the game's camera when you step off the board: it is handed back at once.
* The game's field of view and camera are read just before the camera is taken; changing the game's FOV while riding applies
  at the next take.
* The board's tilt for manuals comes from the deck's rotation, not from the board's physics bodies.
* The camera casts at most about 60 world rays a tick (the plugin limit is 64); in a long jump a landing prediction can be
  cut short.
* Camera logging (dyncam_log 1) writes files to the data folder (diag/) instead of the ReSkate log.

Credits and licence
-------------------
Adapted from SK8-ENGINE and the skate-3-rust-engine research of the Skate 3 camera, and from the Dynamic Camera for ReSkate
(chipeu/ReSkate-S3-CAM). Licensed under the GNU General Public License v3.0 (see LICENSE).
