-- Port of Engine/Game/Camera/s3_shot.h and s3_shots_default.h: one authored camera shot, the maths to
-- blend two of them, the blend-interval chooser and the built-in shot table (Low and High).
--
-- A Shot is a plain table with the C++ field names. Arrays are 1-based Lua arrays (C++ index + 1):
--   shot.distance, shot.lens_length
--   shot.smoothing        = { direction, elevation, yaw, pitch }           (4 numbers, 0 = none, 1 = hold)
--   shot.reference_weights = { Head, Hips, Grind, COM, Board, Trajectory, Anchor, Feet, DampedCOM, unnamed } (10)
--   shot.board_offset, shot.position_heading (rad, pi = behind), shot.position_elevation (rad)
--   shot.framing          = { roll, yaw, pitch }                           (3 numbers, rad)
--   flags: follow_subject_in_air, mirror_for_stance, snap_to_reference_point, use_previous_shot,
--          use_drop_predictor, use_free_camera_stick, avoidance_override
-- All angles are radians, distances metres.
--
-- Enum CameraAngle is a small integer (same values as the C++ enum class): Shots.Low = 0, Shots.High = 1.
--
-- API:
--   Shots.new()                         a default Shot (the C++ Shot{})
--   Shots.copy(shot)                    deep copy
--   Shots.valid(shot)                   the C++ valid(Shot)
--   Shots.interpolate(from, to, fraction, out)  -> out (a new table when `out` is nil; pass a table to avoid allocating)
--   Shots.blend_interval(points, present, value) -> lower, upper, fraction   or nil with no children
--        `points` and `present` are 3-element arrays; lower/upper are 1-BASED child indices
--   Shots.default_shots                 array of { name, angle, shot } (18 entries, C++ order)
--   Shots.find_named_shot(name) / Shots.find_shot(name)   the entry / the Shot, or nil
--   Shots.default_shot_count = 18

local S3 = require("s3math")

local M = {}

local PI = S3.pi
local DEG = S3.degrees
local interpolate_float = S3.interpolate_float

M.Low = 0
M.High = 1
M.CameraAngle = { Low = 0, High = 1 }

M.default_shot_count = 18

-- Shot::new weights the board only; smoothing is the Rust default 0.8.
function M.new()
	return {
		distance = 2.0,
		lens_length = 12.0, -- 12 for every stock shot
		smoothing = { 0.8, 0.8, 0.8, 0.8 },
		reference_weights = { 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 },
		board_offset = 0.0,
		position_heading = PI, -- behind the subject; not blended (see interpolate)
		position_elevation = 0.0,
		framing = { 0, 0, 0 },
		follow_subject_in_air = true,
		mirror_for_stance = true,
		snap_to_reference_point = false,
		use_previous_shot = false,
		use_drop_predictor = false,
		use_free_camera_stick = false,
		avoidance_override = false,
	}
end

function M.copy(s)
	local out = {}
	for k, v in s do
		if type(v) == "table" then
			local t = {}
			for i, x in v do
				t[i] = x
			end
			out[k] = t
		else
			out[k] = v
		end
	end
	return out
end

local function finite(v)
	return v - v == 0
end

local function all_finite(values)
	for _, v in values do
		if not finite(v) then
			return false
		end
	end
	return true
end

-- True when the shot is safe to hand to the rig: every number finite, a positive distance and lens,
-- smoothing in [0, 1] (above 1 would make the filter in filter_blend_value overshoot), elevation
-- short of straight up/down, and non-negative reference weights that sum above the Rust
-- reference_point cutoff (otherwise the reference point falls back to the subject).
function M.valid(s)
	if not finite(s.distance) or not (s.distance > 0.0) then
		return false
	end
	if not finite(s.lens_length) or not (s.lens_length > 0.0) then
		return false
	end
	if not all_finite(s.smoothing) or not all_finite(s.reference_weights) or not all_finite(s.framing) then
		return false
	end
	if not finite(s.board_offset) or not finite(s.position_heading) or not finite(s.position_elevation) then
		return false
	end
	for _, v in s.smoothing do
		if v < 0.0 or v > 1.0 then
			return false
		end
	end
	local weight_sum = 0.0
	for _, w in s.reference_weights do
		if w < 0.0 then
			return false
		end
		weight_sum = weight_sum + w
	end
	if not (weight_sum > 1e-4) then
		return false
	end
	local limit = PI / 2
	return s.position_elevation > -limit and s.position_elevation < limit
