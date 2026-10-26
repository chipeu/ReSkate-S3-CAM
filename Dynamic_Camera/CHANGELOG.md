1.1.0
-----
Plugin test build 7
* Manuals (and nose manuals) now come from the game's trick list as they start: the close-up begins when the manual is named and ends with its landing note, or when you leave the ground, grind, get off the board or start another trick. Reverts and powerslides no longer give the close-up (the game's skate state 101 is theirs, not the manual's). A manual named in the air, straight out of a flip trick, starts as soon as you roll. Repeated notes (the music ticker, landing notes that come again) are ignored.
Plugin test build 6
* No more snaps: every view the plugin is about to show passes a last check. If the camera's offset from you changes by more than 0.25 m in a frame, the view turns more than 8 degrees in a frame, or the field of view moves more than 2 degrees in a frame, the view eases from what is on screen to the new one over about a third of a second instead of jumping. Walls pushing the camera in, and teleports, are not smoothed. The camera log counts the smoothed jumps by cause and by which camera path made them ("N snaps smoothed" on the "off" line, one line for each in verbose logs).
* Getting back on the board no longer snaps the view: the first frame after a remount used to lose the camera's up and down angle and turn 20 to 25 degrees at once.
* Standing or walking slowly on foot is no longer taken for a pause of the game. It handed the camera back and took it again over and over, each time with a jump. Only missing game updates, or, on the board at speed, a root that stands still, mean a pause now.
* The game's field of view is only used as the camera's base when it is a normal one (50 to 100 degrees). A zoomed or menu screen reporting 28 degrees made the take zoom in.
* A retake after a short release (a menu, a pause) starts from the view that was last shown when the game's camera does not look like a normal one.
* Manuals now come from the game's skate state (101, which the game reports while you hold a manual): on after 0.06 s in it, off after 0.15 s out of it, so landing into a manual, a manual after a flip trick, and a manual right after another all get the close-up on time. The trick list no longer starts or ends a manual; with dyncam_log 1 it writes each trick name with the state it came at.
Plugin test build 5
* Off the board: the camera no longer switches off when you step off the board. It keeps the view while you walk, stand, run, bail and land a hippy jump on foot, and you look around with the right stick. Board to foot and foot to board are blended (sine ease), so there are no cuts.
* New tab OFF THE BOARD: Off-board camera (Dynamic or Game), Style (Orbit or Shoulder, the Arkham-style walk), Distance, Height, Look height, Horizontal offset, Field of view, Follow smoothing, Turn smoothing, Stick speed, Invert Y, Recentre after, Match walking to the view, Level with the body, Bobbing strength, Bail distance, Board / foot transition time. Everything eases; nothing snaps.
* The camera swings behind you after a while of walking without touching the right stick (standing still never recentres). R3 on foot swings it behind you at once, eased.
* "Match walking to the view" slowly turns the view toward the direction the left stick walks "forward", so the stick and the screen agree. The game steers walking with its own hidden camera, which the plugin cannot read; it estimates it from how you walk.
* Bails off the board are framed whole (head and hips), further out, with a slower recentre.
* Walls and the ground are handled by a spring arm: the camera slides in fast and comes back slowly, and is lifted instead of going under the ground.
* Choosing Game for Off-board camera gives the old behaviour (the eased hand-back to the game's camera). Menus, pause and having no skater still hand the camera back at once; switching the camera off on foot eases out.
* The mouse does not turn the view on foot (the plugin API's mouse look needs the right mouse button and moves the cursor).
* Old settings and presets load unchanged; the new values are saved as S3Cam.OffBoard.*.
Plugin test build 4
* Binds: "camera on / off" (Ctrl+Shift+D) and "switch shoulder side" (Ctrl+Shift+S) now appear on Settings > Binds under PLUGINS; the keys can be changed or cleared there.
* Manuals: the board's pitch is read from the angle between the feet when the game gives no deck pose, so manuals are detected and the close-up has a board centre to aim at. The log says which source is used and how many manuals were seen.
* Stepping off the board (or finishing a hippy jump) eases the camera to where the game's own camera will be before handing it back. "Hand-back blend time" on the ADVANCED tab sets how long (0 hands back at once).
Plugin test build 3
* Loading: the modules load one per tick instead of all at once, so the plugin starts within the game's 50 ms limit.
Plugin test build 2
* Landing shake after big airs: the view holds still for a moment at touchdown so the landing kick shows. Not on ramps and steep slopes.
Plugin test build 1
* First release as a ReSkate plugin (no DLL needed): the Dynamic Camera 1.0.2 camera ported to the plugin API.
* Same camera, settings, labels, presets (same JSON and S3Cam.* keys) and console commands (dyncam, dyncam_*, s3cam_* aliases).
* Menu page under PLUGINS with the same tabs; presets are managed from a window (save, load, rename, delete, import a file).
* Camera logging writes files to the data folder.
* Not included: the Native+ style.
