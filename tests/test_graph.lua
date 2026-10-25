-- Port of Engine/Game/Camera/Test/s3cam_graph_tests.cpp
local T = require("tlib")
local S = require("s3math")
local Shots = require("shots")
local G = require("graph")
T.group("graph")
local expect = T.expect
local ShotId = G.ShotId
local dt = S.fixed_step
local nan = 0 / 0

local function ride(speed)
	local i = G.new_input()
	i.dt = dt
	i.speed = speed or 6.0
	return i
end

-- The graph without the 1.0.3 damping (the incline dwell, the shortest air): the single-step logic of each rule.
local function instant()
	local s = G.settings()
	s.incline_dwell = 0.0
	s.air_min_time = 0.0
	s.incline_hysteresis_degrees = 3.0
	return s
end

-- Runs the same input for `steps` steps and returns the last output (g.out: read before the next select).
local function run(g, input, set, steps)
	local out
	for _ = 1, steps or 1 do
		out = G.select(g, input, set)
	end
	return out
end

local function shot_of(g, input, set)
	return G.select(g, input, set).shot
end

do -- priority order
	local set = instant()
	for mask = 0, 31 do
		local g = G.new()
		local i = ride()
		i.bailing = mask % 2 >= 1
		i.touchdown = mask % 4 >= 2
		i.air = mask % 8 >= 4
		i.grinding = mask % 16 >= 8
		i.manual = mask % 32 >= 16
		local out = G.select(g, i, set)
		local want = ShotId.Chase
		if i.manual then want = ShotId.ManualFar end
		if i.grinding then want = ShotId.GrindFlat end
		if i.air then want = ShotId.AirNormal end
		if i.touchdown then want = ShotId.Landing end
		if i.bailing then want = ShotId.Wipeout end
		expect(out.shot == want, "priority: Wipeout > Landing > Air > Grind > Manual > Chase for every flag mask (" .. mask .. ")")
	end
end

do -- every shot reachable
	local set = instant()
	local seen, n = {}, 0
	local function note(g, i)
		local id = G.select(g, i, set).shot
		if not seen[id] then
			seen[id] = true
			n += 1
		end
	end
	local g = G.new()
	local i = ride()
	note(g, i) -- Chase
	i.incline_degrees = 15.0; note(g, i) -- ChaseUp
	i.incline_degrees = -15.0; note(g, i) -- ChaseDown
	i.incline_degrees = 0.0
	i.manual = true; i.speed = 8.0; note(g, i) -- ManualFar
	i.speed = 1.0; note(g, i) -- ManualClose
	i.manual = false; i.speed = 6.0
	i.grinding = true
	i.grind_side = -1; note(g, i) -- GrindLedgeL
	i.grind_side = 1; note(g, i) -- GrindLedgeR
	i.grind_side = 0; note(g, i) -- GrindFlat
	i.grinding = false
	i.air = true
	i.predicted_max_height = 0.5; note(g, i) -- AirNormal
	i.predicted_max_height = 3.0; note(g, i) -- AirBig
	i.air = false
	i.touchdown = true; note(g, i) -- Landing
	i.touchdown = false
	i.bailing = true; note(g, i) -- Wipeout
	expect(n == G.shot_id_count, "all 12 shots are reachable")
	for id = 0, G.shot_id_count - 1 do
		expect(seen[id], "each ShotId was selected: " .. id)
	end
end

do -- cached shot lookup
	for _, angle in { Shots.Low, Shots.High } do
		for id = 0, G.shot_id_count - 1 do
			local resolved = G.lookup_shots(id, angle)
			expect(resolved.a ~= nil and resolved.b ~= nil, "every shot id resolves to table shots in both angles")
			for _, blend in { 0.0, 0.37, 1.0 } do
				local cached = G.blend_shots(resolved, blend)
				local direct = G.resolve_shot(id, angle, blend)
				expect(cached.distance == direct.distance and cached.position_elevation == direct.position_elevation
					and cached.smoothing[3] == direct.smoothing[3] and cached.framing[3] == direct.framing[3],
					"cached lookup + blend equals resolve_shot")
				local into = G.blend_shots(resolved, blend, Shots.new())
				expect(into.distance == direct.distance and into.framing[3] == direct.framing[3], "blend_shots into a table equals")
			end
		end
	end
