-- The glue's snap handling: false pauses on foot, the game's FOV read, board <-> foot flips, retakes after a short release, the
-- snap guard (snapguard.lua) and its counters, all against tests\mock_reskate.lua with the real camera.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_snaps.lua
local T = require("tlib")
local mock = require("mock_reskate")
local Settings = require("settings")

T.group("snaps")
local expect = T.expect
local vc = vector.create
local DEG = math.pi / 180
local camera = require("camera")

local function add_missing_api(m)
	local r = m.reskate
	r.input.gamepad = function() return m.pad end
	r.menu.game = function() return { open = m.menu_open == true, skaters = false, buttons = {} } end
	r.ui.dialog = function(id, d) m.dialog = { id = id, d = d } return true end
	r.ui.close_dialog = function() m.dialog = nil end
	r.files.reveal = function() m.revealed = true return true end
end

local function setup(opts)
	opts = opts or {}
	local m = mock.install({ limit_rays = true })
	add_missing_api(m)
	if opts.game_fov then m.state.game_camera.fov = opts.game_fov end
	local app = require("app").start({ camera = opts.camera or camera })
	m.fire("load")
	if opts.guard == false then app.glue.snap_guard_on = false end
	return m, app
end

local function releases(m, since)
	local n = 0
	for i = (since or 0) + 1, #m.calls do
		if m.calls[i].fn == "release" then n += 1 end
	end
	return n
end

-- ---------------------------------------------------------------- the world: a skater who rides or walks along +Z
-- `st` is the scripted skater: z, y offset of the root (the hips and the board are not at the same height), speed. One call = one tick.
local function new_world(m)
	local w = { z = 0.0, root_dy = 0.0, root_dz = 0.0, speed = 6.0, steps = true, tick = 0 }
	function w.step(state, speed)
		w.speed = speed or w.speed
		w.z += w.speed / 60
		local s = m.state.skater
		s.position = vc(0, 0.95 + w.root_dy, w.z + w.root_dz)
		s.heading = 0
		m.state.telemetry.physics_state = state or m.state.telemetry.physics_state
		local on_foot = m.state.telemetry.physics_state == 504
		m.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
		if on_foot then
			m.state.joints[7] = vc(0, 0.95, w.z)
			m.state.joints[44] = vc(0, 1.4, w.z)
			m.state.joints[103] = vc(0, 1.75, w.z)
		end
		if w.steps then
			m.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = { 0, 0, w.speed } })
		end
		m.tick(1000 / 60)
		w.tick += 1
	end
	function w.run(seconds, state, speed)
		for _ = 1, math.floor(seconds * 60 + 0.5) do w.step(state, speed) end
	end
	return w
end

-- Every camera.set after call number `since`: shown position relative to the root at that moment, forward, fov.
local function shown_steps(m, since, root_of)
	local worst_pos, worst_turn, worst_fov, sets = 0, 0, 0, 0
	local prev
	for i = (since or 0) + 1, #m.calls do
		local c = m.calls[i]
		if c.fn == "set" then
			sets += 1
			local f = vector.normalize(c.forward)
			local rel = c.position - c.root
			if prev then
				worst_pos = math.max(worst_pos, vector.magnitude(rel - prev.rel))
				worst_turn = math.max(worst_turn, math.acos(math.clamp(vector.dot(f, prev.f), -1, 1)) / DEG)
				if c.fov and prev.fov then worst_fov = math.max(worst_fov, math.abs(c.fov - prev.fov)) end
			end
			prev = { rel = rel, f = f, fov = c.fov }
		end
	end
	return worst_pos, worst_turn, worst_fov, sets
end

