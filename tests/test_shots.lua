-- Port of Engine/Game/Camera/Test/s3cam_shot_tests.cpp
-- Note: blend_interval indices are 1-based here (the C++ test's 0 is 1, 1 is 2, 2 is 3).
local T = require("tlib")
local S = require("s3math")
local Shots = require("shots")
T.group("shots")
local near, expect = T.near, T.expect
local degrees = S.degrees
local nan = 0 / 0

local function shot_a()
	local s = Shots.new()
	s.distance = 2.0
	s.lens_length = 12.0
	s.smoothing = { 0.5, 0.6, 0.7, 0.8 }
	s.reference_weights = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	s.board_offset = 1.0
	s.position_elevation = 0.1
	s.framing = { 0.0, 0.2, 0.4 }
	s.follow_subject_in_air = true
	s.mirror_for_stance = false
	s.use_drop_predictor = false
	s.use_free_camera_stick = false
	s.position_heading = 1.0
	return s
end
local function shot_b()
	local s = shot_a()
	s.distance = 4.0
	s.lens_length = 20.0
	s.smoothing = { 0.1, 0.2, 0.3, 0.4 }
	s.reference_weights = { 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 }
	s.board_offset = 3.0
	s.position_elevation = 0.5
	s.framing = { 0.2, 0.6, 1.0 }
	s.follow_subject_in_air = false
	s.mirror_for_stance = true
	s.use_drop_predictor = true
	s.use_free_camera_stick = true
	s.position_heading = 2.0
	return s
end

do -- blend endpoints
	local a, b = shot_a(), shot_b()
	local at0 = Shots.interpolate(a, b, 0.0)
	expect(near(at0.distance, 2.0) and near(at0.lens_length, 12.0), "t=0 floats are the source")
	expect(near(at0.smoothing[4], 0.8) and near(at0.board_offset, 1.0), "t=0 smoothing and offset are the source")
	expect(near(at0.reference_weights[1], 1.0) and near(at0.reference_weights[5], 0.0), "t=0 weights are the source")
	expect(near(at0.framing[3], 0.4) and near(at0.position_elevation, 0.1), "t=0 framing and elevation are the source")

	local mid = Shots.interpolate(a, b, 0.5)
	expect(near(mid.distance, 3.0), "t=0.5 distance is the midpoint")
	expect(near(mid.lens_length, 16.0), "t=0.5 lens")
	expect(near(mid.smoothing[1], 0.3) and near(mid.smoothing[4], 0.6), "t=0.5 smoothing")
	expect(near(mid.reference_weights[1], 0.5) and near(mid.reference_weights[5], 0.5), "t=0.5 weights")
	expect(near(mid.board_offset, 2.0) and near(mid.position_elevation, 0.3), "t=0.5 offset and elevation")
	expect(near(mid.framing[1], 0.1) and near(mid.framing[2], 0.4) and near(mid.framing[3], 0.7), "t=0.5 framing")

	local at1 = Shots.interpolate(a, b, 1.0)
	expect(near(at1.distance, 4.0) and near(at1.lens_length, 20.0), "t=1 floats are the target")
	expect(near(at1.smoothing[3], 0.3) and near(at1.framing[2], 0.6), "t=1 smoothing and framing are the target")
	expect(near(at1.reference_weights[5], 1.0) and near(at1.board_offset, 3.0), "t=1 weights and offset are the target")

	local quarter = Shots.interpolate(a, b, 0.25)
	expect(quarter.distance < 2.0 + 2.0 * 0.25, "the ease is slower than linear early on")
	expect(near(quarter.distance, 2.0 + 2.0 * S.sine_blend(0.25)), "uses sine_blend")

	-- reusing an output table gives the same result and does not touch the inputs
	local reuse = Shots.new()
	Shots.interpolate(a, b, 0.5, reuse)
	expect(near(reuse.distance, mid.distance) and near(a.distance, 2.0) and near(b.distance, 4.0), "out table reuse")
end

do -- discrete flags
	local a, b = shot_a(), shot_b()
	for _, t in { 0.0, 0.5, 1.0 } do
		local r = Shots.interpolate(a, b, t)
		expect(r.follow_subject_in_air == b.follow_subject_in_air, "follow_subject_in_air from the target")
		expect(r.mirror_for_stance == b.mirror_for_stance, "mirror_for_stance from the target")
		expect(r.use_drop_predictor == b.use_drop_predictor, "use_drop_predictor from the target")
		expect(r.use_free_camera_stick == b.use_free_camera_stick, "use_free_camera_stick from the target")
		expect(near(r.position_heading, b.position_heading), "heading is not blended: it stays the target's")
	end
	local back = Shots.interpolate(b, a, 0.0)
	expect(back.follow_subject_in_air and not back.use_drop_predictor, "flags switch at t=0 when the target differs")
	expect(Shots.valid(Shots.interpolate(a, b, 0.37)), "a blend of valid shots is valid")
end

do -- blend_interval
	local p = { 1.0, 5.0, 10.0 }
	local all = { true, true, true }
	local bi = Shots.blend_interval
	expect(bi(p, { false, true, true }, 3.0) == nil, "no first child: nothing is published")

	local lo, up, fr = bi(p, all, 0.0)
	expect(lo == 1 and up == 1 and near(fr, 1.0), "below the first point is child 1")
	lo, up, fr = bi(p, all, 1.0)
	expect(lo == 1 and up == 2 and near(fr, 0.0), "at the first point starts the first span")
	lo, up, fr = bi(p, all, 3.0)
	expect(lo == 1 and up == 2 and near(fr, 0.5), "mid first span")
	lo, up, fr = bi(p, all, 7.5)
	expect(lo == 2 and up == 3 and near(fr, 0.5), "mid second span")
	lo, up, fr = bi(p, all, 10.0)
	expect(lo == 2 and up == 3 and near(fr, 1.0), "at the last point is the last child")
	lo, up, fr = bi(p, all, 99.0)
	expect(lo == 2 and up == 3 and near(fr, 1.0), "above the last point is the last child")

	lo, up, fr = bi(p, { true, false, true }, 0.0)
	expect(lo == 1 and up == 1 and near(fr, 1.0), "one child, below")
	lo, up, fr = bi(p, { true, false, false }, 50.0)
	expect(lo == 1 and up == 1 and near(fr, 1.0), "one child, above: no underflow")
	lo, up, fr = bi(p, { true, true, false }, 3.0)
	expect(lo == 1 and up == 2 and near(fr, 0.5), "two children")
	lo, up, fr = bi(p, { true, true, false }, 50.0)
	expect(lo == 1 and up == 2 and near(fr, 1.0), "two children, above")
	lo, up, fr = bi(p, all, nan)
	expect(up == 3 and near(fr, 1.0), "NaN lands on the last child")
	lo, up, fr = bi(p, { true, false, true }, 5.0)
	expect(up == 1, "children after a gap are ignored")
end

do -- validity
	expect(Shots.valid(Shots.new()), "the default Shot is valid")
	local function bad(mutate, what)
		local s = Shots.new()
		mutate(s)
		expect(not Shots.valid(s), what)
	end
	bad(function(s) s.distance = 0 end, "zero distance")
	bad(function(s) s.distance = nan end, "NaN distance")
	bad(function(s) s.lens_length = -1 end, "negative lens")
	bad(function(s) s.smoothing[3] = 1.5 end, "smoothing above 1")
	bad(function(s) s.reference_weights = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } end, "all-zero weights")
	bad(function(s) s.reference_weights[2] = -0.5 end, "negative weight")
	bad(function(s) s.position_elevation = 2.0 end, "elevation past straight up")
	bad(function(s) s.framing[1] = math.huge end, "infinite framing")
