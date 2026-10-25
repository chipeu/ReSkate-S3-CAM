-- The DYNAMIC CAMERA page: Extension/UI/Overlay/skate_menu_camera.cpp on reskate.menu.page. A switch card on top and a row of
-- tabs (PRESETS, CAMERA, FOLLOW & MOVEMENT, TRICKS & CLOSE-UPS, AIR & LANDING, CAMERA EFFECTS, OFF THE BOARD, ADVANCED); each tab is a few cards
-- of toggles, sliders and dropdowns with the DLL's labels, ranges and formats. A change applies to the camera at once (the glue
-- sees the new revision) and is saved to storage.
--
-- Differences from the DLL's page (the plugin menu has fewer widgets):
--  * Descriptions: toggles and dropdowns carry them as their help text; a slider has none, so its description is a muted note
--    under it. "Show descriptions" (top card) hides those notes.
--  * No greyed-out controls: a control that depends on another one stays on screen and simply does nothing while that one is off.
--  * No Native+ style, so the style choice, LANDING BOUNCE and NATIVE+ SETTINGS are not here (a note says so).
--  * No text field: the preset name is typed in a dialog (Manage presets...), which also lists, loads, renames, deletes and
--    imports presets. There is no clipboard in the plugin API: share a preset as its file (Open preset folder) and import with the
--    dialog's file button.
--  * Off the board: the OFF THE BOARD tab (off-board camera, style, framing, feel) is the plugin's own; "Board / foot transition time" is there, "Hand-back blend time" (ADVANCED) is for the Game option.
--
--   Menu.install{ store = store, glue = glue }  registers the page; Menu.on_dialog(e) handles the `throwdown_ui` event.
--   Menu.build(ui) is the page's build function (exposed for the tests).

local Settings = require("settings")
local Presets = require("presets")
local has_off, Off = pcall(require, "offboard")
if not has_off then
	Off = nil
end

local Menu = {}

local clamp, max, min, floor = math.clamp, math.max, math.min, math.floor
local Angle, Shoulder, DistMode, ManualMode = Settings.CameraAngle, Settings.ShoulderSide, Settings.DistanceMode, Settings.ManualDistanceMode

Menu.TABS = { "PRESETS", "CAMERA", "FOLLOW & MOVEMENT", "TRICKS & CLOSE-UPS", "AIR & LANDING", "CAMERA EFFECTS", "OFF THE BOARD", "ADVANCED" }
Menu.DIALOG_ID = "dyncam_presets"

local deps
local state = {
	tab = 1,
	position_for = nil, -- 0 = the Low camera, 1 = the High one; nil until first drawn
	feedback = nil, -- a line to show on top (a refused value, a reset)
	selected = nil, -- the PRESETS tab's chosen preset name
	result = "", -- the last preset result line
	result_ok = true,
	armed_delete = nil,
	armed_overwrite = nil,
	scan_at = 0.0,
	dialog_name = "",
	dialog_row = 0,
	dialog_message = "",
	dialog_rows = {},
}
Menu.state = state