end

do -- landing window
	local set = instant() -- window 0.25 s
	local g = G.new()
	local i = ride()
	run(g, i, set, 10)
	expect(g.shot == ShotId.Chase, "landing: chase before the touchdown")
	i.touchdown = true
	local out = G.select(g, i, set)
	expect(out.shot == ShotId.Landing and out.landing_active, "landing: starts on the touchdown step")
	i.touchdown = false
	local active = 1
	for _ = 1, 200 do
		out = G.select(g, i, set)
		if out.shot == ShotId.Landing then
			active += 1
		else
			break
		end
	end
	local seconds = active * dt
	expect(math.abs(seconds - 0.25) <= dt * 1.01, "landing: the window is 0.25 s, to within one step")
	expect(active == 15, "landing: at 60 Hz the 0.25 s window is exactly 15 steps (got " .. active .. ")")
	expect(out.shot == ShotId.Chase and not out.landing_active, "landing: back to chase after the window")

	local g2 = G.new()
	i.touchdown = true
	G.select(g2, i, set)
	i.touchdown = false
	i.air = true
	expect(shot_of(g2, i, set) == ShotId.Landing, "landing: outranks air inside the window")
	i.bailing = true
	expect(shot_of(g2, i, set) == ShotId.Wipeout, "landing: wipeout outranks it")
	i.bailing = false
	i.air = false
	local g3 = G.new()
	i.touchdown = true
	G.select(g3, i, set)
	i.touchdown = false
	run(g3, i, set, 10)
	i.touchdown = true
	G.select(g3, i, set)
	i.touchdown = false
	run(g3, i, set, 10)
	expect(g3.shot == ShotId.Landing, "landing: a new touchdown restarts the window")
	local longer = G.settings()
	longer.landing_window = 0.5
	local g4 = G.new()
	i.touchdown = true
	G.select(g4, i, longer)
	i.touchdown = false
	run(g4, i, longer, 20)
	expect(g4.shot == ShotId.Landing, "landing: the window follows the setting (still active at 0.33 s of 0.5)")
	run(g4, i, longer, 15)
	expect(g4.shot == ShotId.Chase, "landing: and ends after 0.5 s")
end

do -- air hysteresis
	local set = instant()
	local g = G.new()
	local i = ride()
	i.air = true
	i.predicted_max_height = 1.45
	expect(shot_of(g, i, set) == ShotId.AirNormal, "air: 1.45 m is normal")
	i.predicted_max_height = 1.55
	expect(shot_of(g, i, set) == ShotId.AirBig, "air: 1.55 m is big")
	i.predicted_max_height = 1.35
	expect(shot_of(g, i, set) == ShotId.AirBig, "air: 1.35 m stays big (hysteresis)")
	i.predicted_max_height = 1.1
	expect(shot_of(g, i, set) == ShotId.AirNormal, "air: 1.1 m drops back to normal")
	i.predicted_max_height = 1.35
	expect(shot_of(g, i, set) == ShotId.AirNormal, "air: 1.35 m does not re-enter big")
end

do -- manual hysteresis
	local set = instant()
	local g = G.new()
	local i = ride()
	i.manual = true
	i.speed = 4.0
	expect(shot_of(g, i, set) == ShotId.ManualClose, "manual: slow is the close shot")
	i.speed = 5.5
	expect(shot_of(g, i, set) == ShotId.ManualFar, "manual: fast is the far shot")
	i.speed = 4.5
	expect(shot_of(g, i, set) == ShotId.ManualFar, "manual: 4.5 m/s stays far (hysteresis)")
	i.speed = 4.0
	expect(shot_of(g, i, set) == ShotId.ManualClose, "manual: 4 m/s returns to close")
	i.speed = -6.0
	expect(shot_of(g, i, set) == ShotId.ManualFar, "manual: reverse speed counts by magnitude")
end

do -- manual one shot
	local set = instant()
	local g = G.new()
	local i = ride()
	i.manual = true
	i.manual_one_shot = true
	for _, speed in { 0.0, 2.0, 4.9, 5.5, 8.0, 11.0, -6.0, 3.0 } do
		i.speed = speed
		expect(shot_of(g, i, set) == ShotId.ManualClose, "manual (one shot): the close shot at any speed")
	end
