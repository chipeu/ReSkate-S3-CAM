local T = require("tlib")
local Terrain = require("terrain_context")
local vc = vector.create
T.group("terrain 126")

local function world(height)
	local calls = 0
	local function query(a, b, want_normal)
		calls += 1
		T.expect(want_normal == false, "probe requests point only")
		local y = height(a.x, a.z)
		if not y or a.y < y or b.y > y then return nil end
		return vc(a.x, y, a.z)
	end
	return query, function() return calls end
end
local function input(p, v, state, ground_y, normal)
	return { position = p, velocity = v, state = state, ground_valid = true,
		ground_height = ground_y, ground_normal = normal or vc(0, 1, 0), launch_height = ground_y }
end
local function advance(c, s, query, steps, dt)
	local out
	for _ = 1, steps do out = c:update(s, dt or 1 / 60, query) end
	return out
end

do -- Flat high ollie: the floor, launch datum, and normal stay flat despite vertical velocity.
	local q = world(function() return 0 end)
	local c = Terrain.new()
	local s = input(vc(0, 4, 0), vc(5, 7, 0), 201, 0)
	local out = advance(c, s, q, 45)
	T.expect(out.target == 0 and out.weight == 0 and out.reason == "flat", "high flat ollie stays Off")
	s.velocity = vc(5, -5, 0)
	out = advance(c, s, q, 30)
	T.expect(out.target == 0 and out.weight == 0, "flat ollie descent stays Off")
end

do -- A measured steep support survives the lip for a short airborne handoff.
	local q = world(function(x) return x * 0.8 end)
	local c = Terrain.new()
	local s = input(vc(0, 1, 0), vc(3, 2.4, 0), 100, 0, vc(-0.625, 0.781, 0))
	s.ground_normal = vc(-0.7, 0.714, 0)
	local out = advance(c, s, q, 18)
	T.expect(out.reason == "transition" and out.weight > 0.8, "measured vert engages On context")
	s.state, s.ground_valid, s.ground_normal = 201, false, vc(0, 1, 0)
	out = advance(c, s, nil, 90)
	T.expect(out.reason == "transition" and out.weight == 1, "measured vert persists for 1.5 second air flight")
	s.state, s.ground_valid, s.ground_height = 100, true, 0
	out = advance(c, s, nil, 60)
	T.expect(out.target == 0 and out.weight < 0.2, "vert context retires after the hold")
	local flat = Terrain.new()
	s.state, s.ground_valid, s.transition = 201, false, true
	out = advance(flat, s, nil, 60)
	T.expect(out.target == 0 and out.weight == 0, "transition hint alone cannot trigger flat air")
end

do -- Elevated ledge is detected before the root reaches its edge.
	local q, calls = world(function(x) return x >= 1.5 and 1.25 or 0 end)
	local c = Terrain.new()
	local s = input(vc(0, 1, 0), vc(5, 0, 0), 100, 0)
	local out = advance(c, s, q, 24)
	T.expect(out.reason == "raised_support" and out.target == 1 and out.weight > 0.8,
		"verified upper support acquired before collision")
	T.expect(out.ahead_height == 1.25, "raised surface height reported")
	T.expect(calls() <= 10, "probe budget is two rays per 0.1 second")
end

do -- Landing on an upper flat support retires the old approach before another flat ollie.
	local q = world(function(x) return x >= 1.5 and 1.25 or 0 end)
	local c = Terrain.new()
	local s = input(vc(0, 1, 0), vc(5, 0, 0), 100, 0)
	local out = advance(c, s, q, 18)
	T.expect(out.target == 1 and out.reason == "raised_support", "raised target remains during flat approach")
	s.position, s.ground_height, s.launch_height = vc(2, 2.2, 0), 1.25, 1.25
	out = advance(c, s, q, 5)
	T.expect(out.target == 1, "brief new contact does not clear approach context")
	out = advance(c, s, q, 10)
	T.expect(out.target == 0 and out.reason == "flat" and out.weight > 0,
		"verified upper flat runout clears stale target while weight eases")
	s.state, s.position, s.velocity = 201, vc(2, 3.5, 0), vc(5, 5, 0)
	out = advance(c, s, q, 8)
	T.expect(out.target == 0 and out.reason == "flat", "fresh upper flat ollie stays Off")
