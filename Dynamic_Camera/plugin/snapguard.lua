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
-- The landing bounce is not a jump either: it drops the camera by its own amount in a frame on purpose. The camera reports how far (`impact`,
-- metres down) and the guard judges the pose with that drop taken out, the camera put back up and the view aimed as it was from there; a
-- pose that is not smoothed is passed on exactly as it came.
--
-- The landing rattle is not a jump either, and must never be smoothed: it turns the view by a few degrees in a frame, on purpose. The camera
-- reports its rotation (`rattle`: pitch, yaw, roll in radians) and the guard judges the pose with it taken out of the view's angles; if it
-- smooths something else it puts the rattle back on the result.
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
M.SETTLE_GAP = 0.008 -- m: a riding recovery this close to the wanted pose has arrived
M.SETTLE_FOV = 0.05 -- degrees of lens still to go
M.SETTLE_TIME = 0.08 -- s it must stay there
M.SETTLE_MAX = 1.2 -- s past its own duration a recovery may run while the rider keeps it moving
M.WATCH_POSITION = 0.60 -- share of MAX_POSITION that counts as a jump just after touchdown
M.STAIR_FRAME = 0.75 -- a frame shorter than this share of a tick can fall between physics steps
M.STAIR_DECAY = 0.15 -- s the measured stair height takes to fade
M.SWAY_TIME = 0.6 -- the same recovery motion, explicitly owned by Camera Sway

local vmagnitude, vdot = vector.magnitude, vector.dot
local clamp, abs, acos, max = math.clamp, math.abs, math.acos, math.max
local sin, cos, asin, atan2 = math.sin, math.cos, math.asin, math.atan2
local vcreate, vcross = vector.create, vector.cross
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
	self.last_now = nil
	self.move_velocity=ZERO
	self.finishing=false
	self.watch_until=nil
	self.stair=0
	self.subject_speed=nil
end

-- What the path asked for last tick (w_*) and what was shown (o_*), the offset from the subject being the position that counts.
function Guard:remember(wanted_rel, wanted_fwd, wanted_fov, out_rel, out_fwd, out_up, out_fov, subject, step, turn, dfov)
	self.w_rel, self.w_fwd, self.w_fov = wanted_rel, wanted_fwd, wanted_fov
	self.w_step, self.w_turn, self.w_dfov = step or ZERO, turn or 0.0, dfov or 0.0 -- the steps of the tick that led here
	self.o_rel, self.o_fwd, self.o_up, self.o_fov = out_rel, out_fwd, out_up, out_fov
	self.subject = subject
end

-- Open a bounded position recovery now, from what is on screen, without a measured jump. It ends as any other does.
function Guard:begin_recovery(now, duration)
	if not self.have or self.smoothing then return end
	self.smoothing, self.finishing = true, false
	self.started, self.duration, self.settled = now, duration or M.SMOOTH_TIME, 0
	self.short_recovery = true
	self.move_velocity = ZERO
	self.from_rel, self.from_fwd, self.from_up, self.from_fov = self.o_rel, self.o_fwd, self.o_up, self.o_fov
end

local function nlerp(a, b, t, fallback)
	return S3.normalized(a + (b - a) * t, fallback)
end

-- The yaw, pitch and roll of a view (the angles the camera builds its frame from: forward = (-sin yaw cos pitch, sin pitch, cos yaw cos pitch),
-- roll about the view axis), and the view of given angles.
local function angles_of(forward, up)
	local back = forward * -1.0
	local right0 = S3.normalized(vcross(UP, back), vcreate(1, 0, 0))
	local up0 = vcross(back, right0)
	return atan2(-forward.x, forward.z), asin(clamp(forward.y, -1.0, 1.0)), atan2(-vdot(up, right0), vdot(up, up0))
end

local function view_of(yaw, pitch, roll)
	local cp = cos(pitch)
	local forward = vcreate(-sin(yaw) * cp, sin(pitch), cos(yaw) * cp)
	local back = forward * -1.0
	local right0 = S3.normalized(vcross(UP, back), vcreate(1, 0, 0))
	local up0 = vcross(back, right0)
	local c, s = cos(roll), sin(roll)
	return forward, up0 * c - right0 * s
end

-- The view turned by the rattle (sign 1) or with it taken out (sign -1).
local function rattled(forward, up, rattle, sign)
	local yaw, pitch, roll = angles_of(forward, up)
	return view_of(yaw + sign * rattle.y, pitch + sign * rattle.x, roll + sign * rattle.z)
end

