-- Port of Engine/Game/Camera/s3_rig.h: AnchorTracker, HeadingTracker, ElevationTracker,
-- DistanceTracker, Compass and Rig, with the RigSettings defaults.
-- World is Y up; heading 0 looks down +Z and grows toward -X (heading(v) = atan2(-x, z)).
-- Call Rig.update on the fixed 1/60 s step. All state is in preallocated tables; Rig.update
-- allocates nothing (vectors are values). It writes its result into rig.out (reused every step).
--
-- API:
--   Rig.default_settings()      RigSettings with the C++ defaults: { anchor, heading, elevation, distance, compass }
--   Rig.valid(set)              the C++ RigSettings::valid()
--   Rig.new_input()             one RigInput table (same fields as the C++ RigInput), mutate it each step
--   local r = Rig.new()
--   Rig.reset(r, input, set)    teleport / take ownership: everything lands on the targets at rest
--   Rig.update(r, dt, input, set) -> r.out  { anchor, heading, elevation, distance, compass_heading, anchor_lag }
--   Rig.reset_distance(r, d)    place the distance tracker (at rest) on d
--   Rig.place_heading(r, heading, shot_heading)   place compass + heading tracker (at rest) on heading
--   r.compass / r.anchor / r.heading / r.elevation / r.distance   the sub-states (read-only for callers):
--        compass.heading, anchor.tracker.position/velocity/target, anchor.smoothing, anchor.latched,
--        heading.tracker.position/velocity, elevation.position/velocity, distance.position/velocity
--   Rig.heading_of(dir), Rig.rig_angle_smoothing(s), Rig.rig_step, Rig.default_shot_smoothing
--
-- Validation: the C++ checks RigSettings::valid() on every update. Here the settings are validated once
-- (Rig.valid, called by the camera when settings change) and update does not re-check, for speed.
-- Rig.set_validate_each_step(true) switches the per-update check back on (the tests use it to check the
-- C++ "invalid settings leave everything as it was" behaviour); with it off, invalid settings are the
-- caller's bug.
--
-- Per-step settings copies (heading boost, distance params) are passed as arguments instead of copied.

local S3 = require("s3math")
local T = require("tracker")

local M = {}

local PI = S3.pi
local DEG = S3.degrees
local wrap_angle = S3.wrap_angle
local blend_angle = S3.blend_angle
local clamp01 = S3.clamp01
local heading_of = S3.heading_of
local normalized = S3.normalized
local ZERO = S3.ZERO
local vcreate = vector.create
local vmagnitude = vector.magnitude
local abs = math.abs
local max = math.max
local min = math.min
local clamp = math.clamp
local sqrt = math.sqrt

M.rig_step = S3.fixed_step
M.default_shot_smoothing = 0.8
local ANCHOR_SPEED_MARGIN = 5.0 -- m/s the anchor may move faster than the skater, to catch up its lag

-- ------------------------------------------------------------------ settings

local function finite(v)
	return v - v == 0
end

local function frac(v)
	return v - v == 0 and v >= 0.0 and v <= 1.0
end

local function anchor_defaults()
	return {
		push_curve = T.lag_curve(),
		pump_curve = T.lag_curve(),
		push_max_smoothing = 0.6,
		pump_max_smoothing = 0.4,
		pump_min_acceleration = 4.0,
		speed_clamp = 25.0,
		acceleration_clamp = 120.0,
		lag_full_below_speed = 4.0,
		lag_off_above_speed = 8.0,
		lag_hold_time = 0.5,
	}
end

local function anchor_valid(a)
	return T.lag_valid(a.push_curve) and T.lag_valid(a.pump_curve) and frac(a.push_max_smoothing)
		and frac(a.pump_max_smoothing) and finite(a.pump_min_acceleration) and finite(a.speed_clamp)
		and a.speed_clamp > 0.0 and finite(a.acceleration_clamp) and a.acceleration_clamp > 0.0
		and finite(a.lag_full_below_speed) and a.lag_full_below_speed >= 0.0 and finite(a.lag_off_above_speed)
		and a.lag_off_above_speed > a.lag_full_below_speed and finite(a.lag_hold_time) and a.lag_hold_time > 0.0
		and a.lag_hold_time <= 5.0
end

local function angle_rig_valid(s)
	return T.valid_angle(s.tracker) and finite(s.max_elevation_degrees) and s.max_elevation_degrees > 0.0
		and s.max_elevation_degrees < 90.0
end

