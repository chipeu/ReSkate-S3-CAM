-- Port of Engine/Game/Camera/Test/s3cam_rig_tests.cpp
local T = require("tlib")
local S = require("s3math")
local Tr = require("tracker")
local Rig = require("rig")
T.group("rig")
local near, expect = T.near, T.expect
local pi, degrees, wrap_angle = S.pi, S.degrees, S.wrap_angle
local vc = vector.create
local abs, max = math.abs, math.max
local dt = Rig.rig_step

local function near4(a, b, tol)
	return abs(a - b) <= (tol or 1e-4)
end

do -- lag curve
	local c = Tr.lag_curve()
	expect(Tr.lag_valid(c), "default curve is valid")
	expect(near4(Tr.lag_evaluate(c, -1.0), c.y[1]) and near4(Tr.lag_evaluate(c, 5.0), c.y[8]), "curve clamps")
	expect(near4(Tr.lag_evaluate(c, 0.075), 0.5 * (c.y[1] + c.y[2])), "curve is linear between points")
	local bad = Tr.lag_curve()
	bad.x[4] = 0.1
	expect(not Tr.lag_valid(bad), "descending x is invalid")
	expect(Rig.anchor_valid(Rig.anchor_defaults()), "default anchor settings are valid")
end

local function run_push(speed, push_seconds, set)
	local a = Rig.anchor_new()
	Rig.anchor_reset(a, vc(0, 0, 0), 0.0)
	local r = { lag_early = 0, lag_peak = 0, lag_late = 0 }
	local inp = Rig.new_input().anchor
	for i = 1, 480 do
		local t = i * dt
		inp.position = vc(speed * t, 0, 0)
		inp.velocity = vc(speed, 0, 0)
		inp.push_state = t <= push_seconds
		inp.push_kick = i == 1
		Rig.anchor_update(a, dt, inp, set)
		local lag = inp.position.x - a.tracker.position.x
		r.lag_peak = max(r.lag_peak, lag)
		if i == 24 then
			r.lag_early = lag
		end
		if i == 480 then
			r.lag_late = lag
		end
	end
	return r
end

do -- push lags then catches up
	local set = Rig.anchor_defaults()
	set.push_max_smoothing = 0.8
	local pushed = run_push(3.0, 0.4, set)
	local none = Rig.anchor_defaults()
	none.push_max_smoothing = 0.0
	local plain = run_push(3.0, 0.4, none)
	expect(pushed.lag_early > plain.lag_early * 3.0, "a push makes the anchor trail the subject")
	expect(pushed.lag_peak > plain.lag_peak * 3.0, "peak push lag is well above the unlatched lag")
	expect(pushed.lag_late < plain.lag_late + 0.01, "the anchor catches up once the latch decays")
	expect(pushed.lag_late < pushed.lag_peak * 0.3, "late lag is a small share of the peak")

	local a = Rig.anchor_new()
	Rig.anchor_reset(a, vc(0, 0, 0), 0.0)
	local inp = Rig.new_input().anchor
	inp.push_state, inp.push_kick = true, true
	Rig.anchor_update(a, dt, inp, set)
	inp.push_kick = false
	Rig.anchor_update(a, dt, inp, set)
	expect(a.latched, "latch stays set while the push window is open")
	inp.push_state = false
	Rig.anchor_update(a, dt, inp, set)
	expect(not a.latched, "latch releases with the push window")
end

