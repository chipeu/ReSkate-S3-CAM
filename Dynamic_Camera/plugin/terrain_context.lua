-- Measured terrain context for the Pop Off camera. This module owns no pose or saved setting.
-- update(input, dt, query) returns one weight toward the normal Pop On height/view target.
-- query(from, to, false) returns a hit point; normals are not needed for vertical probes.
local M = {}
local C = {}
C.__index = C

local abs, max, min, sqrt, exp = math.abs, math.max, math.min, math.sqrt, math.exp
local function finite(x) return type(x) == "number" and x == x and x > -1e9 and x < 1e9 end
local function point(v) return v and finite(v.x) and finite(v.y) and finite(v.z) end
local function clamp(x) return max(0, min(1, x)) end
local function output(self, rays)
	return { weight = self.weight, target = self.target, confidence = self.confidence,
		reason = self.reason, transition_weight = self.transition_weight,
		ahead_height = self.ahead_height, rays = rays }
end

function M.new()
	return setmetatable({ weight = 0, weight_velocity = 0, target = 0, confidence = 0, reason = "flat",
		transition_weight = 0, transition_velocity = 0,
		probe_clock = 0.1, steep_hold = 0, steep_seen = false, rail_time = 0, rail_hold = 0,
		drop_hold = 0, rise_hold = 0, ahead_height = nil, support_height = nil,
		flat_time = 0, probe_age = 1, probe_rise = nil, probe_drop = nil }, C)
end

function C:reset()
	self.weight, self.weight_velocity, self.target, self.confidence, self.reason = 0, 0, 0, 0, "flat"
	self.transition_weight, self.transition_velocity = 0, 0
	self.probe_clock, self.steep_hold, self.steep_seen, self.rail_time, self.rail_hold = 0.1, 0, false, 0, 0
	self.drop_hold, self.rise_hold, self.ahead_height, self.support_height = 0, 0, nil, nil
	self.flat_time, self.probe_age, self.probe_rise, self.probe_drop = 0, 1, nil, nil
end

-- Two short horizontal lookaheads, each with one bounded vertical ray. The probe starts
-- above an attainable raised ledge and reaches below a plausible stair landing.
local function probe(self, p, v, datum, query)
	local speed = sqrt(v.x * v.x + v.z * v.z)
	if speed < 1 or type(query) ~= "function" or abs(datum - p.y) > 6 then return nil, 0 end
	local count, rise, drop, best = 0, false, false, nil
	for _, horizon in { 0.15, 0.35 } do
		local distance = min(5, speed * horizon)
		local x, z = p.x + v.x / speed * distance, p.z + v.z / speed * distance
		local top = max(p.y, datum) + 2.6
		local bottom = datum - 3.6
		local hit = query(vector.create(x, top, z), vector.create(x, bottom, z), false)
		count += 1
		if point(hit) and abs(hit.x - x) < 0.15 and abs(hit.z - z) < 0.15
			and hit.y <= top and hit.y >= bottom then
			local delta = hit.y - datum
			local reachable_top = p.y + max(v.y, 0) * horizon + 0.65
			if delta >= 0.35 and hit.y <= reachable_top then
				rise = true; best = max(best or hit.y, hit.y)
			end
			if delta <= -0.9 and delta >= -3.5 then drop = true; best = min(best or hit.y, hit.y) end
		end
	end
	self.ahead_height = best
	return { rise = rise, drop = drop }, count
end

