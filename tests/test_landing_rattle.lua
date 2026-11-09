-- The landing shake: the impulse does not fade with the camera's distance, and the landing rattle (a fast rotation-only shudder, a pure
-- function of the time since the landing).
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_landing_rattle.lua
local T = require("tlib")
local Settings = require("settings")
local Camera = require("camera")
local Subject = require("subject")
local Shake = require("shake")
local SnapGuard = require("snapguard")

T.group("landing_rattle")
local expect, expect_near = T.expect, T.expect_near
local vc = vector.create
local DEG = math.pi / 180.0
local gravity, root_height = 10.1, 0.95

-- ---------------------------------------------------------------- the distance fade (Shake level)

-- A shake that has been on for a while (its weight is 1), kicked by a full landing; `speed` the rumble's speed.
local function warmed(distance, speed, kick)
	local s, set = Shake.new(), Shake.settings()
	for _ = 1, 30 do
		Shake.update(s, 1 / 60, speed, distance, true, set)
	end
	if kick then
		Shake.landing_impulse_fraction(s, 1.0, set)
	end
	return s, set
end

local function strongest(distance, speed, kick)
	local s, set = warmed(distance, speed, kick)
	local best = 0.0
	for _ = 1, 30 do
		local o = Shake.update(s, 1 / 60, speed, distance, true, set)
		best = math.max(best, math.abs(o.pitch), math.abs(o.yaw), math.abs(o.roll))
	end
	return best
end

do
	local near_, far = strongest(2.0, 0.0, true), strongest(3.6, 0.0, true)
	expect(near_ > 0.01, "a landing at 2.0 m shakes the view (" .. near_ .. " rad)")
	expect_near(far / near_, 1.0, 0.05, "the landing impulse's rotation at 3.6 m is the one at 2.0 m")
	-- the same bank position: the whole series agrees, not just its peak
	local a, set = warmed(2.0, 0.0, true)
	local b = warmed(3.6, 0.0, true)
	local worst = 0.0
	for _ = 1, 30 do
		local oa, ob = Shake.update(a, 1 / 60, 0.0, 2.0, true, set), Shake.update(b, 1 / 60, 0.0, 3.6, true, set)
		worst = math.max(worst, math.abs(oa.pitch - ob.pitch), math.abs(oa.yaw - ob.yaw), math.abs(oa.roll - ob.roll))
		expect(vector.magnitude(oa.translation - ob.translation) < 1e-9, "the impulse's translation does not fade either")
	end
	expect(worst < 1e-7, "the landing impulse's rotation is the same at 2.0 and 3.6 m, step by step (" .. worst .. ")")
	local rumble_far, rumble_near = strongest(3.6, 15.0, false), strongest(2.0, 15.0, false)
	expect(rumble_far == 0.0, "the speed rumble at 3.6 m is still faded to 0 (" .. rumble_far .. ")")
	expect(rumble_near > 0.0, "the speed rumble at 2.0 m is there (" .. rumble_near .. ")")
	local mid = strongest(3.1, 15.0, false)
	expect(mid > 0.0 and mid < rumble_near, "the speed rumble still fades in between (" .. mid .. ")")
end

-- ---------------------------------------------------------------- the rattle (Shake level)

-- The rattle of a landing of `fraction` at Landing shake strength `strength`, sampled `fps` times a second from the kick (the shake's
-- own clock: one update after the kick is one step).
local function rattle_series(strength, fraction, fps, seconds)
	local s, set = Shake.new(), Shake.settings()
	set.one_shot_magnitude = strength
	for _ = 1, 30 do
		Shake.update(s, 1 / 60, 0.0, 2.0, true, set)
	end
	expect(Shake.kick_rattle(s, fraction, set), "the landing kicks the rattle")
	local out = {}
	for i = 1, math.floor(seconds * fps) do
		Shake.update(s, 1 / fps, 0.0, 2.0, true, set)
		local r = Shake.rattle(s, set, 0.0)
		out[i] = { t = i / fps, pitch = r.x / DEG, yaw = r.y / DEG, roll = r.z / DEG }
	end
	return out, s, set
end

