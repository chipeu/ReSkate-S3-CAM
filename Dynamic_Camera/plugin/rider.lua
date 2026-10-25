-- Port of Engine/Game/Camera/s3_rider.h: the velocity the camera follows on the board: the rider's,
-- measured from the root's own movement. The board's root body is kicked, spun and caught by every flip
-- trick, and not only in the air: in the crouch before the pop its velocity heading swung 15-40 degrees
-- while the rider's root went straight on (1.0.2 test 7 log), and the camera turned with it. The camera
-- frames the rider, so the board has no say in where it looks; the board body's velocity is only the
-- fallback while nothing can be measured yet.
--
-- The root changes once per physics step (60 Hz) and the frames between repeat it. A change is seen at the
-- first frame after the step, which at 60 or 144 fps is up to a whole frame late and by a different amount
-- each time (0.86 m/s error in the air, 1.0.2 test 7), so the changes are timed by the physics step instead:
-- the steps between two changes are counted and each is one step long. A curve through the last few
-- changes then gives the speed and the acceleration.
--
-- API:
--   local r = Rider.new()
--   Rider.update(r, now, root, board, onboard, step) -> vector
--        now: frame time in seconds (a double; the publisher clock), root: the rider's root position (vector),
--        board: the board body's velocity (vector; the hips' off the board), onboard: bool,
--        step: the physics step in seconds (0 or nil when unknown: frame times are used).
--        Returns the velocity to hand the camera.
--   Rider.reset(r)

local S3 = require("s3math")

local M = {}

local vcreate = vector.create
local vmagnitude = vector.magnitude
local ZERO = S3.ZERO
local abs = math.abs
local max = math.max
local min = math.min
local floor = math.floor
local sqrt = math.sqrt
local clamp = math.clamp

local SAMPLES = 5
local QUADRATIC_FROM = 4 -- samples needed before the acceleration is fitted (fewer: a straight line)
local MIN_SPAN = 0.03 -- s, the shortest stretch a speed is measured over
local STALE = 0.25 -- s without a root change: no measurement at all (paused, or the physics stopped)
local STILL_STEPS = 2.5 -- steps without a root change: the rider stopped, fade back to the board's
local STILL_TIME = 0.05 -- s, the same when the physics step is not known
local JUMP = 3.0 -- m between two steps: a teleport, not riding
local MAX_ACCEL = 40.0 -- m/s^2, a landing's kink in the curve must not run away
local MOVE_MIN = 0.002 -- m a step (0.12 m/s): below it the move says nothing about the step count
local BLEND_TIME = 0.1 -- s to move between the rider's velocity and the board's, so nothing steps

M.rider_samples = SAMPLES
M.rider_blend_time = BLEND_TIME

function M.new()
	local ring = {}
	for i = 1, SAMPLES do
		-- seen: frame time the change was first seen at; at: when the physics step made it (the steps counted
		-- from the one before); root
		ring[i] = { seen = 0.0, at = 0.0, root = ZERO }
	end
	return {
		ring = ring,
		next = 0, -- 0-based slot of the next write
		count = 0,
		last_now = 0.0,
		weight = 0.0,
		rider = ZERO,
		move_x = 0.0, -- m, how far the root moved over its last physics step
		move_y = 0.0,
		move_z = 0.0,
		have_move = false,
		-- measure() result
		vx = 0.0,
		vy = 0.0,
		vz = 0.0,
	}
end

function M.reset(r)
	local fresh = M.new()
	for k, v in fresh do
		r[k] = v
	end
end

local function newest(r)
	return r.ring[(r.next + SAMPLES - 1) % SAMPLES + 1]
end

-- 0 = oldest
local function nth(r, i)
	return r.ring[(r.next + SAMPLES - r.count + i) % SAMPLES + 1]
end

local function round_half_away(x)
	-- std::round for the positive values used here
	return floor(x + 0.5)
end

-- Records a root that differs from the last one (the repeats between physics steps carry nothing). Each
-- change is timed by how many physics steps it holds. The frame clock gives that count to within a frame,
-- and at 60 fps (a frame the length of a step) a step is seen a frame early or late at random, so a change
-- of two steps looks like one and the speed doubles. The rider moves about the same each step, so when the
-- move is nearer to the last step's with one count more or less, that count is used.
local function observe(r, now, root, step)
	local at = now
	if r.count > 0 then
		local last = newest(r)
		if root == last.root then
			return
		end
		if now - last.seen > STALE or vmagnitude(root - last.root) > JUMP then
			r.count = 0
			r.have_move = false
		elseif step > 0.0 then
			local by_clock = max(1.0, round_half_away((now - last.seen) / step))
			local steps = by_clock
			local lr = last.root
			local dx, dy, dz = root.x - lr.x, root.y - lr.y, root.z - lr.z
			if r.have_move and sqrt(r.move_x * r.move_x + r.move_y * r.move_y + r.move_z * r.move_z) > MOVE_MIN then
				local mx, my, mz = r.move_x, r.move_y, r.move_z
				local function miss(count)
					local ex, ey, ez = dx / count - mx, dy / count - my, dz / count - mz
					return sqrt(ex * ex + ey * ey + ez * ez)
				end
				local clock_miss = miss(by_clock)
				local count = max(1.0, by_clock - 2.0)
				while count <= by_clock + 2.0 do
					local m = miss(count)
					if m < 0.5 * clock_miss and m < miss(steps) then
						steps = count
					end
					count = count + 1.0
				end
			end
			r.move_x, r.move_y, r.move_z = dx / steps, dy / steps, dz / steps
			r.have_move = true
			at = last.at + steps * step
		end
	end
	local slot = r.ring[r.next + 1]
	slot.seen, slot.at, slot.root = now, at, root
	r.next = (r.next + 1) % SAMPLES
	r.count = min(r.count + 1, SAMPLES)