do -- pump and fade
	local set = Rig.anchor_defaults()
	local a = Rig.anchor_new()
	Rig.anchor_reset(a, vc(0, 0, 0), 0.0)
	local inp = Rig.new_input().anchor
	inp.pump_acceleration = set.pump_min_acceleration - 0.1
	Rig.anchor_update(a, dt, inp, set)
	expect(near4(a.smoothing, 0.0), "pump below the threshold gives no lag")
	inp.pump_acceleration = set.pump_min_acceleration + 1.0
	Rig.anchor_update(a, dt, inp, set)
	expect(near4(a.smoothing, set.pump_curve.y[1] * set.pump_max_smoothing), "pump above the threshold lags at the curve start")
	inp.velocity = vc(set.lag_off_above_speed + 1.0, 0, 0)
	Rig.anchor_update(a, dt, inp, set)
	expect(near4(a.smoothing, 0.0), "lag fades out at speed")
	inp.velocity = vc(0.5 * (set.lag_full_below_speed + set.lag_off_above_speed), 0, 0)
	Rig.anchor_update(a, dt, inp, set)
	local full = Tr.lag_evaluate(set.pump_curve, 0.0) * set.pump_max_smoothing
	expect(a.smoothing > 0.0 and a.smoothing < full + 1e-4, "lag is partial between the fade speeds")
	inp.no_lag = true
	Rig.anchor_update(a, dt, inp, set)
	expect(near4(a.smoothing, 0.0), "no_lag forces zero smoothing")

	local b = Rig.anchor_new()
	Rig.anchor_reset(b, vc(0, 0, 0), 1.0)
	local up = Rig.new_input().anchor
	up.position = vc(0, 5.0, 0)
	up.reference_height = 1.0
	for _ = 1, 120 do
		Rig.anchor_update(b, dt, up, set)
	end
	expect(near4(b.tracker.position.y, 1.0), "anchor Y is the reference height")
end

-- Drives a heading tracker like HeadingTracker::update: returns the tracker state.
local function heading_step(h, set, target, offset, active, boost, shot)
	return Rig.heading_update(h, dt, target, offset, active, boost, shot, set)
end

do -- heading tracker
	local set = Rig.heading_defaults()
	expect(Rig.angle_rig_valid(set), "heading defaults are valid")
	local h = Rig.heading_new()
	Tr.angle_reset(h.tracker, 0.0)
	local target = 90.0 * degrees
	for _ = 1, 600 do
		heading_step(h, set, target, 0, true, false, 0.8)
	end
	expect(near4(Rig.heading_current(h), target, 0.01), "heading converges on its target")

	local w = Rig.heading_new()
	Tr.angle_reset(w.tracker, 170.0 * degrees)
	local widest = 0.0
	for _ = 1, 60 do
		heading_step(w, set, -170.0 * degrees, 0, true, false, 0.8)
		widest = max(widest, abs(wrap_angle(Rig.heading_current(w) - 180.0 * degrees)))
	end
	expect(widest < 30.0 * degrees, "heading crosses +-pi the short way")

	local slow, fast = Rig.heading_new(), Rig.heading_new()
	Tr.angle_reset(slow.tracker, 0.0)
	Tr.angle_reset(fast.tracker, 0.0)
	for _ = 1, 12 do
		heading_step(slow, set, 120.0 * degrees, 0, true, false, 0.8)
		heading_step(fast, set, 120.0 * degrees, 0, true, true, 0.8)
	end
	expect(Rig.heading_current(fast) > Rig.heading_current(slow) * 1.2, "boost raises the heading's acceleration")

	local idle = Rig.heading_new()
	Tr.angle_reset(idle.tracker, 0.0)
	for _ = 1, 60 do
		heading_step(idle, set, 1.0, 0.25, false, false, 0.8)
	end
	expect(near4(idle.tracker.position, 0.0) and near4(Rig.heading_current(idle), 0.25), "inactive heading holds; offset is added")
	local bad = Rig.heading_defaults()
	bad.max_elevation_degrees = 90.0
	expect(not Rig.angle_rig_valid(bad), "an elevation limit of 90 degrees is invalid")
end

do -- elevation tracker
	local set = Rig.elevation_defaults()
	local e = Tr.new_state()
	Tr.angle_reset(e, 0.0)
	for _ = 1, 600 do
		Rig.elevation_update(e, dt, 10.0 * degrees, set, 0.8)
	end
	expect(near4(e.position, 10.0 * degrees, 0.01), "elevation converges")
	for _ = 1, 1200 do
		Rig.elevation_update(e, dt, 89.0 * degrees, set, 0.0)
	end
	expect(e.position <= set.max_elevation_degrees * degrees + 1e-4, "elevation target is clamped to the limit")
	expect(e.position > 70.0 * degrees, "elevation reaches the clamp")
end

