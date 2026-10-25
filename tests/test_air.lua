-- Port of Engine/Game/Camera/Test/s3cam_air_tests.cpp
local T = require("tlib")
local S = require("s3math")
local Air = require("air")
local Traj = require("trajectory")
T.group("air")
local expect = T.expect
local vc = vector.create
local abs, max = math.abs, math.max
local nan = 0 / 0
local dt = S.fixed_step
local g = 10.1
local board_clearance = 0.9 -- the anchor rides this far above the surface

local function near(a, b, tol)
	return abs(a - b) <= (tol or 1e-4)
end

-- A scripted jump: leave a surface at y = 0 with vertical speed `vy` and land on a surface at
-- `landing_surface_y` (0 = flat, -2 = a stair set). The anchor is the board, 0.9 m up.
local function new_jump()
	return { vy = 3.5, landing_surface_y = 0.0, forward_speed = 5.0 }
end
local function jump_predict(j)
	local launch = Traj.new_launch()
	launch.position = vc(0, 0, 0) -- surface level; the anchor adds board_clearance
	launch.velocity = vc(0, j.vy, j.forward_speed)
	local surface = j.landing_surface_y
	local ground = function(a, b)
		if a.y >= surface and b.y < surface then
			local f = (a.y - surface) / (a.y - b.y)
			return a + (b - a) * f, vc(0, 1, 0)
		end
		return nil
	end
	local ts = Traj.settings()
	ts.gravity = g
	return Traj.predict(launch, ground, ts)
end
local function anchor_height(j, t) return board_clearance + j.vy * t - 0.5 * g * t * t end
local function velocity_at(j, t) return vc(0, j.vy - g * t, j.forward_speed) end

local function fly(j, set, tweak)
	local f = { max_height = -1e9, final_height = 0.0, end_gap = 0.0, landings = 0, steps_in_air = 0,
		monotonic_descent = true, transitioned = false, landing = nil, air = Air.new() }
	local p = jump_predict(j)
	expect(Traj.landed(p), "the scripted jump lands")
	local air_time = p.predicted_air_time
	Air.reset(f.air, board_clearance)
	for _ = 1, 15 do
		local inp = Air.new_input()
		inp.anchor_height = board_clearance
		inp.velocity = vc(0, 0, j.forward_speed)
		Air.update(f.air, dt, inp, set)
	end
	local start_height = f.air.height
	local previous_height = start_height
	for i = 0, 399 do
		local t = i * dt
		local grounded = t >= air_time
		local inp = Air.new_input()
		inp.grounded = grounded
		Air.set_prediction(inp, p)
		inp.trajectory_time = t
		inp.anchor_height = grounded and (j.landing_surface_y + board_clearance) or anchor_height(j, t)
		inp.velocity = grounded and vc(0, 0, j.forward_speed) or velocity_at(j, t)
		inp.ground_normal = vc(0, 1, 0)
		if not grounded then tweak(inp, t) end
		local out = Air.update(f.air, dt, inp, set)
		if out.landing then
			f.landings += 1
			f.landing = out.landing
		end
		if not grounded then
			f.steps_in_air += 1
			f.max_height = max(f.max_height, out.reference_height)
			if out.transitioning then f.transitioned = true end
			if out.reference_height > previous_height + 1e-5 then f.monotonic_descent = false end
			f.end_gap = out.reference_height - inp.anchor_height
		end
		previous_height = out.reference_height
		f.final_height = out.reference_height
	end
	return f
end
local function no_tweak() end

do -- ollie stays low
	local set = Air.settings()
	expect(Air.valid(set), "default air settings are valid")
	local j = new_jump()
	local p = jump_predict(j)
	local apex = p.predicted_max_height
	expect(near(apex, j.vy * j.vy / (2 * g), 0.01), "predicted apex matches the physics")
	local f = fly(j, set, no_tweak)
	local launch_height = board_clearance
	expect(f.max_height < launch_height + 0.35 * apex, "ollie: camera max height stays under launch + 0.35 apex")
	expect(f.max_height <= launch_height + 1e-3, "ollie: on flat ground the camera does not rise at all")
	expect(f.transitioned, "ollie: a transition was armed")
	expect(near(f.final_height, launch_height, 1e-3), "ollie: back on the anchor after landing")
	local follow = Air.settings()
	follow.hold_height_in_air = false
	local chase = fly(j, follow, no_tweak)
	local a = Air.new()
	Air.reset(a, board_clearance)
	local inp = Air.new_input()
	inp.grounded = false
	inp.anchor_height = board_clearance + 0.5
	Air.update(a, dt, inp, follow)
	expect(near(a.height, board_clearance + 0.5), "without the hold the height follows the anchor up")
	expect(chase.landings == 1, "follow variant still lands once")
	local b = Air.new()
	Air.reset(b, board_clearance)
	inp.follow_anchor_in_air = true
	Air.update(b, dt, inp, set)
	expect(near(b.height, board_clearance + 0.5), "follow_anchor_in_air tracks the anchor")