local function peaks(series)
	local p = { pitch = 0.0, yaw = 0.0, roll = 0.0 }
	for _, f in series do
		p.pitch, p.yaw, p.roll = math.max(p.pitch, math.abs(f.pitch)), math.max(p.yaw, math.abs(f.yaw)), math.max(p.roll, math.abs(f.roll))
	end
	return p
end

do
	local fine = rattle_series(10.0, 1.0, 1000, 0.8)
	local p = peaks(fine)
	expect_near(p.pitch, 3.0, 0.45, "full landing, strength 10: the pitch peak is 3 deg within 15%")
	expect_near(p.yaw, 1.5, 0.225, "the yaw peak is 1.5 deg within 15%")
	expect_near(p.roll, 2.0, 0.3, "the roll peak is 2 deg within 15%")
	local reach, first = nil, nil
	for _, f in fine do
		if not reach and math.abs(f.pitch) >= 2.4 then
			reach = f.t
		end
		if not first and math.abs(f.pitch) > 0.05 then
			first = f.pitch
		end
	end
	expect(reach ~= nil and reach <= 0.04, "|pitch| reaches 2.4 deg within 0.04 s (" .. tostring(reach) .. ")")
	expect(first ~= nil and first < 0.0, "the first swing of the pitch is down")
	local late, end_ = 0.0, 0.0
	local changes, last_sign = 0, 0
	for _, f in fine do
		if f.t >= 0.25 then
			late = math.max(late, math.abs(f.pitch), math.abs(f.yaw) * 2.0, math.abs(f.roll) * 1.5)
		end
		if f.t >= 0.6 then
			end_ = math.max(end_, math.abs(f.pitch), math.abs(f.yaw), math.abs(f.roll))
		end
		if f.t <= 0.2 and math.abs(f.pitch) > 1e-3 then
			local sign = f.pitch > 0 and 1 or -1
			if last_sign ~= 0 and sign ~= last_sign then
				changes += 1
			end
			last_sign = sign
		end
	end
	expect(late < 0.3, "below 10% of the peak by 0.25 s (" .. late .. " deg against 0.3)")
	expect(end_ == 0.0, "zero from 0.6 s (" .. end_ .. ")")
	expect(changes >= 3, "the pitch changes sign at least 3 times within 0.2 s: a rattle, not a sway (" .. changes .. ")")
	-- strength and landing fraction
	expect_near(peaks(rattle_series(3.0, 1.0, 1000, 0.8)).pitch / p.pitch, 0.3, 0.01, "strength 3 gives 0.3x")
	expect_near(peaks(rattle_series(3.0, 1.0, 1000, 0.8)).pitch, 0.9, 0.14, "the default strength 3 gives about 0.9 deg of pitch")
	expect_near(peaks(rattle_series(10.0, 0.5, 1000, 0.8)).pitch / p.pitch, 0.25, 0.01, "a landing fraction of 0.5 gives 0.25x")
	-- frame rate: the same function whatever the step
	local worst = 0.0
	for _, fps in { 30, 60, 144 } do
		for _, f in rattle_series(10.0, 1.0, fps, 0.7) do
			local r = Shake.rattle_at(f.t, 1.0, Shake.settings())
			worst = math.max(worst, math.abs(r.x / DEG - f.pitch), math.abs(r.y / DEG - f.yaw), math.abs(r.z / DEG - f.roll))
		end
	end
	expect(worst < 0.01, "30, 60 and 144 fps agree with the rattle's function of time within 0.01 deg (" .. worst .. ")")
end

do -- landings in a row: a new kick takes over only when it is at least what still runs; no jump bigger than the rattle's own motion
	local function run(second_fraction)
		local s, set = Shake.new(), Shake.settings()
		set.one_shot_magnitude = 10.0
		for _ = 1, 30 do
			Shake.update(s, 1 / 60, 0.0, 2.0, true, set)
		end
		Shake.kick_rattle(s, 1.0, set)
		local last, biggest, restarted = 0.0, 0.0, false
		for i = 1, 60 do
			if i == 6 and second_fraction then
				restarted = Shake.kick_rattle(s, second_fraction, set)
			end
			Shake.update(s, 1 / 60, 0.0, 2.0, true, set)
			local r = Shake.rattle(s, set, 0.0)
			local pitch = r.x / DEG
			if i > 1 then
				biggest = math.max(biggest, math.abs(pitch - last))
			end
			last = pitch
		end
		return biggest, restarted, s
	end
	local single = run(nil)
	local weak, weak_restart = run(0.4)
	local strong, strong_restart, s = run(1.0)
	expect(not weak_restart, "a weaker landing during the rattle leaves it alone")
	expect(strong_restart, "an equal landing during the rattle takes over")
	expect(s.rattle_age < 0.95, "the takeover restarted the clock (" .. s.rattle_age .. ")")
	expect(weak <= single * 1.001, "no jump with the weaker landing (" .. weak .. " against " .. single .. ")")
	expect(strong <= single * 1.05, "no jump bigger than the rattle's own motion at the takeover (" .. strong .. " against " .. single .. ")")