-- The mock records a camera.set without the root: wrap it so each call carries the root it was made against.
local function record_root(m)
	local set = m.reskate.camera.set
	m.reskate.camera.set = function(p, f, u, fov)
		local ok, why = set(p, f, u, fov)
		local c = m.calls[#m.calls]
		if c and c.fn == "set" then c.root = m.state.skater and m.state.skater.position or vc(0, 0, 0) end
		return ok, why
	end
end

-- ================================================================ 1. a pause is not a still skater on foot
do
	local m, app = setup()
	local g = app.glue
	local w = new_world(m)
	w.run(1.0, 100, 6)
	local mark = #m.calls
	-- On foot, standing: the root does not move at all while the hips' velocity is noisy 0.5-1 m/s (what the game reports).
	w.root_dy, w.steps = 0, true
	for i = 1, 60 * 6 do
		local s = m.state.skater
		m.state.telemetry.physics_state = 504
		m.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
		m.state.joints[7], m.state.joints[44], m.state.joints[103] = vc(0, 0.95, w.z), vc(0, 1.4, w.z), vc(0, 1.75, w.z)
		s.position = vc(0, 0.95, w.z) -- the root stays put
		local v = 0.5 + 0.5 * (0.5 + 0.5 * math.sin(i * 0.37))
		m.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = { 0.3 * math.sin(i * 0.9), 0, v } })
		m.tick(1000 / 60)
	end
	expect(releases(m, mark) == 0 and m.camera_held_by == "me", "standing on foot with a noisy hip velocity: never a pause (" .. releases(m, mark) .. " releases)")
	expect(g.paused == false, "and the glue does not think the game is paused")
	-- Walking with the root still for 0.4 s (a stop-start) is no pause either.
	for i = 1, 24 do
		m.state.telemetry.physics_state = 504
		m.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = { 0, 0, 1.0 } })
		m.tick(1000 / 60)
	end
	expect(releases(m, mark) == 0, "a still root for 0.4 s on foot: no pause")

	-- A real pause: the physics steps stop. On foot ...
	for _ = 1, 30 do m.tick(1000 / 60) end
	expect(m.camera_held_by == nil, "no physics steps for 0.5 s on foot: released (the game is paused)")
	-- ... and the steps coming back take the camera again.
	for _ = 1, 60 do
		m.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = { 0, 0, 1.0 } })
		m.tick(1000 / 60)
	end
	expect(m.camera_held_by == "me", "steps back: the camera is taken again")
end

do
	-- On the board: a frozen root at speed is a pause, even if the steps keep coming; at walking pace it is not.
	local m, app = setup()
	local w = new_world(m)
	w.run(1.0, 100, 6)
	expect(m.camera_held_by == "me", "riding: taken")
	local mark = #m.calls
	for i = 1, 40 do
		m.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = { 0, 0, 6 } })
		m.tick(1000 / 60) -- the root stays where it was
	end
	expect(m.camera_held_by == nil, "on the board, a root that stands still at 6 m/s: paused")
	local m2, app2 = setup()
	local w2 = new_world(m2)
	w2.run(1.0, 100, 6)
	for i = 1, 40 do
		m2.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = { 0, 0, 1.5 } })
		m2.tick(1000 / 60)
	end
	expect(m2.camera_held_by == "me", "on the board at 1.5 m/s with a still root (standing on it): not a pause")
	for _ = 1, 40 do m2.tick(1000 / 60) end
	expect(m2.camera_held_by == nil, "but no physics steps for 0.5 s on the board: paused")
end

