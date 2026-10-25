-- Port of Engine/Game/Camera/s3_shake.h: camera shake, a landing impulse plus a speed-driven rumble,
-- both read from one procedurally generated, mean-removed sample bank (the recorded .shk files are EA
-- data and are NOT used).
--
-- API:
--   Shake.curve()                      ShakeCurve { points = { {x,y} x4 } } (identity); Shake.curve_valid(c); Shake.curve_sample(c, x)
--   Shake.settings()                   ShakeSettings defaults (field names as the C++; amplitude_curve / frequency_curve are curves)
--   Shake.valid(set)                   ShakeSettings::valid()
--   Shake.make_bank(seed)              { rotation = {vector x256}, translation = {vector x256} } (1-based); seed defaults to
--                                      Shake.bank_seed. Shake.default_bank() builds the default once.
--   local s = Shake.new(); Shake.reset(s)
--   Shake.landing_impulse(s, normal, velocity, settings, magnitude_scale) -> raised (bool); never lowers the impulse
--   Shake.landing_impulse_fraction(s, fraction, settings, magnitude_scale) -> raised (bool)
--   Shake.update(s, dt, speed, distance, enabled, settings, bank) -> out
--        out = s.out (REUSED every call): { pitch, yaw, roll (radians), translation (vector, camera-local x right,
--        y up, z back) }. `bank` is optional (the default bank).
--   s.impulse, s.weight, s.time          state (read-only)
--
-- Number precision: the bank is generated in doubles (the C++ uses floats) and then stored in vectors (floats).

local S3 = require("s3math")

local M = {}

local clamp01 = S3.clamp01
local abs = math.abs
local max = math.max
local floor = math.floor
local fmod = math.fmod
local vcreate = vector.create
local vdot = vector.dot
local vmagnitude = vector.magnitude
local ZERO = S3.ZERO
local UP = vcreate(0, 1, 0)

M.bank_size = 256
M.bank_seed = 0x5C3A11ED

-- ---------------------------------------------------------------- curve

-- Cubic Bezier through 4 control points (x, y). `x` is the input axis and must be non-decreasing.
function M.curve()
	return { points = { { 0.0, 0.0 }, { 1.0 / 3, 1.0 / 3 }, { 2.0 / 3, 2.0 / 3 }, { 1.0, 1.0 } } }
end

function M.curve_valid(c)
	local previous = 0.0
	for i = 1, 4 do
		local p = c.points[i]
		local x, y = p[1], p[2]
		if x - x ~= 0 or y - y ~= 0 then
			return false
		end
		if x < previous or x > 1.0 then
			return false
		end
		previous = x
	end
	return true
end

local function coefficients(points, axis)
	local p0, p1, p2, p3 = points[1][axis], points[2][axis], points[3][axis], points[4][axis]
	return -p0 + 3 * p1 - 3 * p2 + p3, 3 * p0 - 6 * p1 + 3 * p2, -3 * p0 + 3 * p1, p0
end

-- y at input x (shake_curve.rs sample): Newton inversion of the x polynomial, 10 steps from
-- t = 0.5, stopping early once x is within tolerance. `t` is kept in [0, 1].
function M.curve_sample(c, input)
	local cx0, cx1, cx2, cx3 = coefficients(c.points, 1)
	local cy0, cy1, cy2, cy3 = coefficients(c.points, 2)
	local t = 0.5
	for iteration = 0, 9 do
		local t2 = t * t
		local x = cx0 * t2 * t + cx1 * t2 + cx2 * t + cx3
		local residual = input - x
		local derivative = 3 * cx0 * t2 + 2 * cx1 * t + cx2
		if iteration == 9 or not (abs(residual) > 1e-4 and abs(derivative) > 1.2e-7) then
			break
		end
		t = clamp01(t + residual / derivative)
	end
	local t2 = t * t
	return cy0 * t2 * t + cy1 * t2 + cy2 * t + cy3
end

-- ---------------------------------------------------------------- bank

-- Procedural stand-in for the stock .shk files: band-limited noise, bank_size samples, loops
-- seamlessly, each of the 6 channels has its mean removed and its peak scaled to 1.
function M.make_bank(seed)
	local n = M.bank_size
	seed = seed or M.bank_seed
	local state = seed ~= 0 and seed or 1 -- xorshift32
	local bxor, lshift, rshift = bit32.bxor, bit32.lshift, bit32.rshift
	local function next_noise()
		state = bxor(state, lshift(state, 13))
		state = bxor(state, rshift(state, 17))
		state = bxor(state, lshift(state, 5))
		return rshift(state, 8) * (2.0 / 16777216.0) - 1.0 -- [-1, 1)
	end
	local rotation, translation = table.create(n), table.create(n)
	local channels = {}
	for channel = 0, 5 do
		local a = table.create(n)
		for i = 1, n do
			a[i] = next_noise()
		end
		-- Two circular box filters (width 9, a triangular low-pass): band-limited and seamless.
		local half = 4
		local b = table.create(n)
		for _ = 1, 2 do
			for i = 0, n - 1 do
				local sum = 0.0
				for k = 0, 2 * half do
					sum = sum + a[(i + n + k - half) % n + 1]
				end
				b[i + 1] = sum / (2 * half + 1)
			end
			a, b = b, a
		end
		local mean = 0.0
		for i = 1, n do
			mean = mean + a[i]
		end
		mean = mean / n
		local peak = 0.0
		for i = 1, n do
			a[i] = a[i] - mean
			peak = max(peak, abs(a[i]))
		end
		local gain = peak > 1e-9 and 1.0 / peak or 0.0
		for i = 1, n do
			a[i] = a[i] * gain
		end
		channels[channel] = a
	end
	for i = 1, n do
		rotation[i] = vcreate(channels[0][i], channels[1][i], channels[2][i])
		translation[i] = vcreate(channels[3][i], channels[4][i], channels[5][i])
	end
	return { rotation = rotation, translation = translation }
