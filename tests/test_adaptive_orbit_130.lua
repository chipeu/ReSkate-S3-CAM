local T = require("tlib")
local Orbit = require("adaptive_orbit")
local v = vector.create
T.group("adaptive orbit 130 stability")

local function box(a, b, low, high)
	local enter, leave = 0, 1
	for _, axis in ipairs({"x", "y", "z"}) do
		local d = b[axis] - a[axis]
		if math.abs(d) < 1e-9 then
			if a[axis] < low[axis] or a[axis] > high[axis] then return nil end
		else
			local p, q = (low[axis] - a[axis]) / d, (high[axis] - a[axis]) / d
			if p > q then p, q = q, p end
			enter, leave = math.max(enter, p), math.min(leave, q)
			if enter > leave then return nil end
		end
	end
	return a + (b - a) * enter
end

local wall = function(a, b) return box(a, b, v(0.45, 0.5, 0.5), v(0.65, 2.5, 4)) end
local empty = function() return nil end
local st, owner = {}, { rays = 0 }
local first_from, froms
local function cast(self, query, a, b)
	self.rays += 1
	if not first_from then first_from = a end
	table.insert(froms, a)
	return query(a, b)
end
local function solve(query, anchor, pivot, yaw, available, prior)
	owner.rays, first_from, froms = 0, nil, {}
	local y, s = Orbit.solve(st, owner, query, cast, pivot, anchor, 0, 1.5, 3,
		yaw, 0, 0.25, v(0, 0, 0), 1/60, false, available or 7, v(-1, 0, 0), prior)
	T.expect(owner.rays <= (available or 7), "counted rays remain in allowance")
	return y, s
end

Orbit.reset(st)
local origin = v(0, 1.5, 0)
local y
for _ = 1, 90 do y = solve(wall, origin, origin, 0.43) end
T.expect(y < -0.2 and st.alternate, "blocked preference reaches stable alternate")
local alternate_yaw = y
for _ = 1, 10 do
	y = solve(empty, origin, origin, 0.43)
	T.expect(math.abs(y - alternate_yaw) < 0.02, "one clear frame does not switch sides")
	y = solve(wall, origin, origin, 0.43)
	T.expect(st.preferred_time == 0, "blocked frame resets recovery evidence")
end
for _ = 1, 20 do y = solve(empty, origin, origin, 0.43) end
T.expect(y > alternate_yaw + 0.03, "continuous clear dwell begins preferred recovery")

Orbit.reset(st)
solve(empty, origin, origin, 0)
local prior_eye = st.eye
local moved = v(0, 1.5, 0.4)
solve(empty, moved, moved, 0)
T.expect(first_from and first_from.z == moved.z, "candidate starts at current pivot")
T.expect(froms[4] and math.abs(froms[4].z - prior_eye.z) < 1e-5,
	"transit starts at prior world eye, including anchor travel")
T.expect(st.eye and st.eye.z > prior_eye.z + 0.3, "accepted eye follows moving anchor")
local rendered_eye = v(0, 1.5, 2.8)
solve(empty, moved, moved, 0, 7, rendered_eye)
T.expect(froms[4] and math.abs(froms[4].z - rendered_eye.z) < 1e-5,
	"caller supplied rendered eye overrides inferred prior eye")

-- A shifted pivot can see a clear destination even when the eye's world path
-- crosses a thin wall. The movement sweep must start at the previous world eye.
Orbit.reset(st)
solve(empty, origin, origin, 0)
local crossing = function(a, b) return box(a, b, v(-0.5, 0.5, 3.45), v(0.5, 2.5, 3.55)) end
local shifted_anchor, shifted_pivot = v(0, 1.5, 1), v(0, 1.5, 4.2)
y = solve(crossing, shifted_anchor, shifted_pivot, 0)
T.expect(y == 0 and st.eye.z < 3.45, "blocked world transit does not commit a crossed eye")

Orbit.reset(st)
for _ = 1, 90 do solve(wall, origin, origin, 0.43) end
solve(empty, origin, origin, 0.43)
T.expect(st.preferred_time > 0, "clear evidence begins to accumulate")
solve(empty, origin, origin, 0.43, 2)
T.expect(st.preferred_time == 0, "unknown ray budget resets recovery evidence")

-- An outward rate can survive the frame in which clearance first contracts.
-- The requested yaw is already at the wall; recovery must brake immediately.
Orbit.reset(st)
st.yaw, st.shoulder = 0.436, 0.114
st.yaw_rate, st.shoulder_rate = 1.0, 0.0
st.constrained, st.clear_time = true, 1
y = solve(wall, origin, origin, 0.436)
T.expect(y <= 0.436001, "blocked yaw brakes outward momentum during contraction")
T.expect(st.yaw_rate <= 0, "blocked yaw does not retain outward velocity")

Orbit.reset(st)
st.yaw, st.constrained = 0.4, true
local farther_wall = function(a, b)
	return box(a, b, v(0.8, 0.5, 0.5), v(1.0, 2.5, 4))
end
local old_physical_eye = v(0.3, 1.5, 2.5)
y = solve(farther_wall, origin, origin, 0.4, 7, old_physical_eye)
T.expect(y < 0.2 and y > 0, "blocked expanding orbit rebases yaw to the safe world eye")
T.expect(st.eye and st.eye.x < 0.65, "rebased step stays outside the wall radius")

T.done()
