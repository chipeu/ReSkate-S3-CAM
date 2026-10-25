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
-- Off the board (options.offboard_mode "dynamic", the default) the glue keeps the view: self.source is "ride" (camera.lua draws) or
-- "foot" (offboard.lua draws, fed the hips / spine / head joints and the pad's sticks). When it changes, the off-board camera starts
-- from the pose on screen and eases into its own over the Board / foot transition time; the riding camera, on a remount, is blended in
-- from the last shown pose the same way (the take's crossfade, with the shown pose as the "game" pose). Nothing is released
-- on the way. A hippy jump keeps the riding air camera until the landing on foot. "game" keeps the eased hand-back below.
--
-- What the DLL does that the plugin cannot (see also the report):
--  * The crossfade OUT to the game's camera: the game's pose is not readable while the plugin holds the camera. Stepping off the
--    board eases to an ESTIMATE of where the game's on-foot camera will be (learned while on foot, see learn_on_foot), then
--    releases; every other way out (menu, pause, no skater, switched off) releases at once. The crossfade IN works: it starts from
--    the game's pose read just before the take (camera.get()).
--  * The game's camera far from the skater (map, customisation) is not readable; the game's menu flag (menu.game().open) is used.
--  * The board's nine physics bodies are not readable: the board's pitch (for the log and the board centre) comes from the deck's rotation when
--    the game gives it (board.motion().deck, after ReSkate 2.1.2) and from the two feet otherwise (skater.joint).
--
-- Rays: reskate.world.raycast allows 64 a tick. The glue casts its own (ground, 2 to 6) first, then the camera's, and stops
-- answering at RAY_CAP; a tick that hit the cap is counted (rays_capped) and reported by dyncam_dump / the log.

local Settings = require("settings")
local S3 = require("s3math")
local Subject = require("subject")
local Rider = require("rider")
local SnapGuard = require("snapguard")
local DiagModule = require("diag")
-- Optional at start (main.lua): without it the camera is handed back on foot, as in the "game" mode.
local has_off, Off = pcall(require, "offboard")
if not has_off then
	Off = nil
end

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
local PAUSE_AFTER = 0.25
-- A frozen root only means a pause on the board and at speed: on foot the hips' velocity is noise while the root stands still, and
-- reading that as a pause handed the camera back (and took it again) every time the skater stood or walked slowly.
local PAUSE_BOARD_MIN_SPEED = 2.0
-- The game's own FOV, as read while it holds the camera. A zoomed screen or a menu reports something far from the usual 65 (28
-- was seen), and a camera that rides on such a base zooms with it: only a plausible value is taken.
local BASE_FOV_MIN, BASE_FOV_MAX = 50.0, 100.0
local DEFAULT_BASE_FOV = 65.0
local SHORT_RELEASE = 3.0 -- s: a retake this soon after a release (a menu, a pause) can start from the pose we showed
local PATH_HINT_EXTRA = 0.5 -- s a transition's name stays on the snap counts after its blend should be over
local HIPPY_MAX_TIME = 2.5
local HIPPY_RAGDOLL_GRACE = 1.5
local HIPPY_LAUNCH_SPEED = 2.5
local OFFBOARD_STATE = 504
local TAKE_AFTER = 0.15 -- s wanting the view before it is taken
local RELEASE_AFTER = 0.1 -- s not wanting it before it is given back
local RETRY_AFTER = 0.5 -- s after a refused take
-- The board's pitch from the feet (ReSkate 2.1.2 has no deck pose). Joint indices of skater_skeleton.h.
local RIGHT_FOOT_JOINT, LEFT_FOOT_JOINT = 10, 343
local FEET_MIN_SPACING, FEET_MAX_SPACING = 0.2, 0.9 -- m along the travel; a foot off the board or a bad read is not a pitch
local FEET_BELOW_CENTRE = 0.08 -- m, the board's centre under the midpoint of the feet (ankle joints sit above the deck)
local TRAVEL_MIN_SPEED = 1.0 -- m/s; slower, the skater's facing says which end is the nose
-- Handing back: the estimate of the game's on-foot camera.
local ONFOOT_LEARN_TIME = 1.0 -- s, the exponential smoothing of what is learned
local ONFOOT_MAX_DISTANCE = 15.0 -- m; a game camera further than this from the skater (map, free camera) is not the on-foot one
local FALLBACK_BACK, FALLBACK_UP, FALLBACK_LOOK = 2.6, 1.5, 1.0 -- m, when nothing was learned or captured
-- The off-board camera follows the body: hips, spine and head joints of skater_skeleton.h (32 joints are shared by all plugins).
local HIPS_JOINT, SPINE_JOINT, HEAD_JOINT = 7, 44, 103
local CENTRE_HIPS_WEIGHT = 0.6 -- the centre is 0.6 hips + 0.4 spine
local HIPS_TO_CENTRE = 0.18 -- m above the hips, when only they are readable
local FALLBACK_CENTRE_UP = 0.9 -- m above the skater's position, when no joint is readable
local BODY_MAX_DISTANCE = 4.0 -- m from the skater's position: a joint further away is a stale read
local HIPPY_LANDED_RISE = 0.12 -- m above the height the jump left from: back on the ground
local HIPPY_LANDED_SPEED = 1.5 -- m/s of vertical speed
local HIPPY_LANDED_FOR = 0.15 -- s on the ground before the riding camera lets go
local HIPPY_MIN_TIME = 0.3 -- s into the jump before it can count as landed
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
	self.game_pose_fresh = false -- ... and whether this tick's read got it
	self.base_fov = 0.0
	-- Stepping off the board: the camera eases to where the game's own on-foot camera will be before it is handed back.
	self.handback = nil -- nil, or { started, duration, from = { pos, forward, up, fov }, fov_to } while easing
	self.last_shown = { pos = nil, forward = nil, up = nil, fov = nil } -- what camera.set was given last (the ease starts there)
	-- The snap guard (snapguard.lua) sits in show(), in front of every camera.set. snap_guard_on = false lets a test see the paths alone.
	self.guard = SnapGuard.new()
	self.snap_guard_on = true
	self.snaps = { position = 0, turn = 0, fov = 0 } -- jumps smoothed since the plugin loaded, by what made them ...
	self.snaps_by_path = {} -- ... and by which path was drawing
	self.snaps_total = 0
	self.path_hint, self.path_hint_until = nil, 0.0 -- the name of a transition for the counts (board->foot ...), while it lasts
	self.pulled = false -- the camera slid in against a wall this tick (the guard lets that through)
	self.released_at = nil -- when the camera was last given back (a short release lets the retake start from our last pose)
	self.game_pose_ok = false -- the game's camera as read looks like a real game camera (plausible fov, near the skater)
	self.take_offset = nil -- the game's riding camera as seen from the skater at the last take (back, up, right, look)
	self.onfoot = nil -- the same for the game's on-foot camera, learned while the skater is on foot
	self.onfoot_at = 0.0
	self.skater_position, self.skater_heading = ZERO, 0.0
	-- The off-board camera (offboard.lua) and what it is fed. All preallocated: nothing is made per tick.
	self.off = Off and Off.new(deps.store.options.offboard) or nil
	self.source = nil -- who draws the view while running: "ride" (the riding camera) or "foot" (the off-board camera)
	self.body = { centre = ZERO, head = ZERO, hips = ZERO, velocity = ZERO, heading = 0.0, ragdoll = false, valid = false }
	self.input = { look_x = 0.0, look_y = 0.0, left_x = 0.0, left_y = 0.0, mouse_dx = 0.0, mouse_dy = 0.0 }
	self.from_pose = { pos = nil, forward = nil, up = nil, fov = nil }
	self.tele_body = nil -- telemetry.body (the hips) in a bail
	self.obs_velocity = ZERO
	self.blend_time = nil -- set while the riding camera is blended in from the off-board one (Board / foot transition time)
	self.game_fov = nil -- the FOV of the pose that blend starts from
	self.hippy_base, self.hippy_landed_since = 0.0, nil
	self.body_joints = 0 -- how many of hips / spine / head were readable this tick
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
	self.pitch_source = nil -- "deck", "feet" or nil (unreadable) as of the last tick on the board
	self.pitch_source_noted = false -- the once-a-run note of it
	self.feet_centre = nil
	self.hippy, self.hippy_since = false, 0.0
	self.manual = false
	self.manual_detector = nil -- a Manual object (manual.lua), set by app.lua after Glue.new
	self.manuals = 0 -- manuals detected since the plugin loaded
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
		self.diag:note(text, true)
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

-- The board's pitch and centre from the two feet, for when the game gives no deck pose (ReSkate 2.1.2). The front foot is the one
-- further along the flat travel: in a switch stance the rider faces against it, so the skater's facing would flip the sign. The
-- pitch is the angle of (front foot - back foot) above the plane of the ground, along the flat travel, + nose up like deck_pitch.
-- The joints are read every tick on the board (asking keeps a joint read for 2 s; nil is normal on the first call).
-- Returns pitch (degrees), centre, or nil when a foot is unreadable or the spacing is not that of two feet on a board.
function Glue:feet_pose(velocity, forward)
	local ok_r, right = pcall(reskate.skater.joint, RIGHT_FOOT_JOINT)
	local ok_l, left = pcall(reskate.skater.joint, LEFT_FOOT_JOINT)
	local a = ok_r and right and right.position
	local b = ok_l and left and left.position
	if not a or not b or not finite3(a) or not finite3(b) then
		return nil
	end
	local travel = vcreate(velocity.x, 0, velocity.z)
	if vmagnitude(travel) < TRAVEL_MIN_SPEED then
		travel = vcreate(forward.x, 0, forward.z)
	end
	local flat = S3.normalized(travel, vcreate(0, 0, 1))
	local along = vdot(a - b, flat)
	local spacing = abs(along)
	if spacing < FEET_MIN_SPACING or spacing > FEET_MAX_SPACING then
		return nil
	end
	local d = along > 0 and (a - b) or (b - a)
	local n = S3.normalized(self.ground_normal_raw, UP)
	local in_plane = S3.normalized(flat - n * vdot(flat, n), flat)
	local pitch = math.atan2(vdot(d, n), vdot(d, in_plane)) / S3.degrees
	return pitch, (a + b) * 0.5 - n * FEET_BELOW_CENTRE
end

-- Reads the skater once for this tick into self.snap and self.obs. Never raises.
function Glue:observe(now)
	local obs = self.obs
	obs.valid = false
	obs.skater = false
	obs.foot, obs.riding = false, false
	local s = reskate.skater.get()
	if not s then
		obs.wants_view = false
		return obs
	end
	obs.skater = true
	self.skater_position, self.skater_heading = s.position, s.heading
	obs.ragdoll = false
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
	self.obs_velocity = velocity
	self.tele_body = typeof(t.body) == "vector" and t.body or nil
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
	obs.ragdoll = ragdoll
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

	-- Board pitch against the ground: manual detection. The deck's rotation when the game gives it, else the feet.
	do
		local pitch = self:deck_pitch(motion, forward)
		local source = pitch ~= nil and "deck" or nil
		if pitch == nil and onboard then
			local centre
			pitch, centre = self:feet_pose(velocity, forward)
			if pitch ~= nil then
				source = "feet"
				if not snap.board_valid and finite3(centre) and vmagnitude(centre - position) < 2.5 then
					snap.board_valid = true
					snap.board_position = centre
				end
			end
		end
		if onboard then
			self.pitch_source = source
		end
		self.board_pitch_ok = pitch ~= nil
		if pitch then
			self.board_pitch = pitch
		end
		local prev = self.state
		if prev ~= nil and Subject.is_air_state(prev) and not Subject.is_air_state(state) then
			self.landed_at = now
		end
		local det = self.manual_detector
		local on = det ~= nil and det:update(now, state, onboard, Subject.is_air_state(state), Subject.is_grind_state(state),
			self.board_pitch_ok and self.board_pitch or nil)
		if on ~= self.manual then
			self.manual = on
			if on then self.manuals += 1 end
			self:log_verbose("s3cam " .. (det and det.last_event or "manual") .. string.format(" (board pitch %s, state %d)",
				self.board_pitch_ok and string.format("%+.1f deg", self.board_pitch) or "unreadable", state))
		end
		snap.manual = self.manual
		if det and self.store.options.verbose then
			-- The trick list's names with the state they arrived at: the log shows whether state 101 is the manual.
			det:drain_log(function(text) self:log_verbose(text) end)
		end
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
			-- With the off-board camera on, the riding air camera lets go when the skater is back on the ground on foot (the same
			-- height he left from, no vertical speed), and the off-board camera takes over with its blend.
			if not ended and not onboard and not ragdoll and lasted >= HIPPY_MIN_TIME and self:foot_view_wanted() then
				local calm = snap.ground_clearance <= self.hippy_base + HIPPY_LANDED_RISE and abs(velocity.y) < HIPPY_LANDED_SPEED
				if not calm then
					self.hippy_landed_since = nil
				elseif self.hippy_landed_since == nil then
					self.hippy_landed_since = now
				elseif now - self.hippy_landed_since >= HIPPY_LANDED_FOR then
					ended = "landed on foot"
				end
			end
			if ended then
				self.hippy = false
				self:log_verbose(string.format("s3cam hippy jump over after %.2f s (%s)", lasted, ended))
			end
		elseif not onboard and not ragdoll and state ~= prev and riding_before then
			self.hippy = velocity.y >= HIPPY_LAUNCH_SPEED
			self.hippy_since = now
			self.hippy_base = snap.ground_clearance
			self.hippy_landed_since = nil
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

	-- Paused (pause menu, replay editor): no physics step comes, or, on the board, the root has not moved for a while though it has speed.
	local frozen = onboard and now - self.root_changed_at >= PAUSE_AFTER and vmagnitude(velocity) > PAUSE_BOARD_MIN_SPEED
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
	-- Who wants the view: the riding camera (on the board, in a hippy jump, and in a bail when the game's own camera is chosen off the
	-- board), or the off-board camera (on foot or in a bail, when it is on). With the game's camera chosen, on foot nobody does.
	local foot = not onboard and not self.hippy and self:foot_view_wanted()
	obs.foot = foot
	obs.riding = onboard or self.hippy or (ragdoll and not foot)
	obs.wants_view = (obs.riding or foot) and not paused
	if not self.wants_known or obs.wants_view ~= self.wants then
		self.wants_known = true
		self.wants = obs.wants_view
		self.wants_since = now
	end
	obs.wants_for = now - self.wants_since
	return obs
end

-- ---------------------------------------------------------------- the off-board camera's inputs
-- Whether this camera keeps the view when the skater is off the board: it is on, the option says Dynamic, and offboard.lua loaded.
function Glue:foot_view_wanted()
	return self.off ~= nil and self.store.enabled and self.store.options.offboard_mode == "dynamic"
end

local function joint_position(index)
	local ok, joint = pcall(reskate.skater.joint, index)
	local p = ok and joint and joint.position
	if p and finite3(p) then
		return p
	end
	return nil
end

-- The body for the off-board camera, once a tick (the joints are asked for every tick: a joint is only read for 2 s after the last
-- ask, and the first answer is nil). The centre is 0.6 hips + 0.4 spine; in a bail the hips come from telemetry.body when it is given.
-- Without joints it is the skater's position 0.9 m up. Fills self.body in place.
function Glue:read_body()
	local b = self.body
	local hips, spine, head = joint_position(HIPS_JOINT), joint_position(SPINE_JOINT), joint_position(HEAD_JOINT)
	local pos = self.skater_position
	local ragdoll = self.obs.ragdoll == true
	if ragdoll and self.tele_body and finite3(self.tele_body) then
		hips = self.tele_body
	end
	self.body_joints = (hips and 1 or 0) + (spine and 1 or 0) + (head and 1 or 0)
	local centre
	if hips and vmagnitude(hips - pos) <= BODY_MAX_DISTANCE then
		if spine and vmagnitude(spine - pos) <= BODY_MAX_DISTANCE then
			centre = hips * CENTRE_HIPS_WEIGHT + spine * (1.0 - CENTRE_HIPS_WEIGHT)
		else
			centre = hips + UP * HIPS_TO_CENTRE
		end
	else
		hips = nil
		centre = pos + UP * FALLBACK_CENTRE_UP
	end
	if head and vmagnitude(head - pos) > BODY_MAX_DISTANCE then
		head = nil
	end
	b.centre = centre
	b.hips = hips or (centre - UP * HIPS_TO_CENTRE)
	b.head = head or (centre + UP * 0.5)
	b.velocity = self.obs_velocity
	b.heading = self.skater_heading
	b.ragdoll = self.obs.ragdoll == true
	b.valid = self.obs.skater and self.obs.valid
end

-- The sticks, from the pad (nil when the game is not in front or there is none). The right stick is only read, never hidden from the
-- game: its camera must keep turning with it so walking stays aligned with the screen.
function Glue:read_input(pad_ok, pad)
	local i = self.input
	if pad_ok and pad ~= nil then
		i.look_x, i.look_y = pad.right_x or 0.0, pad.right_y or 0.0
		i.left_x, i.left_y = pad.left_x or 0.0, pad.left_y or 0.0
	else
		i.look_x, i.look_y, i.left_x, i.left_y = 0.0, 0.0, 0.0, 0.0
	end
	i.mouse_dx, i.mouse_dy = 0.0, 0.0 -- reskate.input.flight's mouse look needs the right button and moves the cursor: not used
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
	self.game_pose_fresh = false
	local shown, why = reskate.camera.held()
	if shown or (why ~= nil and why ~= "it does not hold the camera") then
		return -- ours (or waiting for the game): get() would hand back our own view
	end
	local v = reskate.camera.get()
	if not v then
		self.game_pose = nil
		return
	end
	self.game_pose_fresh = true
	self.game_pose = { position = v.position, right = v.right, up = v.up, back = -v.forward }
	local fov = v.fov
	local fov_ok = fov ~= nil and fov - fov == 0 and fov >= BASE_FOV_MIN and fov <= BASE_FOV_MAX
	if fov_ok then
		self.base_fov = fov
	elseif self.base_fov <= 0 then
		self.base_fov = DEFAULT_BASE_FOV -- nothing good read yet: the usual 65, not a zoomed screen's 28
	end
	-- A game camera that is not the usual one (a zoomed screen, far from the skater) is no pose to blend from.
	self.game_pose_ok = fov_ok and vmagnitude(v.position - self.skater_position) <= ONFOOT_MAX_DISTANCE
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

-- A direction turned from `a` toward `b` by the fraction t of the angle between them (a straight lerp of two directions passes
-- through nothing when they are opposite and changes speed on the way).
local function blend_direction(a, b, t)
	local d = clamp(vdot(a, b), -1.0, 1.0)
	local angle = math.acos(d)
	if angle < 1e-4 then
		return b
	end
	local axis = vcross(a, b)
	if vmagnitude(axis) < 1e-4 then
		axis = vcross(a, abs(a.y) < 0.9 and UP or vcreate(1, 0, 0)) -- opposite: any way round will do
	end
	axis = S3.normalized(axis, UP)
	local turned = angle * t
	local c, s = math.cos(turned), math.sin(turned)
	return a * c + vcross(axis, a) * s + axis * (vdot(axis, a) * (1.0 - c))
end

-- ---------------------------------------------------------------- handing the camera back
-- A camera seen from the skater, in the skater's heading frame: metres behind him, above him, to his right (his right is
-- forward x up: facing +Z that is -X), and the height over him of the point the camera looks at (the point on its axis nearest
-- him). Returns back, up, right, look, or nil when he is not in front of the camera or it is too far to be the on-foot one.
local function offset_of(position, forward, skater, heading)
	local f = vcreate(math.sin(heading), 0, math.cos(heading))
	local d = position - skater
	local t = vdot(skater - position, forward)
	if t <= 0.1 or vmagnitude(d) > ONFOOT_MAX_DISTANCE then
		return nil
	end
	return -vdot(d, f), d.y, vdot(d, vcross(f, UP)), d.y + forward.y * t
