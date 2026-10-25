-- snapguard.lua: the last line of defence against a camera jump.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_snapguard.lua
local T = require("tlib")
local SnapGuard = require("snapguard")
T.group("snapguard")
local expect = T.expect
local vc = vector.create
local DEG = math.pi / 180

local function dir(yaw_deg, pitch_deg)
	local y, p = yaw_deg * DEG, (pitch_deg or 0) * DEG
	return vc(math.sin(y) * math.cos(p), math.sin(p), math.cos(y) * math.cos(p))
end
local UP = vc(0, 1, 0)

-- Feeds the guard a pose behind a subject that moves along +Z at `speed`; `pose(t)` -> offset (vector), yaw, pitch, fov.
-- Returns the worst per-tick step of the shown offset (m), turn (deg) and fov (deg), and the guard.
local function drive(seconds, speed, pose, g, t0, z0)
	g = g or SnapGuard.new()
	t0, z0 = t0 or 0, z0 or 0
	local worst_pos, worst_turn, worst_fov = 0, 0, 0
	local prev
	local n = math.floor(seconds * 60 + 0.5)
	local last
	for i = 1, n do
		local t = t0 + i / 60
		local subject = vc(0, 0.95, z0 + speed * (t - t0))
		local off, yaw, pitch, fov, pulled = pose(t - t0)
		local p, f, u, v = g:filter(t, subject + off, dir(yaw, pitch), UP, fov, subject, pulled)
		if prev then
			worst_pos = math.max(worst_pos, vector.magnitude((p - subject) - prev.rel))
			worst_turn = math.max(worst_turn, math.acos(math.clamp(vector.dot(f, prev.f), -1, 1)) / DEG)
			if v and prev.v then worst_fov = math.max(worst_fov, math.abs(v - prev.v)) end
		end
		prev = { rel = p - subject, f = f, v = v }
		last = { p = p, f = f, u = u, v = v, rel = p - subject, subject = subject, t = t }
	end
	return worst_pos, worst_turn, worst_fov, g, last
end

local behind = vc(0, 1.5, -3)

-- 1. Smooth riding, even very fast, never counts.
do
	for _, speed in { 0, 6, 25, 60 } do
		local wp, wt, wf, g = drive(3, speed, function(t) return behind + vc(0.2 * math.sin(t), 0, 0), 20 * math.sin(t), -5, 65 + 3 * math.sin(t) end)
		expect(g.total == 0, "smooth riding at " .. speed .. " m/s: nothing smoothed")
	end
	local _, _, _, g, last = drive(1, 10, function() return behind, 0, -5, 65 end)
	expect(T.vnear(last.p, last.subject + behind, 1e-6) and last.v == 65, "an untouched pose passes through as it is")
end

-- 2. A position jump: counted as position, the shown steps stay small, and it ends on the wanted pose.
do
	local jump = 3.0
	local wp, wt, wf, g, last = drive(1.5, 6, function(t) return t < 0.5 and behind or behind + vc(jump, 0, 0), 0, -5, 65 end)
	expect(g.count.position == 1 and g.total == 1, "a 3 m jump is counted once, as position (" .. g.count.position .. ")")
	expect(wp <= 0.25, "and shown in steps of at most 0.25 m (" .. string.format("%.3f", wp) .. ")")
	expect(T.vnear(last.rel, behind + vc(jump, 0, 0), 1e-4), "it ends on the wanted pose")
	expect(not g.smoothing, "the ease is over after 0.35 s")
end

-- 3. A turn jump, a fov jump.
do
	local wp, wt, wf, g = drive(1.5, 6, function(t) return behind, t < 0.5 and 0 or 60, -5, 65 end)
	expect(g.count.turn == 1 and g.total == 1, "a 60 degree turn is counted as turn")
	expect(wt <= 8.0, "shown in steps of at most 8 degrees (" .. string.format("%.2f", wt) .. ")")
	local _, _, wf2, g2, last = drive(1.5, 6, function(t) return behind, 0, -5, t < 0.5 and 65 or 28 end)
	expect(g2.count.fov == 1 and g2.total == 1, "a 37 degree fov jump is counted as fov")
	expect(wf2 <= 2.0, "shown in steps of at most 2 degrees (" .. string.format("%.2f", wf2) .. ")")
	expect(math.abs(last.v - 28) < 1e-3, "and ends on the wanted fov")
end

