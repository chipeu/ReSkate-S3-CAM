-- A bounded side/up search for a swept eye or sightline obstruction ahead,
-- with a local escape when the core has already shortened the camera arm.
-- The core collision and final shown-eye validation remain authoritative.
local M = {}
M.__index = M

local create, dot, cross, magnitude = vector.create, vector.dot, vector.cross, vector.magnitude
local min, max, abs, exp = math.min, math.max, math.abs, math.exp
local UP = create(0, 1, 0)
local WIDTH, REACH = 0.45, 0.12
local MIN_PULL, MIN_GAIN = 0.35, 0.10
local REPROBE, LATCH = 0.18, 0.65
local LOOK_TIME, MIN_SPEED = WIDTH / 0.75 + 0.24, 2.0

local function displacement(velocity, rail, eye_motion, look_time)
    if not velocity then return nil end
    local horizontal = create(velocity.x, 0, velocity.z)
    local speed = eye_motion and magnitude(velocity) or magnitude(horizontal)
    if speed < MIN_SPEED then return nil end
    -- The next rail section is lower in world space. A horizontal-only probe
    -- misses the ledge/floor the eye will meet while following the rider down.
    local shift=((rail or eye_motion) and velocity or horizontal) * (look_time or LOOK_TIME)
    local length=magnitude(shift)
    -- A bad pose delta must not turn a lookahead into an unbounded world ray.
    if length>32 then shift*=32/length end
    return shift
end

local function trial_at(base, direction, lateral, side, width, up_width)
    local shift = side == 2 and UP * up_width or lateral * (side * width)
    return base + shift + direction * REACH
end

function M.new()
    return setmetatable({ offset = 0, goal = 0, side = 0, next_probe = 0, latched_until = 0 }, M)
end

function M:reset()
    self.offset, self.goal, self.side = 0, 0, 0
    self.next_probe, self.latched_until = 0, 0
    self.last_output = nil
end