end

-- While the skater is on foot and the game holds the camera, learns where that camera sits (so a dismount can ease to it). The
-- estimate is smoothed over about a second; nothing is saved.
function Glue:learn_on_foot(now)
	local obs = self.obs
	if not (obs.skater and obs.valid and not self.snap.onboard and not obs.ragdoll and not self.hippy and not self.menu_open
		and not obs.paused and self.game_pose_fresh) then
		return
	end
	local gp = self.game_pose
	local back, up, right, look = offset_of(gp.position, -gp.back, self.skater_position, self.skater_heading)
	if not back then
		return
	end
	local o = self.onfoot
	if not o then
		self.onfoot = { back = back, up = up, right = right, look = look }
	else
		local rate = 1.0 - math.exp(-clamp(now - self.onfoot_at, 0.0, 0.25) / ONFOOT_LEARN_TIME)
		o.back += (back - o.back) * rate
		o.up += (up - o.up) * rate
		o.right += (right - o.right) * rate
		o.look += (look - o.look) * rate
	end
	self.onfoot_at = now
end

-- Where the game's on-foot camera will be, from the skater's position now: what was learned on foot, else the riding camera as it
-- was at the last take, else 2.6 m back and 1.5 m up looking 1 m above him. Returns position, forward.
function Glue:on_foot_target()
	local o = self.onfoot or self.take_offset
	local back, up, right, look = FALLBACK_BACK, FALLBACK_UP, 0.0, FALLBACK_LOOK
	if o then
		back, up, right, look = o.back, o.up, o.right, o.look
	end
	local p, h = self.skater_position, self.skater_heading
	local f = vcreate(math.sin(h), 0, math.cos(h))
	local pos = p - f * back + UP * up + vcross(f, UP) * right
	return pos, S3.normalized(p + UP * look - pos, f)