function C:update(input, dt, query)
	if input and input.cut then self:reset(); return output(self, 0) end
	if type(input) ~= "table" or not point(input.position) or not point(input.velocity)
		or not finite(dt) or dt <= 0 or dt > 0.2 then
		self:reset(); self.reason = "invalid"; return output(self, 0)
	end
	local p, v = input.position, input.velocity
	local state = input.state or input.physics_state
	local air = state == 200 or state == 201
	local grinding = input.grinding == true or (type(state) == "number" and state >= 400 and state <= 499)
	local grounded = input.ground_valid == true and finite(input.ground_height)
		and not air and not grinding and input.grounded ~= false
	if grounded then self.support_height = input.ground_height end
	local datum = finite(input.launch_height) and input.launch_height or self.support_height
	local normal = input.ground_normal
	local steep = grounded and point(normal) and normal.y > -0.05 and normal.y < 0.766
		and (abs(v.y) > 0.35 or input.transition == true)
	if steep then
		self.steep_seen, self.steep_hold = true, 0.48
	elseif air and (self.steep_seen or self.steep_hold>0) then
		-- A lip can briefly report level support before the first airborne
		-- state. Retain the measured approach through that gap and the whole
		-- flight; a settled flat runout below still clears it before flat pops.
		self.steep_seen,self.steep_hold = true,0.48
	else
		if grounded then self.steep_seen = false end
		self.steep_hold = max(0, self.steep_hold - dt)
		if self.steep_hold == 0 then self.steep_seen = false end
	end

	local grade = input.rail_grade
	if grinding and finite(grade) and grade > 0.21 and grade < 1.0 then
		self.rail_time = min(1, self.rail_time + dt)
	else
		self.rail_time = max(0, self.rail_time - 2 * dt)
	end
	if self.rail_time >= 0.12 then self.rail_hold = 0.4
	else self.rail_hold = max(0, self.rail_hold - dt) end

	local rays, found = 0, nil
	self.probe_clock += dt
	self.probe_age += dt
	if datum and not grinding and self.probe_clock >= 0.1 then
		self.probe_clock = self.probe_clock % 0.1
		found, rays = probe(self, p, v, datum, query)
		if found then
			self.probe_age, self.probe_rise, self.probe_drop = 0, found.rise, found.drop
		end
	end
	if found and found.rise then self.rise_hold = 0.3
	elseif air and self.rise_hold > 0 then
		-- The lookahead shortens with speed at takeoff, so a raised support seen on
		-- the approach can leave its range mid-flight. Retain it until touchdown
		-- rather than dipping the eye halfway through the jump.
		self.rise_hold = max(self.rise_hold, 0.12)
	else self.rise_hold = max(0, self.rise_hold - dt) end
	local landing = input.predicted_landing_position
	local predicted_lower = (air or v.y < -0.5) and datum and point(landing) and finite(input.predicted_landing_height)
		and input.predicted_landing_height < datum - 1.0
		and (landing.x - p.x) * v.x + (landing.z - p.z) * v.z > 0.2
	local physical_drop = datum and v.y < -1.5 and p.y < datum - 0.6
	if not grinding and ((found and found.drop) or predicted_lower or physical_drop) then self.drop_hold = 0.38
	else self.drop_hold = max(0, self.drop_hold - dt) end
	-- A new level support and a recently verified level route retire old context
	-- targets before another flat pop. The weight still eases from the shown pose.
	local physical_vy = input.physical_vy or (point(input.physical_velocity) and input.physical_velocity.y) or v.y
	local settled_flat = grounded and type(state) == "number" and state >= 100 and state < 200
		and point(normal) and normal.y > 0.95 and finite(physical_vy) and abs(physical_vy) < 0.5
		and ((self.probe_age <= 0.15 and self.probe_rise == false and self.probe_drop == false)
			or v.x*v.x+v.z*v.z<1)
	if settled_flat then self.flat_time += dt else self.flat_time = 0 end
	if self.flat_time >= 0.12 then
		self.steep_hold, self.rail_hold = 0, 0
		-- At walking speed the lookahead deliberately does not run. Fresh
		-- level support still retires the ramp; it cannot disprove a ledge.
		if self.probe_age<=0.15 and self.probe_rise==false and self.probe_drop==false then
			self.rise_hold,self.drop_hold=0,0
		end
		self.steep_seen, self.rail_time = false, 0
	end
	if self.rise_hold == 0 and self.drop_hold == 0 then self.ahead_height = nil end

	local reason, confidence = "flat", 0
	if self.steep_hold > 0 then reason, confidence = "transition", steep and 1 or 0.75
	elseif self.rail_hold > 0 then reason, confidence = "steep_rail", self.rail_time >= 0.12 and 1 or 0.75
	elseif self.rise_hold > 0 then reason, confidence = "raised_support", found and found.rise and 1 or 0.7
	elseif self.drop_hold > 0 then reason, confidence = "drop", (found and found.drop) and 1 or 0.75 end
	self.target, self.confidence, self.reason = confidence > 0 and 1 or 0, confidence, reason
	-- Exact critically damped response: preserve blend velocity when the
	-- terrain target reverses instead of changing it at a detector threshold.
	local omega=self.target>self.weight and 12.0 or 8.0
	local offset=self.weight-self.target
	local velocity=self.weight_velocity or 0
	local step=(velocity+omega*offset)*dt
	local decay=exp(-omega*dt)
	self.weight=clamp(self.target+(offset+step)*decay)
	self.weight_velocity=(velocity-omega*step)*decay
	if abs(self.weight-self.target)<0.0001 and abs(self.weight_velocity)<0.001 then
		self.weight,self.weight_velocity=self.target,0
	end
	-- Ramp view has its own eased share. Reason describes current detector ownership
	-- and can become flat while the displayed terrain pose is still releasing.
	local transition_target=self.steep_hold>0 and 1 or 0
	local transition_omega=transition_target>self.transition_weight and 12.0 or 8.0
	local transition_offset=self.transition_weight-transition_target
	local transition_velocity=self.transition_velocity
	local transition_step=(transition_velocity+transition_omega*transition_offset)*dt
	local transition_decay=exp(-transition_omega*dt)
	self.transition_weight=clamp(transition_target+(transition_offset+transition_step)*transition_decay)
	self.transition_velocity=(transition_velocity-transition_omega*transition_step)*transition_decay
	if abs(self.transition_weight-transition_target)<0.0001 and abs(self.transition_velocity)<0.001 then
		self.transition_weight,self.transition_velocity=transition_target,0
	end
	if self.steep_hold>0 then
		self.transition_weight,self.transition_velocity=self.weight,self.weight_velocity
	end
	return output(self, rays)
end

return M