end

do -- stair drop eases down
	local j = new_jump()
	j.landing_surface_y = -2.0
	j.vy = 2.0
	local set = Air.settings()
	local f = fly(j, set, no_tweak)
	expect(f.transitioned, "stairs: transition armed for a 2 m drop")
	expect(f.monotonic_descent, "stairs: the reference height only ever eases down")
	expect(near(f.final_height, -2.0 + board_clearance, 1e-3), "stairs: ends on the lower landing")
	expect(abs(f.end_gap) < 0.15, "stairs: the reference is within 15 cm of the board at touchdown")
	expect(f.landings == 1, "stairs: one landing")

	local p = jump_predict(j)
	local a = Air.new()
	Air.reset(a, board_clearance)
	local mid = 0.0
	for i = 0, math.floor(p.predicted_air_time / dt) - 1 do
		local t = i * dt
		local inp = Air.new_input()
		inp.grounded = false
		Air.set_prediction(inp, p)
		inp.trajectory_time = t
		inp.anchor_height = anchor_height(j, t)
		inp.velocity = velocity_at(j, t)
		local out = Air.update(a, dt, inp, set)
		if i == math.floor(0.5 * p.predicted_air_time / dt) then mid = out.reference_height end
	end
	local final_h = -2.0 + board_clearance
	expect(mid < board_clearance - 0.2 and mid > final_h + 0.2, "stairs: halfway through the flight the camera is halfway down")
end

do -- deep drop is ignored
	local j = new_jump()
	j.landing_surface_y = -3.5
	j.vy = 2.0
	local set = Air.settings()
	local f = fly(j, set, no_tweak)
	expect(not f.transitioned, "deep drop: no transition for a 3.5 m drop")
	expect(f.max_height <= board_clearance + 1e-3, "deep drop: the height still does not rise")
	expect(f.landings == 1, "deep drop: one landing")
	expect(near(f.final_height, -3.5 + board_clearance, 1e-3), "deep drop: follows the anchor down after touchdown")
	local inside = new_jump()
	inside.vy = 2.0
	inside.landing_surface_y = -2.9
	expect(fly(inside, set, no_tweak).transitioned, "a 2.9 m drop does transition")
end

do -- recompute on 1 mm
	local j = new_jump()
	j.landing_surface_y = -2.0
	j.vy = 3.0
	local set = Air.settings()
	local small = fly(j, set, function(inp, t)
		inp.landing_height_delta += (t > 0.2) and 0.0005 or 0.0
	end)
	expect(not small.air.moved, "0.5 mm change does not flag the prediction as moved")

	local a = Air.new()
	Air.reset(a, board_clearance)
	local p = jump_predict(j)
	local moved_steps = 0
	local end_before, end_after = 0.0, 0.0
	for i = 0, math.floor(p.predicted_air_time / dt) - 3 do
		local t = i * dt
		local inp = Air.new_input()
		inp.grounded = false
		Air.set_prediction(inp, p)
		if t > 0.5 * p.predicted_air_time then inp.landing_height_delta -= 0.05 end
		inp.trajectory_time = t
		inp.anchor_height = anchor_height(j, t)
		inp.velocity = velocity_at(j, t)
		local before_end = a.transition_end
		local before_dur = a.transition_duration
		local out = Air.update(a, dt, inp, set)
		if i == math.floor(0.5 * p.predicted_air_time / dt) - 1 then end_before = a.transition_end end
		if out.prediction_moved then moved_steps += 1 end
		if t > 0.5 * p.predicted_air_time and end_after == 0.0 and a.transition_end ~= before_end then
			end_after = a.transition_end
			expect(a.transition_time < dt * 1.5, "recompute restarts the transition clock")
			expect(a.transition_duration < before_dur, "recompute spans only the remaining flight")
		end
	end
	expect(end_before ~= 0.0 and end_after ~= 0.0, "recompute happened after the 5 cm change")
	expect(near(end_before - end_after, 0.05, 2e-3), "the new end is the takeoff height plus the new landing delta")
	expect(moved_steps > 0, "a >1 mm change flags the prediction as moved")

	local restarts = 0
	local b = Air.new()
	Air.reset(b, board_clearance)
	local last_time = 0.0
	for i = 0, math.floor(p.predicted_air_time / dt) - 3 do
		local t = i * dt
		local inp = Air.new_input()
		inp.grounded = false
		Air.set_prediction(inp, p)
		if t > 0.5 * p.predicted_air_time then inp.landing_height_delta -= 0.05 end
		inp.trajectory_time = t
		inp.anchor_height = anchor_height(j, t)
		inp.velocity = velocity_at(j, t)
		Air.update(b, dt, inp, set)
		if b.transition_time < last_time then restarts += 1 end
		last_time = b.transition_time
	end
	expect(restarts == 1, "a settled new prediction restarts the transition exactly once (got " .. restarts .. ")")
