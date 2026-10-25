-- Port of Engine/Game/Camera/Test/s3cam_tracker_tests.cpp (+ the LagCurve / VectorTracker bits of s3cam_rig_tests.cpp)
local T = require("tlib")
local S = require("s3math")
local Tr = require("tracker")
T.group("tracker")
local near, expect = T.near, T.expect
local pi, tau, degrees = S.pi, S.tau, S.degrees

local function base()
	local s = Tr.scalar_settings()
	s.delta_umbra = 0.1
	s.delta_penumbra = 1.0
	s.speed_clamp = 4.0
	s.acceleration_min = 10.0
	s.acceleration_max = 40.0
	s.smoothing_min = 0.2
	s.smoothing_max = 0.6
	return s
end
local function newt(v)
	local s = Tr.new_state()
	Tr.scalar_reset(s, v)
	return s
end
local function newa(v)
	local s = Tr.new_state()
	Tr.angle_reset(s, v)
	return s
end
local upd, aupd = Tr.scalar_update, Tr.angle_update
local dt = S.fixed_step
local max, min, abs = math.max, math.min, math.abs

do -- convergence
	local t = newt(0)
	local s = base()
	local peak = 0
	for _ = 1, 2000 do
		peak = max(peak, upd(t, 5.0, dt, s))
	end
	expect(near(t.position, 5.0, 1e-3), "converges on the target")
	expect(peak <= 5.0 + 1e-4, "no overshoot with overshoot_zeroes_velocity")
	local u = newt(0)
	for _ = 1, 60 do
		upd(u, 5.0, dt, s)
	end
	expect(u.position > 1.5 and u.velocity > 0, "moving past the new target before the reversal")
	local low = u.position
	for _ = 1, 2000 do
		low = min(low, upd(u, 1.0, dt, s))
	end
	expect(low >= 1.0 - 1e-3, "reversal does not undershoot")
	expect(near(u.position, 1.0, 1e-3), "reversal converges")
end

do -- clamps
	local t = newt(0)
	local s = base()
	s.smoothing_min, s.smoothing_max = 0, 0
	local max_speed, max_accel, last_v = 0, 0, 0
	for _ = 1, 400 do
		upd(t, 100.0, dt, s)
		max_speed = max(max_speed, abs(t.velocity))
		max_accel = max(max_accel, abs((t.velocity - last_v) / dt))
		last_v = t.velocity
	end
	expect(max_speed <= s.speed_clamp + 1e-4, "speed never exceeds the clamp")
	expect(near(max_speed, s.speed_clamp, 1e-3), "speed reaches the clamp on a long run")
	expect(max_accel <= s.acceleration_min + 1e-2, "acceleration never exceeds the far (min) clamp")
	expect(near(t.acceleration_clamp, s.acceleration_min), "far from target the min acceleration clamp is used")
	local b = newt(0)
	for _ = 1, 200 do
		upd(b, 100.0, dt, s)
	end
	local v0 = b.velocity
	upd(b, b.position + 0.0, dt, s)
	expect(abs(b.velocity) < v0 * 0.01, "braking toward the target is not acceleration-limited")
end

do -- umbra / penumbra
	local s = base()
	local inside = newt(0)
	upd(inside, 0.05, dt, s)
	expect(near(inside.smoothing, s.smoothing_max), "inside the umbra uses the max smoothing")
	expect(near(inside.acceleration_clamp, s.acceleration_max), "inside the umbra uses the max acceleration clamp")
	local outside = newt(0)
	upd(outside, 3.0, dt, s)
	expect(near(outside.smoothing, s.smoothing_min), "past the penumbra uses the min smoothing")
	expect(near(outside.acceleration_clamp, s.acceleration_min), "past the penumbra uses the min acceleration clamp")
	local mid = newt(0)
	upd(mid, 0.55, dt, s)
	expect(near(mid.smoothing, 0.4, 1e-4), "inside the penumbra smoothing ramps linearly")
	expect(near(mid.acceleration_clamp, 25.0, 1e-3), "inside the penumbra the clamp ramps linearly")
	local flat = base()
	flat.smoothing_min, flat.smoothing_max = 0.3, 0.3
	local f = newt(0)
	upd(f, 0.55, dt, flat)
	expect(near(f.smoothing, 0.3), "equal min and max give that value")
end

do -- angle wrapping
	local s = Tr.angle_settings()
	s.speed_clamp_degrees = 720
	s.acceleration_min_degrees, s.acceleration_max_degrees = 5000, 5000
	s.delta_penumbra_degrees = 20
	local t = newa(170 * degrees)
	local crossed_far = 0
	for _ = 1, 600 do
		local p = aupd(t, -170 * degrees, dt, s)
		expect(p >= -pi and p < pi, "position stays in [-pi, pi)")
		crossed_far = max(crossed_far, pi - abs(p))
	end
	expect(crossed_far < 15 * degrees, "170 -> -170 goes the short way, through 180")
	expect(near(t.position, -170 * degrees, 1e-3), "converges across the wrap")
	local u = newa(0)
	for _ = 1, 600 do
		aupd(u, tau + 0.5, dt, s)
	end
	expect(near(u.position, 0.5, 1e-3), "target of 2pi + 0.5 settles at 0.5")
	local v = newa(0)
	for _ = 1, 1200 do
		aupd(v, pi, dt, s)
	end
	expect(near(abs(v.position), pi, 1e-3), "converges on a target 180 degrees away")
	local w = newa(0)
	local slow = Tr.angle_settings()
	slow.speed_clamp_degrees = 90
	slow.acceleration_min_degrees, slow.acceleration_max_degrees = 100000, 100000
	slow.delta_penumbra_degrees = 10
	for _ = 1, 60 do
		aupd(w, pi - 0.01, dt, slow)
	end
	expect(near(w.position, 90 * degrees, 0.05), "speed clamp is in degrees per second")
