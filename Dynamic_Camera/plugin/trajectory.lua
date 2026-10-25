-- Port of Engine/Game/Camera/s3_trajectory.h: ballistic prediction for the air / landing logic.
-- From the launch position and velocity it walks the parabola in fixed steps, ray-tests every chord
-- against the world through an injected function, and reports what the camera graph reads.
--
-- The world query is a plain function:  query(from, to) -> hit_point, hit_normal
--   from / to : vectors (world space, Y up), one chord of the parabola
--   returns the first contact point of the segment (a vector) and, optionally, the surface normal there
--   (a vector); or nil when the segment is clear. The game cannot give the normal, so it is optional:
--   a missing normal reads as straight up, and landing_incline is then 0.
--
-- API:
--   Traj.settings()                 TrajectorySettings: { gravity = 10.1, step = 1/60, max_time = 3.0 }
--                                   (the camera's defaults are { 10.1, 1/20, 3.0 }, see settings.lua)
--   Traj.valid(set)                 TrajectorySettings::valid()
--   Traj.new_launch()               { position, velocity, launch_normal, camera_distance } defaults
--   Traj.predict(launch, query, settings) -> prediction
--   Traj.landed(p)                  p.status == "Landed"
--   Traj.at(p, v, g, t)             position at time t under gravity -Y
--
-- prediction fields (units as the C++): status = "Invalid" | "Landed" | "Miss" (strings stand for the enum),
--   predicted_air_time, predicted_max_height, predicted_landing_height, height_distance_ratio,
--   launch_incline, landing_incline (rad), apex_time, apex_position, landing_position, landing_normal,
--   segments_tested.

local S3 = require("s3math")

local M = {}

local vcreate = vector.create
local ZERO = S3.ZERO
local UP = vcreate(0, 1, 0)
local clamp01 = S3.clamp01
local normalized = S3.normalized
local vdot = vector.dot
local vmagnitude = vector.magnitude
local abs = math.abs
local min = math.min
local ceil = math.ceil
local clamp = math.clamp
local acos = math.acos

M.Invalid = "Invalid" -- bad input or settings: nothing else in the result is meaningful
M.Landed = "Landed" -- a ground contact was found within max_time
M.Miss = "Miss" -- no contact within max_time (Rust: collision time -1, trajectory not valid)

M.max_steps_limit = 4096 -- bounds the loop for any valid settings

function M.settings()
	return {
		gravity = 10.1, -- m/s2, positive; measured in-game, tunable air.gravity
		step = 1.0 / 60.0, -- s, chord length; the physics tick
		max_time = 3.0, -- s, prediction horizon; a miss past this is "no landing"
	}
end

function M.valid(s)
	local g, step, mt = s.gravity, s.step, s.max_time
	return g - g == 0 and g > 0.0 and g <= 100.0
		and step - step == 0 and step >= 1.0 / 480.0 and step <= 0.25
		and mt - mt == 0 and mt > 0.0 and mt <= 30.0
		and mt / step <= M.max_steps_limit
end

function M.new_launch()
	return {
		position = ZERO,
		velocity = ZERO,
		launch_normal = UP, -- ground normal under the launch; feeds launch_incline
		camera_distance = 0.0, -- m, the rig distance the ratio divides by (manager_air trajectory_camera_distance)
	}
end

function M.landed(p)
	return p.status == "Landed"
end

local function new_prediction()
	return {
		status = "Invalid",
		predicted_air_time = 0.0, -- s, launch -> landing (Miss: max_time)
		predicted_max_height = 0.0, -- m, apex above the launch point, >= 0
		predicted_landing_height = 0.0, -- m, landing minus launch height, negative = lower
		height_distance_ratio = 0.0, -- max height / camera distance; 0 if no distance was given
		launch_incline = 0.0, -- rad, acos(launch normal . up)
		landing_incline = 0.0, -- rad, acos(landing normal . up)
		apex_time = 0.0, -- s after launch; 0 when launched level or downward
		apex_position = ZERO,
		landing_position = ZERO, -- Miss: the parabola at max_time
		landing_normal = UP, -- Miss: up
		segments_tested = 0,
	}
end

local function finite3(v)
	local s = v.x + v.y + v.z
	return s - s == 0
end

-- Position at time t under constant gravity along -Y.
local function at(p, v, g, t)
	return vcreate(p.x + v.x * t, p.y + v.y * t - 0.5 * g * t * t, p.z + v.z * t)
end
M.at = at

local function incline_of(normal)
	local y = clamp(normal.y, -1.0, 1.0)
	return acos(y)
end

-- Walks the parabola and ray-tests each chord, first contact wins. Callers should launch from a point
-- that is not already inside the ground (the game's board sits ~0.9 m above the root-level surface).
-- Time is refined inside the hit chord to the parabola point closest to the contact, as the Rust
-- time_at_contact does, so the chord-vs-arc error (g*dt^2/8 ~ 0.4 mm) does not leak into the air time.
function M.predict(launch, query, settings)
	settings = settings or M.settings()
	local out = new_prediction()
	local cd = launch.camera_distance
	if not M.valid(settings) or not finite3(launch.position) or not finite3(launch.velocity)
		or not finite3(launch.launch_normal) or cd - cd ~= 0 then
		return out
	end

	local gravity = settings.gravity
	local step_len = settings.step
	local max_time = settings.max_time
	local p0 = launch.position
	local v0 = launch.velocity
	-- ceil(max_time / step): the C++ divides floats; a tiny epsilon keeps 3 / (1/60) from becoming 181 in doubles.
	local steps = ceil(max_time / step_len - 1e-6)

	local hit_time = -1.0
	local hit_point, hit_normal = ZERO, nil
	local start = p0
	for i = 0, steps - 1 do
		local t0 = i * step_len
		local t1 = min((i + 1) * step_len, max_time)
		local stop = at(p0, v0, gravity, t1)
		out.segments_tested = out.segments_tested + 1
		local found, found_normal = query(start, stop, true)
		if found ~= nil and finite3(found) then
			hit_point, hit_normal = found, found_normal
			-- Start from the contact's projection on the chord, then a few Newton steps on the
			-- distance to the contact along the parabola; clamped to this segment.
			local chord = stop - start
			local chord2 = vdot(chord, chord)
			local frac = 0.0
			if chord2 > 1e-12 then
				frac = clamp01(vdot(found - start, chord) / chord2)
			end
			local t = t0 + (t1 - t0) * frac
			for _ = 1, 3 do
				local p = at(p0, v0, gravity, t)
				local v = vcreate(v0.x, v0.y - gravity * t, v0.z)
				local d = p - found
				local slope = vdot(v, v) - gravity * d.y
				if not (abs(slope) > 1e-6) then
					break
				end
				t = clamp(t - vdot(d, v) / slope, t0, t1)
			end
			hit_time = t
			break
		end
		start = stop
	end

	local landed = hit_time >= 0.0
	local end_time = landed and hit_time or max_time
	out.status = landed and "Landed" or "Miss"
	out.predicted_air_time = end_time

	-- Apex: closed form, clipped to the part of the flight that happened (a ceiling or an early
	-- landing can end the climb before vy/gravity).
	if v0.y > 0.0 then
		out.apex_time = min(v0.y / gravity, end_time)
	else
		out.apex_time = 0.0
	end
	out.apex_position = at(p0, v0, gravity, out.apex_time)
	out.predicted_max_height = out.apex_position.y - p0.y

	if landed then
		out.landing_position = hit_point
		out.landing_normal = hit_normal ~= nil and normalized(hit_normal, UP) or UP
	else
		out.landing_position = at(p0, v0, gravity, end_time)
		out.landing_normal = UP
	end
	out.predicted_landing_height = out.landing_position.y - p0.y
	out.height_distance_ratio = cd > 0.0 and out.predicted_max_height / cd or 0.0
	out.launch_incline = incline_of(normalized(launch.launch_normal, UP))
	out.landing_incline = incline_of(out.landing_normal)
	return out
end

return M