end

do -- landing fires once
	local set = Air.settings()
	local j = new_jump()
	local f = fly(j, set, no_tweak)
	expect(f.landings == 1, "landing fires exactly one event")
	expect(f.landing ~= nil, "the landing carried a payload")
	if f.landing then
		local p = jump_predict(j)
		local steps = math.ceil(p.predicted_air_time / dt)
		local expected = velocity_at(j, (steps - 1) * dt)
		expect(near(f.landing.velocity.y, expected.y, 1e-3) and f.landing.velocity.y < -3.0, "event velocity is the previous (airborne) velocity")
		expect(near(f.landing.velocity.z, j.forward_speed), "event velocity keeps the forward component")
		expect(near(f.landing.normal.y, 1.0), "event normal is the ground normal")
	end
end

do -- landing edge cases
	local set = Air.settings()
	local a = Air.new()
	Air.reset(a, 1.0, false)
	local inp = Air.new_input()
	inp.grounded = false
	inp.anchor_height = 1.0
	inp.velocity = vc(0, 2.0, 0)
	Air.update(a, dt, inp, set)
	inp.grounded = true
	expect(Air.update(a, dt, inp, set).landing == nil, "no event when the previous velocity points away from the ground")

	local b = Air.new()
	local ride = Air.new_input()
	ride.velocity = vc(0, -5.0, 0)
	expect(Air.update(b, dt, ride, set).landing == nil, "first step on the ground does not fire")
	expect(Air.update(b, dt, ride, set).landing == nil, "riding does not fire")

	local count = 0
	local c = Air.new()
	Air.reset(c, 0.0)
	for _ = 1, 2 do
		local up = Air.new_input()
		up.grounded = false
		up.velocity = vc(0, -4.0, 0)
		for _ = 1, 10 do Air.update(c, dt, up, set) end
		up.grounded = true
		for _ = 1, 10 do
			if Air.update(c, dt, up, set).landing then count += 1 end
		end
	end
	expect(count == 2, "each touchdown fires once")

	local d = Air.new()
	Air.reset(d, 0.0, false)
	local slope = Air.new_input()
	slope.grounded = false
	slope.velocity = vc(0, -3.0, 4.0)
	slope.ground_normal = S.normalized(vc(0, 1, -0.5))
	Air.update(d, dt, slope, set)
	local touch = Air.new_input()
	touch.grounded = true
	touch.velocity = slope.velocity
	touch.ground_normal = vc(0, 1, 0)
	local out = Air.update(d, dt, touch, set)
	expect(out.landing ~= nil and near(out.landing.normal.z, slope.ground_normal.z), "the event carries the previous step's normal")
end

