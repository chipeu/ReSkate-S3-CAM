-- The landing bounce in the Full style and the landing kick that never moves toward the skater, with the real camera.
-- Port of test_landing_dip_full / test_landing_dip_keeps_ground_clearance (and the kick-distance check of test_landing_is_1_0_2) in
-- Engine/Game/Camera/Test/s3cam_layers_tests.cpp (the beta3 namespace).
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_landing_dip.lua
local T = require("tlib")
local Settings = require("settings")
local Camera = require("camera")
local Subject = require("subject")

T.group("landing_dip")
local expect = T.expect
local vc = vector.create
local abs, max, min, sqrt, asin, floor, ceil = math.abs, math.max, math.min, math.sqrt, math.asin, math.floor, math.ceil

local gravity = 10.1
local root_height = 0.95

-- A rider who hops (a little) and falls `drop` metres onto level ground, riding at 6 m/s along +Z (the C++ HopRider).
local function hop_rider(drop)
	local hop_height, air_begin = 0.05, 1.0
	local rise = sqrt(2.0 * hop_height / gravity)
	local fall = sqrt(2.0 * (hop_height + drop) / gravity)
	local air_time = rise + fall
	local function at(time)
		local s = Subject.new_snapshot()
		s.valid = true
		s.time = time
		s.velocity = vc(0, 0, 6)
		s.position = vc(0, root_height, 6 * time)
		s.ground_clearance = root_height
		local since = time - air_begin
		if since >= air_time then
			s.position = vc(0, root_height - drop, 6 * time)
		elseif since >= 0 then
			local vy0 = sqrt(2.0 * gravity * hop_height)
			s.position = vc(0, root_height + vy0 * since - 0.5 * gravity * since * since, 6 * time)
			s.velocity = vc(0, vy0 - gravity * since, 6)
			s.physics_state = Subject.physics_state.air
			s.ground_clearance = s.position.y + drop
		end
		return s
	end
	return at, air_begin + air_time
end

-- A level ground at y = -drop.
local function flat_world(ground_y)
	return function(from, to)
		if from.y >= ground_y and to.y < ground_y then
			local t = (ground_y - from.y) / (to.y - from.y)
			return from + (to - from) * t
		end
		return nil
	end
end

-- (The landing bounce is on by default: the runs say so, and turn it off where they compare.)
local function make_settings(configure)
	local cs = Settings.camera()
	cs.shake_enabled = false
	cs.native_plus.landing_dip = true
	if configure then configure(cs) end
	return cs
end

-- One run of 6 s at `fps` (60 unless said): every frame's position, view pitch (degrees, + looks up), debug and subject.
local function run(drop, cs, fps, rider_at, land_time)
	fps = fps or 60
	local at, land = hop_rider(drop)
	if rider_at then at, land = rider_at, land_time end
	local cam = Camera.new()
	expect(cam:set_settings(cs), "settings accepted")
	local world = flat_world(-drop)
	local r = { pos = {}, pitch = {}, dip = {}, impact = {}, frac = {}, subject = {}, fraction = 0.0, land = ceil(land * fps - 1e-3) }
	for i = 0, floor(6 * fps) - 1 do
		local s = at(i / fps)
		local f = cam:update(1 / fps, s, world, nil)
		r.pos[i + 1] = f.pos
		r.pitch[i + 1] = math.deg(asin(max(-1.0, min(1.0, -f.back.y))))
		r.dip[i + 1] = f.debug.landing_dip
		r.impact[i + 1] = f.debug.impact_y
		r.frac[i + 1] = f.debug.landing_fraction
		r.subject[i + 1] = s.position
		r.fraction = max(r.fraction, f.debug.landing_fraction)
	end
	return r
end

local function horizontal_to_root(r, i)
	local d = r.pos[i] - r.subject[i]
	return sqrt(d.x * d.x + d.z * d.z)
end

local function first_depth(d)
	for i = 1, #d do
		if d[i] > 1e-5 then return i end
	end
	return #d + 1
end

local stock = Settings.camera().native_plus
expect(stock.landing_dip == true, "landing bounce: on by default")
expect(abs(stock.dip_depth - 0.32) < 1e-9 and abs(stock.dip_peak_time - 0.18) < 1e-9, "landing bounce: 0.32 m deep, 0.18 s recovery by default")

