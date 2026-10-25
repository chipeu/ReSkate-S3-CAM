-- The last line of defence against a camera snap: every pose the plugin is about to show passes through here first.
--
--   local g = SnapGuard.new()
--   local pos, forward, up, fov, cause, amount = g:filter(now, pos, forward, up, fov, subject, pulled)
--   g:cut()                  forget the last pose (the camera was taken, released, or the level changed): the next pose passes as it is
--   g.count.position / .turn / .fov, g.total     how many times a snap was smoothed, by what made it
--   g.smoothing              true while a smoothing blend is running
--
-- Why it exists: the camera has many paths (riding, off the board, board to foot and back, the hand-back, a retake after a menu), each
-- with its own blending, and a bug or an odd read in any one of them shows as one frame where the view jumps. Instead of trusting
-- every path to be smooth, this looks at what is about to be shown and refuses a jump whatever caused it.
--
-- A jump is measured against the previous pose the PATH asked for, and relative to the subject: the camera's offset from the skater,
-- not its place in the world, so riding fast (the whole camera moving 20 m/s) is not a jump. It is one when, in a single tick,
--   * the camera's offset from the subject changes by more than MAX_POSITION metres,
--   * the view direction turns by more than MAX_TURN degrees, or
--   * the field of view moves by more than MAX_FOV degrees,
-- and that step is new: it is not just the step of the tick before carried on. A blend that is quick but steady (the crossfade
-- from the game's camera, 0.3 m a tick for half a second) is motion, not a snap, and easing it again every tick would only freeze
-- the camera on the skater. Only a step much bigger than that (BIG times the limit) counts however steady it is.
-- Then the shown pose leaves the last shown one and eases to the wanted pose over SMOOTH_TIME seconds (a sine ease, in the
-- subject's frame, following the wanted pose as it moves). A big jump takes longer, so that no tick of the ease is itself more than
-- about 80% of a limit. Another jump during the ease restarts it from what is on screen.
--
-- Two things are not jumps: the camera sliding in because a wall is in the way (`pulled`, and the wanted camera is closer to the
-- subject than the shown one: holding it behind the wall would show the inside of the wall), and the subject itself teleporting
-- (more than TELEPORT metres in one tick: a respawn, a level load), where the camera has to cut with him.

local S3 = require("s3math")

local M = {}

M.MAX_POSITION = 0.25 -- m of camera offset from the subject, in one tick
M.MAX_TURN = 8.0 -- degrees of view direction, in one tick
M.MAX_FOV = 2.0 -- degrees of field of view, in one tick
M.SMOOTH_TIME = 0.35 -- s the ease takes, at least
M.MAX_SMOOTH_TIME = 1.5 -- s, however big the jump
M.TICK = 1.0 / 60.0 -- s, the tick the ease is sized for
M.BIG = 4.0 -- a step this many times a limit is a snap even when the tick before moved as much
M.TELEPORT = 5.0 -- m the subject moves in one tick and it is a cut, not a snap
M.CAUSES = { "position", "turn", "fov" }

local vmagnitude, vdot = vector.magnitude, vector.dot
local clamp, abs, acos = math.clamp, math.abs, math.acos
local DEGREES = math.pi / 180.0
local UP = vector.create(0, 1, 0)
local ZERO = vector.create(0, 0, 0)

local Guard = {}
Guard.__index = Guard

function M.new()
	local self = setmetatable({}, Guard)
	self.count = { position = 0, turn = 0, fov = 0 }
	self.total = 0
	self:cut()
	return self
end

function Guard:cut()
	self.have = false
	self.smoothing = false
end

-- What the path asked for last tick (w_*) and what was shown (o_*), the offset from the subject being the position that counts.
function Guard:remember(wanted_rel, wanted_fwd, wanted_fov, out_rel, out_fwd, out_up, out_fov, subject, step, turn, dfov)
	self.w_rel, self.w_fwd, self.w_fov = wanted_rel, wanted_fwd, wanted_fov
	self.w_step, self.w_turn, self.w_dfov = step or ZERO, turn or 0.0, dfov or 0.0 -- the steps of the tick that led here
	self.o_rel, self.o_fwd, self.o_up, self.o_fov = out_rel, out_fwd, out_up, out_fov
	self.subject = subject
end

local function nlerp(a, b, t, fallback)
	return S3.normalized(a + (b - a) * t, fallback)
end

-- Returns pos, forward, up, fov to show, and, when a jump was found this call, its cause ("position", "turn" or "fov") and size
-- (m or degrees). `fov` may be nil (the game's own is left alone). `pulled`: the camera's collision pulled it in this tick.
function Guard:filter(now, pos, forward, up, fov, subject, pulled)
	local rel = pos - subject
	if self.have and vmagnitude(subject - self.subject) > M.TELEPORT then
		self.have = false
	end
	if not self.have then
		self.have = true
		self.smoothing = false
		self:remember(rel, forward, fov, rel, forward, up, fov, subject)
		return pos, forward, up, fov
	end

	-- Did the wanted pose jump against the one wanted last tick?
	local cause, amount, worst = nil, 0.0, 1.0
	local step_vec = rel - self.w_rel
	local step = vmagnitude(step_vec)
	local closer = pulled and vmagnitude(rel) < vmagnitude(self.o_rel)
	if not closer and step > M.MAX_POSITION and (step > M.BIG * M.MAX_POSITION or vmagnitude(step_vec - self.w_step) > M.MAX_POSITION) then
		cause, amount, worst = "position", step, step / M.MAX_POSITION
	end
	local turn = acos(clamp(vdot(forward, self.w_fwd), -1.0, 1.0)) / DEGREES
	if turn > M.MAX_TURN and (turn > M.BIG * M.MAX_TURN or abs(turn - self.w_turn) > M.MAX_TURN) and turn / M.MAX_TURN > worst then
		cause, amount, worst = "turn", turn, turn / M.MAX_TURN
	end
	local dfov = (fov and self.w_fov) and abs(fov - self.w_fov) or 0.0
	if dfov > M.MAX_FOV and (dfov > M.BIG * M.MAX_FOV or abs(dfov - self.w_dfov) > M.MAX_FOV) and dfov / M.MAX_FOV > worst then
		cause, amount, worst = "fov", dfov, dfov / M.MAX_FOV
	end
	if cause then
		self.count[cause] += 1
		self.total += 1
		-- The ease starts from what is on screen, so it is invisible at its first tick.
		self.smoothing = true
		self.from_rel, self.from_fwd, self.from_up, self.from_fov = self.o_rel, self.o_fwd, self.o_up, self.o_fov
		self.started = now
		-- A sine ease moves at most pi/2 times its distance over its time; the time grows until a tick of that is under the limits.
		local dpos = vmagnitude(rel - self.o_rel)
		local dturn = acos(clamp(vdot(forward, self.o_fwd), -1.0, 1.0)) / DEGREES
		local dfov = (fov and self.o_fov) and abs(fov - self.o_fov) or 0.0
		local need = math.max(dpos / (0.8 * M.MAX_POSITION), dturn / (0.8 * M.MAX_TURN), dfov / (0.8 * M.MAX_FOV))
		self.duration = clamp(math.pi * 0.5 * M.TICK * need, M.SMOOTH_TIME, M.MAX_SMOOTH_TIME)
	end

	local out_rel, out_fwd, out_up, out_fov = rel, forward, up, fov
	if self.smoothing then
		local f = (now - self.started) / self.duration
		if f >= 1.0 then
			self.smoothing = false
		else
			local e = S3.sine_blend(clamp(f, 0.0, 1.0))
			if closer and vmagnitude(rel) < vmagnitude(self.o_rel) then
				self.from_rel = rel -- a wall in the way: the position goes to the wanted one at once, the view eases on
			end
			out_rel = self.from_rel + (rel - self.from_rel) * e
			out_fwd = nlerp(self.from_fwd, forward, e, forward)
			local u = nlerp(self.from_up, up, e, up)
			u = u - out_fwd * vdot(u, out_fwd)
			out_up = S3.normalized(u, UP)
			if fov and self.from_fov then
				out_fov = clamp(self.from_fov + (fov - self.from_fov) * e, 10.0, 150.0)
			end
		end
	end
	self:remember(rel, forward, fov, out_rel, out_fwd, out_up, out_fov, subject, step_vec, turn, dfov)
	if self.smoothing then
		return subject + out_rel, out_fwd, out_up, out_fov, cause, amount
	end
	return pos, forward, up, fov, cause, amount
end

return M