-- 4. Just under the limits is not a jump.
do
	local _, _, _, g = drive(1, 0, function(t) return behind + vc(t < 0.5 and 0 or 0.2, 0, 0), t < 0.5 and 0 or 7, -5, t < 0.5 and 65 or 66.9 end)
	expect(g.total == 0, "0.2 m, 7 degrees and 1.9 degrees in one tick pass")
end

-- 5. A second jump during the ease restarts it cleanly from what is on screen.
do
	local wp, wt, wf, g = drive(2, 6, function(t)
		local x = t < 0.5 and 0 or (t < 0.6 and 4 or -4)
		return behind + vc(x, 0, 0), 0, -5, 65
	end)
	expect(g.total == 2 and g.count.position == 2, "two jumps, two counts (" .. g.total .. ")")
	expect(wp <= 0.3, "no step beyond the ease's own speed, also across the restart (" .. string.format("%.3f", wp) .. ")")
end

-- 6. A wall: the camera slides in, the guard lets the pull through and does not hold the camera behind the wall.
do
	local wp, _, _, g, last = drive(1, 0, function(t)
		if t < 0.5 then return behind, 0, -5, 65, false end
		return vc(0, 1.5, -1.0), 0, -5, 65, true -- pulled in by 2 m in one tick
	end)
	expect(g.total == 0, "a collision pull-in is not smoothed")
	expect(T.vnear(last.rel, vc(0, 1.5, -1.0), 1e-4), "the camera is where the wall lets it")
	-- the same jump without a pull is a jump
	local _, _, _, g2 = drive(1, 0, function(t) return t < 0.5 and behind or vc(0, 1.5, -1.0), 0, -5, 65, false end)
	expect(g2.total == 1, "the same move with no wall in it is smoothed")
	-- a pull when the wanted camera is not closer (the arm lengthening) is no exemption
	local _, _, _, g3 = drive(1, 0, function(t) return t < 0.5 and vc(0, 1.5, -1.0) or behind, 0, -5, 65, true end)
	expect(g3.total == 1, "pulled but moving away from the subject: still a jump")
	-- a wall during an ease takes the position at once
	local g4 = SnapGuard.new()
	local _, _, _, _, l1 = drive(0.3, 0, function(t) return behind + vc(t < 0.1 and 0 or 5, 0, 0), 0, -5, 65, false end, g4)
	local _, _, _, _, l2 = drive(0.05, 0, function() return vc(0, 1.5, -1.0), 0, -5, 65, true end, g4, 0.3)
	expect(vector.magnitude(l2.rel - vc(0, 1.5, -1.0)) < 0.3, "pulled during an ease: the position follows the wall")
end

-- 7. The subject teleporting is a cut.
do
	local g = SnapGuard.new()
	g:filter(0, vc(0, 2, -3), dir(0), UP, 65, vc(0, 0.95, 0), false)
	local p = g:filter(0.016, vc(500, 2, 497), dir(180), UP, 40, vc(500, 0.95, 500), false)
	expect(g.total == 0 and T.vnear(p, vc(500, 2, 497)), "a 700 m teleport cuts, nothing smoothed")
	g:cut()
	local p2 = g:filter(0.032, vc(0, 2, 0), dir(90), UP, 90, vc(0, 0.95, 3), false)
	expect(g.total == 0 and T.vnear(p2, vc(0, 2, 0)), "after cut() the next pose passes")
end

-- 8. nil fov (the game's own) is left alone, never smoothed.
do
	local _, _, _, g, last = drive(1, 0, function() return behind, 0, -5, nil end)
	expect(g.total == 0 and last.v == nil, "a nil fov stays nil")
end

-- 9. A quick but steady blend (0.3 m a tick for a second) is motion, not a snap; four times the limit a tick is, steady or not.
do
	local function ramp(t, v) return t < 0.5 and v * t * t or v * (t - 0.25) end -- speeds up over half a second, then steady
	local _, _, _, g = drive(1.5, 0, function(t) return behind + vc(0, 0, ramp(t, 0.3 * 60)), 0, -5, 65 end)
	expect(g.total == 0, "0.3 m a tick, steady after a ramp up: not a snap")
	local _, _, _, g2 = drive(1, 0, function(t) return behind + vc(0, 0, 1.5 * 60 * t), 0, -5, 65 end)
	expect(g2.total >= 1, "1.5 m a tick, steady: smoothed")
	local _, _, _, g3 = drive(1.5, 0, function(t) return behind, ramp(t, 12 * 60), -5, 65 end)
	expect(g3.total == 0, "a steady 12 degree turn a tick: not a snap")
end

T.done()
if T.failures > 0 then error("snapguard tests failed") end
