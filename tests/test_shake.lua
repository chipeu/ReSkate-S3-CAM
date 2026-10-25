-- Port of Engine/Game/Camera/Test/s3cam_shake_tests.cpp
local T = require("tlib")
local S = require("s3math")
local Sh = require("shake")
T.group("shake")
local near, expect = T.near, T.expect
local degrees = S.degrees
local fixed_step = S.fixed_step
local vc = vector.create
local abs, max = math.abs, math.max
local nan = 0 / 0
local UP = vc(0, 1, 0)

local function head_on(speed) return vc(0, -speed, 0) end
local function landing(speed, s)
	s = s or Sh.settings()
	local shake = Sh.new()
	Sh.landing_impulse(shake, UP, head_on(speed), s)
	return shake.impulse
end
-- Largest rotation/translation magnitude over one second of fixed updates.
local function peak(distance, speed, impulse_speed)
	speed = speed or 15.0
	impulse_speed = impulse_speed or 0.0
	local s = Sh.settings()
	local shake = Sh.new()
	if impulse_speed > 0 then
		Sh.landing_impulse(shake, UP, head_on(impulse_speed), s)
	end
	local best = 0
	for _ = 1, 60 do
		local o = Sh.update(shake, fixed_step, speed, distance, true, s)
		local t = o.translation
		best = max(best, abs(o.pitch), abs(o.yaw), abs(o.roll), abs(t.x), abs(t.y), abs(t.z))
	end
	return best
end

do -- settings validity
	expect(Sh.valid(Sh.settings()), "defaults are valid")
	local s = Sh.settings()
	s.one_shot_max_velocity = s.one_shot_min_velocity
	expect(not Sh.valid(s), "max velocity must exceed min velocity")
	s = Sh.settings()
	s.one_shot_decay = 1.5
	expect(not Sh.valid(s), "decay above 1 is invalid")
	s = Sh.settings()
	s.distance_zero = s.distance_full
	expect(not Sh.valid(s), "fade end must be beyond fade start")
	s = Sh.settings()
	s.rotation_multiplier = nan
	expect(not Sh.valid(s), "non-finite is invalid")
	s = Sh.settings()
	s.amplitude_curve.points[2][1] = 0.9 -- x goes backwards (0.9 then 0.667)
	expect(not Sh.valid(s), "curve x must be non-decreasing")
end

do -- impulse scaling
	local s = Sh.settings()
	-- (vectors hold float32, the setting is a double: 2.2 vs float32(2.2) leaves ~1e-7 m/s, hence the tolerance)
	expect(landing(s.one_shot_min_velocity, s) < 1e-6, "at the minimum velocity there is no impulse")
	expect(landing(1.0, s) == 0.0, "a slow landing gives no impulse")
	expect(near(landing(s.one_shot_max_velocity, s), s.one_shot_magnitude), "full speed gives the full magnitude")
	expect(near(landing(100.0, s), s.one_shot_magnitude), "faster than the maximum is clamped")
	local mid = 0.5 * (s.one_shot_min_velocity + s.one_shot_max_velocity)
	expect(near(landing(mid, s), 0.25 * s.one_shot_magnitude), "impulse is proportional to fraction squared")
	local q = s.one_shot_min_velocity + 0.25 * (s.one_shot_max_velocity - s.one_shot_min_velocity)
	expect(near(landing(q, s) * 4, landing(mid, s)), "half the fraction gives a quarter of the impulse")
	expect(not Sh.landing_impulse(Sh.new(), UP, vc(0, 0, 0), s), "no velocity does nothing")
	local bone = Sh.new()
	Sh.landing_impulse(bone, UP, head_on(s.one_shot_max_velocity), s, s.broken_bone_scale)
	expect(near(bone.impulse, 20 * s.one_shot_magnitude), "broken-bone landing is x20")
end

