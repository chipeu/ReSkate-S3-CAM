-- Port of Engine/Game/Camera/s3_graph.h: the shot selector (a priority state machine with a little
-- hysteresis), the chase blend filter, and the Low / High shot lookup (shot_pair, resolve_shot, blend_shots).
--
-- Priority, highest first:
--   Wipeout > Landing (window after touchdown) > Air (big / normal by predicted max height) >
--   Grind (ledge L / R / flat) > Manual (far / close by speed) > Chase (slow-fast blend by speed;
--   up / down by incline).
--
-- ShotId is a small integer (the same values as the C++ enum class): Graph.ShotId.Wipeout = 0 ... ChaseDown = 11.
-- Graph.shot_id_count = 12. CameraAngle is Shots.Low (0) / Shots.High (1).
--
-- API:
--   Graph.settings()                 GraphSettings with the C++ defaults; transition_time is a 1-based array
--                                    of 12 (index with Graph.transition_time(set, shot_id))
--   Graph.valid(set)                 GraphSettings::valid()
--   Graph.new_input()                GraphInput defaults (dt, bailing, air, grinding, grind_side, manual,
--                                    manual_one_shot, touchdown, speed, predicted_max_height, incline_degrees)
--   local g = Graph.new(); Graph.reset(g)
--   Graph.select(g, input, set) -> out   { shot, chase_blend, landing_active }  (g.out, reused every call: read it
--                                    before the next select). Invalid settings / dt keep the previous selection.
--   g.shot, g.landing_active, g.since_touchdown   read-only state (C++ shot() / landing_active() / seconds_since_touchdown())
--   Graph.shot_id_name(id), Graph.shot_pair(id, angle) -> name_a, name_b
--   Graph.lookup_shots(id, angle) -> { a = Shot, b = Shot }   cache while the selection stays the same
--   Graph.blend_shots(resolved, chase_blend, out) -> Shot     (`out` optional: reuse a Shot table)
--   Graph.resolve_shot(id, angle, chase_blend) -> Shot

local S3 = require("s3math")
local Shots = require("shots")

local M = {}

local clamp01 = S3.clamp01
local abs = math.abs
local max = math.max
local filter_blend_value = S3.filter_blend_value

local ShotId = {
	Wipeout = 0,
	Landing = 1,
	AirBig = 2,
	AirNormal = 3,
	GrindLedgeL = 4,
	GrindLedgeR = 5,
	GrindFlat = 6,
	ManualFar = 7,
	ManualClose = 8,
	Chase = 9, -- slow / fast blend by speed
	ChaseUp = 10, -- riding uphill
	ChaseDown = 11, -- riding downhill
}
M.ShotId = ShotId
M.shot_id_count = 12

local ID_NAMES = {
	[0] = "wipeout",
	"landing",
	"air_big",
	"air_normal",
	"grind_ledge_l",
	"grind_ledge_r",
	"grind_flat",
	"manual_far",
	"manual_close",
	"chase",
	"chase_up",
	"chase_down",
}

function M.shot_id_name(id)
	return ID_NAMES[id] or "?"
end

-- ---------------------------------------------------------------- settings

function M.settings()
	return {
		landing_window = 0.25, -- s after touchdown the Landing shot holds (the card)
		landing_min_air_time = 0.1, -- s of air before a touchdown counts as a landing; TUNE (skips a curb bump)
		big_air_height = 1.5, -- m predicted max height at/above which the air shot is "big"; TUNE
		big_air_hysteresis = 0.3, -- m; once big, stays big until height < big_air_height - this; TUNE
		manual_far_speed = 5.0, -- m/s at/above which a manual uses the far shot; TUNE
		manual_speed_hysteresis = 0.75, -- m/s; TUNE
		chase_slow_speed = 3.0, -- m/s; chase is the slow shot at/below this (blend tree point 0); TUNE
		chase_fast_speed = 9.0, -- m/s; chase is the fast shot at/above this (blend tree point 1); TUNE
		chase_blend_smoothing = 0.85, -- 0..1 filter_blend_value smoothing, applied per fixed step; TUNE
		incline_up_degrees = 8.0, -- riding uphill steeper than this uses ChaseUp; TUNE
		incline_down_degrees = 8.0, -- riding downhill steeper than this (magnitude) uses ChaseDown; TUNE
		incline_hysteresis_degrees = 4.0, -- TUNE (4: noisy ground flickered the 3 degree band)
		incline_dwell = 0.4, -- s a chase / chase up / chase down shot is kept before another incline change; TUNE
		air_min_time = 0.05, -- s the air state must last before the air shot (a two-step blip is not a jump); TUNE
		-- Seconds to ease into each shot (shot_manager.rs transition_time; the Rust default is 0.5). All TUNE.
		-- 1-based array, index = ShotId + 1.
		transition_time = {
			0.30, -- Wipeout
			0.15, -- Landing
			0.40, -- AirBig
			0.40, -- AirNormal
			0.40, -- GrindLedgeL
			0.40, -- GrindLedgeR
			0.40, -- GrindFlat
			0.40, -- ManualFar
			0.40, -- ManualClose
			0.60, -- Chase
			0.60, -- ChaseUp
			0.60, -- ChaseDown
		},
	}