-- ================================================================ 2. the game's FOV read
do
	local m, app = setup({ game_fov = 28.2 })
	local g = app.glue
	local w = new_world(m)
	w.run(1.0, 100, 6)
	expect(m.camera_held_by == "me", "taken with the game's camera at 28.2 degrees")
	expect(g.base_fov == 65, "a 28.2 degree read is not the base fov: the default 65 is (" .. tostring(g.base_fov) .. ")")
	for i = 1, #m.calls do
		local c = m.calls[i]
		if c.fn == "set" and c.fov then expect(c.fov > 55 and c.fov < 80, "no shown fov far from 65 (" .. string.format("%.1f", c.fov) .. ")") break end
	end
	-- A plausible read is taken, an implausible one afterwards keeps it.
	local m2, app2 = setup({ game_fov = 90 })
	m2.state.skater.position = vc(0, 0.95, 0)
	local w2 = new_world(m2)
	m2.tick(16)
	expect(app2.glue.base_fov == 90, "a 90 degree read is the base fov")
	m2.state.game_camera.fov = 28.2
	m2.tick(16)
	expect(app2.glue.base_fov == 90, "a later 28.2 keeps the last good one")
	m2.state.game_camera.fov = 140
	m2.tick(16)
	expect(app2.glue.base_fov == 90, "and so does 140")
end

-- ================================================================ 3. flips between the board and foot, with the root jumping
-- The sequence of the player's log (02:12:40 to 02:12:44): ride, off after 0.7 s, on after 0.8, off after 0.95, on after 0.82, ride.
-- At every change the root jumps 0.5 m (it is the board's, then the hips', and they are not in the same place).
local function flips(guard_on)
	local m, app = setup({ guard = guard_on })
	record_root(m)
	local g = app.glue
	local w = new_world(m)
	w.run(2.0, 100, 6)
	local mark = #m.calls
	local plan = { { 504, 0.7, 1.5 }, { 100, 0.8, 6 }, { 504, 0.95, 1.5 }, { 100, 0.82, 6 }, { 504, 0.6, 1.5 }, { 100, 1.5, 6 } }
	local sign = 1
	for _, leg in plan do
		w.root_dy = w.root_dy + 0.0
		w.root_dz = 0.5 * sign -- the jump
		sign = -sign
		w.run(leg[2], leg[1], leg[3])
	end
	local wp, wt, wf, sets = shown_steps(m, mark)
	return wp, wt, wf, sets, m, app
end

do
	local wp, wt, wf, sets, m, app = flips(false)
	print(string.format("flips, guard OFF: worst step %.3f m, %.2f deg, fov %.2f deg over %d views; %d releases", wp, wt, wf, sets, releases(m, 0)))
	expect(app.errors == 0, "flips, guard off: no errors")
	local wp2, wt2, wf2, sets2, m2, app2 = flips(true)
	print(string.format("flips, guard ON : worst step %.3f m, %.2f deg, fov %.2f deg over %d views; %d smoothed", wp2, wt2, wf2, sets2, app2.glue.snaps_total or -1))
	expect(wp2 <= 0.25, "flips: no shown step over 0.25 m relative to the skater (" .. string.format("%.3f", wp2) .. ")")
	expect(wt2 <= 8.0, "flips: no turn over 8 degrees in a tick (" .. string.format("%.2f", wt2) .. ")")
	expect(wf2 <= 2.0, "flips: no fov step over 2 degrees (" .. string.format("%.2f", wf2) .. ")")
	expect(releases(m2, 0) == 0 and m2.camera_held_by == "me", "flips: never released")
	expect(sets2 >= 5.37 * 60 - 6, "flips: a view every tick (" .. sets2 .. ")")
	-- And the paths alone, with no root jump, are smooth without the guard.
	local m3, app3 = setup({ guard = false })
	record_root(m3)
	local w3 = new_world(m3)
	w3.run(2.0, 100, 6)
	local mark = #m3.calls
	for _, leg in { { 504, 0.7, 1.5 }, { 100, 0.8, 6 }, { 504, 0.95, 1.5 }, { 100, 0.82, 6 }, { 504, 0.6, 1.5 }, { 100, 1.5, 6 } } do w3.run(leg[2], leg[1], leg[3]) end
	local a, b, c = shown_steps(m3, mark)
	print(string.format("flips, no root jump, guard OFF: worst step %.3f m, %.2f deg, fov %.2f deg", a, b, c))
	expect(a <= 0.25 and b <= 8.0 and c <= 2.0, "flips without a root jump: the paths are smooth on their own (" .. string.format("%.3f m %.2f deg %.2f fov", a, b, c) .. ")")