end

local default_bank_cache = nil
-- Built once on first use, then read-only.
function M.default_bank()
	if default_bank_cache == nil then
		default_bank_cache = M.make_bank()
	end
	return default_bank_cache
end

-- ---------------------------------------------------------------- settings

function M.settings()
	return {
		amplitude_curve = M.curve(), -- speed fraction -> 0..1, scales [amplitude_min, amplitude_max]
		frequency_curve = M.curve(), -- speed fraction -> 0..1, scales [frequency_min, frequency_max]
		one_shot_magnitude = 3.0, -- TUNE: impulse at full landing speed (amplitude units)
		-- TUNE: speed INTO the ground (-velocity . normal), m/s. Alpha 3 from the in-game log: ollies land at
		-- 3-4.5 m/s down, so 2.2 / 5.7 gives a flat ollie (3.5) ~12% of full, a 1 m drop (4.5) ~42%, a 3 m
		-- drop (7.8) full; a curb hop (under 2.2) none. The old 4 / 12 was for the Rust's angle-weighted speed.
		one_shot_min_velocity = 2.2, -- TUNE: m/s, at or below this a landing gives no impulse
		one_shot_max_velocity = 5.7, -- TUNE: m/s, at/above this the impulse is full
		one_shot_frequency = 2.0, -- TUNE: playback rate multiplier while an impulse is active
		one_shot_decay = 0.03, -- TUNE: impulse *= (1 - decay) per fixed update (not dt-scaled)
		amplitude_min = 0.0, -- TUNE: speed rumble at standstill
		amplitude_max = 0.15, -- TUNE: speed rumble at top speed
		amplitude_top_speed = 15.0, -- TUNE: m/s (0 = always amplitude_min)
		frequency_min = 0.5, -- TUNE
		frequency_max = 1.5, -- TUNE
		frequency_top_speed = 15.0, -- TUNE: m/s (0 = always frequency_min)
		data_fps = 30.0, -- TUNE: bank samples per second at frequency 1
		translation_multiplier = 0.02, -- TUNE: metres per amplitude unit
		rotation_multiplier = 0.01, -- TUNE: radians per amplitude unit
		dutch_multiplier = 0.5, -- TUNE: extra scale on the roll axis only
		distance_full = 2.8, -- m: full shake at or inside this distance
		distance_zero = 3.4, -- m: no shake at or beyond this distance
		weight_rate = 5.0, -- per second fade in/out
		broken_bone_scale = 20.0, -- landing impulse multiplier for a broken-bone landing
	}
end

local NUMERIC = {
	"one_shot_magnitude", "one_shot_min_velocity", "one_shot_max_velocity", "one_shot_frequency", "one_shot_decay",
	"amplitude_min", "amplitude_max", "amplitude_top_speed", "frequency_min", "frequency_max", "frequency_top_speed",
	"data_fps", "translation_multiplier", "rotation_multiplier", "dutch_multiplier", "distance_full", "distance_zero",
	"weight_rate", "broken_bone_scale",
}

function M.valid(s)
	for _, k in NUMERIC do
		local v = s[k]
		if v - v ~= 0 then
			return false
		end
	end
	return M.curve_valid(s.amplitude_curve) and M.curve_valid(s.frequency_curve) and s.one_shot_magnitude >= 0
		and s.one_shot_min_velocity >= 0 and s.one_shot_max_velocity > s.one_shot_min_velocity
		and s.one_shot_frequency >= 0 and s.one_shot_decay >= 0 and s.one_shot_decay <= 1 and s.amplitude_min >= 0
		and s.amplitude_max >= 0 and s.amplitude_top_speed >= 0 and s.frequency_min >= 0 and s.frequency_max >= 0
		and s.frequency_top_speed >= 0 and s.data_fps > 0 and s.translation_multiplier >= 0
		and s.rotation_multiplier >= 0 and s.distance_zero > s.distance_full and s.weight_rate >= 0
		and s.broken_bone_scale >= 0
end

-- ---------------------------------------------------------------- the shake

function M.new()
	return {
		time = 0.0,
		impulse = 0.0,
		weight = 0.0,
		out = { pitch = 0.0, yaw = 0.0, roll = 0.0, translation = ZERO },
	}
