-- The landing bounce against the snap guard: the bounce drops the camera by its own amount in a frame on purpose, so the guard must not
-- smooth it. The camera reports the drop (debug.impact_y) and the glue hands it to the guard, as here.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_landing_jolt.lua
local T = require("tlib")
local Settings = require("settings")
local Camera = require("camera")
local Subject = require("subject")
local SnapGuard = require("snapguard")

T.group("landing_jolt")
local expect = T.expect
local vc = vector.create
local gravity, root_height = 10.1, 0.95

local function hop_rider(drop)
	local hop_height, air_begin = 0.05, 1.0
	local air_time = math.sqrt(2.0 * hop_height / gravity) + math.sqrt(2.0 * (hop_height + drop) / gravity)
	local function at(time)
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
	return at
end

local function flat_world(ground_y)
	return function(from, to)
		if from.y >= ground_y and to.y < ground_y then
			return from + (to - from) * ((ground_y - from.y) / (to.y - from.y))
		end
		return nil
	end
end

-- Drives the camera at 60 fps through the guard; `pass_impact` hands it the camera's own drop (the glue does). Returns the guard, the
-- biggest difference between what the camera made and what the guard let through, and the biggest impact seen.
local function drive(drop, pass_impact, shake)
	local cs = Settings.camera()
	cs.shake_enabled = shake == true -- the shake plays on top (the camera's own, not an impact): off for the exact comparison
	local cam = Camera.new()
	cam:set_settings(cs)
	local at, world = hop_rider(drop), flat_world(-drop)
	local guard = SnapGuard.new()
	local worst, impact_max = 0.0, 0.0
	for i = 0, 5 * 60 do
		local s = at(i / 60)
		local f = cam:update(1 / 60, s, world, nil)
		local impact = f.debug.impact_y
		impact_max = math.max(impact_max, math.abs(impact))
		local pos, fwd = guard:filter(i / 60, f.pos, -f.back, f.up, f.fov_deg, s.position, false, pass_impact and impact or nil)
		worst = math.max(worst, vector.magnitude(pos - f.pos), vector.magnitude(fwd + f.back))
	end
	return guard, worst, impact_max
end

for _, drop in { 4.0, 1.5 } do
	local guard, worst, impact = drive(drop, true)
	expect(impact > 0.15, "landing " .. drop .. " m: the camera reports its drop (" .. impact .. " m)")
	expect(guard.total == 0, "landing " .. drop .. " m: no snap smoothed with the impact handed over (" .. guard.total .. ")")
	expect(worst < 1e-6, "landing " .. drop .. " m: the shown camera is the camera's own output (" .. worst .. ")")
end
do -- with the shake on as well (default settings): still nothing smoothed
	local guard = drive(4.0, true, true)
	expect(guard.total == 0, "landing 4 m with the shake on: no snap smoothed (" .. guard.total .. ")")
end
do -- the gentler onset stays below the guard's snap threshold even without an impact exemption
	local guard = drive(4.0, false)
	expect(guard.total == 0, "without the impact handed over the guard still does not see a 4 m landing snap (" .. guard.total .. ")")
end
do -- a real jump during a bounce is still caught: the drop is taken out of the measure, not the guard
	local g = SnapGuard.new()
	local subject = vc(0, 0.95, 0)
	local fwd = vc(0, 0, 1)
	g:filter(0, subject + vc(0, 1.5, -3), fwd, vc(0, 1, 0), 65, subject, false, 0.2)
	local _, _, _, _, cause = g:filter(1 / 60, subject + vc(3, 1.5, -3), fwd, vc(0, 1, 0), 65, subject, false, 0.25)
	expect(cause == "position", "a 3 m sideways jump during a bounce is still a position snap")
end

T.done()