end

-- ================================================================ 4. a retake after a short release
do
	-- The menu opens (released), the game's camera is somewhere odd at 28 degrees, the menu closes 1 s later.
	local m, app = setup()
	record_root(m)
	local w = new_world(m)
	w.run(2.0, 100, 6)
	local before
	for i = #m.calls, 1, -1 do if m.calls[i].fn == "set" then before = m.calls[i] break end end
	m.menu_open = true
	m.run(0.2, 60) -- the game stands still behind a menu: no physics steps, the skater does not move
	expect(m.camera_held_by == nil, "menu: released")
	m.state.game_camera = { position = vc(30, 12, 40), forward = vc(0, 0, 1), right = vc(-1, 0, 0), up = vc(0, 1, 0), fov = 28.2, free = false }
	m.run(0.8, 60)
	m.menu_open = false
	local mark = #m.calls
	w.run(0.6, 100, 6)
	local first
	for i = mark + 1, #m.calls do if m.calls[i].fn == "set" then first = m.calls[i] break end end
	expect(first ~= nil, "taken again after the menu")
	local root_then = first.root
	local d = vector.magnitude(first.position - before.position)
	expect(d < 1.0, "retake after 1 s with a silly game camera: starts near the last shown pose, not at the game's (" .. string.format("%.2f", d) .. " m)")
	expect(first.fov == nil or math.abs(first.fov - (before.fov or first.fov)) < 3.0, "and its fov is the shown one, not 28")
	local wp, wt, wf = shown_steps(m, mark)
	expect(wp <= 0.25 and wt <= 8.0 and wf <= 2.0, "and the whole retake is smooth (" .. string.format("%.3f m %.2f deg %.2f fov", wp, wt, wf) .. ")")

	-- A sensible game camera at a retake after a short release is still where the blend starts (as before).
	local m2, app2 = setup()
	record_root(m2)
	local w2 = new_world(m2)
	w2.run(2.0, 100, 6)
	m2.menu_open = true
	m2.run(0.5, 60)
	m2.state.game_camera = { position = vc(0, 2.5, w2.z - 4), forward = vc(0, -0.1, 1), right = vc(-1, 0, 0), up = vc(0, 1, 0), fov = 70, free = false }
	m2.menu_open = false
	local mark2 = #m2.calls
	w2.run(0.2, 100, 6)
	local f2
	for i = mark2 + 1, #m2.calls do if m2.calls[i].fn == "set" then f2 = m2.calls[i] break end end
	expect(f2 ~= nil and vector.magnitude(f2.position - m2.state.game_camera.position) < 1.5, "a sensible game camera: the retake starts from it")
	expect(app2.glue.base_fov == 70, "and its fov is the base")
end

-- ================================================================ 5. the guard's plumbing: counts, log lines, the summary
-- A camera that makes three jumps on demand.
local Jumpy = {}
Jumpy.__index = Jumpy
function Jumpy.new() return setmetatable({ n = 0, mode = nil, cuts = 0 }, Jumpy) end
function Jumpy:set_settings(s) self.settings = s return Settings.valid(s) end
function Jumpy:cut() self.cuts += 1 end
function Jumpy:update(dt, snap, query, extras)
	self.n += 1
	local back = -snap.forward
	local pos = snap.position - snap.forward * 3 + vc(0, 1, 0)
	local fov = 65
	local yaw = 0
	if self.mode == "position" then pos += vc(3, 0, 0) end
	if self.mode == "turn" then yaw = 50 * DEG end
	if self.mode == "fov" then fov = 30 end
	local fwd = vc(math.sin(yaw), -0.2, math.cos(yaw))
	back = -vector.normalize(fwd)
	return { valid = true, pos = pos, right = vector.cross(vc(0, 1, 0), back), up = vc(0, 1, 0), back = back, fov_deg = fov,
		debug = { shot_name = "chase", steps = 1, speed = 6, collision_pull = 0 } }
