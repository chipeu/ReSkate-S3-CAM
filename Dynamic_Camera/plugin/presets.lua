-- Port of Extension/Camera/s3cam_preset_format.h (the format, the loader, the built-ins, the names) and
-- s3cam_presets.cpp (the preset files), against the reskate API.
--
-- Same JSON as the DLL: { "name": "Park cam", "version": 1, "values": { "S3Cam.Framing.DistanceScale": 0.85, ... } }
-- with the same "S3Cam.<Group>.<Field>" keys, so a preset moves between the DLL and the plugin by copying the file.
-- Unknown keys are ignored, a missing key keeps the default, a value of the wrong type or out of range is refused on its
-- own while the rest still load. Presets are files in the plugin's data folder: presets/<name>.json.
--
-- Pure part (no reskate): Presets.collect_values, load_values, parse_preset, preset_text, sanitize_name, unique_name,
--   builtin_settings, new_options.
-- File part (needs reskate.files): Presets.refresh / list / load / save / rename / delete / import_text / reveal.
-- Differences from the DLL: the plugin has no Native+ style (a preset that asks for it loads as Full and says so);
-- file names are plain ASCII (the data folder only takes printable ASCII paths), so other characters are dropped.

local Settings = require("settings")

local M = {}

M.preset_version = 1
M.max_name_chars = 48
M.max_preset_bytes = 256 * 1024
M.folder = "presets"

local floor, clamp = math.floor, math.clamp

-- The glue's options (not camera-core tunables), S3CamOptions in s3cam.h.
function M.new_options()
	return {
		shot_fov = true, -- the camera drives the FOV; off: the game's own
		verbose = false, -- detailed logging (dyncam_log 1)
		follow_game_height = true, -- R3 switches Low / High
		take_blend_time = 0.5, -- s, crossfade from the game camera when the camera is taken
		release_blend_time = 0.4, -- s, kept for the DLL's presets; the plugin releases at once
	}
end

local function options_ok(o)
	local function t(v)
		return v - v == 0 and v >= 0 and v <= 5
	end
	return t(o.take_blend_time) and t(o.release_blend_time)
end

-- group name -> validity of that group (the C++ group_ok). "camera" is the root (its only field is a bool).
local VALID = {
	camera = function() return true end,
	options = options_ok,
	distance = Settings.valid_distance_limits,
	distance_high = Settings.valid_distance_limits,
	ride_distance = Settings.valid_ride_distance,
	ride_distance_high = Settings.valid_ride_distance,
	framing = Settings.valid_framing,
	framing_high = Settings.valid_framing,
	air_camera = Settings.valid_air_camera,
	trick_yaw = Settings.valid_trick_yaw,
	look = Settings.valid_look,
	shoulder = Settings.valid_shoulder,
	follow = Settings.valid_follow,
	fov = Settings.valid_fov,
	shake = Settings.valid_shake,
	landing_shake = Settings.valid_landing_shake,
	speed_shake = Settings.valid_speed_shake,
	collision = Settings.valid_collision,
	native_plus = Settings.valid_native_plus,
}