end

function M.reset(s)
	s.time, s.impulse, s.weight = 0.0, 0.0, 0.0
	s.out.pitch, s.out.yaw, s.out.roll, s.out.translation = 0.0, 0.0, 0.0, ZERO
end

-- Landing response (ShakeEffect::landing_impulse). `normal` is the ground normal, `velocity` the
-- pre-landing velocity. `magnitude_scale` is 1 normally, broken_bone_scale for a broken-bone
-- landing. Returns true when it raised the impulse; it never lowers it.
--
-- Deviation from the Rust (Alpha 3, in-game log): the Rust weights the speed by how head-on the hit
-- is, speed * (1 - angle / 90 degrees), where the angle is between the velocity and the surface
-- normal. A skater lands with a large forward speed and a small downward one (an ollie at 6.6 m/s
-- forward and 3.5 m/s down is 62 degrees off the normal), so that weighting keeps only about a third
-- of the speed and every normal landing fell under one_shot_min_velocity: the impulse was always
-- 0.000. It also made the same drop shake LESS the faster the skater rode. The weighted speed here is
-- the speed INTO the surface, -velocity . normal (the same as the Rust for a head-on hit, 0 when
-- sliding along the surface or moving away from it), so it depends on how hard the board hits, not on
-- how fast it was travelling sideways. CameraMan::kick_dip mirrors this.
function M.landing_impulse(s, normal, velocity, set, magnitude_scale)
	magnitude_scale = magnitude_scale or 1.0
	local speed = vmagnitude(velocity)
	if speed - speed ~= 0 or speed < 1e-5 then
		return false
	end
	local weighted = -vdot(S3.normalized(normal, UP), velocity)
	if not (weighted > 0.0) then
		return false
	end
	local fraction = clamp01((weighted - set.one_shot_min_velocity) / (set.one_shot_max_velocity - set.one_shot_min_velocity))
	local impulse = fraction * fraction * set.one_shot_magnitude * magnitude_scale
	if not (impulse > s.impulse) then
		return false
	end
	s.impulse = impulse
	return true
end

-- Landing impulse from a 0..1 fraction of how hard the landing was (Alpha 5: CameraMan measures it from
-- the fall height instead of the board's velocity, which flip tricks spike). Same squared shaping as
-- landing_impulse; one_shot_magnitude is the full-strength amount. Never lowers the impulse.
function M.landing_impulse_fraction(s, fraction, set, magnitude_scale)
	magnitude_scale = magnitude_scale or 1.0
	if fraction - fraction ~= 0 then
		return false
	end
	local f = clamp01(fraction)
	local impulse = f * f * set.one_shot_magnitude * magnitude_scale
	if not (impulse > s.impulse) then
		return false
	end
	s.impulse = impulse
	return true
end

-- One fixed update (ShakeEffect::update). `speed` is skater speed in m/s, `distance` the camera
-- distance to the subject in metres, `enabled` fades the whole effect in/out.
function M.update(s, dt, speed, distance, enabled, set, bank)
	bank = bank or M.default_bank()
	s.weight = clamp01(s.weight + (enabled and dt or -dt) * set.weight_rate)
	local amplitude = set.amplitude_min
	if set.amplitude_top_speed ~= 0.0 then
		amplitude = set.amplitude_min
			+ M.curve_sample(set.amplitude_curve, clamp01(speed / set.amplitude_top_speed))
				* (set.amplitude_max - set.amplitude_min)
	end
	amplitude = (s.impulse + amplitude) * s.weight
	local frequency = set.frequency_min
	if set.frequency_top_speed ~= 0.0 then
		frequency = set.frequency_min
			+ M.curve_sample(set.frequency_curve, clamp01(speed / set.frequency_top_speed))
				* (set.frequency_max - set.frequency_min)
	end
	if s.impulse > 0.0 then
		frequency = set.one_shot_frequency
	end
	local count = M.bank_size
	local time = fmod(s.time + set.data_fps * frequency * dt, count) -- wrapped: the bank loops
	if time < 0.0 then
		time = time + count
	end
	s.time = time
	local whole = floor(time)
	local fraction = time - whole
	local left = whole % count
	local right = (left + 1) % count
	local fade = clamp01((set.distance_zero - distance) / (set.distance_zero - set.distance_full))
	local rl, rr = bank.rotation[left + 1], bank.rotation[right + 1]
	local tl, tr = bank.translation[left + 1], bank.translation[right + 1]
	local rot = rl + (rr - rl) * fraction
	local tra = tl + (tr - tl) * fraction
	local rot_gain = amplitude * fade * set.rotation_multiplier
	local out = s.out
	out.pitch = rot.x * rot_gain
	out.yaw = rot.y * rot_gain
	out.roll = rot.z * rot_gain * set.dutch_multiplier
	out.translation = tra * (set.translation_multiplier * amplitude * fade)
	s.impulse = s.impulse * (1.0 - set.one_shot_decay) -- per update, not dt-scaled
	if s.impulse < 0.005 then
		s.impulse = 0.0
	end
	return out
end

return M