end
do
	local jumpy = { new = Jumpy.new }
	local m, app = setup({ camera = jumpy })
	record_root(m)
	m.command("dyncam_log 1")
	local g = app.glue
	local w = new_world(m)
	w.run(1.5, 100, 6)
	local cam = g.cam
	local mark = #m.calls - 2
	cam.mode = "position"
	w.run(1.0, 100, 6)
	cam.mode = nil
	w.run(1.0, 100, 6)
	cam.mode = "turn"
	w.run(1.0, 100, 6)
	cam.mode = nil
	w.run(1.0, 100, 6)
	cam.mode = "fov"
	w.run(1.0, 100, 6)
	local wp, wt, wf = shown_steps(m, mark)
	expect(wp <= 0.25 and wt <= 8.0 and wf <= 2.0, "jumps from the camera are shown smoothed (" .. string.format("%.3f m %.2f deg %.2f fov", wp, wt, wf) .. ")")
	local c = g.snaps
	expect(c.position >= 1 and c.turn >= 1 and c.fov >= 1, "counted by cause: position " .. c.position .. " turn " .. c.turn .. " fov " .. c.fov)
	expect(g.snaps_total == c.position + c.turn + c.fov and g.snaps_total >= 5, "and in total (" .. g.snaps_total .. ")")
	expect(g.snaps_by_path.riding and g.snaps_by_path.riding >= 5, "and by path: riding " .. tostring(g.snaps_by_path.riding))
	local lines = table.concat(app.diag.log, "\n")
	expect(string.find(lines, "snap smoothed: position", 1, true) ~= nil, "a log line for a position snap")
	expect(string.find(lines, "snap smoothed: turn", 1, true) ~= nil and string.find(lines, "snap smoothed: fov", 1, true) ~= nil, "and for a turn and a fov snap")
	expect(string.find(lines, " in riding", 1, true) ~= nil, "naming the path")
	m.menu_open = true
	w.run(0.1, 100, 6)
	local off_line
	for _, l in m.logs do if string.find(l[2], "dyncam: off (", 1, true) then off_line = l[2] end end
	expect(off_line ~= nil and string.find(off_line, string.format(", %d snaps smoothed", g.snaps_total), 1, true) ~= nil, "the off line says how many snaps were smoothed: " .. tostring(off_line))
end

-- the guard can be left out: the same jumps then reach the screen (this is what the guard is for)
do
	local jumpy = { new = Jumpy.new }
	local m, app = setup({ camera = jumpy, guard = false })
	record_root(m)
	local w = new_world(m)
	w.run(1.5, 100, 6)
	local mark = #m.calls - 2
	app.glue.cam.mode = "position"
	w.run(0.5, 100, 6)
	local wp = shown_steps(m, mark)
	expect(wp > 2.0, "without the guard the 3 m jump is shown whole (" .. string.format("%.2f", wp) .. ")")
	expect((app.glue.snaps_total or 0) == 0, "and nothing is counted")
end

-- ================================================================ 6. the real camera over a hop: the guard stays out of the way
do
	local m, app = setup()
	record_root(m)
	local g = app.glue
	local w = new_world(m)
	w.run(2.0, 100, 7)
	for k = 1, 3 do
		-- an ollie: pop, air for 0.5 s, landing
		local t0 = w.z
		for i = 1, 30 do
			local t = i / 60
			w.step(i <= 3 and 200 or 201, 7)
			m.state.skater.position = vc(0, 0.95 + math.max(0, 1.2 * (1 - ((t - 0.25) / 0.25) ^ 2)), w.z)
		end
		w.run(1.5, 100, 7)
	end
	expect(app.errors == 0, "hops: no errors")
	expect((g.snaps_total or 0) == 0, "three ollies with the real camera: the guard never had to step in (" .. tostring(g.snaps_total) .. ")")
