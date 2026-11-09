-- Joint Lock vertical translation tracking. The game glue supplies world joint positions every tick;
-- this module reads only their world Y values and never inspects rotations or horizontal coordinates.
local M = {}
local exp = math.exp
local MAX_OFFSET = 1.5 -- metres relative to the current skater root
local MAX_DT = 0.25
local MISSING_GRACE = 0.08 -- brief nil reads are expected on first request / joint-budget contention

local function finite(n)
	return type(n) == "number" and n - n == 0 and n > -math.huge and n < math.huge
end

local function y(v)
	if type(v) == "number" then return finite(v) and v or nil end
	local is_vector = false
	if type(v) ~= "table" and type(v) ~= "userdata" then
		local ok, kind = pcall(typeof, v)
		is_vector = ok and kind == "vector"
	end
	if type(v) == "table" or type(v) == "userdata" or is_vector then
		local ok, value = pcall(function() return v.y end)
		if ok and finite(value) then return value end
	end
	return nil
end

local function mix(a, b, wb)
	return a * (1.0 - wb) + b * wb
end

local function average(points, a, b)
	local ya, yb = y(points[a]), y(points[b])
	if ya and yb then return (ya + yb) * 0.5 end
	return ya or yb
end

local function selected_y(target, points)
	if target == "head" then
		return y(points.head)
	elseif target == "chest" then
		local chest = y(points.chest)
		if chest then return chest end
		local spine = y(points.spine)
		local upper = y(points.spine2)
		if spine and upper then return mix(spine, upper, 0.65) end
		return upper or spine
	elseif target == "feet" then
		return average(points, "left_foot", "right_foot")
	elseif target == "knee" then
		return average(points, "left_knee", "right_knee")
	elseif target == "hips" then
		local hips, spine = y(points.hips), y(points.spine)
		if hips and spine then return mix(hips, spine, 0.3) end
		return hips or spine
	elseif target == "skateboard" then
		return y(points.skateboard)
	end
	return nil
end

function M.new()
	return { initialized = false, trusted = false, world_y = 0.0, target = nil, missing_time = 0.0 }
end

function M.reset(state, root_y)
	if not state then return end
	state.initialized = false
	state.trusted = false
	state.world_y = finite(root_y) and root_y or 0.0
	state.target = nil
	state.missing_time = 0.0
end

-- `root_y` and all target positions are world-space. Returns a root-relative, clamped vertical
-- correction only. Damping filters absolute world height before subtracting the current root, so
-- rigid body translation (a pop or landing) is damped even when a joint's root-relative height is fixed.
function M.update(state, dt, cfg, root_y, points)
	state = state or M.new()
	points = type(points) == "table" and points or {}
	root_y = finite(root_y) and root_y or y(points.root)
	if not root_y then
		state.initialized, state.trusted, state.target, state.missing_time = false, false, nil, 0.0
		return { offset = 0.0, valid = false, target = cfg and cfg.joint_target or nil }
	end
	cfg = type(cfg) == "table" and cfg or {}
	local target = cfg.joint_target or "head"
	if cfg.camera_style ~= nil and cfg.camera_style ~= "joint_lock" then
		state.initialized, state.trusted, state.world_y, state.target, state.missing_time = false, false, root_y, target, 0.0
		return { offset = 0.0, valid = false, target = target }
	end
	local target_world_y = selected_y(target, points)
	if not target_world_y then
		-- Keep a briefly trusted world sample through expected nil reads, then ease to the live root.
		-- The filter still receives dt, so damping=0 intentionally takes the fallback immediately.
		local dt_safe = finite(dt) and math.max(0, math.min(MAX_DT, dt)) or 0
		state.missing_time = (state.missing_time or 0) + dt_safe
		if not state.initialized then
			state.initialized, state.world_y, state.target = true, root_y, target
		end
		local fallback_y = state.missing_time <= MISSING_GRACE and state.world_y or root_y
		local damping = finite(cfg.joint_damping) and math.max(0, math.min(100, cfg.joint_damping)) or 50.0
		if damping <= 0 then
			state.world_y = fallback_y
		else
			state.world_y += (fallback_y - state.world_y) * (1.0 - exp(-dt_safe / (0.0045 * damping)))
		end
		local offset = state.world_y - root_y
		if offset > MAX_OFFSET then offset = MAX_OFFSET elseif offset < -MAX_OFFSET then offset = -MAX_OFFSET end
		state.world_y = root_y + offset
		return { offset = offset, valid = false, target = target }
	end
	state.missing_time = 0.0
	local offset = target_world_y - root_y
	if offset > MAX_OFFSET then offset = MAX_OFFSET elseif offset < -MAX_OFFSET then offset = -MAX_OFFSET end
	target_world_y = root_y + offset
	if not state.trusted or not finite(state.world_y) then
		-- API joint reads are nil on first request. Do not treat that neutral fallback as a
		-- trusted sample; the first actual point seeds its real baseline so damping won't
		-- create a permanent offset drift after Glue establishes its display baseline.
		state.initialized, state.trusted, state.world_y, state.target, state.missing_time = true, true, target_world_y, target, 0.0
		return { offset = offset, valid = true, target = target }
	end
	local damping = finite(cfg.joint_damping) and math.max(0, math.min(100, cfg.joint_damping)) or 50.0
	if damping <= 0 then
		state.world_y, state.target = target_world_y, target
		return { offset = offset, valid = true, target = target }
	end
	-- 0% is immediate; 100% has a finite 0.45 s time constant. Exponential response is frame-rate independent.
	local tau = 0.0045 * damping
	dt = finite(dt) and math.max(0, math.min(MAX_DT, dt)) or 0
	local alpha = 1.0 - exp(-dt / tau)
	state.world_y += (target_world_y - state.world_y) * alpha
	state.target = target
	local filtered_offset = state.world_y - root_y
	if filtered_offset > MAX_OFFSET then filtered_offset = MAX_OFFSET elseif filtered_offset < -MAX_OFFSET then filtered_offset = -MAX_OFFSET end
	-- Keep the internal filter root-relative and bounded too. A large drop cannot leave a many-metre
	-- hidden world-height error that takes a long time to unwind after the visible output hits its clamp.
	state.world_y = root_y + filtered_offset
	return { offset = filtered_offset, valid = true, target = target }
end

M.max_offset = MAX_OFFSET
return M
