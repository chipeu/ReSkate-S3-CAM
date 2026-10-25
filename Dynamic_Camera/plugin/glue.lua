-- The game glue: Extension/Camera/s3cam.cpp (s3cam_observe, s3cam_pose, the take / release rules in client_debug.cpp) written
-- against the reskate plugin API instead of reading game memory.
--
--   local g = Glue.new{ store = store, camera = require("camera"), diag = diag }   -- diag may be nil
--   g:on_physics_step(e)      the `physics_step` event (events.physics): step length, velocity, ragdoll
--   g:tick(dt_ms)             the `tick` event: observe the skater, take / run / release the camera
--   g:release(reason)         give the game its camera back (unload, level change, switched off)
--   g:dump() -> string        what `dyncam_dump` prints
--   g:status() -> text        the menu's Status line
--
-- What the DLL does that the plugin cannot (see also the report):
--  * The crossfade OUT to the game's camera: the game's pose is not readable while the plugin holds the camera, so the camera is
--    released at once. The crossfade IN works: it starts from the game's pose read just before the take (camera.get()).
--  * The game's camera far from the skater (map, customisation) is not readable; the game's menu flag (menu.game().open) is used.
--  * The board's nine physics bodies are not readable: the board's pitch (manual detection) comes from the deck's rotation.
--
-- Rays: reskate.world.raycast allows 64 a tick. The glue casts its own (ground, 2 to 6) first, then the camera's, and stops
-- answering at RAY_CAP; a tick that hit the cap is counted (rays_capped) and reported by dyncam_dump / the log.

local Settings = require("settings")
local S3 = require("s3math")
local Subject = require("subject")
local Rider = require("rider")
local DiagModule = require("diag")

local Glue = {}
Glue.__index = Glue

local vcreate, vmagnitude, vdot, vcross = vector.create, vector.magnitude, vector.dot, vector.cross
local clamp, max, min, abs, sqrt = math.clamp, math.max, math.min, math.abs, math.sqrt
local UP = vcreate(0, 1, 0)
local ZERO = vcreate(0, 0, 0)

-- ---------------------------------------------------------------- constants (s3cam.cpp)
local RAY_CAP = 60 -- of the 64 a tick the API allows; the rest is slack
local MAX_STEPS_PER_TICK = 4 -- fixed 1/60 s camera steps one tick may ask for (about 12 rays each)
local MAX_DT = MAX_STEPS_PER_TICK / 60
local GROUND_RAY_ABOVE, GROUND_RAY_BELOW = 0.1, 10.0
local START_HIT_SKIP, START_HIT_RESTART = 0.02, 0.03
local FALLING_CHORD_LIFT = 0.25
local MIN_NORMAL_UP = 0.1
local NORMAL_SMOOTH_DISTANCE = 0.25
local STEEP_GROUND_Y = 0.866
local NORMAL_SMOOTH_TIME = 0.08
local MAX_EXTRAPOLATION = 1.0 / 30.0
local EXTRAPOLATION_GRAVITY = 10.1
local PLAUSIBLE_FOV_MIN, PLAUSIBLE_FOV_MAX = 10.0, 150.0
local MANUAL_ON_DEGREES, MANUAL_OFF_DEGREES = 7.0, 4.0
local MANUAL_ON_TIME, MANUAL_OFF_TIME = 0.1, 0.1
local MANUAL_MAX_SLOPE_Y = 0.94
local MANUAL_AFTER_LANDING = 0.12
local PAUSE_AFTER = 0.25
local PAUSE_MIN_SPEED = 0.3
local HIPPY_MAX_TIME = 2.5
local HIPPY_RAGDOLL_GRACE = 1.5
local HIPPY_LAUNCH_SPEED = 2.5
local OFFBOARD_STATE = 504
local TAKE_AFTER = 0.15 -- s wanting the view before it is taken
local RELEASE_AFTER = 0.1 -- s not wanting it before it is given back
local RETRY_AFTER = 0.5 -- s after a refused take
Glue.RAY_CAP = RAY_CAP

local PS = Subject.physics_state