end

-- Starts the ease out (the rider stepped off): from what is on screen now, over release_blend_time.
function Glue:begin_handback(now)
	local ls = self.last_shown
	self.handback = { started = now, duration = self.store.options.release_blend_time, pos = ls.pos, forward = ls.forward, up = ls.up, fov = ls.fov }
end

-- The rider is back on the board during the ease: carry on running. The camera has stood still meanwhile, so it starts afresh
-- and its view is crossfaded from what is on screen (the take's own crossfade), not cut.
function Glue:cancel_handback(now)
	self.handback = nil
	if self.obs.foot then
		-- The off-board camera is wanted again (switched back on, or the Dynamic mode chosen again): it starts from what is on screen.
		self:begin_foot(now, self.last_shown)
	else
		self:begin_ride_from_shown(now)
	end
end

-- The riding camera takes over from what is on screen (a remount, or the end of a hand-back): the camera has stood still meanwhile,
-- so it starts afresh and its view is crossfaded from the shown pose over the Board / foot transition time (the take's own crossfade),
-- not cut.
function Glue:begin_ride_from_shown(now)
	local ls = self.last_shown
	if not (ls.pos and ls.forward and ls.up) then
		-- Nothing was shown yet: nothing to blend from. The riding camera starts where it is (the snap guard has nothing to compare to).
		self.game_pose, self.game_fov, self.blend_time = nil, nil, nil
		self.source, self.blend, self.last_pose = "ride", 1.0, now
		self.cam:cut()
		self.guard:cut()
		return
	end
	local right = S3.normalized(vcross(ls.forward, ls.up), vcross(ls.forward, UP))
	self.game_pose = { position = ls.pos, right = right, up = ls.up, back = -ls.forward }
	self.game_fov = ls.fov
	self.blend_time = self.off and self.store.options.offboard.transition_time or nil
	self.source = "ride"
	self.blend = 0.0
	self.last_pose = now
	self.cam:cut()
end

-- ---------------------------------------------------------------- the off-board camera
-- Starts it from `from` (the pose on screen now, or the game's camera at a take): it begins exactly there and eases into its
-- framing, so a dismount, a landing or a take on foot shows no jump.
function Glue:begin_foot(now, from)
	local fp = self.from_pose
	if from and from.pos and from.forward and from.up then
		fp.pos, fp.forward, fp.up, fp.fov = from.pos, from.forward, from.up, from.fov
	else
		fp.pos, fp.forward = self:on_foot_target()
		fp.up, fp.fov = UP, nil
	end
	if not fp.fov or fp.fov <= 0 then
		fp.fov = self.base_fov > 0 and self.base_fov or nil
	end
	self.source = "foot"
	self.last_pose = now
	self.blend_time = nil
	self:read_body()
	self.off.s = self.store.options.offboard
	self.off.base_fov = self.base_fov
	self.off.side_sign = self:side_sign()
	self.off:start(fp, self.body)
	self:log_verbose(string.format("s3cam off-board camera on (state %s%s)", tostring(self.state), self.obs.ragdoll and ", ragdoll" or ""))
end

-- The riding shoulder side decides which way the off-board offset points (the shoulder-side bind flips it): Manual uses its side,
-- Auto the stance's toe side, Off leaves the offset as set (positive: right).
function Glue:side_sign()
	local sh = self.store.settings.shoulder
	if sh.mode == Settings.ShoulderSide.Manual then
		return sh.side < 0 and -1.0 or 1.0
	elseif sh.mode == Settings.ShoulderSide.Auto then
		return (sh.goofy ~= self.snap.switch_stance) and -1.0 or 1.0
	end
	return 1.0
end

-- Picks who draws the view this tick and starts the hand-over when that changes.
function Glue:choose_source(now)
	local want = self.obs.foot and "foot" or "ride"
	if want == self.source then
		return
	end
	local transition = self.store.options.offboard.transition_time
	self:set_path_hint(want == "foot" and "board->foot" or "foot->board", now, transition + PATH_HINT_EXTRA)
	if want == "foot" then
		self:begin_foot(now, self.last_shown)
	else
		self:begin_ride_from_shown(now)
	end
end

-- One off-board camera update. Returns pos, forward, up, fov or nil.
function Glue:foot_pose(now, pad_ok, pad)
	local st = self.stats
	local dt = clamp(now - self.last_pose, 0.0, MAX_DT)
	self.last_pose = now
	st.frames += 1
	self.total_frames += 1
	self:apply_settings()
	local off = self.off
	off.s = self.store.options.offboard
	off.base_fov = self.base_fov
	off.side_sign = self:side_sign()
	self:read_body()
	self:read_input(pad_ok, pad)
	local clock = os.clock()
	local ok, pos, forward, up, fov = pcall(off.update, off, dt, self.input, self.body, self.query)
	local ms = (os.clock() - clock) * 1000.0
	st.update_ms += ms
	st.update_ms_max = max(st.update_ms_max, ms)
	self.total_update_ms += ms
	if not ok then
		self.errors += 1
		st.failed += 1
		if now - self.error_logged_at > 5.0 then
			self.error_logged_at = now
			reskate.log("dyncam: the off-board camera raised an error: " .. tostring(pos), "error")
		end
		return nil
	end
	if not pos then
		st.failed += 1
		return nil
	end
	self.pulled = off.pulled == true
	return pos, forward, up, fov
end

-- One tick of the ease. Ends with the release.
function Glue:handback_tick(now)
	local hb = self.handback
	local f = hb.duration > 0 and clamp((now - hb.started) / hb.duration, 0.0, 1.0) or 1.0
	local mix = S3.sine_blend(f)
	local to_pos, to_forward = self:on_foot_target()
	local pos = S3.lerp(hb.pos, to_pos, mix)
	local forward = S3.normalized(S3.lerp(hb.forward, to_forward, mix), to_forward)
	local right = S3.normalized(vcross(forward, S3.lerp(hb.up, UP, mix)), vcross(forward, UP))
	local up = vcross(right, forward)
	local fov = hb.fov
	if fov and self.base_fov > 0 then
		fov = fov + (self.base_fov - fov) * mix
	end
	self.pulled = false
	local ok, why = self:show(pos, forward, up, fov, "handback")
	if not ok then
		self:release("camera refused: " .. tostring(why))
		self.retry_after = now + RETRY_AFTER
	elseif f >= 1.0 then
		self:release(string.format("on foot, eased %.2f s", hb.duration))
	end
end

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
	self.pulled = (d.collision_pull or 0.0) > 0.001
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
	local blend_time = self.blend_time or opts.take_blend_time -- from the off-board camera: the Board / foot transition time
	local step = blend_time > 0 and dt / max(blend_time, 1e-3) or 1.0
	self.blend = min(1.0, self.blend + step)
	local mix = gp and S3.sine_blend(self.blend) or 1.0
	local right, up, back, pos = frame.right, frame.up, frame.back, frame.pos
	if mix < 1.0 then
		-- The view direction (back) is blended first and the frame is built round it. Blending right and up and rebuilding the back
		-- from them threw the pitch away whenever the start pose had one with an upright "up" (the off-board camera's frame is like
		-- that): the first riding frame after a remount turned 22 to 26 degrees at once.
		back = blend_direction(gp.back, back, mix)
		up = S3.lerp(gp.up, up, mix)
		pos = S3.lerp(gp.position, pos, mix)
		right = S3.normalized(vcross(up, back), frame.right)
		up = vcross(back, right)
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
	if mix < 1.0 and self.game_fov and self.game_fov > 0 then
		-- Blending in from the off-board camera: its FOV eases to this camera's (or the game's own) instead of jumping.
		local target = fov or (self.base_fov > 0 and self.base_fov or frame.fov_deg)
		fov = clamp(self.game_fov + (target - self.game_fov) * mix, PLAUSIBLE_FOV_MIN, PLAUSIBLE_FOV_MAX)
	end
	if self.blend >= 1.0 then
		self.blend_time, self.game_fov = nil, nil
	end
	return pos, -back, up, fov
end

-- Names the path drawing for the snap counts: a transition's name while it lasts, else the plain path.
function Glue:set_path_hint(name, now, seconds)
	self.path_hint, self.path_hint_until = name, now + seconds
end

-- Every pose goes through here on its way to the screen (the riding camera, the off-board one, the hand-back). The snap guard looks
-- at it first: a jump from the last pose, whatever path made it, is eased instead of shown. `path` names who is drawing.
function Glue:show(pos, forward, up, fov, path)
	if self.snap_guard_on then
		local now = now_s()
		local name = path or "riding"
		if self.path_hint and now <= self.path_hint_until and name ~= "handback" then
			name = self.path_hint
		end
		local cause, amount
		pos, forward, up, fov, cause, amount = self.guard:filter(now, pos, forward, up, fov, self.snap.position, self.pulled)
		if cause then
			self.snaps[cause] += 1
			self.snaps_total += 1
			self.snaps_by_path[name] = (self.snaps_by_path[name] or 0) + 1
			self:log_verbose(string.format("s3cam snap smoothed: %s %.2f %s in %s", cause, amount, cause == "position" and "m" or "deg", name))
		end
	end
	local ok, shown, why = pcall(reskate.camera.set, pos, forward, up, fov)
	if not ok then
		self.errors += 1
		return false, tostring(shown)
	end
	if shown then
		local ls = self.last_shown
		ls.pos, ls.forward, ls.up, ls.fov = pos, forward, up, fov
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
	self.handback = nil
	self.pitch_source_noted = false
	self.blend_time, self.game_fov = nil, nil
	self.source = self.obs.foot and "foot" or "ride"
	-- The game's riding camera as seen from the skater: the fallback for where its on-foot camera will be when he steps off.
	local gp = self.game_pose
	if gp and self.game_pose_fresh and not self.obs.foot then
		local back, up, right, look = offset_of(gp.position, -gp.back, self.skater_position, self.skater_heading)
		if back then
			self.take_offset = { back = back, up = up, right = right, look = look }
		end
	end
	self.cam:cut()
	self.guard:cut()
	-- A retake soon after a release (a menu, a pause) while the game's camera does not look like a game camera (a zoomed screen, far
	-- away): carry on from the pose we showed last, as a remount does, instead of blending from something odd.
	local ls = self.last_shown
	local from_shown = self.released_at ~= nil and now - self.released_at < SHORT_RELEASE and ls.pos ~= nil and ls.forward ~= nil
		and ls.up ~= nil and not (gp and self.game_pose_fresh and self.game_pose_ok)
	if from_shown then
		self.game_pose_fresh = true
		gp = { position = ls.pos, right = S3.normalized(vcross(ls.forward, ls.up), vcross(ls.forward, UP)), up = ls.up, back = -ls.forward }
		self.game_pose = gp
		if self.source ~= "foot" then
			self.game_fov = ls.fov
		end
	end
	self:set_path_hint("retake", now, self.store.options.take_blend_time + PATH_HINT_EXTRA)
	if self.source == "foot" then
		-- Taken on foot (the plugin started there, or a menu closed): the off-board camera starts from the game's own camera.
		local from = nil
		if from_shown then
			from = ls
		elseif gp and self.game_pose_fresh then
			local fp = self.from_pose
			fp.pos, fp.forward, fp.up, fp.fov = gp.position, -gp.back, gp.up, self.base_fov > 0 and self.base_fov or nil
			from = fp
		end
		self:begin_foot(now, from)
	end
	if self.diag and self.store.options.verbose then
		self.diag:begin_run()
	end
	local s = self.store.settings
	self:note(string.format("on: angle %s, shake %s, fov override %.0f, shot fov %s, base fov %.1f%s",
		s.angle == Settings.CameraAngle.High and "high" or "low", s.shake_enabled and "on" or "off", s.fov_override_deg,
		self.store.options.shot_fov and "on" or "off", self.base_fov, self.game_pose and "" or " (the game's camera was not readable)"))
end

-- "N snaps smoothed", with what made them and which path was drawing when there were any (the next log shows what still jumps).
function Glue:snaps_text()
	local text = string.format("%d snaps smoothed", self.snaps_total)
	if self.snaps_total > 0 then
		local paths = {}
		for name, n in self.snaps_by_path do
			paths[#paths + 1] = string.format("%s %d", name, n)
		end
		table.sort(paths)
		text ..= string.format(" (position %d, turn %d, fov %d; %s)", self.snaps.position, self.snaps.turn, self.snaps.fov, table.concat(paths, ", "))
	end
	return text
end

function Glue:release(reason)
	self.handback = nil
	self.guard:cut()
	self.released_at = now_s()
	if self.running then
		self.running = false
		if self.landing_pending and self.store.options.verbose then
			self:log_landing()
		end
		self.landing_pending = false
		self:note(string.format("off (%s): %.1f s, %d frames, %d held, update %.3f ms mean, %d landings so far, %d manual%s, %s", reason or "stopped",
			now_s() - self.started, self.total_frames, self.total_held,
			self.total_frames > 0 and self.total_update_ms / self.total_frames or 0.0, self.landings, self.manuals,
			self.manuals == 1 and "" or "s", self:snaps_text()))
		if self.diag then
			self.diag:end_run(reason)
		end
	end
	pcall(reskate.camera.release)
	self.frame = nil
	self.source, self.blend_time, self.game_fov = nil, nil, nil
end

-- Take / release / run, once a tick.
function Glue:tick(dt_ms)
	local now = now_s()
	self.rays_tick = 0
	self.capped_this_tick = false
	local store = self.store

	-- The pad: R3 switches Low / High on the board (the DLL follows the game's camera height option; the plugin reads the stick click
	-- itself), and on foot it swings the off-board camera behind the skater. The sticks steer the off-board camera.
	local pad_ok, pad = pcall(reskate.input.gamepad)
	local r3 = pad_ok and pad ~= nil and pad.buttons ~= nil and pad.buttons.right_stick == true
	if r3 and not self.pad_r3 and store.enabled and not self.menu_open then
		if self.running and self.source == "foot" then
			self.off:recentre_now()
			self:log_verbose("s3cam R3: off-board camera swings behind")
		elseif store.options.follow_game_height and (self.snap.onboard or not self.snap.valid) then
			store:toggle_height()
			self:note("R3: Low / High switched")
		end
	end
	self.pad_r3 = r3

	-- Switched off: a riding camera is handed back at once; the off-board one eases out like a step off the board.
	local enabled = store.enabled
	if not enabled then
		local eases = self.running and self.source == "foot" and (self.handback ~= nil
			or (store.options.release_blend_time > 0 and self.last_shown.pos ~= nil))
		if not eases then
			if self.running then
				self:release("switched off")
			end
			self:read_game_camera()
			return
		end
	end

	local obs = self:observe(now)
	local ok_menu, game_menu = pcall(reskate.menu.game)
	self.menu_open = ok_menu and game_menu ~= nil and game_menu.open == true

	if self.running then
		-- Screens of the game's own, no skater, a pause: hand back at once. Off the board with the game's camera chosen: ease to where
		-- that camera will be (release_blend_time; 0 hands back at once), and if he is back on the board meanwhile, carry on. With the
		-- off-board camera on, nothing is handed back when he steps off: the view changes hands by blending (choose_source).
		local reason
		if not obs.skater then
			reason = "no skater"
		elseif self.menu_open then
			reason = "a game menu is open"
		elseif obs.valid and obs.paused then
			reason = "the game is paused"
		elseif not enabled and not self.handback then
			self:begin_handback(now)
		elseif not enabled and obs.valid and obs.riding then
			reason = "switched off"
		elseif enabled and obs.valid and self.handback and obs.wants_view then
			self:cancel_handback(now)
		elseif obs.valid and not self.handback and not obs.wants_view and obs.wants_for >= RELEASE_AFTER then
			if store.options.release_blend_time > 0 and self.last_shown.pos then
				self:begin_handback(now)
			else
				reason = "on foot"
			end
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
		if self.handback then
			self:handback_tick(now)
			if not self.running then
				self:read_game_camera()
			end
			return
		end
		if not obs.valid then
			self.stats.held += 1
			self.total_held += 1
			return -- the skater is unreadable: the last view stays
		end
		self:choose_source(now)
		if self.source ~= "foot" and self:foot_view_wanted() then
			self:read_body() -- keeps the joints asked for (a read lasts 2 s), so the first frame on foot is not an empty one
		end
		local pos, forward, up, fov
		if self.source == "foot" then
			pos, forward, up, fov = self:foot_pose(now, pad_ok, pad)
		else
			pos, forward, up, fov = self:pose(now)
		end
		if pos then
			local ok, why2 = self:show(pos, forward, up, fov, self.source == "foot" and "offboard" or "riding")
			if not ok then
				self:release("camera refused: " .. tostring(why2))
				self.retry_after = now + RETRY_AFTER
			end
		end
		self:after_tick(now)
		return
	end

	-- Not running: keep the game's camera in mind (and, on foot, learn where it sits), and take the view when the rider has wanted
	-- it long enough.
	self:read_game_camera()
	self:learn_on_foot(now)
	if self.capped_this_tick then
		self.rays_capped += 1
	end
	if now < self.retry_after or self.menu_open or not obs.valid or not obs.wants_view or obs.wants_for < TAKE_AFTER then
		return
	end
	self:begin_run(now)
	local pos, forward, up, fov
	if self.source == "foot" then
		pos, forward, up, fov = self:foot_pose(now, pad_ok, pad)
	else
		pos, forward, up, fov = self:pose(now)
	end
	if not pos then
		self.running = false
		self.retry_after = now + RETRY_AFTER
		return
	end
	local ok, why = self:show(pos, forward, up, fov, "retake")
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
	if not self.pitch_source_noted and now - self.started >= 1.0 then
		-- Which signal the manual detection runs on, once a run (the first second is the joints' first, empty reads).
		self.pitch_source_noted = true
		local source = self.pitch_source
		local det = self.manual_detector
		self:note("manual detection: " .. (det and det.source or "none") .. "; board pitch "
			.. (source == "deck" and "from the deck" or (source == "feet" and "from the feet" or "unreadable")))
	end
	local opts = self.store.options
	if opts.verbose and self.diag and self.frame and self.snap.valid and self.source == "ride" then
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
	if self.store.options.verbose and self.diag and self.source == "foot" and self.off then
		-- On foot: the off-board camera's line, with how far the view is from the game's hidden camera (walking direction estimate).
		self.diag:note(string.format("s3cam t=%.0f %d frames, %d failed | update %.3f ms mean, %.3f max, %d rays, %d ticks over the ray budget | "
			.. "state %s joints %d/3 | %s", now - self.started, st.frames, st.failed, st.frames > 0 and st.update_ms / st.frames or 0.0,
			st.update_ms_max, self.rays_total - st.rays_at, self.rays_capped, tostring(self.state), self.body_joints, self.off:summary()))
	elseif self.store.options.verbose and self.diag and f then
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
	elseif self:foot_view_wanted() then
		return "Waiting"
	end
	return "Disabled off board"
end

function Glue:dump()
	local s, o = self.store.settings, self.store.options
	local text = string.format("Dynamic Camera %s | angle %s | shake %s | fov override %.0f | shot fov %s | log %s | rays/tick cap %d, ticks over it %d",
		self.running and "owns the view" or "idle", s.angle == Settings.CameraAngle.High and "high" or "low", s.shake_enabled and "on" or "off",
		s.fov_override_deg, o.shot_fov and "on" or "off", o.verbose and "on" or "off", RAY_CAP, self.rays_capped)
	if self.running and self.source == "foot" and self.off then
		text ..= "\n" .. self.off:summary()
	elseif self.running and self.frame then
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