do -- per-shot smoothing
	local rs = Rig.rig_angle_smoothing
	expect(near(rs(0.85), 0.9775, 1e-6), "shot smoothing 0.85 -> tracker smoothing 1 - 0.15^2")
	expect(near4(rs(0.0), 0.0) and near4(rs(1.0), 1.0), "shot smoothing 0 takes the step, 1 holds")

	-- Hand-computed first step from rest (written out from the tracker maths, as in the C++ test).
	local function heading_expect(shot, error_deg)
		local d, p, a_min, a_max = 3.0, 40.0, 400.0, 900.0
		local deg = 3.14159265358979 / 180.0
		local delta = error_deg * deg
		local fraction = error_deg < d and 1.0 or (error_deg < p and 1.0 - (error_deg - d) / (p - d) or 0.0)
		local limit = (a_min + (a_max - a_min) * fraction) * deg
		local accel = math.min(delta * 3600.0, limit)
		local velocity = accel / 60.0
		local h = 1.0 - shot
		local base = 1.0 - h * h
		local capped = math.min(base, 0.8)
		local quarter = 3.14159265358979 / 4.0
		local smoothing = delta < quarter and base + (capped - base) * (delta / quarter) or capped
		return velocity / 60.0 * (1.0 - smoothing)
	end
	local hs = Rig.heading_defaults()
	local moved = {}
	local shots = { 0.2, 0.85, 0.95 }
	for k = 1, 3 do
		local h = Rig.heading_new()
		Tr.angle_reset(h.tracker, 0.0)
		heading_step(h, hs, 5.0 * degrees, 0, true, false, shots[k])
		moved[k] = h.tracker.position
		expect(abs(moved[k] - heading_expect(shots[k], 5.0)) < 1e-7, "heading first step matches the Rust smoothing formula")
	end
	expect(moved[1] > moved[2] * 1.5 and moved[2] > moved[3], "a smoother shot responds more slowly in heading")

	local function elevation_expect(shot, error_deg)
		local d, p, a_min, a_max = 1.0, 20.0, 200.0, 400.0
		local deg = 3.14159265358979 / 180.0
		local fraction = error_deg < d and 1.0 or (error_deg < p and 1.0 - (error_deg - d) / (p - d) or 0.0)
		local limit = (a_min + (a_max - a_min) * fraction) * deg
		local accel = math.min(error_deg * deg * 3600.0, limit)
		local h = 1.0 - shot
		return accel / 60.0 / 60.0 * (h * h)
	end
	local es = Rig.elevation_defaults()
	local emoved = {}
	local eshots = { 0.5, 0.85 }
	for k = 1, 2 do
		local e = Tr.new_state()
		Tr.angle_reset(e, 0.0)
		Rig.elevation_update(e, dt, 5.0 * degrees, es, eshots[k])
		emoved[k] = e.position
		expect(abs(emoved[k] - elevation_expect(eshots[k], 5.0)) < 1e-8, "elevation first step matches the Rust smoothing formula")
	end
	expect(emoved[1] > emoved[2] * 5.0, "a smoother shot responds more slowly in elevation")

	-- Through the whole rig.
	local set = Rig.default_settings()
	local loose, tight = Rig.new(), Rig.new()
	local inp = Rig.new_input()
	inp.compass.forward = vc(0, 0, 1)
	inp.shot_heading = pi
	inp.elevation_target = 0.0
	Rig.reset(loose, inp, set)
	Rig.reset(tight, inp, set)
	inp.shot_heading = pi + 20.0 * degrees
	inp.elevation_target = 10.0 * degrees
	local lo, ti
	local lo_h, lo_e, ti_h, ti_e
	for _ = 1, 20 do
		inp.heading_smoothing, inp.elevation_smoothing = 0.3, 0.3
		lo = Rig.update(loose, dt, inp, set)
		lo_h, lo_e = lo.heading, lo.elevation
		inp.heading_smoothing, inp.elevation_smoothing = 0.9, 0.9
		ti = Rig.update(tight, dt, inp, set)
		ti_h, ti_e = ti.heading, ti.elevation
	end
	expect(abs(wrap_angle(lo_h - pi)) > abs(wrap_angle(ti_h - pi)) * 2.0, "Rig: the shot's direction smoothing sets the heading response")
	expect(lo_e > ti_e * 2.0, "Rig: the shot's elevation smoothing sets the elevation response")
end

