-- subject.lua, rider.lua and settings.lua. The C++ has no unit tests for s3_subject.h / s3_rider.h in the
-- list given; these check behaviour derived from the headers and their comments.
local T = require("tlib")
local S = require("s3math")
local Subject = require("subject")
local Rider = require("rider")
local Settings = require("settings")
local Shots = require("shots")
T.group("misc")
local near, expect = T.near, T.expect
local vc = vector.create
local nan = 0 / 0

do -- subject
	local PS = Subject.physics_state
	expect(PS.ride == 100 and PS.crouch == 103 and PS.pop == 200 and PS.air == 201 and PS.offboard == 504, "physics state values")
	expect(Subject.is_air_state(200) and Subject.is_air_state(201) and not Subject.is_air_state(100), "air states are 200 / 201")
	expect(Subject.is_grind_state(400) and Subject.is_grind_state(499) and not Subject.is_grind_state(500) and not Subject.is_grind_state(399), "grind states are 400-499")
	local s = Subject.new_snapshot()
	expect(not Subject.usable(s), "a default snapshot is not valid")
	s.valid = true
	expect(Subject.usable(s), "a valid default snapshot is usable")
	local function bad(mutate, what)
		local x = Subject.new_snapshot()
		x.valid = true
		mutate(x)
		expect(not Subject.usable(x), what)
	end
	bad(function(x) x.position = vc(nan, 0, 0) end, "NaN position is unusable")
	bad(function(x) x.forward = vc(0, 0, 0) end, "zero forward is unusable")
	bad(function(x) x.ground_normal = vc(0, 0, 0) end, "zero normal is unusable")
	bad(function(x) x.time = math.huge end, "infinite time is unusable")
	bad(function(x) x.grind_side = 2 end, "grind side out of range is unusable")
	bad(function(x) x.ground_clearance = nan end, "NaN clearance is unusable")
	local a = Subject.new_snapshot()
	a.physics_state = PS.air
	expect(Subject.air(a) and not Subject.grinding(a), "snapshot air()")
	a.physics_state = 450
	expect(Subject.grinding(a) and not Subject.air(a), "snapshot grinding()")
end

do -- rider: steady motion seen through a faster frame clock
	local r = Rider.new()
	local board = vc(0, 0, 9) -- wrong on purpose: the rider's own velocity must win
	local step = 1 / 60
	local out
	for k = 0, 143 do
		local now = k / 144
		local root = vc(math.floor(now * 60) / 60 * 6.0, 1, 0)
		out = Rider.update(r, now, root, board, true, step)
	end
	expect(near(out.x, 6.00001, 1e-3) and near(out.z, 0.0, 1e-3), "rider: (C++ probe: 6.00001) measured velocity follows the root, not the board (" .. tostring(out) .. ")")
	-- not onboard: the board's velocity as is
	expect(Rider.update(r, 1.01, vc(7, 1, 0), vc(1, 2, 3), false, step) == vc(1, 2, 3), "rider: off the board returns the board's velocity")
	-- a teleport drops the history: back to the board's velocity at once
	Rider.reset(r)
	local o2 = Rider.update(r, 0.0, vc(0, 0, 0), vc(0, 0, 4), true, step)
	expect(o2 == vc(0, 0, 4), "rider: with nothing measured the board's velocity is used")
	o2 = Rider.update(r, 0.1, vc(0, 0, 0), vc(0, 0, 4), true, step)
	expect(o2 == vc(0, 0, 4), "rider: a root that never changes stays on the board's")
end

do -- rider: acceleration and the jump rule
	local r = Rider.new()
	local step = 1 / 60
	local out
	-- uniform acceleration 10 m/s^2 along z from rest, 60 fps frames on the physics clock
	for k = 0, 59 do
		local t = k * step
		out = Rider.update(r, t, vc(0, 0, 0.5 * 10.0 * t * t), vc(0, 0, 0), true, step)
	end
	-- Golden value from compiling the C++ RiderVelocity (s3_rider.h) on this exact input: 3.27778. (Starting from rest the
	-- first moves are below rider_move_min / too small for the step-count heuristic, so the fit lags the true 9.83 m/s: that
	-- is the C++ behaviour, kept.)
	expect(near(out.z, 3.27778, 1e-3), "rider: matches the C++ on an accelerating root (" .. out.z .. ")")
	-- a 5 m jump between two steps is a teleport: history cleared, board velocity again
	local after = Rider.update(r, 60 * step, vc(0, 0, 50), vc(1, 1, 1), true, step)
	expect(near(after.x, 1.0, 1e-3) and near(after.y, 1.0, 1e-3) and near(after.z, 1.0, 1e-3), "rider: a 3 m+ jump falls back to the board's velocity")
end

