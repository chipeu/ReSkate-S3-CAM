-- Whole-stack camera testbox: real App + Glue + Camera + SnapGuard against a scripted host.
TRACE_ONLY_60 = arg and arg[3] == "60"
-- Physics ticks at 60 Hz on its own clock; the render clock is independent (fps, jitter), like the game.
--
--   luau_run -I <plugin dir> -I tests -I tools/trace/out tests/testbox/routes.lua [filter] [csv-dir]
--
-- Prints one TSV row per route/host/fps run. No assertions: the same file measures any plugin version,
-- which is what makes before/after numbers comparable. tests/testbox/compare.py owns the verdicts.
local Mock, Settings = require("mock_reskate"), require("settings")
local v, mag = vector.create, vector.magnitude
local filter = arg and arg[1] or ""
if filter == "-" then filter = "" end
local PHYS = 1 / 60
local AIR = { [200] = true, [201] = true }

-- ------------------------------------------------------------------ world
-- A world is { boxes = {{min,max}...}, profile = {{z,y}...} } . The profile is extruded along X.
local function ray_box(a, b, box)
	local t0, t1 = 0, 1
	local d = b - a
	for _, axis in { "x", "y", "z" } do
		local o, s = a[axis], d[axis]
		local lo, hi = box[1][axis], box[2][axis]
		if math.abs(s) < 1e-9 then
			if o < lo or o > hi then return nil end
		else
			local n, f = (lo - o) / s, (hi - o) / s
			if n > f then n, f = f, n end
			t0, t1 = math.max(t0, n), math.min(t1, f)
			if t0 > t1 then return nil end
		end
	end
	return t0
end
local function ray_profile(a, b, p)
	local best
	for i = 1, #p - 1 do
		local z1, y1, z2, y2 = p[i][1], p[i][2], p[i + 1][1], p[i + 1][2]
		local dz, dy = z2 - z1, y2 - y1
		local da = (a.z - z1) * dy - (a.y - y1) * dz
		local db = (b.z - z1) * dy - (b.y - y1) * dz
		if da ~= db and da * db <= 0 then
			local t = da / (da - db)
			local q = a + (b - a) * t
			local u = math.abs(dz) > math.abs(dy) and (q.z - z1) / dz or (q.y - y1) / dy
			if u >= 0 and u <= 1 and (not best or t < best) then best = t end
		end
	end
	return best
end
local function make_ray(w)
	return function(a, b)
		local best
		if w.profile then best = ray_profile(a, b, w.profile) end
		for _, box in w.boxes or {} do
			local t = ray_box(a, b, box)
			if t and (not best or t < best) then best = t end
		end
		if best then return a + (b - a) * best end
		return nil
	end