local function heading_defaults()
	local t = T.angle_settings()
	t.delta_umbra_degrees = 3.0
	t.delta_penumbra_degrees = 40.0
	t.speed_clamp_degrees = 200.0
	t.acceleration_min_degrees = 400.0
	t.acceleration_max_degrees = 900.0
	return { tracker = t, max_elevation_degrees = 80.0 }
end

local function elevation_defaults()
	local t = T.angle_settings()
	t.delta_umbra_degrees = 1.0
	t.delta_penumbra_degrees = 20.0
	t.speed_clamp_degrees = 60.0
	t.acceleration_min_degrees = 200.0
	t.acceleration_max_degrees = 400.0
	return { tracker = t, max_elevation_degrees = 80.0 }
end

local function distance_defaults()
	return {
		normal = { speed_clamp = 6.0, acceleration_clamp = 20.0, smoothing = 0.1 },
		fast = { speed_clamp = 14.0, acceleration_clamp = 60.0, smoothing = 0.05 },
		min_distance = 0.6,
		min_distance_wipeout = 0.3,
		near_distance = 1.05,
		near_acceleration = 100.0,
	}
end

local function distance_valid(d)
	local function good(p)
		return finite(p.speed_clamp) and p.speed_clamp > 0.0 and finite(p.acceleration_clamp)
			and p.acceleration_clamp > 0.0 and finite(p.smoothing) and p.smoothing >= 0.0 and p.smoothing <= 1.0
	end
	return good(d.normal) and good(d.fast) and finite(d.min_distance) and d.min_distance >= 0.0
		and finite(d.min_distance_wipeout) and d.min_distance_wipeout >= 0.0 and finite(d.near_distance)
		and d.near_distance >= 0.0 and finite(d.near_acceleration) and d.near_acceleration > 0.0
end

local function compass_defaults()
	return {
		heading_response = 0.08,
		time_before_lineup = 1.5,
		lineup_speed = 0.03,
		stopped_speed = 0.5,
		min_deadzone_speed = 1.0,
		max_deadzone_speed = 6.0,
		max_deadzone_size = 0.3,
		deadzone_smoothing = 0.9,
	}
end

local function compass_valid(c)
	return frac(c.heading_response) and frac(c.lineup_speed) and frac(c.deadzone_smoothing)
		and finite(c.time_before_lineup) and c.time_before_lineup >= 0.0 and finite(c.stopped_speed)
		and c.stopped_speed >= 0.0 and finite(c.min_deadzone_speed) and c.min_deadzone_speed >= 0.0
		and finite(c.max_deadzone_speed) and c.max_deadzone_speed > c.min_deadzone_speed
		and finite(c.max_deadzone_size) and c.max_deadzone_size >= 0.0
end

-- RigSettings with the C++ defaults.
function M.default_settings()
	return {
		anchor = anchor_defaults(),
		heading = heading_defaults(),
		elevation = elevation_defaults(),
		distance = distance_defaults(),
		compass = compass_defaults(),
	}
end

function M.valid(set)
	return anchor_valid(set.anchor) and angle_rig_valid(set.heading) and angle_rig_valid(set.elevation)
		and distance_valid(set.distance) and compass_valid(set.compass)
end

local validate_each_step = false
function M.set_validate_each_step(on)
	validate_each_step = on and true or false
end

-- ------------------------------------------------------------------ input (one shared table, mutated in place)

function M.new_input()
	return {
		anchor = {
			position = ZERO, -- only X and Z are used
			reference_height = 0.0, -- world Y to track instead of position.y
			velocity = ZERO,
			push_state = false,
			push_kick = false,
			pump_acceleration = 0.0,
			no_lag = false,
		},
		compass = {
			position = ZERO,
			forward = vcreate(0, 0, 1),
			grind_direction = vcreate(0, 0, 1),
			grinding = false,
			wiping_out = false,
			crouching = false,
			hold = false,
			reset = false,
		},
		heading_from_compass = true,
		shot_heading = PI,
		heading_target = 0.0,
		heading_offset = 0.0,
		heading_active = true,
		heading_boost = false,
		heading_smoothing = M.default_shot_smoothing,
		elevation_target = 0.0,
		elevation_smoothing = M.default_shot_smoothing,
		distance = { target = 2.0, fast = false, wipeout = false, snap = false },
	}
end

-- ------------------------------------------------------------------ anchor (push / pump lag)

local function anchor_new()
	return { tracker = T.new_vector_state(), latch_time = 0.0, input_time = 0.0, smoothing = 0.0, latched = false }
end

