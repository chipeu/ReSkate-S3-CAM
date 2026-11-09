-- A small, latched sideways search for room when the riding collision has
-- already shortened the camera arm. The core collision remains authoritative.
local M = {}
M.__index = M

local create, dot, cross, magnitude = vector.create, vector.dot, vector.cross, vector.magnitude
local min, max, abs, exp = math.min, math.max, math.abs, math.exp
local UP = create(0, 1, 0)
local WIDTH, REACH = 0.45, 0.12
local MIN_PULL, MIN_GAIN = 0.35, 0.10
local REPROBE, LATCH = 0.18, 0.65
local LOOK_TIME, LOOK_DISTANCE, MIN_SPEED = 0.23, 1.15, 2.0

local function displacement(velocity)
    if not velocity then return nil end
    local horizontal = create(velocity.x, 0, velocity.z)
    local speed = magnitude(horizontal)
    if speed < MIN_SPEED then return nil end
    return horizontal * min(LOOK_TIME, LOOK_DISTANCE / speed)
end

local function trial_at(base, direction, lateral, side, width)
    local shift = side == 2 and UP * width or lateral * (side * width)
    return base + shift + direction * REACH
end

function M.new()
    return setmetatable({ offset = 0, goal = 0, side = 0, next_probe = 0, latched_until = 0 }, M)
end

function M:reset()
    self.offset, self.goal, self.side = 0, 0, 0
    self.next_probe, self.latched_until = 0, 0
end

-- cast is a counted, point-only world ray. remaining must leave the two final
-- validation slots free. No ray is spent when the arm has ordinary clearance.
function M:step(base, pivot, full, pull, now, dt, cast, remaining, search_enabled, velocity)
    local radial = base - pivot
    local distance = magnitude(radial)
    local width = min(WIDTH, 0.20 * distance)
    self.offset = max(-width, min(width, self.offset))
    if search_enabled == false then
        -- Fast vertical motion may suppress discovery without cutting an
        -- already visible shoulder to zero in a single frame.
        self.goal = self.offset
    elseif distance < 0.3 or full < distance or (pull < MIN_PULL and not displacement(velocity)) then
        self.goal = 0
    elseif now >= self.next_probe and remaining >= 5 then
        self.next_probe = now + (pull < MIN_PULL and displacement(velocity) and 0.06 or REPROBE)
        local direction = radial / distance
        local lateral = cross(UP, direction)
        local lateral_len = magnitude(lateral)
        if lateral_len > 0.1 then
            lateral /= lateral_len
            local future = nil
            if pull < MIN_PULL and remaining >= 10 then
                local shift = displacement(velocity)
                if shift then
                    local future_base, future_pivot = base + shift, pivot + shift
                    -- A future sightline alone misses a thin wall that the
                    -- eye crosses before the lookahead point.
                    local sight = cast(future_pivot, future_base)
                    local sweep = cast(base, future_base)
                    local sight_short = sight and magnitude(sight - future_pivot) < distance - 0.10
                    if sight_short or sweep then future = {shift=shift,pivot=future_pivot} end
                end
            end
            if pull >= MIN_PULL or future then
            local gain_best, side_best = MIN_GAIN, 0
            local candidates = future and { -1, 1, 2 } or { -1, 1 }
            if self.side ~= 0 then
                local ordered = { self.side }
                for _,side in ipairs(candidates) do if side ~= self.side then ordered[#ordered+1]=side end end
                candidates = ordered
            end
            for _, side in ipairs(candidates) do
                if self.side == 0 or side == self.side or now >= self.latched_until then
                    local trial = trial_at(base, direction, lateral, side, width)
                    local gain
                    if future then
                        local projected = trial + future.shift
                        local view_hit = cast(future.pivot, projected)
                        local path_hit = cast(base, projected)
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
            end
            if side_best ~= 0 then
                if self.side ~= 0 and side_best ~= self.side and abs(self.offset)>0.008 then
                    -- Return along the old axis before changing to a shoulder
                    -- or upward path; a basis jump would look like a teleport.
                    self.goal = 0
                    self.next_probe = now + 0.06
                else
                    if side_best ~= self.side then self.latched_until = now + LATCH end
                    self.side, self.goal = side_best, (side_best == 2 and 1 or side_best) * width
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
    local response = 1 - exp(-max(0, min(dt, 0.1)) / 0.24)
    local delta = (self.goal - self.offset) * response
    local limit = 0.75 * max(0, min(dt, 0.1))
    delta = max(-limit, min(limit, delta))
    local next_offset = self.offset + delta
    if abs(next_offset) < 0.001 then next_offset = 0 end
    if next_offset == 0 then self.offset = 0; if self.goal == 0 then self.side = 0 end; return base end
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
    if cast(base, candidate) then
        self:reset()
        return base
    end
    self.offset = next_offset
    return candidate
end

return M
