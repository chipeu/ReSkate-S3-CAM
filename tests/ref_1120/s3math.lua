-- Port of Engine/Game/Camera/s3_math.h (+ heading_of from s3_rig.h).
-- Vec3 is Luau's native vector type (value type, no allocation): add / sub / scale are the
-- operators + - *, dot / cross / length are vector.dot / vector.cross / vector.magnitude.
-- Finite test used everywhere in the hot path: (x - x == 0) is false for NaN and +-inf.
--
-- API: pi, tau, degrees (deg -> rad factor), fixed_hz, fixed_step, ZERO,
--   wrap_angle(a), blend_angle(from, to, weight), sine_blend(f), interpolate_float(from, to, style, f),
--   filter_blend_value(prev, raw, smoothing, min, max), clamp01(v), lerp(a, b, t) (numbers or vectors),
--   length(v), normalized(v, fallback), heading_of(dir), flat_length(v), handedness(m16), finite(x),
--   finite3(v).

local M = {}

local fmod = math.fmod
local atan2 = math.atan2
local sin = math.sin
local sqrt = math.sqrt
local vmagnitude = vector.magnitude

local PI = 3.14159265358979
local TAU = 6.28318530717959

M.pi = PI
M.tau = TAU
M.degrees = PI / 180.0
M.fixed_hz = 60.0
M.fixed_step = 1.0 / 60.0

M.ZERO = vector.create(0, 0, 0)

-- Angle reduced to [-pi, pi). Non-finite input passes through.
-- fmod(a, tau) == a - trunc(a / tau) * tau (Luau has no math.trunc).
local function wrap_angle(angle)
	if angle - angle ~= 0 then
		return angle
	end
	local reduced = fmod(angle, TAU)
	if reduced < -PI then
		reduced = reduced + TAU
	end
	if reduced >= PI then
		reduced = reduced - TAU
	end
	return reduced
end
M.wrap_angle = wrap_angle

-- Moves `from` toward `to` by `weight` along the shorter way round.
function M.blend_angle(from, to, weight)
	return wrap_angle(from + wrap_angle(to - from) * weight)
end

function M.clamp01(v)
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

-- Works for numbers and for vectors (a + (b - a) * t).
function M.lerp(a, b, t)
	return a + (b - a) * t
end

function M.length(v)
	return vmagnitude(v)
end

-- Unit vector, or `fallback` when `a` is too short (or not finite) to have a direction.
function M.normalized(a, fallback)
	local l = vmagnitude(a)
	if l - l == 0 and l > 1e-6 then
		return a * (1 / l)
	end
	return fallback or M.ZERO
end

-- Heading of a direction: 0 along +Z, growing toward -X. Straight up has no heading (0).
function M.heading_of(direction)
	if direction.y > 0.99999 then
		return 0.0
	end
	return atan2(-direction.x, direction.z)
end

-- Skate 3's transition ease: 0.5 + 0.5 sin(pi t - pi/2).
function M.sine_blend(fraction)
	return 0.5 + 0.5 * sin(PI * fraction - PI / 2)
end

-- style 0 eases with sine_blend, 1 jumps to the target, anything else keeps the source.
function M.interpolate_float(from, to, style, fraction)
	if style == 0 then
		return from + (to - from) * M.sine_blend(fraction)
	elseif style == 1 then
		return to
	end
	return from
end

-- Blend-tree input filter: moves `previous` toward `raw` by (1 - smoothing)^2 of the gap, then clamps to
-- [minimum, maximum]. Deliberately NOT scaled by dt: run it on the fixed step only.
function M.filter_blend_value(previous, raw, smoothing, minimum, maximum)
	local response = 1.0 - smoothing
	local nxt = previous + response * response * (raw - previous)
	local lower = (minimum - nxt >= 0.0) and minimum or nxt
	return (maximum - lower >= 0.0) and lower or maximum
end

-- True for a finite number (false for NaN and +-inf).
function M.finite(x)
	return x - x == 0
end

-- True when all three components are finite.
function M.finite3(v)
	local s = v.x + v.y + v.z
	return s - s == 0
end

-- The game's camera matrices are rows {right, up, backward, position} (16 numbers, 1-based table).
-- Returns +1 or -1 for the sign of (right x up) . backward, 0 if the matrix is not a rotation.
function M.handedness(m)
	local r0 = vector.create(m[1], m[2], m[3])
	local r1 = vector.create(m[5], m[6], m[7])
	local r2 = vector.create(m[9], m[10], m[11])
	local h = vector.dot(vector.cross(r0, r1), r2)
	if h > 0.9 then
		return 1
	elseif h < -0.9 then
		return -1
	end
	return 0
end

-- Horizontal length of a vector (x, z).
function M.flat_length(v)
	local x, z = v.x, v.z
	return sqrt(x * x + z * z)
end

return M