end

do -- A real ledge still ahead prevents flat-ground retirement; missing rays cannot confirm a runout.
	local q = world(function(x) return x >= 1.5 and 1.25 or 0 end)
	local c = Terrain.new()
	local s = input(vc(0, 1, 0), vc(5, 0, 0), 100, 0)
	local out = advance(c, s, q, 25)
	T.expect(out.target == 1, "flat approach does not clear a verified ledge ahead")
	out = advance(c, s, nil, 10)
	T.expect(out.target == 1, "missing probe cannot certify a flat runout")
end

do -- Measured vert persists in air but clears after a stable flat contact.
	local c = Terrain.new()
	local s = input(vc(0, 1, 0), vc(5, 2, 0), 100, 0, vc(-0.7, 0.714, 0))
	local q = world(function() return 0 end)
	local out = advance(c, s, q, 6)
	T.expect(out.target == 1 and out.reason == "transition", "steep surface measured before takeoff")
	s.state, s.ground_valid, s.position = 201, false, vc(0, 3, 0)
	out = advance(c, s, q, 60)
	T.expect(out.target == 1 and out.reason == "transition", "vert retained during flight")
	s.state, s.ground_valid, s.position = 100, true, vc(0, 1, 0)
	s.ground_normal, s.velocity = vc(0, 1, 0), vc(5, 0, 0)
	out = advance(c, s, q, 10)
	T.expect(out.target == 0 and out.reason == "flat", "flat contact retires vert target before hold expiry")
	s.state, s.position, s.velocity = 201, vc(0, 4, 0), vc(5, 5, 0)
	out = advance(c, s, q, 8)
	T.expect(out.target == 0, "new flat ollie does not inherit vert target")
end

do -- A one frame board or rail grade spike cannot engage; sustained grade can.
	local q = world(function() return 0 end)
	local c = Terrain.new()
	local s = input(vc(0, 3, 0), vc(5, -1, 0), 403, 0)
	s.launch_height, s.rail_grade = 2, 0.4
	local out = c:update(s, 1 / 60, q)
	T.expect(out.target == 0, "single rail grade sample ignored")
	s.rail_grade = 0
	out = advance(c, s, q, 15)
	T.expect(out.target == 0, "short grade spike decays")
	s.rail_grade = 0.4
	out = advance(c, s, q, 35)
	T.expect(out.reason == "steep_rail" and out.weight > 0.8, "stable steep rail engages")
	s.state, s.grinding, s.rail_grade = 201, false, 0
	out = advance(c, s, q, 9)
	T.expect(out.reason == "steep_rail", "rail exit latches for handoff")
end

do -- A level raised grind must not acquire the raised terrain underneath as approach context.
	local q, calls = world(function() return 1.2 end)
	local c = Terrain.new()
	local s = input(vc(0, 2.2, 0), vc(5, 0, 0), 403, 0)
	s.launch_height, s.rail_grade = 0, 0
	local out = advance(c, s, q, 30)
	T.expect(out.target == 0 and out.reason == "flat", "level raised grind stays Off")
	T.expect(calls() == 0, "grinding does not cast forward probes")
end

do -- A real downstep is visible ahead; a level route is not a drop.
	local q = world(function(x) return x >= 1.5 and -2 or 0 end)
	local c = Terrain.new()
	local s = input(vc(0, 1, 0), vc(5, 0, 0), 100, 0)
	local out = advance(c, s, q, 18)
	T.expect(out.reason == "drop" and out.weight > 0.7, "downstep engages before edge")
	local flat = Terrain.new()
	local flat_q = world(function() return 0 end)
	out = advance(flat, s, flat_q, 18)
	T.expect(out.target == 0, "level route remains flat")