end

-- Fits a curve through the recorded roots. Returns true and leaves the velocity in r.vx/vy/vz, or false.
local function measure(r, now, step)
	if r.count < 2 then
		return false
	end
	local last = newest(r)
	if last.at - nth(r, 0).at < MIN_SPAN or now - last.seen > (step > 0.0 and STILL_STEPS * step or STILL_TIME) then
		return false
	end
	-- Positions against the newest root and times against its step, so the numbers stay small: p(u) = a + b u + c u^2.
	local s0, s1, s2, s3, s4 = 0.0, 0.0, 0.0, 0.0, 0.0
	local m0x, m0y, m0z, m1x, m1y, m1z, m2x, m2y, m2z = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
	local lroot = last.root
	local lx, ly, lz = lroot.x, lroot.y, lroot.z
	for i = 0, r.count - 1 do
		local sample = nth(r, i)
		local u = sample.at - last.at
		local u2 = u * u
		s0 = s0 + 1.0
		s1 = s1 + u
		s2 = s2 + u2
		s3 = s3 + u2 * u
		s4 = s4 + u2 * u2
		local sr = sample.root
		local px, py, pz = sr.x - lx, sr.y - ly, sr.z - lz
		m0x, m0y, m0z = m0x + px, m0y + py, m0z + pz
		m1x, m1y, m1z = m1x + px * u, m1y + py * u, m1z + pz * u
		m2x, m2y, m2z = m2x + px * u2, m2y + py * u2, m2z + pz * u2
	end
	local ahead = clamp(now - last.seen, 0.0, step > 0.0 and step or STILL_TIME) -- the root is this long old
	local vx, vy, vz = 0.0, 0.0, 0.0
	local ax, ay, az = 0.0, 0.0, 0.0
	if r.count >= QUADRATIC_FROM then
		local det = s0 * (s2 * s4 - s3 * s3) - s1 * (s1 * s4 - s3 * s2) + s2 * (s1 * s3 - s2 * s2)
		if abs(det) < 1e-30 then
			return false
		end
		local function solve(y0, y1, y2)
			local b = (s0 * (y1 * s4 - s3 * y2) - y0 * (s1 * s4 - s3 * s2) + s2 * (s1 * y2 - y1 * s2)) / det
			local c = (s0 * (s2 * y2 - y1 * s3) - s1 * (s1 * y2 - y1 * s2) + y0 * (s1 * s3 - s2 * s2)) / det
			return b, 2.0 * c
		end
		vx, ax = solve(m0x, m1x, m2x)
		vy, ay = solve(m0y, m1y, m2y)
		vz, az = solve(m0z, m1z, m2z)
		local magnitude = sqrt(ax * ax + ay * ay + az * az)
		if magnitude > MAX_ACCEL then
			local k = MAX_ACCEL / magnitude
			ax, ay, az = ax * k, ay * k, az * k
		end
	else
		local det = s0 * s2 - s1 * s1
		if abs(det) < 1e-18 then
			return false
		end
		vx = (s0 * m1x - s1 * m0x) / det
		vy = (s0 * m1y - s1 * m0y) / det
		vz = (s0 * m1z - s1 * m0z) / det
	end
	local ox, oy, oz = vx + ax * ahead, vy + ay * ahead, vz + az * ahead
	local sum = ox + oy + oz
	if sum - sum ~= 0 then
		return false
	end
	r.vx, r.vy, r.vz = ox, oy, oz
	return true
end

-- The velocity to hand the camera. `board` is the board body's (the hips' off the board). On the board the
-- rider's own measured velocity is used at all times; `board` stands in until there is a measurement (the
-- first frames, after a teleport, paused), and the two are blended so the switch never steps. `step` is the
-- physics step in seconds (0 when unknown: frame times are used).
function M.update(r, now, root, board, onboard, step)
	step = step or 0.0
	local frame = clamp(now - r.last_now, 0.0, BLEND_TIME)
	r.last_now = now
	observe(r, now, root, step)
	if not onboard then
		r.weight = 0.0
		return board
	end
	local have = measure(r, now, step)
	if have then
		r.rider = vcreate(r.vx, r.vy, r.vz)
	end
	-- Nothing to hold: snap to the board's. Otherwise fade, the way a measurement that has gone still (the rider stopped) leaves.
	if r.count < 2 or now - newest(r).seen > STALE then
		r.weight = 0.0
	else
		r.weight = clamp(r.weight + (frame / BLEND_TIME) * (have and 1.0 or -1.0), 0.0, 1.0)
	end
	if r.weight <= 0.0 then
		return board
	end
	return board + (r.rider - board) * r.weight
end

return M