end

function M.transition_time(set, id)
	return set.transition_time[id + 1]
end

function M.valid(set)
	local function fin(v)
		return v - v == 0
	end
	local landing_window = set.landing_window
	if not fin(landing_window) or landing_window < 0.0 or landing_window > 5.0 then
		return false
	end
	local incline_dwell = set.incline_dwell
	if not fin(incline_dwell) or incline_dwell < 0.0 or incline_dwell > 5.0 then
		return false
	end
	local air_min_time = set.air_min_time
	if not fin(air_min_time) or air_min_time < 0.0 or air_min_time > 1.0 then
		return false
	end
	local lmat = set.landing_min_air_time
	if not fin(lmat) or lmat < 0.0 or lmat > 5.0 then
		return false
	end
	local bah = set.big_air_height
	if not fin(bah) or bah < 0.0 then
		return false
	end
	local bahy = set.big_air_hysteresis
	if not fin(bahy) or bahy < 0.0 or bahy > bah then
		return false
	end
	local mfs = set.manual_far_speed
	if not fin(mfs) or mfs < 0.0 then
		return false
	end
	local msh = set.manual_speed_hysteresis
	if not fin(msh) or msh < 0.0 or msh > mfs then
		return false
	end
	local css, cfs = set.chase_slow_speed, set.chase_fast_speed
	if not fin(css) or css < 0.0 or not fin(cfs) or not (cfs > css) then
		return false
	end
	local cbs = set.chase_blend_smoothing
	if not fin(cbs) or cbs < 0.0 or cbs > 1.0 then
		return false
	end
	local iu, id, ih = set.incline_up_degrees, set.incline_down_degrees, set.incline_hysteresis_degrees
	if not fin(iu) or iu <= 0.0 or iu >= 90.0 then
		return false
	end
	if not fin(id) or id <= 0.0 or id >= 90.0 then
		return false
	end
	if not fin(ih) or ih < 0.0 or ih >= iu or ih >= id then
		return false
	end
	local tt = set.transition_time
	for i = 1, 12 do
		local t = tt[i]
		if t == nil or not fin(t) or t < 0.0 or t > 10.0 then
			return false
		end
	end
	return true
end

-- ---------------------------------------------------------------- the selector

-- The conditions, already reduced from the subject by the caller (CameraMan).
function M.new_input()
	return {
		dt = S3.fixed_step, -- s, the fixed step (60 Hz)
		bailing = false, -- IsWipingOut
		air = false, -- IsInOnBoardAir (physics state 200 / 201)
		grinding = false, -- SkaterIsGrinding (state 400-499)
		grind_side = 0, -- -1 IsGrindLedgeLeft, +1 IsGrindLedgeRight, 0 flat
		manual = false, -- IsInManual
		manual_one_shot = false, -- the player's manual camera is on: one manual shot (ManualClose) at every speed (1.0.2)
		touchdown = false, -- this step is the first one after leaving the air (starts the landing window)
		speed = 0.0, -- m/s, |velocity . forward| (CameraSubjectSpeed)
		predicted_max_height = 0.0, -- m above takeoff (PredictedMaxHeight)
		incline_degrees = 0.0, -- slope of the travel direction, + uphill (InclineAngle)
	}
end

function M.new()
	return {
		shot = ShotId.Chase,
		air_clock = 0.0, -- s of continuous air
		since_change = 1.0e3, -- s since the shot last changed
		since_touchdown = -1.0, -- < 0: no touchdown yet
		landing_active = false,
		blend_value = 0.0,
		chase_blend = 0.0,
		blend_valid = false,
		out = { shot = ShotId.Chase, chase_blend = 0.0, landing_active = false },
	}
