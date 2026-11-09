-- Contracts of the 1.2.32 orbit hold limit. A measured eye may be held off a wall at a small angle; when the heading
-- turns far away from the eye, as on a halfpipe return, the held angle stops at Orbit.HOLD_MAX and the eye follows the
-- camera's turn. Input matches the 1.2.31 log: 2.40 m arm, heading turning 9 degrees per frame, orbit constrained.
local T = require("tlib")
local Orbit = require("adaptive_orbit")
local v = vector.create
local rad, deg = math.rad, math.deg
T.group("orbit reversal 1232")

local LIMIT = rad(40)
local REACH, HEIGHT = 2.4, 2.0
local anchor = v(0, 1.0, 0)
local right, owner = v(-1, 0, 0), { rays = 0 }
local function cast(self, query, a, b) self.rays += 1; return query(a, b) end
-- Rays from the rider's position are blocked, so the wanted pose is not clear; moves of the eye itself are free.
local function blocked_at_rider(a, b)
	if vector.magnitude(v(a.x - anchor.x, 0, a.z - anchor.z)) < 0.6 then return a end
	return nil
end
local function empty() return nil end
local function eye_at(base, yaw)
	local h = base - yaw
	return v(anchor.x - math.sin(h) * REACH, HEIGHT, anchor.z + math.cos(h) * REACH)
end
local function step(st, query, base, requested, prior)
	return Orbit.solve(st, owner, query, cast, anchor, anchor, base, HEIGHT, REACH,
		requested, 0, 0.25, v(0, 0, 0), 1 / 60, false, 7, right, prior)
end
local function constrained_state(yaw)
	local st = {}
	Orbit.reset(st)
	st.yaw, st.constrained = yaw, true
	return st
end

-- 1: heading turning away from a held eye, the case in the log.
do
	local st, base, peak = constrained_state(rad(25)), 0, 0
	local eye = eye_at(0, rad(25))
	for _ = 1, 40 do
		base += rad(9)
		local y = step(st, blocked_at_rider, base, rad(20), eye)
		eye = eye_at(base, y)
		peak = math.max(peak, math.abs(y))
	end
	T.expect(peak <= LIMIT + rad(1), string.format("1: a held eye stops at the limit on a turn of 9 deg/frame (%.1f deg)", deg(peak)))
	T.expect(peak >= rad(20), string.format("1: the hold still applies up to the limit (%.1f deg)", deg(peak)))
end

-- 2: heading already reversed, the measured angle wraps at 180 degrees: no flip between sides.
do
	for _, offset in ipairs({ 150, 179, 181, 210 }) do
		local st = constrained_state(rad(25))
		local y = step(st, blocked_at_rider, 0, rad(20), eye_at(0, rad(offset)))
		T.expect(math.abs(y) <= LIMIT + rad(1), string.format("2: an eye %d degrees round is limited (%.1f deg)", offset, deg(y)))
	end
end

-- 3: ordinary wall holds are unchanged below the limit.
do
	for _, offset in ipairs({ 15, 30, 38 }) do
		local st = constrained_state(rad(offset))
		local y = step(st, blocked_at_rider, 0, rad(10), eye_at(0, rad(offset)))
		T.expect(math.abs(deg(y) - offset) < 2, string.format("3: an eye held at %d degrees stays there (%.1f deg)", offset, deg(y)))
	end
end

-- 4: a requested orbit wider than the limit keeps its own range.
do
	local st = constrained_state(rad(55))
	local y = step(st, blocked_at_rider, 0, rad(60), eye_at(0, rad(55)))
	T.expect(math.abs(deg(y) - 55) < 2, string.format("4: a requested 60 degree orbit may hold 55 degrees (%.1f deg)", deg(y)))
end

-- 5: unconstrained requests never read the eye.
do
	local st = {}
	Orbit.reset(st)
	local y = step(st, empty, 0, rad(25), eye_at(0, rad(150)))
	T.expect(not st.constrained, "5: a clear request stays unconstrained")
	T.expect(math.abs(deg(y) - 25) < 1, string.format("5: a clear request is untouched by the old eye (%.1f deg)", deg(y)))
end

T.done()
if T.failures > 0 then error("orbit reversal regression") end