-- ---------------------------------------------------------------- the build
function Menu.build(ui)
	local store, glue = deps.store, deps.glue
	local draft = Settings.copy(store.settings)
	local opts = Settings.copy(store.options)
	local s_changed, o_changed = false, false
	local help = store.show_help
	local discard = false -- a preset load or a reset: this build's edits would undo it

	local function mark(g)
		if g == opts or g == opts.offboard then
			o_changed = true
		else
			s_changed = true
		end
	end
	local function note(text)
		if help and text then
			ui:note(text)
		end
	end
	local function toggle(id, label, tip, g, field)
		local v = ui:toggle(id, label, g[field], help and tip or nil)
		if v ~= g[field] then
			g[field] = v
			mark(g)
		end
	end
	local function slider(id, label, tip, g, field, lo, hi, fmt)
		hi = max(hi, lo + 0.01)
		local shown = clamp(g[field], lo, hi)
		local v = ui:slider(id, label, shown, lo, hi, fmt)
		note(tip)
		if v ~= shown then
			g[field] = v
			mark(g)
		end
	end
	-- A strip of options: `index` is 1-based; returns the new index and whether it changed. Tips are joined into the help.
	local function pick(id, label, names, index, tips)
		local text
		if help and tips then
			local parts = {}
			for i, n in names do
				parts[#parts + 1] = n .. ": " .. tips[i]
			end
			text = table.concat(parts, " ")
			if #text > 300 then
				text = string.sub(text, 1, 297) .. "..."
			end
		end
		local v = ui:dropdown(id, label, names, index, text)
		return v, v ~= index
	end

	-- The Low / High switch shared by the position, distance, manual and grind cards.
	local function camera_for(id, label, low_tip, high_tip)
		if state.position_for == nil then
			state.position_for = draft.angle == Angle.High and 1 or 0
		end
		local v = pick(id, label, { "Low", "High" }, state.position_for + 1, { low_tip, high_tip })
		state.position_for = v - 1
	end
	local function framing()
		return state.position_for == 1 and draft.framing_high or draft.framing
	end

	-- ---- the switch on top of every tab
	if state.feedback then
		ui:warn(state.feedback)
		state.feedback = nil
	end
	ui:card("DYNAMIC CAMERA")
	ui:note("Settings for the camera: follow, tricks, jumps, landings and effects, and the view off the board.")
	local on = ui:toggle("main_on", "Dynamic Camera", store.enabled,
		"Enables the camera. In menus and the Replay Editor the game's camera takes over. On foot, see the OFF THE BOARD tab.")
	if on ~= store.enabled then
		store:set_enabled(on)
	end
	ui:info("Status", glue:status())
	local show = ui:toggle("show_help", "Show descriptions", store.show_help, "Shows a short description under each slider.")
	if show ~= store.show_help then
		store:set_show_help(show)
	end

	state.tab = ui:tabs("tabs", Menu.TABS, state.tab)
	local tab = state.tab

	if tab == 1 then
		-- ---- PRESETS
		if reskate.time.now() >= state.scan_at then
			state.scan_at = reskate.time.now() + 2000 -- dropped-in files show up by themselves, here only
			Presets.refresh()
		end
		local list = Presets.list()
		local names, index = {}, 1
		for i = 1, min(#list, 32) do
			names[i] = list[i].name
			if names[i] == state.selected then
				index = i
			end
		end
		if state.selected == nil or names[index] ~= state.selected then
			state.selected = names[1]
			index = 1
		end
		ui:card("PRESETS", "Save, load, and manage camera setups")
		index = ui:dropdown("preset_pick", "Preset", names, index,
			help and "The saved camera setups. 'Manage presets...' shows them all (this list holds the first 32)." or nil)
		local picked = names[index]
		if picked ~= state.selected then
			state.selected = picked
			state.armed_delete = nil
		end
		local chosen
		for _, e in list do
			if e.name == state.selected then
				chosen = e
			end
		end
		local function answer(r)
			state.result, state.result_ok = r.message, r.ok
			state.armed_delete, state.armed_overwrite = nil, nil
		end
		if ui:button("preset_load", "Load preset", true) then
			answer(Presets.load(store, state.selected))
			discard = true
		end
		note("Applies the selected preset without changing whether the camera is enabled.")
		local saved = chosen ~= nil and not chosen.built_in
		local deleting = saved and state.armed_delete == state.selected
		if ui:button("preset_delete", deleting and "Really delete?" or "Delete preset") then
			if not saved then
				state.result, state.result_ok = "Built-in presets cannot be deleted.", false
			elseif deleting then
				answer(Presets.delete(state.selected))
				state.selected = nil
			else
				state.result, state.result_ok = "Click Really delete? to remove '" .. state.selected .. "'.", true
				state.armed_delete = state.selected
			end
		end
		if ui:button("preset_manage", "Manage presets... (save, rename, import)") then
			Menu.open_dialog("")
		end
		note("Opens a window to save the camera under a name, rename or delete presets, and import a preset file.")
		if ui:button("preset_folder", "Open preset folder") then
			answer(Presets.reveal())
		end
		note("Shows the preset folder in Explorer. Copy a .json file out to share it, or in to add one: it appears in the list by itself.")
		if ui:button("preset_refresh", "Refresh preset list") then
			state.scan_at = 0.0
			state.result, state.result_ok = "Preset list refreshed.", true
		end
		if state.result ~= "" then
			if state.result_ok then
				ui:note(state.result)
			else
				ui:warn(state.result)
			end
		end
	elseif tab == 2 then
		-- ---- CAMERA
		ui:card("CAMERA", "Camera style, view and position")
		ui:note("Camera style: this plugin has the Full style only (it controls the whole view). Native+ is not included.")
		local h, changed = pick("cam_height", "Camera view", { "Low", "High" }, draft.angle == Angle.High and 2 or 1,
			{ "The camera sits low, close to the ground.", "The camera sits higher and looks down more." })
		if changed then
			draft.angle = h == 2 and Angle.High or Angle.Low
			s_changed = true
		end
		toggle("o_r3", "Switch camera view with R3", "R3 switches between the Low and High camera views, also during bails.", opts, "follow_game_height")

		ui:card("CAMERA POSITION")
		camera_for("pos_for", "Edit camera position for", "Edit the position of the Low camera.", "Edit the position of the High camera.")
		local fr = framing()
		slider("pos_height", "Camera elevation angle",
			"How high the camera sits around you, as an angle. Higher: further above you, looking down. Lower: closer to the ground.",
			fr, "height_degrees", -30, 45, "%.1f degrees")
		slider("pos_pitch", "View aim angle", "Aims the view higher or lower without moving the camera. Higher: more sky. Lower: more ground.",
			fr, "pitch_degrees", -30, 30, "%.1f degrees")

		ui:card("CAMERA DISTANCE", "Low and High each have their own")
		camera_for("dist_for", "Edit camera distance for", "Edit the distance of the Low camera.", "Edit the distance of the High camera.")
		local ride = state.position_for == 1 and draft.ride_distance_high or draft.ride_distance
		local m, mchanged = pick("dist_mode", "Camera distance mode", { "Speed-based", "Fixed" }, ride.mode == DistMode.Fixed and 2 or 1, {
			"The camera sits closer when you are slow and further back at top speed.",
			"The camera stays the same distance at every speed, and the game's own FOV widening at speed is left out (Speed-based FOV still applies). Only a big air moves the camera back, as far as it needs to keep you in view.",
		})
		if mchanged then
			ride.mode = m == 2 and DistMode.Fixed or DistMode.Speed
			s_changed = true
		end
		if ride.mode == DistMode.Fixed then
			slider("dist_fixed", "Camera distance",
				"How far behind you the camera stays while riding, at any speed. A wall can still bring it closer for a moment. Manual and grind close-ups have their own distances.",
				ride, "fixed", 0.5, 10, "%.2f m")
		else
			slider("dist_slow", "Camera distance at low speed", "How far behind you the camera sits when standing or riding slowly.",
				ride, "slow", 0.5, ride.fast, "%.2f m")
			slider("dist_fast", "Camera distance at top speed",
				"How far behind you the camera sits when you ride fast. It eases between the two distances as your speed changes.",
				ride, "fast", ride.slow, 10, "%.2f m")
		end

		ui:card("CAMERA COLLISION", "Walls, poles and the ground")
		toggle("col_on", "Camera collision", "The camera moves in front of walls instead of going through them.", draft.collision, "enabled")
		toggle("col_auto", "Automatic collision handling",
			"On: the camera handles walls and the ground by itself, and lets thin things like poles and rails pass. Off: the values in MANUAL COLLISION SETTINGS (ADVANCED tab) are used.",
			draft.collision, "automatic")
	elseif tab == 3 then
		-- ---- FOLLOW & MOVEMENT
		local follow = draft.follow
		ui:card("FOLLOW", "How the camera follows your riding")
		slider("fl_strength", "Follow responsiveness", "How quickly the camera catches up with you. Higher: less lag. Lower: more lag. 1x is normal.",
			follow, "strength", 0.2, 4, "%.2fx")
		slider("fl_horizontal", "Turn-follow strength",
			"How strongly the camera turns with your direction. 0: off, the normal lazy swing. 10: locked to your direction, so flat tricks, reverts and spins do not turn it and carving does.",
			follow, "horizontal", 0, 10, "%.1f")
		toggle("fl_dynamic", "Reduce follow lag at speed", "The faster you go, the less the camera lags behind you.", follow, "dynamic")
		slider("fl_dspeed", "Speed for max follow boost",
			"The speed at which the follow boost is full. Higher: you must go faster to get it. Lower: you get it at lower speeds.",
			follow, "dynamic_speed", 0.5, 60, "%.1f m/s")
		slider("fl_boost", "Speed-based follow boost", "Extra follow responsiveness at that speed. Higher: the camera lags even less. Lower: it changes less.",
			follow, "dynamic_boost", 0, 3, "+%.2f")

		local sh = draft.shoulder
		ui:card("SHOULDER CAMERA")
		local mode, mchanged = pick("sh_mode", "Shoulder camera", { "Off", "Manual", "Auto" },
			sh.mode == Shoulder.Manual and 2 or (sh.mode == Shoulder.Auto and 3 or 1),
			{ "You stay in the middle of the screen.", "You pick the side below.", "The camera sits on the toe side of your stance." })
		if mchanged then
			sh.mode = mode == 2 and Shoulder.Manual or (mode == 3 and Shoulder.Auto or Shoulder.Off)
			s_changed = true
		end
		local side, schanged = pick("sh_side", "Shoulder side", { "Left", "Right" }, sh.side == 1 and 2 or 1, {
			"The camera sits to your left, so you are right of the screen centre. Used when Shoulder camera is Manual.",
			"The camera sits to your right, so you are left of the screen centre. Used when Shoulder camera is Manual.",
		})
		if schanged then
			sh.side = side == 2 and 1 or -1
			s_changed = true
		end
		local stance, tchanged = pick("sh_stance", "Auto shoulder stance", { "Regular", "Goofy" }, sh.goofy and 2 or 1, {
			"Regular rides with the toes to the right; riding switch flips it. Used when Shoulder camera is Auto.",
			"Goofy rides with the toes to the left. Used when Shoulder camera is Auto.",
		})
		if tchanged then
			sh.goofy = stance == 2
			s_changed = true
		end
		slider("sh_offset", "Shoulder offset", "Higher: you sit further to the side of the screen. Lower: closer to the middle.", sh, "offset", 0, 1, "%.2f m")
		slider("sh_time", "Shoulder switch time", "Higher: the camera slides across slowly. Lower: it slides across quickly.", sh, "switch_time", 0, 5, "%.2f s")
		ui:note("Bind 'Switch shoulder side' on ReSkate's Binds page (L3 in Skate 3) to switch shoulder sides.")

		local look = draft.look
		ui:card("SLOPE TILT")
		toggle("sl_on", "Slope tilt", "On the ground, the view tilts down going downhill and up going uphill.", look, "slope_look")
		slider("sl_strength", "Slope tilt strength", "Higher: the view tilts more on hills. Lower: it stays more level.", look, "slope_look_strength", 0, 1, "%.2f")
		slider("sl_response", "Tilt transition time",
			"How quickly the view's up and down tilt settles. Also sets the timing of the landing tilt, changes to the view aim angle, and the manual and grind camera targets. Higher: slower. Lower: right away.",
			look, "response_time", 0.15, 5, "%.2f s")
	elseif tab == 4 then
		-- ---- TRICKS & CLOSE-UPS
		local yaw = draft.trick_yaw
		ui:card("TRICK CAMERA TURN", "Camera turns during tricks")
		ui:note("The camera turns to show the trick, holds that angle while you keep tricking, and returns behind you after landing.")
		toggle("ty_on", "Trick camera turn", "Turns the camera to the side during tricks.", yaw, "enabled")
		slider("ty_angle", "Trick camera angle", "Higher: the camera turns further to the side. Lower: it stays closer behind you.", yaw, "angle_degrees", 0, 45, "%.0f degrees")
		local side, changed = pick("ty_side", "Trick camera direction", { "Auto", "Left", "Right" }, yaw.side < 0 and 2 or (yaw.side > 0 and 3 or 1), {
			"Follows the shoulder side, or your stance if the shoulder is off.", "The camera turns to your left.", "The camera turns to your right.",
		})
		if changed then
			yaw.side = side == 2 and -1 or (side == 3 and 1 or 0)
			s_changed = true
		end
		toggle("ty_air", "Air trick camera turn", "Turns the camera during airs and flip tricks.", yaw, "in_air")
		toggle("ty_grind", "Grind camera turn", "Turns the camera while grinding.", yaw, "on_grinds")
		toggle("ty_manual", "Manual camera turn", "Turns the camera while manualling.", yaw, "on_manuals")
		slider("ty_minair", "Minimum airtime for camera turn",
			"Higher: you must be in the air longer before the camera turns, so a plain ollie stays centred. Lower: it turns sooner.",
			yaw, "min_air_time", 0, 3, "%.2f s")
		slider("ty_in", "Camera turn-in time", "Higher: the camera turns slowly. Lower: it turns quickly.", yaw, "in_time", 0.15, 5, "%.2f s")
		slider("ty_hold", "Camera angle hold time",
			"Higher: the camera stays turned longer after the trick. Lower: it comes back sooner. A new trick keeps the angle.", yaw, "hold_time", 0, 5, "%.2f s")
		slider("ty_return", "Camera return time", "Higher: the camera is slower to come back behind you. Lower: it comes back quicker.",
			yaw, "return_time", 0.15, 10, "%.2f s")

		local cmd = Settings.closeup_min_distance
		ui:card("MANUAL CAMERA")
		camera_for("man_for", "Edit manual camera for", "Edit the manual close-up of the Low camera.", "Edit the manual close-up of the High camera.")
		local fr = framing()
		toggle("man_on", "Manual close-up", "On: the camera moves in close for manuals and nose manuals. Off: it keeps its normal distance.", fr, "manual_camera")
		local mm, mchanged = pick("man_mode", "Manual camera distance mode", { "Fixed close-up", "Speed-based" }, fr.manual_mode == ManualMode.Speed and 2 or 1, {
			"The camera stays at the manual camera distance at every speed.",
			"The camera sits at the minimum distance when slow and eases out to the maximum at 8 m/s and faster.",
		})
		if mchanged then
			fr.manual_mode = mm == 2 and ManualMode.Speed or ManualMode.Fixed
			s_changed = true
		end
		if fr.manual_mode == ManualMode.Speed then
			slider("man_min", "Minimum manual camera distance", "How far back the camera sits in a slow manual. It never comes closer than this.",
				fr, "manual_min_distance", cmd, fr.manual_max_distance, "%.2f m")
			slider("man_max", "Maximum manual camera distance",
				"How far back the camera sits in a manual at 8 m/s and faster. It never goes further than this.", fr, "manual_max_distance",
				fr.manual_min_distance, 8, "%.2f m")
		else
			slider("man_dist", "Manual camera distance", "How far back the camera sits in a manual, at every speed. Separate from the main camera distance.",
				fr, "manual_distance", cmd, 8, "%.2f m")
		end
		slider("man_height", "Manual camera elevation angle",
			"Higher: the camera sits further above you in a manual. Lower: closer to the ground. Separate from the main elevation angle.",
			fr, "manual_height_degrees", -30, 45, "%.1f degrees")
		slider("man_pitch", "Manual view aim angle", "Where the view points in a manual. Higher: up. Lower: down. Separate from the main view aim angle.",
			fr, "manual_pitch_degrees", -30, 30, "%.1f degrees")
		slider("man_focus", "Manual camera target", "0: the camera looks at the board. 1: it looks at your upper body.", draft.look, "manual_focus", 0, 1, "%.2f")

		ui:card("GRIND CAMERA")
		camera_for("grd_for", "Edit grind camera for", "Edit the grind close-up of the Low camera.", "Edit the grind close-up of the High camera.")
		fr = framing()
		toggle("grd_on", "Grind close-up", "On: grinds use their own close-up view. Off: the camera keeps its normal view.", fr, "grind_camera")
		slider("grd_dist", "Grind camera distance", "How far back the camera sits in a grind. Separate from the main camera distance.",
			fr, "grind_distance", cmd, 8, "%.2f m")
		slider("grd_height", "Grind camera elevation angle",
			"Higher: the camera sits further above you in a grind. Lower: closer to the ground. Separate from the main elevation angle.",
			fr, "grind_height_degrees", -30, 45, "%.1f degrees")
		slider("grd_pitch", "Grind view aim angle", "Where the view points in a grind. Higher: up. Lower: down. Separate from the main view aim angle.",
			fr, "grind_pitch_degrees", -30, 30, "%.1f degrees")
		slider("grd_focus", "Grind camera target", "0: the camera looks at the board. 1: it looks at your upper body.", draft.look, "grind_focus", 0, 1, "%.2f")

		ui:card("CLOSE-UP SETTINGS", "Shot changes, manuals and grinds")
		slider("cu_blend", "Camera transition time multiplier",
			"Multiplies how long the camera takes to change from one shot to the next (riding, tricks, manuals, grinds) and to move into a close-up. Higher: slower. Lower: quicker. 1x is normal. Close-up return time and the trick camera turn times are not affected.",
			draft.look, "shot_blend", 0.25, 4, "%.2fx")
		toggle("cu_board", "Track board in close-ups",
			"On: in manuals and grinds the camera circles and aims at your board. Off: it aims at your body as usual.", draft.look, "board_anchor")
		slider("cu_exit", "Close-up return time",
			"How long the camera takes to move back out after a manual or grind ends (a trick, or riding off). Higher: slower. Lower: quicker.",
			draft.look, "closeup_exit_time", 0.2, 3, "%.2f s")
	elseif tab == 5 then
		-- ---- AIR & LANDING
		local air = draft.air_camera
		ui:card("BIG AIR", "Camera movement while jumping")
		toggle("ba_keep", "Keep skater in frame", "Aims the camera so you do not leave the screen while you are in the air.", air, "keep_in_frame")
		slider("ba_follow", "Camera rise ratio",
			"How much of your height gain the camera follows in a big air. Higher: it rises more with you. Lower: it stays near the height you took off from.",
			air, "follow_height", 0.25, 1, "%.2f")
		slider("ba_rise", "Big-air camera rise angle",
			"Higher: in a big air the camera swings further up over you and looks down at the landing. Lower: it stays behind you.",
			air, "rise_degrees", 0, 40, "%.0f degrees")
		slider("ba_full", "Jump height for max big-air rise",
			"Jump height (or drop below takeoff) for the full rise. Higher: only very big jumps or drops get it. Lower: even small ones do.",
			air, "rise_full_height", 0.1, 20, "%.1f m")
		slider("ba_ease", "Big-air rise transition time", "Higher: the rise builds and settles back more slowly. Lower: it reacts faster.",
			air, "ease_time", 0.15, 3, "%.2f s")

		local look = draft.look
		ui:card("LANDING VIEW")
		toggle("lv_on", "Landing camera tilt",
			"When you jump down to something lower (stairs, gaps), the camera tilts down to show where you will land.", look, "landing_look")
		slider("lv_strength", "Landing tilt strength", "Higher: the camera tilts down more toward the landing. Lower: it tilts less.",
			look, "landing_look_strength", 0, 1, "%.2f")
		slider("lv_drop", "Drop height for max landing tilt",
			"How far below the takeoff the landing must be for the full tilt. Higher: a bigger drop is needed. Lower: a small drop is enough.",
			look, "landing_look_full_drop", 0.5, 10, "%.1f m")
		slider("lv_vertical", "Air vertical tracking strength",
			"Higher: the view tilts to follow you up and down as you jump (every jump, not just landings). 0: it stays level.",
			look, "vertical_follow", 0, 1, "%.2f")
		ui:note("How quickly the landing tilt changes is Tilt transition time, in FOLLOW & MOVEMENT.")
	elseif tab == 6 then
		-- ---- CAMERA EFFECTS
		local sp, landing = draft.speed_shake, draft.landing_shake
		ui:card("CAMERA SHAKE", "Speed, downhill and landing shake")
		local shake_on = ui:toggle("sk_on", "Camera shake", draft.shake_enabled,
			help and "Turns camera shake effects on or off: speed, downhill and landing shake." or nil)
		if shake_on ~= draft.shake_enabled then
			draft.shake_enabled = shake_on
			s_changed = true
		end
		toggle("sk_speed", "Speed shake", "The camera rumbles more the faster you go.", sp, "enabled")
		slider("sk_strength", "Speed shake strength", "Higher: a stronger rumble at speed. Lower: a gentler one. 0: none.", sp, "strength", 0, 10, "%.2fx")
		slider("sk_top", "Speed for max shake", "Higher: you must go faster for the strongest rumble. Lower: it peaks at lower speeds.",
			sp, "top_speed", 0.5, 80, "%.1f m/s")
		toggle("sk_down", "Downhill shake", "More rumble riding downhill.", sp, "downhill_boost")
		slider("sk_down_s", "Downhill shake strength", "Higher: the rumble gets much stronger on a steep downhill. Lower: only a little.",
			sp, "downhill_scale", 1, 10, "%.2fx")
		slider("sk_down_a", "Slope angle for max downhill shake", "Higher: the hill must be steeper for the full extra rumble. Lower: a gentle hill is enough.",
			sp, "downhill_full_degrees", 1, 80, "%.0f degrees")
		slider("sk_land", "Landing shake strength", "Higher: the camera kicks harder when you land. Lower: gentler. 0: no kick.",
			draft.shake, "one_shot_magnitude", 0, 10, "%.2f")
		slider("sk_minfall", "Min drop height for landing shake",
			"Landings that fell less than this do not shake the camera. Higher: more landings count as light. Lower: even small drops shake it.",
			landing, "min_fall", 0, min(10, landing.full_fall - 0.1), "%.1f m")
		slider("sk_fullfall", "Drop height for max landing shake", "Higher: you must fall further for the strongest shake. Lower: smaller falls shake fully.",
			landing, "full_fall", max(0.5, landing.min_fall + 0.1), 10, "%.1f m")
		slider("sk_weight", "Speed-based landing shake strength", "Higher: riding fast makes landings shake harder. 0: only how far you fell counts.",
			landing, "speed_weight", 0, 1, "%.2f")

		local fov = draft.fov
		ui:card("FIELD OF VIEW")
		toggle("fv_override", "Override game FOV",
			"On: this camera sets the FOV. Required for the speed-based and big-air FOV increases. Off: the game's own FOV.", opts, "shot_fov")
		-- The console accepts 0 or 30-120; the slider jumps over the gap.
		do
			local shown = clamp(floor(draft.fov_override_deg + 0.5), 0, 120)
			local v = floor(ui:slider("fv_base", "Base FOV (0 = game's own)", shown, 0, 120, "%d degrees") + 0.5)
			note("Higher: a wider view that shows more around you. Lower: a narrower, more zoomed-in view. 0 keeps the game's FOV.")
			if v ~= shown then
				if v > 0 and v < 30 then
					v = v < 15 and 0 or 30
				end
				draft.fov_override_deg = v
				s_changed = true
			end
		end
		slider("fv_smooth", "FOV transition time", "How quickly the FOV changes. Higher: slower. Lower: quicker.", fov, "smoothing_time", 0, 5, "%.2f s")

		ui:card("SPEED-BASED FOV")
		if not opts.shot_fov then
			ui:note("Turn on Override game FOV above to use this.")
		end
		toggle("sf_on", "Speed-based FOV increase", "The faster you go, the wider the FOV.", fov, "speed_fov")
		slider("sf_deg", "Maximum speed-based FOV increase", "Higher: the FOV is wider at speed. Lower: it changes less.", fov, "speed_fov_degrees", 0, 40, "+%.1f degrees")
		slider("sf_min", "Speed to start FOV increase", "Higher: you must go faster before the FOV starts to increase. Lower: it starts at lower speeds.",
			fov, "speed_fov_min", 0, min(60, fov.speed_fov_max - 0.1), "%.1f m/s")
		slider("sf_max", "Speed for max FOV increase", "Higher: the FOV is widest at a higher speed. Lower: at a lower speed.",
			fov, "speed_fov_max", max(0.1, fov.speed_fov_min + 0.1), 80, "%.1f m/s")

		ui:card("BIG-AIR FOV")
		if not opts.shot_fov then
			ui:note("Turn on Override game FOV above to use this.")
		end
		toggle("af_on", "Big-air FOV increase", "The FOV is wider in a big air.", fov, "air_fov")
		slider("af_deg", "Maximum big-air FOV increase", "Higher: the FOV is wider in a big air. Lower: it changes less.", fov, "air_fov_degrees", 0, 40, "+%.1f degrees")
		slider("af_full", "Jump height for max FOV increase", "Higher: only very big jumps give the full FOV increase. Lower: smaller jumps do too.",
			fov, "air_fov_full_height", 0.1, 50, "%.1f m")
	elseif tab == 7 then
		-- ---- OFF THE BOARD
		local ob = opts.offboard
		ui:card("OFF THE BOARD", "The camera while you walk, stand, run and bail")
		if not ob or not Off then
			ui:note("The off-board camera is not available in this install.")
		else
			local mode, mchanged = pick("ob_mode", "Off-board camera", { "Dynamic", "Game" }, opts.offboard_mode == "game" and 2 or 1, {
				"This camera keeps the view on foot and in bails. Use the right stick to look around.",
				"The game's own camera takes over when you step off the board, after a short ease.",
			})
			if mchanged then
				opts.offboard_mode = mode == 2 and "game" or "dynamic"
				o_changed = true
			end
			local style, tchanged = pick("ob_style", "Style", { "Orbit", "Shoulder" }, ob.style == "shoulder" and 2 or 1, {
				"A view from behind and above you, a little further out. Fills the sliders below.",
				"Close over one shoulder, like the Arkham games. Fills the sliders below; the shoulder side is the riding one (Switch shoulder side).",
			})
			if tchanged then
				Off.apply_style(ob, style == 2 and "shoulder" or "orbit", glue.base_fov)
				o_changed = true
			end
			ui:note("Look around with the right stick. R3 swings the camera behind you. The mouse is not used.")

			ui:card("FRAMING")
			slider("ob_dist", "Distance", "Higher: the camera sits further from you. Lower: closer.", ob, "distance", 1.0, 6.0, "%.1f m")
			slider("ob_height", "Height", "How high the camera sits above the middle of your body.", ob, "height", -0.5, 1.5, "%.2f m")
			slider("ob_look", "Look height", "Where the camera aims, above the middle of your body. Higher: you sit lower on the screen.",
				ob, "look_height", -0.3, 1.0, "%.2f m")
			slider("ob_offset", "Horizontal offset",
				"Moves the camera to the side. Positive: to the right. Negative: to the left. Switch shoulder side flips it.", ob, "offset", -1.2, 1.2, "%.2f m")
			do
				-- 0 is the game's FOV, else 40 to 110; the slider jumps over the gap.
				local shown = clamp(floor(ob.fov + 0.5), 0, 110)
				local v = floor(ui:slider("ob_fov", "Field of view (0 = game's own)", shown, 0, 110, "%d degrees") + 0.5)
				note("Higher: a wider view. Lower: a narrower, more zoomed-in view. 0 keeps the game's FOV.")
				if v ~= shown then
					if v > 0 and v < 40 then
						v = v < 20 and 0 or 40
					end
					ob.fov = v
					o_changed = true
				end
			end

			ui:card("FEEL", "Everything eases; nothing snaps")
			slider("ob_follow", "Follow smoothing", "Higher: the camera trails you more softly. Lower: it keeps closer to you.", ob, "follow_time", 0.02, 1.0, "%.2f s")
			slider("ob_turn", "Turn smoothing", "Higher: the view starts and stops turning more gradually. 0: it follows the stick exactly.", ob, "turn_time", 0.0, 0.5, "%.2f s")
			slider("ob_stick", "Stick speed", "How fast the right stick turns the view. The game's own is about 170.", ob, "stick_speed", 60, 360, "%.0f deg/s")
			toggle("ob_invert", "Invert Y", "On: pushing the right stick up looks down.", ob, "invert_y")
			slider("ob_recentre", "Recentre after (0 = never)",
				"While you move and leave the right stick alone, the camera swings behind you after this long. Standing still never recentres.",
				ob, "recentre_after", 0.0, 10.0, "%.1f s")
			toggle("ob_match", "Match walking to the view",
				"Slowly turns the view toward the direction the left stick walks 'forward', which the game decides with its own hidden camera.", ob, "match_walking")

			ui:card("BODY")
			slider("ob_level", "Level with the body",
				"Higher: steps, stairs and crouches do not bob the camera. 0: it follows your body's height exactly.", ob, "level", 0.0, 1.0, "%.2f")
			slider("ob_bob", "Bobbing strength", "A walking bob put back on purpose, stronger when you run. 0: none.", ob, "bob", 0.0, 1.0, "%.2f")
			slider("ob_bail", "Bail distance", "How much further out the camera goes when you bail. 1: no change.", ob, "bail_distance", 1.0, 2.5, "%.2fx")

			ui:card("BOARD TRANSITION")
			slider("ob_trans", "Board / foot transition time",
				"How long the view takes to change between the riding camera and this one, either way. 0: straight away.", ob, "transition_time", 0.0, 3.0, "%.2f s")
		end
	else
		-- ---- ADVANCED
		local col = draft.collision
		ui:card("MANUAL COLLISION SETTINGS")
		if col.automatic then
			ui:note("Used when Automatic collision handling is off (CAMERA tab).")
		end
		slider("mc_radius", "Wall clearance", "Higher: the camera stays further from walls. Lower: it can get right up to them.", col, "radius", 0, 2, "%.2f m")
		slider("mc_in", "Collision entry time", "Higher: the camera moves in front of a wall slowly. Lower: it moves in at once.", col, "pull_in_time", 0.05, 2, "%.2f s")
		slider("mc_out", "Collision exit time", "Higher: the camera returns slowly once the wall is gone. Lower: it returns quickly.", col, "release_time", 0.1, 5, "%.2f s")
		slider("mc_ground", "Ground clearance", "Higher: the camera stays further above the ground. Lower: it can sit closer to the ground.",
			col, "ground_clearance", 0, 3, "%.2f m")

		ui:card("BOARD TRANSITIONS")
		slider("bt_take", "Board mount transition time",
			"Higher: the switch to this camera takes longer when you get on the board. 0: it cuts at once.", opts, "take_blend_time", 0, 5, "%.2f s")
		slider("bt_release", "Hand-back blend time",
			"Higher: when you get off the board the camera takes longer to settle where the game's camera will be before it is handed back. 0: it hands back at once.",
			opts, "release_blend_time", 0, 5, "%.2f s")
		ui:note("The plugin cannot see the game's camera while it holds the view, so it eases to where it expects it to be, learned from the last time you were on foot.")

		ui:card("LOGGING")
		toggle("lg_on", "Camera logging",
			"Writes camera state and landing information to files in the plugin's data folder (diag/), with one line per fault in the log. Same as dyncam_log 1.",
			opts, "verbose")

		ui:card("DEFAULTS", "Changes apply at once and are saved between launches")
		if ui:button("reset_all", "Reset all settings") then
			store:reset()
			state.feedback = "Dynamic Camera settings are back to their defaults."
			discard = true
		end
	end

	if discard then
		return
	end
	if s_changed and not store:set_settings(draft) then
		state.feedback = "That value is out of range; the old one is kept."
	end
	if o_changed then
		store:set_options(opts)
	end
end

-- ---------------------------------------------------------------- the presets dialog
local function rows_of(list)
	local rows, refs = {}, {}
	for i = 1, min(#list, 64) do
		local e = list[i]
		rows[i] = { text = e.name, sub = e.built_in and "built in" or nil, buttons = e.built_in and { "Load" } or { "Load", "Rename", "Delete" } }
		refs[i] = e
	end
	return rows, refs
end

function Menu.open_dialog(message)
	Presets.refresh()
	local rows, refs = rows_of(Presets.list())
	state.dialog_rows = refs
	if message ~= nil then
		state.dialog_message = message
	end
	local ok, err = pcall(reskate.ui.dialog, Menu.DIALOG_ID, {
		title = "DYNAMIC CAMERA PRESETS",
		message = state.dialog_message ~= "" and state.dialog_message
			or "Pick a preset and Load it, or type a name and Save the camera as it is now.",
		field = { text = state.dialog_name, max = Presets.max_name_chars },
		list = { rows = rows, empty = "No presets yet" },
		buttons = { { id = "save", label = "Save as new" }, { id = "close", label = "Close" } },
		file = { label = "Import a preset file", filter = "*.json" },
	})
	if not ok then
		state.result, state.result_ok = "The presets window is not available here (" .. tostring(err) .. ").", false
	end
end

-- The `throwdown_ui` event: e = { action = "dialog", mode = "", args = { id, button, text, row, file_text } }.
function Menu.on_dialog(e)
	if e.action ~= "dialog" or not e.args or e.args[1] ~= Menu.DIALOG_ID then
		return
	end
	local store = deps.store
	local button, text, row, file_text = e.args[2], e.args[3] or "", tonumber(e.args[4]) or 0, e.args[5] or ""
	local entry = state.dialog_rows[row]
	local message
	if button == "cancel" or button == "close" then
		pcall(reskate.ui.close_dialog, Menu.DIALOG_ID)
		return
	elseif button == "row" then
		if entry then
			state.dialog_name = entry.name
			state.selected = entry.name
		end
		message = state.dialog_message
	elseif button == "Load" and entry then
		message = Presets.load(store, entry.name).message
		state.dialog_name = entry.name
	elseif button == "Rename" and entry then
		local r = Presets.rename(entry.name, text)
		message = r.message
		if r.ok then
			state.dialog_name = r.name
		end
	elseif button == "Delete" and entry then
		if state.armed_delete == entry.name then
			message = Presets.delete(entry.name).message
			state.armed_delete = nil
		else
			state.armed_delete = entry.name
			message = "Press Delete again to remove '" .. entry.name .. "'."
		end
	elseif button == "save" then
		local overwrite = state.armed_overwrite == text and text ~= ""
		local r = Presets.save(store, text, overwrite)
		if r.confirm then
			state.armed_overwrite = text
			message = "'" .. r.name .. "' already exists. Press Save as new again to replace it."
		else
			state.armed_overwrite = nil
			message = r.message
			if r.ok then
				state.dialog_name = r.name
				state.selected = r.name
			end
		end
	elseif button == "file" then
		local r = Presets.import_text(file_text)
		message = r.message
		if r.ok then
			state.selected = r.name
		end
	elseif button == "file_error" then
		message = "Could not read that file: " .. text
	else
		message = state.dialog_message
	end
	state.dialog_name = (button == "row" or button == "Load") and state.dialog_name or (text ~= "" and text or state.dialog_name)
	if button ~= "Delete" then
		state.armed_delete = nil
	end
	state.result, state.result_ok = message or "", true
	Menu.open_dialog(message or "")
end

function Menu.install(d)
	deps = d
	reskate.menu.page("Dynamic Camera", Menu.build)
end

return Menu
