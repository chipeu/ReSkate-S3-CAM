-- Tests of the off-board camera (offboard.lua) on its own: scripted bodies, scripted sticks, scripted worlds. No game, no glue.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_offboard.lua
local T = require("tlib")
local Off = require("offboard")

T.group("offboard")
local expect, expect_near = T.expect, T.expect_near
local vc = vector.create
local deg = math.pi / 180
local UP = vc(0, 1, 0)
local DT = 1 / 60

-- ---------------------------------------------------------------- helpers
local function settings(over)
	local s = Off.defaults()
	for k, v in over or {} do s[k] = v end
	return s
end

-- A skater walking along `dir` (yaw, radians) at `speed`. centre = position + 1.1 m up (+ `bob` metres, + `rise` metres).
local function new_scene(s, opts)
	opts = opts or {}
	local sc = { s = s, off = Off.new(s), t = 0, pos = opts.pos or vc(0, 0, 0), dir = opts.dir or 0, speed = opts.speed or 0,
		centre_y = opts.centre_y or 1.1, input = { look_x = 0, look_y = 0, left_x = 0, left_y = 0, mouse_dx = 0, mouse_dy = 0 },
		ragdoll = false, query = opts.query, side_sign = 1 }
	sc.off.base_fov = 60
	sc.body = { centre = vc(0, 0, 0), head = vc(0, 0, 0), hips = vc(0, 0, 0), velocity = vc(0, 0, 0), heading = sc.dir, ragdoll = false, valid = true }
	function sc.refresh()
		local b = sc.body
		local v = vc(math.sin(sc.dir) * sc.speed, 0, math.cos(sc.dir) * sc.speed)
		b.velocity = v
		b.heading = sc.dir
		b.centre = vc(sc.pos.x, sc.centre_y, sc.pos.z)
		b.hips = b.centre - vc(0, 0.18, 0)
		b.head = b.centre + vc(0, 0.5, 0)
		b.ragdoll = sc.ragdoll
	end
	-- the pose the riding camera might have had: 2.9 m behind (along -dir), 0.8 m above the centre
	function sc.behind()
		return { pos = vc(sc.pos.x - math.sin(sc.dir) * 2.9, sc.centre_y + 0.8, sc.pos.z - math.cos(sc.dir) * 2.9),
			forward = vector.normalize(vc(math.sin(sc.dir), -0.12, math.cos(sc.dir))), up = UP, fov = 60 }
	end
	sc.refresh()
	return sc
end

local function start(sc, from)
	sc.off.side_sign = sc.side_sign
	sc.off:start(from or sc.behind(), sc.body)
end

-- One tick. Returns pos, forward, up, fov.
local function step(sc, dt)
	dt = dt or DT
	sc.t += dt
	sc.pos = sc.pos + vc(math.sin(sc.dir), 0, math.cos(sc.dir)) * (sc.speed * dt)
	if sc.rise then sc.centre_y = sc.rise(sc.t) end
	sc.refresh()
	sc.off.side_sign = sc.side_sign
	return sc.off:update(dt, sc.input, sc.body, sc.query)
end

local function run(sc, seconds, each)
	local n = math.floor(seconds / DT + 0.5)
	local p, f, u, fov
	for i = 1, n do
		if each then each(i, sc.t + DT) end
		p, f, u, fov = step(sc)
	end
	return p, f, u, fov
end

local function yaw_of(f) return math.atan2(f.x, f.z) end
local function wrap(a) return math.atan2(math.sin(a), math.cos(a)) end
local function flat_angle(a, b) return math.abs(wrap(yaw_of(a) - yaw_of(b))) end