local function anchor_reset(a, position, reference_height)
	T.vector_reset(a.tracker, vcreate(position.x, reference_height, position.z))
	a.latch_time = 0.0
	a.input_time = 0.0
	a.smoothing = 0.0
	a.latched = false
end

local function anchor_update(a, dt, inp, set)
	if not (dt > 0.0) or dt - dt ~= 0 then
		return a.tracker.position
	end
	local hold = set.lag_hold_time
	-- latch_smoothing: decay, set while latched, read the curve at 1 - time / hold.
	local latch_time = max(0.0, a.latch_time - dt)
	if not inp.push_state then
		a.latched = false
	elseif inp.push_kick then
		a.latched = true
	end
	if a.latched then
		latch_time = hold
	end
	a.latch_time = latch_time
	local latch = clamp01(T.lag_evaluate(set.push_curve, 1.0 - latch_time / hold)) * set.push_max_smoothing
	-- input_smoothing: same, triggered by pump acceleration over the threshold.
	local input_time = max(0.0, a.input_time - dt)
	if inp.pump_acceleration > set.pump_min_acceleration then
		input_time = hold
	end
	a.input_time = input_time
	local input = clamp01(T.lag_evaluate(set.pump_curve, 1.0 - input_time / hold)) * set.pump_max_smoothing
	-- The larger of the two, faded out as the anchor speeds up.
	local speed = vmagnitude(inp.velocity)
	local fade = clamp01((set.lag_off_above_speed - speed) / (set.lag_off_above_speed - set.lag_full_below_speed))
	local smoothing
	if inp.no_lag then
		smoothing = 0.0
	else
		smoothing = max(latch, input) * fade
	end
	a.smoothing = smoothing
	-- The speed cap limits the lag's catch-up, not the skater: it stays above his speed.
	local speed_clamp = max(set.speed_clamp, speed + ANCHOR_SPEED_MARGIN)
	local p = inp.position
	return T.vector_update(a.tracker, vcreate(p.x, inp.reference_height, p.z), dt, speed_clamp,
		set.acceleration_clamp, smoothing)
end

-- ------------------------------------------------------------------ heading and elevation

-- The tracker smoothing the rig derives from a shot's smoothing: with h = 1 - s the tracker is
-- bound to 1 - h * h.
local function rig_angle_smoothing(shot_smoothing)
	local h = 1.0 - clamp01(shot_smoothing)
	return 1.0 - h * h
end

M.rig_angle_smoothing = rig_angle_smoothing

local function heading_new()
	return { tracker = T.new_state(), offset = 0.0 }
end

local function heading_current(h)
	return wrap_angle(h.tracker.position + h.offset)
end

-- Returns the tracked heading plus offset.
local function heading_update(h, dt, target, offset, active, boost, shot_smoothing, set)
	if offset - offset == 0 then
		h.offset = offset
	else
		h.offset = 0.0
	end
	if not (dt > 0.0) or target - target ~= 0 then
		return heading_current(h)
	end
	if not active and not boost then
		return heading_current(h)
	end
	local current = heading_current(h)
	local err = abs(wrap_angle(wrap_angle(target) - current))
	-- The shot sets the smoothing for a small error; it is capped at 0.8 for big errors, so the
	-- camera hurries when it is far off and settles gently.
	local base = rig_angle_smoothing(shot_smoothing)
	local capped = min(base, 0.8)
	local quarter_turn = PI / 4
	local smoothing
	if err < quarter_turn then
		smoothing = base + (capped - base) * (err / quarter_turn)
	else
		smoothing = capped
	end
	smoothing = clamp01(smoothing)
	-- boost doubles both acceleration clamps; the heading carries its velocity through the target.
	T.angle_update_ex(h.tracker, target, dt, set.tracker, smoothing, boost and 2.0 or 1.0, false)
	return heading_current(h)
end

local function elevation_update(e, dt, target, set, shot_smoothing)
	if not (dt > 0.0) or target - target ~= 0 then
		return e.position
	end
	local limit = set.max_elevation_degrees * DEG
	local smoothing = clamp01(rig_angle_smoothing(shot_smoothing))
	return T.angle_update_ex(e, clamp(wrap_angle(target), -limit, limit), dt, set.tracker, smoothing, 1.0,
		set.tracker.overshoot_zeroes_velocity)
end

-- ------------------------------------------------------------------ distance