-- ---------------------------------------------------------------- the field table
-- { key, group, field, kind } kind: "b" boolean, "f" number. Every saved field once, as visit_fields.
local FIELDS = {}
local function add(prefix, group, list)
	for _, e in list do
		FIELDS[#FIELDS + 1] = { prefix .. e[1], group, e[2], e[3] }
	end
end

add("S3Cam.", "camera", { { "ShakeEnabled", "shake_enabled", "b" } })
add("S3Cam.Distance.", "distance", { { "Min", "min", "f" }, { "Max", "max", "f" } })
add("S3Cam.DistanceHigh.", "distance_high", { { "Min", "min", "f" }, { "Max", "max", "f" } })
local RIDE = { { "Slow", "slow", "f" }, { "Fast", "fast", "f" }, { "Fixed", "fixed", "f" } }
add("S3Cam.Distance.", "ride_distance", RIDE)
add("S3Cam.DistanceHigh.", "ride_distance_high", RIDE)
local FRAMING = {
	{ "DistanceScale", "distance_scale", "f" }, { "HeightDegrees", "height_degrees", "f" },
	{ "PitchDegrees", "pitch_degrees", "f" }, { "ManualCamera", "manual_camera", "b" },
	{ "ManualDistanceScale", "manual_distance_scale", "f" }, { "ManualHeightDegrees", "manual_height_degrees", "f" },
	{ "GrindCamera", "grind_camera", "b" }, { "GrindDistanceScale", "grind_distance_scale", "f" },
	{ "GrindHeightDegrees", "grind_height_degrees", "f" }, { "ManualDistance", "manual_distance", "f" },
	{ "ManualPitchDegrees", "manual_pitch_degrees", "f" }, { "GrindDistance", "grind_distance", "f" },
	{ "GrindPitchDegrees", "grind_pitch_degrees", "f" }, { "ManualMinDistance", "manual_min_distance", "f" },
	{ "ManualMaxDistance", "manual_max_distance", "f" },
}
add("S3Cam.Framing.", "framing", FRAMING)
add("S3Cam.FramingHigh.", "framing_high", FRAMING)
add("S3Cam.AirCamera.", "air_camera", {
	{ "FollowHeight", "follow_height", "f" }, { "RiseDegrees", "rise_degrees", "f" },
	{ "RiseFullHeight", "rise_full_height", "f" }, { "EaseTime", "ease_time", "f" }, { "KeepInFrame", "keep_in_frame", "b" },
})
add("S3Cam.TrickYaw.", "trick_yaw", {
	{ "Enabled", "enabled", "b" }, { "AngleDegrees", "angle_degrees", "f" }, { "InAir", "in_air", "b" },
	{ "OnGrinds", "on_grinds", "b" }, { "OnManuals", "on_manuals", "b" }, { "MinAirTime", "min_air_time", "f" },
	{ "InTime", "in_time", "f" }, { "HoldTime", "hold_time", "f" }, { "ReturnTime", "return_time", "f" },
})
add("S3Cam.Look.", "look", {
	{ "LandingLook", "landing_look", "b" }, { "LandingLookStrength", "landing_look_strength", "f" },
	{ "LandingLookFullDrop", "landing_look_full_drop", "f" }, { "SlopeLook", "slope_look", "b" },
	{ "SlopeLookStrength", "slope_look_strength", "f" }, { "VerticalFollow", "vertical_follow", "f" },
	{ "ResponseTime", "response_time", "f" }, { "ManualFocus", "manual_focus", "f" }, { "GrindFocus", "grind_focus", "f" },
	{ "BoardAnchor", "board_anchor", "b" }, { "CloseupExitTime", "closeup_exit_time", "f" }, { "ShotBlend", "shot_blend", "f" },
})
add("S3Cam.Shoulder.", "shoulder", { { "Offset", "offset", "f" }, { "SwitchTime", "switch_time", "f" } })
add("S3Cam.Follow.", "follow", {
	{ "Strength", "strength", "f" }, { "Dynamic", "dynamic", "b" }, { "DynamicSpeed", "dynamic_speed", "f" },
	{ "DynamicBoost", "dynamic_boost", "f" }, { "Horizontal", "horizontal", "f" },
})
add("S3Cam.Fov.", "fov", {
	{ "ShotLens", "shot_fov", "b" }, { "SpeedFov", "speed_fov", "b" }, { "SpeedFovDegrees", "speed_fov_degrees", "f" },
	{ "SpeedFovMin", "speed_fov_min", "f" }, { "SpeedFovMax", "speed_fov_max", "f" }, { "AirFov", "air_fov", "b" },
	{ "AirFovDegrees", "air_fov_degrees", "f" }, { "AirFovFullHeight", "air_fov_full_height", "f" },
	{ "SmoothingTime", "smoothing_time", "f" },
})
add("S3Cam.Shake.", "shake", { { "LandingStrength", "one_shot_magnitude", "f" } })
add("S3Cam.LandingShake.", "landing_shake", {
	{ "MinFall", "min_fall", "f" }, { "FullFall", "full_fall", "f" }, { "SpeedWeight", "speed_weight", "f" },
})
add("S3Cam.SpeedShake.", "speed_shake", {
	{ "Enabled", "enabled", "b" }, { "Strength", "strength", "f" }, { "TopSpeed", "top_speed", "f" },
	{ "DownhillBoost", "downhill_boost", "b" }, { "DownhillScale", "downhill_scale", "f" },
	{ "DownhillFullDegrees", "downhill_full_degrees", "f" },
})
-- S3Cam.Collision.MinDistance is no longer saved (unused since Alpha 6); files that carry it load, the key is ignored.
add("S3Cam.Collision.", "collision", {
	{ "Enabled", "enabled", "b" }, { "Automatic", "automatic", "b" }, { "Radius", "radius", "f" },
	{ "PullInTime", "pull_in_time", "f" }, { "ReleaseTime", "release_time", "f" }, { "GroundClearance", "ground_clearance", "f" },
})
add("S3Cam.NativePlus.", "native_plus", {
	{ "AirHold", "air_hold", "b" }, { "LandingDip", "landing_dip", "b" }, { "Shake", "shake", "b" }, { "Roll", "roll", "b" },
	{ "DipDepth", "dip_depth", "f" }, { "DipPeakTime", "dip_peak_time", "f" },
})
add("S3Cam.Options.", "options", {
	{ "ShotFov", "shot_fov", "b" }, { "Logging", "verbose", "b" }, { "FollowGameHeight", "follow_game_height", "b" },
	{ "TakeBlendTime", "take_blend_time", "f" }, { "ReleaseBlendTime", "release_blend_time", "f" },
})
M.fields = FIELDS

-- Text choices (their names are part of the saved file; keep them stable).
local preset_names = { "full", "native" }
local angle_names = { "low", "high" }
local shoulder_names = { "off", "manual", "auto" }
local side_names = { "left", "right" }
local stance_names = { "regular", "goofy" }
local trick_side_names = { "auto", "left", "right" } -- side 0, -1, +1
local manual_mode_names = { "fixed", "speed" }
local distance_mode_names = { "speed", "fixed" }
local RIDE_FIELDS = { "Mode", "Slow", "Fast", "Fixed" }

local function index_of(text, names)
	if text == nil then
		return -1
	end
	for i, n in names do
		if n == text then
			return i - 1
		end
	end
	return -1
end

local function group_of(camera, options, name)
	if name == "options" then
		return options
	elseif name == "camera" then
		return camera
	end
	return camera[name]
end

local function number_ok(v)
	return type(v) == "number" and v - v == 0 and math.abs(v) <= 1.0e9
end

-- ---------------------------------------------------------------- loading
-- The loader applies one saved value over a field when it has the right type and the group stays valid.
local function new_loader(source)
	local L = { refused = 0, first_refused = "" }
	function L.refuse(key)
		L.refused += 1
		if L.refused == 1 then
			L.first_refused = key
		end
	end
	function L.fetch(key)
		local ok, v = pcall(source, key)
		if ok then
			return v
		end
		return nil
	end
	function L.text(key)
		local v = L.fetch(key)
		if type(v) == "string" then
			return v
		end
		return nil
	end
	return L
end

local function load_fields(L, camera, options)
	for _, f in FIELDS do
		local key, gname, field, kind = f[1], f[2], f[3], f[4]
		local v = L.fetch(key)
		if v ~= nil then
			local good = (kind == "b" and type(v) == "boolean") or (kind == "f" and number_ok(v))
			if not good then
				L.refuse(key)
			else
				local g = group_of(camera, options, gname)
				local previous = g[field]
				g[field] = v
				if not VALID[gname](g) then
					g[field] = previous
					L.refuse(key)
				end
			end
		end
	end
end

local function load_choices(L, camera)
	local t = L.text("S3Cam.Preset")
	if t then
		local i = index_of(t, preset_names)
		if i >= 0 then
			camera.preset = Settings.CameraPreset.FullS3 -- Native+ is not in the plugin
			L.native_asked = i == 1
		else
			L.refuse("S3Cam.Preset")
		end
	end
	t = L.text("S3Cam.Angle")
	if t then
		local i = index_of(t, angle_names)
		if i >= 0 then
			camera.angle = i == 1 and Settings.CameraAngle.High or Settings.CameraAngle.Low
		else
			L.refuse("S3Cam.Angle")
		end
	end
	t = L.text("S3Cam.Shoulder.Mode")
	if t then
		local i = index_of(t, shoulder_names)
		if i >= 0 then
			camera.shoulder.mode = i == 1 and Settings.ShoulderSide.Manual or (i == 2 and Settings.ShoulderSide.Auto or Settings.ShoulderSide.Off)
		else
			L.refuse("S3Cam.Shoulder.Mode")
		end
	end
	t = L.text("S3Cam.Shoulder.Side")
	if t then
		local i = index_of(t, side_names)
		if i >= 0 then
			camera.shoulder.side = i == 1 and 1 or -1
		else
			L.refuse("S3Cam.Shoulder.Side")
		end
	end
	t = L.text("S3Cam.Shoulder.Stance")
	if t then
		local i = index_of(t, stance_names)
		if i >= 0 then
			camera.shoulder.goofy = i == 1
		else
			L.refuse("S3Cam.Shoulder.Stance")
		end
	end
	for _, e in { { "S3Cam.Framing.ManualMode", camera.framing }, { "S3Cam.FramingHigh.ManualMode", camera.framing_high } } do
		t = L.text(e[1])
		if t then
			local i = index_of(t, manual_mode_names)
			if i >= 0 then
				e[2].manual_mode = i == 1 and Settings.ManualDistanceMode.Speed or Settings.ManualDistanceMode.Fixed
			else
				L.refuse(e[1])
			end
		end
	end
	for _, e in { { "S3Cam.Distance.Mode", camera.ride_distance }, { "S3Cam.DistanceHigh.Mode", camera.ride_distance_high } } do
		t = L.text(e[1])
		if t then
			local i = index_of(t, distance_mode_names)
			if i >= 0 then
				e[2].mode = i == 1 and Settings.DistanceMode.Fixed or Settings.DistanceMode.Speed
			else
				L.refuse(e[1])
			end
		end
	end
	t = L.text("S3Cam.TrickYaw.Side")
	if t then
		local i = index_of(t, trick_side_names)
		if i >= 0 then
			camera.trick_yaw.side = i == 1 and -1 or (i == 2 and 1 or 0)
		else
			L.refuse("S3Cam.TrickYaw.Side")
		end
	end
	local fo = L.fetch("S3Cam.FovOverride")
	if fo ~= nil then
		if number_ok(fo) and (fo == 0 or (fo >= 30 and fo <= 120)) then
			camera.fov_override_deg = fo
		else
			L.refuse("S3Cam.FovOverride")
		end
	end
end

-- Brings the settings inside the ranges of the menu's sliders (clamp_to_menu_ranges; keep the menu in step).
function M.clamp_to_menu_ranges(camera)
	local function into(t, k, lo, hi)
		local v = t[k]
		if v - v == 0 then
			t[k] = clamp(v, lo, hi)
		end
	end
	into(camera.shoulder, "offset", 0, 1)
	into(camera.trick_yaw, "angle_degrees", 0, 45)
	into(camera.trick_yaw, "in_time", 0.15, 5)
	into(camera.trick_yaw, "return_time", 0.15, 10)
	into(camera.air_camera, "ease_time", 0.15, 3)
	into(camera.air_camera, "rise_degrees", 0, 40)
	into(camera.air_camera, "follow_height", 0.25, 1)
	into(camera.look, "response_time", 0.15, 5)
	into(camera.look, "closeup_exit_time", 0.2, 3)
	into(camera.look, "shot_blend", 0.25, 4)
	into(camera.collision, "pull_in_time", 0.05, 2)
	into(camera.collision, "release_time", 0.1, 5)
	into(camera.framing, "distance_scale", 0.4, 2)
	into(camera.framing_high, "distance_scale", 0.4, 2)
	for _, ride in { camera.ride_distance, camera.ride_distance_high } do
		into(ride, "slow", 0.5, 10)
		ride.fast = clamp(ride.fast, ride.slow, 10)
		into(ride, "fixed", 0.5, 10)
	end
end

-- Applies every value `source(key)` has over `camera` and `options`, then clamps to the menu's ranges. A field refused only
-- because it needs a partner later in the table gets a second pass. Returns { refused, first_refused, native_asked }.
function M.load_values(source, camera, options)
	local first = new_loader(source)
	load_fields(first, camera, options)
	load_choices(first, camera)
	local report = { refused = 0, first_refused = "", native_asked = first.native_asked }
	if first.refused > 0 then
		local second = new_loader(source)
		load_fields(second, camera, options)
		load_choices(second, camera)
		report.refused, report.first_refused = second.refused, second.first_refused
	end
	-- 1.0.2: Low and High have their own distance limits; a setup from before has one shared pair, which framed both.
	if first.fetch("S3Cam.DistanceHigh.Min") == nil and first.fetch("S3Cam.DistanceHigh.Max") == nil then
		camera.distance_high = Settings.copy(camera.distance)
	end
	M.clamp_to_menu_ranges(camera)
	local function saved(prefix)
		for _, field in RIDE_FIELDS do
			if first.fetch(prefix .. field) ~= nil then
				return true
			end
		end
		return false
	end
	if not saved("S3Cam.Distance.") then
		camera.ride_distance = Settings.ride_distance_from_legacy(camera.distance, camera.framing.distance_scale, Settings.CameraAngle.Low)
	end
	if not saved("S3Cam.DistanceHigh.") then
		camera.ride_distance_high =
			Settings.ride_distance_from_legacy(camera.distance_high, camera.framing_high.distance_scale, Settings.CameraAngle.High)
	end
	return report
end

-- Whole-struct safety net after the field pass: drops an offending group to its defaults.
function M.drop_invalid_groups(camera)
	local d = Settings.defaults()
	for _, name in { "look", "shoulder", "follow", "fov", "speed_shake", "collision", "native_plus", "shake", "framing",
		"framing_high", "trick_yaw", "air_camera", "landing_shake", "distance", "distance_high" } do
		if not VALID[name](camera[name]) then
			camera[name] = d[name]
		end
	end
	if not Settings.valid_ride_distance(camera.ride_distance) then
		camera.ride_distance = Settings.default_ride_distance(Settings.CameraAngle.Low)
	end
	if not Settings.valid_ride_distance(camera.ride_distance_high) then
		camera.ride_distance_high = Settings.default_ride_distance(Settings.CameraAngle.High)
	end
end

-- Settings and options from a values table (the profile / storage / a preset's "values"). Returns camera, options, report.
function M.from_values(values, base_camera, base_options)
	local camera = base_camera or Settings.defaults()
	local options = base_options or M.new_options()
	local report = M.load_values(function(key)
		return values[key]
	end, camera, options)
	M.drop_invalid_groups(camera)
	if not Settings.valid(camera) then
		camera = Settings.defaults()
	end
	if not options_ok(options) then
		options = M.new_options()
	end
	return camera, options, report
end

-- ---------------------------------------------------------------- saving
local function tidy(v)
	return tonumber(string.format("%.7g", v)) or v
end

-- Every saved key and value, as one table.
function M.collect_values(camera, options)
	local values = {}
	for _, f in FIELDS do
		local v = group_of(camera, options, f[2])[f[3]]
		if f[4] == "f" then
			v = tidy(v)
		end
		values[f[1]] = v
	end
	values["S3Cam.Preset"] = "full" -- the plugin has only the Full style
	values["S3Cam.Angle"] = angle_names[camera.angle == Settings.CameraAngle.High and 2 or 1]
	values["S3Cam.FovOverride"] = tidy(camera.fov_override_deg)
	local sm = camera.shoulder.mode
	values["S3Cam.Shoulder.Mode"] = shoulder_names[sm == Settings.ShoulderSide.Manual and 2 or (sm == Settings.ShoulderSide.Auto and 3 or 1)]
	values["S3Cam.Shoulder.Side"] = side_names[camera.shoulder.side == 1 and 2 or 1]
	values["S3Cam.Shoulder.Stance"] = stance_names[camera.shoulder.goofy and 2 or 1]
	local ts = camera.trick_yaw.side
	values["S3Cam.TrickYaw.Side"] = trick_side_names[ts < 0 and 2 or (ts > 0 and 3 or 1)]
	local function mm(fr)
		return manual_mode_names[fr.manual_mode == Settings.ManualDistanceMode.Speed and 2 or 1]
	end
	values["S3Cam.Framing.ManualMode"] = mm(camera.framing)
	values["S3Cam.FramingHigh.ManualMode"] = mm(camera.framing_high)
	local function dm(rd)
		return distance_mode_names[rd.mode == Settings.DistanceMode.Fixed and 2 or 1]
	end
	values["S3Cam.Distance.Mode"] = dm(camera.ride_distance)
	values["S3Cam.DistanceHigh.Mode"] = dm(camera.ride_distance_high)
	return values
end

-- ---------------------------------------------------------------- names
local FORBIDDEN = {}
for c in string.gmatch('\\/:*?"<>|', ".") do
	FORBIDDEN[string.byte(c)] = true
end

local function device_name(stem)
	local l = string.lower(stem)
	l = string.gsub(l, " +$", "")
	if l == "con" or l == "prn" or l == "aux" or l == "nul" then
		return true
	end
	return #l == 4 and (string.sub(l, 1, 3) == "com" or string.sub(l, 1, 3) == "lpt") and string.sub(l, 4, 4) >= "1" and string.sub(l, 4, 4) <= "9"
end

-- A name that is safe as a file name stem: printable ASCII only (the data folder takes nothing else), the characters
-- \/:*?"<>| dropped, trimmed, at most 48 characters, a device name such as CON given an underscore. "" when nothing is left.
function M.sanitize_name(text)
	local kept = {}
	for i = 1, #text do
		local b = string.byte(text, i)
		if b >= 0x20 and b <= 0x7E and not FORBIDDEN[b] and not (#kept == 0 and b == 0x20) then
			kept[#kept + 1] = string.char(b)
			if #kept >= M.max_name_chars then
				break
			end
		end
	end
	local s = table.concat(kept)
	s = string.gsub(s, "[ %.]+$", "")
	if s == "" then
		return s
	end
	local dot = string.find(s, ".", 1, true)
	if device_name(dot and string.sub(s, 1, dot - 1) or s) then
		s ..= "_"
	end
	return s
end

function M.same_name(a, b)
	return string.lower(a) == string.lower(b)
end

-- `name` itself when nothing has it, else "name (2)", "name (3)", ... `taken(candidate)` says whether a name is in use.
function M.unique_name(name, taken)
	local base = M.sanitize_name(name)
	if base == "" then
		return base
	end
	if not taken(base) then
		return base
	end
	for n = 2, 999 do
		local suffix = " (" .. n .. ")"
		local candidate = M.sanitize_name(string.sub(base, 1, M.max_name_chars - #suffix)) .. suffix
		if not taken(candidate) then
			return candidate
		end
	end
	return ""
end

-- ---------------------------------------------------------------- built-ins (code, not files)
M.builtin_count = 2
local BUILTIN_NAMES = { "Skate 3", "Close & low" }
function M.builtin_name(i)
	return BUILTIN_NAMES[i] or ""
end

-- The settings a built-in sets (everything else at the code defaults).
function M.builtin_settings(i)
	local s = Settings.defaults()
	if i == 2 then -- Close & low. TUNE
		s.angle = Settings.CameraAngle.Low
		s.ride_distance.slow = 1.53 -- 0.85x the Low chase distances (its old distance scale)
		s.ride_distance.fixed = 1.53
		s.ride_distance.fast = 2.125
		s.framing.height_degrees = -3.0
	end
	return s
end

function M.find_builtin(name)
	for i = 1, M.builtin_count do
		if M.same_name(name, BUILTIN_NAMES[i]) then
			return i
		end
	end
	return nil
end

-- ---------------------------------------------------------------- the preset JSON
function M.preset_table(name, camera, options)
	return { name = name, version = M.preset_version, values = M.collect_values(camera, options) }
end

function M.preset_text(name, camera, options)
	return reskate.json.encode(M.preset_table(name, camera, options), true)
end

-- Reads a preset over the code defaults. Returns parsed { name, camera, options, report, from_newer_version } or nil, error
-- ("not_json" | "not_preset" | "too_large").
function M.parse_preset(text)
	if #text > M.max_preset_bytes then
		return nil, "too_large"
	end
	local ok, root = pcall(reskate.json.decode, text)
	if not ok then
		return nil, "not_json"
	end
	if type(root) ~= "table" or type(root.values) ~= "table" or type(root.version) ~= "number" or root.version ~= floor(root.version) then
		return nil, "not_preset"
	end
	if root.version < 1 then
		return nil, "not_preset"
	end
	local name = type(root.name) == "string" and M.sanitize_name(root.name) or ""
	if name == "" then
		name = "Imported preset"
	end
	local camera, options, report = M.from_values(root.values)
	return {
		name = name,
		camera = camera,
		options = options,
		report = report,
		from_newer_version = root.version > M.preset_version,
	}
end

-- ---------------------------------------------------------------- the files
-- Results are { ok, confirm, message, name }.
local cache = {} -- list of { name, built_in }

local function result(ok, message, name)
	return { ok = ok, message = message, name = name }
end

local function file_of(stem)
	return M.folder .. "/" .. stem .. ".json"
end

local function file_exists(stem)
	local ok, text = pcall(reskate.files.read, file_of(stem))
	return ok and text ~= nil
end

local function is_built_in(name)
	return M.find_builtin(name) ~= nil
end

local function read_text(stem)
	local ok, text = pcall(reskate.files.read, file_of(stem))
	if ok and text ~= nil and #text <= M.max_preset_bytes then
		return text
	end
	return nil
end

local function refused_note(parsed)
	local extra = ""
	if parsed.report.refused > 0 then
		extra ..= " (" .. parsed.report.refused .. " value(s) were out of range or the wrong type and kept their defaults)"
	end
	if parsed.from_newer_version then
		extra ..= " (made by a newer version: the settings this version knows were loaded)"
	end
	if parsed.report.native_asked then
		extra ..= " (it asked for the Native+ style, which this plugin does not have: Full is used)"
	end
	return extra
end

local function error_message(err, what)
	if err == "too_large" then
		return what .. " is too large to be a Dynamic Camera preset."
	end
	return what .. " is not a Dynamic Camera preset."
end

-- Rescans the folder (built-ins first, then the files by name).
function M.refresh()
	local list = {}
	for i = 1, M.builtin_count do
		list[#list + 1] = { name = BUILTIN_NAMES[i], built_in = true }
	end
	local ok, names = pcall(reskate.files.list, M.folder)
	local stems = {}
	if ok and names then
		for _, n in names do
			if string.lower(string.sub(n, -5)) == ".json" and #stems < 500 then
				local stem = string.sub(n, 1, -6)
				if stem ~= "" and not is_built_in(stem) then
					stems[#stems + 1] = stem
				end
			end
		end
	end
	table.sort(stems, function(a, b)
		local x, y = string.lower(a), string.lower(b)
		if x ~= y then
			return x < y
		end
		return a < b
	end)
	for _, s in stems do
		list[#list + 1] = { name = s, built_in = false }
	end
	cache = list
	return list
end

function M.list()
	if #cache == 0 then
		M.refresh()
	end
	return cache
end

-- Applies a preset to the store (store.lua): settings and options (a built-in puts the options back to their defaults).
function M.load(store, name)
	local i = M.find_builtin(name)
	if i then
		if not store:set_settings(M.builtin_settings(i)) then
			return result(false, "That preset is not valid.")
		end
		store:set_options(M.new_options())
		return result(true, "Loaded '" .. BUILTIN_NAMES[i] .. "'", BUILTIN_NAMES[i])
	end
	local stem = M.sanitize_name(name)
	if stem == "" or not file_exists(stem) then
		return result(false, "'" .. name .. "' is not in the preset folder any more.")
	end
	local text = read_text(stem)
	if not text then
		return result(false, "Could not read '" .. name .. "'.")
	end
	local parsed, err = M.parse_preset(text)
	if not parsed then
		return result(false, error_message(err, "'" .. name .. "'"))
	end
	if not store:set_settings(parsed.camera) then
		return result(false, "'" .. name .. "' does not hold valid settings.")
	end
	store:set_options(parsed.options)
	return result(true, "Loaded '" .. name .. "'" .. refused_note(parsed), name)
end

function M.save(store, name, overwrite)
	local stem = M.sanitize_name(name)
	if stem == "" then
		return result(false, "Type a name for the preset first (letters, digits and spaces).")
	end
	if is_built_in(stem) then
		return result(false, "'" .. stem .. "' is a built-in preset. Pick another name.")
	end
	if file_exists(stem) and not overwrite then
		local r = result(false, "'" .. stem .. "' already exists.", stem)
		r.confirm = true
		return r
	end
	local ok, wrote, why = pcall(reskate.files.write, file_of(stem), M.preset_text(stem, store.settings, store.options))
	if not ok or not wrote then
		return result(false, "Could not write the preset file for '" .. stem .. "'" .. (why and (": " .. tostring(why)) or "."))
	end
	M.refresh()
	return result(true, "Saved '" .. stem .. "'", stem)
end

function M.rename(from, to)
	if is_built_in(from) then
		return result(false, "Built-in presets cannot be renamed.")
	end
	local stem = M.sanitize_name(to)
	if stem == "" then
		return result(false, "Type the new name first.")
	end
	if is_built_in(stem) then
		return result(false, "'" .. stem .. "' is a built-in preset. Pick another name.")
	end
	local old = M.sanitize_name(from)
	if old == "" or not file_exists(old) then
		return result(false, "'" .. from .. "' is not in the preset folder any more.")
	end
	local same = M.same_name(old, stem)
	if not same and file_exists(stem) then
		return result(false, "'" .. stem .. "' already exists.")
	end
	local text = read_text(old)
	local written = false
	if text then
		local ok, json = pcall(reskate.json.decode, text)
		if ok and type(json) == "table" then
			json.name = stem -- the name inside the file follows, so a shared copy carries the new name
			local ok2, w = pcall(reskate.files.write, file_of(stem), reskate.json.encode(json, true))
			written = ok2 and w == true
		end
	end
	if not written then
		-- No rename in the API: copy the text as it is, then remove the old file.
		local ok2, w = pcall(reskate.files.write, file_of(stem), text or "")
		if not (ok2 and w == true and text) then
			return result(false, "Could not rename '" .. from .. "'.")
		end
	end
	if not same then
		pcall(reskate.files.remove, file_of(old))
	end
	M.refresh()
	return result(true, "Renamed '" .. from .. "' to '" .. stem .. "'", stem)
end

function M.delete(name)
	if is_built_in(name) then
		return result(false, "Built-in presets cannot be deleted.")
	end
	local stem = M.sanitize_name(name)
	if stem == "" or not file_exists(stem) then
		M.refresh()
		return result(false, "'" .. name .. "' is not in the preset folder any more.")
	end
	local ok, removed = pcall(reskate.files.remove, file_of(stem))
	if not ok or not removed then
		return result(false, "Could not delete '" .. name .. "'.")
	end
	M.refresh()
	return result(true, "Deleted '" .. name .. "'", name)
end

-- Saves the preset in `text` (a picked file's contents) as a new preset with a free name.
function M.import_text(text)
	local first = string.find(text, "%S")
	if not first then
		return result(false, "That file is empty.")
	end
	local parsed, err = M.parse_preset(string.sub(text, first))
	if not parsed then
		return result(false, error_message(err, "That file"))
	end
	local stem = M.unique_name(parsed.name, function(c)
		return is_built_in(c) or file_exists(c)
	end)
	if stem == "" then
		return result(false, "Could not find a free name for the preset.")
	end
	local ok, wrote = pcall(reskate.files.write, file_of(stem), M.preset_text(stem, parsed.camera, parsed.options))
	if not ok or not wrote then
		return result(false, "Could not write the preset file for '" .. stem .. "'.")
	end
	M.refresh()
	return result(true, "Imported '" .. stem .. "'" .. refused_note(parsed), stem)
end

-- Opens the preset folder in Explorer (made if missing).
function M.reveal()
	local ok, opened, why = pcall(reskate.files.reveal, M.folder)
	if ok and opened then
		return result(true, "Opened the preset folder.")
	end
	return result(false, "Could not open the preset folder" .. (why and (": " .. tostring(why)) or "."))
end

return M