end

do -- incline hysteresis
	local set = instant()
	local g = G.new()
	local i = ride()
	local function at(deg, want, what)
		i.incline_degrees = deg
		expect(shot_of(g, i, set) == want, what)
	end
	at(7.0, ShotId.Chase, "incline: 7 degrees is flat chase")
	at(9.0, ShotId.ChaseUp, "incline: 9 degrees is chase up")
	at(6.0, ShotId.ChaseUp, "incline: 6 degrees stays up (hysteresis)")
	at(4.0, ShotId.Chase, "incline: 4 degrees is flat again")
	at(-9.0, ShotId.ChaseDown, "incline: -9 degrees is chase down")
	at(-6.0, ShotId.ChaseDown, "incline: -6 degrees stays down")
	at(-4.0, ShotId.Chase, "incline: -4 degrees is flat again")
end

do -- dwell and air blip
	local set = G.settings()
	expect(set.incline_dwell >= 0.39 and set.air_min_time >= 0.049 and set.incline_hysteresis_degrees >= 4.0,
		"damping: the defaults are a 0.4 s dwell, 0.05 s of air, a 4 degree band")
	local g = G.new()
	local i = ride()
	run(g, i, set, 30)
	local changes = 0
	local last = g.shot
	for k = 0, 599 do
		i.incline_degrees = (k % 2 == 0) and 9.5 or 3.0
		local now = G.select(g, i, set).shot
		if now ~= last then changes += 1 end
		last = now
	end
	expect(changes <= 26, "damping: a flickering slope changes the shot at most every 0.4 s (changes " .. changes .. ")")
	local h = G.new()
	i = ride()
	run(h, i, set, 60)
	i.incline_degrees = 12.0
	local steps = 0
	while G.select(h, i, set).shot ~= ShotId.ChaseUp and steps < 100 do
		steps += 1
	end
	expect(steps <= 1, "damping: a real slope is followed at once after a quiet spell")
	local a = G.new()
	i = ride()
	run(a, i, set, 10)
	i.air = true
	local first = shot_of(a, i, set) == ShotId.Chase
	local second = shot_of(a, i, set) == ShotId.Chase
	expect(first and second, "damping: two steps of air do not leave the chase shot")
	i.air = false
	expect(shot_of(a, i, set) == ShotId.Chase, "damping: and the blip is over")
	i.air = true
	local reached = ShotId.Chase
	for _ = 1, 5 do
		reached = shot_of(a, i, set)
	end
	expect(reached == ShotId.AirNormal, "damping: a real jump reaches the air shot within 0.05 s")
end

do -- chase blend
	local set = instant()
	local function settled(speed)
		local g = G.new()
		return run(g, ride(speed), set, 2000).chase_blend
	end
	expect(settled(0.0) == 0.0, "chase blend: standing is the slow shot")
	expect(settled(3.0) < 0.001, "chase blend: 3 m/s is the slow shot")
	expect(settled(9.0) > 0.999, "chase blend: 9 m/s is the fast shot")
	expect(settled(20.0) > 0.999, "chase blend: faster still stays the fast shot")
	local mid = settled(6.0)
	expect(math.abs(mid - 0.5) < 0.01, "chase blend: the midpoint speed gives 0.5 (the sine ease is symmetric)")
	expect(settled(4.5) < mid and mid < settled(7.5), "chase blend: monotonic in speed")

	local g = G.new()
	run(g, ride(3.0), set, 50)
	local first = G.select(g, ride(9.0), set).chase_blend
	expect(first < 0.1, "chase blend: a speed jump is filtered, not instant")
	local later = run(g, ride(9.0), set, 600)
	expect(later.chase_blend > 0.99, "chase blend: and settles on the fast shot")
end

do -- grind side
	local set = instant()
	local g = G.new()
	local i = ride()
	i.grinding = true
	i.grind_side = -1
	expect(shot_of(g, i, set) == ShotId.GrindLedgeL, "grind: side -1 is the left ledge shot")
	i.grind_side = 1
	expect(shot_of(g, i, set) == ShotId.GrindLedgeR, "grind: side +1 is the right ledge shot")
	i.grind_side = 0
	expect(shot_of(g, i, set) == ShotId.GrindFlat, "grind: side 0 is the flat grind shot")
