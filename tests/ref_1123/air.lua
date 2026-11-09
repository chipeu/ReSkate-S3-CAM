-- Port of Engine/Game/Camera/s3_air.h: the "air trick" feel. While the board is airborne the camera
-- must not chase it upward: its reference height eases from the takeoff height to the predicted landing
-- height over the remaining flight time. On touchdown the previous frame's velocity and ground normal are
-- handed to the shake. Call Air.update once per fixed step, in the "prepare" stage, before the incline update.
--
-- API:
--   Air.settings()                 AirSettings defaults { max_ignored_drop, change_threshold, min_remaining_time, hold_height_in_air }
--   Air.valid(set)                 AirSettings::valid()
--   Air.new_input()                AirInput defaults (see fields below)
--   Air.set_prediction(input, prediction, launch_clearance)   fills trajectory_valid / landing_height_delta /
--                                  trajectory_duration from a trajectory.lua prediction (launch_clearance: how far the
--                                  launch point sat above the surface beneath it, 0 when launched from the surface)
--   local a = Air.new(); Air.reset(a, height, grounded)       teleport / respawn: snap the height, drop any transition
--   Air.update(a, dt, input, set) -> out                      out = a.out (REUSED every call: read it before the next
--                                  update): { reference_height, transition_weight, transitioning, prediction_moved,
--                                  landing } where landing is nil or a fresh { normal, velocity } on the single step
--                                  that touches down
--   Air.height(a), Air.transitioning(a)  (a.height is also readable directly)
--   a.transition_start / transition_end / transition_duration / transition_time / moved   state (read-only)
--
-- AirInput fields: grounded, trajectory_valid, landing_height_delta (predicted landing height minus takeoff
-- height, both at the SAME datum), trajectory_time (s since takeoff), trajectory_duration (s, predicted air
-- time), velocity, ground_normal (vectors), anchor_height, follow_anchor_in_air, snap_height.

local S3 = require("s3math")

local M = {}

local clamp01 = S3.clamp01
local abs = math.abs
local max = math.max
local vdot = vector.dot
local ZERO = S3.ZERO
local UP = vector.create(0, 1, 0)

function M.settings()
	return {
		max_ignored_drop = 3.0, -- m. A landing more than this below takeoff gets no transition (manager_air.rs)
		change_threshold = 0.001, -- m. A landing-height change above this recomputes the transition (1 mm)
		min_remaining_time = S3.fixed_step, -- s. Do not arm a transition with less flight than this left
		hold_height_in_air = true, -- true: the reference height does not rise with the board (Rust height mode 1)
	}
end

function M.valid(s)
	local a, b, c = s.max_ignored_drop, s.change_threshold, s.min_remaining_time
	return a - a == 0 and a > 0.0 and a <= 100.0 and b - b == 0 and b > 0.0 and b <= 1.0 and c - c == 0 and c >= 0.0
		and c <= 1.0
end

function M.new_input()
	return {
		grounded = true, -- physics says the board is on the ground (not the 200/201 air states)
		trajectory_valid = false, -- a prediction exists and it landed (TrajectoryPrediction::landed())
		-- Predicted landing height minus takeoff height, both at the SAME datum. A prediction launched
		-- from a point `c` above the surface under it reports landing - launch = surface drop - c, so
		-- set_prediction() adds that clearance back.
		landing_height_delta = 0.0,
		trajectory_time = 0.0, -- s since takeoff
		trajectory_duration = 0.0, -- s, predicted air time
		velocity = ZERO, -- subject velocity this step
		ground_normal = UP, -- ground normal under the subject this step
		anchor_height = 0.0, -- world Y the reference height follows on the ground
		follow_anchor_in_air = false, -- the active shot has follow_subject_in_air
		snap_height = false, -- jump straight to the anchor height this step (a cut)
	}
end

-- Fills the trajectory fields from a trajectory prediction. A Miss or Invalid prediction clears trajectory_valid.
function M.set_prediction(input, prediction, launch_clearance)
	launch_clearance = launch_clearance or 0.0
	local landed = prediction.status == "Landed"
	input.trajectory_valid = landed
	input.landing_height_delta = landed and (prediction.predicted_landing_height + launch_clearance) or 0.0
	input.trajectory_duration = landed and prediction.predicted_air_time or 0.0
end

function M.new()
	return {
		height = 0.0,
		initialized = false,
		transition_start = 0.0,
		transition_end = 0.0,
		transition_duration = 0.0,
		transition_time = 0.0,
		base_height = 0.0,
		previous_delta = 0.0,
		weight = 0.0,
		in_flight = false, -- an airborne step has happened since the last touchdown (base_height is taken)
		tracking = false,
		armed = false,
		moved = false,
		prev_grounded = true, -- true so the first step cannot report a landing
		prev_velocity = ZERO,
		prev_normal = UP,
		out = {
			reference_height = 0.0,
			transition_weight = 0.0,
			transitioning = false,
			prediction_moved = false,
			landing = nil,
		},
	}