end

-- Blend two shots (shot.rs interpolate_from). Numbers ease with sine_blend(fraction) through
-- interpolate_float style 0; discrete options come from `to` even at fraction 0. Heading is not
-- blended (Rust leaves it to the shot's own evaluation), so the result carries `to`'s heading.
-- The caller owns clamping `fraction` to [0, 1]. Pass `out` (any Shot table, may even be `from`) to avoid
-- allocating; a fresh Shot is made when it is nil.
function M.interpolate(from, to, fraction, out)
	if out == nil then
		out = M.new()
	end
	local sb = S3.sine_blend(fraction)
	-- interpolate_float(a, b, 0, fraction) inlined: a + (b - a) * sine_blend(fraction)
	out.distance = from.distance + (to.distance - from.distance) * sb
	out.lens_length = from.lens_length + (to.lens_length - from.lens_length) * sb
	local os, fs, ts = out.smoothing, from.smoothing, to.smoothing
	for i = 1, 4 do
		os[i] = fs[i] + (ts[i] - fs[i]) * sb
	end
	local ow, fw, tw = out.reference_weights, from.reference_weights, to.reference_weights
	for i = 1, 10 do
		ow[i] = fw[i] + (tw[i] - fw[i]) * sb
	end
	out.board_offset = from.board_offset + (to.board_offset - from.board_offset) * sb
	out.position_elevation = from.position_elevation + (to.position_elevation - from.position_elevation) * sb
	local of, ff, tf = out.framing, from.framing, to.framing
	for i = 1, 3 do
		of[i] = ff[i] + (tf[i] - ff[i]) * sb
	end
	-- discrete flags and heading from the target
	out.position_heading = to.position_heading
	out.follow_subject_in_air = to.follow_subject_in_air
	out.mirror_for_stance = to.mirror_for_stance
	out.snap_to_reference_point = to.snap_to_reference_point
	out.use_previous_shot = to.use_previous_shot
	out.use_drop_predictor = to.use_drop_predictor
	out.use_free_camera_stick = to.use_free_camera_stick
	out.avoidance_override = to.avoidance_override
	return out
end

-- Which two children of a blend tree a value falls between (shot.rs blend_interval, TU3 82E07240).
-- `present[i]` says whether child i exists; the list stops at the first absent child. Returns nil
-- with no children, else lower, upper, fraction (1-based indices). A value below the first point picks
-- child 1 outright, one at/above the last point picks the last child outright; lower/upper may be equal
-- at the ends. Points are expected ascending. A NaN value matches no point and so lands on the last child.
-- fraction: 0 = all `lower`, 1 = all `upper`; feed it to interpolate().
function M.blend_interval(points, present, value)
	local count = 0
	while count < 3 and present[count + 1] do
		count = count + 1
	end
	if count == 0 then
		return nil
	end
	for i = 1, count do
		if points[i] > value then
			if i == 1 then
				return 1, 1, 1.0
			end
			return i - 1, i, (value - points[i - 1]) / (points[i] - points[i - 1])
		end
	end
	local lower = count >= 2 and count - 1 or 1
	return lower, count, 1.0
end

-- ---------------------------------------------------------------- default table

-- Authored units: metres and degrees. Everything not passed here is a shared hand-picked default.
local function make_shot(distance, elevation_deg, pitch_deg, board_offset)
	local s = M.new()
	s.distance = distance
	s.lens_length = 12.0 -- 12 for every stock shot
	s.position_elevation = elevation_deg * DEG
	s.framing = { 0.0, 0.0, pitch_deg * DEG }
	s.board_offset = board_offset
	return s
end

local function with_smoothing(s, direction, elevation, yaw, pitch)
	s.smoothing = { direction, elevation, yaw, pitch }
	return s
end

local function with_weights(s, weights)
	s.reference_weights = { table.unpack(weights) }
	return s
end

local function with_flags(s, follow_in_air, drop_predictor)
	s.follow_subject_in_air = follow_in_air
	s.use_drop_predictor = drop_predictor
	return s
end

-- Reference-point weight presets (order: Head, Hips, Grind, COM, Board, Trajectory, Anchor, Feet,
-- DampedCOM, unnamed). All TUNE: the stock weights are not published.
local board_weights = { 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 }
local grind_weights = { 0, 0, 0.5, 0, 0.5, 0, 0, 0, 0, 0 } -- TUNE
local air_weights = { 0, 0, 0, 0.25, 0.5, 0.25, 0, 0, 0, 0 } -- TUNE
local body_weights = { 0, 0.5, 0, 0.5, 0, 0, 0, 0, 0, 0 } -- TUNE
M.board_weights, M.grind_weights, M.air_weights, M.body_weights = board_weights, grind_weights, air_weights, body_weights

local Low, High = M.Low, M.High

local function entry(name, angle, shot)
	return { name = name, angle = angle, shot = shot }
end

local function ledge(heading_offset)
	local s = with_weights(make_shot(1.7, 8.0, -8.0, 0.6), grind_weights)
	s.position_heading = PI + heading_offset * DEG
	return s
end

M.default_shots = {
	-- ---- Low camera: distance, elevation, pitch, board offset from section 1.3 (21-low-camera.md).
	entry("chase_flat_slow", Low, with_smoothing(make_shot(1.8, 7.0, -4.0, 0.9), 0.85, 0.85, 0.8, 0.8)), -- smoothing TUNE
	entry("chase_flat_fast", Low, with_smoothing(make_shot(2.5, 5.0, -2.0, 0.9), 0.8, 0.8, 0.8, 0.8)), -- smoothing TUNE
	entry("chase_up_slow", Low, with_smoothing(make_shot(2.1, -5.0, -10.0, 0.9), 0.85, 0.85, 0.8, 0.8)), -- smoothing TUNE
	-- Not published: looking down a slope, a little further back and higher than chase_flat_slow.
	entry("chase_down", Low, with_flags(make_shot(2.3, 12.0, 0.0, 0.9), true, true)), -- TUNE (all but lens)
	entry("grind_flat_slow", Low, with_weights(make_shot(1.5, 7.0, -10.0, 0.6), grind_weights)), -- weights TUNE
	-- Ledge shots are not published: grind_flat_slow pushed a little to the side (heading offset) and back.
	entry("grind_ledge_l", Low, ledge(-25.0)), -- TUNE
	entry("grind_ledge_r", Low, ledge(25.0)), -- TUNE
	entry("far_manual", Low, make_shot(2.35, 13.0, -2.0, 0.9)),
	entry("close_manual", Low, make_shot(1.1, -5.0, -8.0, 0.5)),
	-- Air shots: not published. Low stays close and level; the rig holds height (manager_air.rs).
	entry("low_ollie", Low, with_flags(with_weights(make_shot(2.2, 6.0, -3.0, 0.9), air_weights), false, false)), -- TUNE
	entry("air_high", Low, with_flags(with_weights(make_shot(3.2, 14.0, 0.0, 0.9), air_weights), false, false)), -- TUNE: big air
	entry("landing", Low, with_smoothing(make_shot(2.0, 6.0, -4.0, 0.9), 0.7, 0.7, 0.7, 0.7)), -- TUNE
	entry("wipeout", Low, with_flags(with_weights(make_shot(3.0, 15.0, 0.0, 0.5), body_weights), false, false)), -- TUNE
	-- ---- High camera
	entry("high_chase", High, make_shot(3.0, 30.0, 3.0, 1.0)),
	entry("high_chase2", High, make_shot(4.4, 26.6, 5.0, 1.0)),
	entry("high_grind", High, with_weights(make_shot(2.9, 17.0, 5.0, 1.0), grind_weights)), -- weights TUNE
	entry("high_manual", High, make_shot(2.25, 19.0, 0.0, 1.0)),
	entry("bl_high_air", High, with_flags(with_weights(make_shot(4.0, 25.0, 3.0, 1.0), air_weights), false, false)), -- TUNE
}

local by_name = {}
for _, e in M.default_shots do
	by_name[e.name] = e
end

-- The shot called `name`, or nil. The table is tiny and this runs on shot change, not per frame.
function M.find_named_shot(name)
	return by_name[name]
end

function M.find_shot(name)
	local e = by_name[name]
	return e and e.shot or nil
end

return M
