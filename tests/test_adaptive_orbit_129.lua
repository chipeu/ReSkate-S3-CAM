local T = require("tlib")
local Orbit = require("adaptive_orbit")
local v = vector.create
T.group("adaptive orbit 129")

-- Segment against an actual solid AABB; the oracle is the first geometric contact.
local function box(a, b, low, high)
	local enter, leave = 0, 1
	for _, axis in ipairs({"x", "y", "z"}) do
		local d = b[axis] - a[axis]
		if math.abs(d) < 1e-9 then
			if a[axis] < low[axis] or a[axis] > high[axis] then return nil end
		else
			local p, q = (low[axis] - a[axis]) / d, (high[axis] - a[axis]) / d
			if p > q then p, q = q, p end
			enter, leave = math.max(enter, p), math.min(leave, q)
			if enter > leave then return nil end
		end
	end
	return a + (b - a) * enter
end

local owner = { step_rays = 0 }
local function cast(self, query, a, b)
	self.step_rays += 1
	return query(a, b)
end
local empty = function() return nil end
local right_wall = function(a, b) return box(a, b, v(0.45, 0.5, 0.5), v(0.65, 2.5, 4)) end
local left_wall = function(a, b) return box(a, b, v(-0.65, 0.5, 0.5), v(-0.45, 2.5, 4)) end
local both = function(a, b) return right_wall(a, b) or left_wall(a, b) end
local transit_wall = function(a, b)
	return right_wall(a, b) or box(a, b, v(-0.85, 0.5, 2.75), v(-0.65, 2.5, 3.05))
end
local short_wall = function(a, b)
	return box(a, b, v(0.45, 0.5, 2.5), v(0.65, 2.5, 4))
end
local near_margin = function(a, b)
	return box(a, b, v(0.77, 0.5, 2.75), v(0.82, 2.5, 3.2))
end
local st = {}
local pivot, anchor = v(0, 1.5, 0), v(0, 1.5, 0)
local function run(query, yaw, shoulder, available, n, height)
	local out_y, out_s
	for _ = 1, n do
		owner.step_rays = 0
		out_y, out_s = Orbit.solve(st, owner, query, cast, pivot, anchor, 0, height or 1.5,
			3, yaw, shoulder, 0.25, v(0, 0, 0), 1/60, false, available, v(-1, 0, 0))
		T.expect(owner.step_rays <= available, "stays inside supplied ray allowance")
	end
	return out_y, out_s
end

Orbit.reset(st)
local y, s = run(empty, 0.43, 0.2, 7, 90)
T.expect(y > 0.35 and s > 0.15, "unobstructed preference returns after dwell")

Orbit.reset(st)
y, s = run(right_wall, 0.43, 0.2, 7, 90)
T.expect(y < 0.25, "solid wall at eye height limits positive yaw")
T.expect(s < 0.1, "shoulder shares wall clearance with yaw")

Orbit.reset(st)
y = run(right_wall, 0.43, 0, 7, 90)
T.expect(y < -0.2, "clear alternate side is reached through a tested transit")

Orbit.reset(st)
y = run(transit_wall, 0.43, 0, 7, 90)
T.expect(3 * math.sin(y) > -0.4, "alternate transit keeps the eye radius clear of the solid wall")

Orbit.reset(st)
y, s = run(left_wall, 0, 0.5, 7, 90)
T.expect(s < -0.3, "shoulder-only wall selects the clear opposite side after dwell")

Orbit.reset(st)
y, s = run(both, 0.43, 0.2, 7, 90)
T.expect(math.abs(y) < 0.08 and math.abs(s) < 0.08, "walls on both sides keep framing near centre")

Orbit.reset(st)
y, s = run(short_wall, 0.43, 0.2, 7, 90, 4)
T.expect(y > 0.35, "geometry below the actual elevated eye does not falsely limit yaw")

Orbit.reset(st)
y = run(short_wall, 0.43, 0, 7, 90, 1.2)
T.expect(y < 0.1, "same short wall limits a held low eye")

local h = -0.2
local centre = v(-math.sin(h) * 3, 1.5, math.cos(h) * 3)
T.expect(near_margin(pivot, centre) == nil, "margin fixture misses the centre ray")
Orbit.reset(st)
y = run(near_margin, 0.2, 0, 7, 90)
T.expect(y < 0.1, "radius whisker catches a solid the centre ray misses")

Orbit.reset(st)
y, s = run(empty, 0.43, 0.2, 0, 10)
T.expect(y == 0 and s == 0 and owner.step_rays == 0, "exhausted budget is not treated as clear")

T.done()