do -- grazing
	local s = Sh.settings()
	local v = s.one_shot_max_velocity * 1.1
	local head = landing(v, s)
	expect(near(head, s.one_shot_magnitude), "head on just past the full speed is the full impulse")
	local function slanted(angle_degrees)
		local shake = Sh.new()
		Sh.landing_impulse(shake, UP, vc(v * math.sin(angle_degrees * degrees), -v * math.cos(angle_degrees * degrees), 0), s)
		return shake.impulse
	end
	local a45, a80, a10 = slanted(45), slanted(80), slanted(10)
	local f45 = S.clamp01((v * math.cos(45 * degrees) - s.one_shot_min_velocity) / (s.one_shot_max_velocity - s.one_shot_min_velocity))
	expect(near(a45, f45 * f45 * s.one_shot_magnitude, 1e-4), "45 degrees off the normal keeps v cos 45 of the speed")
	expect(a45 < head, "grazing gives less than head on")
	expect(a80 < a45, "more grazing gives less")
	expect(a10 <= head and a10 >= a45, "10 degrees is no more than head on and no less than 45 degrees")
	local c = Sh.new()
	local raised = Sh.landing_impulse(c, UP, vc(v, 0, 0), s)
	expect(not raised and c.impulse == 0.0, "sliding along the surface (90 degrees) gives zero")
	local away = Sh.new()
	expect(not Sh.landing_impulse(away, UP, vc(0, v, 0), s) and away.impulse == 0.0, "moving away from the surface gives zero")
	local slope = vc(math.sin(20 * degrees), math.cos(20 * degrees), 0.0)
	local tilted = Sh.new()
	Sh.landing_impulse(tilted, slope, vc(0, -v, 0), s)
	local level = Sh.new()
	Sh.landing_impulse(level, UP, vc(0, -v * math.cos(20 * degrees), 0), s)
	expect(near(tilted.impulse, level.impulse, 1e-4), "the weight is the speed along the (unit) ground normal")
	local unscaled = Sh.new()
	Sh.landing_impulse(unscaled, vc(0.0, 5.0, 0), head_on(v), s)
	expect(near(unscaled.impulse, head, 1e-4), "a non-unit normal is normalised")
end

do -- log landings
	local s = Sh.settings()
	local forward, gravity = 6.6, 10.1
	local function land(down_speed)
		local shake = Sh.new()
		Sh.landing_impulse(shake, UP, vc(0.0, -down_speed, forward), s)
		return shake.impulse / s.one_shot_magnitude
	end
	local ollie = land(3.5)
	local one_m = land(math.sqrt(2.0 * gravity * 1.0))
	local three_m = land(math.sqrt(2.0 * gravity * 3.0))
	expect(ollie > 0.05 and ollie < 0.2, "a flat ollie gives a light impulse (5-20% of full)")
	expect(one_m >= 0.3 and one_m <= 0.5, "a 1 m drop gives a clear but moderate impulse (30-50% of full)")
	expect(three_m >= 0.95, "a 3 m drop is near full")
	expect(ollie < one_m and one_m < three_m, "and they rise with the drop")
	expect(land(1.5) == 0.0, "a curb hop (1.5 m/s down) gives none")
end

do -- only raises
	local s = Sh.settings()
	local range = s.one_shot_max_velocity - s.one_shot_min_velocity
	local strong = s.one_shot_min_velocity + 0.75 * range
	local weak = s.one_shot_min_velocity + 0.4 * range
	local strongest = s.one_shot_max_velocity
	local shake = Sh.new()
	expect(Sh.landing_impulse(shake, UP, head_on(strong), s), "first landing raises")
	local first = shake.impulse
	expect(not Sh.landing_impulse(shake, UP, head_on(weak), s), "a weaker landing reports no change")
	expect(shake.impulse == first, "a weaker landing does not lower the impulse")
	expect(not Sh.landing_impulse(shake, UP, head_on(strong), s), "an equal landing is not a raise")
	expect(Sh.landing_impulse(shake, UP, head_on(strongest), s), "a stronger landing raises")
	expect(shake.impulse > first, "and the value goes up")
	local f = Sh.new()
	expect(Sh.landing_impulse_fraction(f, 0.5, s) and near(f.impulse, 0.25 * s.one_shot_magnitude), "fraction impulse is squared")
	expect(not Sh.landing_impulse_fraction(f, nan, s), "NaN fraction ignored")
end

