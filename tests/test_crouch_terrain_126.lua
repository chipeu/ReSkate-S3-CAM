local T = require("tlib")
local Crouch = require("crouch")
local Subject = require("subject")
local vc = vector.create
T.group("crouch terrain 126")

local function snapshot(root, board, terrain, state)
	local s = Subject.new_snapshot()
	s.valid, s.onboard, s.ground_valid, s.board_valid = true, true, true, true
	s.physics_state = state or 100
	s.position, s.board_position = vc(0, root, 0), vc(0, board, 0)
	s.ground_height, s.ground_normal = terrain, vc(0, 1, 0)
	return s
end
local function follow(amount)
	return { crouch_enabled = true, crouch_amount = amount, crouch_mode = 0 }
end
local function step(c, s, amount)
	return Crouch.update(c, 1 / 60, s, follow(amount), false)
end

do -- Establish legacy and board neutral references, then vary only the ray datum.
	local c = Crouch.new()
	step(c, snapshot(0.95, 0, 0), 0)
	T.expect(T.near(c.baseline, 0.95) and T.near(c.board_baseline, 0.95), "both upright baselines established")
	c.terrain_support = true
	for _, terrain in { 0.344, 0.28, -0.2, 0.4 } do
		local s = snapshot(0.95, 0, terrain)
		T.expect_near(step(c, s, 0), 0, 1e-6, "ray-only stair variation makes no fake compensation")
		T.expect_near(Crouch.sample(c, s), 0, 1e-6, "render sample matches fixed-step board datum")
		T.expect_near(c.baseline, 0.95, 1e-6, "board support does not relearn ground baseline")
	end
	local s = snapshot(0.65, 0, 0.344, 103)
	T.expect_near(step(c, s, 0), 0.3, 1e-5, "actual 0.3 m body crouch compensated at Pop Off")
	T.expect_near(Crouch.sample(c, s), 0.3, 1e-5, "render sample matches actual crouch")
	T.expect_near(Crouch.sample(c, snapshot(0.95, 0, 0.344, 103), 0.65), 0.3, 1e-5,
		"raw render root override uses the board datum")
	T.expect_near(c.baseline, 0.95, 1e-6, "actual crouch does not alter legacy ground baseline")
end

do -- Board support can establish its own upright datum without contaminating ground baseline.
	local c = Crouch.new()
	c.terrain_support = true
	local s = snapshot(0.95, 0, 0.344)
	T.expect_near(step(c, s, 0), 0, 1e-6, "initial board support is neutral")
	T.expect(c.baseline == nil and T.near(c.board_baseline, 0.95), "board datum does not seed ground baseline")
end

do -- Pop On follows the actual body lowering; intermediate strength scales it.
	for _, amount in { 0.5, 1 } do
		local c = Crouch.new()
		step(c, snapshot(0.95, 0, 0), amount)
		c.terrain_support = true
		local s = snapshot(0.65, 0, 0.344, 103)
		local expected = 0.3 * (1 - amount)
		T.expect_near(step(c, s, amount), expected, 1e-5, "terrain crouch respects strength " .. amount)
		T.expect_near(Crouch.sample(c, s), expected, 1e-5, "sample respects strength " .. amount)
	end
end

do -- Disabled flag and missing board data retain the ground-relative behavior.
	local c = Crouch.new()
	step(c, snapshot(0.95, 0, 0), 0)
	local s = snapshot(0.95, 0, 0.344)
	T.expect_near(step(c, s, 0), 0.344, 1e-5, "flag off preserves legacy ray compensation")
	Crouch.reset(c)
	T.expect(c.terrain_support == false and c.board_baseline == nil, "reset clears optional terrain flag and board baseline")
	step(c, snapshot(0.95, 0, 0), 0)
	c.terrain_support = true
	s.board_valid = false
	T.expect_near(step(c, s, 0), 0.344, 1e-5, "missing board data uses legacy ground measurement")
end

do -- Air ignores even a wildly drawn board pose while the support flag remains set.
	local c = Crouch.new()
	step(c, snapshot(0.95, 0, 0), 0)
	c.terrain_support = true
	local s = snapshot(1.8, 8, 0, 201)
	T.expect(Crouch.sample(c, s) == nil, "air render sample ignores drawn board")
	T.expect(math.abs(step(c, s, 0)) < 1e-6, "air update ignores drawn board")
	T.expect_near(c.board_baseline, 0.95, 1e-6, "air does not learn board baseline")
end

T.done()