do -- distance tracker
	local set = Rig.distance_defaults()
	local d = Tr.new_state()
	Tr.scalar_reset(d, 2.0)
	local inp = { target = 4.0, fast = false, wipeout = false, snap = false }
	local first = 0.0
	for _ = 1, 12 do
		first = Rig.distance_update(d, dt, inp, set)
	end
	expect(first > 2.0 and first < 4.0, "distance eases toward a farther target")
	for _ = 1, 1200 do
		Rig.distance_update(d, dt, inp, set)
	end
	expect(near4(d.position, 4.0, 0.01), "distance converges")

	local slow, quick = Tr.new_state(), Tr.new_state()
	Tr.scalar_reset(slow, 2.0)
	Tr.scalar_reset(quick, 2.0)
	local fast_in = { target = 4.0, fast = true, wipeout = false, snap = false }
	for _ = 1, 24 do
		Rig.distance_update(slow, dt, inp, set)
		Rig.distance_update(quick, dt, fast_in, set)
	end
	expect(quick.position > slow.position, "the fast parameter set closes the gap sooner")

	local tiny = { target = 0.1, fast = false, wipeout = false, snap = true }
	Rig.distance_update(d, dt, tiny, set)
	expect(near4(d.position, set.min_distance), "target is held at the minimum distance")
	tiny.wipeout = true
	Rig.distance_update(d, dt, tiny, set)
	expect(near4(d.position, set.min_distance_wipeout), "wipeout tightens the minimum distance")
	local bad = Rig.distance_defaults()
	bad.normal.speed_clamp = 0.0
	expect(not Rig.distance_valid(bad), "zero speed clamp is invalid")
end

do -- compass lineup
	local set = Rig.compass_defaults()
	expect(Rig.compass_valid(set), "compass defaults are valid")
	local c = Rig.compass_new()
	local inp = Rig.new_input().compass
	inp.forward = vc(0, 0, 1)
	Rig.compass_update(c, dt, inp, set) -- initialises
	for i = 1, 480 do
		inp.position = vc(6.0 * i * dt, 0, 0)
		Rig.compass_update(c, dt, inp, set)
	end
	expect(near4(c.heading, -pi / 2, 0.05), "compass follows the direction of travel")

	inp.position = vc(6.0 * 480 * dt, 0, 0)
	local delay_steps = math.floor(set.time_before_lineup / dt)
	for _ = 1, delay_steps - 10 do
		Rig.compass_update(c, dt, inp, set)
	end
	local before = c.heading
	expect(near4(before, -pi / 2, 0.06), "compass holds its heading during the delay")
	for _ = 1, 30 do
		Rig.compass_update(c, dt, inp, set)
	end
	expect(abs(wrap_angle(c.heading)) < abs(wrap_angle(before)) - 1e-3, "compass starts lining up after the delay")
	for _ = 1, 1200 do
		Rig.compass_update(c, dt, inp, set)
	end
	expect(near4(c.heading, 0.0, 0.02), "compass ends up behind the subject's forward")

	local k = Rig.compass_new()
	local held = Rig.new_input().compass
	held.forward = vc(1, 0, 0)
	Rig.compass_reset(k, held.position, vc(0, 0, 1))
	held.crouching = true
	for _ = 1, 1200 do
		Rig.compass_update(k, dt, held, set)
	end
	expect(near4(k.heading, 0.0), "no lineup while crouching")
	held.crouching = false
	held.wiping_out = true
	for _ = 1, 1200 do
		Rig.compass_update(k, dt, held, set)
	end
	expect(near4(k.heading, 0.0) and near4(k.stopped_time, 0.0), "no lineup while wiping out")

	held.wiping_out = false
	held.grinding = true
	held.grind_direction = vc(-1, 0, 0)
	Rig.compass_update(k, dt, held, set)
	expect(near4(k.heading, Rig.heading_of(vc(-1, 0, 0))), "grinding takes the rail heading")
	local bad = Rig.compass_defaults()
	bad.max_deadzone_speed = bad.min_deadzone_speed
	expect(not Rig.compass_valid(bad), "dead-zone speeds must be ordered")
end