local function distance_update(d, dt, inp, set)
	if not (dt > 0.0) or inp.target - inp.target ~= 0 then
		return d.position
	end
	local minimum
	if inp.wipeout then
		minimum = set.min_distance_wipeout
	else
		minimum = set.min_distance
	end
	local target = max(inp.target, minimum)
	if inp.snap then
		T.scalar_reset(d, target)
		return d.position
	end
	local p
	if inp.fast then
		p = set.fast
	else
		p = set.normal
	end
	local acc
	if d.position < set.near_distance then
		acc = set.near_acceleration
	else
		acc = p.acceleration_clamp
	end
	-- ScalarTrackerSettings defaults: delta_umbra 0, delta_penumbra 1, overshoot_zeroes_velocity true.
	return T.scalar_step(d, target, dt, 0.0, 1.0, p.speed_clamp, acc, acc, p.smoothing, p.smoothing, true)
end

-- ------------------------------------------------------------------ compass

local function compass_new()
	return {
		heading = 0.0,
		velocity = ZERO,
		damped_velocity = ZERO,
		previous_position = ZERO,
		dz_x = 0.0, -- dead-zone point (x, z)
		dz_z = 0.0,
		deadzone_size = 0.0,
		stopped_time = 0.0,
		initialized = false,
	}
end

local function compass_reset(c, position, forward)
	c.velocity = ZERO
	c.damped_velocity = ZERO
	c.deadzone_size = 0.0
	c.stopped_time = 0.0
	c.previous_position = position
	c.dz_x = position.x
	c.dz_z = position.z
	c.heading = heading_of(forward)
	c.initialized = true
end

-- The dead-zone point trails the subject, staying within the radius.
local function compass_deadzone(c, dt, x, z)
	local old_x, old_z = c.dz_x, c.dz_z
	local dx, dz = x - old_x, z - old_z
	local distance = sqrt(dx * dx + dz * dz)
	if distance > c.deadzone_size and distance > 0.0 then
		local move = (distance - c.deadzone_size) / distance
		c.dz_x = old_x + dx * move
		c.dz_z = old_z + dz * move
	end
	c.damped_velocity = vcreate((c.dz_x - old_x) / dt, 0.0, (c.dz_z - old_z) / dt)
end

-- The movement compass: heading follows the dead-zoned travel direction while moving and lines up
-- behind the subject's forward once it has been stopped for time_before_lineup.
local function compass_update(c, dt, inp, set)
	if not (dt > 0.0) or dt - dt ~= 0 then
		return c.heading
	end
	local pos, fwd = inp.position, inp.forward
	local psum = pos.x + pos.y + pos.z
	local fsum = fwd.x + fwd.y + fwd.z
	if psum - psum ~= 0 or fsum - fsum ~= 0 then
		return c.heading
	end
	if inp.reset or not c.initialized then
		compass_reset(c, pos, fwd)
		return c.heading
	end
	local velocity = (pos - c.previous_position) * (1.0 / dt)
	c.velocity = velocity
	local vx, vz = velocity.x, velocity.z
	local speed = sqrt(vx * vx + vz * vz)
	local gap = set.max_deadzone_speed - set.min_deadzone_speed
	local fraction = clamp01((speed - set.max_deadzone_speed) / -gap)
	c.deadzone_size = c.deadzone_size + (fraction * set.max_deadzone_size - c.deadzone_size) * (1.0 - set.deadzone_smoothing)
	compass_deadzone(c, dt, pos.x, pos.z)
	c.previous_position = pos

	if inp.hold then
		c.stopped_time = 0.0
		return c.heading
	end
	if inp.grinding then
		c.heading = heading_of(inp.grind_direction)
		return c.heading
	end
	if inp.wiping_out or speed > set.stopped_speed then
		c.stopped_time = 0.0
	else
		c.stopped_time = c.stopped_time + dt
	end
	if speed > set.stopped_speed then
		local travel = normalized(c.damped_velocity)
		if vmagnitude(travel) > 0.0 then
			c.heading = blend_angle(c.heading, heading_of(travel), set.heading_response) -- per 1/60 s step
		end
	elseif not inp.crouching and c.stopped_time >= set.time_before_lineup then
		c.heading = blend_angle(c.heading, heading_of(fwd), set.lineup_speed) -- per 1/60 s step
	end
	return c.heading
end

-- ------------------------------------------------------------------ the rig

M.heading_of = heading_of

-- Places the distance tracker (at rest) on `distance`: the camera's own ease that ran past it hands back.
function M.reset_distance(r, distance)
	T.scalar_reset(r.distance, distance)
end