end

do -- Valid predicted lower landing and physical descent are fallback evidence.
	local c = Terrain.new()
	local s = input(vc(0, 2, 0), vc(5, -2, 0), 201, 1)
	s.predicted_landing_position, s.predicted_landing_height = vc(4, -1, 0), -1
	local out = c:update(s, 1 / 60, nil)
	T.expect(out.reason == "drop" and out.rays == 0, "predicted lower landing works without query")
	c:reset()
	s.predicted_landing_position = nil
	s.position, s.velocity = vc(0, 0, 0), vc(3, -3, 0)
	out = c:update(s, 1 / 60, nil)
	T.expect(out.reason == "drop", "physical descent below launch datum works")
end

do -- Fixed-step rates use the same real-time probe cadence and converge to full On.
	for _, fps in { 30, 60, 144 } do
		local q, calls = world(function(x) return x >= 1.2 and 1.1 or 0 end)
		local c = Terrain.new()
		local s = input(vc(0, 1, 0), vc(5, 0, 0), 100, 0)
		local out = advance(c, s, q, fps * 2, 1 / fps)
		T.expect(out.weight == 1 and out.target == 1, "full On at " .. fps .. " Hz")
		T.expect(calls() <= 42, "bounded probe cadence at " .. fps .. " Hz")
	end
	local q = world(function() return 0.2 end)
	local c = Terrain.new()
	local s = input(vc(0, 1, 0), vc(5, 0, 0), 100, 0)
	local out = advance(c, s, q, 60)
	T.expect(out.weight == 0, "normal low ledge preserves Off context")
end

do -- Invalid input, cut, and probe failure have bounded outputs.
	local c = Terrain.new()
	local q = world(function() return 1.2 end)
	local s = input(vc(0, 1, 0), vc(5, 0, 0), 100, 0)
	advance(c, s, q, 25)
	T.expect(c.weight > 0.5, "context set before cut")
	local out = c:update({ cut = true }, 1 / 60, q)
	T.expect(out.weight == 0 and out.target == 0 and out.rays == 0, "cut resets context")
	out = c:update({ position = vc(0, 0 / 0, 0), velocity = vc(1, 0, 0) }, 1 / 60, q)
	T.expect(out.weight == 0 and out.reason == "invalid", "nonfinite input rejected")
	local bad = function() return vc(100, 999, 0) end
	out = advance(c, s, bad, 20)
	T.expect(out.target == 0, "out of segment hits ignored")
end

do -- A stale or discontinuous launch datum never creates a long ray.
	local longest, calls = 0, 0
	local function bounded(a, b)
		calls += 1
		longest = math.max(longest, vector.magnitude(b - a))
		return nil
	end
	local c = Terrain.new()
	local s = input(vc(0, 100, 0), vc(9, -5, 0), 201, 0)
	local out = advance(c, s, bounded, 30)
	T.expect(out.target == 0 and calls == 0, "stale datum skips spatially remote probes")
	s.launch_height, s.ground_height = 95, 95
	out = advance(c, s, bounded, 30)
	T.expect(calls > 0 and longest <= 14, "all probe segments stay within 14 metres")
end

do -- A genuinely reachable high landing is terrain, not a blanket high-pop rule.
    local c=Terrain.new()
    local s=input(vc(0,4.2,0),vc(5,0,0),201,0)
    s.launch_height=0
    local raised=world(function(x) return x>=1 and 3.2 or 0 end)
    local out=advance(c,s,raised,20)
    T.expect(out.reason=="raised_support" and out.weight>0.8,"verified high ledge is not rejected by an arbitrary rise cap")
    c:reset()
    out=advance(c,s,world(function() return 0 end),20)
    T.expect(out.target==0,"same high flat ollie remains level without a raised surface")
end

T.done()