do -- decay
	local s = Sh.settings()
	local shake = Sh.new()
	Sh.landing_impulse(shake, UP, head_on(12), s)
	Sh.update(shake, fixed_step, 0, 1, true, s)
	expect(near(shake.impulse, s.one_shot_magnitude * (1 - s.one_shot_decay), 1e-5), "one update multiplies by (1 - decay)")
	local slow = Sh.new()
	Sh.landing_impulse(slow, UP, head_on(12), s)
	Sh.update(slow, 1.0 / 30, 0, 1, true, s)
	expect(near(slow.impulse, shake.impulse, 1e-6), "decay is not scaled by dt")
	local previous = shake.impulse
	local monotone = true
	local updates = 1
	while shake.impulse > 0.0 and updates < 5000 do
		Sh.update(shake, fixed_step, 0, 1, true, s)
		updates += 1
		if shake.impulse > previous then monotone = false end
		previous = shake.impulse
	end
	expect(monotone, "impulse never grows while decaying")
	expect(shake.impulse == 0.0 and updates < 5000, "decay reaches exactly 0")
	local fast = Sh.settings()
	fast.one_shot_magnitude = 0.0051
	local tiny = Sh.new()
	Sh.landing_impulse(tiny, UP, head_on(12), fast)
	Sh.update(tiny, fixed_step, 0, 1, true, fast)
	expect(tiny.impulse == 0.0, "values under 0.005 snap to 0")
end

do -- frequency and curves
	local s = Sh.settings()
	local quiet = Sh.new()
	Sh.update(quiet, 0.1, 0, 1, true, s)
	expect(near(quiet.time, s.data_fps * s.frequency_min * 0.1, 1e-4), "at rest the speed curve gives frequency_min")
	local fast = Sh.new()
	Sh.update(fast, 0.1, 100, 1, true, s)
	expect(near(fast.time, s.data_fps * s.frequency_max * 0.1, 1e-3), "above top speed gives frequency_max")
	local hit = Sh.new()
	Sh.landing_impulse(hit, UP, head_on(12), s)
	Sh.update(hit, 0.1, 100, 1, true, s)
	expect(near(hit.time, s.data_fps * s.one_shot_frequency * 0.1, 1e-4), "an active impulse forces the one-shot frequency")
	local linear = Sh.curve()
	expect(near(Sh.curve_sample(linear, 0), 0, 1e-3) and near(Sh.curve_sample(linear, 1), 1, 1e-3)
		and near(Sh.curve_sample(linear, 0.5), 0.5, 1e-3), "default curve is the identity")
	local ease = Sh.curve()
	ease.points = { { 0, 0 }, { 0.5, 0 }, { 0.5, 1 }, { 1, 1 } }
	expect(Sh.curve_sample(ease, 0.25) < 0.25 and Sh.curve_sample(ease, 0.75) > 0.75, "an s-curve is slow at the start and fast after")
	expect(peak(1, 15) > peak(1, 3), "more speed gives more shake")
	local none = Sh.settings()
	none.amplitude_top_speed = 0
	local flat = Sh.new()
	local best = 0
	for _ = 1, 60 do
		best = max(best, abs(Sh.update(flat, fixed_step, 15, 1, true, none).pitch))
	end
	expect(best == 0.0, "top speed 0 means amplitude_min (0 by default)")
end

do -- roll axis
	local s = Sh.settings()
	s.amplitude_min, s.amplitude_max = 1, 1
	local a, b = Sh.new(), Sh.new()
	local doubled = Sh.settings()
	doubled.amplitude_min, doubled.amplitude_max = 1, 1
	doubled.dutch_multiplier = 2 * s.dutch_multiplier
	local roll_a, roll_b, pitch_a, pitch_b = 0, 0, 0, 0
	for _ = 1, 60 do
		local x = Sh.update(a, 1.0 / 60, 5, 1, true, s)
		roll_a, pitch_a = max(roll_a, abs(x.roll)), max(pitch_a, abs(x.pitch))
		local y = Sh.update(b, 1.0 / 60, 5, 1, true, doubled)
		roll_b, pitch_b = max(roll_b, abs(y.roll)), max(pitch_b, abs(y.pitch))
	end
	expect(roll_a > 0 and near(roll_b, 2 * roll_a, 1e-6), "the dutch multiplier scales roll")
	expect(near(pitch_a, pitch_b, 1e-9), "the dutch multiplier leaves pitch alone")