end
local function arc(cz, cy, r, a0, a1, n, into)
	for i = 0, n do
		local t = a0 + (a1 - a0) * i / n
		into[#into + 1] = { cz + r * math.sin(t), cy - r * math.cos(t) }
	end
end

-- ------------------------------------------------------------------ routes
-- A route's pose(t) returns root, velocity, state, heading. Roots stand HIP above the surface.
local HIP = 0.95
local G = 9.8
local function ballistic(y0, vy0, u) return y0 + vy0 * u - 0.5 * G * u * u, vy0 - G * u end

local function route_vert(opt)
	local R, flat, speed, lip = opt.radius, 18, opt.speed, opt.lip or 0
	local prof = { { -200, 0 }, { flat, 0 } }
	arc(flat, R, R, 0, math.pi / 2, 24, prof)
	prof[#prof + 1] = { flat + R, R + 2 } -- vertical extension
	local deck_z = flat + R + 0.02
	local world = { profile = prof, boxes = { { v(-40, -1, deck_z), v(40, R + 2, deck_z + 8) } } }
	if opt.ledge then
		world.boxes[#world.boxes + 1] = { v(-40, 0, flat - opt.ledge[1]), v(40, opt.ledge[2], flat - opt.ledge[1] + 0.5) }
	end
	local t_flat = flat / speed
	local t_arc = (math.pi / 2) * R / speed
	local vy = opt.pop or speed
	local t_air = 2 * vy / G
	local function surf(a) -- arc point at angle a with hips along the normal
		local r = R - HIP
		return v(0, R - r * math.cos(a), flat + r * math.sin(a))
	end
	local top = surf(math.pi / 2)
	local cycle = t_flat + t_arc + t_air + t_arc + t_flat
	local function pose(t)
		t = t % cycle
		if t < t_flat then return v(0, HIP, speed * t), v(0, 0, speed), 100, 0 end
		t -= t_flat
		if t < t_arc then
			local a = (t * speed) / R
			return surf(a), v(0, math.sin(a), math.cos(a)) * speed, 100, 0
		end
		t -= t_arc
		if t < t_air then
			local y, w = ballistic(top.y, vy, t)
			local h = math.pi * math.clamp(t / t_air, 0, 1) -- backside 180
			return v(0, y, top.z), v(0, w, 0), t < 0.08 and 200 or 201, h
		end
		t -= t_air
		if t < t_arc then
			local a = math.pi / 2 - (t * speed) / R
			return surf(a), v(0, -math.sin(a), -math.cos(a)) * speed, 100, math.pi
		end
		t -= t_arc
		return v(0, HIP, flat - speed * t), v(0, 0, -speed), 100, math.pi
	end
	return { world = world, pose = pose, duration = cycle * 2, warm = 1.0, settings = opt.settings }
end

-- Back and forth in a halfpipe: long airs with short rides between them, the travel direction reversing at every landing.
-- opt: radius, flat (half the flat length), speed (m/s on the transitions), pop (take-off up speed), fakie (no spin in the air)
local function route_halfpipe(opt)
	local R, F, speed, vy = opt.radius, opt.flat, opt.speed, opt.pop
	local prof = { { -(F + R), R + 2 } }
	arc(-F, R, R, -math.pi / 2, 0, 24, prof)
	arc(F, R, R, 0, math.pi / 2, 24, prof)
	prof[#prof + 1] = { F + R, R + 2 }
	local world = { profile = prof, boxes = {
		{ v(-40, -1, F + R + 0.02), v(40, R + 2, F + R + 8) },
		{ v(-40, -1, -(F + R + 8)), v(40, R + 2, -(F + R + 0.02)) },
	} }
	if opt.wall then
		world.boxes[#world.boxes + 1] = { v(opt.wall, -1, -(F + R + 8)), v(opt.wall + 1, R + 12, F + R + 8) }
		world.boxes[#world.boxes + 1] = { v(-opt.wall - 1, -1, -(F + R + 8)), v(-opt.wall, R + 12, F + R + 8) }
	end
	local t_flat, t_arc, t_air = F / speed, (math.pi / 2) * R / speed, 2 * vy / G
	local half = 2 * (t_flat + t_arc) + t_air
	local function surf(a, sgn)
		local r = R - HIP
		return v(0, R - r * math.cos(a), sgn * (F + r * math.sin(a)))
	end
	local carve = math.tan(math.rad(opt.cross or 0)) * speed
	local function plain(t)
		t = t % (2 * half)
		local sgn = 1
		if t >= half then t -= half; sgn = -1 end
		local h0 = sgn == 1 and 0 or math.pi
		local h1 = opt.fakie and h0 or h0 + math.pi
		if t < t_flat then return v(0, HIP, sgn * speed * t), v(0, 0, sgn * speed), 100, h0 end
		t -= t_flat
		if t < t_arc then
			local a = (t * speed) / R
			return surf(a, sgn), v(0, math.sin(a), sgn * math.cos(a)) * speed, 100, h0
		end
		t -= t_arc
		if t < t_air then
			local top = surf(math.pi / 2, sgn)
			local y, w = ballistic(top.y, vy, t)
			return v(0, y, top.z), v(0, w, 0), t < 0.08 and 200 or 201, opt.flip and h0 or opt.spin and (h1 + math.rad(opt.spin) * (math.clamp(t / t_air, 0, 1) - 1)) or (h0 + (h1 - h0) * math.clamp(t / t_air, 0, 1))
		end
		t -= t_air
		if t < t_arc then
			local a = math.pi / 2 - (t * speed) / R
			return surf(a, sgn), v(0, -math.sin(a), -sgn * math.cos(a)) * speed, 100, h1
		end
		t -= t_arc
		return v(0, HIP, sgn * (F - speed * t)), v(0, 0, -sgn * speed), 100, h1
	end
	local function pose(t)
		local p, vel, state, h = plain(t)
		if carve == 0 then return p, vel, state, h end
		local turn = math.atan2(carve, math.abs(vel.z) > 1 and math.abs(vel.z) or speed)
		local forward = math.cos(h) > 0 and 1 or -1
		return v(carve * t, p.y, p.z), v(carve, vel.y, vel.z), state, h + forward * turn
	end
	return { world = world, pose = pose, duration = half * 3, warm = 1.0, settings = opt.settings }
end

-- Ollie onto a ledge, roll along it, drop off the end, roll away.
local function route_ledge(opt)
	local H, speed = opt.height, opt.speed
	local z_pop = 14
	local z_on = z_pop + opt.gap
	local z_off = z_on + opt.length
	local world = { boxes = { { v(-40, -5, -300), v(40, 0, 400) }, { v(-opt.half, 0, z_on), v(opt.half, H, z_off) } } }
	local vy = math.sqrt(2 * G * (H + 0.55))
	local up_t = vy / G
	local t_air = up_t + math.sqrt(2 * 0.55 / G)
	local vz = opt.gap / t_air * 1.3
	local t_pop = z_pop / speed
	local land_z = z_pop + vz * t_air
	local t_roll = (z_off - land_z) / speed
	local t_drop = math.sqrt(2 * H / G)
	local cycle_rest = 3
	local total = t_pop + t_air + t_roll + t_drop + cycle_rest
	local function pose(t)
		t = t % total
		if t < t_pop then return v(0, HIP, speed * t), v(0, 0, speed), 100, 0 end
		t -= t_pop
		if t < t_air then
			local y, w = ballistic(HIP, vy, t)
			return v(0, y, z_pop + vz * t), v(0, w, vz), t < 0.08 and 200 or 201, 0
		end
		t -= t_air
		if t < t_roll then return v(0, H + HIP, land_z + speed * t), v(0, 0, speed), 100, 0 end
		t -= t_roll
		if t < t_drop then
			local y, w = ballistic(H + HIP, 0, t)
			return v(0, y, z_off + speed * t), v(0, w, speed), 201, 0
		end
		t -= t_drop
		return v(0, HIP, z_off + speed * t_drop + speed * t), v(0, 0, speed), 100, 0
	end
	return { world = world, pose = pose, duration = total * 2, warm = 1.0 }
end

-- Riding beside a raised block's edge, weaving slightly, with the eye close to the block's top:
-- the trailing eye crosses the edge back and forth by millimetres to centimetres.
local function route_edge(opt)
	local H, speed, amp = opt.height, opt.speed, opt.amp
	local world = { boxes = { { v(-40, -5, -300), v(40, 0, 2000) }, { v(opt.edge, 0, -300), v(opt.edge + 3, H, 2000) } } }
	local w = opt.rate * 2 * math.pi
	local function pose(t)
		local x, dx = amp * math.sin(w * t), amp * w * math.cos(w * t)
		local h = math.atan2(dx, speed)
		return v(x, HIP, speed * t), v(dx, 0, speed), 100, h
	end
	return { world = world, pose = pose, duration = 8, warm = 1.5 }
end

-- A repeated curb: short steps across the direction of travel, bumping support and eye clearance.
local function route_curbs(opt)
	local boxes = { { v(-40, -5, -300), v(40, 0, 2000) } }
	for i = 0, 60 do
		local z = 6 + i * opt.pitch
		boxes[#boxes + 1] = { v(-40, 0, z), v(40, opt.height, z + opt.pitch * 0.5) }
	end
	local speed = opt.speed
	local function support(z)
		local u = (z - 6) / opt.pitch
		if u >= 0 and u % 1 < 0.5 and u < 61 then return opt.height end
		return 0
	end
	local function pose(t)
		local z = speed * t
		return v(0, support(z) * 0.5 + HIP, z), v(0, 0, speed), 100, 0
	end
	return { world = world or { boxes = boxes }, pose = pose, duration = 8, warm = 1.0 }
end

-- Plain flat pop: no terrain at all. Anything that isn't smooth here is a pure tracking fault.
local function route_flat_pop(opt)
	local world = { boxes = { { v(-40, -5, -300), v(40, 0, 2000) } } }
	local vy, speed = opt.pop, opt.speed
	local t_air = 2 * vy / G
	local cycle = t_air + 1.6
	local function pose(t)
		local u = t % cycle
		local z = speed * t
		if u < 1.6 then return v(0, HIP, z), v(0, 0, speed), 100, 0 end
		u -= 1.6
		local y, w = ballistic(HIP, vy, u)
		return v(0, y, z), v(0, w, speed), u < 0.08 and 200 or 201, 0
	end
	return { world = world, pose = pose, duration = cycle * 3, warm = 1.0 }
end

-- A big drop onto a downslope: long air, fast fall, landing on a slope like the live 3 s airs.
local function route_mega(opt)
	local speed, vy, slope = opt.speed, opt.pop, opt.slope
	local z_pop, y_land = 20, -opt.drop
	local g = G
	local t_air = (vy + math.sqrt(vy * vy + 2 * g * opt.drop)) / g
	local z_land = z_pop + speed * t_air
	local prof = { { -200, 0 }, { z_pop, 0 }, { z_pop + 0.01, -3 }, { z_land - 6, y_land + 6 * slope }, { z_land, y_land }, { z_land + 60 , y_land - 60 * slope }, { z_land + 60.1, y_land - 60 * slope - 5 }, { z_land + 800, y_land - 60 * slope - 5 } }
	local world = { profile = prof }
	local t_pop = z_pop / speed
	local rest = 3.0
	local cycle = t_pop + t_air + rest
	local c, sn = 1 / math.sqrt(1 + slope * slope), slope / math.sqrt(1 + slope * slope)
	local function pose(t)
		t = t % cycle
		if t < t_pop then return v(0, HIP, speed * t), v(0, 0, speed), 100, 0 end
		t -= t_pop
		if t < t_air then
			local y, w = ballistic(HIP, vy, t)
			return v(0, y, z_pop + speed * t), v(0, w, speed), t < 0.08 and 200 or 201, 0
		end
		t -= t_air
		local run = (speed + 3) * t
		return v(0, y_land + HIP - run * sn, z_land + run * c), v(0, -sn, c) * (speed + 3), 100, 0
	end
	return { world = world, pose = pose, duration = cycle * 2, warm = 1.0, teleports = true }
end

-- Riding down a straight hill between two flats, optionally over rollers or carving across the fall line.
local function route_hill(opt)
	local deg, length, speed = math.rad(opt.deg), opt.length or 45, opt.speed
	local z0, z1, grade = 20, 20 + length, math.tan(deg)
	local wave, amp = opt.wave or 2.5, opt.roll or 0
	local function height(z)
		if z <= z0 then return 0 end
		local u = math.min(z, z1) - z0
		local fade = math.clamp(math.min(u, z1 - math.min(z, z1)) / 2, 0, 1)
		local rise = -u * grade
		if z > z1 then return -length * grade end
		return rise + amp * fade * math.sin(2 * math.pi * u / wave)
	end
	local prof = { { -200, 0 } }
	for z = z0 - 0.5, z1 + 0.5, 0.2 do prof[#prof + 1] = { z, height(z) } end
	prof[#prof + 1] = { 900, height(z1 + 1) }
	local total = (z1 + 24) / speed
	local weave = (opt.carve or 0)
	local function pose(t)
		local z = speed * t
		local e, y = 0.04, height(z)
		local dy = (height(z + e) - height(z - e)) / (2 * e)
		local n = vector.normalize(v(0, 1, -dy))
		local x, dx = weave * math.sin(1.5 * t), weave * 1.5 * math.cos(1.5 * t)
		return v(x, y, z) + n * HIP, v(dx, dy * speed, speed), 100, math.atan2(dx, speed)
	end
	return { world = { profile = prof }, pose = pose, duration = total, warm = 1.0 }
end

-- A trick from a kicker onto a hill: long air, a landing into the fall line (or across it), then the run-out.
-- `bank` stands a wall beside the run, so the sideways way out is blocked as well as the way behind.
local function route_land(opt)
	local deg, speed, cross = math.rad(opt.deg), opt.speed, math.rad(opt.cross or 0)
	local vy, drop = opt.pop, opt.drop
	local z_pop, g = 25, 10.1 -- the game's measured gravity, so the landing prediction is as good as it is in play
	local t_air = (vy + math.sqrt(vy * vy + 2 * g * drop)) / g
	local vz, vx = speed * math.cos(cross), speed * math.sin(cross)
	local z_land, grade = z_pop + vz * t_air, math.tan(deg)
	local run_len = opt.length or 55
	local z_end = z_land + run_len * math.cos(deg)
	local y_land, y_end = -drop, -drop - run_len * math.sin(deg)
	local prof = { { -200, 0 }, { z_pop, 0 }, { z_pop + 0.01, -3 }, { z_land - 8, y_land + 8 * grade }, { z_land, y_land }, { z_end, y_end }, { z_end + 500, y_end } }
	local world = { profile = prof }
	if opt.bank then
		world.boxes = {}
		local z = z_land - 6
		while z < z_end do
			local top = y_land - (z - z_land) * grade + 3.5
			world.boxes[#world.boxes + 1] = { v(opt.bank, -500, z), v(opt.bank + 3, top, z + 1) }
			z += 1
		end
	end
	local t_pop = z_pop / vz
	local c, sn = math.cos(deg), math.sin(deg)
	local after = speed + 3
	local t_slope = run_len / after
	local flat_time = 3.0
	local x_air = vx * t_air
	local head = math.atan2(vx, vz)
	local function pose(t)
		if t < t_pop then return v(vx * t, HIP, vz * t), v(vx, 0, vz), 100, head end
		t -= t_pop
		if t < t_air then
			return v(vx * (t_pop + t), HIP + vy * t - 0.5 * g * t * t, z_pop + vz * t), v(vx, vy - g * t, vz), t < 0.08 and 200 or 201, head
		end
		t -= t_air
		local x0 = vx * t_pop + x_air
		local fx, fz = math.sin(cross), math.cos(cross)
		if t < t_slope then
			local dir = vector.normalize(v(fx, -fz * grade, fz))
			local base = v(x0, y_land, z_land) + dir * (after * t)
			return base + v(0, c, sn) * HIP, dir * after, 100, head
		end
		t -= t_slope
		local dir = vector.normalize(v(fx, -fz * grade, fz))
		local foot = v(x0, y_land, z_land) + dir * (after * t_slope)
		return v(foot.x + vx * t, y_end + HIP, foot.z + vz * t), v(vx, 0, vz), 100, head
	end
	return { world = world, pose = pose, duration = t_pop + t_air + t_slope + flat_time, warm = 1.0, settings = opt.settings }
end

-- A polyline walker for riding a surface: pts are {z, y}; s is arclength; returns the point and its upward normal.
local function walker(pts)
	local cum, total = { 0 }, 0
	for i = 2, #pts do
		total += math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2)
		cum[i] = total
	end
	return function(s)
		s = math.clamp(s, 0, total)
		local i = 2
		while i < #pts and cum[i] < s do i += 1 end
		local len = math.max(cum[i] - cum[i - 1], 1e-6)
		local u = (s - cum[i - 1]) / len
		local z1, y1, z2, y2 = pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]
		local tz, ty = (z2 - z1) / len, (y2 - y1) / len
		return z1 + (z2 - z1) * u, y1 + (y2 - y1) * u, -ty, tz, tz, ty
	end, total
end

-- Mega-ramp landing: a 10-14 m drop, about 3 s of air at 13-17 m/s, onto the steep face of a landing ramp that curves out to
-- flat ground. The rider lands on the face, rides down it at `after`, through the transition arc and out onto the flat.
-- opt: speed, drop, t_air, deg (face angle), radius (run-out arc), top_off (m of face above the landing point), below (m of
-- face below it), wall (x of a wall beside the run), after (speed on the face), settings.
local function route_bigland(opt)
	local g = 10.1
	local speed, drop, t_air, deg = opt.speed, opt.drop, opt.t_air, math.rad(opt.deg)
	local R, top_off, below = opt.radius or 9, opt.top_off or 5, opt.below or 8
	local after = opt.after or (speed + 2)
	local z_pop = 25
	local vy = (-drop + 0.5 * g * t_air * t_air) / t_air
	local zl, yl = z_pop + speed * t_air, HIP - drop -- the root at touchdown
	local c, sn = math.cos(deg), math.sin(deg)
	local s0z, s0y = zl - HIP * sn, yl - HIP * c -- the surface point under it
	local kz, ky = s0z - top_off * c, s0y + top_off * sn -- the knuckle
	local az, ay = s0z + below * c, s0y - below * sn -- where the straight face ends
	local cz, cy = az + R * sn, ay + R * c -- arc centre
	local y_flat = cy - R
	local face = { { kz, ky }, { s0z, s0y }, { az, ay } }
	for i = 1, 24 do
		local phi = -deg + deg * i / 24
		face[#face + 1] = { cz + R * math.sin(phi), cy - R * math.cos(phi) }
	end
	face[#face + 1] = { cz + 400, y_flat }
	local prof = { { -200, 0 }, { z_pop, 0 }, { z_pop + 0.01, y_flat }, { kz - 0.01, y_flat } }
	for _, p in face do prof[#prof + 1] = p end
	local world = { profile = prof }
	if opt.wall then
		local x0, x1 = opt.wall, opt.wall + 3 -- a negative wall stands on the left, the side the trick swing goes to
		if opt.wall < 0 then x0, x1 = opt.wall - 3, opt.wall end
		world.boxes = { { v(x0, y_flat - 1, kz - 8), v(x1, ky + 14, cz + 40) } }
	end
	local path = {}
	for i = 2, #face do path[#path + 1] = face[i] end
	local ride = walker(path)
	local t_pop = z_pop / speed
	local function pose(t)
		if t < t_pop then return v(0, HIP, speed * t), v(0, 0, speed), 100, 0 end
		t -= t_pop
		if t < t_air then
			return v(0, HIP + vy * t - 0.5 * g * t * t, z_pop + speed * t), v(0, vy - g * t, speed), t < 0.08 and 200 or 201, 0
		end
		t -= t_air
		local z, y, nz, ny, tz, ty = ride(after * t)
		-- the walker starts at the surface point; the root stands HIP along the normal
		return v(0, y + ny * HIP, z + nz * HIP), v(0, ty * after, tz * after), 100, 0
	end
	return { world = world, pose = pose, duration = t_pop + t_air + 4.5, warm = 1.0, settings = opt.settings }
end

-- #204: air of 0.72 s that ends on a deck 6.4 m above the take-off, much higher than any prediction from the arc.
-- The deck's front face is a wall between the eye (behind and low) and the rider.
local function route_platform(opt)
	local g = 10.1
	local speed, rise, t_air = opt.speed, opt.rise, opt.t_air
	local z_pop = 25
	local vy = (rise + 0.5 * g * t_air * t_air) / t_air
	local zl = z_pop + speed * t_air
	local deck_top = rise
	local edge = zl - (opt.edge_back or 0.6)
	local world = { boxes = { { v(-40, -5, -300), v(40, 0, z_pop) }, { v(-40, -5, edge), v(40, deck_top, edge + 60) } } }
	if opt.wall then world.boxes[#world.boxes + 1] = { v(opt.wall, -5, edge - 10), v(opt.wall + 3, deck_top + 8, edge + 60) } end
	local t_pop = z_pop / speed
	local function pose(t)
		if t < t_pop then return v(0, HIP, speed * t), v(0, 0, speed), 100, 0 end
		t -= t_pop
		if t < t_air then
			return v(0, HIP + vy * t - 0.5 * g * t * t, z_pop + speed * t), v(0, vy - g * t, speed), t < 0.08 and 200 or 201, 0
		end
		t -= t_air
		return v(0, deck_top + HIP, zl + speed * t), v(0, 0, speed), 100, 0
	end
	return { world = world, pose = pose, duration = t_pop + t_air + 3.5, warm = 1.0, settings = opt.settings }
end

-- #204 again, with a launch ramp: the rider climbs a ramp, leaves its lip and lands 0.72 s later on a deck far above the lip.
local function route_deckramp(opt)
	local g = 10.1
	local speed, deg, t_air = opt.speed, math.rad(opt.deg), opt.t_air
	local z0, run = 25, opt.run or 6
	local c, sn = math.cos(deg), math.sin(deg)
	local lip_z, lip_y = z0 + run * c, run * sn
	local vz, vy = speed * c, speed * sn
	local zl = lip_z + vz * t_air
	local y_root = lip_y + HIP * c + vy * t_air - 0.5 * g * t_air * t_air
	local deck_top = y_root - HIP
	local edge = zl - (opt.edge_back or 0.6)
	local world = { profile = { { -200, 0 }, { z0, 0 }, { lip_z, lip_y }, { lip_z + 0.01, -5 }, { lip_z + 50, -5 } },
		boxes = { { v(-40, -5, edge), v(40, deck_top, edge + 60) } } }
	if opt.wall then
		local x0, x1 = opt.wall, opt.wall + 3
		if opt.wall < 0 then x0, x1 = opt.wall - 3, opt.wall end
		world.boxes[#world.boxes + 1] = { v(x0, -5, edge - 10), v(x1, deck_top + 8, edge + 60) }
	end
	local t_ramp = z0 / speed
	local t_up = run / speed
	local function pose(t)
		if t < t_ramp then return v(0, HIP, speed * t), v(0, 0, speed), 100, 0 end
		t -= t_ramp
		if t < t_up then
			return v(0, speed * sn * t + HIP * c, z0 + speed * c * t), v(0, vy, vz), 100, 0
		end
		t -= t_up
		if t < t_air then
			return v(0, lip_y + HIP * c + vy * t - 0.5 * g * t * t, lip_z + vz * t), v(0, vy - g * t, vz), t < 0.08 and 200 or 201, 0
		end
		t -= t_air
		return v(0, deck_top + HIP, zl + speed * t), v(0, 0, speed), 100, 0
	end
	return { world = world, pose = pose, duration = t_ramp + t_up + t_air + 3.5, warm = 1.0, settings = opt.settings }
end

local POP_ON = { trick_pop = true }
local NO_TRICK = { trick_yaw = false }
local POP_NO_TRICK = { trick_pop = true, trick_yaw = false }
local ROUTES = {
	{ "bigland_50", route_bigland, { speed = 15, drop = 12, t_air = 3.0, deg = 50 } },
	{ "bigland_50_pop", route_bigland, { speed = 15, drop = 12, t_air = 3.0, deg = 50, settings = POP_ON } },
	{ "bigland_50_notrick", route_bigland, { speed = 15, drop = 12, t_air = 3.0, deg = 50, settings = NO_TRICK } },
	{ "bigland_50_pop_notrick", route_bigland, { speed = 15, drop = 12, t_air = 3.0, deg = 50, settings = POP_NO_TRICK } },
	{ "bigland_60_pop", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 60, radius = 7, settings = POP_ON } },
	{ "bigland_60", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 60, radius = 7 } },
	{ "bigland_40_pop", route_bigland, { speed = 13, drop = 10, t_air = 3.0, deg = 40, settings = POP_ON } },
	{ "bigland_50_wall", route_bigland, { speed = 15, drop = 12, t_air = 3.0, deg = 50, wall = 1.8 } },
	{ "bigland_50_wall_pop", route_bigland, { speed = 15, drop = 12, t_air = 3.0, deg = 50, wall = 1.8, settings = POP_ON } },
	{ "bigland_60_wall_pop", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 60, radius = 7, wall = 1.5, settings = POP_ON } },
	{ "bigland_50_wall_notrick", route_bigland, { speed = 15, drop = 12, t_air = 3.0, deg = 50, wall = 1.8, settings = NO_TRICK } },
	{ "bigland_60_notrick", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 60, radius = 7, settings = NO_TRICK } },
	{ "bigland_55", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 55, radius = 7 } },
	{ "bigland_65", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 65, radius = 7 } },
	{ "bigland_60_slow", route_bigland, { speed = 13, drop = 12.1, t_air = 3.02, deg = 60, radius = 7 } },
	{ "bigland_60_wallL", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 60, radius = 7, wall = -0.9 } },
	{ "bigland_60_wallL_pop", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 60, radius = 7, wall = -0.9, settings = POP_ON } },
	{ "bigland_60_wallR_notrick", route_bigland, { speed = 16.6, drop = 12.1, t_air = 3.02, deg = 60, radius = 7, wall = 0.7, settings = NO_TRICK } },
	{ "bigland_deckramp_45", route_deckramp, { speed = 14, deg = 45, t_air = 0.72 } },
	{ "bigland_deckramp_45_pop", route_deckramp, { speed = 14, deg = 45, t_air = 0.72, settings = POP_ON } },
	{ "bigland_deckramp_55_pop", route_deckramp, { speed = 15, deg = 55, t_air = 0.72, settings = POP_ON } },
	{ "bigland_deckramp_55_wall", route_deckramp, { speed = 15, deg = 55, t_air = 0.72, wall = -0.9 } },
	{ "bigland_deck_slow", route_platform, { speed = 8, rise = 6.36, t_air = 0.72, edge_back = 1.5, settings = POP_ON } },
	{ "bigland_deck_slow_off", route_platform, { speed = 8, rise = 6.36, t_air = 0.72, edge_back = 1.5 } },
	{ "bigland_deck_far", route_platform, { speed = 16, rise = 6.36, t_air = 0.72, edge_back = 3.0, wall = -1.0 } },
	{ "bigland_deck", route_platform, { speed = 14, rise = 6.36, t_air = 0.72 } },
	{ "bigland_deck_pop", route_platform, { speed = 14, rise = 6.36, t_air = 0.72, settings = POP_ON } },
	{ "bigland_deck_wall_pop", route_platform, { speed = 14, rise = 6.36, t_air = 0.72, wall = 2.2, settings = POP_ON } },
	{ "land_30", route_land, { deg = 30, speed = 15, pop = 6, drop = 5 } },
	{ "land_30_pop", route_land, { deg = 30, speed = 15, pop = 6, drop = 5, settings = POP_ON } },
	{ "land_40_pop", route_land, { deg = 40, speed = 15, pop = 6, drop = 5, settings = POP_ON } },
	{ "land_30_cross_pop", route_land, { deg = 30, speed = 15, pop = 6, drop = 5, cross = 30, settings = POP_ON } },
	{ "land_40_cross_pop", route_land, { deg = 40, speed = 15, pop = 6, drop = 5, cross = 40, settings = POP_ON } },
	{ "land_30_bank_pop", route_land, { deg = 30, speed = 15, pop = 6, drop = 5, bank = 2.2, settings = POP_ON } },
	{ "land_40_bank_pop", route_land, { deg = 40, speed = 15, pop = 6, drop = 5, bank = 2.2, settings = POP_ON } },
	{ "land_40_bank", route_land, { deg = 40, speed = 15, pop = 6, drop = 5, bank = 2.2 } },
	{ "hill_15", route_hill, { deg = 15, speed = 12 } },
	{ "hill_25", route_hill, { deg = 25, speed = 12 } },
	{ "hill_35", route_hill, { deg = 35, speed = 11 } },
	{ "hill_25_roll", route_hill, { deg = 25, speed = 12, roll = 0.10, wave = 2.5 } },
	{ "hill_35_roll", route_hill, { deg = 35, speed = 11, roll = 0.14, wave = 3.0 } },
	{ "hill_25_carve", route_hill, { deg = 25, speed = 12, carve = 3.0 } },
	{ "mega_10m", route_mega, { speed = 14, pop = 5, drop = 8, slope = 0.5 } },
	{ "mega_15m", route_mega, { speed = 17, pop = 6, drop = 13, slope = 0.7 } },
	{ "flatpop_low", route_flat_pop, { pop = 3.5, speed = 7 } },
	{ "flatpop_big", route_flat_pop, { pop = 6.5, speed = 9 } },
	{ "vert_3m", route_vert, { radius = 3.0, speed = 8.5, pop = 6.5 } },
	{ "vert_4m", route_vert, { radius = 4.0, speed = 10, pop = 8 } },
	{ "vert_low_air", route_vert, { radius = 3.0, speed = 7.5, pop = 3.0 } },
	{ "vert_ledge", route_vert, { radius = 3.0, speed = 8.5, pop = 6.5, ledge = { 4, 0.6 } } },
	{ "vert_3m_pop", route_vert, { radius = 3.0, speed = 8.5, pop = 6.5, settings = POP_ON } },
	{ "vert_4m_pop", route_vert, { radius = 4.0, speed = 10, pop = 8, settings = POP_ON } },
	{ "qp_big", route_vert, { radius = 6.0, speed = 15, pop = 14.8 } },
	{ "qp_big_pop", route_vert, { radius = 6.0, speed = 15, pop = 14.8, settings = POP_ON } },
	{ "halfpipe_20_high", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, settings = { high = true, crouch = false } } },
	{ "halfpipe_20_low", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, settings = { crouch = false } } },
	{ "halfpipe_15_high", route_halfpipe, { radius = 4, flat = 7, speed = 14.6, pop = 13.5, settings = { high = true, crouch = false } } },
	{ "halfpipe_25_high", route_halfpipe, { radius = 4, flat = 7, speed = 25, pop = 24.5, settings = { high = true, crouch = false } } },
	{ "halfpipe_20_high_pop", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, settings = { high = true, trick_pop = true } } },
	{ "halfpipe_20_high_fakie", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, fakie = true, settings = { high = true, crouch = false } } },
	{ "halfpipe_20_high_cross20", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, cross = 20, settings = { high = true, crouch = false } } },
	{ "halfpipe_20_high_flip", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, flip = true, settings = { high = true, crouch = false } } },
	{ "halfpipe_20_high_spin540", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, spin = 540, settings = { high = true, crouch = false } } },
	{ "halfpipe_20_low_fakie", route_halfpipe, { radius = 4, flat = 7, speed = 20, pop = 21, fakie = true, settings = { crouch = false } } },
	{ "ledge_045", route_ledge, { height = 0.45, speed = 7, gap = 1.2, length = 8, half = 6 } },
	{ "ledge_100", route_ledge, { height = 1.0, speed = 7, gap = 1.2, length = 8, half = 6 } },
	{ "ledge_140", route_ledge, { height = 1.4, speed = 7, gap = 1.2, length = 8, half = 6 } },
	{ "edge_020", route_edge, { height = 0.20, speed = 6, amp = 0.25, rate = 0.5, edge = 0.5 } },
	{ "edge_030", route_edge, { height = 0.30, speed = 6, amp = 0.25, rate = 0.5, edge = 0.5 } },
	{ "edge_040", route_edge, { height = 0.40, speed = 6, amp = 0.06, rate = 1.5, edge = 0.25 } },
	{ "edge_055", route_edge, { height = 0.55, speed = 4, amp = 0.15, rate = 1.0, edge = 0.3 } },
	{ "curbs_low", route_curbs, { height = 0.15, pitch = 1.2, speed = 6 } },
	{ "curbs_mid", route_curbs, { height = 0.30, pitch = 2.0, speed = 7 } },
}