end

do -- shot lookup low / high
	for id = 0, G.shot_id_count - 1 do
		for _, angle in { Shots.Low, Shots.High } do
			local a, b = G.shot_pair(id, angle)
			expect(Shots.find_shot(a) ~= nil and Shots.find_shot(b) ~= nil, "lookup: every id resolves to table shots")
			expect(Shots.valid(G.resolve_shot(id, angle, 0.5)), "lookup: every resolved shot is valid")
		end
	end
	local function distance(id, a) return G.resolve_shot(id, a, 0.0).distance end
	local function elevation(id, a) return G.resolve_shot(id, a, 0.0).position_elevation end
	local Low, High = Shots.Low, Shots.High
	expect(distance(ShotId.Chase, Low) < distance(ShotId.Chase, High), "Low chase is closer than High")
	expect(elevation(ShotId.Chase, Low) < elevation(ShotId.Chase, High), "Low chase is lower than High")
	expect(distance(ShotId.GrindLedgeL, Low) < distance(ShotId.GrindLedgeL, High), "Low grind is closer")
	expect(distance(ShotId.ManualFar, Low) ~= distance(ShotId.ManualFar, High), "manual differs")
	expect(distance(ShotId.AirNormal, Low) < distance(ShotId.AirNormal, High), "Low air is closer")
	expect(distance(ShotId.Wipeout, Low) == distance(ShotId.Wipeout, High), "wipeout is shared")
	expect(math.abs(G.resolve_shot(ShotId.Chase, Low, 0.0).distance - 1.8) < 1e-5, "Low chase slow is 1.8 m")
	expect(math.abs(G.resolve_shot(ShotId.Chase, Low, 1.0).distance - 2.5) < 1e-5, "Low chase fast is 2.5 m")
	expect(math.abs(G.resolve_shot(ShotId.Chase, High, 0.0).distance - 3.0) < 1e-5, "High chase slow is 3.0 m")
	expect(math.abs(G.resolve_shot(ShotId.Chase, High, 1.0).distance - 4.4) < 1e-5, "High chase fast is 4.4 m")
	expect(distance(ShotId.ChaseUp, Low) ~= distance(ShotId.Chase, Low), "Low chase up has its own shot")
	expect(distance(ShotId.ChaseUp, High) == distance(ShotId.Chase, High), "High has no chase up variant")
	local names, n = {}, 0
	for id = 0, G.shot_id_count - 1 do
		local name = G.shot_id_name(id)
		if not names[name] then
			names[name] = true
			n += 1
		end
	end
	expect(n == G.shot_id_count, "shot ids have distinct names")
end

do -- settings and guards
	local s = G.settings()
	expect(G.valid(s), "default graph settings are valid")
	local bad = G.settings()
	bad.chase_fast_speed = bad.chase_slow_speed
	expect(not G.valid(bad), "chase points must ascend")
	bad = G.settings()
	bad.landing_window = -1.0
	expect(not G.valid(bad), "negative landing window is rejected")
	bad = G.settings()
	bad.transition_time[4] = nan
	expect(not G.valid(bad), "NaN transition time is rejected")
	bad = G.settings()
	bad.incline_hysteresis_degrees = 20.0
	expect(not G.valid(bad), "incline hysteresis must be smaller than the threshold")
	expect(G.transition_time(s, ShotId.Wipeout) == 0.30 and G.transition_time(s, ShotId.ChaseDown) == 0.60, "transition_time by ShotId")

	local g = G.new()
	local i = ride()
	i.manual = true
	G.select(g, i, s)
	local kept = G.select(g, i, bad)
	expect(kept.shot == g.shot and g.shot == ShotId.ManualFar, "invalid settings keep the previous selection")
	i.dt = 0.0
	i.bailing = true
	expect(shot_of(g, i, s) == ShotId.ManualFar, "zero dt keeps the previous selection")
	i.dt = dt
	i.speed = nan
	i.manual = false
	i.bailing = false
	expect(shot_of(g, i, s) == ShotId.Chase, "NaN speed is treated as standing")
	local out = G.select(g, i, s)
	expect(out.chase_blend - out.chase_blend == 0, "NaN speed gives a finite blend")
end

T.done()