end

-- ---------------------------------------------------------------- through the camera

local function hop_rider(drop)
	local hop_height, air_begin = 0.05, 1.0
	local air_time = math.sqrt(2.0 * hop_height / gravity) + math.sqrt(2.0 * (hop_height + drop) / gravity)
	return function(time)
		local s = Subject.new_snapshot()
		s.valid, s.time, s.velocity = true, time, vc(0, 0, 6)
		s.position = vc(0, root_height, 6 * time)
		s.ground_clearance = root_height
		local since = time - air_begin
		if since >= air_time then
			s.position = vc(0, root_height - drop, 6 * time)
		elseif since >= 0 then
			local vy0 = math.sqrt(2.0 * gravity * hop_height)
			s.position = vc(0, root_height + vy0 * since - 0.5 * gravity * since * since, 6 * time)
			s.velocity = vc(0, vy0 - gravity * since, 6)
			s.physics_state = Subject.physics_state.air
			s.ground_clearance = s.position.y + drop
		end
		return s
	end
end

local function flat_world(ground_y)
	return function(from, to)
		if from.y >= ground_y and to.y < ground_y then
			return from + (to - from) * ((ground_y - from.y) / (to.y - from.y))
		end
		return nil
	end
end

-- Drives the camera through a landing; `each(frame, subject, index)` sees every frame. Returns the frames' list when `keep`.
local function drive(drop, fps, tune, each)
	local cs = Settings.camera()
	cs.shake.one_shot_magnitude = 10.0
	cs.landing_shake.min_fall, cs.landing_shake.full_fall = 0.0, 0.1 -- every landing counts in full
	if tune then
		tune(cs)
	end
	local cam = Camera.new()
	cam:set_settings(cs)
	local at, world = hop_rider(drop), flat_world(-drop)
	for i = 0, math.floor(4.0 * fps) do
		local s = at(i / fps)
		if each then
			each(cam:update(1 / fps, s, world, nil), s, i)
		else
			cam:update(1 / fps, s, world, nil)
		end
	end
end