end

do -- weight fade
	local s = Sh.settings()
	local shake = Sh.new()
	Sh.update(shake, 0.1, 5, 1, true, s)
	expect(near(shake.weight, 0.5), "weight fades in at 5 per second")
	Sh.update(shake, 1.0, 5, 1, true, s)
	expect(near(shake.weight, 1), "weight clamps at 1")
	Sh.update(shake, 0.1, 5, 1, false, s)
	expect(near(shake.weight, 0.5), "weight fades out at 5 per second")
	Sh.update(shake, 1.0, 5, 1, false, s)
	expect(shake.weight == 0.0, "weight clamps at 0")
	local off = Sh.new()
	Sh.landing_impulse(off, UP, head_on(12), s)
	local o = Sh.update(off, fixed_step, 15, 1, false, s)
	expect(o.pitch == 0 and o.yaw == 0 and o.roll == 0 and o.translation.x == 0, "disabled shake outputs nothing")
end

do -- distance fade
	local s = Sh.settings()
	local full = peak(1.0)
	expect(full > 0, "close shake is non-zero")
	expect(near(peak(s.distance_full), full, 1e-7), "full strength at the fade start")
	expect(peak(0.0) == full, "closer than the fade start is still full")
	local mid = 0.5 * (s.distance_full + s.distance_zero)
	expect(near(peak(mid), 0.5 * full, 1e-6), "half way through the fade is half strength")
	expect(peak(s.distance_zero) == 0.0, "zero at the fade end")
	expect(peak(10.0) == 0.0, "zero beyond the fade end")
	expect(peak(3.0) < full and peak(3.0) > peak(3.3), "strength falls steadily with distance")
	expect(peak(1.0, 15, 12) > full, "an impulse adds to the speed shake")
end

do -- bank
	local a, b = Sh.make_bank(), Sh.make_bank()
	local same, finite = true, true
	for i = 1, Sh.bank_size do
		same = same and a.rotation[i] == b.rotation[i] and a.translation[i] == b.translation[i]
		local r, t = a.rotation[i], a.translation[i]
		local sum = r.x + r.y + r.z + t.x + t.y + t.z
		finite = finite and sum - sum == 0
	end
	expect(same, "the bank is deterministic")
	expect(finite, "the bank is finite")
	expect(Sh.bank_size == 256 and #a.rotation == 256, "the bank has 256 samples")
	for _, k in { "x", "y", "z" } do
		local rot_sum, tra_sum, rot_peak, tra_peak = 0, 0, 0, 0
		for i = 1, Sh.bank_size do
			rot_sum += a.rotation[i][k]
			tra_sum += a.translation[i][k]
			rot_peak = max(rot_peak, abs(a.rotation[i][k]))
			tra_peak = max(tra_peak, abs(a.translation[i][k]))
		end
		expect(abs(rot_sum / 256) < 1e-5, "rotation channel has zero mean")
		expect(abs(tra_sum / 256) < 1e-5, "translation channel has zero mean")
		expect(near(rot_peak, 1, 1e-5) and near(tra_peak, 1, 1e-5), "each channel peaks at 1")
	end
	local differ = false
	for i = 1, Sh.bank_size do
		differ = differ or a.rotation[i].x ~= a.translation[i].x or a.rotation[i].x ~= a.rotation[i].y
	end
	expect(differ, "rotation and translation channels are independent")
	local other = Sh.make_bank(1234)
	local seed_matters = false
	for i = 1, Sh.bank_size do
		seed_matters = seed_matters or other.rotation[i].x ~= a.rotation[i].x
	end
	expect(seed_matters, "a different seed gives a different bank")
	local max_step = 0
	for i = 1, Sh.bank_size do
		local nxt = a.rotation[i % Sh.bank_size + 1].x
		max_step = max(max_step, abs(nxt - a.rotation[i].x))
	end
	expect(max_step < 0.5, "samples are smooth (band-limited), including across the loop point")
	expect(Sh.default_bank() == Sh.default_bank(), "the default bank is built once")
	expect(Sh.default_bank().rotation[8].y == a.rotation[8].y, "the default bank is the seeded bank")
end

T.done()
