-- Port of Engine/Game/Camera/Test/s3cam_trajectory_tests.cpp
-- The query returns (point, normal); ground shapes here are analytic as in the C++ test.
local T = require("tlib")
local S = require("s3math")
local Traj = require("trajectory")
T.group("trajectory")
local near, expect = T.near, T.expect
local degrees = S.degrees
local vc = vector.create
local nan = 0 / 0
local g = 10.1

-- `solid(p)` says whether a point is inside the ground, `normal_at(p)` its surface normal. A segment hits when it
-- goes from free to solid; the crossing is bisected to ~1e-6 m.
local function ground(solid, normal_at)
	local self = { calls = 0 }
	self.query = function(a, b)
		self.calls += 1
		if solid(a) or not solid(b) then
			return nil
		end
		local lo, hi = a, b
		for _ = 1, 40 do
			local mid = lo + (hi - lo) * 0.5
			if solid(mid) then
				hi = mid
			else
				lo = mid
			end
		end
		return hi, normal_at(hi)
	end
	return self
end
local function launch_of(pos, vel, normal, dist)
	return { position = pos, velocity = vel, launch_normal = normal, camera_distance = dist }
end
local UP = vc(0, 1, 0)

do -- settings validation
	expect(Traj.valid(Traj.settings()), "defaults are valid")
	local s = Traj.settings()
	s.gravity = 0.0
	expect(not Traj.valid(s), "zero gravity rejected")
	s = Traj.settings()
	s.gravity = nan
	expect(not Traj.valid(s), "NaN gravity rejected")
	s = Traj.settings()
	s.step = 0.0
	expect(not Traj.valid(s), "zero step rejected")
	s = Traj.settings()
	s.max_time = -1.0
	expect(not Traj.valid(s), "negative horizon rejected")
	s = Traj.settings()
	s.step = 1.0 / 480.0
	s.max_time = 30.0
	expect(not Traj.valid(s), "too many steps rejected")
end

do -- flat ground
	local gr = ground(function(p) return p.y <= 0.0 end, function() return UP end)
	local launch = launch_of(vc(1, 0.5, 2), vc(3, 4, 0), UP, 4.0)
	local p = Traj.predict(launch, gr.query)
	local apex_t = 4.0 / g
	local apex_h = 4.0 * 4.0 / (2 * g)
	local land_t = (4.0 + math.sqrt(16.0 + 2 * g * 0.5)) / g
	expect(p.status == "Landed" and Traj.landed(p), "flat: landed")
	expect(near(p.apex_time, apex_t, 1e-5), "flat: apex time is vy/g")
	expect(near(p.predicted_max_height, apex_h, 1e-4), "flat: apex height is vy^2/2g")
	expect(near(p.predicted_air_time, land_t, 2e-3), "flat: landing time matches the quadratic")
	expect(near(p.predicted_landing_height, -0.5, 1e-4), "flat: landing height is the drop to the floor")
	expect(near(p.landing_position.x, 1 + 3 * land_t, 1e-2) and near(p.landing_position.z, 2, 1e-4), "flat: landing x follows the horizontal velocity")
	expect(near(p.landing_normal.y, 1) and near(p.landing_incline, 0, 1e-4), "flat: level landing")
	expect(near(p.launch_incline, 0, 1e-4), "flat: level launch")
	expect(near(p.height_distance_ratio, apex_h / 4.0, 1e-4), "flat: ratio is apex height over camera distance")
	expect(p.segments_tested == math.ceil(land_t * 60.0), "flat: one query per 1/60 s segment")
	expect(p.segments_tested == gr.calls, "flat: segments_tested matches query calls")

	local no_cam = launch_of(vc(0, 0.5, 0), vc(0, 4, 0), UP, 0.0)
	expect(Traj.predict(no_cam, gr.query).height_distance_ratio == 0.0, "flat: no camera distance gives ratio 0")

	local moon = Traj.settings()
	moon.gravity = 5.0
	local m = Traj.predict(launch, gr.query, moon)
	expect(near(m.apex_time, 4.0 / 5.0, 1e-5), "gravity parameter drives the apex time")
	expect(near(m.predicted_air_time, (4.0 + math.sqrt(16.0 + 2 * 5.0 * 0.5)) / 5.0, 2e-3), "gravity parameter drives the landing time")
end