do -- the rattle in a landing: values, frame rates, no move, off
	local set = Shake.settings()
	local peak_pitch = 0.0
	drive(4.0, 60, nil, function(f, s, i)
		local d = f.debug
		peak_pitch = math.max(peak_pitch, math.abs(d.rattle_pitch) / DEG)
	end)
	expect(peak_pitch > 2.0 and peak_pitch <= 3.2, "a 4 m landing at strength 10 rattles the view by about 3 deg of pitch (" .. peak_pitch .. ")")

	for _, fps in { 30, 60, 144 } do
		local worst, count = 0.0, 0
		drive(4.0, fps, nil, function(f)
			local d = f.debug
			if d.rattle_time >= 0.0 and d.rattle_time < 0.6 then
				count += 1
				local fraction = d.landing_fraction
				local want = Shake.rattle_at(d.rattle_time, fraction * fraction, set)
				worst = math.max(worst, math.abs(d.rattle_pitch - want.x), math.abs(d.rattle_yaw - want.y), math.abs(d.rattle_roll - want.z))
			end
		end)
		expect(count > 0.5 * fps * 0.5, "at " .. fps .. " fps the rattle plays (" .. count .. " frames)")
		expect(worst / DEG < 0.01, "at " .. fps .. " fps every frame shows the rattle's function of its time since the landing (" .. worst / DEG .. " deg)")
	end

	-- the rattle moves the view and never the camera
	local with, without = {}, {}
	local turned = 0.0
	drive(4.0, 60, nil, function(f, s, i)
		with[i] = { f.pos, f.back }
	end)
	drive(4.0, 60, function(cs)
		cs.shake.rattle_pitch_deg, cs.shake.rattle_yaw_deg, cs.shake.rattle_roll_deg = 0.0, 0.0, 0.0
	end, function(f, s, i)
		without[i] = { f.pos, f.back }
	end)
	local moved = 0.0
	for i, a in with do
		moved = math.max(moved, vector.magnitude(a[1] - without[i][1]))
		turned = math.max(turned, vector.magnitude(a[2] - without[i][2]))
	end
	expect(moved == 0.0, "the camera's position is the same with the rattle on and off (" .. moved .. ")")
	expect(turned > 0.02, "and the view differs (" .. turned .. ")")

	-- off with the shake, and while bailing
	local off_max = 0.0
	drive(4.0, 60, function(cs)
		cs.shake_enabled = false
	end, function(f)
		off_max = math.max(off_max, math.abs(f.debug.rattle_pitch), math.abs(f.debug.rattle_yaw), math.abs(f.debug.rattle_roll))
	end)
	expect(off_max == 0.0, "shake off: no rattle (" .. off_max .. ")")
	local bail_max = 0.0
	do
		local cs = Settings.camera()
		cs.shake.one_shot_magnitude = 10.0
		cs.landing_shake.min_fall, cs.landing_shake.full_fall = 0.0, 0.1
		local cam = Camera.new()
		cam:set_settings(cs)
		local at, world = hop_rider(4.0), flat_world(-4.0)
		for i = 0, 240 do
			local s = at(i / 60)
			s.bailing = true
			local f = cam:update(1 / 60, s, world, nil)
			bail_max = math.max(bail_max, math.abs(f.debug.rattle_pitch), math.abs(f.debug.rattle_yaw), math.abs(f.debug.rattle_roll))
		end
	end
	expect(bail_max == 0.0, "bailing: no rattle (" .. bail_max .. ")")
end

do -- the snap guard never smooths the rattle, and still catches a real jump
	local guard = SnapGuard.new()
	local worst, rattle_peak = 0.0, 0.0
	drive(4.0, 60, nil, function(f, s, i)
		local d = f.debug
		local rattle = vc(d.rattle_pitch, d.rattle_yaw, d.rattle_roll)
		rattle_peak = math.max(rattle_peak, math.abs(d.rattle_pitch))
		local pos, fwd, up = guard:filter(i / 60, f.pos, -f.back, f.up, f.fov_deg, s.position, false, d.impact_y, rattle)
		worst = math.max(worst, vector.magnitude(pos - f.pos), vector.magnitude(fwd + f.back), vector.magnitude(up - f.up))
	end)
	expect(rattle_peak > 0.03, "(the landing did rattle: " .. rattle_peak / DEG .. " deg)")
	expect(guard.total == 0, "a 4 m landing at strength 10: no snap smoothed (" .. guard.total .. ")")
	expect(worst < 1e-6, "the shown pose is the camera's own output (" .. worst .. ")")

	-- a rattle's turn is judged without itself: handed over, a big one is not a snap; the same pose without it as a new view is
	local g = SnapGuard.new()
	local subject = vc(0, 0.95, 0)
	local rattle = vc(-0.05, 0.03, 0.04)
	g:filter(0, subject + vc(0, 1.5, -3), vc(0, 0, 1), vc(0, 1, 0), 65, subject, false, 0.0, rattle)
	local _, _, _, _, cause = g:filter(1 / 60, subject + vc(3, 1.5, -3), vc(0, 0, 1), vc(0, 1, 0), 65, subject, false, 0.0, rattle)
	expect(cause == "position", "a 3 m sideways jump during a rattle is still a position snap")
	-- and when it does smooth, the rattle is on the result
	local g2 = SnapGuard.new()
	local f0 = vc(0, 0, 1)
	g2:filter(0, subject + vc(0, 1.5, -3), f0, vc(0, 1, 0), 65, subject, false, 0.0, nil)
	local _, fwd = g2:filter(1 / 60, subject + vc(3, 1.5, -3), f0, vc(0, 1, 0), 65, subject, false, 0.0, nil)
	expect(vector.magnitude(fwd - f0) < 1e-6, "(a smoothed pose without a rattle keeps its view)")
end

T.done()