-- Returns pos, forward, up, fov to show, and, when a jump was found this call, its cause ("position", "turn" or "fov") and size
-- (m or degrees). `fov` may be nil (the game's own is left alone). `pulled`: the camera's collision pulled it in this tick. `impact`:
-- how far down the landing bounce has taken the camera in this pose (m, nil or 0 when none). `rattle`: the landing rattle's rotation in this
-- pose (vector: pitch, yaw, roll in radians, nil when none).
function Guard:filter(now, pos, forward, up, fov, subject, pulled, impact, rattle)
	local dt=clamp(now-(self.last_now or now-M.TICK),0,0.10)
	self.last_now=now
	local scale=self.stable and clamp(dt/M.TICK,0.1,6.0) or 1.0
	local position_limit,turn_limit,fov_limit=M.MAX_POSITION*scale,M.MAX_TURN*scale,M.MAX_FOV*scale
	impact = impact or 0.0
	local shown_pos, shown_forward, shown_up = pos, forward, up
	if rattle and (rattle.x ~= 0.0 or rattle.y ~= 0.0 or rattle.z ~= 0.0) then
		forward, up = rattled(forward, up, rattle, -1.0)
	else
		rattle = nil
	end
	local lift = vector.create(0, impact, 0)
	local reach = 0.0
	if impact ~= 0.0 then
		-- The camera without the drop, aiming at the point the real one aims at (about as far on as the subject is).
		reach = math.max(vmagnitude(pos - subject), 0.5)
		pos = pos + lift
		forward = S3.normalized(forward * reach - lift, forward)
	end
	local rel = pos - subject
	if self.have and vmagnitude(subject - self.subject) > M.TELEPORT then
		self.have = false
	end
	if not self.have then
		self.have = true
		self.smoothing = false
		self:remember(rel, forward, fov, rel, forward, up, fov, subject)
		return shown_pos, shown_forward, shown_up, fov
	end

	if self.continuous then
		-- Previously a slam could leave this recovery active indefinitely. The
		-- off-board toggle now enables it deliberately, including normal walking.
		self.smoothing=true
		self.finishing=false
		self.duration=M.SWAY_TIME
		self.move_velocity=self.move_velocity or ZERO
	elseif self.finite_recovery and self.smoothing then
		local finished=now-self.started>=self.duration
		if self.finish_settled then
			-- A riding recovery ends when the eye has really reached the wanted pose,
			-- or at a bounded age if the rider never lets it settle.
			local gap=vmagnitude(rel-self.o_rel)
			local lens=(fov and self.o_fov and not self.fov_passthrough) and abs(fov-self.o_fov) or 0
			self.settled=gap<M.SETTLE_GAP+(self.stair or 0) and lens<M.SETTLE_FOV and (self.settled or 0)+dt or 0
			finished=self.settled>=M.SETTLE_TIME or now-self.started>=self.duration+(self.short_recovery and 0 or M.SETTLE_MAX)
		end
		if finished then
			self.finishing=true
			self.move_velocity=ZERO
		end
	end

	-- Did the wanted pose jump against the one wanted last tick?
	local cause, amount, worst = nil, 0.0, 1.0
	local step_vec = rel - self.w_rel
	local step = vmagnitude(step_vec)
	local closer = pulled and vmagnitude(rel) < vmagnitude(self.o_rel)
	-- The first moments on the ground are when a body animation can move the rider's root in one frame.
	local jump_limit = (self.watch_until and now <= self.watch_until) and position_limit * M.WATCH_POSITION or position_limit
	-- Above the physics rate a stepped rider advances in stairs under an eye that glides.
	-- What the stair adds to this frame's step is the rider's clock, not a camera jump.
	local stair_step = 0.0
	if self.stable and self.subject and dt > 0.0 then
		local moved = vmagnitude(subject - self.subject)
		local speed = (self.subject_speed or moved / max(dt, M.TICK)) + ((moved / M.TICK) - (self.subject_speed or moved / M.TICK)) * clamp(dt / 0.1, 0.0, 1.0)
		if moved > 0.0 then self.subject_speed = speed end
		-- Only a rider held for about one physics step is on stairs; a virtual subject held for longer is not.
		if dt < M.TICK * M.STAIR_FRAME and moved > 0.0 and (self.held_for or 0.0) > 0.0 and self.held_for <= M.TICK * 1.5 then
			stair_step = max(0.0, moved - (self.subject_speed or 0.0) * dt)
		end
		self.stair = max(stair_step, (self.stair or 0.0) * math.exp(-dt / M.STAIR_DECAY))
		self.held_for = moved < 1e-5 and (self.held_for or 0.0) + dt or 0.0
	end
	jump_limit += stair_step
	if not closer and step > jump_limit and (step > M.BIG * jump_limit or vmagnitude(step_vec - self.w_step) > jump_limit) then
		cause, amount, worst = "position", step, step / jump_limit
	end
	local turn = acos(clamp(vdot(forward, self.w_fwd), -1.0, 1.0)) / DEGREES
	if turn > turn_limit and (turn > M.BIG * turn_limit or abs(turn - self.w_turn) > turn_limit) and turn / turn_limit > worst then
		cause, amount, worst = "turn", turn, turn / turn_limit
	end
	local dfov = (fov and self.w_fov) and abs(fov - self.w_fov) or 0.0
	if dfov > fov_limit and (dfov > M.BIG * fov_limit or abs(dfov - self.w_dfov) > fov_limit) and dfov / fov_limit > worst then
		cause, amount, worst = "fov", dfov, dfov / fov_limit
	end
	if cause then
		self.count[cause] += 1
		self.total += 1
	end
	if cause and not (self.stable and self.smoothing and not (self.finishing and self.restart_finishing)) then
		self.move_velocity=ZERO
		self.finishing=false
		-- The ease starts from what is on screen, so it is invisible at its first tick.
		self.smoothing = true
		self.from_rel, self.from_fwd, self.from_up, self.from_fov = self.o_rel, self.o_fwd, self.o_up, self.o_fov
		self.started = now
		self.settled = 0
		self.short_recovery = false
		-- A sine ease moves at most pi/2 times its distance over its time; the time grows until a tick of that is under the limits.
		local dpos = vmagnitude(rel - self.o_rel)
		local dturn = acos(clamp(vdot(forward, self.o_fwd), -1.0, 1.0)) / DEGREES
		local dfov = (fov and self.o_fov) and abs(fov - self.o_fov) or 0.0
		local need = math.max(dpos / (0.8 * M.MAX_POSITION), dturn / (0.8 * M.MAX_TURN), dfov / (0.8 * M.MAX_FOV))
		self.duration = clamp(math.pi * 0.5 * M.TICK * need, M.SMOOTH_TIME, M.MAX_SMOOTH_TIME)
	end

	local out_rel, out_fwd, out_up, out_fov = rel, forward, up, fov
	if self.smoothing then
		if self.finishing then
			-- End an Off-mode position correction without extending angular momentum
			-- or jumping across the remaining gap at the recovery deadline.
			local delta=rel-self.o_rel
			local length=vmagnitude(delta)
			local cap=position_limit*(self.finish_rate or 0.8)
			local lens_open=false
			if self.finish_settled and fov and self.o_fov and not self.fov_passthrough then
				-- The lens finishes under the same one-frame limit as a running recovery.
				local lens=fov-self.o_fov
				local most=fov_limit*0.35
				out_fov=self.o_fov+clamp(lens,-most,most)
				lens_open=abs(lens)>most
			end
			if length>cap then delta*=cap/length
			elseif not lens_open then self.smoothing=false;self.finishing=false end
			out_rel=self.o_rel+delta
		elseif self.stable then
			-- Chase the current target from the last displayed pose. Repeated disturbances
			-- cannot restart the ease at zero progress and freeze a board/foot handover.
			local fraction=1-math.exp(-4.6*dt/math.max(self.duration,0.10))
			local omega=4.6/math.max(self.duration,0.10)
			local e=self.o_rel-rel
			local v=self.move_velocity or ZERO
			local decay=math.exp(-omega*dt)
			local proposed=rel+(e+(v+e*omega)*dt)*decay
			self.move_velocity=(v-(v+e*omega)*(omega*dt))*decay
			local delta=proposed-self.o_rel
			local length=vmagnitude(delta)
			local cap=position_limit*0.35
			if length>cap then delta*=cap/length; self.move_velocity=dt>0 and delta/dt or ZERO end
			out_rel=self.o_rel+delta
			if closer then out_rel=rel;self.move_velocity=ZERO end
			local angle=acos(clamp(vdot(self.o_fwd,forward),-1,1))
			if angle>1e-5 then
				local axis=vcross(self.o_fwd,forward)
				if vmagnitude(axis)<1e-5 then axis=vcross(self.o_fwd,abs(self.o_fwd.y)<0.9 and UP or vcreate(1,0,0)) end
				axis=S3.normalized(axis,UP)
				local a=math.min(angle*fraction,turn_limit*DEGREES*0.35)
				out_fwd=S3.normalized(self.o_fwd*cos(a)+vcross(axis,self.o_fwd)*sin(a),forward)
			else out_fwd=forward end
			local u=self.o_up+(up-self.o_up)*fraction
			local fallback=abs(out_fwd.y)<0.9 and UP or vcross(out_fwd,vcreate(1,0,0))
			out_up=S3.normalized(u-out_fwd*vdot(u,out_fwd),fallback)
			if fov and self.o_fov then out_fov=self.o_fov+clamp((fov-self.o_fov)*fraction,-fov_limit*0.35,fov_limit*0.35) end
			if vmagnitude(out_rel-rel)<1e-4 and vmagnitude(out_fwd-forward)<1e-4 and (not fov or not out_fov or abs(fov-out_fov)<0.001) then
				self.smoothing=false
				out_rel,out_fwd,out_up,out_fov=rel,forward,up,fov
			end
		else
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
	end
	if self.rotation_passthrough then out_fwd,out_up=forward,up end
	if self.fov_passthrough then out_fov=fov end
	self:remember(rel, forward, fov, out_rel, out_fwd, out_up, out_fov, subject, step_vec, turn, dfov)
	if self.smoothing then
		local out_pos = subject + out_rel
		if impact ~= 0.0 then
			-- Put the drop back: the camera lower by it, aiming at the same point from there.
			out_pos = out_pos - lift
			out_fwd = S3.normalized(out_fwd * reach + lift, out_fwd)
		end
		if rattle then
			out_fwd, out_up = rattled(out_fwd, out_up, rattle, 1.0)
		end
		return out_pos, out_fwd, out_up, out_fov, cause, amount
	end
	return shown_pos, shown_forward, shown_up, fov, cause, amount
end

return M