-- Places the orbit heading (the compass and the heading tracker, at rest) on `heading`, whatever the tracker did:
-- the camera swung the heading itself (the ramp swing) and the rig carries on from where that left it, so nothing
-- jumps or lags behind when the swing hands back. `shot_heading` is the offset the rig adds to the compass.
function M.place_heading(r, heading, shot_heading)
	r.compass.heading = wrap_angle(heading - shot_heading)
	T.angle_reset(r.heading.tracker, wrap_angle(heading))
end

-- A new rig. Call Rig.reset before the first update.
function M.new()
	return {
		compass = compass_new(),
		anchor = anchor_new(),
		heading = heading_new(),
		elevation = T.new_state(),
		distance = T.new_state(),
		-- Reused every update; read it right after Rig.update.
		out = {
			anchor = ZERO,
			heading = 0.0,
			elevation = 0.0,
			distance = 0.0,
			compass_heading = 0.0,
			anchor_lag = 0.0,
		},
		ready = false,
	}
end

local function resolve_heading(r, inp)
	if inp.heading_from_compass then
		return wrap_angle(r.compass.heading + inp.shot_heading)
	end
	return inp.heading_target
end

-- Teleport / respawn / take ownership: everything lands on this frame's targets with zero velocity.
function M.reset(r, inp, set)
	compass_reset(r.compass, inp.compass.position, inp.compass.forward)
	anchor_reset(r.anchor, inp.anchor.position, inp.anchor.reference_height)
	T.angle_reset(r.heading.tracker, resolve_heading(r, inp))
	local limit = set.elevation.max_elevation_degrees * DEG
	T.angle_reset(r.elevation, clamp(wrap_angle(inp.elevation_target), -limit, limit))
	local dmin
	if inp.distance.wipeout then
		dmin = set.distance.min_distance_wipeout
	else
		dmin = set.distance.min_distance
	end
	T.scalar_reset(r.distance, max(inp.distance.target, dmin))
	r.ready = true
end

-- One fixed step (pass Rig.rig_step). Order follows the Rust rig: compass, anchor, heading,
-- elevation, distance. Returns r.out.
function M.update(r, dt, inp, set)
	local ok = dt > 0.0 and dt - dt == 0
	if ok and validate_each_step then
		ok = M.valid(set)
	end
	if ok then
		compass_update(r.compass, dt, inp.compass, set.compass)
		anchor_update(r.anchor, dt, inp.anchor, set.anchor)
		heading_update(r.heading, dt, resolve_heading(r, inp), inp.heading_offset, inp.heading_active,
			inp.heading_boost, inp.heading_smoothing, set.heading)
		elevation_update(r.elevation, dt, inp.elevation_target, set.elevation, inp.elevation_smoothing)
		distance_update(r.distance, dt, inp.distance, set.distance)
	end
	local out = r.out
	local at = r.anchor.tracker
	out.anchor = at.position
	out.heading = heading_current(r.heading)
	out.elevation = r.elevation.position
	out.distance = r.distance.position
	out.compass_heading = r.compass.heading
	out.anchor_lag = vmagnitude(at.target - at.position)
	return out
end

-- The sub-trackers on their own (the C++ classes), for tests and for callers that drive one directly.
-- Each `*_new()` makes a state table; the update functions take the same arguments as the C++ methods.
M.anchor_new = anchor_new
M.anchor_reset = anchor_reset       -- (a, position, reference_height)
M.anchor_update = anchor_update     -- (a, dt, anchor_input, anchor_settings) -> position
M.heading_new = heading_new
M.heading_current = heading_current -- (h) -> tracked heading + offset
M.heading_update = heading_update   -- (h, dt, target, offset, active, boost, shot_smoothing, angle_rig_settings)
M.elevation_update = elevation_update -- (e_state, dt, target, angle_rig_settings, shot_smoothing); e_state = tracker.new_state()
M.distance_update = distance_update -- (d_state, dt, distance_input, distance_settings); d_state = tracker.new_state()
M.compass_new = compass_new
M.compass_reset = compass_reset     -- (c, position, forward)
M.compass_update = compass_update   -- (c, dt, compass_input, compass_settings) -> heading
M.anchor_valid = anchor_valid
M.angle_rig_valid = angle_rig_valid
M.distance_valid = distance_valid
M.compass_valid = compass_valid
M.heading_defaults = heading_defaults
M.elevation_defaults = elevation_defaults
M.anchor_defaults = anchor_defaults
M.distance_defaults = distance_defaults
M.compass_defaults = compass_defaults

return M