end

do -- dt stability
	for _, dtv in { 1 / 30, 1 / 60, 1 / 120, 1 / 240 } do
		local steps = math.floor(6.0 / dtv)
		local t = newt(0)
		local s = base()
		local peak, finite = 0, true
		for _ = 1, steps do
			peak = max(peak, upd(t, 5.0, dtv, s))
			finite = finite and S.finite(t.position) and S.finite(t.velocity)
		end
		expect(finite, "state stays finite")
		expect(peak <= 5.0 + 1e-3, "no overshoot at any step size")
		expect(near(t.position, 5.0, 5e-3), "converges at any step size")
		expect(abs(t.velocity) <= s.speed_clamp + 1e-4, "speed clamp holds at any step size")
		local a = newa(0)
		local as = Tr.angle_settings()
		as.delta_penumbra_degrees = 45
		as.smoothing_max = 0.5
		local apeak = 0
		for _ = 1, steps do
			apeak = max(apeak, aupd(a, 1.0, dtv, as))
		end
		expect(apeak <= 1.0 + 1e-3 and near(a.position, 1.0, 5e-3), "angle tracker stable at any step size")
	end
end

do -- resets
	local t = newt(2)
	local s = base()
	for _ = 1, 30 do
		upd(t, 9, 1 / 60, s)
	end
	expect(t.velocity > 0, "moving before reset")
	Tr.scalar_reset(t, -3)
	expect(t.position == -3 and t.target == -3, "reset sets position and target")
	expect(t.velocity == 0 and t.acceleration == 0, "reset clears motion")
	for _ = 1, 30 do
		upd(t, 9, 1 / 60, s)
	end
	local v = t.velocity
	Tr.scalar_snap_keep_motion(t, 0)
	expect(t.position == 0 and t.velocity == v, "snap_keep_motion keeps velocity")
	Tr.scalar_reset(t, 0 / 0)
	expect(t.position == 0, "non-finite reset is ignored")
	local before = t.position
	upd(t, 0 / 0, 1 / 60, s)
	upd(t, 1, 0.0, s)
	upd(t, 1, -1.0, s)
	expect(t.position == before and t.velocity == v, "bad target or dt leaves the state alone")
	local a = newa(3 * pi / 2)
	expect(near(a.position, -pi / 2), "angle reset wraps")
end

do -- invalid settings
	local valid = Tr.valid_scalar
	expect(valid(base()), "default-ish settings are valid")
	local s = base()
	s.speed_clamp = 0 / 0
	expect(not valid(s), "NaN speed clamp rejected")
	s = base()
	s.speed_clamp = 0
	expect(not valid(s), "zero speed clamp rejected")
	s = base()
	s.delta_penumbra = 0.05
	expect(not valid(s), "penumbra below umbra rejected")
	s = base()
	s.delta_umbra = -1
	expect(not valid(s), "negative umbra rejected")
	s = base()
	s.smoothing_max = 1.5
	expect(not valid(s), "smoothing above 1 rejected")
	s = base()
	s.acceleration_min = math.huge
	expect(not valid(s), "infinite acceleration rejected")
	local a = Tr.angle_settings()
	expect(Tr.valid_angle(a), "default angle settings valid")
	a.delta_penumbra_degrees = 270
	expect(not Tr.valid_angle(a), "angle penumbra above 180 rejected")
	a = Tr.angle_settings()
	a.acceleration_max_degrees = -5
	expect(not Tr.valid_angle(a), "negative angle acceleration rejected")
	local t = newt(1)
	s = base()
	s.speed_clamp = 0 / 0
	upd(t, 5, 1 / 60, s)
	expect(t.position == 1 and t.velocity == 0, "update with invalid settings does nothing")
end

do -- lag curve + vector tracker (s3_rig.h)
	local c = Tr.lag_curve()
	expect(Tr.lag_valid(c), "default curve is valid")
	expect(near(Tr.lag_evaluate(c, -1), c.y[1]) and near(Tr.lag_evaluate(c, 5), c.y[8]), "curve clamps outside its range")
	expect(near(Tr.lag_evaluate(c, 0.075), 0.5 * (c.y[1] + c.y[2])), "curve is linear between points")
	local bad = Tr.lag_curve()
	bad.x[4] = 0.1
	expect(not Tr.lag_valid(bad), "descending x is invalid")
	expect(near(Tr.lag_evaluate(c, 0 / 0), c.y[8]), "NaN input reads the last point")

	local v = Tr.new_vector_state()
	Tr.vector_reset(v, vector.create(1, 2, 3))
	expect(v.position == vector.create(1, 2, 3), "vector reset places it")
	for _ = 1, 600 do
		Tr.vector_update(v, vector.create(5, 2, -3), dt, 25, 120, 0)
	end
	expect(T.vnear(v.position, vector.create(5, 2, -3), 1e-3), "vector tracker converges")
	local keep = v.position
	Tr.vector_update(v, vector.create(0 / 0, 0, 0), dt, 25, 120, 0)
	Tr.vector_update(v, vector.create(1, 1, 1), 0, 25, 120, 0)
	expect(v.position == keep, "bad vector target or dt leaves the state alone")
end

T.done()