function Glue.new(deps)
	local self = setmetatable({}, Glue)
	self.store = deps.store
	self.diag = deps.diag
	self.camera_module = deps.camera
	self.cam = deps.camera.new()
	self.applied_revision = -1
	self.snap = Subject.new_snapshot()
	self.extras = { base_fov_deg = 0.0 }
	self.rider = Rider.new()
	self.running = false
	self.started = 0.0
	self.last_pose = 0.0
	self.blend = 0.0
	self.retry_after = 0.0
	self.last_refusal = ""
	self.game_pose = nil -- the game's camera as read while we did not hold it
	self.base_fov = 0.0
	self.spectating = false
	self.frame = nil
	-- observation state (Watch in s3cam.cpp)
	self.obs = { valid = false, wants_view = false, wants_for = 0.0, paused = false, bailing = false, state = 0 }
	self.state = nil
	self.state_since = 0.0
	self.wants, self.wants_known, self.wants_since = false, false, 0.0
	self.ground_normal = UP
	self.ground_normal_raw = UP
	self.ground_normal_at = 0.0
	self.landed_at = 0.0
	self.physics_root = ZERO
	self.root_changed_at = 0.0
	self.board_pitch, self.board_pitch_ok = 0.0, false
	self.hippy, self.hippy_since = false, 0.0
	self.manual, self.manual_candidate, self.manual_candidate_since = false, false, 0.0
	self.paused = false
	-- physics_step event
	self.step_velocity, self.step_seconds, self.step_ragdoll = nil, 0.0, nil
	self.steps_seen, self.last_step_at = false, 0.0
	-- rays and counters
	self.rays_tick, self.rays_total, self.rays_capped, self.ray_errors = 0, 0, 0, 0
	self.capped_this_tick = false
	self.stats = { frames = 0, steps = 0, held = 0, resets = 0, failed = 0, update_ms = 0.0, update_ms_max = 0.0, rays_at = 0 }
	self.total_frames, self.total_held, self.total_update_ms, self.landings = 0, 0, 0.0, 0
	self.report_at = 0.0
	self.errors, self.error_logged_at = 0, -100.0
	self.pad_r3 = false
	self.menu_open = false
	-- per-flight logging (watch_frame)
	self.shot = ""
	self.airborne, self.takeoff_at, self.takeoff_y = false, 0.0, 0.0
	self.landing_pending, self.landed_report_at = false, 0.0
	self.flight = { fov_min = 0.0, fov_max = 0.0, turn = 0.0, pull = 0.0, prev_back = nil, prev_fov = 0.0 }
	self.predicted = nil
	local g = self
	self.query = function(from, to, want_normal)
		return g:ground_query(from, to, want_normal)
	end
	return self
end

local function now_s()
	return reskate.time.now() / 1000.0
end

function Glue:log_verbose(text)
	if self.store.options.verbose and self.diag then
		self.diag:note(text)
	end
end

function Glue:note(text, level)
	reskate.log("dyncam: " .. text, level)
	if self.diag and self.store.options.verbose then
		self.diag:note(text)
	end
end

-- ---------------------------------------------------------------- rays
function Glue:cast(from, to)
	if self.rays_tick >= RAY_CAP then
		self.capped_this_tick = true
		return nil
	end
	self.rays_tick += 1
	self.rays_total += 1
	local ok, hit = pcall(reskate.world.raycast, from, to)
	if ok then
		return hit
	end
	self.ray_errors += 1
	return nil
end

-- The ray query gives a point only: the normal comes from two more short down-rays beside the hit (flat 0.7 deg, ramps 41 and
-- 60 deg measured this way in game). A side that misses is tried on the other side. No answer is "unknown", not flat.
function Glue:try_normal_at(hit)
	local reach, side = 1.0, 0.25
	local function probe(dx, dz)
		return self:cast(vcreate(hit.x + dx, hit.y + reach, hit.z + dz), vcreate(hit.x + dx, hit.y - reach, hit.z + dz))
	end
	local x = probe(side, 0)
	if not x then
		x = probe(-side, 0)
	end
	local z = probe(0, side)
	if not z then
		z = probe(0, -side)
	end
	if not x or not z then
		return nil
	end
	local n = vcross(z - hit, x - hit)
	if n.y < 0 then
		n = -n
	end
	n = S3.normalized(n, UP)
	if n.y < MIN_NORMAL_UP then
		return nil -- a probe hit a different surface (a wall, coping)
	end
	return n
end