end

function M.reset(g)
	g.shot = ShotId.Chase
	g.air_clock = 0.0
	g.since_change = 1.0e3
	g.since_touchdown = -1.0
	g.landing_active = false
	g.blend_value = 0.0
	g.chase_blend = 0.0
	g.blend_valid = false
end

-- Blend tree weight of the fast shot: the filtered speed mapped through blend_interval, eased once.
local chase_points = { 0.0, 0.0, 0.0 }
local chase_present = { true, true, false }
local function chase_weight(value, set)
	chase_points[1] = set.chase_slow_speed
	chase_points[2] = set.chase_fast_speed
	local lower, upper, fraction = Shots.blend_interval(chase_points, chase_present, value)
	if lower == nil or lower == upper then
		return 0.0 -- below the first point: all slow
	end
	return S3.sine_blend(clamp01(fraction))
end

local function is_chase_family(id)
	return id == ShotId.Chase or id == ShotId.ChaseUp or id == ShotId.ChaseDown
end

local function pick(g, input, set, speed)
	if input.bailing then
		return ShotId.Wipeout
	end
	if g.landing_active then
		return ShotId.Landing
	end
	if input.air and g.air_clock >= set.air_min_time - 0.5 * input.dt then
		local was_big = g.shot == ShotId.AirBig
		local threshold = was_big and (set.big_air_height - set.big_air_hysteresis) or set.big_air_height
		return input.predicted_max_height >= threshold and ShotId.AirBig or ShotId.AirNormal
	end
	if input.grinding then
		if input.grind_side < 0 then
			return ShotId.GrindLedgeL
		end
		if input.grind_side > 0 then
			return ShotId.GrindLedgeR
		end
		return ShotId.GrindFlat
	end
	if input.manual then
		if input.manual_one_shot then
			return ShotId.ManualClose
		end
		local was_far = g.shot == ShotId.ManualFar
		local threshold = was_far and (set.manual_far_speed - set.manual_speed_hysteresis) or set.manual_far_speed
		return speed >= threshold and ShotId.ManualFar or ShotId.ManualClose
	end
	-- Chase family, with hysteresis on the incline so a bumpy slope does not flicker.
	local up_threshold = g.shot == ShotId.ChaseUp and (set.incline_up_degrees - set.incline_hysteresis_degrees)
		or set.incline_up_degrees
	local down_threshold = g.shot == ShotId.ChaseDown and (set.incline_down_degrees - set.incline_hysteresis_degrees)
		or set.incline_down_degrees
	if input.incline_degrees >= up_threshold then
		return ShotId.ChaseUp
	end
	if input.incline_degrees <= -down_threshold then
		return ShotId.ChaseDown
	end
	return ShotId.Chase
end

-- One fixed step. Invalid settings keep the previous selection.
function M.select(g, input, set)
	local out = g.out
	out.shot = g.shot
	out.chase_blend = g.chase_blend
	out.landing_active = g.landing_active
	local dt = input.dt
	if not M.valid(set) or not (dt > 0.0) or dt - dt ~= 0 then
		return out
	end

	-- Landing window: restarts on a touchdown, otherwise counts up. "Active while elapsed is
	-- under the window minus half a step" makes it exactly window / dt steps long and keeps float
	-- drift from adding or dropping one.
	if input.touchdown then
		g.since_touchdown = 0.0
	elseif g.since_touchdown >= 0.0 then
		g.since_touchdown = g.since_touchdown + dt
	end
	g.landing_active = g.since_touchdown >= 0.0 and g.since_touchdown < set.landing_window - 0.5 * dt

	-- Chase blend tree: the speed is filtered per fixed step and not scaled by dt (shot.rs
	-- filter_blend_value), then mapped through blend_interval and eased once (shot_manager.rs).
	local speed = input.speed
	if speed - speed == 0 then
		speed = abs(speed)
	else
		speed = 0.0
	end
	if not g.blend_valid then
		g.blend_value = math.clamp(speed, set.chase_slow_speed, set.chase_fast_speed)
		g.blend_valid = true
	end
	g.blend_value = filter_blend_value(g.blend_value, speed, set.chase_blend_smoothing, set.chase_slow_speed,
		set.chase_fast_speed)
	g.chase_blend = chase_weight(g.blend_value, set)

	if input.air then
		g.air_clock = g.air_clock + dt
	else
		g.air_clock = 0.0
	end
	local before = g.shot
	local nxt = pick(g, input, set, speed)
	-- The incline shots are kept at least incline_dwell: a noisy slope does not flap between chase, up and down.
	if nxt ~= before and is_chase_family(nxt) and is_chase_family(before) and g.since_change < set.incline_dwell then
		nxt = before
	end
	g.shot = nxt
	if nxt ~= before then
		g.since_change = 0.0
	else
		g.since_change = g.since_change + dt
	end
	out.shot = g.shot
	out.chase_blend = g.chase_blend
	out.landing_active = g.landing_active
	return out
