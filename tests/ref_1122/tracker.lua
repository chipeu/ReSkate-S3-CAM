-- Port of Engine/Game/Camera/s3_tracker.h (ScalarTracker, AngleTracker) plus the VectorTracker and
-- LagCurve that live in s3_rig.h. All state lives in preallocated tables; nothing here allocates
-- per step.
--
-- Skate 3's critically-damped-like follower: each update works out the acceleration that would hit the
-- target this step, clamps it (only while it pushes toward the target), clamps the speed, then moves the
-- position by the smoothed step. Run it on the fixed 1/60 s step, not on raw frame dt.
--
-- API (a tracker is a plain state table; angles are radians, AngleTracker settings are in degrees):
--   T.scalar_settings() / T.angle_settings() / T.vector_settings()   defaults, as the C++ structs
--   T.valid_scalar(set) / T.valid_angle(set)                          the C++ valid(); false = rejected
--   T.new_state()                                                     state of a Scalar/Angle tracker
--   T.scalar_reset(s, v) / T.angle_reset(s, rad)                      jump, motion cleared (ignores non-finite)
--   T.scalar_snap_keep_motion(s, v) / T.angle_snap_keep_motion(s, r)  jump, velocity kept
--   T.scalar_update(s, target, dt, set) / T.angle_update(s, target, dt, set)
--        -> new position. Like the C++ they validate `set` and do nothing when it is invalid; a bad
--        dt/target leaves the state alone. State fields: target, position, velocity, acceleration,
--        acceleration_clamp, smoothing.
--   T.scalar_step(s, target, dt, umbra, penumbra, speed, acc_min, acc_max, sm_min, sm_max, overshoot)
--   T.angle_update_ex(s, target, dt, set, smoothing, acceleration_scale, overshoot_zeroes)
--        hot-path variants WITHOUT validation (the caller validated the settings when they changed):
--        same maths without building a settings copy per step.
--   T.lag_curve() / T.lag_evaluate(curve, x) / T.lag_valid(curve)     LagCurve
--   T.new_vector_state() / T.vector_reset(s, v) / T.vector_update(s, target, dt, speed, acc, smoothing)

local S3 = require("s3math")

local M = {}

local wrap_angle = S3.wrap_angle
local DEG = S3.degrees
local abs = math.abs
local vdot = vector.dot
local vmagnitude = vector.magnitude
local ZERO = S3.ZERO

-- ------------------------------------------------------------------ settings

function M.scalar_settings()
	return {
		delta_umbra = 0.0,
		delta_penumbra = 1.0,
		speed_clamp = 10.0,
		acceleration_min = 20.0,
		acceleration_max = 20.0,
		smoothing_min = 0.0,
		smoothing_max = 0.0,
		overshoot_zeroes_velocity = true,
	}
end

-- Degrees, as AngleTrackerSettings stores them; converted to radians on use.
function M.angle_settings()
	return {
		delta_umbra_degrees = 0.0,
		delta_penumbra_degrees = 30.0,
		speed_clamp_degrees = 360.0,
		acceleration_min_degrees = 720.0,
		acceleration_max_degrees = 720.0,
		smoothing_min = 0.0,
		smoothing_max = 0.0,
		overshoot_zeroes_velocity = true,
	}
end

local function finite_in(v, lo, hi)
	return v - v == 0 and v >= lo and v <= hi
end

local function ordered(umbra, penumbra, speed, acc_min, acc_max, s_min, s_max)
	local big = 1.0e9
	return finite_in(umbra, 0.0, big) and finite_in(penumbra, umbra, big) and finite_in(speed, 1e-6, big)
		and finite_in(acc_min, 0.0, big) and finite_in(acc_max, 0.0, big)
		and finite_in(s_min, 0.0, 1.0) and finite_in(s_max, 0.0, 1.0)
end

function M.valid_scalar(s)
	return ordered(s.delta_umbra, s.delta_penumbra, s.speed_clamp, s.acceleration_min, s.acceleration_max,
		s.smoothing_min, s.smoothing_max)
end

function M.valid_angle(s)
	return ordered(s.delta_umbra_degrees, s.delta_penumbra_degrees, s.speed_clamp_degrees,
		s.acceleration_min_degrees, s.acceleration_max_degrees, s.smoothing_min, s.smoothing_max)
		and s.delta_penumbra_degrees <= 180.0
end

-- ------------------------------------------------------------------ scalar / angle tracker state