-- ---------------------------------------------------------------- settings
do
	expect(Off.valid(Off.defaults()), "the defaults are valid")
	for _, case in { { "distance", 7 }, { "distance", 0.5 }, { "fov", 20 }, { "fov", 120 }, { "follow_time", 0 }, { "level", 1.5 },
		{ "offset", 2 }, { "style", "other" }, { "invert_y", 1 }, { "bail_distance", 0.5 } } do
		local s = Off.defaults()
		s[case[1]] = case[2]
		expect(not Off.valid(s), "out of range / wrong type is invalid: " .. case[1])
	end
	local s = Off.defaults()
	expect(s.distance == 2.8 and s.height == 0.35 and s.look_height == 0.35 and s.offset == 0 and s.fov == 0 and s.level == 0.85
		and s.bob == 0.2 and s.bail_distance == 1.3 and s.stick_speed == 170 and s.recentre_after == 1.5, "the defaults are the specified ones")
	local sh = Off.defaults()
	Off.apply_style(sh, "shoulder", 60)
	expect(sh.style == "shoulder" and sh.distance == 1.6 and sh.height == 0.55 and sh.look_height == 0.55 and sh.offset == 0.55 and sh.fov == 65
		and sh.recentre_after == 0 and sh.turn_time < s.turn_time, "Shoulder fills the sliders (fov base + 5, recentre off, low turn smoothing)")
	expect(Off.valid(sh), "Shoulder is valid")
	Off.apply_style(sh, "orbit", 60)
	expect(sh.distance == 2.8 and sh.offset == 0 and sh.fov == 0 and sh.recentre_after == 1.5, "Orbit puts the defaults back")
end

-- ---------------------------------------------------------------- walking straight
do
	local sc = new_scene(settings(), { speed = 3 })
	start(sc)
	local p0 = run(sc, 0.0)
	local first = sc.off:update(DT, sc.input, sc.body, nil)
	expect((first - sc.behind().pos).z < 0.3, "the first frame is where the start pose was")
	local prev, worst = first, 0
	local last, lf
	for i = 1, 360 do
		local p, f = step(sc)
		worst = math.max(worst, vector.magnitude(p - prev))
		prev, last, lf = p, p, f
		if i == 120 then
			-- settled after 2 s
			local pivot = sc.body.centre + UP * sc.s.height
			expect_near(vector.magnitude(p - pivot), sc.s.distance, 0.1, "walking straight: the distance is the set one")
			expect(vector.dot(p - sc.body.centre, vc(math.sin(sc.dir), 0, math.cos(sc.dir))) < -2.0, "walking straight: the camera is behind")
		end
	end
	expect(worst < 0.25, "walking straight: no frame step over 0.25 m (" .. string.format("%.3f", worst) .. ")")
	expect(flat_angle(lf, vc(0, 0, 1)) < 5 * deg, "walking straight: the view looks along the walking direction")
	expect(sc.off.rays == 1 or sc.off.rays == 0, "walking straight in open space: one ray a tick at most (" .. sc.off.rays .. ")")
end

-- ---------------------------------------------------------------- the stick turns the view
do
	local s = settings({ turn_time = 0.0 })
	local sc = new_scene(s)
	start(sc)
	run(sc, 0.5)
	local _, f0 = step(sc)
	sc.input.look_x = 1
	local _, f1 = run(sc, 0.1)
	expect(vector.dot(f1, vc(-1, 0, 0)) > 0 and f1.x < f0.x, "stick right turns the view to the right")
	local _, f2 = run(sc, 0.9)
	local turned = math.abs(wrap(yaw_of(f2) - yaw_of(f0))) / deg
	-- 1 s at 170 deg/s is 170 deg (the end of the stick range is 1.0)
	expect(turned > 160 and turned < 175, "stick held right for 1 s turns about 170 deg (" .. string.format("%.1f", turned) .. ")")

	local sd = new_scene(settings())
	start(sd)
	run(sd, 0.5)
	local _, g0 = step(sd)
	sd.input.look_x = -1
	local _, g1 = run(sd, 1.0)
	local d = math.abs(wrap(yaw_of(g1) - yaw_of(g0))) / deg
	expect(d > 150 and d < 172, "with the default turn smoothing it is a little less (" .. string.format("%.1f", d) .. ")")
	expect(vector.dot(g1, vc(0, 0, 1)) < 0 or d > 100, "left stick turns the other way")
	-- the view coasts to a stop after the stick is let go, it does not freeze or snap
	sd.input.look_x = 0
	local last = yaw_of(g1)
	local worst = 0
	for _ = 1, 60 do
		local _, g = step(sd)
		worst = math.max(worst, math.abs(wrap(yaw_of(g) - last)))
		last = yaw_of(g)
	end
	expect(worst / DT < 175 * deg, "no turn faster than the stick speed after release")
end