-- ground_query of s3cam.cpp: the camera's world query. Returns the hit and, when asked (want_normal ~= false), its normal.
function Glue:ground_query(from, to, want_normal)
	if want_normal == nil then
		-- The camera does not say (its collision rays and the trajectory's chords both call query(from, to)): the trajectory
		-- only runs in the air, so a normal is worth its 2 to 4 extra rays only there. A caller that passes false/true is obeyed.
		want_normal = Subject.is_air_state(self.snap.physics_state)
	end
	if want_normal and to.y < from.y then
		-- A falling chord is cast from a little higher: a re-prediction just before touchdown starts at or under the landing surface.
		local hit = self:cast(vcreate(from.x, from.y + FALLING_CHORD_LIFT, from.z), to)
		if not hit then
			return nil
		end
		return hit, self:try_normal_at(hit) or UP
	end
	local hit = self:cast(from, to)
	if hit and to.y > from.y and vmagnitude(hit - from) < START_HIT_SKIP then
		-- A rising chord that touches the surface it starts on is cast again from a little further along.
		local d = to - from
		local len = vmagnitude(d)
		if len < 1e-9 then
			return nil
		end
		local direction = d / len
		local restart = from + direction * START_HIT_RESTART
		if vdot(to - restart, direction) <= 0 then
			return nil
		end
		hit = self:cast(restart, to)
	end
	if not hit then
		return nil
	end
	if want_normal then
		return hit, self:try_normal_at(hit) or UP
	end
	return hit
end

-- ---------------------------------------------------------------- physics_step
function Glue:on_physics_step(e)
	if e.seconds and e.seconds > 0 then
		self.step_seconds = e.seconds
	end
	local v = e.velocity
	if v and v[1] and v[2] and v[3] then
		self.step_velocity = vcreate(v[1], v[2], v[3])
	end
	if e.ragdoll ~= nil then
		self.step_ragdoll = e.ragdoll
	end
	self.steps_seen = true
	self.last_step_at = now_s()
end

-- ---------------------------------------------------------------- observe (s3cam_observe)
local function rotate(q, v)
	-- v rotated by the quaternion {x, y, z, w}
	local qx, qy, qz, qw = q.x, q.y, q.z, q.w
	local tx = 2 * (qy * v.z - qz * v.y)
	local ty = 2 * (qz * v.x - qx * v.z)
	local tz = 2 * (qx * v.y - qy * v.x)
	return vcreate(v.x + qw * tx + (qy * tz - qz * ty), v.y + qw * ty + (qz * tx - qx * tz), v.z + qw * tz + (qx * ty - qy * tx))
end
Glue.rotate = rotate

-- The deck's pitch against the ground, in degrees (+ front end up), from its rotation: the deck's long axis is the local axis
-- most along the skater's facing. nil when unknown.
function Glue:deck_pitch(motion, forward)
	local pose = motion and (motion.deck or motion.place)
	local q = pose and pose.rotation
	if not q or q.x == nil then
		return nil
	end
	local flat = S3.normalized(vcreate(forward.x, 0, forward.z), vcreate(0, 0, 1))
	local best, best_dot = nil, 0.0
	for _, axis in { vcreate(1, 0, 0), vcreate(0, 1, 0), vcreate(0, 0, 1) } do
		local a = rotate(q, axis)
		local d = vdot(a, flat)
		if abs(d) > abs(best_dot) then
			best, best_dot = a, d
		end
	end
	if not best or abs(best_dot) < 0.5 then
		return nil
	end
	if best_dot < 0 then
		best = -best
	end
	local up = vdot(S3.normalized(best, flat), S3.normalized(self.ground_normal_raw, UP))
	return math.asin(clamp(up, -1, 1)) / S3.degrees
end

local function finite3(v)
	local s = v.x + v.y + v.z
	return s - s == 0
end

-- Reads the skater once for this tick into self.snap and self.obs. Never raises.
function Glue:observe(now)
	local obs = self.obs
	obs.valid = false
	obs.skater = false
	local s = reskate.skater.get()
	if not s then
		obs.wants_view = false
		return obs
	end
	obs.skater = true
	local t = reskate.skater.telemetry()
	if not t or t.skater == false or not t.physics_state or t.physics_state == 0 then
		self.unreadable = (self.unreadable or 0) + 1
		self.snap.valid = false
		return obs
	end
	local state = t.physics_state
	local onboard = state ~= OFFBOARD_STATE
	local motion = reskate.board.motion()
	-- Riding: the board's root body velocity; off the board the hips' (physics_step gives whichever applies).
	local velocity = self.step_velocity or (motion and motion.velocity) or ZERO
	-- Offboard covers walking and bails alike; the ragdoll flag tells a bail.
	local ragdoll = false
	if not onboard then
		local w = t.watch
		if w and w.ragdoll_known then
			ragdoll = w.ragdoll and true or false
		else
			ragdoll = self.step_ragdoll == true
		end
	end
	local position = s.position
	local h = s.heading
	local forward = vcreate(math.sin(h), 0, math.cos(h))
	local snap = self.snap
	snap.time = now
	snap.position = position
	snap.forward = forward
	-- On the board the camera follows the rider, not the board (see rider.lua).
	snap.velocity = Rider.update(self.rider, now, position, velocity, onboard, self.step_seconds)
	snap.physics_state = state
	snap.onboard = onboard
	snap.manual = false
	snap.grind_side = 0
	snap.switch_stance = s.switch == true

	-- Ground under the skater. On a steep ramp the ray runs along the last slope's normal instead.
	local steep = self.ground_normal.y < STEEP_GROUND_Y
	local down = steep and -self.ground_normal or vcreate(0, -1, 0)
	local ground = self:cast(position - down * GROUND_RAY_ABOVE, position + down * GROUND_RAY_BELOW)
	local along_slope = steep and ground ~= nil
	if not ground and steep then
		ground = self:cast(position + vcreate(0, GROUND_RAY_ABOVE, 0), position - vcreate(0, GROUND_RAY_BELOW, 0))
	end
	if ground then
		snap.ground_clearance = along_slope and vmagnitude(position - ground) or position.y - ground.y
		local n = self:try_normal_at(ground)
		if n then
			self.ground_normal_raw = n
			local gap = clamp(now - self.ground_normal_at, 0.0, 0.25)
			local smooth = min(NORMAL_SMOOTH_TIME, NORMAL_SMOOTH_DISTANCE / max(0.1, vmagnitude(velocity)))
			local rate = 1.0 - math.exp(-gap / smooth)
			self.ground_normal = S3.normalized(S3.lerp(self.ground_normal, n, rate), n)
		end
	end
	self.ground_normal_at = now
	snap.ground_normal = self.ground_normal

	-- The board's real centre: manuals and grinds aim at it.
	snap.board_valid = false
	local place = motion and (motion.place or motion.deck)
	if place and place.position and finite3(place.position) and vmagnitude(place.position - position) < 2.5 then
		snap.board_valid = true
		snap.board_position = place.position
	end

	-- Board pitch against the ground: manual detection.
	do
		local pitch = self:deck_pitch(motion, forward)
		self.board_pitch_ok = pitch ~= nil
		if pitch then
			self.board_pitch = pitch
		end
		-- No manuals on steep ground, in the landing bounce, in the air or grinding.
		local prev = self.state
		if prev ~= nil and Subject.is_air_state(prev) and not Subject.is_air_state(state) then
			self.landed_at = now
		end
		local rolling = onboard and not Subject.is_air_state(state) and not Subject.is_grind_state(state)
			and self.ground_normal_raw.y >= MANUAL_MAX_SLOPE_Y and now - self.landed_at >= MANUAL_AFTER_LANDING
		local tilted = self.board_pitch_ok and rolling and abs(self.board_pitch) >= (self.manual and MANUAL_OFF_DEGREES or MANUAL_ON_DEGREES)
		if tilted ~= self.manual then
			if not self.manual_candidate then
				self.manual_candidate = true
				self.manual_candidate_since = now
			end
			if now - self.manual_candidate_since >= (self.manual and MANUAL_OFF_TIME or MANUAL_ON_TIME) then
				self.manual = tilted
				self.manual_candidate = false
				self:log_verbose(string.format("s3cam manual %s (board pitch %+.1f deg, state %d)",
					self.manual and (self.board_pitch > 0 and "on (nose up)" or "on (nose down)") or "off", self.board_pitch, state))
			end
		else
			self.manual_candidate = false
		end
		snap.manual = self.manual
	end

	-- Hippy jump or dismount: off the board from a riding state, without a ragdoll.
	local bailing = not onboard and ragdoll
	do
		local prev = self.state
		local riding_before = prev ~= nil and prev ~= OFFBOARD_STATE and (prev < 700 or prev == PS.post_grind)
		if self.hippy then
			local lasted = now - self.hippy_since
			local ended = onboard and "back on the board" or (ragdoll and lasted >= HIPPY_RAGDOLL_GRACE and "real bail")
				or (lasted >= HIPPY_MAX_TIME and "time limit") or nil
			if ended then
				self.hippy = false
				self:log_verbose(string.format("s3cam hippy jump over after %.2f s (%s)", lasted, ended))
			end
		elseif not onboard and not ragdoll and state ~= prev and riding_before then
			self.hippy = velocity.y >= HIPPY_LAUNCH_SPEED
			self.hippy_since = now
			self:log_verbose(string.format("s3cam off the board from state %d: %s (hips up %+.1f m/s)", prev, self.hippy and "hippy jump" or "dismount", velocity.y))
		end
		if self.hippy then
			bailing = false
			snap.physics_state = PS.air -- in the jump the camera treats the skater as in the air
		end
	end
	snap.bailing = bailing
	snap.valid = true

	-- The root moves once per physics step: between steps it is carried forward along its velocity.
	if position ~= self.physics_root then
		self.physics_root = position
		self.root_changed_at = now
	else
		local ahead = clamp(now - self.root_changed_at, 0.0, MAX_EXTRAPOLATION)
		local p = position + snap.velocity * ahead
		if Subject.is_air_state(state) then
			p = vcreate(p.x, p.y - 0.5 * EXTRAPOLATION_GRAVITY * ahead * ahead, p.z)
		end
		snap.position = p
	end

	if state ~= self.state then
		self:log_verbose(string.format("s3cam state %d -> %d after %.2f s%s%s", self.state or 0, state, now - self.state_since,
			ragdoll and " (ragdoll)" or "", snap.switch_stance and " (switch)" or ""))
		self.state = state
		self.state_since = now
	end

	-- Paused (pause menu, replay editor): the root has not moved for a while though the body has speed, or no physics step comes.
	local frozen = now - self.root_changed_at >= PAUSE_AFTER and vmagnitude(velocity) > PAUSE_MIN_SPEED
	local no_steps = self.steps_seen and now - self.last_step_at >= PAUSE_AFTER
	local paused = frozen or no_steps
	if paused ~= self.paused then
		self:log_verbose(string.format("s3cam game %s (speed %.1f m/s)", paused and "paused" or "running", vmagnitude(velocity)))
	end
	self.paused = paused

	obs.valid = Subject.usable(snap)
	obs.state = state
	obs.paused = paused
	obs.bailing = bailing
	obs.wants_view = (onboard or ragdoll or self.hippy) and not paused
	if not self.wants_known or obs.wants_view ~= self.wants then
		self.wants_known = true
		self.wants = obs.wants_view
		self.wants_since = now
	end
	obs.wants_for = now - self.wants_since
	return obs
end

-- ---------------------------------------------------------------- the camera run
local plugin_trajectory_step = 0.1 -- s, the landing prediction's chord in the plugin (see apply_settings)

function Glue:apply_settings()
	local store = self.store
	if store.revision ~= self.applied_revision then
		self.applied_revision = store.revision
		-- A plugin may cast 64 rays a tick: the landing prediction's chords of 1/20 s (up to 60 for a 3 s flight, all in the tick of the
		-- take-off) plus the collision's left the camera without rays in a jump. Chords of 1/10 s (30 at most) still find the
		-- contact, which the prediction refines inside the hit chord.
		local applied = Settings.copy(store.settings)
		if applied.trajectory and applied.trajectory.step < plugin_trajectory_step then applied.trajectory.step = plugin_trajectory_step end
		if not self.cam:set_settings(applied) then
			reskate.log("dyncam: settings rejected (out of range); the previous ones stay.", "warn")
		end
	end