-- One state table per tracker: target, position, velocity, acceleration, acceleration_clamp, smoothing.
function M.new_state()
	return {
		target = 0.0,
		position = 0.0,
		velocity = 0.0,
		acceleration = 0.0,
		acceleration_clamp = 0.0,
		smoothing = 0.0,
	}
end

-- Jump to `value` with no motion (a camera cut). Non-finite values are ignored.
function M.scalar_reset(s, value)
	if value - value ~= 0 then
		return
	end
	s.target = value
	s.position = value
	s.velocity = 0.0
	s.acceleration = 0.0
	s.acceleration_clamp = 0.0
	s.smoothing = 0.0
end

function M.angle_reset(s, radians)
	if radians - radians ~= 0 then
		return
	end
	M.scalar_reset(s, wrap_angle(radians))
end

-- Jump to `value` but keep the current velocity (rig_tracking.rs reset_* with clear_motion=false).
function M.scalar_snap_keep_motion(s, value)
	if value - value ~= 0 then
		return
	end
	s.target = value
	s.position = value
end

function M.angle_snap_keep_motion(s, radians)
	if radians - radians ~= 0 then
		return
	end
	M.scalar_snap_keep_motion(s, wrap_angle(radians))
end

-- Shared body of ScalarTracker::update and AngleTracker::update (wrap = true for angles).
-- Returns false (state untouched) on a bad dt or target.
local function step(s, wrap, target, dt, umbra, penumbra, speed_clamp, acc_min, acc_max, smoothing_min,
	smoothing_max, overshoot_zeroes)
	if not (dt > 0.0) or dt - dt ~= 0 or target - target ~= 0 then
		return false
	end
	local position = s.position
	local delta = target - position
	if wrap then
		delta = wrap_angle(delta)
	end
	s.target = target
	local velocity = s.velocity
	if overshoot_zeroes and velocity * delta < 0.0 then
		velocity = 0.0
	end
	-- The acceleration that would land on the target this step.
	local acceleration = ((delta / dt) - velocity) / dt
	-- 1 inside the umbra, 0 past the penumbra, linear between.
	local ad = abs(delta)
	local fraction
	if ad < umbra then
		fraction = 1.0
	elseif ad < penumbra then
		fraction = 1.0 - (ad - umbra) / (penumbra - umbra)
	else
		fraction = 0.0
	end
	-- Only acceleration toward the target is clamped; braking is never limited.
	if acceleration * delta > 0.0 then
		local limit
		if acc_min == acc_max then
			limit = acc_max
		else
			limit = acc_min + (acc_max - acc_min) * fraction
		end
		s.acceleration_clamp = limit
		local magnitude = abs(acceleration)
		if magnitude > limit then
			acceleration = (acceleration / magnitude) * limit
		end
	end
	s.acceleration = acceleration
	velocity = velocity + acceleration * dt
	local speed = abs(velocity)
	if speed > speed_clamp then
		velocity = (velocity / speed) * speed_clamp
	end
	s.velocity = velocity
	local smoothing
	if smoothing_min == smoothing_max then
		smoothing = smoothing_max
	else
		smoothing = smoothing_min + (smoothing_max - smoothing_min) * fraction
	end
	s.smoothing = smoothing
	-- Smoothing shortens the position step only; velocity is not derived back from it.
	if wrap then
		local nxt = wrap_angle(wrap_angle(velocity * dt) + position)
		local displacement = wrap_angle(nxt - position)
		s.position = wrap_angle(wrap_angle(displacement * (1.0 - smoothing)) + position)
	else
		s.position = position + (velocity * dt) * (1.0 - smoothing)
	end
	return true
end

-- ScalarTracker::update with the settings passed as plain numbers (no settings table needed).
function M.scalar_step(s, target, dt, umbra, penumbra, speed_clamp, acc_min, acc_max, smoothing_min,
	smoothing_max, overshoot_zeroes)
	step(s, false, target, dt, umbra, penumbra, speed_clamp, acc_min, acc_max, smoothing_min, smoothing_max,
		overshoot_zeroes)
	return s.position
end

function M.scalar_update(s, target, dt, set)
	if not M.valid_scalar(set) then
		return s.position
	end
	step(s, false, target, dt, set.delta_umbra, set.delta_penumbra, set.speed_clamp, set.acceleration_min,
		set.acceleration_max, set.smoothing_min, set.smoothing_max, set.overshoot_zeroes_velocity)
	return s.position