do -- miss and invalid
	local set = Air.settings()
	local inp = Air.new_input()
	local miss = { status = "Miss" }
	Air.set_prediction(inp, miss)
	expect(not inp.trajectory_valid, "a Miss prediction is not usable")
	local a = Air.new()
	Air.reset(a, 1.0)
	inp.grounded = false
	inp.anchor_height = 2.0
	local out = Air.update(a, dt, inp, set)
	expect(not out.transitioning and near(out.reference_height, 1.0) and near(out.transition_weight, 0.0), "miss: holds, no transition")
	inp.anchor_height = 0.5
	expect(near(Air.update(a, dt, inp, set).reference_height, 0.5), "miss: still comes down with the board")

	local bad = Air.new_input()
	bad.anchor_height = nan
	expect(near(Air.update(a, dt, bad, set).reference_height, 0.5), "non-finite anchor is ignored")
	expect(near(Air.update(a, 0.0, inp, set).reference_height, 0.5), "zero dt is ignored")
	local broken = Air.settings()
	broken.change_threshold = 0.0
	expect(not Air.valid(broken), "zero threshold is invalid")
	expect(near(Air.update(a, dt, inp, broken).reference_height, 0.5), "invalid settings leave the height alone")
end

do -- a one-step prediction Miss mid flight keeps the takeoff base
	local set = Air.settings()
	local a = Air.new()
	Air.reset(a, 1.0) -- takeoff height 1.0
	local previous, miss_step, end_at_miss = 1.0, 0.0, 0.0
	for i = 0, 49 do
		local t = i * dt
		local inp = Air.new_input()
		inp.grounded = false
		inp.anchor_height = 1.0
		inp.trajectory_time = t
		inp.trajectory_duration = 1.0
		inp.velocity = vc(0, -1, 5)
		inp.trajectory_valid = i ~= 29
		inp.landing_height_delta = i < 29 and -2.0 or (i < 40 and -2.05 or -2.10)
		local out = Air.update(a, dt, inp, set)
		if i == 29 then end_at_miss = a.transition_end end
		if i == 29 then miss_step = abs(out.reference_height - previous) end
		previous = out.reference_height
		if i == 29 then
			expect(out.transitioning and out.landing == nil, "miss: the transition carries on through the Miss step")
		end
	end
	expect(near(end_at_miss, -1.0, 1e-3), "miss: the Miss step holds the current target (takeoff 1.0 + delta -2.0)")
	expect(near(a.transition_end, 1.0 - 2.10, 1e-3), "miss: after the Miss the end is takeoff + the new delta (-1.10), not re-based")
	expect(miss_step < 0.05, "miss: the height keeps easing on the Miss step (no jump)")
	local land = Air.new_input()
	land.anchor_height = 0.0
	land.velocity = vc(0, -5, 5)
	Air.update(a, dt, land, set)
	Air.update(a, dt, land, set)
	expect(near(a.height, 0.0, 1e-3), "miss: touchdown follows the anchor")
	local hop = Air.new_input()
	hop.grounded = false
	hop.anchor_height = 0.0
	hop.trajectory_valid = true
	hop.trajectory_duration = 0.5
	hop.landing_height_delta = -1.0
	hop.velocity = vc(0, 2, 5)
	Air.update(a, dt, hop, set)
	expect(near(a.transition_end, -1.0, 1e-3), "miss: the next flight re-bases on its own takeoff height (0.0)")
end

do -- reset snaps
	local set = Air.settings()
	local j = new_jump()
	j.landing_surface_y = -1.0
	local p = jump_predict(j)
	local a = Air.new()
	Air.reset(a, board_clearance)
	local inp = Air.new_input()
	inp.grounded = false
	Air.set_prediction(inp, p)
	inp.anchor_height = board_clearance + 0.3
	inp.trajectory_time = 0.1
	inp.velocity = vc(0, 1, 3)
	Air.update(a, dt, inp, set)
	expect(Air.transitioning(a), "mid-flight transition is live")
	Air.reset(a, 7.0)
	expect(near(a.height, 7.0) and not Air.transitioning(a) and not a.moved, "reset snaps the height and drops the transition")
	local ride = Air.new_input()
	ride.anchor_height = 7.0
	ride.velocity = vc(0, -9, 0)
	expect(Air.update(a, dt, ride, set).landing == nil, "reset forgets the previous frame")
	Air.reset(a, 1.0)
	inp.anchor_height = 4.0
	Air.update(a, dt, inp, set)
	inp.snap_height = true
	expect(near(Air.update(a, dt, inp, set).reference_height, 4.0), "snap_height cuts to the anchor")
end

T.done()