do -- stair set
	local function height(x) return x < 3.0 and 2.0 or 0.0 end
	local gr = ground(function(p) return p.y <= height(p.x) end, function() return UP end)
	local launch = launch_of(vc(2, 2.05, 0), vc(4, 3, 0), UP, 5.0)
	local p = Traj.predict(launch, gr.query)
	local land_t = (3.0 + math.sqrt(9.0 + 2 * g * 2.05)) / g
	expect(Traj.landed(p), "stairs: landed")
	expect(near(p.apex_time, 3.0 / g, 1e-5), "stairs: apex time")
	expect(near(p.predicted_max_height, 9.0 / (2 * g), 1e-4), "stairs: apex height")
	expect(near(p.predicted_air_time, land_t, 2e-3), "stairs: landing time includes the extra fall")
	expect(p.predicted_air_time > 2 * 3.0 / g, "stairs: longer than a level-ground flight")
	expect(near(p.predicted_landing_height, -2.05, 1e-3), "stairs: landing is about 2 m lower")
	expect(p.landing_position.x > 3.0, "stairs: clears the platform edge")
	expect(p.predicted_air_time < 3.0, "stairs: inside the horizon")
end

do -- quarter pipe
	local R = 3.0
	local function surface(x)
		if x < 0.0 then return 0.0 end
		if x > R then return R end
		return R - math.sqrt(R * R - x * x)
	end
	local gr = ground(function(p) return p.y <= surface(p.x) end, function(p)
		if p.x <= 0.0 then return UP end
		return S.normalized(vc(-p.x, R - p.y, 0), UP)
	end)
	local launch = launch_of(vc(3.0, 3.05, 0), vc(-1, 6, 0), UP, 3.0)
	local p = Traj.predict(launch, gr.query)
	expect(Traj.landed(p), "pipe: re-entry lands")
	expect(near(p.apex_time, 6.0 / g, 1e-5), "pipe: apex time")
	expect(near(p.predicted_max_height, 36.0 / (2 * g), 1e-4), "pipe: apex height")
	expect(p.landing_position.x > 0.0 and p.landing_position.x < R, "pipe: lands on the curved transition")
	expect(near(math.sqrt(p.landing_position.x ^ 2 + (p.landing_position.y - R) ^ 2), R, 5e-3), "pipe: landing point is on the arc")
	local on_path = Traj.at(launch.position, launch.velocity, g, p.predicted_air_time)
	expect(vector.magnitude(on_path - p.landing_position) < 1e-2, "pipe: landing time puts the parabola on the landing point")
	expect(p.predicted_air_time > 2 * p.apex_time, "pipe: lands below the lip, after the symmetric time")
	expect(p.predicted_landing_height < -2.0, "pipe: landing is well below the lip")
	expect(p.landing_normal.y > 0.0 and p.landing_normal.y < 0.99 and p.landing_normal.x < 0.0, "pipe: landing normal leans back toward the arc centre")
	expect(near(p.landing_incline, math.acos(p.landing_normal.y)) and p.landing_incline > 20.0 * degrees, "pipe: landing incline is the angle of the transition")
end

do -- miss
	local gr = ground(function(p) return p.y <= -1000.0 end, function() return UP end)
	local launch = launch_of(vc(0, 1, 0), vc(2, 5, 0), UP, 4.0)
	local p = Traj.predict(launch, gr.query)
	expect(p.status == "Miss" and not Traj.landed(p), "miss: status is Miss")
	expect(near(p.predicted_air_time, 3.0), "miss: air time is the horizon")
	expect(p.segments_tested == 180, "miss: 3 s at 1/60 s is 180 segments (got " .. p.segments_tested .. ")")
	expect(near(p.apex_time, 5.0 / g, 1e-5) and near(p.predicted_max_height, 25.0 / (2 * g), 1e-4), "miss: apex still predicted")
	expect(near(p.landing_position.y, 1 + 5 * 3.0 - 0.5 * g * 9.0, 1e-3), "miss: end point is the parabola at 3 s")
	expect(near(p.landing_normal.y, 1) and p.landing_incline == 0.0, "miss: no landing normal, level incline")

	local shorter = Traj.settings()
	shorter.max_time = 0.5
	expect(Traj.predict(launch, gr.query, shorter).segments_tested == 30, "miss: custom horizon")

	local none = Traj.predict(launch, function() return nil end)
	expect(none.status == "Miss", "miss: plain function query works")

	local floor = ground(function(q) return q.y <= 0.0 end, function() return UP end)
	local down = Traj.predict(launch_of(vc(0, 0.5, 0), vc(0, -3, 0), UP, 2.0), floor.query)
	expect(Traj.landed(down) and down.apex_time == 0.0 and down.predicted_max_height == 0.0, "downward launch has no climb")