-- ------------------------------------------------------------------ hosts
-- stepped: the root moves only on physics steps. rendered: the root is interpolated to the render clock.
local HOSTS = { "stepped", "rendered" }
local ANIM_NAMES = { "none", "tuck", "sink" }
local RATES = { { 60, 0.12 }, { 144, 0.05 }, { 30, 0.05 }, { 240, 0.03 } }
if TRACE_ONLY_60 then RATES = { { 60, 0.12 } } end

local function profile_settings(extra)
	local s = Settings.defaults()
	s.follow.camera_style = "classic"
	s.follow.trick_pop = false
	s.follow.crouch_enabled = true
	s.follow.crouch_amount = 1
	s.follow.crouch_mode = 0
	s.angle = Settings.CameraAngle.Low
	s.ride_distance.mode = Settings.DistanceMode.Fixed
	s.ride_distance.fixed = 1.53
	-- Effects off: landing shake is intentional and tested separately. Anything left here is tracking.
	-- Effects stay on only for the landing-effect comparison run (fourth argument "fx").
	if not (arg and arg[4] == "fx") then
		s.shake_enabled = false
		s.native_plus.landing_dip = false
	end
	if extra and extra.trick_pop ~= nil then s.follow.trick_pop = extra.trick_pop end
	if extra and extra.trick_yaw ~= nil then s.trick_yaw.enabled = extra.trick_yaw end
	if extra and extra.crouch ~= nil then s.follow.crouch_enabled = extra.crouch end
	if extra and extra.high then
		s.angle = Settings.CameraAngle.High
		s.ride_distance_high.mode = Settings.DistanceMode.Fixed
		s.ride_distance_high.fixed = 2.40
	end
	return s