-- The landing bounce builds over several frames, then eases out with one small rebound.
local on = make_settings()
local off = make_settings(function(cs) cs.native_plus.landing_dip = false end)
local recovery = on.native_plus.dip_peak_time
local curves = {}
for _, fps in { 30, 60, 144 } do
	curves[fps] = {}
	for _, drop in { 4.0, 1.5 } do
		local with, without = run(drop, on, fps), run(drop, off, fps)
		local d = with.dip
		local k0 = first_depth(d)
		local a = on.native_plus.dip_depth * min(with.fraction, 1.0) ^ 2
		local tag = "landing bounce (" .. drop .. " m drop at " .. fps .. " fps): "
		expect(a > 0.02 and k0 <= #d, tag .. "the landing is hard enough to bounce")
		if k0 <= #d then
			local by_035, by_16, peak, kp, rebound, rebound_at = 0.0, 0.0, 0.0, k0, 0.0, 0.0
			for i = k0, #d do
				if (i - k0) / fps <= 0.035 + 1e-4 then by_035 = max(by_035, d[i]) end
				if (i - k0) / fps <= 0.16 + 1e-4 then by_16 = max(by_16, d[i]) end
				if d[i] > peak then peak, kp = d[i], i end
			end
			expect(by_035 <= 0.75 * a, tag .. "no abrupt first-frame plunge (" .. by_035 .. " of " .. a .. ")")
			expect(by_16 >= 0.85 * a, tag .. "the intended bounce still builds to most of its depth (" .. by_16 .. " of " .. a .. ")")
			expect(abs(peak - a) <= 0.1 * a, tag .. "the deepest point is dip_depth * fraction^2 within 10% (" .. peak .. " of " .. a .. ")")
			local i = kp
			while i < #d and d[i + 1] <= d[i] + 1e-5 and d[i] > 0.0 do i += 1 end
			expect(d[i] <= 0.0 or i == #d, tag .. "the depth eases out without a second push before it reaches the rest position")
			for j = kp, #d do
				if (j - k0) / fps < 0.7 and d[j] < rebound then rebound, rebound_at = d[j], (j - k0) / fps end
			end
			expect(-rebound >= 0.05 * a and -rebound <= 0.2 * a, tag .. "one small rebound over the rest position, 5 to 20% of the depth (" .. -rebound .. ")")
			expect(rebound_at >= 0.15 and rebound_at <= 0.4, tag .. "at about a quarter second (" .. rebound_at .. ")")
			local late = 0.0
			for j = 1, #d do
				if (j - k0) / fps >= 4.0 * recovery then late = max(late, abs(d[j])) end
			end
			expect(late < 2e-3, tag .. "under 2 mm by 4 recovery times (" .. late .. ")")
			if fps == 60 then
				local horizontal, pitch, before = 0.0, 0.0, 0.0
				for j = 1, #with.pos do
					horizontal = max(horizontal, abs(horizontal_to_root(with, j) - horizontal_to_root(without, j)))
					if j + 1 < k0 then before = max(before, vector.magnitude(with.pos[j] - without.pos[j])) end
					-- (a frame shows the pose of the step before it: the two frames from the touchdown step on)
					if j >= k0 and j <= k0 + 2 then pitch = max(pitch, abs(with.pitch[j] - without.pitch[j])) end
				end
				print(string.format("  landing bounce [%.1f m drop, 60 fps]: fraction %.2f, depth %.3f m (expected %.3f), first step %.3f m, second %.3f m; rebound %.3f m at %.2f s; horizontal change %.4f m; view pitch changes by %.2f deg in the first 2 frames",
					drop, with.fraction, peak, a, d[k0], d[k0 + 1], -rebound, rebound_at, horizontal, pitch))
				expect(horizontal < 0.01, tag .. "the horizontal distance to the skater changes by less than 1 cm (" .. horizontal .. ")")
				expect(before < 1e-6, tag .. "nothing moves before the touchdown")
				if drop == 4.0 then expect(pitch >= 1.0, tag .. "the view still responds to the impact in the first 2 frames (" .. pitch .. ")") end
			end
			if drop == 4.0 then -- the steps' curve from the first one
				local last = -1.0
				for j = k0, #d do
					if #curves[fps] < 60 and d[j] ~= last then table.insert(curves[fps], d[j]); last = d[j] end
				end
			end
		end
	end
end
do -- 30 and 144 fps against 60 fps: every step the frames show is a step of the 60 fps run, at the same depth, to 1e-4 m
	local worst = 0.0
	for _, other in { 30, 144 } do
		for _, v in curves[other] do
			local best = 1e9
			for _, w in curves[60] do best = min(best, abs(v - w)) end
			worst = max(worst, best)
		end
	end
	print(string.format("  landing bounce, the 4 m curve at 30 / 144 fps against 60 fps: worst difference %.6f m", worst))
	expect(#curves[60] > 0 and worst < 1e-4, "landing bounce: the curve at 30 and 144 fps agrees with 60 fps within 1e-4 m")
end

do -- off: none; a depth of 0 is the same as off; the default camera is the one with the bounce on
	local a = run(4.0, off)
	local shown = 0.0
	for i = 1, #a.dip do shown = max(shown, abs(a.dip[i]), abs(a.impact[i])) end
	expect(shown == 0.0, "landing bounce: switched off there is none")
	local b = run(4.0, make_settings(function(cs) cs.native_plus.dip_depth = 0.0 end))
	local most = 0.0
	for i = 1, #a.pos do most = max(most, vector.magnitude(a.pos[i] - b.pos[i])) end
	expect(most < 1e-6, "landing bounce: a depth of 0 is the same as off")
	local def = Settings.camera()
	def.shake_enabled = false
	local c, d = run(4.0, def), run(4.0, on)
	local differ = 0.0
	for i = 1, #c.pos do differ = max(differ, vector.magnitude(c.pos[i] - d.pos[i])) end
	expect(differ < 1e-6, "landing bounce: the default camera bounces (the same as switched on)")
end

-- Landings in a row: the second 0.1 s after the first, strong enough to count (and, as a second case, too weak to matter). The depth
-- restarts from where it is: it never jumps up (less deep) at the new touchdown.
for _, strong in { true, false } do
	local first_at, first_land = hop_rider(4.0)
	local second_begin = first_land + 1 / 60
	local second_hop, second_air = 0.0126, 2.0 * sqrt(2.0 * 0.0126 / gravity)
	local function at(time)
		if time < second_begin then return first_at(time) end
		local s = Subject.new_snapshot()
		s.valid, s.time, s.velocity = true, time, vc(0, 0, 6)
		s.position = vc(0, root_height - 4.0, 6 * time)
		s.ground_clearance = root_height
		local since = time - second_begin
		if since < second_air then
			local vy0 = sqrt(2.0 * gravity * second_hop)
			s.position = vc(0, root_height - 4.0 + vy0 * since - 0.5 * gravity * since * since, 6 * time)
			s.velocity = vc(0, vy0 - gravity * since, 6)
			s.physics_state = Subject.physics_state.air
			s.ground_clearance = s.position.y + 4.0
		end
		return s
	end
	local cs = make_settings(function(c)
		c.landing_shake.min_fall = 0.0
		c.landing_shake.full_fall = strong and 0.1 or 10.0
	end)
	local r = run(4.0, cs, 60, at, second_begin + second_air)
	local k0 = first_depth(r.dip)
	local kk
	for i = k0 + 1, #r.dip do
		if r.frac[i] ~= r.frac[k0] then kk = i break end
	end
	local tag = "landing bounce, second landing (" .. (strong and "strong" or "weak") .. "): "
	expect(kk ~= nil and kk > k0 + 2, tag .. "the camera sees it")
	if kk and kk > k0 + 2 then
		local d = r.dip
		print(string.format("  landing bounce, a second landing 0.1 s after the first (%s): depth %.3f m before it, %.3f m after; at most %.4f m up in a frame",
			strong and "strong" or "weak", d[kk - 1], d[kk + 2], d[kk - 1] - d[kk]))
		expect(d[kk - 1] - d[kk] <= 2e-3, tag .. "the camera never jumps up at the new touchdown")
		if strong then expect(d[kk + 2] >= d[kk - 1] - 1e-3, tag .. "it preserves the prior depth at another strong touchdown")
		else expect(d[kk + 2] <= d[kk - 1] + 1e-3, tag .. "it does not go deeper than it was") end
	end
end

do -- the sliders: Bounce depth scales the depth, Bounce recovery sets how long the ease back takes
	local function measure(configure)
		local d = run(4.0, make_settings(configure)).dip
		local k0, peak, settled = first_depth(d), 0.0, 0.0
		for i = k0, #d do
			peak = max(peak, d[i])
			if abs(d[i]) > 0.01 then settled = (i - k0) / 60 end
		end
		return peak, settled
	end
	local p_def, t_def = measure(function() end)
	local p_shallow = measure(function(cs) cs.native_plus.dip_depth = 0.16 end)
	local p_slow, t_slow = measure(function(cs) cs.native_plus.dip_peak_time = 0.4 end)
	print(string.format("  landing bounce sliders: depth 0.32 / recovery 0.18 -> %.3f m, back within 1 cm after %.2f s; depth 0.16 -> %.3f m; recovery 0.4 -> %.3f m, %.2f s", p_def, t_def, p_shallow, p_slow, t_slow))
	expect(abs(p_shallow - 0.5 * p_def) <= 0.03 * p_def, "landing bounce: Bounce depth scales the depth")
	expect(abs(p_slow - p_def) <= 0.03 * p_def and t_slow > t_def + 0.2, "landing bounce: Bounce recovery sets how long the ease back takes, not the depth")
end

do -- low cameras on level ground: the dip never takes the camera below the ground clearance
	local limited = 0
	for _, drop in { 1.5, 5.0 } do
		for _, height in { -3.0, -6.0, -9.0, -12.0, -15.0, -18.0, -21.0, -25.0 } do
			local function low(cs)
				cs.framing.height_degrees = height
				cs.framing.distance_scale = 0.8
			end
			local with = run(drop, make_settings(low))
			local without = run(drop, make_settings(function(cs)
				low(cs)
				cs.native_plus.landing_dip = false
			end))
			local clearance = Settings.camera().collision.ground_clearance
			local worst, cut = 1e9, 0.0
			for i = with.land + 1, with.land + 120 do
				local h_with, h_without = with.pos[i].y + drop, without.pos[i].y + drop
				worst = min(worst, h_with - min(h_without, clearance))
				-- (the frame shows the previous step's camera: the spring that made it is the previous frame's debug value)
				cut = max(cut, with.dip[i - 1] - (h_without - h_with))
			end
			if cut > 0.01 then limited += 1 end
			expect(worst >= -0.01, "landing dip, low camera (" .. drop .. " m, " .. height .. " deg): never below the ground clearance, nor lower than without the dip (" .. worst .. ")")
		end
	end
	expect(limited >= 1, "landing dip, low camera: the ground cut the dip short in some setup (the test means something)")
end

do -- the landing kick never moves the camera toward the skater: with and without the shake, the distance to the root differs by under 1 cm
	for _, drop in { 1.5, 5.0 } do
		local function shaken(cs)
			cs.shake_enabled = true
			cs.native_plus.landing_dip = false
			cs.speed_shake.enabled = false
			cs.shake.one_shot_magnitude = 10.0 -- a strong kick
			cs.ride_distance.slow = 1.35 -- close enough for the shake to show (it fades out beyond 3.4 m)
			cs.ride_distance.fast = 1.9
		end
		local with = run(drop, make_settings(shaken))
		local without = run(drop, make_settings(function(cs)
			shaken(cs)
			cs.shake_enabled = false
		end))
		local worst, pitch = 0.0, 0.0
		for i = with.land + 1, with.land + 30 do
			worst = max(worst, abs(vector.magnitude(with.pos[i] - with.subject[i]) - vector.magnitude(without.pos[i] - without.subject[i])))
			pitch = max(pitch, abs(with.pitch[i] - without.pitch[i]))
		end
		expect(pitch > 0.5, "landing kick (" .. drop .. " m drop): there is a kick (" .. pitch .. " deg)")
		expect(worst < 0.01, "landing kick (" .. drop .. " m drop): the camera's distance to the root changes by less than 1 cm from the shake (" .. worst .. ")")
	end
end

T.done()