-- cast is a counted, point-only world ray. remaining must leave the two final
-- validation slots free. No ray is spent when the arm has ordinary clearance.
function M:step(base, pivot, full, pull, now, dt, cast, remaining, search_enabled, velocity, rail, eye_velocity, radius)
    local radial = base - pivot
    local distance = magnitude(radial)
    local up_width=WIDTH+max(0,radius or 0)
    local look_time=up_width/0.75+0.24
    local width = self.side == 2 and up_width or min(WIDTH, 0.20 * distance)
    self.offset = max(-width, min(width, self.offset))
    if rail and self.side ~= 0 and self.side ~= 2 then
        -- A grind keeps the camera behind the rail. Retire an earlier lateral
        -- shoulder before acquiring an upward clearance route.
        self.goal = 0
    elseif search_enabled == false then
        -- Fast vertical motion may suppress discovery without cutting an
        -- already visible shoulder to zero in a single frame.
        self.goal = self.offset
    elseif distance < 0.3 or full < distance or (pull < MIN_PULL and not displacement(eye_velocity or velocity, rail, eye_velocity~=nil,look_time)) then
        self.goal = 0
    elseif now >= self.next_probe and remaining >= 5 then
        self.next_probe = now + (pull < MIN_PULL and displacement(eye_velocity or velocity, rail, eye_velocity~=nil,look_time) and 0.06 or REPROBE)
        local direction = radial / distance
        local lateral = cross(UP, direction)
        local lateral_len = magnitude(lateral)
        if lateral_len > 0.1 then
            lateral /= lateral_len
            local future = nil
            if pull < MIN_PULL and remaining >= 10 then
                local shift = displacement(eye_velocity or velocity, rail, eye_velocity~=nil,look_time)
                if shift then
                    local pivot_shift=eye_velocity and velocity*look_time or shift
                    local pivot_length=magnitude(pivot_shift)
                    if pivot_length>32 then pivot_shift*=32/pivot_length end
                    local future_base, future_pivot = base + shift, pivot + pivot_shift
                    -- A future sightline alone misses a thin wall that the
                    -- eye crosses before the lookahead point.
                    local sight = cast(future_pivot, future_base)
                    local sweep = cast(base, future_base)
                    local sight_short = sight and magnitude(sight - future_pivot) < distance - 0.10
                    if sight_short or sweep then
                        -- Evaluate candidate clearance at first contact. A ray
                        -- all the way beyond a wall rejects a route that would
                        -- have cleared the near face in time.
                        local contact=sweep and sweep-base+shift/magnitude(shift)*min(0.30,magnitude(shift)) or shift
                        local fraction=math.clamp(dot(contact,shift)/math.max(dot(shift,shift),1e-8),0,1)
                        future = {shift=contact,pivot=pivot+pivot_shift*fraction,swept=sweep~=nil,
                            travel=shift/magnitude(shift)}
                    end
                end
            end
            if pull >= MIN_PULL or future then
            local gain_best, side_best = MIN_GAIN, 0
            local candidates = rail and { 2 } or (future and { -1, 1, 2 } or { -1, 1 })
            if self.side ~= 0 then
                local ordered = { self.side }
                for _,side in ipairs(candidates) do if side ~= self.side then ordered[#ordered+1]=side end end
                candidates = ordered
            end
            for _, side in ipairs(candidates) do
                local trial = trial_at(base, direction, lateral, side, width, up_width)
                local gain
                if future then
                    local projected = trial + future.shift
                    local view_hit = cast(future.pivot, projected)
                    local path_hit = cast(base, future.swept and projected or projected+future.travel*0.30)
                    gain = not view_hit and not path_hit and MIN_GAIN + 0.25 or 0
                else
                    local hit = cast(pivot, trial)
                    local clear = hit and max(0, magnitude(hit - pivot) - 0.08) or magnitude(trial - pivot)
                    gain = clear - distance
                end
                -- The existing side wins ties, and a switch needs extra room.
                local required = self.side ~= 0 and side ~= self.side and MIN_GAIN + 0.12 or MIN_GAIN
                if gain > max(gain_best, required) then gain_best, side_best = gain, side end
            end
            if side_best ~= 0 then
                self.latched_until=math.max(self.latched_until,now+look_time)
                if self.side ~= 0 and side_best ~= self.side and abs(self.offset)>0.008 then
                    -- Return along the old axis before changing to a shoulder
                    -- or upward path; a basis jump would look like a teleport.
                    self.goal = 0
                    self.next_probe = now + 0.06
                else
                    if side_best ~= self.side then self.latched_until = now + LATCH end
                    self.side, self.goal = side_best, side_best == 2 and up_width or side_best * width
                end
            elseif now >= self.latched_until then
                self.goal = 0
            end
            elseif now >= self.latched_until then
                self.goal = 0
            end
        end
    end

    -- Smooth both acquisition and return, with a per-second speed bound.
    local response = 1 - exp(-max(0, min(dt, 0.1)) / 0.12)
    local delta = (self.goal - self.offset) * response
    local limit = 0.75 * max(0, min(dt, 0.1))
    -- Retiring one axis before switching uses the same bounded speed as
    -- acquisition. An exponential tail can leave a few centimetres on the
    -- blocked axis when the next obstacle is already at the eye.
    if self.goal==0 and self.offset~=0 then delta=-self.offset end
    delta = max(-limit, min(limit, delta))
    local next_offset = self.offset + delta
    if abs(next_offset) < 0.001 then next_offset = 0 end
    if next_offset == 0 then self.offset = 0; if self.goal == 0 then self.side = 0 end; self.last_output=base; return base end
    if remaining < 1 then return base end
    local direction = radial / distance
    local lateral = cross(UP, direction)
    local lateral_len = magnitude(lateral)
    if lateral_len < 0.1 then self:reset(); return base end
    lateral /= lateral_len
    local shift = self.side == 2 and UP * abs(next_offset) or lateral * next_offset
    local candidate = base + shift + direction * (REACH * abs(next_offset) / width)
    if remaining >= 2 and cast(pivot, candidate) then
        self:reset()
        return base
    end
    -- A swept eye can hit a side wall even if the view ray itself is open.
    -- The unconstrained base can already lie inside a thin ledge as the rider
    -- reaches it. Validate travel from the eye that was actually cleared last
    -- step; sweeping from a buried desired eye falsely cancels safe escape.
    local sweep_from=self.last_output or base
    if cast(sweep_from, candidate) then
        self:reset()
        return base
    end
    self.offset = next_offset
    self.last_output=candidate
    return candidate
end

return M
