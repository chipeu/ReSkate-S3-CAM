-- The DYNAMIC CAMERA page: Extension/UI/Overlay/skate_menu_camera.cpp on reskate.menu.page. A switch card on top and a row of
-- tabs (PRESETS, CAMERA, FOLLOW & MOVEMENT, TRICKS & CLOSE-UPS, AIR & LANDING, CAMERA EFFECTS, OFF THE BOARD, ADVANCED); each tab is a few cards
-- of toggles, sliders and dropdowns with the DLL's labels, ranges and formats. A change applies to the camera at once (the glue
-- sees the new revision) and is saved to storage.
--
-- Differences from the DLL's page (the plugin menu has fewer widgets):
--  * Descriptions: toggles and dropdowns carry them as their help text; a slider has none, so its description is a muted note
--    under it. "Show descriptions" (top card) hides those notes.
--  * No greyed-out controls: a control that depends on another one stays on screen and simply does nothing while that one is off.
--  * No Native+ style, so the style choice and NATIVE+ SETTINGS are not here (a note says so). LANDING BOUNCE is (the dip works in the Full style).
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

	local on = ui:toggle("main_on", "Dynamic Camera", store.enabled,
		help and "Use Dynamic Camera while playing." or nil)
	if on ~= store.enabled then
		store:set_enabled(on)
	end
	ui:info("Status", glue:status())
	local show = ui:toggle("show_help", "Show descriptions", store.show_help, help and "Show control descriptions." or nil)
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
		ui:card("PRESETS")
		index = ui:dropdown("preset_pick", "Preset", names, index,
			help and "Select a saved preset." or nil)
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
		if ui:button("preset_manage", "Manage presets…") then
			Menu.open_dialog("")
		end

		if ui:button("preset_folder", "Open preset folder") then
			answer(Presets.reveal())
		end
		note("Copy preset files here to import or share them.")
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
		ui:card("CAMERA")

		local h, changed = pick("cam_height", "Camera view", { "Low", "High" }, draft.angle == Angle.High and 2 or 1,
			{ "Use the Low view.", "Use the High view." })
		if changed then
			draft.angle = h == 2 and Angle.High or Angle.Low
			s_changed = true
		end
		toggle("o_r3", "Switch camera view with R3", "Press R3 to switch between Low and High.", opts, "follow_game_height")

		local follow = draft.follow
		ui:card("CAMERA STYLE")
		local style, style_changed = pick("cam_style", "Camera style", { "Classic", "Joint Lock" },
			follow.camera_style == "joint_lock" and 2 or 1,
			{ "Use the existing crouch and pop camera controls.", "Follow a body landmark vertically." })
		if style_changed then
			follow.camera_style = style == 2 and "joint_lock" or "classic"
			s_changed = true
		end
		if follow.camera_style == "joint_lock" then
			ui:card("JOINT LOCK")
			local targets = { "Head", "Chest", "Feet", "Knee", "Hips", "Skateboard" }
			local keys = { "head", "chest", "feet", "knee", "hips", "skateboard" }
			local selected = 1
			for i, key in keys do
				if follow.joint_target == key then selected = i end
			end
			local target, target_changed = pick("joint_target", "Follow target", targets, selected,
				{ "Follow the head height.", "Follow the chest height.", "Follow the feet height.", "Follow the knees height.", "Follow the hips height.", "Follow the skateboard height." })
			if target_changed then follow.joint_target = keys[target]; s_changed = true end
			local damping = ui:slider("joint_damping", "Joint damping", follow.joint_damping, 0, 100, "%.0f%%")
			note("0% responds immediately. Higher values ease vertical movement more strongly.")
			if damping ~= follow.joint_damping then follow.joint_damping = damping; s_changed = true end
		else
			ui:card("POP HEIGHT FOLLOW")
			toggle("pop_follow", "Follow pop height", "Follow the skater's small pops. Large drops stay in view in either setting.", follow, "trick_pop")
			local pm,pm_changed=pick("pop_mode","Pop follow mode",{"Camera height","Camera pitch"},follow.pop_mode+1,
				{"Move the camera up with the pop.","Keep camera height steady and tilt up with the pop."})
			if pm_changed then follow.pop_mode=pm-1;s_changed=true end
			local pop_percent=ui:slider("pop_amount","Pop follow strength",follow.pop_amount*100.0,0,100,"%.0f%%")
			if pop_percent~=follow.pop_amount*100.0 then follow.pop_amount=pop_percent/100.0;s_changed=true end

			ui:card("CROUCH")
			toggle("crouch_on", "Follow crouching", "Follow the skater lowering into a crouch.", follow, "crouch_enabled")
			local cm,cm_changed=pick("crouch_mode","Crouch follow mode",{"Camera height","Camera pitch"},follow.crouch_mode+1,
				{"Move the camera down with the crouch.","Keep camera height steady and tilt down with the crouch."})
			if cm_changed then follow.crouch_mode=cm-1;s_changed=true end
			local percent = ui:slider("crouch_amount", "Crouch follow strength", follow.crouch_amount * 100.0, 0, 100, "%.0f%%")
			if percent ~= follow.crouch_amount * 100.0 then follow.crouch_amount = percent / 100.0; s_changed = true end
			note("Adjust how much the camera follows.")
		end

		ui:card("CAMERA POSITION")
		camera_for("pos_for", "Camera position", "Edit the Low view.", "Edit the High view.")
		local fr = framing()
		slider("pos_height", "Camera elevation angle",
			"Adjust how high the camera sits.",
			fr, "height_degrees", -30, 45, "%.1f degrees")
		slider("pos_pitch", "View aim angle", "Aim the view up or down.",
			fr, "pitch_degrees", -30, 30, "%.1f degrees")

		ui:card("CAMERA DISTANCE")
		camera_for("dist_for", "Camera distance", "Edit the Low view.", "Edit the High view.")
		local ride = state.position_for == 1 and draft.ride_distance_high or draft.ride_distance
		local m, mchanged = pick("dist_mode", "Distance mode", { "Speed-based", "Fixed" }, ride.mode == DistMode.Fixed and 2 or 1, { "Change distance with speed.", "Lock riding distance and FOV to the body. Collision can move the camera." })
		if mchanged then
			ride.mode = m == 2 and DistMode.Fixed or DistMode.Speed
			s_changed = true
		end
		if ride.mode == DistMode.Fixed then
			slider("dist_fixed", "Camera distance",
				"Set the riding distance.",
				ride, "fixed", 0.5, 10, "%.2f m")
		else
			slider("dist_slow", "Distance at low speed", "Set the distance when riding slowly.",
				ride, "slow", 0.5, ride.fast, "%.2f m")
			slider("dist_fast", "Distance at top speed",
				"Set the distance when riding fast.",
				ride, "fast", ride.slow, 10, "%.2f m")
		end

		ui:card("CAMERA COLLISION")
		toggle("col_on", "Camera collision", "Keep the camera clear of walls.", draft.collision, "enabled")
		toggle("col_auto", "Automatic collision handling",
			"Handle collision automatically. Turn off to use Manual collision settings.",
			draft.collision, "automatic")
	elseif tab == 3 then
		-- ---- FOLLOW & MOVEMENT
		local follow = draft.follow
		ui:card("FOLLOW")
		slider("fl_strength", "Follow responsiveness", "Adjust how quickly the camera follows.",
			follow, "strength", 0.2, 4, "%.2fx")
		slider("fl_horizontal", "Turn-follow strength",
			"Adjust how strongly the camera follows turns.",
			follow, "horizontal", 0, 10, "%.1f")
		toggle("fl_dynamic", "Reduce lag at speed", "Increase follow responsiveness at speed.", follow, "dynamic")
		slider("fl_dspeed", "Speed for maximum follow boost",
			"Set the speed for the full follow boost.",
			follow, "dynamic_speed", 0.5, 60, "%.1f m/s")
		slider("fl_boost", "Speed-based follow boost", "Adjust the extra responsiveness at speed.",
			follow, "dynamic_boost", 0, 3, "+%.2f")

		local sh = draft.shoulder
		ui:card("SHOULDER CAMERA")
		local mode, mchanged = pick("sh_mode", "Shoulder camera", { "Off", "Manual", "Auto" },
			sh.mode == Shoulder.Manual and 2 or (sh.mode == Shoulder.Auto and 3 or 1),
			{ "Centre the camera.", "Choose a side.", "Use the stance to choose a side." })
		if mchanged then
			sh.mode = mode == 2 and Shoulder.Manual or (mode == 3 and Shoulder.Auto or Shoulder.Off)
			s_changed = true
		end
		local side, schanged = pick("sh_side", "Shoulder side", { "Left", "Right" }, sh.side == 1 and 2 or 1, { "Place the camera on the left.", "Place the camera on the right." })
		if schanged then
			sh.side = side == 2 and 1 or -1
			s_changed = true
		end
		local stance, tchanged = pick("sh_stance", "Auto shoulder stance", { "Regular", "Goofy" }, sh.goofy and 2 or 1, { "Use a regular stance.", "Use a goofy stance." })
		if tchanged then
			sh.goofy = stance == 2
			s_changed = true
		end
		slider("sh_offset", "Shoulder offset", "Move the camera sideways.", sh, "offset", 0, 1, "%.2f m")
		slider("sh_time", "Shoulder switch time", "Set how long a shoulder switch takes.", sh, "switch_time", 0, 5, "%.2f s")
		ui:note("L3 switches shoulder side.")

		local look = draft.look
		ui:card("SLOPE TILT")
		toggle("sl_on", "Slope tilt", "Tilt with hills while riding.", look, "slope_look")
		slider("sl_strength", "Slope tilt strength", "Adjust how much the view tilts with hills.", look, "slope_look_strength", 0, 1, "%.2f")
		slider("sl_response", "Tilt transition time",
			"Set how quickly tilt and aim changes settle.",
			look, "response_time", 0.15, 5, "%.2f s")
	elseif tab == 4 then
		-- ---- TRICKS & CLOSE-UPS
		local yaw = draft.trick_yaw
		ui:card("TRICK CAMERA")

		toggle("ty_on", "Trick camera turn", "Turn the camera to show tricks.", yaw, "enabled")
		slider("ty_angle", "Trick camera angle", "Set how far the camera turns.", yaw, "angle_degrees", 0, 45, "%.0f degrees")
		local side, changed = pick("ty_side", "Trick camera direction", { "Auto", "Left", "Right" }, yaw.side < 0 and 2 or (yaw.side > 0 and 3 or 1), { "Follow the shoulder side or stance.", "Turn left.", "Turn right." })
		if changed then
			yaw.side = side == 2 and -1 or (side == 3 and 1 or 0)
			s_changed = true
		end
		toggle("ty_air", "Air trick camera turn", "Turn the camera during air tricks.", yaw, "in_air")
		toggle("ty_grind", "Grind camera turn", "Turn the camera during grinds.", yaw, "on_grinds")
		toggle("ty_manual", "Manual camera turn", "Turn the camera during manuals.", yaw, "on_manuals")
		slider("ty_minair", "Minimum airtime for camera turn",
			"Set the airtime needed before the camera turns.",
			yaw, "min_air_time", 0, 3, "%.2f s")
		slider("ty_in", "Camera turn time", "Set how long the camera takes to turn.", yaw, "in_time", 0.15, 5, "%.2f s")
		slider("ty_hold", "Camera angle hold time",
			"Hold the angle after a trick.", yaw, "hold_time", 0, 5, "%.2f s")
		slider("ty_return", "Camera return time", "Set how long the camera takes to return behind you.",
			yaw, "return_time", 0.15, 10, "%.2f s")

		local cmd = Settings.closeup_min_distance
		ui:card("MANUAL CAMERA")
		camera_for("man_for", "Manual camera", "Edit the Low view.", "Edit the High view.")
		local fr = framing()
		toggle("man_on", "Manual close-up", "Use a closer view during manuals.", fr, "manual_camera")
		local mm, mchanged = pick("man_mode", "Manual distance mode", { "Fixed", "Speed-based" }, fr.manual_mode == ManualMode.Speed and 2 or 1, { "Keep a fixed distance.", "Change distance with speed." })
		if mchanged then
			fr.manual_mode = mm == 2 and ManualMode.Speed or ManualMode.Fixed
			s_changed = true
		end
		if fr.manual_mode == ManualMode.Speed then
			slider("man_min", "Minimum manual distance", "Set the distance at low speed.",
				fr, "manual_min_distance", cmd, fr.manual_max_distance, "%.2f m")
			slider("man_max", "Maximum manual distance",
				"Set the distance at 8 m/s and above.", fr, "manual_max_distance",
				fr.manual_min_distance, 8, "%.2f m")
		else
			slider("man_dist", "Manual camera distance", "Set the distance during manuals.",
				fr, "manual_distance", cmd, 8, "%.2f m")
		end
		slider("man_height", "Manual camera elevation angle",
			"Adjust the camera height during manuals.",
			fr, "manual_height_degrees", -30, 45, "%.1f degrees")
		slider("man_pitch", "Manual view aim angle", "Aim the view during manuals.",
			fr, "manual_pitch_degrees", -30, 30, "%.1f degrees")
		slider("man_focus", "Manual camera target", "0 targets the board. 1 targets the upper body.", draft.look, "manual_focus", 0, 1, "%.2f")

		ui:card("GRIND CAMERA")
		camera_for("grd_for", "Grind camera", "Edit the Low view.", "Edit the High view.")
		fr = framing()
		toggle("grd_on", "Grind close-up", "Use a closer view during grinds.", fr, "grind_camera")
		slider("grd_dist", "Grind camera distance", "Set the distance during grinds.",
			fr, "grind_distance", cmd, 8, "%.2f m")
		slider("grd_height", "Grind camera elevation angle",
			"Adjust the camera height during grinds.",
			fr, "grind_height_degrees", -30, 45, "%.1f degrees")
		slider("grd_pitch", "Grind view aim angle", "Aim the view during grinds.",
			fr, "grind_pitch_degrees", -30, 30, "%.1f degrees")
		slider("grd_focus", "Grind camera target", "0 targets the board. 1 targets the upper body.", draft.look, "grind_focus", 0, 1, "%.2f")

		ui:card("CLOSE-UPS")
		slider("cu_blend", "Camera transition time multiplier",
			"Adjust the time between camera views.",
			draft.look, "shot_blend", 0.25, 4, "%.2fx")
		toggle("cu_board", "Track board in close-ups",
			"Use the board as the close-up target.", draft.look, "board_anchor")
		slider("cu_exit", "Close-up return time",
			"Set how long the camera takes to leave a close-up.",
			draft.look, "closeup_exit_time", 0.2, 3, "%.2f s")
	elseif tab == 5 then
		-- ---- AIR & LANDING
		local air = draft.air_camera
		ui:card("BIG AIR")
		toggle("ba_keep", "Keep skater in frame", "Keep the skater visible during jumps.", air, "keep_in_frame")
		slider("ba_follow", "Camera rise ratio",
			"Adjust how much the camera rises with the skater.",
			air, "follow_height", 0.25, 1, "%.2f")
		slider("ba_rise", "Big-air camera rise angle",
			"Set how far the camera rises over the skater.",
			air, "rise_degrees", 0, 40, "%.0f degrees")
		slider("ba_full", "Jump height for maximum rise",
			"Set the height needed for full camera rise.",
			air, "rise_full_height", 0.1, 20, "%.1f m")
		slider("ba_ease", "Big-air rise time", "Set how quickly the camera rises and settles.",
			air, "ease_time", 0.15, 3, "%.2f s")

		local look = draft.look
		ui:card("LANDING VIEW")
		toggle("lv_on", "Landing camera tilt",
			"Tilt toward the landing on drops.", look, "landing_look")
		slider("lv_strength", "Landing tilt strength", "Adjust how much the view tilts toward the landing.",
			look, "landing_look_strength", 0, 1, "%.2f")
		slider("lv_drop", "Drop height for maximum tilt",
			"Set the drop needed for full landing tilt.",
			look, "landing_look_full_drop", 0.5, 10, "%.1f m")
		slider("lv_vertical", "Air vertical tracking strength",
			"Adjust how much the view follows vertical movement.",
			look, "vertical_follow", 0, 1, "%.2f")

	elseif tab == 6 then
		-- ---- CAMERA EFFECTS
		local sp, landing = draft.speed_shake, draft.landing_shake
		ui:card("CAMERA SHAKE")
		local shake_on = ui:toggle("sk_on", "Camera shake", draft.shake_enabled,
			help and "Enable camera shake effects." or nil)
		if shake_on ~= draft.shake_enabled then
			draft.shake_enabled = shake_on
			s_changed = true
		end
		toggle("sk_speed", "Speed shake", "Increase shake with speed.", sp, "enabled")
		slider("sk_strength", "Speed shake strength", "Adjust the shake while riding.", sp, "strength", 0, 10, "%.2fx")
		slider("sk_top", "Speed for maximum shake", "Set the speed needed for full shake.",
			sp, "top_speed", 0.5, 80, "%.1f m/s")
		toggle("sk_down", "Downhill shake", "Add shake while riding downhill.", sp, "downhill_boost")
		slider("sk_down_s", "Downhill shake strength", "Adjust the extra downhill shake.",
			sp, "downhill_scale", 1, 10, "%.2fx")
		slider("sk_down_a", "Slope angle for maximum shake", "Set the slope needed for full downhill shake.",
			sp, "downhill_full_degrees", 1, 80, "%.0f degrees")
		slider("sk_land", "Landing shake strength", "Adjust the shake on landing.",
			draft.shake, "one_shot_magnitude", 0, 10, "%.2f")
		slider("sk_minfall", "Minimum drop height for shake",
			"Ignore drops below this height.",
			landing, "min_fall", 0, min(10, landing.full_fall - 0.1), "%.1f m")
		slider("sk_fullfall", "Drop height for maximum shake", "Set the drop needed for full landing shake.",
			landing, "full_fall", max(0.5, landing.min_fall + 0.1), 10, "%.1f m")
		slider("sk_weight", "Landing speed influence", "Adjust how much speed adds to landing shake.",
			landing, "speed_weight", 0, 1, "%.2f")

		local bounce = draft.native_plus
		ui:card("LANDING BOUNCE")
		if draft.follow.camera_style == "joint_lock" then
			ui:note("Landing bounce is disabled by Joint Lock.")
		else
			toggle("lb_on", "Landing bounce", "Lower the camera briefly on landing.", bounce, "landing_dip")
			slider("lb_depth", "Bounce depth", "Adjust how far the camera drops.", bounce, "dip_depth", 0, 2, "%.2f m")
			slider("lb_time", "Bounce recovery time", "Set how quickly the camera returns after landing.", bounce, "dip_peak_time", 0.02, 2, "%.2f s")
		end

		local fov = draft.fov
		ui:card("FIELD OF VIEW")
		toggle("fv_override", "Override game FOV",
			"Allow Dynamic Camera to set the field of view.", opts, "shot_fov")
		-- The console accepts 0 or 30-120; the slider jumps over the gap.
		do
			local shown = clamp(floor(draft.fov_override_deg + 0.5), 0, 120)
			local v = floor(ui:slider("fv_base", "Base FOV", shown, 0, 120, "%d degrees") + 0.5)
			note("0 uses the game's FOV.")
			if v ~= shown then
				if v > 0 and v < 30 then
					v = v < 15 and 0 or 30
				end
				draft.fov_override_deg = v
				s_changed = true
			end
		end
		slider("fv_smooth", "FOV transition time", "Set how quickly the field of view changes.", fov, "smoothing_time", 0, 5, "%.2f s")

		ui:card("SPEED-BASED FOV")
		if not opts.shot_fov then
			ui:note("Enable Override game FOV to use this.")
		end
		toggle("sf_on", "Speed-based FOV increase", "Widen the view with speed in Speed-based distance mode.", fov, "speed_fov")
		slider("sf_deg", "Maximum speed-based FOV increase", "Set the extra field of view at full speed.", fov, "speed_fov_degrees", 0, 40, "+%.1f degrees")
		slider("sf_min", "Speed to start FOV increase", "Set when the field of view starts widening.",
			fov, "speed_fov_min", 0, min(60, fov.speed_fov_max - 0.1), "%.1f m/s")
		slider("sf_max", "Speed for maximum FOV increase", "Set the speed needed for full widening.",
			fov, "speed_fov_max", max(0.1, fov.speed_fov_min + 0.1), 80, "%.1f m/s")

		ui:card("BIG-AIR FOV")
		if not opts.shot_fov then
			ui:note("Enable Override game FOV to use this.")
		end
		toggle("af_on", "Big-air FOV increase", "Widen the view during big jumps.", fov, "air_fov")
		slider("af_deg", "Maximum big-air FOV increase", "Set the extra field of view during big jumps.", fov, "air_fov_degrees", 0, 40, "+%.1f degrees")
		slider("af_full", "Jump height for maximum FOV increase", "Set the jump height needed for full widening.",
			fov, "air_fov_full_height", 0.1, 50, "%.1f m")
	elseif tab == 7 then
		-- ---- OFF THE BOARD
		local ob = opts.offboard
		ui:card("OFF-BOARD CAMERA")
		if not ob or not Off then
			ui:note("The off-board camera is not available in this install.")
		else
			local mode, mchanged = pick("ob_mode", "Off-board camera mode", { "Dynamic", "Game" }, opts.offboard_mode == "game" and 2 or 1, { "Use Dynamic Camera on foot.", "Use the game's camera on foot." })
			if mchanged then
				opts.offboard_mode = mode == 2 and "game" or "dynamic"
				o_changed = true
			end
			local style, tchanged = pick("ob_style", "Camera type", { "Orbit", "Shoulder" }, ob.style == "shoulder" and 2 or 1, { "Look around the skater.", "Use an over-the-shoulder view." })
			if tchanged then
				if (style == 2) ~= (ob.style == "shoulder") then
					-- Each style keeps its own sliders (the same switch as double R3 and the bind).
					store.offboard_other = Off.switch_style(ob, glue.base_fov, store.offboard_other)
				end
				o_changed = true
			end
			ui:note("R3 recentres. Double R3 switches Orbit / Shoulder.")
			toggle("ob_sway", "Camera Sway", "Use the smooth camera momentum felt after a bail. Works without crashing.", opts, "camera_sway")

			ui:card("FRAMING")
			slider("ob_dist", "Camera distance", "Set the distance from the skater.", ob, "distance", 1.0, 6.0, "%.1f m")
			slider("ob_height", "Camera height", "Set the height above the body centre.", ob, "height", -0.5, 1.5, "%.2f m")
			slider("ob_look", "Look height", "Set the height the camera aims at.",
				ob, "look_height", -0.3, 1.0, "%.2f m")
			slider("ob_offset", "Horizontal offset",
				"Move the view sideways. L3 switches sides.", ob, "offset", -1.2, 1.2, "%.2f m")
			do
				-- 0 is the game's FOV, else 40 to 110; the slider jumps over the gap.
				local shown = clamp(floor(ob.fov + 0.5), 0, 110)
				local v = floor(ui:slider("ob_fov", "Field of view", shown, 0, 110, "%d degrees") + 0.5)
				note("0 uses the game's FOV.")
				if v ~= shown then
					if v > 0 and v < 40 then
						v = v < 20 and 0 or 40
					end
					ob.fov = v
					o_changed = true
				end
			end

			ui:card("CAMERA MOVEMENT")
			slider("ob_follow", "Follow smoothing", "Adjust how quickly the camera follows.", ob, "follow_time", 0.02, 1.0, "%.2f s")
			slider("ob_turn", "Look smoothing", "Smooth the start and stop of camera turns.", ob, "turn_time", 0.0, 0.5, "%.2f s")
			slider("ob_stick", "Look speed", "Set how quickly the right stick turns the view.", ob, "stick_speed", 60, 360, "%.0f deg/s")
			toggle("ob_invert", "Invert vertical look", "Push the right stick up to look down.", ob, "invert_y")
			slider("ob_recentre", "Recentre delay",
				"Set the delay before the camera returns behind you. 0 disables recentring.",
				ob, "recentre_after", 0.0, 10.0, "%.1f s")
			toggle("ob_match", "Align view with walking",
				"Align the view with the walking direction.", ob, "match_walking")

			ui:card("BODY FOLLOWING")
			slider("ob_level", "Body height smoothing",
				"Reduce camera movement from body height changes.", ob, "level", 0.0, 1.0, "%.2f")
			slider("ob_bob", "Walking bob strength", "Adjust camera bob while walking.", ob, "bob", 0.0, 1.0, "%.2f")
			slider("ob_bail", "Bail distance multiplier", "Move further back during bails. 1 keeps the same distance.", ob, "bail_distance", 1.0, 2.5, "%.2fx")

			ui:card("BOARD TRANSITIONS")
			slider("ob_trans", "Board-to-foot transition time",
				"Set the transition time between riding and walking views.", ob, "transition_time", 0.0, 3.0, "%.2f s")
		end
	else
		-- ---- ADVANCED
		ui:card("STABILITY")
		toggle("o_stability", "Stability test", "Keep camera sampling aligned with the skater. Turn off to compare.", opts, "stable_timing")
		local col = draft.collision
		ui:card("MANUAL COLLISION")
		if col.automatic then
			ui:note("Turn off Automatic collision handling to use these settings.")
		end
		slider("mc_radius", "Wall clearance", "Set the distance from walls.", col, "radius", 0, 2, "%.2f m")
		slider("mc_in", "Collision entry time", "Set how quickly the camera moves clear of a wall.", col, "pull_in_time", 0.05, 2, "%.2f s")
		slider("mc_out", "Collision exit time", "Set how quickly the camera returns after a wall.", col, "release_time", 0.1, 5, "%.2f s")
		slider("mc_ground", "Ground clearance", "Set the distance above the ground.",
			col, "ground_clearance", 0, 3, "%.2f m")

		ui:card("BOARD TRANSITIONS")
		slider("bt_take", "Board mount transition time",
			"Set the transition time when taking the camera.", opts, "take_blend_time", 0, 5, "%.2f s")
		slider("bt_release", "Return to game camera time",
			"Set the return time. 0 returns control immediately.",
			opts, "release_blend_time", 0, 5, "%.2f s")


		ui:card("LOGGING")
		toggle("lg_on", "Camera logging",
			"Record camera diagnostics for troubleshooting.",
			opts, "verbose")

		ui:card("DEFAULTS")
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