do -- settings
	local s = Settings.camera()
	expect(Settings.valid(s), "default camera settings are valid")
	expect(s.preset == Settings.CameraPreset.FullS3 and s.angle == Settings.CameraAngle.Low, "default preset FullS3 / Low")
	expect(s.shake_enabled and s.fov_override_deg == 0.0, "camera defaults")
	expect(Settings.CameraAngle.Low == Shots.Low and Settings.CameraAngle.High == Shots.High, "angle constants agree")
	expect(Settings.valid_rig(s.rig) and Settings.valid_air(s.air) and Settings.valid_shake(s.shake)
		and Settings.valid_trajectory(s.trajectory) and Settings.valid_graph(s.graph), "module groups are valid")
	expect(s.trajectory.gravity == 10.1 and near(s.trajectory.step, 1 / 20) and s.trajectory.max_time == 3.0, "camera trajectory is {10.1, 1/20, 3}")
	-- spot checks on defaults copied from the C++
	expect(s.orientation.pan.delta_penumbra_degrees == 20.0 and s.orientation.tilt.acceleration_max_degrees == 2400.0, "orientation defaults")
	expect(s.points.board_drop == 0.9 and s.points.anchor_height == 0.32 and s.points.head_height == 0.7, "points defaults")
	expect(s.pipeline.max_steps_per_update == 16 and s.pipeline.teleport_distance == 10.0, "pipeline defaults")
	expect(s.look.closeup_exit_time == 0.9 and s.look.manual_focus == 0.25 and s.look.board_anchor, "look defaults")
	expect(s.shoulder.mode == Settings.ShoulderSide.Off and s.shoulder.offset == 0.45 and s.shoulder.side == 1, "shoulder defaults")
	expect(s.follow.strength == 1.0 and s.follow.dynamic_speed == 12.0, "follow defaults")
	expect(s.fov.speed_fov_degrees == 6.0 and s.fov.smoothing_time == 0.35, "fov defaults")
	expect(s.framing.manual_distance == 1.6 and s.framing.manual_mode == Settings.ManualDistanceMode.Fixed, "framing defaults")
	expect(s.framing_high.manual_min_distance == 1.4 and s.framing_high.manual_max_distance == 2.0, "framing_high defaults")
	expect(s.collision.automatic and s.collision.radius == 0.25, "collision defaults")
	expect(s.distance.min == 1.2 and s.distance_high.max == 6.0, "legacy distance limits defaults")
	-- ride distance defaults per angle: Low 1.8 / 2.5, High 3.0 / 4.4
	expect(near(s.ride_distance.slow, 1.8) and near(s.ride_distance.fast, 2.5) and near(s.ride_distance.fixed, 1.8), "Low ride distance")
	expect(near(s.ride_distance_high.slow, 3.0) and near(s.ride_distance_high.fast, 4.4) and near(s.ride_distance_high.fixed, 3.0), "High ride distance")
	expect(s.ride_distance.mode == Settings.DistanceMode.Speed, "ride distance mode defaults to Speed")
	expect(near(Settings.default_ride_distance(Shots.High).fast, 4.4), "default_ride_distance per angle")

	-- ride_distance_from_legacy: scaled chase distances held inside the old limits
	local limits = Settings.distance_limits()
	local r = Settings.ride_distance_from_legacy(limits, 1.0, Shots.Low)
	expect(near(r.slow, 1.8) and near(r.fast, 2.5) and near(r.fixed, 1.8), "legacy conversion, scale 1, Low")
	r = Settings.ride_distance_from_legacy(limits, 2.0, Shots.Low) -- 3.6 / 5.0, inside 1.2..6
	expect(near(r.slow, 3.6) and near(r.fast, 5.0), "legacy conversion scales the distances")
	r = Settings.ride_distance_from_legacy({ min = 1.2, max = 4.0 }, 2.0, Shots.High) -- 6.0 / 8.8 held to 4.0
	expect(near(r.slow, 4.0) and near(r.fast, 4.0) and near(r.fixed, 4.0), "legacy conversion clamps to the limits")
	r = Settings.ride_distance_from_legacy({ min = 0.2, max = 0.3 }, 0.2, Shots.Low) -- never below 0.5
	expect(near(r.slow, 0.5) and r.fast >= r.slow, "legacy conversion never goes below 0.5 m")

	-- validity failures
	local function bad(mutate, what)
		local x = Settings.camera()
		mutate(x)
		expect(not Settings.valid(x), what)
	end
	bad(function(x) x.fov_override_deg = 180 end, "fov_override_deg must be below 180")
	bad(function(x) x.rig.anchor.speed_clamp = -1 end, "a bad rig group fails the whole")
	bad(function(x) x.graph.chase_fast_speed = 1 end, "a bad graph group fails the whole")
	bad(function(x) x.trajectory.step = 0 end, "a bad trajectory group fails the whole")
	bad(function(x) x.pipeline.max_steps_per_update = 0 end, "max_steps_per_update >= 1")
	bad(function(x) x.shoulder.side = 0 end, "shoulder side must be +-1")
	bad(function(x) x.fov.speed_fov_max = x.fov.speed_fov_min end, "fov max above min")
	bad(function(x) x.distance_high.max = x.distance_high.min end, "distance limits need 0.2 m between them")
	bad(function(x) x.ride_distance.fast = x.ride_distance.slow - 0.1 end, "ride fast >= slow")
	bad(function(x) x.framing_high.manual_max_distance = 0.6 end, "manual max >= manual min")
	bad(function(x) x.landing_shake.full_fall = x.landing_shake.min_fall end, "landing full_fall > min_fall")
	bad(function(x) x.trick_yaw.side = 2 end, "trick yaw side in -1..1")
	bad(function(x) x.look.shot_blend = 5 end, "shot_blend in 0.25..4")
	bad(function(x) x.orientation.pan.delta_penumbra_degrees = 270 end, "orientation tracker validity")
	-- deep copy
	local c = Settings.copy(s)
	c.rig.anchor.speed_clamp = 1
	c.rig.anchor.push_curve.y[1] = 0.5
	expect(s.rig.anchor.speed_clamp == 25.0 and s.rig.anchor.push_curve.y[1] == 1.0, "copy is deep")
	expect(Settings.valid(Settings.copy(s)), "a copy is valid")
end

T.done()