end

-- ================================================================ 7. manuals from the trick list with the real camera
local function hop_then(state_after, seconds_after)
	local m, app = setup()
	local g = app.glue
	local w = new_world(m)
	w.run(2.0, 100, 7)
	for i = 1, 30 do
		local t = i / 60
		w.step(i <= 3 and 200 or 201, 7)
		m.state.skater.position = vc(0, 0.95 + math.max(0, 1.2 * (1 - ((t - 0.25) / 0.25) ^ 2)), w.z)
	end
	return m, app, g, w
end
do
	-- state 101 (a revert, a powerslide) is not a manual; a Manual named while rolling is, until its landing note
	local m, app, g, w = hop_then()
	w.run(1.0, 100, 7)
	expect(g.snap.manual == false and g.shot ~= "close_manual", "rolling: no manual")
	w.run(1.0, 101, 7)
	expect(g.snap.manual == false and g.manuals == 0, "state 101 for 1 s: no manual")
	w.run(0.2, 100, 7)
	for _ = 1, 5 do m.trick_notes({ { entry = "4295033426", kind = "n", text = "Behemoth" } }) end -- the song ticker is already running
	m.trick_notes({ { entry = "12885001598", kind = "n", text = "Manual" } })
	w.run(0.02, 100, 7)
	expect(g.snap.manual == true and g.manuals == 1, "a Manual named: the manual is on at once")
	w.run(0.5, 100, 7)
	expect(string.find(g.shot, "manual", 1, true) ~= nil, "and the camera is in a manual shot (" .. g.shot .. ")")
	-- the music ticker (already known) and a landing note for another entry change nothing
	m.trick_notes({ { entry = "4295033426", kind = "n", text = "Behemoth" } })
	w.run(0.1, 100, 7)
	m.trick_notes({ { entry = "4295033426", kind = "n", text = "Behemoth" }, { entry = "99732", kind = "l", text = "x" } })
	w.run(0.3, 100, 7)
	m.trick_notes({ { entry = "4295033426", kind = "n", text = "Behemoth" }, { entry = "4295033426", kind = "n", text = "Behemoth" } })
	w.run(0.3, 100, 7)
	expect(g.snap.manual == true and g.manuals == 1, "still on")
	m.trick_notes({ { entry = "12885001598", kind = "l", text = "x" } })
	w.run(0.02, 100, 7)
	expect(g.snap.manual == false, "its landing note: the manual is over")
	expect(app.errors == 0, "no errors")
end
do
	-- landing straight into a manual (Manual named in the air) against landing onto the ground: the shake is the same, the close-up wins after the landing shot
	local results = {}
	for _, manual in { false, true } do
		local m, app, g, w = hop_then()
		if manual then m.trick_notes({ { entry = "8590034324", kind = "n", text = "Manual" } }) end
		w.run(0.1, 100, 7)
		results[manual] = { fall = g.landing_fall, fraction = g.landing_fraction, manual_early = g.snap.manual }
		w.run(0.7, 100, 7)
		results[manual].shot = g.shot
		results[manual].manual = g.snap.manual
	end
	results[101], results[100] = results[true], results[false]
	expect(results[101].manual_early == true and results[101].manual == true, "a Manual named in the air: on 0.1 s after the landing")
	expect(results[100].manual == false, "landing with no Manual named: no manual")
	expect(string.find(results[101].shot, "manual", 1, true) ~= nil, "the close-up is on 0.8 s after the landing (" .. tostring(results[101].shot) .. ")")
	expect(results[100].fall ~= nil and math.abs((results[101].fall or -1) - results[100].fall) < 1e-6
		and math.abs((results[101].fraction or -1) - (results[100].fraction or -2)) < 1e-6, "the landing shake is the same either way")
end

T.done()
if T.failures > 0 then error("snaps tests failed") end
