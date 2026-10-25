-- The off-board camera: an orbit camera for walking, standing, running, bailing and landing a hippy jump on foot.
--
-- Pure maths: it reads nothing from the game. The glue reads the joints, the sticks and the world and passes them in:
--
--   local off = Off.new(settings)              settings: Off.defaults() (the glue passes store.options.offboard)
--   off:start(from_pose, body)                 from_pose = the view on screen now { pos, forward, up, fov }; the orbit begins
--                                              exactly there and eases into its own framing over settings.transition_time
--   pos, forward, up, fov = off:update(dt, input, body, query)
--   off:recentre_now()                         (R3) swing behind the skater, eased
--   off:summary() -> text                      one line for the log, with the walking-direction estimate's error
--
--   input = { look_x, look_y (right stick, -1..1, up positive), left_x, left_y (left stick), mouse_dx, mouse_dy }
--   body  = { centre, head, hips (world vectors), velocity (vector), heading (radians, 0 = +Z, growing toward +X), ragdoll, valid }
--   query(from, to, want_normal) -> hit point or nil: the world ray, as the glue casts it.
--
-- Yaw is the direction the camera faces, atan2(x, z) (0 along +Z, growing toward +X: the same as the skater's heading). The right of
-- a view facing yaw is (-cos yaw, 0, sin yaw), so turning right means a smaller yaw.
--
-- Why the walking-direction estimate exists: Skate 3 steers walking by its own hidden camera, which keeps turning with the right
-- stick underneath ours and which a plugin cannot read while it holds the view. We learn where it faces from how the skater walks
-- (move direction = hidden yaw - atan2(stick x, stick y)), and we turn ours the way the game turns its own, so the left stick's
-- "forward" stays close to the screen's. When the player is not steering the view, ours eases toward the estimate, slowly.

local S3 = require("s3math")

local Off = {}
Off.__index = Off

local vcreate, vmagnitude, vdot = vector.create, vector.magnitude, vector.dot
local sin, cos, atan2, exp, sqrt, abs = math.sin, math.cos, math.atan2, math.exp, math.sqrt, math.abs
local clamp, max, min = math.clamp, math.max, math.min
local wrap = S3.wrap_angle
local RAD = S3.degrees
local UP = vcreate(0, 1, 0)

-- ---------------------------------------------------------------- tuning that is not a setting
local MAX_DT = 0.1
local DEADZONE = 0.12 -- right stick
local STICK_IDLE = 0.05 -- after the dead zone: below this the view is not being steered
local PITCH_RATIO = 110.0 / 170.0 -- the game turns up and down slower than sideways
local PITCH_MIN, PITCH_MAX = -35.0 * RAD, 55.0 * RAD -- orbit elevation of the camera above its pivot
local PITCH_REST = 10.0 * RAD -- where a recentre leaves the camera's elevation
local PITCH_BACK_RATE = 60.0 * RAD -- an elevation outside the limits is eased back at this rate
local MOUSE_RAD_PER_COUNT = 0.1 * RAD
local RECENTRE_MIN_SPEED = 1.0 -- m/s: standing still never recentres
local RECENTRE_RATE = 90.0 * RAD -- the cap
local RECENTRE_REQUEST_RATE = 240.0 * RAD -- R3
local RECENTRE_KP = 2.5 -- 1/s: the approach slows as the gap closes
local RECENTRE_EASE = 0.5 -- s: the swing eases in and out
local BAIL_RECENTRE_SCALE = 0.35
local ALIGN_RATE = 30.0 * RAD -- the view eases toward the estimate no faster than this
local ALIGN_KP = 1.5
local ALIGN_MIN_CONFIDENCE = 0.35
local ALIGN_IDLE = 0.3 -- s without steering before it starts
local ALIGN_DEADBAND = 3.0 * RAD
local ALIGN_EASE = 0.5
local LEFT_STICK_MIN = 0.5
local LEFT_STICK_STEADY = 0.3 -- s
local LEFT_STICK_DRIFT = 25.0 * RAD
local ESTIMATE_MIN_SPEED = 1.0
local FRAMING_SMOOTH = 0.3 -- s: distance, height, look height, shoulder and FOV follow their settings, never jump to them
local BAIL_SMOOTH = 0.6
local LEVEL_EXTRA = 0.6 -- s of vertical smoothing added at Level 1
local BOB_REF_TIME, BOB_LOW_PASS = 0.35, 0.04
local BOB_LIMIT = 0.08
local BOB_GAIN = 1.5
local ARM_MARGIN = 0.35 -- m kept between the camera and what the ray hit
local ARM_MIN = 0.2
local ARM_SIDE = 0.25
local PULL_IN_TIME, RELEASE_TIME, HOLD_TIME = 0.12, 0.4, 0.3
local PULL_IN_SLACK = 0.15 -- m of the margin the smoothing may use up; the camera never gets past the hit
local GROUND_CLEARANCE = 0.3
local LIFT_RISE, LIFT_FALL = 0.08, 0.4
local MAX_RAYS = 3
local FRAME_FRACTION = 0.8 -- of the half FOV: head and hips stay inside this in a bail
local EXTRA_MAX = 6.0
local TELEPORT = 6.0 -- m between two ticks: a cut, not a walk
local FALLBACK_FOV = 60.0
local FOV_MIN, FOV_MAX = 40.0, 110.0

-- ---------------------------------------------------------------- settings
Off.MODES = { "dynamic", "game" }
Off.STYLE_NAMES = { "orbit", "shoulder" }

function Off.defaults()
	return {
		style = "orbit",
		distance = 2.8, -- m from the camera to its pivot
		height = 0.35, -- m, the camera's pivot above the body's centre
		look_height = 0.35, -- m, what the camera aims at, above the centre
		offset = 0.0, -- m to the right (negative: left); the shoulder-side bind flips its sign
		fov = 0.0, -- 0: the game's own
		follow_time = 0.2, -- s, the follow of the body's centre
		turn_time = 0.06, -- s, smoothing of the stick turning the view
		stick_speed = 170.0, -- degrees a second at full stick (the game's own)
		invert_y = false,
		recentre_after = 1.5, -- s without steering, while moving, before the camera swings behind (0: never)
		match_walking = true, -- ease the view toward the direction the left stick walks "forward"
		level = 0.85, -- how much of the body's vertical bobbing is filtered out
		bob = 0.2, -- the walking bob that is put back on purpose
		bail_distance = 1.3, -- x the distance while the skater is in a ragdoll
		transition_time = 0.6, -- s, board <-> foot
	}
end

-- What a style fills in (the sliders stay editable after). Shoulder is the Arkham-style walk: close, over one shoulder.
function Off.style_values(style, base_fov)
	if style == "shoulder" then
		local fov = (base_fov and base_fov > 0) and base_fov + 5.0 or FALLBACK_FOV + 5.0
		return { distance = 1.6, height = 0.55, look_height = 0.55, offset = 0.55, fov = clamp(math.floor(fov + 0.5), FOV_MIN, FOV_MAX),
			turn_time = 0.03, recentre_after = 0.0 }
	end
	local d = Off.defaults()
	return { distance = d.distance, height = d.height, look_height = d.look_height, offset = d.offset, fov = d.fov,
		turn_time = d.turn_time, recentre_after = d.recentre_after }
end

function Off.apply_style(t, style, base_fov)
	for k, v in Off.style_values(style, base_fov) do
		t[k] = v
	end
	t.style = style
end

local function num(v, lo, hi)
	return type(v) == "number" and v - v == 0 and v >= lo and v <= hi
end

function Off.valid(t)
	return type(t) == "table" and (t.style == "orbit" or t.style == "shoulder") and num(t.distance, 1.0, 6.0) and num(t.height, -0.5, 1.5)
		and num(t.look_height, -0.3, 1.0) and num(t.offset, -1.2, 1.2) and (t.fov == 0 or num(t.fov, FOV_MIN, FOV_MAX))
		and num(t.follow_time, 0.02, 1.0) and num(t.turn_time, 0.0, 0.5) and num(t.stick_speed, 30.0, 400.0)
		and type(t.invert_y) == "boolean" and num(t.recentre_after, 0.0, 10.0) and type(t.match_walking) == "boolean"
		and num(t.level, 0.0, 1.0) and num(t.bob, 0.0, 1.0) and num(t.bail_distance, 1.0, 2.5) and num(t.transition_time, 0.0, 3.0)
end

-- ---------------------------------------------------------------- helpers
local function finite3(v)
	local s = v.x + v.y + v.z
	return s - s == 0
end

-- The share of the gap a smoothing of time constant tau closes in dt.
local function rate(dt, tau)
	if tau <= 1e-4 then
		return 1.0
	end
	return 1.0 - exp(-dt / tau)
end

local function dead(v)
	if v == nil or v ~= v then
		return 0.0
	end
	local a = abs(v)
	if a < DEADZONE then
		return 0.0
	end
	a = min(1.0, (a - DEADZONE) / (1.0 - DEADZONE))
	return v < 0 and -a or a
end

-- ---------------------------------------------------------------- the object
function Off.new(settings)
	local self = setmetatable({}, Off)
	self.s = settings or Off.defaults()
	self.base_fov = 0.0 -- the game's own FOV, set by the glue
	self.side_sign = 1.0 -- the riding shoulder side: -1 mirrors the horizontal offset
	self.started = false
	self.rays = 0
	self.out_pos, self.out_fwd, self.out_up, self.out_fov = nil, nil, nil, nil
	self:reset_state()
	return self
end

function Off:reset_state()
	self.t = 0.0
	self.yaw, self.elev = 0.0, PITCH_REST
	self.w_yaw, self.w_el = 0.0, 0.0
	self.idle_for = 0.0
	self.rc_gain, self.rc_request = 0.0, false
	self.al_gain = 0.0
	self.hidden, self.conf = 0.0, 0.0
	self.l_held, self.l_ref = 0.0, 0.0
	self.align_error = 0.0
	self.move_yaw = 0.0
	self.speed = 0.0
	self.ph, self.vh = vcreate(0, 0, 0), vcreate(0, 0, 0)
	self.c_prev = vcreate(0, 0, 0)
	self.vref = vcreate(0, 0, 0)
	self.y, self.vy = 0.0, 0.0
	self.ry, self.bp = 0.0, 0.0
	self.dist, self.height, self.look, self.offset = 2.8, 0.35, 0.35, 0.0
	self.bailm, self.extra = 1.0, 0.0
	self.fov = FALLBACK_FOV
	self.arm, self.hold, self.lift = 1.0e3, 0.0, 0.0
	self.start_t, self.blend_time = 0.0, 0.0
	self.need_r0 = false
	self.r0 = vcreate(0, 0, 0)
	self.f0, self.u0 = vcreate(0, 0, 1), UP
end

-- Seats the follow filters on the body: no lag, no jump.
function Off:seat(body)
	local c = body.centre
	local v = body.velocity or vcreate(0, 0, 0)
	self.ph = vcreate(c.x, 0, c.z)
	self.vh = vcreate(v.x, 0, v.z)
	self.vref = self.vh
	self.c_prev = c
	self.y, self.vy = c.y, 0.0
	self.ry, self.bp = c.y, 0.0
end

-- Begins (or restarts) the orbit at `from`: where the view on screen is now. Its yaw, elevation and distance come from it, and the
-- difference between that pose and the orbit's own is eased out over transition_time (a sine blend), so nothing jumps.
function Off:start(from, body)
	local s = self.s
	self:reset_state()
	local c = body.centre
	self:seat(body)
	local pos, fwd, up, fov = from and from.pos, from and from.forward, from and from.up, from and from.fov
	if not pos or not fwd or not finite3(pos) or not finite3(fwd) or vmagnitude(fwd) < 1e-6 then
		-- Nothing on screen to start from: behind the way the skater faces.
		local h = body.heading or 0.0
		fwd = vcreate(sin(h), -0.15, cos(h))
		pos = c + UP * (s.height + 0.5) - vcreate(sin(h), 0, cos(h)) * s.distance
		up = UP
		fov = nil
	end
	fwd = S3.normalized(fwd, vcreate(0, 0, 1))
	if not up or not finite3(up) or vmagnitude(up) < 1e-6 then
		up = UP
	end
	local flat = sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
	self.yaw = flat > 1e-4 and atan2(fwd.x, fwd.z) or (body.heading or 0.0)
	-- The pivot is above the centre; the camera sits on a sphere round it.
	local pivot = c + UP * s.height
	local d = pos - pivot
	local dh = sqrt(d.x * d.x + d.z * d.z)
	self.elev = clamp(atan2(d.y, max(dh, 1e-3)), PITCH_MIN, PITCH_MAX)
	self.dist = clamp(vmagnitude(d), 1.0, 8.0)
	self.fov = (fov and fov >= 10 and fov <= 150) and fov or self:target_fov()
	self.height, self.look, self.offset = s.height, s.look_height, s.offset * self.side_sign
	self.from_pos, self.from_fwd, self.from_up = pos, fwd, S3.normalized(up, UP)
	self.blend_time = s.transition_time
	self.need_r0 = true
	self.started = true
	self.out_pos, self.out_fwd, self.out_up, self.out_fov = pos, fwd, self.from_up, self.fov
end

function Off:target_fov()
	local s = self.s
	if s.fov and s.fov > 0 then
		return clamp(s.fov, FOV_MIN, FOV_MAX)
	end
	return self.base_fov > 0 and self.base_fov or FALLBACK_FOV
end

-- R3: swing behind the skater, eased. Ends when it is there or the player steers.
function Off:recentre_now()
	self.rc_request = true
end

-- ---------------------------------------------------------------- the update
function Off:update(dt, input, body, query)
	if not self.started then
		if not body or not body.centre then
			return nil
		end
		self:start(nil, body)
	end
	local c = body.centre
	if not body.valid or not c or not finite3(c) then
		return self.out_pos, self.out_fwd, self.out_up, self.out_fov
	end
	local s = self.s
	dt = clamp(dt, 0.0, MAX_DT)
	self.rays = 0
	self.t += dt
	if vmagnitude(c - self.c_prev) > TELEPORT then
		self:seat(body) -- a teleport or a respawn: the filters follow at once
	end

	-- ---- the body's velocity
	local velocity = body.velocity
	local vx, vz
	if velocity then
		vx, vz = velocity.x, velocity.z
	else
		vx, vz = (c.x - self.c_prev.x) / max(dt, 1e-3), (c.z - self.c_prev.z) / max(dt, 1e-3)
	end
	local speed = sqrt(vx * vx + vz * vz)
	self.speed = speed
	if speed > 0.3 then
		self.move_yaw = atan2(vx, vz)
	end
	local ragdoll = body.ragdoll == true

	-- ---- the sticks turn the view
	local sx, sy = dead(input.look_x), dead(input.look_y)
	local mdx, mdy = input.mouse_dx or 0.0, input.mouse_dy or 0.0
	local steering = abs(sx) + abs(sy) > STICK_IDLE or mdx ~= 0 or mdy ~= 0
	local turn = rate(dt, s.turn_time)
	local yaw_rate = s.stick_speed * RAD
	local invert = s.invert_y and -1.0 or 1.0
	self.w_yaw += (-sx * yaw_rate - self.w_yaw) * turn
	self.w_el += (-sy * yaw_rate * PITCH_RATIO * invert - self.w_el) * turn
	local dyaw = self.w_yaw * dt - mdx * MOUSE_RAD_PER_COUNT
	local yaw = self.yaw + dyaw
	local elev = self.elev + self.w_el * dt + mdy * MOUSE_RAD_PER_COUNT * invert
	if steering then
		self.idle_for = 0.0
		self.rc_request = false
	else
		self.idle_for += dt
	end

	-- ---- where the game's hidden camera faces (estimated from how the left stick walks)
	if self.conf > 0 then
		self.hidden = wrap(self.hidden + dyaw) -- it turns with the same stick
	end
	local lx, ly = input.left_x or 0.0, input.left_y or 0.0
	local lmag = sqrt(lx * lx + ly * ly)
	if lmag > LEFT_STICK_MIN then
		local angle = atan2(lx, ly)
		if self.l_held <= 0 or abs(wrap(angle - self.l_ref)) > LEFT_STICK_DRIFT then
			self.l_ref = angle
			self.l_held = 0.0
		end
		self.l_held += dt
	else
		self.l_held = 0.0
	end
	if self.l_held >= LEFT_STICK_STEADY and speed > ESTIMATE_MIN_SPEED then
		local sample = wrap(self.move_yaw + atan2(lx, ly))
		if self.conf <= 0 then
			self.hidden, self.conf = sample, 0.3
		else
			local dev = wrap(sample - self.hidden)
			self.hidden = wrap(self.hidden + dev * rate(dt, abs(dev) > 25.0 * RAD and 0.2 or 0.5))
			self.conf = min(1.0, self.conf + dt * 0.8)
		end
	else
		self.conf = max(0.0, self.conf - dt / 40.0)
	end

	-- ---- recentre behind the walking direction
	local moving = speed > RECENTRE_MIN_SPEED
	local want_rc = self.rc_request or (s.recentre_after > 0 and moving and self.idle_for >= s.recentre_after)
	local rc_target = want_rc and 1.0 or 0.0
	self.rc_gain += (rc_target - self.rc_gain) * rate(dt, steering and 0.1 or RECENTRE_EASE)
	if self.rc_gain > 1e-3 then
		local aim = moving and self.move_yaw or (body.heading or self.move_yaw)
		local gap = wrap(aim - yaw)
		local cap = self.rc_request and RECENTRE_REQUEST_RATE or RECENTRE_RATE
		local scale = ragdoll and not self.rc_request and BAIL_RECENTRE_SCALE or 1.0
		yaw += clamp(gap * RECENTRE_KP, -cap, cap) * self.rc_gain * scale * dt
		elev += clamp((PITCH_REST - elev) * 2.0, -40.0 * RAD, 40.0 * RAD) * self.rc_gain * scale * dt
		if self.rc_request and abs(gap) < 2.0 * RAD then
			self.rc_request = false
		end
	end

	-- ---- match walking to the view: ease toward the estimate while the player is not steering
	local err = wrap(self.hidden - yaw)
	local align_ok = s.match_walking and self.conf >= ALIGN_MIN_CONFIDENCE and self.idle_for >= ALIGN_IDLE and self.rc_gain < 0.5
		and not ragdoll
	self.al_gain += ((align_ok and 1.0 or 0.0) - self.al_gain) * rate(dt, steering and 0.1 or ALIGN_EASE)
	if self.al_gain > 1e-3 then
		local dead_scale = clamp((abs(err) - ALIGN_DEADBAND) / (4.0 * RAD), 0.0, 1.0)
		yaw += clamp(err * ALIGN_KP, -ALIGN_RATE, ALIGN_RATE) * self.al_gain * dead_scale * dt
	end
	self.yaw = wrap(yaw)
	-- The limits are hard for the stick; a start pose outside them (a very high or low riding camera) is eased in at a fixed rate.
	if self.elev >= PITCH_MIN and self.elev <= PITCH_MAX then
		elev = clamp(elev, PITCH_MIN, PITCH_MAX)
	elseif elev > PITCH_MAX then
		elev = max(PITCH_MAX, min(elev, self.elev) - PITCH_BACK_RATE * dt)
	else
		elev = min(PITCH_MIN, max(elev, self.elev) + PITCH_BACK_RATE * dt)
	end
	self.elev = elev
	self.align_error = wrap(self.yaw - self.hidden)

	-- ---- the body's centre, filtered
	-- Sideways it is a critically damped spring that follows the body's own velocity too, so walking at a steady speed leaves no lag;
	-- only starts, stops and turns are smoothed. Up and down it is a two-term tracker (zero lag on a ramp) with a long time constant
	-- at high Level, so steps, stairs and crouches do not bob the camera.
	local w = 2.0 / max(s.follow_time, 0.02)
	local vref = vcreate(vx, 0, vz)
	local e = self.ph - vcreate(self.c_prev.x, 0, self.c_prev.z)
	local ve = self.vh - self.vref
	local decay = exp(-w * dt)
	local e_end = (e + (ve + e * w) * dt) * decay
	local ve_end = (ve - (ve + e * w) * (w * dt)) * decay
	self.ph = vcreate(c.x, 0, c.z) + e_end
	self.vh = vref + ve_end
	self.vref = vref
	self.c_prev = c
	local level = ragdoll and s.level * 0.5 or s.level
	local tv = s.follow_time + level * LEVEL_EXTRA
	if dt > 0 then
		local theta = exp(-dt / max(tv, 1e-3))
		local alpha, beta = 1.0 - theta * theta, (1.0 - theta) * (1.0 - theta)
		local predicted = self.y + self.vy * dt
		local residual = c.y - predicted
		self.y = predicted + alpha * residual
		self.vy += beta * residual / dt
	end
	-- the bob put back on purpose: the centre's own vertical motion around the stride, scaled by speed
	self.ry += (c.y - self.ry) * rate(dt, BOB_REF_TIME)
	self.bp += ((c.y - self.ry) - self.bp) * rate(dt, BOB_LOW_PASS)
	local bob = clamp(self.bp, -BOB_LIMIT, BOB_LIMIT) * s.bob * BOB_GAIN * clamp((speed - 0.5) / 2.5, 0.0, 1.0)
	local cf = vcreate(self.ph.x, self.y + bob, self.ph.z)

	-- ---- framing, each eased toward its setting
	local f = rate(dt, FRAMING_SMOOTH)
	self.bailm += ((ragdoll and s.bail_distance or 1.0) - self.bailm) * rate(dt, BAIL_SMOOTH)
	self.dist += (s.distance * self.bailm - self.dist) * f
	self.height += (s.height - self.height) * f
	self.look += (s.look_height - self.look) * f
	self.offset += (s.offset * self.side_sign - self.offset) * f
	self.fov += (self:target_fov() - self.fov) * f
	local dist = self.dist + self.extra

	local yaw_now = self.yaw
	local fh = vcreate(sin(yaw_now), 0, cos(yaw_now))
	local right = vcreate(-cos(yaw_now), 0, sin(yaw_now))
	local ce, se = cos(self.elev), sin(self.elev)
	local shift = right * self.offset
	local cam = cf + UP * self.height + shift - fh * (ce * dist) + UP * (se * dist)
	local aim = cf + UP * self.look + shift

	-- ---- collision: a spring arm from the look point, with the ground under the camera
	local origin = cf + UP * self.look
	local used = 0
	local lift_target = 0.0
	if cam.y < cf.y and query then
		local gy = query(vcreate(cam.x, cam.y + 1.0, cam.z), vcreate(cam.x, cam.y - 1.5, cam.z), false)
		used += 1
		if gy then
			lift_target = max(0.0, gy.y + GROUND_CLEARANCE - cam.y)
		end
	end
	self.lift += (lift_target - self.lift) * rate(dt, lift_target > self.lift and LIFT_RISE or LIFT_FALL)
	self.lift = max(self.lift, lift_target - 0.2) -- never under the floor
	cam += UP * self.lift
	local toward = cam - origin
	local length = vmagnitude(toward)
	local allowed = length
	if query and length > 1e-3 then
		local hit = query(origin, cam, false)
		used += 1
		if hit then
			allowed = max(ARM_MIN, vmagnitude(hit - origin) - ARM_MARGIN)
			-- a corner or a post beside the line: two rays either side, while the budget lasts
			local side = right * ARM_SIDE
			if used < MAX_RAYS then
				local a = query(origin + side, cam + side, false)
				used += 1
				if a then
					allowed = min(allowed, max(ARM_MIN, vmagnitude(a - origin - side) - ARM_MARGIN))
				end
			end
			if used < MAX_RAYS then
				local b = query(origin - side, cam - side, false)
				used += 1
				if b then
					allowed = min(allowed, max(ARM_MIN, vmagnitude(b - origin + side) - ARM_MARGIN))
				end
			end
		end
	end
	self.rays = used
	local arm = min(self.arm, length)
	self.pulled = allowed < arm -- the wall is in the way this tick (the glue's snap guard lets a pull-in through)
	if allowed < arm then
		self.hold = HOLD_TIME
		arm += (allowed - arm) * rate(dt, PULL_IN_TIME * 0.5)
		arm = min(arm, allowed + PULL_IN_SLACK)
	elseif self.hold > 0 then
		self.hold -= dt
	else
		arm += (allowed - arm) * rate(dt, RELEASE_TIME * 0.5)
	end
	self.arm = arm
	if length > 1e-3 and arm < length then
		cam = origin + toward * (arm / length)
	end

	-- ---- the view
	local forward = S3.normalized(aim - cam, fh)

	-- A bail: keep head and hips well inside the picture. The extra distance this finds is used by the next frame.
	local fov = self.fov
	if ragdoll and body.head and body.hips then
		local tan_limit = math.tan(FRAME_FRACTION * 0.5 * fov * RAD)
		local grow = 0.0
		for i = 1, 2 do
			local p = i == 1 and body.head or body.hips
			local v = p - cam
			local depth = vdot(v, forward)
			local lateral = vmagnitude(v - forward * depth)
			grow = max(grow, lateral / tan_limit - depth)
		end
		if grow > 0 then
			self.extra = min(EXTRA_MAX, self.extra + grow * rate(dt, 0.15))
		else
			self.extra = max(0.0, self.extra - self.extra * rate(dt, 1.5))
		end
	else
		self.extra = max(0.0, self.extra - self.extra * rate(dt, 0.5))
	end

	-- ---- the hand-over: the start pose eases into the orbit
	if self.need_r0 then
		self.need_r0 = false
		self.r0 = self.from_pos - cam
		self.f0, self.u0 = self.from_fwd, self.from_up
		self.start_t = 0.0
	end
	local up = UP
	if self.start_t < self.blend_time then
		self.start_t += dt
		local mix = S3.sine_blend(clamp(self.start_t / self.blend_time, 0.0, 1.0))
		cam += self.r0 * (1.0 - mix)
		forward = S3.normalized(self.f0 + (forward - self.f0) * mix, forward)
		up = S3.normalized(self.u0 + (UP - self.u0) * mix, UP)
	end
	if not (finite3(cam) and finite3(forward) and finite3(up)) then
		return self.out_pos, self.out_fwd, self.out_up, self.out_fov
	end
	self.out_pos, self.out_fwd, self.out_up, self.out_fov = cam, forward, up, clamp(fov, 10.0, 150.0)
	return cam, forward, up, self.out_fov
end

-- One line for the log, once a second: the angle, how sure the walking-direction estimate is and how far the view is from it.
function Off:summary()
	return string.format("off-board yaw %.0f deg elev %.0f dist %.2f | walking dir estimate %.0f deg (confidence %.2f), view minus estimate %+.1f deg | "
		.. "speed %.1f | rays %d arm %.2f extra %.2f",
		self.yaw / RAD, self.elev / RAD, self.dist + self.extra, self.hidden / RAD, self.conf, self.align_error / RAD, self.speed, self.rays,
		min(self.arm, 99.0), self.extra)
end

return Off