-- pitch limits and Invert Y
do
	local sc = new_scene(settings({ turn_time = 0.0 }))
	start(sc)
	sc.input.look_y = 1 -- stick up: look up, so the camera goes down
	run(sc, 3)
	expect_near(sc.off.elev / deg, -35, 0.6, "stick up for 3 s stops at the lower limit (-35)")
	sc.input.look_y = -1
	run(sc, 4)
	expect_near(sc.off.elev / deg, 55, 0.6, "stick down stops at the upper limit (55)")
	local inv = new_scene(settings({ turn_time = 0.0, invert_y = true }))
	start(inv)
	inv.input.look_y = 1
	run(inv, 4)
	expect_near(inv.off.elev / deg, 55, 0.6, "Invert Y: stick up raises the camera")
end

-- ---------------------------------------------------------------- recentre
do
	-- walking along +X (yaw 90 deg), the view starts looking along +Z
	local s = settings()
	local sc = new_scene(s, { speed = 3, dir = 90 * deg })
	start(sc, { pos = vc(0, 1.9, -2.9), forward = vector.normalize(vc(0, -0.12, 1)), up = UP, fov = 60 })
	local y0 = sc.off.yaw
	local worst, prev = 0, sc.off.yaw
	local at_1_4, final
	for i = 1, 60 * 5 do
		local _, f = step(sc)
		local y = yaw_of(f)
		if i > 12 then worst = math.max(worst, math.abs(wrap(y - prev)) / DT) end
		prev = y
		if i == 84 then at_1_4 = math.abs(wrap(sc.off.yaw - y0)) / deg end
		final = flat_angle(f, vc(1, 0, 0)) / deg
	end
	expect(at_1_4 < 2, "no recentre before 1.5 s of no steering (turned " .. string.format("%.1f", at_1_4 or -1) .. " deg by 1.4 s)")
	expect(final < 6, "after the idle time it swings behind the walking direction (" .. string.format("%.1f", final) .. " deg off)")
	expect(worst <= 91 * deg, "the swing is capped at 90 deg/s (" .. string.format("%.1f", worst / deg) .. ")")

	-- steering restarts the wait
	local sd = new_scene(s, { speed = 3, dir = 90 * deg })
	start(sd, { pos = vc(0, 1.9, -2.9), forward = vector.normalize(vc(0, -0.12, 1)), up = UP, fov = 60 })
	run(sd, 1.2)
	sd.input.look_x = 0.5
	run(sd, 0.1)
	sd.input.look_x = 0
	run(sd, 0.3) -- the coast after the stick is let go
	local yy = sd.off.yaw
	run(sd, 1.2)
	expect(math.abs(wrap(sd.off.yaw - yy)) < 2 * deg, "steering restarts the idle time")

	-- standing still never recentres
	local st = new_scene(s, { speed = 0, dir = 90 * deg })
	start(st, { pos = vc(0, 1.9, -2.9), forward = vector.normalize(vc(0, -0.12, 1)), up = UP, fov = 60 })
	local ys = st.off.yaw
	run(st, 12)
	expect(math.abs(wrap(st.off.yaw - ys)) < 1 * deg, "standing still: the view stays where it is for 12 s")

	-- recentre off (0)
	local no = new_scene(settings({ recentre_after = 0 }), { speed = 3, dir = 90 * deg })
	start(no, { pos = vc(0, 1.9, -2.9), forward = vector.normalize(vc(0, -0.12, 1)), up = UP, fov = 60 })
	local yn = no.off.yaw
	run(no, 6)
	expect(math.abs(wrap(no.off.yaw - yn)) < 1 * deg, "Recentre after 0 never recentres")

	-- R3: eased, behind the skater's heading even standing
	local r3 = new_scene(s, { speed = 0, dir = 90 * deg })
	start(r3, { pos = vc(0, 1.9, -2.9), forward = vector.normalize(vc(0, -0.12, 1)), up = UP, fov = 60 })
	run(r3, 0.3)
	r3.off:recentre_now()
	local wr, pv = 0, r3.off.yaw
	for _ = 1, 120 do
		step(r3)
		wr = math.max(wr, math.abs(wrap(r3.off.yaw - pv)) / DT)
		pv = r3.off.yaw
	end
	expect(math.abs(wrap(r3.off.yaw - 90 * deg)) < 3 * deg, "R3 swings behind the skater")
	expect(wr < 245 * deg, "R3 swing is eased and capped")
