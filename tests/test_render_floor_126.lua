-- App/Glue render-floor regression: the final safety stage must use the safe
-- core eye when render alignment moves a few centimetres beneath an overhang.
local T = require("tlib")
local Mock, Settings = require("mock_reskate"), require("settings")
local BodyFrame = require("bodyframe")
local vc = vector.create
local FWD, UP = vc(0, 0, 1), vc(0, 1, 0)
T.group("render floor 126")

local function box(a, b)
	local lo, hi = 0, 1
	for _, axis in { "x", "y", "z" } do
		local low = axis == "x" and 0 or axis == "y" and 1.3 or -2.4
		local high = axis == "x" and 0.4 or axis == "y" and 1.4 or -1.6
		local d = b[axis] - a[axis]
		if math.abs(d) < 1e-8 then
			if a[axis] < low or a[axis] > high then return nil end
		else
			local u, v = (low - a[axis]) / d, (high - a[axis]) / d
			if u > v then u, v = v, u end
			lo, hi = math.max(lo, u), math.min(hi, v)
			if lo > hi then return nil end
		end
	end
	return a + (b - a) * lo
end
local function world(a, b)
	local slab = box(a, b)
	local floor
	if a.y >= 0 and b.y <= 0 and a.y ~= b.y then floor = a + (b - a) * (a.y / (a.y - b.y)) end
	if slab and floor then return vector.magnitude(slab - a) < vector.magnitude(floor - a) and slab or floor end
	return slab or floor
end
local function scene()
	local m = Mock.install({ limit_rays = true })
	m.reskate.input.gamepad = function() return nil end
	m.reskate.menu.game = function() return { open = false } end
	local app = require("app").start()
	local s = Settings.defaults()
	s.follow.trick_pop, s.shake_enabled = false, false
	assert(app.store:set_settings(s))
	local o = Settings.copy(app.store.options)
	o.stable_timing = true
	app.store:set_options(o)
	m.state.raycast = world
	for i = 1, 4 do
		m.fire("physics_step", { at = m.clock_ms, seconds = 1 / 60, velocity = { 0, 0, 0 }, ragdoll = false })
		m.tick(1000 / 60)
	end
	local g = app.glue
	g.source, g.blend, g.snap_guard_on = "ride", 1, false
	g.collision_prediction_enabled = false
	g.collision_escape:reset()
	g.snap.valid, g.snap.onboard, g.snap.physics_state = true, true, 201
	g.skater_position, g.snap.position = vc(-0.02, 2.5, 0), vc(-0.02, 2.5, 0)
	g.snap.forward = FWD
	g.render_delta = vc(-0.04, 0, 0)
	g.frame = nil
	return m, app, g
end
local function show(m, g, p)
	m.state.raycasts, g.rays_tick, g.capped_this_tick = 0, 59, false
	local ok, why = g:show(p, FWD, UP, 65, "riding")
	T.expect(ok == true, "App/Glue show succeeds: " .. tostring(why))
	return m.last_call("set")
end

do
	local m, app, g = scene()
	local core = vc(-0.02, 1.25, -2)
	local shown = show(m, g, core)
	T.expect(shown.position == core, "safe core eye restored beneath a nearby ledge")
	T.expect(shown.forward == FWD and shown.up == UP, "safe core aim restored with eye")
	T.expect(m.state.raycasts <= 4 and g.rays_tick <= 64 and app.errors == 0,
		"false floor correction stays in reserved ray budget without API errors")
end

do
	local m, app, g = scene()
	g.render_delta = vc(0, 0, 0)
	local core = vc(0.1, 1.2, -2)
	local shown = show(m, g, core)
	local expected = vc(0.1, 1.7, -2)
	local forward, up = BodyFrame.reposition(g.skater_position, core, expected, FWD, UP, true)
	T.expect(math.abs(shown.position.y - 1.7) < 1e-5, "genuinely buried core clears raised floor")
	T.expect(vector.magnitude(shown.forward - forward) < 1e-5
		and vector.magnitude(shown.up - up) < 1e-5, "buried core aim follows corrected eye")
	T.expect(m.state.raycasts <= 4 and g.rays_tick <= 64 and app.errors == 0,
		"buried correction stays in reserved ray budget without API errors")
end

T.done()