do -- deadzone
	local set = Rig.compass_defaults()
	local c = Rig.compass_new()
	Rig.compass_reset(c, vc(0, 0, 0), vc(0, 0, 1))
	local inp = Rig.new_input().compass
	inp.forward = vc(0, 0, 1)
	for i = 0, 239 do
		inp.position = vc(0.02 * ((i % 2 == 1) and 1.0 or -1.0), 0, 0)
		Rig.compass_update(c, dt, inp, set)
	end
	expect(near4(c.heading, 0.0, 0.1), "small jitter stays inside the dead-zone")
end

do -- reset snaps everything
	local set = Rig.default_settings()
	expect(Rig.valid(set), "default rig settings are valid")
	local rig = Rig.new()
	local inp = Rig.new_input()
	inp.compass.forward = vc(0, 0, 1)
	inp.anchor.velocity = vc(5, 0, 0)
	inp.elevation_target = 10.0 * degrees
	inp.distance.target = 2.5
	Rig.reset(rig, inp, set)
	local out = Rig.update(rig, dt, inp, set)
	expect(near4(out.distance, 2.5, 0.01) and near4(out.anchor.x, 0.0, 0.01), "rig starts settled")

	for i = 1, 45 do
		local t = i * dt
		inp.anchor.position = vc(10.0 * t, 0.5, -4.0 * t)
		inp.anchor.reference_height = 0.5
		inp.anchor.push_state, inp.anchor.push_kick = true, true
		inp.compass.position = inp.anchor.position
		inp.elevation_target = 40.0 * degrees
		inp.distance.target = 9.0
		out = Rig.update(rig, dt, inp, set)
	end
	expect(out.anchor_lag > 0.0, "the rig is lagging before the reset")
	expect(not near4(out.distance, 9.0, 0.05), "distance is still moving before the reset")
	expect(abs(rig.elevation.velocity) > 0.0 or abs(rig.heading.tracker.velocity) > 0.0, "angles carry velocity")

	inp.anchor.position = vc(-30.0, 2.0, 8.0)
	inp.anchor.reference_height = 2.0
	inp.anchor.push_state, inp.anchor.push_kick = false, false
	inp.compass.position = inp.anchor.position
	inp.compass.forward = vc(1, 0, 0)
	inp.elevation_target = -5.0 * degrees
	inp.distance.target = 3.0
	Rig.reset(rig, inp, set)
	out = Rig.update(rig, dt, inp, set)
	expect(near4(out.anchor.x, -30.0, 0.01) and near4(out.anchor.y, 2.0, 0.01) and near4(out.anchor.z, 8.0, 0.01), "reset snaps the anchor")
	expect(near4(out.anchor_lag, 0.0, 0.01), "reset leaves no anchor lag")
	expect(vector.magnitude(rig.anchor.tracker.velocity) < 0.5, "reset zeroes the anchor velocity")
	expect(near4(out.compass_heading, Rig.heading_of(vc(1, 0, 0)), 0.01), "reset puts the compass on the forward direction")
	expect(near4(out.heading, wrap_angle(Rig.heading_of(vc(1, 0, 0)) + pi), 0.02), "reset snaps the heading behind the subject")
	expect(near4(out.elevation, -5.0 * degrees, 0.01), "reset snaps the elevation")
	expect(near4(out.distance, 3.0, 0.01), "reset snaps the distance")
	expect(near4(rig.heading.tracker.velocity, 0.0, 0.05) and near4(rig.elevation.velocity, 0.0, 0.05), "reset zeroes the angular velocities")

	-- Invalid settings are refused without touching state (the per-step check is off by default here).
	Rig.set_validate_each_step(true)
	local bad = Rig.default_settings()
	bad.anchor.speed_clamp = -1.0
	local kept_d, kept_x = out.distance, out.anchor.x
	local after = Rig.update(rig, dt, inp, bad)
	expect(near4(after.distance, kept_d) and near4(after.anchor.x, kept_x), "invalid settings leave the rig alone")
	Rig.set_validate_each_step(false)

	-- reset_distance and place_heading (the camera's hand-back helpers).
	Rig.reset_distance(rig, 5.5)
	expect(rig.distance.position == 5.5 and rig.distance.velocity == 0, "reset_distance places the distance at rest")
	Rig.place_heading(rig, 1.0, pi)
	expect(near4(rig.heading.tracker.position, 1.0) and near4(rig.compass.heading, wrap_angle(1.0 - pi)), "place_heading puts compass and heading on it")
end

T.done()