end

do -- invalid input
	local calls = 0
	local counting = function()
		calls += 1
		return nil
	end
	local P = Traj.predict
	expect(P(launch_of(vc(0, 1, 0), vc(nan, 1, 0), UP, 1), counting).status == "Invalid", "NaN velocity is invalid")
	expect(P(launch_of(vc(0, 1, 0), vc(0, math.huge, 0), UP, 1), counting).status == "Invalid", "infinite velocity is invalid")
	expect(P(launch_of(vc(0, nan, 0), vc(0, 1, 0), UP, 1), counting).status == "Invalid", "NaN position is invalid")
	expect(P(launch_of(vc(0, 1, 0), vc(0, 1, 0), vc(nan, 1, 0), 1), counting).status == "Invalid", "NaN launch normal is invalid")
	local bad = Traj.settings()
	bad.gravity = -1.0
	expect(P(launch_of(vc(0, 1, 0), vc(0, 1, 0), UP, 1), counting, bad).status == "Invalid", "invalid settings give Invalid")
	expect(calls == 0, "invalid input never reaches the world query")
	local p = P(launch_of(vc(0, 1, 0), vc(nan, 0, 0), UP, 1), counting)
	expect(p.predicted_air_time == 0.0 and p.segments_tested == 0, "invalid result is zeroed")

	local poisoned = P(launch_of(vc(0, 1, 0), vc(0, 1, 0), UP, 1), function() return vc(nan, 0, 0), UP end)
	expect(poisoned.status == "Miss" and poisoned.predicted_air_time - poisoned.predicted_air_time == 0, "non-finite contact is ignored")
end

do -- incline
	local launch_deg, land_deg = 20.0, 30.0
	local tl = math.tan(land_deg * degrees)
	local gr = ground(function(p) return p.y <= -p.x * tl end,
		function() return vc(math.sin(land_deg * degrees), math.cos(land_deg * degrees), 0) end)
	local ramp_normal = vc(-math.sin(launch_deg * degrees), math.cos(launch_deg * degrees), 0)
	local launch = launch_of(vc(0, 1, 0), vc(3, 2, 0), ramp_normal, 2.0)
	local p = Traj.predict(launch, gr.query)
	local a, b, c = 0.5 * g, -(2.0 + 3.0 * math.tan(land_deg * degrees)), -1.0
	local land_t = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
	expect(Traj.landed(p), "incline: landed")
	expect(near(p.launch_incline, launch_deg * degrees, 1e-4), "incline: launch incline is 20 degrees")
	expect(near(p.landing_incline, land_deg * degrees, 1e-4), "incline: landing incline is 30 degrees")
	expect(near(p.predicted_air_time, land_t, 3e-3), "incline: landing time on a sloped surface")
	expect(near(p.apex_time, 2.0 / g, 1e-5) and near(p.predicted_max_height, 4.0 / (2 * g), 1e-4), "incline: apex")
	expect(p.landing_position.y < launch.position.y - 1.0, "incline: downhill landing is lower than the launch")
	local scaled = Traj.predict(launch_of(vc(0, 1, 0), vc(3, 2, 0), ramp_normal * 5.0, 2.0), gr.query)
	expect(near(scaled.launch_incline, launch_deg * degrees, 1e-4), "incline: launch normal is normalised")
	local zero = Traj.predict(launch_of(vc(0, 1, 0), vc(3, 2, 0), vc(0, 0, 0), 2.0), gr.query)
	expect(near(zero.launch_incline, 0.0), "incline: degenerate launch normal reads as level")

	-- Normal is optional: a query returning only the point lands with a level normal.
	local flat = function(a2, b2)
		if a2.y > 0 and b2.y <= 0 then
			return a2 + (b2 - a2) * (a2.y / (a2.y - b2.y))
		end
		return nil
	end
	local q = Traj.predict(launch_of(vc(0, 1, 0), vc(3, 2, 0), UP, 2.0), flat)
	expect(Traj.landed(q) and near(q.landing_normal.y, 1) and near(q.landing_incline, 0), "optional normal reads as up")
end

T.done()