end

-- AngleTracker::update. `target` in radians (any turn count; it is wrapped).
function M.angle_update(s, target, dt, set)
	if not M.valid_angle(set) then
		return s.position
	end
	step(s, true, wrap_angle(target), dt, set.delta_umbra_degrees * DEG, set.delta_penumbra_degrees * DEG,
		set.speed_clamp_degrees * DEG, set.acceleration_min_degrees * DEG, set.acceleration_max_degrees * DEG,
		set.smoothing_min, set.smoothing_max, set.overshoot_zeroes_velocity)
	return s.position
end

-- AngleTracker::update as the heading / elevation trackers call it: they copy the settings, then
-- set smoothing_min = smoothing_max = `smoothing`, optionally scale both accelerations and override
-- overshoot_zeroes_velocity. Doing that with arguments avoids a settings copy per step.
function M.angle_update_ex(s, target, dt, set, smoothing, acceleration_scale, overshoot_zeroes)
	step(s, true, wrap_angle(target), dt, set.delta_umbra_degrees * DEG, set.delta_penumbra_degrees * DEG,
		set.speed_clamp_degrees * DEG, set.acceleration_min_degrees * acceleration_scale * DEG,
		set.acceleration_max_degrees * acceleration_scale * DEG, smoothing, smoothing, overshoot_zeroes)
	return s.position
end

-- ------------------------------------------------------------------ lag curve (PointGraph<8>)

local LAG_SIZE = 8

function M.lag_curve()
	return {
		x = { 0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0 },
		y = { 1.0, 0.85, 0.65, 0.45, 0.28, 0.14, 0.05, 0.0 },
	}
end

-- Clamps outside the range, linear between.
function M.lag_evaluate(curve, input)
	local xs, ys = curve.x, curve.y
	if input < xs[1] then
		return ys[1]
	end
	if not (input < xs[LAG_SIZE]) then -- also catches NaN
		return ys[LAG_SIZE]
	end
	for upper = 2, LAG_SIZE do
		if input < xs[upper] then
			local lower = upper - 1
			local width = xs[upper] - xs[lower]
			if width <= 0.0 then
				return ys[upper]
			end
			return ys[lower] + (ys[upper] - ys[lower]) / width * (input - xs[lower])
		end
	end
	return ys[1]
end

function M.lag_valid(curve)
	local xs, ys = curve.x, curve.y
	for i = 1, LAG_SIZE do
		if xs[i] - xs[i] ~= 0 or ys[i] - ys[i] ~= 0 then
			return false
		end
		if i > 1 and xs[i] < xs[i - 1] then
			return false
		end
	end
	return true
end

-- ------------------------------------------------------------------ vector tracker

function M.vector_settings()
	return { speed_clamp = 25.0, acceleration_clamp = 120.0, smoothing = 0.0 }
end

function M.new_vector_state()
	return { target = ZERO, position = ZERO, velocity = ZERO, acceleration = ZERO }
end

function M.vector_reset(s, value)
	local sum = value.x + value.y + value.z
	if sum - sum ~= 0 then
		return
	end
	s.target = value
	s.position = value
	s.velocity = ZERO
	s.acceleration = ZERO
end

local function clamp_length(v, limit)
	local magnitude = vmagnitude(v)
	if magnitude > limit then
		return v * (limit / magnitude)
	end
	return v
end

-- VectorTracker::update with min == max clamps and smoothing. Acceleration is clamped only while
-- it pushes toward the target. Returns the new position.
function M.vector_update(s, target, dt, speed_clamp, acceleration_clamp, smoothing)
	local sum = target.x + target.y + target.z
	if not (dt > 0.0) or dt - dt ~= 0 or sum - sum ~= 0 then
		return s.position
	end
	s.target = target
	local delta = target - s.position
	local velocity = s.velocity
	if vdot(delta, velocity) < 0.0 then -- overshoot_zeroes_velocity
		velocity = ZERO
	end
	local inv = 1.0 / dt
	local acceleration = ((delta * inv) - velocity) * inv
	if vdot(acceleration, delta) > 0.0 then
		acceleration = clamp_length(acceleration, acceleration_clamp)
	end
	s.acceleration = acceleration
	velocity = clamp_length(velocity + acceleration * dt, speed_clamp)
	s.velocity = velocity
	s.position = s.position + velocity * (dt * (1.0 - smoothing))
	return s.position
end

return M
