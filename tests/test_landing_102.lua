-- The landing is Dynamic Camera 1.0.2's: 14 real landings recorded from 1.0.2 (landing_dumps.lua, the rider's own settings in
-- landing_values.lua) are played through the camera and through the camera as it was in the first plugin commit (ref_102/, which
-- has the 1.0.2 landing: it drops with the landing and the kick reads the shared bank at its running position, nothing holds the
-- camera still). The camera must match it frame by frame for 0.5 s after the touchdown, within 1 cm of height over the root and
-- 0.2 degrees of view pitch. What may differ is only the kick's push along the line to the skater (it is taken out on purpose).
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_landing_102.lua
local T = require("tlib")
local Presets = require("presets")
local Settings = require("settings")
local Subject = require("subject")
local Camera = require("camera")
local RefCamera = require("ref_102/camera")
local dumps = require("landing_dumps")
local values = require("landing_values")

T.group("landing_102")
local expect = T.expect
local vc = vector.create
local abs, max, min, sin, rad, deg, asin = math.abs, math.max, math.min, math.sin, math.rad, math.deg, math.asin

local ROOT_H = 0.95
-- How close the current camera must stay to the 1.0.2 one over the 0.5 s after the touchdown. The view pitch is the same to the
-- last digit; the height differs by up to 1.1 cm in the worst of the 14 landings, which is the kick's push along the line to the
-- skater being taken out (the 1.0.2 camera still moved the camera that much toward or away from him).
local HEIGHT_TOLERANCE = 0.012 -- m, camera height over the root
local PITCH_TOLERANCE = 0.2 -- degrees, view pitch
-- Before the touchdown the two are the same but for the float rounding of a position 1500 m from the origin (and the rumble's own push
-- along the line to the skater, a few tenths of a mm).
local BEFORE_TOLERANCE = 0.001

local function to_vec(t) return vc(t[1], t[2], t[3]) end

local function snapshot(f, ground)
	local s = Subject.new_snapshot()
	s.valid = true
	s.time = f.t
	s.position = to_vec(f.pos)
	local h = rad(f.fwd)
	s.forward = vc(-sin(h), 0, math.cos(h))
	s.velocity = to_vec(f.vel)
	s.physics_state = f.state
	s.onboard = true
	s.bailing = false
	s.manual = f.manual
	s.grind_side = 0
	s.switch_stance = false
	s.board_valid = f.bv
	s.board_position = to_vec(f.board)
	s.ground_normal = vc(0, 1, 0)
	s.ground_clearance = s.position.y - ground
	return s
end

local function pitch_of(frame) return deg(asin(max(-1, min(1, -frame.back.y)))) end

-- The rider's saved settings, with the landing bounce and the landing rattle off: they carry LandingDip on, which the 1.0.2 camera never
-- drew in this style, and the 1.0.2 camera had no rattle either.
local function camera_settings()
	local cs = Presets.from_values(values)
	-- Cruising yaw was intentionally redesigned in134. Isolate the landing
	-- response by giving both cameras the same neutral legacy compass path;
	-- test_turn_follow_134 owns the new positive-strength yaw contract.
	cs.follow.horizontal = 0
	cs.native_plus.landing_dip = false
	cs.shake.rattle_pitch_deg, cs.shake.rattle_yaw_deg, cs.shake.rattle_roll_deg = 0.0, 0.0, 0.0
	return cs
end

-- One landing through both cameras. Returns the worst differences from the touchdown for 0.5 s, and before it, plus what the
-- 1.0.2 camera itself did (so the test means something: it does drop and kick).
local function compare(d)
	local frames = d.frames
	local ground = to_vec(frames[#frames].pos).y - ROOT_H
	local cur, ref = Camera.new(), RefCamera.new()
	expect(cur:set_settings(camera_settings()), "current settings accepted")
	expect(ref:set_settings(camera_settings()), "reference settings accepted")
	local query = function(from, to)
		if from.y >= ground and to.y < ground then
			local t = (from.y - ground) / (from.y - to.y)
			return from + (to - from) * t
		end
		return nil
	end
	local r = { height = 0.0, pitch = 0.0, before_height = 0.0, before_pitch = 0.0, sink = 0.0, rate = 0.0 }
	local prev_t, t0, prev_pitch
	for i, f in ipairs(frames) do
		local s = snapshot(f, ground)
		local dt = prev_t and (s.time - prev_t) or 1 / 60
		if dt <= 0 or dt > 0.1 then dt = 1 / 60 end
		prev_t = s.time
		local a = cur:update(dt, s, query, { base_fov_deg = 0 })
		local b = ref:update(dt, s, query, { base_fov_deg = 0 })
		local dh = abs((a.pos.y - s.position.y) - (b.pos.y - s.position.y))
		local dp = abs(pitch_of(a) - pitch_of(b))
		if i < d.td then
			r.before_height, r.before_pitch = max(r.before_height, dh), max(r.before_pitch, dp)
		else
			t0 = t0 or s.time
			if s.time - t0 <= 0.5 + 1e-6 then
				r.height, r.pitch = max(r.height, dh), max(r.pitch, dp)
			end
			if i == d.td then r.touch = b.pos.y - s.position.y end
			if s.time - t0 <= 0.25 + 1e-6 then
				r.sink = max(r.sink, r.touch - (b.pos.y - s.position.y))
				if prev_pitch then r.rate = max(r.rate, abs(pitch_of(b) - prev_pitch) / dt) end
			end
		end
		prev_pitch = pitch_of(b)
	end
	return r
end

expect(Settings.camera().native_plus.landing_dip == true, "the landing bounce is on by default (this comparison runs with it off, 1.0.2 had no bounce)")
expect(#dumps >= 14, "the recorded landings are there")

local worst_height, worst_pitch, worst_before = 0.0, 0.0, 0.0
local worst_sink_low, any_kick = 1e9, 0.0
for _, d in ipairs(dumps) do
	local r = compare(d)
	worst_height, worst_pitch = max(worst_height, r.height), max(worst_pitch, r.pitch)
	worst_before = max(worst_before, r.before_height, r.before_pitch)
	any_kick = max(any_kick, r.rate)
	expect(r.before_height < BEFORE_TOLERANCE and r.before_pitch < 0.01, string.format("landing %d: the same as 1.0.2 up to the touchdown (%.2g m, %.2g deg)", d.n, r.before_height, r.before_pitch))
	expect(r.height <= HEIGHT_TOLERANCE, string.format("landing %d: camera height over the root within 1.2 cm of 1.0.2's for 0.5 s after the touchdown (worst %.4f m)", d.n, r.height))
	expect(r.pitch <= PITCH_TOLERANCE, string.format("landing %d: view pitch within 0.2 deg of 1.0.2's for 0.5 s after the touchdown (worst %.3f deg)", d.n, r.pitch))
end
print(string.format("  landing_102: %d landings; worst height difference %.4f m, worst pitch difference %.3f deg, before the touchdown %.2g", #dumps, worst_height, worst_pitch, worst_before))
expect(any_kick > 100.0, "(the reference does jolt the view: its fastest landing pitch step is over 100 deg/s)")

T.done()