end

local function bit(n, b) return math.floor(n / b) % 2 == 1 end

-- The real root is an animated bone: it crouches before a pop, tucks away from the physics path in the air and absorbs a landing.
local ANIMS = {
	none = function() return 0 end,
	tuck = function(air, since_land, since_air)
		if air ~= nil then return 0.55 * math.clamp(air / 1.0, 0, 1) end
		return 0.55 * math.max(0, 1 - since_land / 0.08) - 0.28 * math.sin(math.clamp(since_land / 0.45, 0, 1) * math.pi)
	end,
	sink = function(air, since_land)
		if air ~= nil then return -0.55 * math.clamp(air / 1.0, 0, 1) end
		return -0.55 * math.max(0, 1 - since_land / 0.08) - 0.28 * math.sin(math.clamp(since_land / 0.45, 0, 1) * math.pi)
	end,
}
local TRACE = arg and arg[2] ~= "-" and arg[2] or nil
local DBG = arg and arg[5] and string.match(arg[5], "^dbg:([%d%.]+):([%d%.]+)$") and { tonumber(string.match(arg[5], "^dbg:([%d%.]+):")), tonumber(string.match(arg[5], ":([%d%.]+)$")) } or nil

local function run(route, host, fps, jitter, anim)
	local m = Mock.install({ limit_rays = true })
	m.reskate.input.gamepad = function() return nil end
	m.reskate.menu.game = function() return { open = false } end
	local app = require("app").start()
	assert(app.store:set_settings(profile_settings(route.settings)))
	m.state.raycast = make_ray(route.world)
	local epoch, phys_t, height, prev_vy = m.clock_ms, 0, 0, nil
	local t = 0
	local seed = 12345
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local out = { frames = 0, air = 0, airrev = 0, airhf = 0, airhfrel = 0, peakstep = 0, peakyaw = 0, peakpitch = 0,
		sweep = 0, floor = 0, restore = 0, hard = 0, guard = 0, pump = 0, pumpn = 0, rays = 0, errs = 0, minclear = 99,
		screen = 0, gnd_hf = 0, gnd_n = 0, lag = 0, recov = 0, recovmax = 0, stranded = 0,
		dist0 = 99, dist1 = 0, vpitch = 0, sy = 0, lift = 0, look = 0, pull = 0, liftstep = 0, off = 0, offland = 0, yawrev = 0, sx = 0, sidemax = 0,
		mindepth = 99, behind = 0, orbmax = 0, conframes = 0, rs = 0, rs_t = 0, rs_i = 0, ys = 0, ys_t = 0, ys_i = 0, yc = 0, yc_t = 0, yc_i = 0, hz = 99, hz_t = 0, hz_i = 0 }
	local core_yaw_prev, yaw_corr_prev
	local yaw_rate_prev
	local since_land
	local lift_prev
	local ys, rys, rel_prev, fwd_prev, prev_root = {}, {}, nil, nil, nil
	local history = {}
	local air_start, land_at
	local animate = ANIMS[anim or "none"]
	local last = {}
	do
		local g, orig = app.glue, app.glue.trace_camera_frame
		g.trace_camera_frame = function(self, now, original, base, after, final, cause, a, b, c, d)
			last.original, last.base, last.after, last.final, last.cause = original, base, after, final, cause
			if orig then return orig(self, now, original, base, after, final, cause, a, b, c, d) end
		end
	end
	out.snaps, out.snapmax = 0, 0
	local recovering_for = 0
	local skip_until = -1
	local was_air_frame, dip_ref, dip_until = false, nil, 0
	out.dip = 0
	local last_air_frame = -1000
	local n = math.floor(route.duration * fps)
	for i = 1, n do
		local dt = (1 / fps) * (1 + (rnd() * 2 - 1) * jitter)
		t += dt
		local steps = 0
		while phys_t + PHYS <= t + 1e-9 do
			phys_t += PHYS
			steps += 1
			local _, pv = route.pose(phys_t)
			m.fire("physics_step", { at = epoch + phys_t * 1000, seconds = PHYS, velocity = { pv.x, pv.y, pv.z }, ragdoll = false })
		end
		local sample = host == "stepped" and phys_t or t
		local root, vel, state, heading = route.pose(sample)
		do
			local is_air = AIR[state] == true
			if is_air then
				air_start = air_start or sample
				land_at = nil
			elseif air_start then
				air_start, land_at = nil, sample
			end
			local offset = animate(air_start and (sample - air_start) or nil, land_at and (sample - land_at) or 99)
			root += v(0, offset, 0)
		end
		m.state.skater.position = root
		m.state.skater.heading = heading
		m.state.skater.airborne = AIR[state] == true
		m.state.telemetry.physics_state = state
		m.state.telemetry.airborne = AIR[state] == true
		m.state.telemetry.position = root
		m.state.telemetry.heading = math.deg(heading)
		m.state.board.deck = { position = root - v(0, 0.6, 0), rotation = { 0, 0, 0, 1 } }
		m.state.board.velocity = vel
		m.tick(dt * 1000)
		local g = app.glue
		local shown = m.last_call("set")
		local rays = m.state.raycasts
		out.rays = math.max(out.rays, rays)
		m.state.raycasts = 0
		-- A route that loops teleports the rider: a legitimate cut that must not count as camera motion.
		if prev_root and mag(root - prev_root) > 3 then
			skip_until = t + 0.75
			rel_prev, fwd_prev = nil, nil
			ys, rys, history = {}, {}, {}
			air_start, land_at = nil, nil
			recovering_for = 0
		end
		if TRACE and shown and t > route.warm and last.final then
			local d = g.frame and g.frame.debug or {}
			print(string.format("F	%.4f	%d	%x	%d	r=%.3f	orig=%.3f	after=%.3f	fin=%.3f	z=%.3f	cz=%.3f	cause=%s	steps=%s	gs=%.3f	ph=%s",
				t, state, g.display_flags or 0, g.guard.smoothing and 1 or 0, root.y, last.original.y, last.after.y, last.final.y,
				last.final.z, last.original.z, tostring(last.cause), tostring(d.steps), g.guard.subject and g.guard.subject.y or 0, tostring(g.snap.physical_height))
				.. string.format("	w=%.3f	pw=%.3f	vw=%.3f	py=%s	rs=%s	reason=%s	shot=%s", d.terrain_weight or -1, d.pop_height_weight or -1, d.pop_vertical_weight or -1, tostring(d.pop_anchor_y), tostring(g.root_render_sampled), tostring(d.terrain_reason), tostring(d.shot_name))
				.. string.format("	pull=%.3f	lift=%.1f	look=%.1f	dist=%.2f	elev=%.1f	inc=%.1f	ny=%.3f	trans=%s", d.collision_pull or 0, math.deg(d.downhill_lift or 0), math.deg(d.look_pitch_offset or 0), mag(shown.position - root), math.deg(d.elevation or 0), d.incline_degrees or 0, g.snap.ground_normal and g.snap.ground_normal.y or 0, tostring(g.cam.transition))
					.. string.format("	side=%.1f	orb=%.1f	con=%s	up=%s	rise=%s	blk=%s	sw=%s", math.deg(d.ramp_side or 0), g.cam.adaptive_orbit and math.deg(g.cam.adaptive_orbit.yaw or 0) or 0, tostring(g.cam.adaptive_orbit and g.cam.adaptive_orbit.constrained), tostring(g.cam.transition_up_seen), tostring(g.cam.downhill_rise), tostring(g.cam.ramp_blocked), tostring(g.cam.swing))
					.. (function()
						local f2 = shown.forward
						local cy = g.frame and g.frame.back and math.deg(math.atan2(-g.frame.back.x, -g.frame.back.z)) or 0
						local rl, orl = shown.position - root, last.original - root
						return string.format("	i=%d	yaw=%.2f	cyaw=%.2f	rx=%.3f	ry=%.3f	rz=%.3f	hd=%.3f	ox=%.3f	oy=%.3f	oz=%.3f",
							i, math.deg(math.atan2(f2.x, f2.z)), cy, rl.x, rl.y, rl.z, math.sqrt(rl.x * rl.x + rl.z * rl.z), orl.x, orl.y, orl.z)
					end)())
		end
		-- Optional: arg[5] = "dbg:<t0>:<t1>" dumps every debug field and stage position of the frames inside [t0, t1].
		if DBG and shown and t >= DBG[1] and t <= DBG[2] then
			local d = g.frame and g.frame.debug or {}
			local keys = {}
			for k, val in d do if type(val) == "number" or type(val) == "boolean" or type(val) == "string" then keys[#keys + 1] = k end end
			table.sort(keys)
			local parts = {}
			for _, k in keys do parts[#parts + 1] = k .. "=" .. (type(d[k]) == "number" and string.format("%.4g", d[k]) or tostring(d[k])) end
			local function rel(p_) return p_ and string.format("(%.3f,%.3f,%.3f)", p_.x - root.x, p_.y - root.y, p_.z - root.z) or "nil" end
			print(string.format("D	%.4f	root=%s	orig=%s	base=%s	after=%s	final=%s	%s", t, rel(root), rel(last.original), rel(last.base), rel(last.after), rel(last.final), table.concat(parts, " ")))
		end
		if last.cause == "position" and t > route.warm and t > skip_until then out.snaps += 1 end
		last.cause = nil
		if shown and g.source == "ride" and g.blend >= 1 and t > route.warm and t > skip_until then
			out.frames += 1
			local p, f = shown.position, shown.forward
			local rel = p - root
			local air = AIR[state] == true
			local flags = g.display_flags or 0
			if bit(flags, 4) then out.sweep += 1 end
			if bit(flags, 8) then out.floor += 1 end
			if bit(flags, 16) then out.restore += 1 end
			if bit(flags, 1) then out.hard += 1 end
			if bit(flags, 2) then out.guard += 1 end
			out.errs = g.errors + g.ray_errors
			if rel_prev then
				local step = mag(rel - rel_prev) * (dt * 60 < 1 and 1 or 1 / (dt * 60))
				out.peakstep = math.max(out.peakstep, step)
				local yaw0, yaw1 = math.atan2(fwd_prev.x, fwd_prev.z), math.atan2(f.x, f.z)
				local dyaw = math.abs((yaw1 - yaw0 + math.pi) % (2 * math.pi) - math.pi)
				local dpitch = math.abs(math.asin(math.clamp(f.y, -1, 1)) - math.asin(math.clamp(fwd_prev.y, -1, 1)))
				local scale = dt * 60 < 1 and 1 or 1 / (dt * 60)
				out.peakyaw = math.max(out.peakyaw, math.deg(dyaw) * scale)
				out.peakpitch = math.max(out.peakpitch, math.deg(dpitch) * scale)
			end
				-- Raw per-frame steps (not scaled to 60 Hz): eye relative to the rider, shown yaw, shown-minus-core yaw.
				do
					local cy
					if g.frame and g.frame.back then cy = math.atan2(-g.frame.back.x, -g.frame.back.z) end
					local sy_ = math.atan2(f.x, f.z)
					if rel_prev then
						local st = mag(rel - rel_prev)
						if st > out.rs then out.rs, out.rs_t, out.rs_i = st, t, i end
						local ds = math.deg(math.abs((sy_ - math.atan2(fwd_prev.x, fwd_prev.z) + math.pi) % (2 * math.pi) - math.pi))
						if ds > out.ys then out.ys, out.ys_t, out.ys_i = ds, t, i end
					end
					if cy then
						local corr = math.deg((sy_ - cy + math.pi) % (2 * math.pi) - math.pi)
						if yaw_corr_prev then
							local dc = math.abs((corr - yaw_corr_prev + 180) % 360 - 180)
							if dc > out.yc then out.yc, out.yc_t, out.yc_i = dc, t, i end
						end
						yaw_corr_prev = corr
					end
					local hd = math.sqrt(rel.x * rel.x + rel.z * rel.z)
					if hd < out.hz then out.hz, out.hz_t, out.hz_i = hd, t, i end
				end
			-- Clearance: distance of the eye above whatever is directly below.
			do
				local probe = make_ray(route.world)(p + v(0, 0.02, 0), p - v(0, 3, 0))
				if probe then out.minclear = math.min(out.minclear, p.y - probe.y) end
			end
			ys[#ys + 1] = p.y
			rys[#rys + 1] = rel.y
			local k = #ys
			if air then
				if not was_air_frame then dip_ref = nil end
				last_air_frame = i
			elseif was_air_frame then
				dip_ref, dip_until = rel.y, t + 0.6
			end
			was_air_frame = air
			if dip_ref and t <= dip_until then out.dip = math.max(out.dip, dip_ref - rel.y) end
			if k >= 4 then
				-- Third difference of height per frame, at equal spacing: a parabola gives zero and a sine almost
				-- zero, while a zig-zag of amplitude a gives about 8a. Scaled to mm for the table.
				local hf = math.abs(ys[k] - 3 * ys[k - 1] + 3 * ys[k - 2] - ys[k - 3])
				local hfr = math.abs(rys[k] - 3 * rys[k - 1] + 3 * rys[k - 2] - rys[k - 3])
				local a, b = ys[k] - ys[k - 1], ys[k - 1] - ys[k - 2]
				if air then
					out.air += 1
					out.airhf = math.max(out.airhf, hf)
					out.airhfrel = math.max(out.airhfrel, hfr)
					if a * b < 0 and math.abs(a) > 0.0015 and math.abs(b) > 0.0015 then out.airrev += 1 end
				elseif i - last_air_frame > fps * 0.8 then
					out.gnd_n += 1
					out.gnd_hf = math.max(out.gnd_hf, hfr)
					if a * b < 0 and math.abs(a) > 0.0015 and math.abs(b) > 0.0015 then out.pumpn += 1 end
				end
			end
			-- Pump: largest up-down excursion of eye height (rider-relative) inside any 0.5 s ground window.
			if not air then
				history[#history + 1] = rel.y
				local w = math.max(4, math.floor(fps * 0.5))
				if #history > w then table.remove(history, 1) end
				if i - last_air_frame > fps * 0.8 then
					local lo, hi = 1e9, -1e9
					for _, y in history do lo, hi = math.min(lo, y), math.max(hi, y) end
					out.pump = math.max(out.pump, hi - lo)
				end
			else history = {} end
			-- Framing: rider must stay inside the frame.
			local depth = vector.dot(root - p, f)
			if g.cam and g.cam.adaptive_orbit and g.cam.adaptive_orbit.constrained then out.conframes += 1 end
			if g.cam and g.cam.adaptive_orbit then out.orbmax = math.max(out.orbmax, math.abs(math.deg(g.cam.adaptive_orbit.yaw or 0))) end
			out.mindepth = math.min(out.mindepth, depth)
			if depth <= 0.3 then out.behind += 1 end
			if depth > 0.05 then
				local right = vector.normalize(vector.cross(f, shown.up))
				local half = math.tan(math.rad(shown.fov or 65) * 0.5)
				local sx, sy = vector.dot(root - p, right) / (depth * half), vector.dot(root - p, shown.up) / (depth * half)
				out.screen = math.max(out.screen, math.max(math.abs(sx) / 1.78, math.abs(sy)))
			end
				out.lag = math.max(out.lag, mag(v(rel.x, 0, rel.z)))
				-- Off-axis: how far round from straight behind the travel direction the eye is on the ground.
				do
					local fl, vl = math.sqrt(rel.x * rel.x + rel.z * rel.z), math.sqrt(vel.x * vel.x + vel.z * vel.z)
					if not air and fl > 0.5 and vl > 1 then -- an eye nearly overhead has no meaningful side
						local cs = -(rel.x * vel.x + rel.z * vel.z) / (fl * vl)
						local off = math.deg(math.acos(math.clamp(cs, -1, 1)))
						out.off = math.max(out.off, off)
						since_land = since_land or 0
						if since_land < 2.5 then out.offland = math.max(out.offland, off) end
						since_land += dt
					end
					if air then since_land = 0 end
					local dd = g.frame and g.frame.debug or {}
					local cam = g.cam
					out.sidemax = math.max(out.sidemax, math.deg(math.abs(dd.ramp_side or 0)), cam.adaptive_orbit and math.deg(math.abs(cam.adaptive_orbit.yaw or 0)) or 0)
					if depth > 0.05 and not air then
						local right = vector.normalize(vector.cross(f, shown.up))
						out.sx = math.max(out.sx, math.abs(vector.dot(root - p, right) / (depth * math.tan(math.rad(shown.fov or 65) * 0.5)) / 1.78))
					end
				end
				if fwd_prev and not air then
					local y0, y1 = math.atan2(fwd_prev.x, fwd_prev.z), math.atan2(f.x, f.z)
					local rate = ((y1 - y0 + math.pi) % (2 * math.pi) - math.pi) / math.max(dt, 1e-4)
					if yaw_rate_prev and rate * yaw_rate_prev < 0 and math.abs(rate) > math.rad(25) and math.abs(yaw_rate_prev) > math.rad(25) then out.yawrev += 1 end
					yaw_rate_prev = rate
				elseif air then yaw_rate_prev = nil end
				if not air then
					out.dist0, out.dist1 = math.min(out.dist0, mag(rel)), math.max(out.dist1, mag(rel))
					out.vpitch = math.min(out.vpitch, math.deg(math.asin(math.clamp(f.y, -1, 1))))
					if depth > 0.05 then
						local half = math.tan(math.rad(shown.fov or 65) * 0.5)
						out.sy = math.max(out.sy, math.abs(vector.dot(root - p, shown.up) / (depth * half)))
					end
					local dd = g.frame and g.frame.debug or {}
					local lift = math.deg(dd.downhill_lift or 0)
					out.lift, out.look = math.max(out.lift, lift), math.min(out.look, math.deg(dd.look_pitch_offset or 0))
					out.pull = math.max(out.pull, dd.collision_pull or 0)
					if lift_prev then out.liftstep = math.max(out.liftstep, math.abs(lift - lift_prev)) end
					lift_prev = lift
				else lift_prev = nil end
			-- Recovery age: how long the guard stays in continuous recovery.
			if bit(flags, 2) then
				recovering_for += dt
				out.recovmax = math.max(out.recovmax, recovering_for)
			else recovering_for = 0 end
			rel_prev, fwd_prev = rel, f
		end
		prev_root = root
	end
	return out
end

local rows = {}
print(table.concat({ "route", "host", "fps", "frames", "airHFmm", "airHFrelmm", "airRev", "gndHFmm", "pumpcm", "gndRev", "stepcm", "yawdeg", "pitchdeg", "sweep", "floor", "restore", "hard", "guardpct", "recovS", "minclr", "screen", "maxback", "rays", "errs", "snaps", "anim", "dipcm", "dist0", "dist1", "vpitch", "sy", "liftdeg", "lookdeg", "pull", "liftstep", "offdeg", "offland", "yawrev", "sx", "sidemax", "relstep_m", "relstep_t", "relstep_i", "yawstep_deg", "yawstep_t", "yawstep_i", "ycorr_deg", "ycorr_t", "ycorr_i", "minhz", "minhz_t", "minhz_i", "mindepth", "behind", "orbmax", "conframes" }, "\t"))
for _, r in ROUTES do
	local name, build, opt = r[1], r[2], r[3]
	if filter == "" or (string.sub(filter, 1, 1) == "=" and name == string.sub(filter, 2)) or string.find(name, filter, 1, true) then
		for _, host in HOSTS do
			for _, anim in ANIM_NAMES do for _, rate in RATES do
				local o = run(build(opt), host, rate[1], rate[2], anim)
				print(table.concat({ name, host, rate[1], o.frames,
					string.format("%.2f", o.airhf * 1000), string.format("%.2f", o.airhfrel * 1000), o.airrev,
					string.format("%.2f", o.gnd_hf * 1000), string.format("%.2f", o.pump * 100), o.pumpn,
					string.format("%.2f", o.peakstep * 100), string.format("%.2f", o.peakyaw), string.format("%.2f", o.peakpitch),
					o.sweep, o.floor, o.restore, o.hard, string.format("%.1f", 100 * o.guard / math.max(o.frames, 1)),
					string.format("%.2f", o.recovmax), string.format("%.3f", o.minclear), string.format("%.2f", o.screen),
					string.format("%.2f", o.lag), o.rays, o.errs, o.snaps, anim, string.format("%.2f", o.dip * 100),
						string.format("%.2f", o.dist0), string.format("%.2f", o.dist1), string.format("%.1f", o.vpitch), string.format("%.2f", o.sy),
						string.format("%.1f", o.lift), string.format("%.1f", o.look), string.format("%.2f", o.pull), string.format("%.2f", o.liftstep),
							string.format("%.1f", o.off), string.format("%.1f", o.offland), o.yawrev, string.format("%.2f", o.sx), string.format("%.1f", o.sidemax),
						string.format("%.3f", o.rs), string.format("%.2f", o.rs_t), o.rs_i, string.format("%.2f", o.ys), string.format("%.2f", o.ys_t), o.ys_i,
						string.format("%.2f", o.yc), string.format("%.2f", o.yc_t), o.yc_i, string.format("%.3f", o.hz), string.format("%.2f", o.hz_t), o.hz_i,
						string.format("%.2f", o.mindepth), o.behind, string.format("%.1f", o.orbmax), o.conframes }, "\t"))
			end end
		end
	end
end