end

do -- table
	expect(#Shots.default_shots == Shots.default_shot_count, "table size")
	local seen = {}
	for _, e in Shots.default_shots do
		expect(Shots.valid(e.shot), "every default shot is valid: " .. e.name)
		expect(near(e.shot.lens_length, 12.0), "lens 12 for every shot")
		expect(Shots.find_shot(e.name) == e.shot, "every default shot is findable by name")
		expect(not seen[e.name], "names are unique")
		seen[e.name] = true
	end
	expect(Shots.find_shot("no_such_shot") == nil and Shots.find_shot("") == nil, "unknown names give nil")
	expect(Shots.find_shot("Chase_Flat_Slow") == nil, "names are lowercase and exact")
	for _, name in {
		"chase_flat_slow", "chase_flat_fast", "chase_up_slow", "chase_down", "grind_flat_slow", "grind_ledge_l",
		"grind_ledge_r", "far_manual", "close_manual", "low_ollie", "air_high", "landing", "wipeout", "high_chase",
		"high_chase2", "high_grind", "high_manual", "bl_high_air",
	} do
		expect(Shots.find_shot(name) ~= nil, "card shot name present: " .. name)
	end
end

do -- section 1.3
	local rows = {
		{ "chase_flat_slow", Shots.Low, 1.8, 7.0, -4.0, 0.9 },
		{ "chase_flat_fast", Shots.Low, 2.5, 5.0, -2.0, 0.9 },
		{ "chase_up_slow", Shots.Low, 2.1, -5.0, -10.0, 0.9 },
		{ "high_chase", Shots.High, 3.0, 30.0, 3.0, 1.0 },
		{ "high_chase2", Shots.High, 4.4, 26.6, 5.0, 1.0 },
		{ "grind_flat_slow", Shots.Low, 1.5, 7.0, -10.0, 0.6 },
		{ "high_grind", Shots.High, 2.9, 17.0, 5.0, 1.0 },
		{ "far_manual", Shots.Low, 2.35, 13.0, -2.0, 0.9 },
		{ "close_manual", Shots.Low, 1.1, -5.0, -8.0, 0.5 },
		{ "high_manual", Shots.High, 2.25, 19.0, 0.0, 1.0 },
	}
	for _, row in rows do
		local e = Shots.find_named_shot(row[1])
		expect(e ~= nil, "published shot exists")
		if e then
			expect(e.angle == row[2], "published shot is in the right camera")
			expect(near(e.shot.distance, row[3]), "section 1.3 distance")
			expect(near(e.shot.position_elevation, row[4] * degrees, 1e-5), "section 1.3 elevation")
			expect(near(e.shot.framing[3], row[5] * degrees, 1e-5), "section 1.3 framing pitch")
			expect(near(e.shot.board_offset, row[6]), "section 1.3 board offset")
		end
	end
	local low_max, high_min = 0, 1e9
	local chase_like = { chase_flat_slow = 1, chase_flat_fast = 1, chase_up_slow = 1, high_chase = 1, high_chase2 = 1 }
	for _, e in Shots.default_shots do
		if chase_like[e.name] then
			if e.angle == Shots.Low then
				low_max = math.max(low_max, e.shot.distance)
				expect(e.shot.position_elevation <= 7.0 * degrees + 1e-5 and e.shot.position_elevation >= -5.0 * degrees - 1e-5,
					"Low chase elevation within -5..+7 degrees")
			else
				high_min = math.min(high_min, e.shot.distance)
				expect(e.shot.position_elevation >= 26.0 * degrees, "High chase elevation 26.6..30 degrees")
			end
		end
	end
	expect(low_max < high_min, "every Low chase is closer than every High chase")
	-- the ledge shots lean the other way round
	expect(near(Shots.find_shot("grind_ledge_l").position_heading, S.pi - 25 * degrees), "ledge L heading")
	expect(near(Shots.find_shot("grind_ledge_r").position_heading, S.pi + 25 * degrees), "ledge R heading")
end

T.done()
