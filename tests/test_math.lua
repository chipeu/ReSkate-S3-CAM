-- Port of Engine/Game/Camera/Test/s3cam_math_tests.cpp
local T = require("tlib")
local S = require("s3math")
T.group("math")
local near, expect = T.near, T.expect
local pi, tau, degrees = S.pi, S.tau, S.degrees
local wrap_angle = S.wrap_angle

expect(near(wrap_angle(0), 0), "0 stays 0")
expect(near(wrap_angle(pi / 2), pi / 2), "inside the range is unchanged")
expect(near(wrap_angle(3 * pi / 2), -pi / 2), "270 degrees wraps to -90")
expect(near(wrap_angle(-3 * pi / 2), pi / 2), "-270 degrees wraps to 90")
expect(near(wrap_angle(5 * tau + 0.25), 0.25, 1e-4), "whole turns are removed")
expect(near(wrap_angle(pi), -pi), "pi maps to the lower bound")
local nan = 0 / 0
local w = wrap_angle(nan)
expect(w ~= w, "non-finite passes through for the caller to reject")
expect(wrap_angle(math.huge) == math.huge, "inf passes through")
local a = -20
while a < 20 do
	local r = wrap_angle(a)
	expect(r >= -pi and r < pi, "always in [-pi, pi)")
	a += 0.37
end

local half = S.blend_angle(170 * degrees, -170 * degrees, 0.5)
expect(near(math.abs(half), pi, 1e-4), "blending across +-180 goes the short way")
expect(near(S.blend_angle(0.1, 0.5, 1), 0.5), "weight 1 reaches the target")
expect(near(S.blend_angle(0.1, 0.5, 0), 0.1), "weight 0 stays")

expect(near(S.sine_blend(0), 0), "ease starts at 0")
expect(near(S.sine_blend(0.5), 0.5), "ease is half way at half time")
expect(near(S.sine_blend(1), 1), "ease ends at 1")
expect(S.sine_blend(0.01) < 0.01 and S.sine_blend(0.99) > 0.99, "ease is slow at both ends")
expect(near(S.interpolate_float(2, 4, 0, 0.5), 3), "style 0 eases")
expect(near(S.interpolate_float(2, 4, 1, 0.1), 4), "style 1 jumps to the target")
expect(near(S.interpolate_float(2, 4, 7, 0.9), 2), "other styles keep the source")

local f = S.filter_blend_value
expect(near(f(0, 10, 0, -100, 100), 10), "no smoothing takes the raw value")
expect(near(f(0, 10, 0.5, -100, 100), 2.5), "smoothing 0.5 moves (0.5)^2 of the gap")
expect(near(f(0, 10, 1, -100, 100), 0), "smoothing 1 holds")
expect(near(f(0, 10, 0, -1, 1), 1), "clamped to the maximum")
expect(near(f(0, -10, 0, -1, 1), -1), "clamped to the minimum")
local value = 0
for _ = 1, 400 do
	value = f(value, 5, 0.8, 0, 10)
end
expect(near(value, 5, 1e-3), "repeated updates converge on the raw value")

expect(near(S.length(vector.create(3, 4, 0)), 5), "length")
expect(near(S.normalized(vector.create(0, 0, 2)).z, 1), "normalized")
expect(near(S.normalized(vector.create(0, 0, 0), vector.create(1, 0, 0)).x, 1), "a zero vector takes the fallback")
expect(near(vector.cross(vector.create(1, 0, 0), vector.create(0, 1, 0)).z, 1), "x cross y is z")
expect(near(S.lerp(vector.create(0, 0, 0), vector.create(2, 4, 6), 0.5).y, 2), "lerp")
expect(S.lerp(2, 4, 0.25) == 2.5, "lerp on numbers")

-- heading_of: 0 along +Z, grows toward -X; straight up has no heading.
expect(near(S.heading_of(vector.create(0, 0, 1)), 0), "heading of +Z is 0")
expect(near(S.heading_of(vector.create(1, 0, 0)), -pi / 2), "heading of +X is -pi/2")
expect(S.heading_of(vector.create(0, 1, 0)) == 0, "straight up has no heading")

-- handedness
local rot = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
expect(S.handedness(rot) == 1, "identity rotation is +1")
local mirrored = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1 }
expect(S.handedness(mirrored) == -1, "mirrored is -1")
expect(S.handedness({ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }) == 0, "not a rotation is 0")

T.done()
