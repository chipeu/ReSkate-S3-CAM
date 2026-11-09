-- Ground-relative framing. Never changes the physics snapshot, terrain, or landing inputs.
local M = {}
local PS = require("subject").physics_state
local function finite(n)
	return type(n) == "number" and n - n == 0
end
local function riding_height(s)
	local riding = s.onboard and not s.bailing and not s.manual and s.physics_state >= 100 and s.physics_state < 200
	if not riding or s.ground_valid ~= true or not finite(s.ground_height) or s.ground_normal.y < 0.5 then return nil end
	local h = s.position.y - s.ground_height
	return h >= 0.15 and h <= 1.8 and h or nil
end

-- Render ticks can arrive between simulation steps. Sample the same virtual height there,
-- otherwise the render carry would add rising-body motion back at high frame rates.
function M.sample(c, s)
	local h = riding_height(s)
	if h == nil or c.baseline == nil then return nil end
	return math.clamp(c.baseline - h, -0.6, 0.6) * (c.weight or 0.0)
end

function M.new()
	return { baseline = nil, offset = 0.0, weight = nil }
end

function M.reset(c)
	c.baseline, c.offset = nil, 0.0
	c.weight = nil
end

function M.update(c, dt, s, follow, cut)
	if cut or s.bailing or not s.onboard then M.reset(c) end
	local state = s.physics_state
	local height = riding_height(s)
	local known = height ~= nil
	local target = 0.0
	local amount = follow.crouch_enabled and follow.crouch_amount or 0.0
	local weight = 1.0 - amount
	if c.weight == nil then c.weight = weight end
	-- Smooth the player's control, not the body signal: otherwise Off would still dip then catch up.
	c.weight += (weight - c.weight) * (1.0 - math.exp(-dt / 0.10))
	if math.abs(weight - c.weight) < 1e-5 then c.weight = weight end
	-- Keep an upright body-to-ground distance, not a world-space height. Relearning it during
	-- ride state absorbs the animation before state 103 and makes Off still follow the body.
	if known then
		if c.baseline == nil and state ~= PS.crouch then c.baseline = height end
		if c.baseline ~= nil then target = math.clamp(c.baseline - height, -0.6, 0.6) * c.weight end
	end
	-- Both body lowering and rising are removed. Keep the relative reference through a jump
	-- or missing ray so landing compression cannot become a new neutral pose.
	if known and c.baseline ~= nil then
		c.offset = target
	else
		c.offset += (target - c.offset) * (1.0 - math.exp(-dt / 0.10))
	end
	if target == 0.0 and math.abs(c.offset) < 1e-5 then c.offset = 0.0 end
	return c.offset
end

return M
