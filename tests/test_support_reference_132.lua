local T = require("tlib")
local Crouch = require("crouch")
local Subject = require("subject")
local vc = vector.create

T.group("support reference 132")

local dt = 1 / 60
local function snapshot(root, board, ground, state, normal_y)
	local s = Subject.new_snapshot()
	s.valid, s.onboard, s.ground_valid, s.board_valid = true, true, true, true
	s.physics_state = state or 100
	s.position, s.board_position = vc(0, root, 0), vc(0, board, 0)
	s.ground_height = ground
	s.ground_normal = vc(0, normal_y or 1, 0)
	return s
end

local function follow(amount, enabled)
	return { crouch_enabled = enabled ~= false, crouch_amount = amount, crouch_mode = 0 }
end

local function step(c, s, f)
	local value = Crouch.update(c, dt, s, f, false)
	T.expect_near(Crouch.sample(c, s), value, 1e-6, "render and step use the same support reference")
	return value
end

-- The two support heights differ by 0.3 m. Switching the chosen datum on an
-- unchanged frame must preserve the correction, even after repeated handoffs.
for _, normal_y in { 1, 0.8 } do
	for _, amount in { 0, 0.5, 1 } do
		local c, f = Crouch.new(), follow(amount)
		step(c, snapshot(0.95, 0, 0), f)
		local s = snapshot(0.65, 0, 0.3, 103, normal_y)
		local before = step(c, s, f)
		for i = 1, 6 do
			c.terrain_support = i % 2 == 1
			T.expect_near(step(c, s, f), before, 1e-6,
				"ground/board handoff preserves correction on flat or slope")
		end
		T.expect_near(c.compression, 0.6, 1e-6, "handoff retains unscaled compression")
	end
end

-- A board datum may first become valid while already crouched. Transfer the
-- ground reference instead of learning the crouched body as upright.
do
	local c, f = Crouch.new(), follow(0)
	local upright = snapshot(0.95, 0, 0)
	upright.board_valid = false
	step(c, upright, f)
	T.expect(c.board_baseline == nil, "board baseline initially unavailable")
	local compressed = snapshot(0.65, 0, 0, 103)
	T.expect_near(step(c, compressed, f), 0.3, 1e-6, "ground compression before board appears")
	c.terrain_support = true
	T.expect_near(step(c, compressed, f), 0.3, 1e-6, "board handoff preserves crouch with missing baseline")
	T.expect_near(c.board_baseline, 0.95, 1e-6, "board baseline transferred from upright ground datum")
	local upright_again = snapshot(0.95, 0, 0, 100)
	T.expect_near(step(c, upright_again, f), 0, 1e-6, "standing up releases transferred correction")
end

-- If the first seen pose is already crouched, there is no upright reference to
-- transfer. Handoffs must not invent one from the support height difference.
do
	local c, f = Crouch.new(), follow(0)
	local s = snapshot(0.65, 0, 0.3, 103)
	T.expect_near(Crouch.update(c, dt, s, f, false), 0, 1e-6, "crouched start has no guessed correction")
	c.terrain_support = true
	T.expect_near(Crouch.update(c, dt, s, f, false), 0, 1e-6, "source switch still has no guessed correction")
	T.expect(c.baseline == nil and c.board_baseline == nil, "no baseline learned from crouched start")
	T.expect(Crouch.sample(c, s) == nil, "render sample also waits for a reference")
end

-- Slider and toggle change only the applied weight. A support handoff must not
-- add a second movement while that control is easing.
do
	local c = Crouch.new()
	step(c, snapshot(0.95, 0, 0), follow(0))
	local s = snapshot(0.65, 0, 0, 103)
	step(c, s, follow(0))
	local half = follow(0.5)
	local before = step(c, s, half)
	c.terrain_support = true
	local after = step(c, s, half)
	T.expect(after <= before and before - after < 0.05, "handoff adds no pulse during slider easing")
	local disabled = follow(1, false)
	for _ = 1, 80 do step(c, s, disabled) end
	T.expect_near(c.offset, 0.3, 1e-5, "disabled toggle retains full compensation")
	c.terrain_support = false
	T.expect_near(step(c, s, disabled), 0.3, 1e-5, "toggle and support switch remain independent")
end

-- A rigid upright skater rotates through a quarter pipe without crouching.
-- Its world-Y body/board gap shrinks, while body length stays unchanged.
do
 local Crouch=require("crouch")
 local Subject=require("subject")
 local c=Crouch.new();c.terrain_support=true
 local s=Subject.new_snapshot();s.onboard=true;s.board_valid=true;s.ground_valid=true;s.physics_state=100
 s.board_position=vector.create(0,0,0);s.ground_height=0
 local follow={crouch_enabled=false,crouch_amount=1,crouch_mode=0}
 for i=0,180 do
  local angle=math.rad(i<=90 and i or 180-i)
  local axis=vector.create(0,math.cos(angle),math.sin(angle))
  s.position=axis*0.95;s.ground_normal=axis
  local lift=Crouch.update(c,1/60,s,follow,false)
  T.expect_near(lift,0,1e-5,"rigid ramp lean is not crouch compression")
  T.expect_near(Crouch.sample(c,s),0,1e-5,"render shares rotationally stable support")
 end
 for i=0,85,5 do
  local angle=math.rad(i);local axis=vector.create(0,math.cos(angle),math.sin(angle))
  s.position=axis*0.65;s.ground_normal=axis;s.physics_state=103
  local lift=Crouch.update(c,1/60,s,follow,false)
  T.expect_near(lift,0.3*math.cos(angle),1e-5,"crouch compensation follows vertical part of body compression")
 end
end
T.done()
if T.failures > 0 then error("support reference tests failed") end