end

-- seconds_since_touchdown() of the C++ is g.since_touchdown.

-- ---------------------------------------------------------------- shot lookup (Low / High)

-- Which table shots a ShotId uses. Low picks the dedicated shots; High has fewer, so several ids
-- share one (21-low-camera.md: wipeouts use the same shot in both graphs). Landing has no published
-- High shot: it reuses high_chase (TUNE). Returns the names of blend tree child 0 (slow) and child 1
-- (fast); equal for everything but Chase.
function M.shot_pair(id, angle)
	if id == ShotId.Wipeout then
		return "wipeout", "wipeout"
	end
	if angle == Shots.Low then
		if id == ShotId.Landing then
			return "landing", "landing"
		elseif id == ShotId.AirBig then
			return "air_high", "air_high"
		elseif id == ShotId.AirNormal then
			return "low_ollie", "low_ollie"
		elseif id == ShotId.GrindLedgeL then
			return "grind_ledge_l", "grind_ledge_l"
		elseif id == ShotId.GrindLedgeR then
			return "grind_ledge_r", "grind_ledge_r"
		elseif id == ShotId.GrindFlat then
			return "grind_flat_slow", "grind_flat_slow"
		elseif id == ShotId.ManualFar then
			return "far_manual", "far_manual"
		elseif id == ShotId.ManualClose then
			return "close_manual", "close_manual"
		elseif id == ShotId.ChaseUp then
			return "chase_up_slow", "chase_up_slow"
		elseif id == ShotId.ChaseDown then
			return "chase_down", "chase_down"
		end
		return "chase_flat_slow", "chase_flat_fast"
	end
	if id == ShotId.AirBig or id == ShotId.AirNormal then
		return "bl_high_air", "bl_high_air"
	elseif id == ShotId.GrindLedgeL or id == ShotId.GrindLedgeR or id == ShotId.GrindFlat then
		return "high_grind", "high_grind"
	elseif id == ShotId.ManualFar or id == ShotId.ManualClose then
		return "high_manual", "high_manual"
	end
	return "high_chase", "high_chase2" -- Landing, Chase, ChaseUp, ChaseDown
end

-- The two table shots of a selection, looked up once so a caller can cache them while the selection
-- stays the same and blend every step with blend_shots(). b == a when the selection has a single shot.
function M.lookup_shots(id, angle)
	local na, nb = M.shot_pair(id, angle)
	local a = Shots.find_shot(na)
	local b = (na == nb) and a or Shots.find_shot(nb)
	return { a = a, b = b }
end

-- The leaf shot of a resolved selection: the single shot, or for Chase the slow/fast pair blended by
-- `chase_blend` through interpolate() (which eases once more, as the Rust blend tree does).
-- With no `out` a single shot is returned as the table-shot itself (do not modify it); with `out` the
-- result is always copied into it.
function M.blend_shots(shots, chase_blend, out)
	chase_blend = chase_blend or 0.0
	local a, b = shots.a, shots.b
	if a == nil then
		if b ~= nil then
			if out then
				return Shots.interpolate(b, b, 0.0, out)
			end
			return b
		end
		return out and Shots.interpolate(Shots.new(), Shots.new(), 0.0, out) or Shots.new()
	end
	if b == nil or a == b then
		if out then
			return Shots.interpolate(a, a, 0.0, out)
		end
		return a
	end
	return Shots.interpolate(a, b, clamp01(chase_blend), out)
end

-- Falls back to a default Shot if the table lacks a name (cannot happen with the built-in table).
function M.resolve_shot(id, angle, chase_blend)
	return M.blend_shots(M.lookup_shots(id, angle), chase_blend)
end

return M
