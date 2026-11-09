-- Ground-relative framing. Never changes the physics snapshot, terrain, or landing inputs.
local M = {}
local PS = require("subject").physics_state
local function finite(n)
	return type(n) == "number" and n - n == 0
end
local function riding_height(c, s, root_y)
	local riding = s.onboard and not s.bailing and not s.manual and s.physics_state >= 100 and s.physics_state < 200
	if not riding or s.ground_valid ~= true then return nil end
	if c.terrain_support and s.board_valid and s.board_position and finite(s.board_position.y) then
		local h = (root_y or s.position.y) - s.board_position.y
		return h >= 0.15 and h <= 1.8 and h or nil, "board"
	end
	if not finite(s.ground_height) or not s.ground_normal or s.ground_normal.y < 0.5 then return nil end
	local h = (root_y or s.position.y) - s.ground_height
	return h >= 0.15 and h <= 1.8 and h or nil, "ground"
end
local function recent_height(c,s,root_y)
	if s.ground_valid==true or not s.onboard or s.bailing or s.manual
		or s.physics_state<100 or s.physics_state>=200 or c.last_ground_height==nil
		or not s.ground_normal or s.ground_normal.y<0.5
		or not finite(s.ground_height) or math.abs(s.ground_height-c.last_ground_height)>0.2
		or (c.missing_time or 0)>0.12 then return nil end
	local h=(root_y or s.position.y)-s.ground_height
	return h>=0.15 and h<=1.8 and h or nil
end

-- Render ticks can arrive between simulation steps. Sample the same virtual height there,
-- otherwise the render carry would add rising-body motion back at high frame rates.
function M.sample(c, s, root_y)
	local h, source = riding_height(c,s,root_y)
	if h==nil then h=recent_height(c,s,root_y) end
	if h == nil then
		if s.ground_valid~=true and s.onboard and not s.bailing and not s.manual
			and s.ground_normal and s.ground_normal.y>=0.5
			and s.physics_state>=100 and s.physics_state<200 and (c.missing_time or 0)<=0.12 then
			return c.offset
		end
		return nil
	end
	local baseline = source == "board" and c.board_baseline or c.baseline
	if baseline == nil then return nil end
	return math.clamp(baseline - h, -0.6, 0.6) * (c.weight or 0.0)
end

function M.new()
	return { baseline = nil, board_baseline = nil, terrain_support = false,
		offset = 0.0, weight = nil, missing_time = 0.0, last_ground_height = nil }
end

function M.reset(c)
	c.baseline, c.offset = nil, 0.0
	c.weight = nil
	c.pitch_amount=0
	c.missing_time=0
	c.last_ground_height=nil
	c.board_baseline=nil
	c.terrain_support=false
end

function M.update(c, dt, s, follow, cut)
	if cut or s.bailing or not s.onboard then M.reset(c) end
	local state = s.physics_state
	local height, source = riding_height(c,s)
	local known = height ~= nil
	local missing_ray=not known and s.ground_valid~=true and s.onboard and not s.bailing
		and s.ground_normal and s.ground_normal.y>=0.5
		and not s.manual and state>=100 and state<200
	c.missing_time=missing_ray and (c.missing_time or 0)+dt or 0
	if known and finite(s.ground_height) then c.last_ground_height=s.ground_height end
	if known and state~=PS.crouch and c.board_baseline==nil and s.board_valid then
		local gap=s.position.y-s.board_position.y
		if finite(gap) and gap>=0.2 and gap<=1.8 then c.board_baseline=gap end
	end
	local fallback=not known and recent_height(c,s)
	if fallback then height=fallback; source="ground" end
	local target = 0.0
	local amount = follow.crouch_enabled and follow.crouch_amount or 0.0
	local pitch = follow.crouch_mode==1
	local wanted_pitch=pitch and amount or 0
	c.pitch_amount=(c.pitch_amount or 0)+(wanted_pitch-(c.pitch_amount or 0))*(1-math.exp(-dt/0.10))
	local weight = pitch and 1.0 or (1.0 - amount)
	if c.weight == nil then c.weight = weight end
	-- Smooth the player's control, not the body signal: otherwise Off would still dip then catch up.
	c.weight += (weight - c.weight) * (1.0 - math.exp(-dt / 0.10))
	if math.abs(weight - c.weight) < 1e-5 then c.weight = weight end
	-- Keep an upright body-to-ground distance, not a world-space height. Relearning it during
	-- ride state absorbs the animation before state 103 and makes Off still follow the body.
	local baseline=source=="board" and c.board_baseline or c.baseline
	if height~=nil then
		if known and source~="board" and c.baseline == nil and state ~= PS.crouch then
			c.baseline = height; baseline = height
		end
		if baseline ~= nil then target = math.clamp(baseline - height, -0.6, 0.6) * c.weight end
	end
	-- Both body lowering and rising are removed. Keep the relative reference through a jump
	-- or missing ray so landing compression cannot become a new neutral pose.
	if height~=nil and baseline ~= nil then
		c.offset = target
	elseif missing_ray and c.missing_time<=0.12 and c.baseline~=nil then
		-- A transient missing ground ray contains no evidence that the body
		-- returned upright. Keep the last body-relative correction briefly.
	else
		c.offset += (target - c.offset) * (1.0 - math.exp(-dt / 0.10))
	end
	if target == 0.0 and math.abs(c.offset) < 1e-5 then c.offset = 0.0 end
	return c.offset
end

-- Pitch mode holds the eye level but retains a share of the crouching body's
-- lowering in the look target. Height mode keeps the previous math exactly.
function M.aim(c)
	return c.offset*(1-(c.pitch_amount or 0))
end

return M