end

-- ---------------------------------------------------------------- stairs and bobbing
do
	-- 10 steps of 0.18 m, one every 0.2 s, walking at 1.5 m/s
	local s = settings({ level = 1.0, bob = 0.0 })
	local sc = new_scene(s, { speed = 1.5 })
	sc.rise = function(t)
		if t < 1.0 then return 1.1 end
		return 1.1 + 0.18 * math.min(10, math.floor((t - 1.0) / 0.2) + 1)
	end
	start(sc)
	local ts, ys = {}, {}
	for i = 1, 60 * 5 do
		local p = step(sc)
		if sc.t >= 1.6 and sc.t <= 2.8 then ts[#ts + 1] = sc.t; ys[#ys + 1] = p.y end
	end
	-- the best straight line through the camera's height over the climb
	local n, st, sy, stt, sty = #ts, 0, 0, 0, 0
	for i = 1, n do st += ts[i]; sy += ys[i]; stt += ts[i] * ts[i]; sty += ts[i] * ys[i] end
	local slope = (n * sty - st * sy) / (n * stt - st * st)
	local icpt = (sy - slope * st) / n
	local worst = 0
	for i = 1, n do worst = math.max(worst, math.abs(ys[i] - (icpt + slope * ts[i]))) end
	expect(worst < 0.05, "stairs, Level 1: the camera height stays within 5 cm of a straight line (" .. string.format("%.3f", worst) .. ")")
	expect(slope > 0.4 and slope < 1.2, "stairs: and the line climbs with the stairs (slope " .. string.format("%.2f", slope) .. " m/s, stairs 0.9)")
	local final = step(sc)
	expect(sc.centre_y - 1.1 - 1.8 < 1e-6, "stairs scene reached the top")
end

do
	local function bob_range(strength, speed)
		local sc = new_scene(settings({ bob = strength }), { speed = speed })
		sc.rise = function(t) return 1.1 + 0.04 * math.sin(2 * math.pi * 2.0 * t) end -- a 4 cm bob at 2 Hz
		start(sc)
		run(sc, 5)
		local lo, hi = math.huge, -math.huge
		for _ = 1, 120 do
			local p = step(sc)
			lo, hi = math.min(lo, p.y), math.max(hi, p.y)
		end
		return hi - lo
	end
	local none, full, slow = bob_range(0, 3), bob_range(1, 3), bob_range(1, 0)
	expect(none < 0.025, "bob 0: the walking bob is filtered out (" .. string.format("%.3f", none) .. " m)")
	expect(full > 0.05 and full > 2 * none, "bob 1: it comes back (" .. string.format("%.3f", full) .. " m)")
	expect(slow < 0.025, "bob 1 standing still: no bob (" .. string.format("%.3f", slow) .. " m)")
end

-- ---------------------------------------------------------------- shoulder
do
	local s = settings()
	Off.apply_style(s, "shoulder", 60)
	local sc = new_scene(s)
	start(sc)
	local p, f = run(sc, 3)
	-- facing +Z the right is -X: the camera sits to the skater's right, he is left of the centre of the screen
	local right = vc(-1, 0, 0)
	local lateral = vector.dot(p - sc.body.centre, right)
	expect_near(lateral, 0.55, 0.06, "Shoulder style: the camera sits 0.55 m to the right")
	local view_right = vector.dot(sc.body.centre - p, vector.cross(f, UP)) -- skater's position across the screen
	expect(view_right < 0, "Shoulder style: the skater is left of the screen centre")
	expect_near(vector.magnitude(p - (sc.body.centre + UP * s.height + right * 0.55)), 1.6, 0.1, "Shoulder style: close, 1.6 m")
	sc.side_sign = -1
	local q = run(sc, 3)
	expect_near(vector.dot(q - sc.body.centre, right), -0.55, 0.06, "the shoulder-side bind flips it to the left")
	-- the slider on its own: a negative offset is the left shoulder
	local sl = new_scene(settings({ offset = -0.8 }))
	start(sl)
	local pl = run(sl, 3)
	expect_near(vector.dot(pl - sl.body.centre, right), -0.8, 0.06, "a negative Horizontal offset is the left")
	expect(math.abs(vector.dot(pl - sl.body.centre, right)) < 0.9, "and it is smoothed, not instant")
end

-- ---------------------------------------------------------------- collision
do
	local wall_z = -1.5
	local wall = true
	local function query(from, to)
		if not wall then return nil end
		if (from.z - wall_z) * (to.z - wall_z) < 0 then
			local t = (from.z - wall_z) / (from.z - to.z)
			return from + (to - from) * t
		end
		return nil
	end
	local sc = new_scene(settings(), { query = query })
	start(sc, { pos = vc(0, 1.9, -1.0), forward = vector.normalize(vc(0, -0.12, 1)), up = UP, fov = 60 })
	local entered, maxrays = false, 0
	local p
	for _ = 1, 180 do
		p = step(sc)
		if p.z < wall_z + 0.05 then entered = true end
		maxrays = math.max(maxrays, sc.off.rays)
	end
	expect(not entered, "wall behind: the camera never gets past the wall")
	expect(p.z > wall_z + 0.3, "wall behind: it stays 0.3 m or more from it (z " .. string.format("%.2f", p.z) .. ")")
	expect(p.z < -0.2, "wall behind: but is not stuck on the skater (z " .. string.format("%.2f", p.z) .. ")")
	expect(maxrays <= 3, "at most 3 rays a tick (" .. maxrays .. ")")
	local held_z = p.z
	wall = false
	local early
	for i = 1, 60 * 4 do
		local q = step(sc)
		if i == 12 then early = q.z end
		p = q
	end
	expect(early < held_z + 0.001 and early > held_z - 0.15, "released slowly: 0.2 s after the wall goes it has hardly moved (z " .. string.format("%.2f", early) .. ")")
	expect(p.z < -2.5, "and is back out after a few seconds (z " .. string.format("%.2f", p.z) .. ")")
end

do
	-- the floor: a camera that would sit under the ground is lifted, not put in it
	local function floor_query(from, to)
		if from.y >= 0 and to.y < 0 then
			return from + (to - from) * (from.y / (from.y - to.y))
		end
		return nil
	end
	local sc = new_scene(settings({ turn_time = 0.0 }), { query = floor_query, pos = vc(0, 0, 0) })
	sc.centre_y = 0.5 -- a skater lying low
	sc.refresh()
	start(sc, { pos = vc(0, 1.5, -2.8), forward = vector.normalize(vc(0, -0.2, 1)), up = UP, fov = 60 })
	sc.input.look_y = 1 -- look up from low down: the camera goes under the ground
	local under = false
	for _ = 1, 240 do
		local p = step(sc)
		if p.y < 0.02 then under = true end
	end
	expect(not under, "the camera is lifted instead of entering the ground")
	expect(sc.off.rays <= 3, "ground ray included: at most 3 rays")
end

-- ---------------------------------------------------------------- the hand-over
do
	-- a riding camera far from the orbit: 5 m back, 3 m up, 70 deg off
	local sc = new_scene(settings(), { speed = 2 })
	local from = { pos = vc(-4.7, 4.1, -1.7), forward = vector.normalize(vc(0.9, -0.5, 0.3)), up = vector.normalize(vc(0.1, 1, 0)), fov = 75 }
	start(sc, from)
	local prev = from.pos
	local worst, worst_angle = 0, 0
	local last_f = from.forward
	for _ = 1, 150 do
		local p, f, _, fov = step(sc)
		worst = math.max(worst, vector.magnitude(p - prev) - 2 * DT)
		worst_angle = math.max(worst_angle, math.acos(math.min(1, vector.dot(f, last_f))))
		prev, last_f = p, f
		expect(fov >= 60 - 1e-6 and fov <= 75 + 1e-6, "fov stays between the two")
	end
	expect(worst < 0.25, "a far start pose: no step over 0.25 m a frame (" .. string.format("%.3f", worst) .. ")")
	expect(worst_angle < 4 * deg, "and no turn over 4 deg a frame")
	local a = new_scene(settings({ transition_time = 0 }), { speed = 2 })
	start(a, from)
	local p0 = a.off:update(DT, a.input, a.body, nil)
	expect(vector.magnitude(p0 - from.pos) < 5, "a transition time of 0 is allowed (it goes straight to the orbit)")
	-- no start pose at all: behind the way the skater faces
	local n = new_scene(settings(), { dir = 45 * deg })
	n.off:start(nil, n.body)
	local p, f = step(n)
	expect(vector.dot(f, vc(math.sin(45 * deg), 0, math.cos(45 * deg))) > 0.9, "no start pose: looks the way the skater faces")
end

-- ---------------------------------------------------------------- a bail
do
	local sc = new_scene(settings(), { speed = 0 })
	start(sc)
	run(sc, 0.5)
	sc.ragdoll = true
	local fovv, ok = 60, true
	local p, f, fov
	for i = 1, 60 * 4 do
		-- tumbling: the body lies out 1.6 m between hips and head, rolling about
		local a = i * 0.05
		sc.centre_y = 0.5
		sc.refresh()
		local hips = vc(0.2 * math.sin(a), 0.35, 0.1)
		local head = hips + vc(1.4 * math.cos(a), 0.2, 1.4 * math.sin(a))
		sc.body.hips, sc.body.head = hips, head
		sc.body.centre = (hips + head) * 0.5
		p, f, _, fov = sc.off:update(DT, sc.input, sc.body, nil)
	end
	local half = fov * 0.5 * deg
	for _, pt in { sc.body.hips, sc.body.head } do
		local v = vector.normalize(pt - p)
		local ang = math.acos(math.min(1, vector.dot(v, f)))
		expect(ang <= 0.8 * half + 1e-3, "bail: head and hips inside 80% of the half FOV (" .. string.format("%.1f of %.1f deg", ang / deg, 0.8 * half / deg) .. ")")
	end
	expect(sc.off.dist + sc.off.extra > 2.8 * 1.3 * 0.9, "bail: the camera is further out (" .. string.format("%.2f", sc.off.dist + sc.off.extra) .. " m)")
	-- stick orbit still works in a bail
	local y0 = sc.off.yaw
	sc.input.look_x = 1
	for _ = 1, 30 do step(sc) end
	expect(math.abs(wrap(sc.off.yaw - y0)) > 60 * deg, "bail: the stick still orbits")
end

-- ---------------------------------------------------------------- the walking direction
do
	-- The game walks along (hidden yaw - atan2(stick x, stick y)); the scripted skater does exactly that.
	local function walk_with(hidden, lx, ly, yaw_start)
		local s = settings({ recentre_after = 0 })
		local sc = new_scene(s, { speed = 3 })
		sc.dir = hidden - math.atan2(lx, ly)
		sc.refresh()
		sc.input.left_x, sc.input.left_y = lx, ly
		start(sc, { pos = vc(0, 1.9, 0) - vc(math.sin(yaw_start), 0, math.cos(yaw_start)) * 2.9, forward = vector.normalize(vc(math.sin(yaw_start), -0.12, math.cos(yaw_start))), up = UP, fov = 60 })
		run(sc, 3)
		return sc
	end
	for _, c in { { 40, 0, 1 }, { 40, 1, 0 }, { -100, 0.7, 0.7 }, { 170, -0.6, 0.8 }, { 0, 0, 1 } } do
		local H = c[1] * deg
		local sc = walk_with(H, c[2], c[3], 0.0)
		local err = math.abs(wrap(sc.off.hidden - H)) / deg
		expect(err < 5, string.format("hidden yaw %d deg, stick (%.1f, %.1f): estimate within 5 deg (%.1f)", c[1], c[2], c[3], err))
		expect(sc.off.conf > 0.5, "and it is confident")
	end

	-- the player lets go of the view stick: ours eases toward the estimate, no faster than 30 deg/s
	local sc = walk_with(70 * deg, 0, 1, 0.0)
	local yaw0 = sc.off.yaw
	local worst, prev = 0, sc.off.yaw
	local err_first = math.abs(wrap(sc.off.yaw - sc.off.hidden)) / deg
	for _ = 1, 60 * 6 do
		step(sc)
		worst = math.max(worst, math.abs(wrap(sc.off.yaw - prev)) / DT)
		prev = sc.off.yaw
	end
	local err_last = math.abs(wrap(sc.off.yaw - sc.off.hidden)) / deg
	expect(worst <= 30.5 * deg, "alignment never turns faster than 30 deg/s (" .. string.format("%.1f", worst / deg) .. ")")
	expect(err_last < 4, "and gets there (" .. string.format("%.1f", err_last) .. " deg left, was " .. string.format("%.0f", err_first) .. ")")
	expect(math.abs(sc.off.align_error) / deg < 4, "the logged error says so")

	-- Match walking to the view off: the view stays
	local s2 = settings({ recentre_after = 0, match_walking = false })
	local nm = new_scene(s2, { speed = 3 })
	nm.dir = 70 * deg
	nm.refresh()
	nm.input.left_y = 1
	start(nm, { pos = vc(0, 1.9, -2.9), forward = vector.normalize(vc(0, -0.12, 1)), up = UP, fov = 60 })
	run(nm, 5)
	expect(math.abs(wrap(nm.off.yaw - 0)) < 2 * deg, "Match walking off: the view is not turned")

	-- while the player steers, ours does not fight
	local sg = walk_with(70 * deg, 0, 1, 0.0)
	sg.input.look_x = 0.6
	local before = sg.off.yaw
	run(sg, 0.5)
	local moved = wrap(sg.off.yaw - before)
	expect(moved < -20 * deg and moved > -50 * deg, "steering wins over alignment (" .. string.format("%.1f", moved / deg) .. " deg)")
	sg.input.look_x = 0
	run(sg, 6)
	expect(math.abs(wrap(sg.off.yaw - 70 * deg)) < 4 * deg, "after the steering the view eases back to the walking frame (" .. string.format("%.1f", wrap(sg.off.yaw - 70 * deg) / deg) .. ")")
end

-- ---------------------------------------------------------------- robustness
do
	local sc = new_scene(settings(), { speed = 2 })
	start(sc)
	run(sc, 0.5)
	local p0, f0 = step(sc)
	sc.body.valid = false
	local p1, f1 = sc.off:update(DT, sc.input, sc.body, nil)
	expect(p1 == p0 or vector.magnitude(p1 - p0) < 1e-6, "an invalid body holds the last view")
	sc.body.valid = true
	sc.body.centre = vc(0 / 0, 0, 0)
	local p2 = sc.off:update(DT, sc.input, sc.body, nil)
	expect(vector.magnitude(p2 - p0) < 1e-6, "a NaN body holds the last view")
	sc.refresh()
	-- a teleport: the filters follow at once, the output stays finite
	sc.pos = vc(300, 0, 300)
	sc.refresh()
	local p3 = sc.off:update(DT, sc.input, sc.body, nil)
	expect(p3.x - p3.x == 0 and vector.magnitude(p3 - vc(300, 1.5, 300)) < 8, "a teleport follows the skater")
	-- a huge dt is capped
	local p4 = sc.off:update(5.0, sc.input, sc.body, nil)
	expect(p4.x - p4.x == 0, "dt is capped")
	-- update before start starts itself
	local fresh = Off.new(settings())
	local ok = fresh:update(DT, sc.input, sc.body, nil)
	expect(ok ~= nil, "update without start starts from the body")
	expect(#fresh:summary() > 20, "summary line")
end

-- ---------------------------------------------------------------- cost
do
	local sc = new_scene(settings(), { speed = 3 })
	local rays = 0
	sc.query = function(from, to) rays += 1; return nil end
	start(sc)
	run(sc, 2)
	local wall_query = function(from, to)
		rays += 1
		if (from.z + 1.5) * (to.z + 1.5) < 0 then return from + (to - from) * ((from.z + 1.5) / (from.z - to.z)) end
		return nil
	end
	for _, q in { sc.query, wall_query } do
		local sb = new_scene(settings(), { speed = 0 })
		sb.query = q
		start(sb)
		run(sb, 1)
		local n = 20000
		local t0 = os.clock()
		for _ = 1, n do
			sb.t += DT
			sb.refresh()
			sb.off:update(DT, sb.input, sb.body, q)
		end
		local ms = (os.clock() - t0) * 1000 / n
		print(string.format("off-board update: %.4f ms mean (%s)", ms, q == wall_query and "wall: 3 rays" or "open: 1 ray"))
		expect(ms < 0.15, "per-tick cost under 0.15 ms (" .. string.format("%.4f", ms) .. ")")
	end
end

T.done()
if T.failures > 0 then error("offboard tests failed") end
