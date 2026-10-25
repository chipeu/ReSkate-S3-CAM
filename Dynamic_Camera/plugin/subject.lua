-- Port of Engine/Game/Camera/s3_subject.h: what the camera knows about the skater on one frame.
-- Plain data, no game types, so the camera core can be driven by scripted subjects.
--
-- API:
--   Subject.physics_state          { ride = 100, brief_after_air = 101, crouch = 103, pop = 200, air = 201,
--                                    grind_first = 400, grind_last = 499, offboard = 504, brief = 601, post_grind = 701 }
--   Subject.is_air_state(state) / Subject.is_grind_state(state)
--   Subject.new_snapshot()         a SubjectSnapshot with the C++ defaults (valid = false)
--   Subject.air(s) / Subject.grinding(s)   the snapshot's physics_state tested for air / grind
--   Subject.usable(s)              true when the snapshot can drive the camera: flagged valid, every number finite,
--                                  a forward with a direction, a ground normal with a direction
--
-- Snapshot fields (vectors are Luau vectors, Y up):
--   time (s, publisher clock, diagnostics only), position, forward (unit), velocity (m/s), physics_state (number),
--   onboard, bailing, manual, grind_side (-1 ledge on the left, 0 unknown/flat, +1 on the right), switch_stance,
--   board_position, board_valid, ground_normal, ground_clearance (m), valid

local S3 = require("s3math")

local M = {}

local vcreate = vector.create
local vmagnitude = vector.magnitude
local ZERO = S3.ZERO

-- skate. physics state values (context +0x1414), measured in game.
M.physics_state = {
	ride = 100,
	brief_after_air = 101,
	crouch = 103,
	pop = 200,
	air = 201,
	grind_first = 400,
	grind_last = 499,
	offboard = 504,
	brief = 601,
	post_grind = 701,
}
local PS = M.physics_state

function M.is_air_state(state)
	return state == PS.pop or state == PS.air
end

function M.is_grind_state(state)
	return state >= PS.grind_first and state <= PS.grind_last
end

function M.new_snapshot()
	return {
		time = 0.0, -- s, publisher clock (diagnostics only; the camera uses its own dt)
		position = ZERO, -- skater root, Y up
		forward = vcreate(0, 0, 1), -- unit, entity row 2
		velocity = ZERO, -- m/s
		physics_state = PS.ride,
		onboard = true, -- false off the board (state 504); the camera then holds unless bailing
		bailing = false, -- the wipeout shot
		manual = false, -- native source still unknown: may always be false in game
		grind_side = 0, -- -1 ledge on the left, 0 unknown/flat, +1 on the right
		switch_stance = false, -- carried for the glue; no shot uses it yet
		board_position = ZERO, -- the board's real centre (its root physics body), when board_valid
		board_valid = false, -- false: use the estimate (root - board_drop)
		ground_normal = vcreate(0, 1, 0),
		ground_clearance = 0.95, -- m, root height above the ground beneath it (~0.95 riding)
		valid = false, -- false: the publisher had no trustworthy data this frame
	}
end

function M.air(s)
	return M.is_air_state(s.physics_state)
end

function M.grinding(s)
	return M.is_grind_state(s.physics_state)
end

local function finite3(v)
	local sum = v.x + v.y + v.z
	return sum - sum == 0
end

function M.usable(s)
	local t, gc = s.time, s.ground_clearance
	return s.valid and t - t == 0 and finite3(s.position) and finite3(s.forward) and finite3(s.velocity)
		and finite3(s.ground_normal) and finite3(s.board_position) and gc - gc == 0
		and vmagnitude(s.forward) > 1e-4 and vmagnitude(s.ground_normal) > 1e-4
		and s.grind_side >= -1 and s.grind_side <= 1
end

return M