end

-- Teleport / respawn: snap the height, drop any transition and forget the previous frame.
function M.reset(a, height, grounded)
	if grounded == nil then
		grounded = true
	end
	a.height = 0.0
	a.initialized = false
	a.transition_start = 0.0
	a.transition_end = 0.0
	a.transition_duration = 0.0
	a.transition_time = 0.0
	a.base_height = 0.0
	a.previous_delta = 0.0
	a.weight = 0.0
	a.in_flight = false
	a.tracking = false
	a.armed = false
	a.moved = false
	a.prev_grounded = true
	a.prev_velocity = ZERO
	a.prev_normal = UP
	if height - height ~= 0 then
		return
	end
	a.height = height
	a.initialized = true
	a.prev_grounded = grounded
end

local function is_transitioning(a)
	return a.transition_duration > 0.0 and a.transition_time < a.transition_duration
end
M.transitioning = is_transitioning

function M.height(a)
	return a.height
end

local function fill(a, out)
	out.reference_height = a.height
	out.transition_weight = a.weight
	out.transitioning = is_transitioning(a)
	out.prediction_moved = a.moved
end

-- ReferenceHeightTracking::update, with smoothing 1 (take the whole step).
local function step_height(a, dt, input, set, ground, weight)
	local old_height = a.height
	local anchor = input.anchor_height
	local target = old_height
	local blending = not input.snap_height and is_transitioning(a)
	if blending then
		local fraction = clamp01(a.transition_time / max(a.transition_duration, 1e-6))
		target = a.transition_start + fraction * (a.transition_end - a.transition_start)
		if a.moved then
			local pull = weight * weight -- the prediction is unsettled: lean on the anchor
			target = (1.0 - pull) * target + anchor * pull
		end
	elseif ground or input.follow_anchor_in_air or not set.hold_height_in_air then
		target = anchor
	elseif input.snap_height or old_height > anchor then
		target = anchor -- hold: never rises with the board, still comes down with it
	end
	a.height = target
	a.transition_time = a.transition_time + dt
end

function M.update(a, dt, input, set)
	local out = a.out
	out.landing = nil
	local anchor_height = input.anchor_height
	if not (dt > 0.0) or dt - dt ~= 0 or anchor_height - anchor_height ~= 0 or not M.valid(set) then
		fill(a, out)
		return out
	end
	if not a.initialized then
		a.height = anchor_height
		a.initialized = true
	end
	local ground = input.grounded
	local weight = 0.0

	if ground then
		-- Touchdown: the response reads last step's velocity and normal, before this step's
		-- incline overwrites them (manager_air.rs). Strictly toward the surface.
		if not a.prev_grounded and vdot(a.prev_velocity, a.prev_normal) < 0.0 then
			out.landing = { normal = a.prev_normal, velocity = a.prev_velocity }
		end
		-- Deviation: Rust lets an unfinished transition run on after landing; cut it so the
		-- camera follows the anchor from the touchdown step on.
		a.in_flight, a.tracking, a.armed, a.moved = false, false, false, false
		a.transition_time, a.transition_duration = 0.0, 0.0
	else
		if not a.in_flight then
			-- First airborne step of the flight: the height now is the takeoff reference height
			-- every (re)computed end is relative to. Taken once per flight; a later prediction
			-- Miss does not re-base it.
			a.in_flight = true
			a.base_height = a.height
		end
		weight = a.weight -- held across a step with no usable prediction
	end
	local delta = input.landing_height_delta
	local duration = input.trajectory_duration
	local ttime = input.trajectory_time
	if not ground and input.trajectory_valid and delta - delta == 0 and duration - duration == 0 and duration > 0.0
		and ttime - ttime == 0 then
		weight = clamp01(ttime / duration)
		local recompute = false
		if a.tracking then
			if abs(delta - a.previous_delta) > set.change_threshold then
				a.moved = true -- flags_517 |= 8: pull toward the anchor as touchdown nears
				recompute = true
			end
		else
			a.tracking = true
			a.moved = false
		end
		a.previous_delta = delta
		local remaining = duration - ttime
		if delta <= -set.max_ignored_drop then
			-- Too deep to follow down: no transition (a recompute into this range cancels one).
			if recompute then
				a.armed = false
				a.transition_time, a.transition_duration = 0.0, 0.0
			end
		elseif (not a.armed or recompute) and remaining > 0.0 and remaining >= set.min_remaining_time then
			a.transition_start = a.height
			a.transition_end = a.base_height + delta
			a.transition_duration = remaining
			a.transition_time = 0.0
			a.armed = true
		end
	end
	-- No usable prediction this step (a Miss or Invalid): hold the current target. The transition,
	-- the tracking state and the base height all carry on until the board is grounded.

	step_height(a, dt, input, set, ground, weight)
	a.weight = weight
	a.prev_grounded = ground
	a.prev_velocity = input.velocity
	a.prev_normal = input.ground_normal
	fill(a, out)
	return out
end

return M