end

-- Remembers the game's own camera (pose and FOV) while we do not hold it: the take starts its crossfade from it, and
-- the FOV is the base the camera's speed / big-air terms ride on.
function Glue:read_game_camera()
	local shown, why = reskate.camera.held()
	if shown or (why ~= nil and why ~= "it does not hold the camera") then
		return -- ours (or waiting for the game): get() would hand back our own view
	end
	local v = reskate.camera.get()
	if not v then
		self.game_pose = nil
		return
	end
	self.game_pose = { position = v.position, right = v.right, up = v.up, back = -v.forward }
	local fov = v.fov
	if fov and fov - fov == 0 and fov >= PLAUSIBLE_FOV_MIN and fov <= PLAUSIBLE_FOV_MAX then
		self.base_fov = fov
	end
end

local function orthonormalize(right, up)
	right = S3.normalized(right, vcreate(1, 0, 0))
	local u = up - right * vdot(up, right)
	if vmagnitude(u) < 1e-4 then
		u = abs(right.y) < 0.9 and vcreate(0, 1, 0) or vcreate(0, 0, 1)
		u = u - right * vdot(u, right)
	end
	up = S3.normalized(u, UP)
	return right, up, vcross(right, up)
end
Glue.orthonormalize = orthonormalize

-- One camera update. Returns pos, forward, up, fov (fov nil: leave the camera's own) or nil when there is no pose to show.
function Glue:pose(now)
	local st = self.stats
	local dt = clamp(now - self.last_pose, 0.0, MAX_DT)
	self.last_pose = now
	st.frames += 1
	self.total_frames += 1
	self:apply_settings()
	self.extras.base_fov_deg = self.base_fov
	local clock = os.clock()
	local ok, frame = pcall(self.cam.update, self.cam, dt, self.snap, self.query, self.extras)
	local ms = (os.clock() - clock) * 1000.0
	st.update_ms += ms
	st.update_ms_max = max(st.update_ms_max, ms)
	self.total_update_ms += ms
	if not ok then
		self.errors += 1
		st.failed += 1
		if now - self.error_logged_at > 5.0 then
			self.error_logged_at = now
			reskate.log("dyncam: the camera raised an error: " .. tostring(frame), "error")
		end
		return nil
	end
	local d = frame.debug or {}
	st.steps += d.steps or 0
	if d.held then
		st.held += 1
		self.total_held += 1
	end
	if d.reset then
		st.resets += 1
	end
	if not frame.valid then
		st.failed += 1
		return nil
	end
	self.frame = frame
	self:watch_frame(frame, now)

	-- Crossfade with the game's camera, from the pose read just before the take.
	local opts = self.store.options
	local gp = self.game_pose
	local blend_time = opts.take_blend_time
	local step = blend_time > 0 and dt / max(blend_time, 1e-3) or 1.0
	self.blend = min(1.0, self.blend + step)
	local mix = gp and S3.sine_blend(self.blend) or 1.0
	local right, up, back, pos = frame.right, frame.up, frame.back, frame.pos
	if mix < 1.0 then
		right = S3.lerp(gp.right, right, mix)
		up = S3.lerp(gp.up, up, mix)
		back = S3.lerp(gp.back, back, mix)
		pos = S3.lerp(gp.position, pos, mix)
		right, up, back = orthonormalize(right, up)
	end
	if not (finite3(pos) and finite3(up) and finite3(back)) or vmagnitude(back) < 1e-6 then
		st.failed += 1
		return nil
	end
	local fov
	if opts.shot_fov or self.store.settings.fov_override_deg > 0 then
		local base = self.base_fov
		fov = base > 0 and base + (frame.fov_deg - base) * mix or frame.fov_deg
		fov = clamp(fov, PLAUSIBLE_FOV_MIN, PLAUSIBLE_FOV_MAX)
	end
	return pos, -back, up, fov
end

function Glue:show(pos, forward, up, fov)
	local ok, shown, why = pcall(reskate.camera.set, pos, forward, up, fov)
	if not ok then
		self.errors += 1
		return false, tostring(shown)
	end
	return shown, why
end

function Glue:begin_run(now)
	self.running = true
	self.started = now
	self.last_pose = now
	self.blend = 0.0
	self.report_at = now + 1
	self.stats = { frames = 0, steps = 0, held = 0, resets = 0, failed = 0, update_ms = 0.0, update_ms_max = 0.0, rays_at = self.rays_total }
	self.spectating = false
	self.cam:cut()
	if self.diag and self.store.options.verbose then
		self.diag:begin_run()
	end
	local s = self.store.settings
	self:note(string.format("on: angle %s, shake %s, fov override %.0f, shot fov %s, base fov %.1f%s",
		s.angle == Settings.CameraAngle.High and "high" or "low", s.shake_enabled and "on" or "off", s.fov_override_deg,
		self.store.options.shot_fov and "on" or "off", self.base_fov, self.game_pose and "" or " (the game's camera was not readable)"))
end

function Glue:release(reason)
	if self.running then
		self.running = false
		if self.landing_pending and self.store.options.verbose then
			self:log_landing()
		end
		self.landing_pending = false
		self:note(string.format("off (%s): %.1f s, %d frames, %d held, update %.3f ms mean, %d landings so far", reason or "stopped",
			now_s() - self.started, self.total_frames, self.total_held,
			self.total_frames > 0 and self.total_update_ms / self.total_frames or 0.0, self.landings))
		if self.diag then
			self.diag:end_run(reason)
		end
	end
	pcall(reskate.camera.release)
	self.frame = nil
end

-- Take / release / run, once a tick.
function Glue:tick(dt_ms)
	local now = now_s()
	self.rays_tick = 0
	self.capped_this_tick = false
	local store = self.store

	-- R3 switches Low / High (the DLL follows the game's camera height option; the plugin reads the stick click itself).
	local pad_ok, pad = pcall(reskate.input.gamepad)
	local r3 = pad_ok and pad ~= nil and pad.buttons ~= nil and pad.buttons.right_stick == true
	if r3 and not self.pad_r3 and store.options.follow_game_height and store.enabled and not self.menu_open then
		store:toggle_height()
		self:note("R3: Low / High switched")
	end
	self.pad_r3 = r3

	if not store.enabled then
		if self.running then
			self:release("switched off")
		end
		self:read_game_camera()
		return
	end

	local obs = self:observe(now)
	local ok_menu, game_menu = pcall(reskate.menu.game)
	self.menu_open = ok_menu and game_menu ~= nil and game_menu.open == true

	if self.running then
		-- Screens of the game's own, no skater, a pause, or on foot: hand back at once.
		local reason
		if not obs.skater then
			reason = "no skater"
		elseif self.menu_open then
			reason = "a game menu is open"
		elseif obs.valid and obs.paused then
			reason = "the game is paused"
		elseif obs.valid and not obs.wants_view and obs.wants_for >= RELEASE_AFTER then
			reason = "on foot"
		end
		if reason then
			self:release(reason)
			self:read_game_camera()
			return
		end
		local shown, why = reskate.camera.held()
		if not shown and why then
			if string.find(why, "Spectate", 1, true) then
				self.spectating = true -- our view is not shown; start fresh when it is
				return
			elseif why == "it does not hold the camera" then
				self:release("the camera was taken away")
				self.retry_after = now + RETRY_AFTER
				return
			end
		end
		if self.spectating then
			self.spectating = false
			self.cam:cut()
			self.last_pose = now
		end
		if not obs.valid then
			self.stats.held += 1
			self.total_held += 1
			return -- the skater is unreadable: the last view stays
		end
		local pos, forward, up, fov = self:pose(now)
		if pos then
			local ok, why2 = self:show(pos, forward, up, fov)
			if not ok then
				self:release("camera refused: " .. tostring(why2))
				self.retry_after = now + RETRY_AFTER
			end
		end
		self:after_tick(now)
		return
	end

	-- Not running: keep the game's camera in mind, and take the view when the rider has wanted it long enough.
	self:read_game_camera()
	if self.capped_this_tick then
		self.rays_capped += 1
	end
	if now < self.retry_after or self.menu_open or not obs.valid or not obs.wants_view or obs.wants_for < TAKE_AFTER then
		return
	end
	self:begin_run(now)
	local pos, forward, up, fov = self:pose(now)
	if not pos then
		self.running = false
		self.retry_after = now + RETRY_AFTER
		return
	end
	local ok, why = self:show(pos, forward, up, fov)
	if not ok then
		self.running = false
		self.retry_after = now + RETRY_AFTER
		why = tostring(why)
		if why ~= self.last_refusal then
			self.last_refusal = why
			reskate.log("dyncam: could not take the camera: " .. why, "warn")
		end
		pcall(reskate.camera.release)
		return
	end
	self.last_refusal = ""
end

function Glue:after_tick(now)
	if self.capped_this_tick then
		self.rays_capped += 1
		if self.store.options.verbose and self.diag then
			self.diag:note(string.format("t=%.2f ray budget reached (%d of 64 used)", now - self.started, self.rays_tick))
		end
	end
	local opts = self.store.options
	if opts.verbose and self.diag and self.frame and self.snap.valid then
		self.diag:push(DiagModule.sample_of(now - self.started, self.obs.state, self.manual, self.frame, self.snap))
		self.diag:tick(now)
	end
	self:report(now)
end

-- ---------------------------------------------------------------- logging (report, watch_frame, log_landing)
function Glue:report(now)
	if now < self.report_at then
		return
	end
	self.report_at = now + 1
	local st = self.stats
	local f = self.frame
	if self.store.options.verbose and self.diag and f then
		local d = f.debug or {}
		self.diag:note(string.format(
			"s3cam t=%.0f %d frames, %d steps, %d held, %d resets, %d failed | update %.3f ms mean, %.3f max, %d rays, %d ticks over the ray budget | "
				.. "state %s shot %s speed %.1f clearance %.2f normal.y %.3f | dist %.2f elev %.1f lag %.2f | fov %.1f (game %.1f) | blend %.2f | board pitch %s manual %s",
			now - self.started, st.frames, st.steps, st.held, st.resets, st.failed,
			st.frames > 0 and st.update_ms / st.frames or 0.0, st.update_ms_max, self.rays_total - st.rays_at, self.rays_capped,
			tostring(self.state), tostring(d.shot_name), d.speed or 0, self.snap.ground_clearance, self.snap.ground_normal.y,
			d.distance or 0, (d.elevation or 0) / S3.degrees, d.anchor_lag or 0, f.fov_deg, self.base_fov, self.blend,
			self.board_pitch_ok and string.format("%+.1f deg", self.board_pitch) or "unreadable", self.manual and "on" or "off"))
	end
	st.frames, st.steps, st.held, st.resets, st.failed = 0, 0, 0, 0, 0
	st.update_ms, st.update_ms_max, st.rays_at = 0.0, 0.0, self.rays_total
end

function Glue:log_landing()
	local f = self.flight
	local p = self.predicted
	self:log_verbose(string.format(
		"s3cam landing #%d: air %.2f s (predicted %s), drop %+.2f m (predicted %s), speed %.1f m/s, fell %.2f m (shake %.0f%%), "
			.. "in the air: fov %.1f-%.1f, largest turn %.2f deg/frame, collision pull %.2f m",
		self.landings, self.landed_air or 0, p and string.format("%.2f s", p.air) or "none", self.landed_drop or 0,
		p and string.format("%+.2f m", p.drop) or "none", self.landing_speed or 0, self.landing_fall or 0,
		(self.landing_fraction or 0) * 100, f.fov_min, f.fov_max, f.turn, f.pull))
end

-- Shot changes, takeoffs and landings, from the frame's debug values.
function Glue:watch_frame(frame, now)
	local d = frame.debug or {}
	local f = self.flight
	local verbose = self.store.options.verbose
	local shot = d.shot_name or ""
	if verbose and shot ~= self.shot then
		self:log_verbose(string.format("s3cam shot %s -> %s (state %s, speed %.1f)", self.shot == "" and "none" or self.shot, shot,
			tostring(self.state), d.speed or 0))
	end
	self.shot = shot
	local air = d.airborne and true or false
	if air and not self.airborne then
		f.fov_min, f.fov_max, f.turn, f.pull, f.prev_back = frame.fov_deg, frame.fov_deg, 0.0, 0.0, nil
		self.takeoff_at, self.takeoff_y, self.predicted, self.landing_pending = now, self.snap.position.y, nil, false
	end
	if air then
		f.fov_min, f.fov_max = min(f.fov_min, frame.fov_deg), max(f.fov_max, frame.fov_deg)
		if f.prev_back then
			f.turn = max(f.turn, math.acos(clamp(vdot(frame.back, f.prev_back), -1, 1)) / S3.degrees)
		end
		f.pull = max(f.pull, d.collision_pull or 0)
		if d.prediction_valid then
			self.predicted = { air = d.predicted_air_time or 0, drop = d.predicted_landing_delta or 0 }
		end
	end
	f.prev_back = frame.back
	if not air and self.airborne then
		self.landings += 1
		self.landed_at_run = now
		self.landed_air = now - self.takeoff_at
		self.landed_drop = self.snap.position.y - self.takeoff_y
		self.landing_speed = vmagnitude(self.snap.velocity)
		self.landing_fall = d.landing_fall or 0
		self.landing_fraction = d.landing_fraction or 0
		self.landing_pending = true
	end
	self.airborne = air
	if self.landing_pending and now - (self.landed_at_run or now) >= 0.3 then
		self.landing_pending = false
		if verbose then
			self:log_landing()
		end
	end
end

-- ---------------------------------------------------------------- reporting to the menu and the console
function Glue:status()
	if not self.store.enabled then
		return "Off"
	elseif self.running then
		return self.spectating and "Enabled (Spectate has the camera)" or "Enabled"
	elseif self.last_refusal ~= "" then
		return "Waiting: " .. self.last_refusal
	end
	return "Disabled off board"
end

function Glue:dump()
	local s, o = self.store.settings, self.store.options
	local text = string.format("Dynamic Camera %s | angle %s | shake %s | fov override %.0f | shot fov %s | log %s | rays/tick cap %d, ticks over it %d",
		self.running and "owns the view" or "idle", s.angle == Settings.CameraAngle.High and "high" or "low", s.shake_enabled and "on" or "off",
		s.fov_override_deg, o.shot_fov and "on" or "off", o.verbose and "on" or "off", RAY_CAP, self.rays_capped)
	if self.running and self.frame then
		local f = self.frame
		local d = f.debug or {}
		text ..= string.format("\nshot %s (%.0f%%) | speed %.1f m/s | dist %.2f m | elev %.1f deg | heading %.1f deg | anchor lag %.2f m | "
			.. "air hold %+.2f m | impulse %.3f | fov %.1f | incline %.1f deg", tostring(d.shot_name), (d.shot_fraction or 0) * 100, d.speed or 0,
			d.distance or 0, (d.elevation or 0) / S3.degrees, (d.heading or 0) / S3.degrees, d.anchor_lag or 0, d.air_hold_delta or 0,
			d.impulse or 0, f.fov_deg, d.incline_degrees or 0)
	end
	return text
end

return Glue
