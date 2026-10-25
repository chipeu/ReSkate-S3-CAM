-- Port of Engine/Game/Camera/s3_camera.h (class CameraMan and its helpers): turns a stream of skater snapshots into a camera
-- pose. FullS3 only: NativePlus needs the game's own camera pose, which a plugin cannot drive, so a NativePlus preset runs
-- as FullS3 (the setting is kept, the native layers are not ported).
--
-- Order of operations per FIXED 1/60 s step (as the C++):
--   prepare (air / landing, then incline) -> graph select -> shot blend -> board anchoring -> fov extras -> shoulder side ->
--   rig -> swing / horizontal follow / trick yaw / ramp slide -> elevation, distance -> orbit camera -> look target ->
--   shoulder -> fixed distance -> motion limit -> collision -> orientation (pan / tilt) -> keep-in-frame -> shake -> write.
-- update() takes the real frame dt, runs as many fixed steps as the accumulator holds (the subject is interpolated between
-- the previous and the current snapshot across them) and publishes the pose interpolated between the last two steps.
--
-- Conventions: world is Y up. Heading 0 looks down +Z and grows toward -X (heading = atan2(-x, z)). Frame rows are right,
-- up, back, position with right x up = +back, so the camera looks along -back. Roll > 0 turns right toward up.
--
-- API (PORT_PLAN.md):
--   local cam = Camera.new()
--   cam:set_settings(settings)    settings.lua's CameraSettings table; false (old settings kept) when not valid. The table is
--                                 copied: later changes to the caller's table do not reach the camera.
--   cam:update(dt, snapshot, query, extras) -> frame
--        snapshot: the SubjectSnapshot table of subject.lua (read, never kept)
--        query(from, to) -> hit point (vector) or nil [, normal]   the world ray; the n-th ray of a step is the n-th the C++ casts
--        extras: { base_fov_deg = number or 0, aspect = number or nil }  (FrameExtras; native is not ported)
--        frame (REUSED every call, read it before the next update):
--          { valid, pos, right, up, back, fov_deg, shot (ShotId), debug = { ...FrameDebug field names... } }
--   cam:cut()                     take ownership / teleport: the next update snaps
--   cam.frame                     the last frame
--
-- Performance: no table is created in the step paths (state lives in preallocated tables, vectors are values), and no closure
-- is made per step: the C++ lambdas are local functions that take their context as arguments.

local S3 = require("s3math")
local Subject = require("subject")
local Shots = require("shots")
local Graph = require("graph")
local Air = require("air")
local Rig = require("rig")
local Shake = require("shake")
local Traj = require("trajectory")
local T = require("tracker")
local Settings = require("settings")

local Camera = {}
Camera.__index = Camera

local vcreate = vector.create
local vmag = vector.magnitude
local vdot = vector.dot
local vcross = vector.cross
local abs, sqrt, sin, cos, tan, asin, atan2, exp, floor = math.abs, math.sqrt, math.sin, math.cos, math.tan, math.asin, math.atan2, math.exp, math.floor
local max, min = math.max, math.min

local ZERO = S3.ZERO
local UP = vcreate(0, 1, 0)
local FWD = vcreate(0, 0, 1)
local PI = S3.pi
local DEG = S3.degrees
-- The C++ step is a float (0.016666668): timers that add it up cross their thresholds on the same step only with that value.
local fixed_step = (string.unpack("f", string.pack("f", 1 / 60)))
local fixed_hz = S3.fixed_hz
local wrap_angle = S3.wrap_angle
local blend_angle = S3.blend_angle
local sine_blend = S3.sine_blend
local clamp01 = S3.clamp01
local heading_of = S3.heading_of
local normalized = S3.normalized

local ShotId = Graph.ShotId
local Low, High = Shots.Low, Shots.High
local FIXED = Settings.DistanceMode.Fixed
local MANUAL_SPEED = Settings.ManualDistanceMode.Speed
local SHOULDER_MANUAL, SHOULDER_AUTO = Settings.ShoulderSide.Manual, Settings.ShoulderSide.Auto
local closeup_min_distance = Settings.closeup_min_distance
local manual_full_speed = Settings.manual_full_speed
local PS_CROUCH = Subject.physics_state.crouch
local is_air_state, is_grind_state = Subject.is_air_state, Subject.is_grind_state

-- std::clamp semantics (no error when lo > hi, unlike math.clamp).
local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif hi < v then
		return hi
	end
	return v
end

local function isfinite(x)
	return x - x == 0
end

local function finite3(v)
	local s = v.x + v.y + v.z
	return s - s == 0
end

-- Rounds to a 32-bit float (the C++ accumulator's precision).
local pack, unpack = string.pack, string.unpack
local function f32(x)
	return (unpack("f", pack("f", x)))
end

local function lerp_f(a, b, t)
	return a + (b - a) * t
end

-- ---------------------------------------------------------------- constants (the C++ static constexpr members)

local personal_margin = 0.02
local ramp_root_distance, ramp_board_distance = 0.9, 0.7
local ramp_space_time = 0.08
local personal_root_distance, personal_board_distance = 0.8, 0.6
local min_pull_in_time, air_pull_in_time, min_pull_out_time = 0.12, 0.25, 0.15
local pull_max_speed, fast_pull_max_speed = 5.0, 7.0
local ramp_pull_max_speed = 3.0
local fast_pull_time, fast_pull_release, penetration_skin = 0.012, 0.05, 0.10
local ray_budget = 12
local coll_lookahead_time, coll_lookahead_max = 0.08, 1.0
local coll_hold_time, coll_hold_hysteresis = 0.3, 0.05
local trick_side_period, trick_side_dwell, trick_side_lookahead = 0.2, 0.5, 0.3
local thin_near_end = 0.5
local whisker_skin = 0.05
local wall_lift_time = 0.2
local wall_lift_gain, wall_lift_max = 2.0, 1.0
local ground_lift_max = 0.6
local lip_probe_reach, lip_probe_rise, lip_probe_skin, lip_top_margin = 0.3, 0.1, 0.05, 0.1
local rel_max_speed, rel_max_orbit, rel_accel = 5.0, 9.5, 110.0
local trick_yaw_speed = 6.0
local min_ease_time = 0.15
local keep_response_time = 0.08
local keep_guard_rate, keep_guard_accel = 180.0, 1800.0
local big_air_from, big_air_full = 0.75, 2.0
local big_air_head = 0.8
local big_air_frame_share = 0.6
local big_air_room_rate = 2.5
local big_air_room_cap = 8.0
local fixed_ease_time = 0.3
local limits_rate = 6.0
local rider_hold_rate = 2.0
local rest_fov_max_speed = 4.0
local rest_fov_ease_time = 0.5
local keep_in_time = 0.08
local keep_ramp_normal_y = 0.77
local follow_min_speed = 1.0
local follow_slowest_time, follow_fastest_time = 0.45, 0.1
local follow_slowest_turn, follow_fastest_turn = 90.0, 240.0
local follow_ease_time = 0.4
local aim_max_yaw_rate, aim_max_pitch_rate = 360.0, 240.0
local aim_fast_acceleration = 4800.0
local pan_lock_min_span = 0.8
local pan_lock_rate = 30.0
local ramp_side_margin = 1.5
local ramp_side_clearance = 1.0
local ramp_side_hold_time = 0.3
local ramp_side_below = 0.3
local ramp_side_max_degrees = 120.0
local ramp_side_grow_rate, ramp_side_release_rate, ramp_side_accel = 240.0, 90.0, 1200.0
local ramp_side_probe_step = 15.0
local ramp_lead_time = 0.25
local ramp_probe_period = 0.1
local ramp_ray_budget = 8
local ramp_turn_speed = 1.0
local ramp_air_fall_speed, ramp_air_flat_speed = 1.0, 1.5
local swing_slowest_turn, swing_fastest_turn = 180.0, 300.0
local swing_blocked_turn = 90.0
local coll_blocked_threshold = 0.05
local swing_orbit_speed, ramp_side_orbit_speed, orbit_speed_total = 6.0, 3.5, 6.5
local swing_acceleration = 1200.0
local swing_done_degrees, swing_flip_guard_degrees = 1.5, 150.0
local swing_done_rate = 10.0
local launch_above_ground = 0.05
local wide_whisker, wide_depth = 0.35, 0.75
local fast_release_speed, fast_release_floor = 3.0, 0.25
local transition_on_degrees, transition_off_degrees = 40.0, 25.0
local transition_off_time, transition_ease_time = 0.35, 0.3
local transition_path_degrees, ramp_path_min_speed = 30.0, 1.0
local hill_rise_min = 5.0
local downhill_lift_margin, downhill_lift_max, downhill_lift_time = 5.0, 60.0, 0.3
local downhill_lift_after, downhill_side_cap = 0.5, 60.0
local transition_lag_cut = 0.8
local manual_grind_min_height = 0.3
local floor_in_time = 0.3
local floor_out_share = 0.55
local height_ease_time = 0.2
local board_anchor_height = 0.3
local board_smooth_time = 0.12

-- Automatic collision: the stock values (the player's own are only used with automatic off).
local AUTO_COLLISION = Settings.collision()

-- The built-in shots' distances the camera reads over and over (the table never changes): the big-air shot's, and the chase
-- shots' slow and fast ones, per angle.
local air_big_distance = {
	[Low] = Graph.resolve_shot(ShotId.AirBig, Low, 0.0).distance,
	[High] = Graph.resolve_shot(ShotId.AirBig, High, 0.0).distance,
}
local chase_slow = { [Low] = Graph.resolve_shot(ShotId.Chase, Low, 0.0).distance, [High] = Graph.resolve_shot(ShotId.Chase, High, 0.0).distance }
local chase_fast = { [Low] = Graph.resolve_shot(ShotId.Chase, Low, 1.0).distance, [High] = Graph.resolve_shot(ShotId.Chase, High, 1.0).distance }
local chase_lens_of = { [Low] = Graph.resolve_shot(ShotId.Chase, Low, 0.0).lens_length, [High] = Graph.resolve_shot(ShotId.Chase, High, 0.0).lens_length }
local lookup_shots = Graph.lookup_shots
local blend_shots = Graph.blend_shots

-- A prediction that never landed (TrajectoryPrediction{}); never modified.
local EMPTY_PREDICTION = {
	status = "Invalid",
	predicted_air_time = 0.0,
	predicted_max_height = 0.0,
	predicted_landing_height = 0.0,
	landing_position = ZERO,
}

-- ---------------------------------------------------------------- free helpers

-- manager_frame.rs lens_field_of_view: the angle subtended by a 35 mm frame at `lens` mm, in degrees, scaled by
-- 1 / sqrt(aspect + 1). Non-finite or non-positive input gives 0.
local function lens_field_of_view_degrees(lens_length, aspect)
	if not isfinite(lens_length) or not isfinite(aspect) or not (lens_length > 0.0) or not (aspect > 0.0) then
		return 0.0
	end
	local degrees_full = math.atan(35.0 / (lens_length * 2.0)) * (2.0 * 180.0 / PI)
	return sqrt(degrees_full * degrees_full / (aspect + 1.0))
end
Camera.lens_field_of_view_degrees = lens_field_of_view_degrees

-- Rows for a camera looking along (yaw, pitch) with roll about the view axis. Positive pitch looks up.
local function basis_from_angles(yaw, pitch, roll)
	local limit = 89.0 * DEG
	local p = clamp(pitch, -limit, limit)
	local cp = cos(p)
	local back = -vcreate(-sin(yaw) * cp, sin(p), cos(yaw) * cp)
	local right = normalized(vcross(UP, back), vcreate(1, 0, 0))
	local up = vcross(back, right)
	local c, s = cos(roll), sin(roll)
	return right * c + up * s, up * c - right * s, back
end

-- Per-step share of the gap an exponential filter with `time_constant` closes (0 = take it all).
local function ease_rate(time_constant, step_time)
	if time_constant > 0.0 then
		return 1.0 - exp(-step_time / max(time_constant, 1e-6))
	end
	return 1.0
end

local function ease_to(value, target, time_constant, step_time)
	return value + (target - value) * ease_rate(time_constant, step_time)
end

-- Two first-order filters in a row, each with half the time constant (a step in the target starts and ends gently). Works for
-- numbers and for vectors. Returns the new stage and the new value.
local function ease2(stage, value, target, time_constant, step_time)
	local rate = ease_rate(0.5 * time_constant, step_time)
	stage = stage + (target - stage) * rate
	value = value + (stage - value) * rate
	return stage, value
end

-- Exact step of a critically damped spring toward `target` that settles (about 90%) in `time` seconds. Returns value, velocity.
local function critically_damped(value, velocity, target, time, dt)
	local omega = 3.9 / max(time, 1e-3)
	local offset = value - target
	local push = velocity + omega * offset
	local decay = exp(-omega * dt)
	velocity = (velocity - omega * push * dt) * decay
	return target + (offset + push * dt) * decay, velocity
end

-- HeldSpring: a value that follows its goal through a critically damped spring and does not let go of a goal that has just
-- dropped: the goal falls only after the target has stayed lower (by more than `hysteresis`) for `hold_time`.
local function held_new()
	return { goal = 0.0, value = 0.0, velocity = 0.0, clear_time = 0.0 }
end

local function held_reset(h, v)
	v = v or 0.0
	h.goal = v
	h.value = v
	h.velocity = 0.0
	h.clear_time = 0.0
end

local function held_update(h, target, in_time, out_time, hold_time, hysteresis, dt)
	if target >= h.goal then
		h.goal = target
		h.clear_time = 0.0
	elseif target < h.goal - hysteresis then
		h.clear_time = h.clear_time + dt
		if h.clear_time >= hold_time then
			h.goal = target
			h.clear_time = 0.0
		end
	else
		h.clear_time = 0.0
	end
	h.value, h.velocity = critically_damped(h.value, h.velocity, h.goal, h.goal > h.value and in_time or out_time, dt)
	return h.value
end

-- MotionLimiter: a camera position held to a speed and an acceleration relative to a moving point (the skater's root).
local function limiter_new()
	return { rel = ZERO, target = ZERO, velocity = ZERO, valid = false, engaged = false }
end

local function limiter_update(l, camera, root, snap, engage, max_speed, accel, dt, max_orbit)
	max_orbit = max(max_orbit, max_speed)
	local wanted = camera - root
	if snap or not l.valid then
		l.rel = wanted
		l.target = wanted
		l.velocity = ZERO
		l.valid = true
		l.engaged = false
		return camera
	end
	local target_velocity = (wanted - l.target) * (1.0 / dt)
	l.target = wanted
	l.engaged = l.engaged or engage
	local err = wanted - l.rel
	local distance = vmag(err)
	if not l.engaged then
		l.rel = wanted
		l.velocity = target_velocity
		return camera
	end
	-- The catch-up speed: what still lets it stop at the target (sqrt(2 a d)), and never more than half the gap a step.
	local catch_up = ZERO
	if distance > 1e-5 then
		catch_up = err * (min(max_orbit, sqrt(2.0 * accel * distance), 0.5 * distance / dt) / distance)
	end
	local relative_velocity = l.velocity - target_velocity -- the camera's velocity in the target's frame
	local change = catch_up - relative_velocity
	local change_length = vmag(change)
	local room = accel * dt
	if change_length > room then
		change = change * (room / change_length)
	end
	relative_velocity = relative_velocity + change
	local velocity = target_velocity + relative_velocity
	-- Round the point (horizontal, across the line to it) up to max_orbit; the rest (in / out, up / down) up to max_speed.
	local rel = l.rel
	local out_dir = normalized(vcreate(rel.x, 0.0, rel.z), FWD)
	local radial = vdot(velocity, out_dir)
	local around = vcreate(velocity.x, 0.0, velocity.z) - out_dir * radial
	local in_up = out_dir * radial + vcreate(0.0, velocity.y, 0.0)
	local around_speed, in_up_speed = vmag(around), vmag(in_up)
	if around_speed > max_orbit then
		around = around * (max_orbit / around_speed)
	end
	if in_up_speed > max_speed then
		in_up = in_up * (max_speed / in_up_speed)
	end
	velocity = around + in_up
	l.velocity = velocity
	l.rel = rel + velocity * dt
	if not engage and distance < 0.02 and vmag(relative_velocity) < 0.3 then
		l.engaged = false -- caught up
	end
	return root + l.rel
end

-- A shot copied field by field into an existing one (no allocation).
local function copy_shot(dst, src)
	dst.distance = src.distance
	dst.lens_length = src.lens_length
	local a, b = dst.smoothing, src.smoothing
	for i = 1, 4 do
		a[i] = b[i]
	end
	a, b = dst.reference_weights, src.reference_weights
	for i = 1, 10 do
		a[i] = b[i]
	end
	dst.board_offset = src.board_offset
	dst.position_heading = src.position_heading
	dst.position_elevation = src.position_elevation
	a, b = dst.framing, src.framing
	for i = 1, 3 do
		a[i] = b[i]
	end
	dst.follow_subject_in_air = src.follow_subject_in_air
	dst.mirror_for_stance = src.mirror_for_stance
	dst.snap_to_reference_point = src.snap_to_reference_point
	dst.use_previous_shot = src.use_previous_shot
	dst.use_drop_predictor = src.use_drop_predictor
	dst.use_free_camera_stick = src.use_free_camera_stick
	dst.avoidance_override = src.avoidance_override
end

local function copy_snapshot(dst, src)
	dst.time = src.time
	dst.position = src.position
	dst.forward = src.forward
	dst.velocity = src.velocity
	dst.physics_state = src.physics_state
	dst.onboard = src.onboard
	dst.bailing = src.bailing
	dst.manual = src.manual
	dst.grind_side = src.grind_side
	dst.switch_stance = src.switch_stance
	dst.board_position = src.board_position
	dst.board_valid = src.board_valid
	dst.ground_normal = src.ground_normal
	dst.ground_clearance = src.ground_clearance
	dst.valid = src.valid
end

local function new_step_out()
	return {
		pos = ZERO,
		yaw = 0.0,
		pitch = 0.0,
		roll = 0.0,
		localpos = ZERO,
		anchor = ZERO,
		skater_anchor = ZERO,
		subject = ZERO,
		fov_extra = 0.0,
		shoulder = 0.0,
	}
end

local function copy_step_out(dst, src)
	dst.pos = src.pos
	dst.yaw = src.yaw
	dst.pitch = src.pitch
	dst.roll = src.roll
	dst.localpos = src.localpos
	dst.anchor = src.anchor
	dst.skater_anchor = src.skater_anchor
	dst.subject = src.subject
	dst.fov_extra = src.fov_extra
	dst.shoulder = src.shoulder
end

local function step_out_finite(o)
	local s = o.yaw + o.pitch + o.roll + o.fov_extra + o.shoulder
	return finite3(o.pos) and finite3(o.localpos) and s - s == 0
end

local function trick_yaw_reset(st)
	st.value = 0.0
	st.start = 0.0
	st.target = 0.0
	st.elapsed = 0.0
	st.duration = 0.0
	st.hold_left = 0.0
	st.side_known = false
	st.side_used = 0
	st.side_clock = 0.0
	st.side_since_change = 0.0
	st.urgent = false
end

local function layers_reset(ly)
	ly.landing_look_weight = 0.0
	ly.look_pitch_offset = 0.0
	ly.follow_strength = 1.0
	ly.collision_pull = 0.0
	ly.trick_yaw = 0.0
	ly.air_follow_weight = 0.0
	ly.air_reference_height = 0.0
	ly.air_rise = 0.0
	ly.keep_pitch_offset = 0.0
	ly.focus_weight = 1.0
	ly.follow_weight = 0.0
	ly.floor_weight = 0.0
	ly.height_offset = 0.0
	ly.board_weight = 0.0
	ly.keep_weight = 0.0
	ly.look_target = ZERO
	ly.board_target = ZERO
	ly.camera_free = ZERO
	ly.coll_pivot = ZERO
	ly.coll_full = 0.0
	ly.coll_hard = 0.0
	ly.coll_floor = 0.0
	ly.coll_goal = 0.0
	ly.coll_fast = 0.0
end

-- ---------------------------------------------------------------- the state

function Camera.new()
	local self = setmetatable({}, Camera)
	self.settings = Settings.camera()
	self.settings_valid_shake = nil
	-- The frame handed out (reused).
	self.frame = {
		right = vcreate(1, 0, 0),
		up = vcreate(0, 1, 0),
		back = vcreate(0, 0, 1),
		pos = ZERO,
		fov_deg = 0.0,
		shot = ShotId.Chase,
		valid = false,
		debug = {
			shot_name = "chase", reset = false, held = false, preset = 0, steps = 0, accumulator = 0.0, airborne = false,
			landing_active = false, transitioning = false, shot_fraction = 1.0, chase_blend = 0.0, prediction_valid = false,
			predicted_max_height = 0.0, predicted_air_time = 0.0, predicted_landing_delta = 0.0, air_hold_delta = 0.0,
			anchor_lag = 0.0, heading = 0.0, elevation = 0.0, distance = 0.0, impulse = 0.0, landing_dip = 0.0, speed = 0.0,
			incline_degrees = 0.0, forward_acceleration = 0.0, push_state = false, push_kick = false, fov_base = 0.0,
			fov_extra = 0.0, landing_look_weight = 0.0, look_pitch_offset = 0.0, shoulder = 0.0, follow_strength = 1.0,
			collision_pull = 0.0, trick_yaw = 0.0, air_follow_weight = 0.0, air_reference_height = 0.0, air_rise = 0.0,
			keep_pitch_offset = 0.0, focus_weight = 1.0, look_target = ZERO, landing_fall = 0.0, landing_fraction = 0.0,
			follow_weight = 0.0, travel_heading = 0.0, exit_blend = 1.0, floor_weight = 0.0, height_offset = 0.0,
			board_weight = 0.0, orbit_anchor = ZERO, skater_anchor = ZERO, view_heading = 0.0, ramp_side = 0.0,
			collision_rays = 0, collision_rays_max = 0, collision_pivot = ZERO, collision_full = 0.0, collision_hard = 0.0,
			collision_floor = 0.0, collision_goal = 0.0, collision_fast = 0.0, keep_weight = 0.0, board_target = ZERO,
			camera_free = ZERO, carried = ZERO,
		},
	}

	-- pipeline
	self.graph = Graph.new()
	self.air = Air.new()
	self.rig = Rig.new()
	self.shake = Shake.new()
	self.pan = T.new_state()
	self.tilt = T.new_state()
	self.roll = 0.0

	-- scratch input tables, filled every step
	self.graph_in = Graph.new_input()
	self.air_in = Air.new_input()
	self.rig_in = Rig.new_input()
	self.launch = Traj.new_launch()
	self.pan_set = T.angle_settings()
	self.tilt_set = T.angle_settings()
	self.shake_cfg = nil -- built from settings.shake in set_settings
	self.points = { ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO, ZERO }
	self.keep_points = { ZERO, ZERO, ZERO, ZERO }

	-- shot blend
	self.from = Shots.new()
	self.leaf = Shots.new()
	self.current = Shots.new()
	self.shots = lookup_shots(ShotId.Chase, Low)
	self.id = ShotId.Chase
	self.angle = Low
	self.shot_elapsed = 0.0
	self.shot_duration = 0.0
	self.shot_fraction = 1.0
	self.limits = { min = 1.2, max = 6.0 }
	self.limits_from = { min = 1.2, max = 6.0 }

	-- fixed-step driver
	self.cur_snap = Subject.new_snapshot()
	self.sub_snap = Subject.new_snapshot()
	self.prev_out = new_step_out()
	self.curr_out = new_step_out()
	self.out = new_step_out()
	self.acc = 0.0
	self.aspect = 16.0 / 9.0
	self.invalid_time = 0.0
	self.initialized = false
	self.reset_requested = false
	self.last_preset = 0

	-- air / prediction
	self.was_air = false
	self.air_time = 0.0
	self.repredict_timer = 0.0
	self.flight_max_height = 0.0
	self.takeoff_surface_y = 0.0
	self.last_clearance = 0.95
	self.last_ground_normal = UP
	self.prediction = EMPTY_PREDICTION
	self.prediction_offset = 0.0
	self.prediction_time_base = 0.0

	-- acceleration / push
	self.accel_ready = false
	self.prev_forward_speed = 0.0
	self.accel_filtered = 0.0
	self.prev_accel = 0.0
	self.push_timer = 0.0
	self.no_lag_timer = 0.0

	-- Alpha 2 layers
	self.fov_extra = 0.0
	self.chase_lens = 12.0
	self.landing_w = 0.0
	self.look_pitch = 0.0
	self.landing_point = ZERO
	self.fov_extra_stage = 0.0
	self.landing_w_stage = 0.0
	self.look_pitch_stage = 0.0
	self.air_w_stage = 0.0
	self.rise_w_stage = 0.0
	self.landing_point_stage = ZERO
	self.shoulder_value = 0.0
	self.shoulder_start = 0.0
	self.shoulder_target = 0.0
	self.shoulder_elapsed = 0.0
	self.pull = held_new()
	self.shoulder_clip = held_new()
	self.coll_fast = 0.0
	self.coll_lift_fast = 0.0
	self.coll_lift = 0.0
	self.coll_lift_stage = 0.0
	self.ramp_space_w = 0.0
	self.coll_wall = 0.0
	self.coll_wall_stage = 0.0
	-- Alpha 4
	self.air_w = 0.0
	self.rise_w = 0.0
	self.keep_off = 0.0
	self.focus_value = 1.0
	self.focus_from = 1.0
	self.framing_pitch = 0.0
	self.last_elevation_used = 0.0
	self.last_view_heading = 0.0
	self.extras_base_fov = 0.0
	self.last_shake_pitch = 0.0
	self.ramp_limit = limiter_new()
	self.hard_pivot = ZERO
	self.hard_dir = FWD
	self.hard_allowed = 1.0e9
	self.hard_floor_y = -1.0e9
	self.air_room_w = 0.0
	self.air_room_w_stage = 0.0
	self.rider_hold = 0.0
	self.orbit_reach = 0.0
	self.fixed_w = 0.0
	self.fixed_w_stage = 0.0
	self.rest_fov = 0.0
	self.rest_fov_stage = 0.0
	self.rest_fov_target = 0.0
	self.rest_fov_w = 0.0
	self.rest_fov_w_stage = 0.0
	self.rest_fov_valid = false
	self.air_room_max = 0.0
	self.air_room_extra = 0.0
	self.keep_rate = 0.0
	self.keep_w = 0.0
	self.keep_w_stage = 0.0
	self.held_speed = 0.0
	self.trick_yaw = {}
	trick_yaw_reset(self.trick_yaw)
	-- Alpha 5
	self.air_peak_y = 0.0
	self.last_landing_fall = 0.0
	self.last_landing_fraction = 0.0
	self.travel_heading = 0.0
	self.travel_stage = 0.0
	self.hf_w = 0.0
	self.hf_w_stage = 0.0
	self.exit_active = false
	self.transition = false
	self.transition_w = 0.0
	self.transition_w_stage = 0.0
	self.transition_shallow = 0.0
	self.transition_hold = false
	self.swing = false
	self.swing_heading = 0.0
	self.swing_dir = 0.0
	self.swing_target = 0.0
	self.prev_heading_used = 0.0
	self.ramp_clear_time = 0.0
	self.ramp_side = 0.0
	self.ramp_side_rate = 0.0
	self.ramp_probe_clock = 0.0
	self.ramp_zero_clear = false
	self.ramp_down = FWD
	self.last_shift = ZERO
	self.coll_blocked = false
	self.ray_parity = false
	self.shoulder_goal_cached = 0.0
	self.ramp_parity = false
	self.ramp_scan = 0
	self.ramp_block_streak = 0
	self.ramp_blocked = false
	self.swing_rate = 0.0
	self.exit_start_distance = 0.0
	self.exit_elapsed = 0.0
	self.exit_duration = 0.0
	self.exit_blend = 1.0
	self.distance_used = 0.0
	self.transition_up_seen = false
	self.downhill_grade = 0.0
	self.downhill_lift = 0.0
	self.downhill_lift_stage = 0.0
	self.hill_grade = 0.0
	self.transition_from_hill = false
	self.downhill_time = 0.0
	self.downhill_rise = false
	self.floor_w = 0.0
	self.floor_w_stage = 0.0
	self.height_off = 0.0
	self.height_stage = 0.0
	-- Alpha 6
	self.board_rel = ZERO
	self.board_rel_stage = ZERO
	self.trajectory_arc = ZERO
	self.trajectory_arc_stage = ZERO
	self.board_w = 0.0
	self.board_w_stage = 0.0
	self.layers = {}
	layers_reset(self.layers)
	-- ramp slide look context (the C++ lambdas' captures)
	self.rs_pivot = ZERO
	self.rs_anchor = ZERO
	self.rs_heading = 0.0
	self.rs_reach = 0.0
	self.rs_rise = 0.0
	self.rs_first_ray = 0
	self.rs_look_ahead = false
	self.rs_landing_shift = ZERO

	-- diagnostics from the last step
	self.kick_in_update = false
	self.step_rays = 0
	self.update_rays = 0
	self.update_rays_max = 0
	self.last_pick_chase_blend = 0.0
	self.last_pick_landing_active = false
	self.last_rig_heading = 0.0
	self.last_rig_elevation = 0.0
	self.last_rig_distance = 0.0
	self.last_rig_anchor_lag = 0.0
	self.last_speed = 0.0
	self.last_hold = 0.0
	self.incline_degrees = 0.0
	self.last_push_state = false
	self.last_push_kick = false
	self:set_settings(self.settings)
	return self
end

-- Replaces the settings. Invalid settings are rejected (returns false, old ones kept). Changing the preset cuts the camera on
-- the next update; changing the angle blends through a shot transition.
function Camera:set_settings(settings)
	if not Settings.valid(settings) then
		return false
	end
	local copy = Settings.copy(settings)
	self.settings = copy
	-- The speed shake rebuilds the shake settings each step: a shallow copy to write the four fields it changes into.
	local cfg = {}
	for k, v in copy.shake do
		cfg[k] = v
	end
	self.shake_cfg = cfg
	return true
end

-- Cut on the next update: spawn, teleport, respawn after a bail, taking ownership.
function Camera:cut()
	self.reset_requested = true
end

-- ---------------------------------------------------------------- settings-derived values

local function active_framing(self)
	local cs = self.settings
	return cs.angle == High and cs.framing_high or cs.framing
end

local function active_ride(self)
	local cs = self.settings
	return cs.angle == High and cs.ride_distance_high or cs.ride_distance
end

-- A built-in shot's distance on the player's Speed range: placed between the slow and the top-speed distance where it sits
-- between the built-in slow and fast chase distances, so a chase shot blended by speed lands on the same blend (not held).
local function speed_mapped_distance(self, tbl)
	local rd = active_ride(self)
	local angle = self.settings.angle
	local slow, fast = chase_slow[angle], chase_fast[angle]
	return rd.slow + (tbl - slow) / max(fast - slow, 1e-3) * (rd.fast - rd.slow)
end

-- The angle in use's riding distance limits: Speed, slow up to the big-air shot's own distance on the range (which may lie past
-- the top-speed one); Fixed, its one distance. Returns min, max.
local function active_limits(self)
	local rd = active_ride(self)
	if rd.mode == FIXED then
		return rd.fixed, rd.fixed
	end
	return rd.slow, clamp(speed_mapped_distance(self, air_big_distance[self.settings.angle]), rd.fast, big_air_room_cap)
end

-- A shot's distance: Fixed, the one distance; Speed, mapped and held inside the range, except the air and wipeout shots, which
-- keep their place on it up to the limits.
local function ride_distance_of(self, tbl, id)
	local rd = active_ride(self)
	if rd.mode == FIXED then
		return rd.fixed
	end
	local own = id == ShotId.AirBig or id == ShotId.AirNormal or id == ShotId.Wipeout
	local hi = rd.fast
	if own then
		local _, limit_max = active_limits(self)
		hi = limit_max
	end
	return clamp(speed_mapped_distance(self, tbl), rd.slow, hi)
end

-- 0: neither, 1: a manual shot, 2: a grind shot. Leaving one kind for any other shot is an "exit".
local function closeup_kind(id)
	if id == ShotId.ManualFar or id == ShotId.ManualClose then
		return 1
	elseif id == ShotId.GrindFlat or id == ShotId.GrindLedgeL or id == ShotId.GrindLedgeR then
		return 2
	end
	return 0
end

-- The manual close-up's distance: the player's own (Fixed), or eased from the minimum standing to the maximum at
-- manual_full_speed (Speed; smoothstep, and the rig's distance tracker eases it further).
local function manual_distance_of(fr, speed)
	if fr.manual_mode ~= MANUAL_SPEED then
		return fr.manual_distance
	end
	local x = clamp01(abs(speed) / manual_full_speed)
	return lerp_f(fr.manual_min_distance, fr.manual_max_distance, x * x * (3.0 - 2.0 * x))
end

-- The shot with the player's framing applied (FullS3), in place: the distance of the shot (each kind held inside its own
-- limits where the shot is resolved, so the rig's distance tracker, the blend and the close-up exit all work from it).
local function framed(self, shot, id, speed)
	local fr = active_framing(self)
	local kind = closeup_kind(id)
	if fr.manual_camera and kind == 1 then
		shot.distance = clamp(manual_distance_of(fr, speed), closeup_min_distance, 8.0)
	elseif fr.grind_camera and kind == 2 then
		shot.distance = clamp(fr.grind_distance, closeup_min_distance, 8.0)
	else
		shot.distance = ride_distance_of(self, shot.distance, id)
	end
	return shot
end

-- The framing height for a shot, radians: height_degrees plus the manual_ / grind_ one on those shots.
local function height_goal_of(self, id)
	local fr = active_framing(self)
	local kind = closeup_kind(id)
	if fr.manual_camera and kind == 1 then
		return fr.manual_height_degrees * DEG
	end
	if fr.grind_camera and kind == 2 then
		return fr.grind_height_degrees * DEG
	end
	return fr.height_degrees * DEG
end

-- The view pitch for a shot, radians: the close-ups have their own.
local function pitch_goal_of(self, id)
	local fr = active_framing(self)
	local kind = closeup_kind(id)
	if fr.manual_camera and kind == 1 then
		return fr.manual_pitch_degrees * DEG
	end
	if fr.grind_camera and kind == 2 then
		return fr.grind_pitch_degrees * DEG
	end
	return fr.pitch_degrees * DEG
end

-- Ease times (1.0.2): every ease the player's sliders (or the shot table) set has an internal minimum.
local function with_minimum(seconds)
	return max(seconds, min_ease_time)
end

local function ease_time(self, seconds)
	return with_minimum(seconds * self.settings.look.shot_blend)
end

local function exit_time(self)
	return with_minimum(self.settings.look.closeup_exit_time)
end

local function enter_time(self)
	return with_minimum(floor_in_time * self.settings.look.shot_blend)
end

local function response_time(self)
	return with_minimum(self.settings.look.response_time)
end

-- Base fov: the override, else the game camera's own (extras.base_fov_deg), else the chase shot's lens. In Fixed distance the
-- game's own speed widening is left out: the base eases to the game's resting lens (rest_fov) and back.
local function fov_base_deg(self)
	local base_fov = lens_field_of_view_degrees(self.chase_lens, self.aspect)
	local ebf = self.extras_base_fov
	if isfinite(ebf) and ebf > 0.0 then
		base_fov = ebf
		if self.rest_fov_valid then
			base_fov = lerp_f(base_fov, self.rest_fov, self.rest_fov_w)
		end
	end
	local override = self.settings.fov_override_deg
	if override > 0.0 then
		base_fov = override
	end
	return base_fov
end

-- The distance limits in force: the main camera's, relaxed to the close-ups' own range as the close-up weight eases in and out.
local function distance_min(self)
	return lerp_f(self.limits.min, closeup_min_distance, self.floor_w)
end

local function distance_max(self)
	return lerp_f(self.limits.max, 8.0, self.floor_w)
end

-- The orbit distance at which the skater, head to board, takes big_air_frame_share of the vertical view.
local function air_fit_distance(self)
	local half = 0.5 * clamp(fov_base_deg(self) + self.fov_extra, 1.0, 170.0) * DEG
	return (big_air_head + self.settings.points.board_drop) / (2.0 * tan(big_air_frame_share * half))
end

-- How hard a landing was, 0..1.
local function landing_fraction_of(self, fall_height, flat_speed)
	local cs = self.settings
	local ls = cs.landing_shake
	local grav = max(cs.trajectory.gravity, 1e-3)
	local impact = sqrt(2.0 * grav * max(fall_height, 0.0)) + ls.speed_weight * flat_speed
	local low, high = sqrt(2.0 * grav * max(ls.min_fall, 0.0)), sqrt(2.0 * grav * max(ls.full_fall, 0.0))
	return clamp01((impact - low) / max(high - low, 1e-3))
end

-- The slope of the direction of travel along the ground, degrees, + uphill, from the velocity on the surface, faded out below
-- incline_full_speed.
local function incline_of(s, normal)
	local incline_min_speed, incline_full_speed = 0.5, 2.0
	local velocity = s.velocity
	local along = velocity - normal * vdot(velocity, normal)
	local l = vmag(along)
	if not (l > incline_min_speed) then
		return 0.0
	end
	local weight = clamp01((l - incline_min_speed) / (incline_full_speed - incline_min_speed))
	return weight * asin(clamp(along.y / l, -1.0, 1.0)) / DEG
end

-- Where the look target sits between the board (0) and the shot's usual point (1).
local function focus_of(self, id)
	if id == ShotId.ManualFar or id == ShotId.ManualClose then
		return self.settings.look.manual_focus
	elseif id == ShotId.GrindFlat or id == ShotId.GrindLedgeL or id == ShotId.GrindLedgeR then
		return self.settings.look.grind_focus
	end
	return 1.0
end

-- Pitch of the line camera -> point, radians (+ above the camera). 0 when they coincide.
local function elevation_to(from_pos, to_pos)
	local line = to_pos - from_pos
	local span = vmag(line)
	if span > 1e-3 then
		return asin(clamp(line.y / max(span, 1e-3), -1.0, 1.0))
	end
	return 0.0
end

local function personal_root(self)
	return lerp_f(personal_root_distance, ramp_root_distance, self.ramp_space_w)
end

local function personal_board(self)
	return lerp_f(personal_board_distance, ramp_board_distance, self.ramp_space_w)
end

-- `camera` pushed straight away from `point` until it is `radius` from it (unchanged when it already is).
local function keep_out_of(camera, point, radius)
	local away = camera - point
	local span = vmag(away)
	if span >= radius or span < 1e-4 then
		return camera
	end
	return point + away * (radius / span)
end

-- The least distance along the line pivot + dir * d at which a camera is at least `radius` from `point` (0: the line never comes
-- that close), never more than `free`.
local function distance_clear_of(pivot, dir, point, radius, free)
	local to_point = point - pivot
	local along = vdot(dir, to_point)
	local miss_sq = vdot(to_point, to_point) - along * along
	if radius * radius <= miss_sq then
		return 0.0
	end
	return clamp(along + sqrt(radius * radius - miss_sq), 0.0, free)
end

-- The final camera held at most DistanceLimits::max from the orbit anchor. The minimum is NOT held here. `fallback` is the
-- direction to use when the camera sits on the anchor. It never cuts what the orbit itself puts there (orbit_reach).
local function clamp_distance(self, camera, anchor, fallback)
	local offset = camera - anchor
	local span = vmag(offset)
	if span < 1e-4 then
		offset = fallback
		span = max(vmag(offset), 1e-4)
	end
	local wanted = min(span, max(distance_max(self), distance_min(self), self.air_room_max, self.orbit_reach))
	if wanted == span then
		return camera
	end
	return anchor + offset * (wanted / max(span, 1e-4))
end

-- ---------------------------------------------------------------- world rays

-- One collision / ramp ray (counted: the ray budget of a fixed step is the collision layer's and the ramp slide's together).
-- Returns the hit point or nil.
local function cast(self, query, from, to)
	if self.step_rays >= ray_budget then
		return nil -- out of rays this step: no answer is a clear line
	end
	self.step_rays = self.step_rays + 1
	-- (A point is all a collision ray needs: false spares the glue the extra rays a normal costs, as query_point does in the C++.)
	local hit = query(from, to, false)
	if hit ~= nil and not finite3(hit) then
		return nil
	end
	return hit
end

-- Is what the line meets the ground he rides on or a ledge he has landed on, rather than a wall? One look straight down, a
-- little toward him from the hit, finds a top surface at or just above the hit that is no higher than his look point.
local function ground_under_hit(self, query, from, hit)
	local toward = normalized(vcreate(from.x - hit.x, 0.0, from.z - hit.z), ZERO)
	local over = vcreate(hit.x + toward.x * lip_probe_reach, max(from.y, hit.y) + lip_probe_rise, hit.z + toward.z * lip_probe_reach)
	local top = cast(self, query, over, vcreate(over.x, hit.y - lip_probe_skin, over.z))
	return top ~= nil and top.y <= from.y + lip_top_margin
end

-- ---------------------------------------------------------------- keep in frame

-- Keep the skater inside the vertical view while airborne (air_camera.keep_in_frame). `view_pitch` is the view's pitch BEFORE
-- this offset. The first `held` points are held inside the hard limit; the rest only steer the view toward keeping them in too.
-- `weight` (0..1, eased by the caller) is how much of the guard applies. Returns the offset, radians.
local function update_keep_in_frame(self, cam_pos, view_pitch, points, count, held, weight, snap)
	local half_fov = 0.5 * clamp(fov_base_deg(self) + self.fov_extra, 1.0, 170.0) * DEG
	local soft, hard = 0.7 * half_fov, 0.9 * half_fov
	local w = (self.settings.air_camera.keep_in_frame and not snap) and clamp01(weight) or 0.0
	local goal_up, goal_down, range_lo, range_hi = 0.0, 0.0, -1.0e3, 1.0e3
	for i = 1, count do
		local err = elevation_to(cam_pos, points[i]) - view_pitch -- + the point is above the view axis
		goal_up = max(goal_up, err - soft)
		goal_down = max(goal_down, -err - soft)
		if i <= held then
			range_lo = max(range_lo, err - hard)
			range_hi = min(range_hi, err + hard)
		end
	end
	if snap then
		self.keep_off = 0.0
		self.keep_rate = 0.0
	else
		-- The offset eases toward the weighted share of the one that brings every point inside the soft band, and is then held
		-- at once inside the weighted hard limits (range_lo > range_hi: the points cannot all fit, aim between them).
		local keep_off = self.keep_off
		local wanted = ease_to(keep_off, w * (goal_up - goal_down), keep_response_time, fixed_step)
		if range_lo <= range_hi then
			wanted = clamp(wanted, w * range_lo, w * range_hi)
		else
			wanted = w * 0.5 * (range_lo + range_hi)
		end
		-- However the ease and the guard ask, the offset moves at most keep_guard_rate, and its rate changes by at most
		-- keep_guard_accel a second.
		local max_rate, accel = keep_guard_rate * DEG, keep_guard_accel * DEG
		local wanted_rate = clamp((wanted - keep_off) / fixed_step, -max_rate, max_rate)
		local keep_rate = self.keep_rate + clamp(wanted_rate - self.keep_rate, -accel * fixed_step, accel * fixed_step)
		self.keep_rate = keep_rate
		-- (Never past what was wanted: the rate is what reaches it, not more.)
		local step = keep_rate * fixed_step
		if (wanted - keep_off) * step > 0.0 and abs(step) > abs(wanted - keep_off) then
			self.keep_off = wanted
		else
			self.keep_off = keep_off + step
		end
	end
	return self.keep_off
end

-- ---------------------------------------------------------------- trick yaw

-- Is the side `toward` (+1 right, -1 left) walled: a surface within the swing's reach beside the skater, now or where he will
-- be in trick_side_lookahead (at most 2.5 m on).
local function trick_side_blocked(self, query, s, pivot, heading, shoulder_metres, toward)
	local ty = self.settings.trick_yaw
	local v = s.velocity
	local flat_velocity = vcreate(v.x, 0.0, v.z)
	local ahead = flat_velocity * min(trick_side_lookahead, 2.5 / max(vmag(flat_velocity), 1e-3))
	local sin_a = sin(ty.angle_degrees * DEG)
	local reach = max(self.distance_used, 1.0) * sin_a + self.settings.collision.radius + max(0.0, shoulder_metres * toward)
	local right = vcreate(cos(heading), 0.0, sin(heading))
	local sideways = right * (reach * toward)
	return cast(self, query, pivot, pivot + sideways) ~= nil or cast(self, query, pivot + ahead, pivot + ahead + sideways) ~= nil
end

-- Is there something in the camera's own path while it is turned `yaw` out (a pole it would ride into).
local function trick_path_blocked(self, query, s, pivot, heading, yaw)
	local v = s.velocity
	local flat_velocity = vcreate(v.x, 0.0, v.z)
	local speed = vmag(flat_velocity)
	if speed < 0.5 then
		return false
	end
	local radius = self.settings.collision.radius
	local h = heading - yaw
	local reach = max(self.distance_used * cos(self.last_elevation_used), 0.5)
	local spot = pivot + vcreate(-sin(h) * reach, 0.0, cos(h) * reach)
	local run = min(speed * trick_side_lookahead, 2.5) + radius
	local along = flat_velocity * (run / speed)
	-- The camera's width: its centre line and one either side, a radius out.
	local across = vcreate(flat_velocity.z, 0.0, -flat_velocity.x) * (radius / speed)
	if cast(self, query, spot, spot + along) ~= nil then
		return true
	end
	local a = spot + across
	if cast(self, query, a, a + along) ~= nil then
		return true
	end
	local b = spot - across
	if cast(self, query, b, b + along) ~= nil then
		return true
	end
	return false
end

-- The trick-yaw state machine (one fixed step). Tricking = airborne for min_air_time, grinding or in a manual, each only if its
-- switch is on. The target is angle * side while tricking and for hold_time after the last trick step, then 0.
local function update_trick_yaw(self, query, s, snap, dt, pivot, heading, shoulder_metres)
	local cs = self.settings
	local ty = cs.trick_yaw
	local st = self.trick_yaw
	if snap then
		trick_yaw_reset(st)
		return
	end
	local tricking = ty.enabled and not s.bailing
		and ((ty.in_air and is_air_state(s.physics_state) and self.air_time >= ty.min_air_time)
			or (ty.on_grinds and is_grind_state(s.physics_state)) or (ty.on_manuals and s.manual))
	local goal = 0.0
	if tricking then
		-- Same rule as the shoulder's Auto side: +1 regular (toes to the right), -1 goofy XOR switch.
		local side = ty.side
		if side == 0 then
			local preferred
			if cs.shoulder.mode == SHOULDER_MANUAL then
				preferred = cs.shoulder.side
			else
				preferred = (cs.shoulder.goofy ~= s.switch_stance) and -1 or 1
			end
			st.side_clock = st.side_clock + dt
			if not st.side_known or st.side_clock >= trick_side_period then
				local chosen = preferred
				if cs.collision.enabled and ty.angle_degrees > 1.0 then
					if trick_side_blocked(self, query, s, pivot, heading, shoulder_metres, preferred) then
						chosen = trick_side_blocked(self, query, s, pivot, heading, shoulder_metres, -preferred) and 0 or -preferred
					end
				end
				st.side_clock = 0.0
				if not st.side_known then
					st.side_used = chosen
					st.side_since_change = trick_side_dwell
				elseif chosen ~= st.side_used and st.side_since_change >= trick_side_dwell then
					st.side_used = chosen
					st.side_since_change = 0.0
				end
				st.side_known = true
			end
			st.side_since_change = st.side_since_change + dt
			side = st.side_used
		end
		st.hold_left = ty.hold_time
		goal = ty.angle_degrees * DEG * side
	else
		st.hold_left = (ty.enabled and not s.bailing) and max(0.0, st.hold_left - dt) or 0.0
		-- Held out to the side after the trick: a wall or a pole coming up on that side ends the hold.
		if st.hold_left > 0.0 and st.target ~= 0.0 and cs.collision.enabled then
			st.side_clock = st.side_clock + dt
			if st.side_clock >= trick_side_period then
				st.side_clock = 0.0
				if trick_side_blocked(self, query, s, pivot, heading, shoulder_metres, st.target < 0.0 and -1 or 1)
					or trick_path_blocked(self, query, s, pivot, heading, st.value) then
					st.hold_left = 0.0
					st.urgent = true -- back as fast as the swing may go, not at the player's return time
				end
			end
		end
		goal = st.hold_left > 0.0 and st.target or 0.0
		if st.hold_left <= 0.0 then
			st.side_known = false
		end
	end
	if goal ~= st.target then -- retarget: ease from wherever the value is now
		st.start = st.value
		st.target = goal
		st.elapsed = 0.0
		-- At least min_ease_time, and long enough that the camera's sine-eased swing round him stays within trick_yaw_speed.
		local swing_time = abs(st.target - st.start) * max(self.distance_used, 1.0) * 0.5 * PI / trick_yaw_speed
		if st.urgent and goal == 0.0 then
			st.duration = max(min_ease_time, swing_time)
		else
			st.duration = max(with_minimum(goal == 0.0 and ty.return_time or ty.in_time), swing_time)
		end
		st.urgent = false
	end
	st.elapsed = st.elapsed + dt
	local fraction = st.duration > 1e-4 and clamp01(st.elapsed / max(st.duration, 1e-4)) or 1.0
	st.value = st.start + (st.target - st.start) * sine_blend(fraction)
end

-- ---------------------------------------------------------------- transitions, swing, ramp slide

-- Transitions (quarter pipes, vert, banks): riding a surface steeper than transition_on_degrees starts it, and it lasts through
-- the air off it, until the skater has ridden transition_off_time on a surface flatter than transition_off_degrees.
local function update_transition(self, snap, grounded, normal, velocity, dt)
	local on_y, off_y = cos(transition_on_degrees * DEG), cos(transition_off_degrees * DEG)
	local speed = vmag(velocity)
	local path_steep = speed < ramp_path_min_speed or abs(velocity.y) >= sin(transition_path_degrees * DEG) * speed
	local steep = grounded and normal.y < on_y and path_steep
	-- Speed along the ramp, + going up it: the velocity on the surface's uphill direction.
	local across = sqrt(max(0.0, 1.0 - normal.y * normal.y))
	local up_speed = 0.0
	if across > 1e-3 then
		up_speed = (-normal.y * normal.x * velocity.x + across * across * velocity.y - normal.y * normal.z * velocity.z) / across
	end
	local was_held = self.transition_hold
	if steep and across > 1e-3 then
		self.ramp_down = vcreate(normal.x / across, 0.0, normal.z / across) -- the wall's way down
	end
	if snap then
		self.transition = steep
		self.transition_shallow = 0.0
		local w = self.transition and 1.0 or 0.0
		self.transition_w = w
		self.transition_w_stage = w
		self.ramp_space_w = w
		self.transition_hold = self.transition and up_speed > -ramp_turn_speed
		self.transition_up_seen = self.transition_hold
		self.downhill_grade = 0.0
		self.downhill_time = 0.0
		self.hill_grade = 0.0
		self.downhill_rise = false
		self.transition_from_hill = false
		self.swing = false
		return
	end
	local was_on = self.transition
	if steep then
		self.transition = true
		self.transition_shallow = 0.0
	elseif grounded and normal.y > off_y then
		self.transition_shallow = self.transition_shallow + dt
		if self.transition_shallow >= transition_off_time then
			self.transition = false
		end
	end
	if not self.transition then
		self.transition_hold = false
		self.transition_up_seen = false
	elseif not was_on then
		self.transition_hold = up_speed > -ramp_turn_speed -- dropping in down a ramp has no reversal ahead
		-- Already riding down a hill as the ground steepens into a transition: it stays above it.
		self.transition_from_hill = self.hill_grade > hill_rise_min * DEG
	elseif steep then
		if up_speed > ramp_turn_speed then
			self.transition_hold = true -- riding up (again): the reversal is ahead
		elseif up_speed < -ramp_turn_speed then
			self.transition_hold = false -- riding down: turn round behind it
		end
	elseif not grounded and self.transition_hold and velocity.y < -ramp_air_fall_speed
		and sqrt(velocity.x * velocity.x + velocity.z * velocity.z) < ramp_air_flat_speed then
		self.transition_hold = false -- over the lip and falling straight down: it has reversed
	end
	if self.transition_hold then
		self.transition_up_seen = true
	end
	-- Riding DOWN a slope: how steeply the ground rises behind him, along his travel.
	local grade = 0.0
	if grounded and up_speed < -ramp_turn_speed then
		local flat_speed = sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
		if flat_speed > 0.5 and normal.y > 1e-3 then
			local flat = vcreate(velocity.x, 0.0, velocity.z)
			grade = max(0.0, math.atan(vdot(normal, flat * (1.0 / flat_speed)) / normal.y))
		end
	end
	if grounded then
		self.hill_grade = grade
	end
	self.downhill_grade = (self.transition and not self.transition_up_seen) and grade or 0.0
	if self.downhill_grade > 0.0 then
		self.downhill_time = self.downhill_time + dt
	elseif not self.transition then
		self.downhill_time = 0.0
	end
	if not self.transition or self.transition_up_seen then
		self.downhill_rise = false
	elseif self.downhill_grade > 0.0
		and (self.transition_from_hill or self.downhill_time >= downhill_lift_after
			or (abs(self.ramp_side) >= (downhill_side_cap - 1.0) * DEG and self.ramp_blocked)) then
		self.downhill_rise = true
	end
	if was_held and not self.transition_hold then
		self.swing = true
		self.swing_target = wrap_angle(heading_of(self.ramp_down) + self.current.position_heading)
	end
	self.transition_w_stage, self.transition_w = ease2(self.transition_w_stage, self.transition_w, self.transition and 1.0 or 0.0, transition_ease_time, dt)
	self.ramp_space_w = ease_to(self.ramp_space_w, (self.transition or self.swing) and 1.0 or 0.0, ramp_space_time, dt)
end

-- The ramp swing: after the hold, the heading is turned round behind the new travel direction at a capped rate.
local function apply_swing(self, snap, heading, velocity, dt)
	if snap or not self.swing then
		self.swing = self.swing and not snap
		self.swing_heading = heading
		self.swing_dir = 0.0
		self.swing_rate = 0.0
		return heading
	end
	local shot_heading = self.current.position_heading
	local flat = vcreate(velocity.x, 0.0, velocity.z)
	if vmag(flat) > follow_min_speed then
		self.swing_target = wrap_angle(heading_of(flat) + shot_heading)
	end
	local remaining = wrap_angle(self.swing_target - self.swing_heading)
	if abs(remaining) > swing_flip_guard_degrees * DEG then -- about half a turn: keep to one side, not flip with the sign
		if self.swing_dir == 0.0 then
			self.swing_dir = remaining < 0.0 and -1.0 or 1.0
		end
		remaining = self.swing_dir * abs(remaining)
	else
		self.swing_dir = 0.0
	end
	local level = clamp01(self.settings.follow.horizontal / 10.0)
	local cap = lerp_f(swing_slowest_turn, swing_fastest_turn, level)
	if self.ramp_blocked then
		cap = min(cap, swing_blocked_turn)
	end
	local orbit_radius = max(self.distance_used * cos(self.last_elevation_used), 0.5)
	local max_rate, accel = min(cap * DEG, swing_orbit_speed / orbit_radius), swing_acceleration * DEG
	local wanted = (remaining < 0.0 and -1.0 or 1.0) * min(max_rate, sqrt(2.0 * accel * abs(remaining)), 0.5 * abs(remaining) / dt)
	self.swing_rate = self.swing_rate + clamp(wanted - self.swing_rate, -accel * dt, accel * dt)
	local turn = self.swing_rate * dt
	local applied = turn
	if abs(turn) >= abs(remaining) and turn * remaining > 0.0 then
		applied = remaining
	end
	self.swing_heading = wrap_angle(self.swing_heading + applied)
	Rig.place_heading(self.rig, self.swing_heading, shot_heading)
	local th = wrap_angle(self.swing_heading - shot_heading)
	self.travel_heading = th
	self.travel_stage = th
	if abs(wrap_angle(self.swing_target - self.swing_heading)) < swing_done_degrees * DEG and abs(self.swing_rate) < swing_done_rate * DEG then
		self.swing = false
	end
	return self.swing_heading
end

-- Which side of the wall the heading lies (-1 / +1): the sign of wrap_angle(heading - wall_heading), worked in float32 like the
-- C++. Behind a ramp the gap is exactly a whole turn (heading -pi, wall +pi), where double and float round to opposite signs.
local TAU_F32 = f32(S3.tau)
local function side_of_gap(heading, wall_heading)
	local d = f32(f32(heading) - f32(wall_heading))
	local reduced = d - (d / TAU_F32 >= 0 and floor(d / TAU_F32) or -floor(-d / TAU_F32)) * TAU_F32
	if reduced < -PI then
		reduced = reduced + TAU_F32
	end
	if reduced >= PI then
		reduced = reduced - TAU_F32
	end
	return reduced < 0.0 and -1.0 or 1.0
end

-- The line from `from` to `spot` blocked: a surface in it, or just beyond the camera (one ray; a hit within ramp_side_clearance
-- of it counts).
local function ramp_line_blocked(self, query, from, spot)
	local direction = normalized(spot - from, UP)
	local hit = cast(self, query, from, spot + direction * ramp_side_margin)
	return hit ~= nil and vmag(hit - from) <= vmag(spot - from) + ramp_side_clearance
end

-- Is the way from the pivot to the camera at heading offset `offset` blocked (also from the predicted landing, in the air).
local function ramp_blocked_at(self, query, offset)
	local h = self.rs_heading + offset
	local reach = self.rs_reach
	-- The line goes to a point below the camera; the shoulder's shift is added (built last step).
	local spot = self.rs_anchor + vcreate(-sin(h) * reach, self.rs_rise - ramp_side_below, cos(h) * reach) + self.last_shift
	if ramp_line_blocked(self, query, self.rs_pivot, spot) then
		return true
	end
	if self.rs_look_ahead then
		local shift = self.rs_landing_shift
		return ramp_line_blocked(self, query, self.rs_pivot + shift, spot + shift)
	end
	return false
end

local function ramp_has_room(self)
	return self.step_rays - self.rs_first_ray + (self.rs_look_ahead and 1 or 0) < ramp_ray_budget
end

-- Ramps: how far to slide the camera round to the side so the line from the skater to it is clear of the pipe. The camera keeps
-- its distance and turns away from the wall just far enough to be clear of it. Only in a transition; outside one it eases to 0.
local function update_ramp_side(self, query, snap, pivot, root, airborne, anchor, heading, dt)
	local cs = self.settings
	local goal = self.ramp_side
	if snap or not self.transition or not cs.collision.enabled or self.downhill_rise then
		goal = 0.0
		self.ramp_blocked = false
		self.ramp_probe_clock = 0.0
		self.ramp_clear_time = 0.0
		self.ramp_zero_clear = false
		self.ramp_scan = 0
		self.ramp_block_streak = 0
	else
		local le = self.last_elevation_used
		local reach, rise = self.distance_used * cos(le), self.distance_used * sin(le)
		self.rs_first_ray = self.step_rays
		self.rs_pivot = pivot
		self.rs_anchor = anchor
		self.rs_heading = heading
		self.rs_reach = reach
		self.rs_rise = rise
		-- In the air the camera also has to be clear of the wall where the skater will be: the line is also tried from where the
		-- trajectory prediction lands him.
		self.rs_look_ahead = false
		self.rs_landing_shift = ZERO
		local prediction = self.prediction
		if airborne and prediction.status == "Landed" then
			local shift = prediction.landing_position + vcreate(0.0, self.last_clearance, 0.0) - root
			self.rs_landing_shift = shift
			self.rs_look_ahead = vmag(shift) > 0.3
		end
		self.ramp_probe_clock = self.ramp_probe_clock + dt
		-- Nothing wrong and nothing moving: looked at every other step (the slide then starts at most a step late).
		self.ramp_parity = not self.ramp_parity
		if self.ramp_side == 0.0 and not self.ramp_blocked and not self.coll_blocked and not self.swing and self.ramp_parity then
			return
		end
		-- While the swing carries the heading on, the line is also tried where the heading will be in ramp_lead_time.
		local line_blocked_now = ramp_blocked_at(self, query, self.ramp_side)
			or (self.swing and abs(self.swing_rate) > 0.1 and ramp_blocked_at(self, query, self.ramp_side + self.swing_rate * ramp_lead_time))
		-- Once the slide has settled, it moves again only when two looks in a row are blocked.
		self.ramp_block_streak = line_blocked_now and (self.ramp_block_streak + 1) or 0
		local settled = self.ramp_side ~= 0.0 and self.ramp_side_rate == 0.0
		local nominal_blocked = line_blocked_now and (not settled or self.ramp_block_streak >= 2)
		self.ramp_blocked = nominal_blocked or self.coll_blocked
		-- Riding down a transition he never rode up, the slide stops at the side (downhill_side_cap).
		local side_max = (not self.transition_up_seen) and downhill_side_cap or ramp_side_max_degrees
		if self.ramp_blocked then
			self.ramp_clear_time = 0.0
			-- Away from the wall the short way, or the side it is already on.
			local wall_heading = heading_of(self.ramp_down * -1.0)
			local side
			if self.ramp_side ~= 0.0 then
				side = self.ramp_side < 0.0 and -1.0 or 1.0
			else
				-- (float rounding: a gap of exactly a whole turn, the common case behind a ramp, then picks the side the C++ picks)
				side = side_of_gap(heading, wall_heading)
			end
			if self.ramp_scan >= 100 then
				side = -side -- the last scan found nothing on that side: this one tries the other
			end
			-- The nearest clear offset to 0 on that side, in 15 degree steps.
			local candidates = floor(side_max / ramp_side_probe_step)
			local index = self.ramp_scan % 100
			local found = false
			while index < candidates and ramp_has_room(self) do
				local from
				if nominal_blocked then
					from = 0.0
				else
					from = abs(self.ramp_side) * ((self.ramp_side * side > 0.0) and 1.0 or -1.0)
				end
				local candidate = side * (from + (index + 1) * ramp_side_probe_step * DEG)
				if abs(candidate) > side_max * DEG then
					index = candidates
					break
				end
				if not ramp_blocked_at(self, query, candidate) then
					goal = candidate
					found = true
					break
				end
				index = index + 1
			end
			if found then
				self.ramp_scan = 0
			elseif index >= candidates then
				goal = side * side_max * DEG -- walled in: as wide as it goes, the collision takes over
				self.ramp_scan = self.ramp_scan >= 100 and 0 or 100 -- and the next scan tries the other side
			else
				self.ramp_scan = (self.ramp_scan >= 100 and 100 or 0) + index -- out of rays: the next step goes on from here
				goal = self.ramp_side
			end
		else
			self.ramp_scan = 0
			if self.ramp_side ~= 0.0 then
				-- Clear here. Is it clear at 0 too? Looked at every ramp_probe_period; the slide lets go once that has held for
				-- ramp_side_hold_time.
				if self.ramp_probe_clock >= ramp_probe_period and ramp_has_room(self) then
					self.ramp_probe_clock = 0.0
					self.ramp_zero_clear = not ramp_blocked_at(self, query, 0.0)
				end
				self.ramp_clear_time = self.ramp_zero_clear and (self.ramp_clear_time + dt) or 0.0
				goal = self.ramp_clear_time >= ramp_side_hold_time and 0.0 or self.ramp_side
			else
				self.ramp_clear_time = 0.0
				self.ramp_zero_clear = false
			end
		end
	end
	if snap then
		self.ramp_side = 0.0
		self.ramp_side_rate = 0.0
		return
	end
	local ramp_side = self.ramp_side
	local growing = abs(goal) > abs(ramp_side) or goal * ramp_side < 0.0
	local orbit_radius = max(self.distance_used * cos(self.last_elevation_used), 0.5)
	local max_rate = min((growing and ramp_side_grow_rate or ramp_side_release_rate) * DEG, ramp_side_orbit_speed / orbit_radius)
	local accel = ramp_side_accel * DEG
	local err = goal - ramp_side
	-- The speed that still lets it stop at the goal, within the rate cap; the rate follows it by at most the acceleration.
	local wanted = (err < 0.0 and -1.0 or 1.0) * min(max_rate, sqrt(2.0 * accel * abs(err)))
	-- The swing and the slide together turn the camera round him: that, in metres a second, stays inside orbit_speed_total.
	local net_limit = orbit_speed_total / orbit_radius
	wanted = clamp(wanted, -net_limit - self.swing_rate, net_limit - self.swing_rate)
	local rate = self.ramp_side_rate + clamp(wanted - self.ramp_side_rate, -accel * dt, accel * dt)
	local moved = rate * dt
	if abs(moved) >= abs(err) and moved * err > 0.0 then
		ramp_side = goal
	else
		ramp_side = ramp_side + moved
	end
	self.ramp_side = ramp_side
	if ramp_side == goal then
		rate = 0.0
	end
	self.ramp_side_rate = rate
end

-- Horizontal follow, "Turn with you" (FollowSettings::horizontal, 0-10): ties the camera to the direction you ride. Returns the
-- orbit heading: the rig's own pulled toward `travel + the shot's position heading` by w = horizontal / 10.
local function update_horizontal_follow(self, s, snap, grounded, flat_speed, rig_heading, dt)
	local level = clamp01(self.settings.follow.horizontal / 10.0)
	local v = s.velocity
	local raw_heading = heading_of(vcreate(v.x, 0.0, v.z))
	local position_heading = self.current.position_heading
	if snap then
		local th = flat_speed > follow_min_speed and raw_heading or wrap_angle(rig_heading - position_heading)
		self.travel_heading = th
		self.travel_stage = th
		self.hf_w = level
		self.hf_w_stage = level
	else
		if not (self.hf_w > 0.0) then -- off: start from the camera
			local th = wrap_angle(rig_heading - position_heading)
			self.travel_heading = th
			self.travel_stage = th
		end
		if grounded and flat_speed > follow_min_speed then
			local time = lerp_f(follow_slowest_time, follow_fastest_time, level)
			local rate = ease_rate(0.5 * time, dt)
			local max_turn = lerp_f(follow_slowest_turn, follow_fastest_turn, level) * DEG * dt
			self.travel_stage = blend_angle(self.travel_stage, raw_heading, rate)
			local step = wrap_angle(blend_angle(self.travel_heading, self.travel_stage, rate) - self.travel_heading)
			self.travel_heading = wrap_angle(self.travel_heading + clamp(step, -max_turn, max_turn))
		end
		self.hf_w_stage, self.hf_w = ease2(self.hf_w_stage, self.hf_w, level, follow_ease_time, dt)
	end
	if not (self.hf_w > 0.0) then
		return rig_heading
	end
	return blend_angle(rig_heading, wrap_angle(self.travel_heading + position_heading), self.hf_w)
end

-- ---------------------------------------------------------------- collision

-- One look along the line, shifted by `shift`: how far the camera would have to come in (goal), how high to lift it over a wall
-- inside the personal space (lift), and how far its centre may be (hard). Returns goal, lift, hard.
local function collide_probe(self, query, automatic, radius, pivot, camera, dir, full, floor_d, shift, goal, lift, hard)
	local from, to = pivot + shift, camera + shift
	local centre = cast(self, query, from, to)
	if centre == nil then
		return goal, lift, hard
	end
	local hit_c = vmag(centre - from)
	local room = hit_c - radius
	if automatic then
		-- A thin obstacle (a pole, a rail) passes by: the line counts only when a whisker beside it also meets something no more
		-- than wide_depth beyond.
		local side = normalized(vcross(dir, UP), vcreate(1.0, 0.0, 0.0))
		local counts = false
		for i = 1, 2 do
			local offset = side * ((i == 1 and -1.0 or 1.0) * wide_whisker)
			local beside = cast(self, query, from + offset, to + offset)
			if beside ~= nil then
				local hit_s = vmag(beside - (from + offset))
				if not (hit_s > hit_c + wide_depth) then
					counts = true
					room = min(room, hit_s - whisker_skin)
				end
			end
		end
		-- ... unless the camera is right at it (a pole it would sit inside is an obstacle).
		if not counts and full - hit_c > thin_near_end then
			return goal, lift, hard
		end
	end
	-- The ground or a ledge between him and the camera holds the pull at the riding minimum and the camera rises over it; a wall
	-- keeps the personal space as the floor.
	local floor_here, lift_cap = floor_d, wall_lift_max
	if room < distance_min(self) and room < full and ground_under_hit(self, query, from, centre) then
		floor_here = max(floor_d, distance_min(self))
		lift_cap = ground_lift_max
	end
	goal = max(goal, max(0.0, full - max(room, floor_here)))
	-- Nearer than the floor: stay at it and lift the camera over the obstacle instead.
	lift = max(lift, min(wall_lift_gain * max(0.0, floor_here - room), lift_cap))
	hard = min(hard, max(hit_c - penetration_skin, floor_d))
	return goal, lift, hard
end

-- Camera collision (FullS3). The ray runs from the SKATER's own look point (`pivot`) to the final camera position; the camera
-- sits at pivot + dir * (full - pull) with the pull a critically damped spring. Returns the metres pulled in and the camera.
local function collide(self, query, pivot, camera, root, board, velocity, snap, air, speed)
	local sc = self.settings.collision
	local automatic = sc.automatic
	local src = automatic and AUTO_COLLISION or sc
	local radius, pull_in_time, release_time, ground_clearance = src.radius, src.pull_in_time, src.release_time, src.ground_clearance
	-- Automatic, on the ground: the faster the skater, the quicker the camera lets go once an obstacle is gone.
	local release_speed_factor = 1.0
	if automatic and not air then
		release_speed_factor = clamp(fast_release_speed / max(speed, 0.1), fast_release_floor, 1.0)
	end
	release_time = release_time * release_speed_factor
	self.hard_allowed = 1.0e9
	self.hard_floor_y = -1.0e9
	if not sc.enabled then
		held_reset(self.pull)
		self.coll_lift = 0.0
		self.coll_lift_stage = 0.0
		self.coll_wall = 0.0
		self.coll_wall_stage = 0.0
		return 0.0, camera
	end
	local ray = camera - pivot
	local full = vmag(ray)
	local pull_goal, wall_goal, hard_allowed, floor_d = 0.0, 0.0, 1.0e9, 0.0
	if full > 1e-3 then
		local dir = ray * (1.0 / full)
		-- The floor under the pull: nearer than this to the skater is a camera on his body, whatever the wall says.
		floor_d = max(distance_clear_of(pivot, dir, root, personal_root(self), full), distance_clear_of(pivot, dir, board, personal_board(self), full))
		pull_goal, wall_goal, hard_allowed = collide_probe(self, query, automatic, radius, pivot, camera, dir, full, floor_d, ZERO, pull_goal, wall_goal, hard_allowed)
		-- (Not riding a ramp: the surface rises under the line, and the camera rises with the skater. In the air it is the deck.)
		local ahead = ((self.transition or self.swing) and not air) and ZERO or velocity * coll_lookahead_time
		local ahead_len = vmag(ahead)
		if ahead_len > 0.05 then
			local shift = ahead_len > coll_lookahead_max and ahead * (coll_lookahead_max / ahead_len) or ahead
			pull_goal, wall_goal = collide_probe(self, query, automatic, radius, pivot, camera, dir, full, floor_d, shift, pull_goal, wall_goal, 1.0e9)
		end
	end
	self.coll_blocked = pull_goal > coll_blocked_threshold
	-- In the air the pull eases in over at least air_pull_in_time.
	local in_time = max(pull_in_time, air and air_pull_in_time or min_pull_in_time)
	local out_time = max(release_time, min_pull_out_time)
	local pull_state = self.pull
	if snap then
		held_reset(pull_state, pull_goal)
	else
		-- A big pull takes longer: the peak speed of the spring is omega * distance / e, kept within pull_max_speed.
		local max_speed = (self.transition or self.swing) and ramp_pull_max_speed or pull_max_speed
		local in_scaled = max(in_time, 3.9 * max(0.0, max(pull_goal, pull_state.goal) - pull_state.value) / (2.71828 * max_speed))
		local out_scaled = max(out_time, 3.9 * max(0.0, pull_state.value - min(pull_goal, pull_state.goal)) / (2.71828 * max_speed))
		held_update(pull_state, pull_goal, in_scaled, out_scaled, coll_hold_time * release_speed_factor, coll_hold_hysteresis, fixed_step)
	end
	-- Never closer than the floor (a rig distance already shorter than that is left alone).
	local pull = min(pull_state.value, max(0.0, full - floor_d))
	-- The hard part (an actual penetration) is looked at again after the final limiter (apply_hard_collision).
	self.hard_pivot = pivot
	if full > 1e-3 then
		self.hard_dir = ray * (1.0 / full)
	end
	self.hard_allowed = hard_allowed
	local ly = self.layers
	ly.coll_pivot = pivot
	ly.coll_full = full
	ly.coll_hard = hard_allowed
	ly.coll_floor = floor_d
	ly.coll_goal = pull_state.goal
	if pull > 0.0 then
		camera = pivot + ray * ((full - pull) / max(full, 1e-3))
	end
	-- The lift over a too-close wall: slower in than a pull, so it reads as a swing up.
	if snap then
		self.coll_wall_stage = wall_goal
		self.coll_wall = wall_goal
	else
		self.coll_wall_stage, self.coll_wall = ease2(self.coll_wall_stage, self.coll_wall, wall_goal,
			wall_goal > self.coll_wall_stage and max(in_time, wall_lift_time) or out_time, fixed_step)
	end
	if self.coll_wall > 1e-4 then -- swing up about the pivot (the distance to it is kept), not away from it
		local raised = camera - pivot + vcreate(0.0, self.coll_wall, 0.0)
		camera = pivot + raised * (vmag(camera - pivot) / max(vmag(raised), 1e-3))
	end

	self.ray_parity = not self.ray_parity -- (the shoulder's wall look alternates with this)
	local lift_goal = 0.0
	local floor_hit = cast(self, query, camera + vcreate(0.0, 1.0, 0.0), camera - vcreate(0.0, ground_clearance, 0.0))
	if floor_hit ~= nil then
		lift_goal = max(0.0, floor_hit.y + ground_clearance - camera.y)
		self.hard_floor_y = floor_hit.y
	end
	if snap then
		self.coll_lift_stage = lift_goal
		self.coll_lift = lift_goal
	else
		self.coll_lift_stage, self.coll_lift = ease2(self.coll_lift_stage, self.coll_lift, lift_goal,
			lift_goal > self.coll_lift_stage and in_time or out_time, fixed_step)
	end
	camera = camera + vcreate(0.0, self.coll_lift, 0.0)
	return pull, camera
end

-- The hard part of the collision, on the camera the final limiter has placed: a camera centre behind the surface on the
-- collision line is pulled out within about two frames, and one under the ground is lifted over it at once.
local function apply_hard_collision(self, camera, snap)
	local along = vdot(camera - self.hard_pivot, self.hard_dir)
	local behind = (snap or self.hard_allowed > 1.0e8) and 0.0 or max(0.0, along - self.hard_allowed)
	if snap then
		self.coll_fast = 0.0
	else
		local eased = ease_to(self.coll_fast, behind, behind > self.coll_fast and fast_pull_time or fast_pull_release, fixed_step)
		self.coll_fast = min(eased, self.coll_fast + fast_pull_max_speed * fixed_step) -- quick, but not a jump
	end
	camera = camera - self.hard_dir * self.coll_fast
	-- How far the camera centre is below the ground (and 5 cm).
	local lift_behind = (snap or self.hard_floor_y < -1.0e8) and 0.0 or max(0.0, self.hard_floor_y + 0.05 - camera.y)
	self.coll_lift_fast = ease_to(self.coll_lift_fast, lift_behind, lift_behind > self.coll_lift_fast and 0.004 or fast_pull_release, fixed_step)
	camera = camera + vcreate(0.0, self.coll_lift_fast, 0.0) -- (not rate limited: the camera centre does not go under the ground)
	self.layers.coll_fast = self.coll_fast
	return camera
end

-- The shoulder offset, kept off whatever is beside the camera. A line sideways from the camera before the shoulder, here and
-- where it will be in coll_lookahead_time; a hit takes the offset down to the room there, less the radius.
local function limited_shoulder(self, query, camera, dir, velocity, metres, snap, speed)
	local sc = self.settings.collision
	local wanted = abs(metres)
	local goal = self.shoulder_goal_cached
	if not sc.enabled or wanted <= 0.02 then
		goal = 0.0
		self.shoulder_goal_cached = 0.0
	elseif snap or self.ray_parity then -- (every other step; the goal holds in between)
		local toward = dir * (metres < 0.0 and -1.0 or 1.0)
		local radius = sc.automatic and AUTO_COLLISION.radius or sc.radius
		local ahead = vcreate(velocity.x, 0.0, velocity.z) * coll_lookahead_time
		local ahead_len = vmag(ahead)
		if ahead_len > coll_lookahead_max then
			ahead = ahead * (coll_lookahead_max / ahead_len)
			ahead_len = vmag(ahead)
		end
		local room = wanted
		local count = (ahead_len > 0.05 and not self.transition) and 2 or 1
		for i = 0, count - 1 do
			local from = i == 0 and camera or (camera + ahead)
			local hit = cast(self, query, from, from + toward * (wanted + radius))
			if hit ~= nil then
				room = min(room, max(0.0, vmag(hit - from) - radius))
			end
		end
		goal = wanted - room
		self.shoulder_goal_cached = goal
	end
	local release_factor = sc.automatic and clamp(fast_release_speed / max(speed, 0.1), fast_release_floor, 1.0) or 1.0
	if snap then
		held_reset(self.shoulder_clip, goal)
	else
		held_update(self.shoulder_clip, goal, min_pull_in_time, max(sc.release_time, 0.4) * release_factor, coll_hold_time * release_factor, coll_hold_hysteresis, fixed_step)
	end
	return (metres < 0.0 and -1.0 or 1.0) * max(0.0, wanted - self.shoulder_clip.value)
end

-- ---------------------------------------------------------------- prediction, graph input

-- Ballistic prediction from the surface-level point (position - up * clearance).
local function predict(self, s, query)
	local launch = self.launch
	-- The launch point sits last_clearance (the takeoff clearance) under the root, but never below the ground measured now.
	local gc = s.ground_clearance
	local live_clearance = isfinite(gc) and gc or self.last_clearance
	local surface_y = s.position.y - min(self.last_clearance, max(launch_above_ground, live_clearance - launch_above_ground))
	launch.position = vcreate(s.position.x, surface_y, s.position.z)
	launch.velocity = s.velocity
	launch.launch_normal = self.last_ground_normal
	launch.camera_distance = self.current.distance
	self.prediction = Traj.predict(launch, query, self.settings.trajectory)
	-- Express everything against the takeoff surface.
	self.prediction_offset = surface_y - self.takeoff_surface_y
	self.prediction_time_base = self.air_time
end

local function fill_graph_input(self, s, dt, touchdown, max_height, speed, normal)
	local g = self.graph_in
	g.dt = dt
	g.bailing = s.bailing
	g.air = is_air_state(s.physics_state)
	g.grinding = is_grind_state(s.physics_state)
	g.grind_side = s.grind_side
	g.manual = s.manual
	g.manual_one_shot = active_framing(self).manual_camera
	g.touchdown = touchdown
	g.speed = speed
	g.predicted_max_height = max_height
	g.incline_degrees = incline_of(s, normal)
	return g
end

-- Pan / tilt smoothing from the shot (rig_orientation.rs bind_shot): 1 - (1 - s)^2, then capped. Fills `dst` from `base`.
local function fill_tracker(dst, base, shot_smoothing, set)
	local inverse = 1.0 - clamp(shot_smoothing, 0.0, 1.0)
	local smoothing = clamp01(min(1.0 - inverse * inverse, set.smoothing_cap))
	dst.delta_umbra_degrees = base.delta_umbra_degrees
	dst.delta_penumbra_degrees = base.delta_penumbra_degrees
	dst.speed_clamp_degrees = base.speed_clamp_degrees
	dst.acceleration_min_degrees = base.acceleration_min_degrees
	dst.acceleration_max_degrees = base.acceleration_max_degrees
	dst.smoothing_min = smoothing
	dst.smoothing_max = smoothing
	dst.overshoot_zeroes_velocity = base.overshoot_zeroes_velocity
end

-- ---------------------------------------------------------------- the fixed step

local function step_once(self, s, query, snap)
	local cs = self.settings
	local dt = fixed_step
	self.step_rays = 0
	local phys = s.physics_state
	local air = is_air_state(phys)
	local grounded = not air
	local grinding = is_grind_state(phys)
	local vel = s.velocity
	local normal = normalized(s.ground_normal, UP)
	local clearance_now = clamp(s.ground_clearance, 0.0, 3.0)
	local forward_speed = vdot(vel, normalized(s.forward, FWD))
	local horizontal_speed = sqrt(vel.x * vel.x + vel.z * vel.z)
	-- The camera speed (graph blend, debug): |velocity . forward| on the ground; in the air the last grounded value is held.
	if grounded then
		self.held_speed = abs(forward_speed)
	elseif snap then
		self.held_speed = horizontal_speed
	end
	local speed = self.held_speed
	local rig = self.rig
	local graph = self.graph
	local ly = self.layers

	if snap then
		-- A cut has no previous shot, but the framing below needs this frame's shot: resolve the one the graph would pick first.
		Graph.reset(graph)
		local first = Graph.select(graph, fill_graph_input(self, s, dt, false, 0.0, speed, normal), cs.graph)
		local first_shot, first_blend = first.shot, first.chase_blend
		Graph.reset(graph)
		self.angle = cs.angle
		self.id = first_shot
		self.shots = lookup_shots(first_shot, self.angle)
		blend_shots(self.shots, first_blend, self.leaf)
		framed(self, self.leaf, first_shot, speed)
		copy_shot(self.current, self.leaf)
		copy_shot(self.from, self.leaf)
	end
	local pos = s.position
	local anchor_pt = pos + vcreate(0.0, cs.points.anchor_height - cs.points.board_drop, 0.0) -- the root-based orbit anchor

	-- ---- forward acceleration -> pump / push
	if not self.accel_ready then
		self.prev_forward_speed = forward_speed
		self.accel_filtered = 0.0
		self.prev_accel = 0.0
		self.accel_ready = true
	elseif grounded and self.was_air then
		self.prev_forward_speed = forward_speed
	end
	local raw_accel = grounded and (forward_speed - self.prev_forward_speed) / dt or 0.0
	if grounded then
		self.prev_forward_speed = forward_speed
	end
	local pl = cs.pipeline
	local smoothing_time = pl.accel_smoothing_time
	local blend = smoothing_time > 0.0 and (1.0 - exp(-dt / max(smoothing_time, 1e-6))) or 1.0
	self.accel_filtered = self.accel_filtered + (raw_accel - self.accel_filtered) * blend
	local accel_filtered = self.accel_filtered
	local push_kick = grounded and not grinding and self.prev_accel < pl.push_accel_threshold and accel_filtered >= pl.push_accel_threshold
	self.prev_accel = accel_filtered
	self.push_timer = push_kick and pl.push_window or max(0.0, self.push_timer - dt)
	local push_state = self.push_timer > 0.0
	if not snap then
		self.no_lag_timer = max(0.0, self.no_lag_timer - dt)
	end
	local no_lag = s.bailing or self.no_lag_timer > 0.0

	-- ---- prepare 1: air / landing (before the incline)
	if grounded then
		self.last_clearance = clearance_now
		self.last_ground_normal = normal
	elseif snap then
		self.last_clearance = clearance_now -- reset mid-air: the surface under the skater is the datum
		self.last_ground_normal = normal
	end
	local entered_air = air and (not self.was_air or snap)
	if entered_air then
		self.air_time = 0.0
		self.flight_max_height = 0.0
		self.air_peak_y = pos.y
		self.takeoff_surface_y = pos.y - self.last_clearance
		self.repredict_timer = 0.0
		predict(self, s, query)
	elseif air then
		self.air_time = self.air_time + dt
		self.air_peak_y = max(self.air_peak_y, pos.y)
		self.repredict_timer = self.repredict_timer + dt
		if pl.repredict_interval > 0.0 and self.repredict_timer >= pl.repredict_interval then
			self.repredict_timer = 0.0
			predict(self, s, query)
		end
	end
	local touchdown = not snap and self.was_air and grounded and self.air_time >= cs.graph.landing_min_air_time

	local prediction = self.prediction
	local landed = prediction.status == "Landed"
	local air_in = self.air_in
	air_in.grounded = grounded
	Air.set_prediction(air_in, prediction, self.prediction_offset)
	if air_in.trajectory_valid then
		air_in.trajectory_duration = air_in.trajectory_duration + self.prediction_time_base
	end
	air_in.trajectory_time = self.air_time
	air_in.velocity = vel
	air_in.ground_normal = normal
	air_in.anchor_height = anchor_pt.y
	air_in.follow_anchor_in_air = self.current.follow_subject_in_air
	air_in.snap_height = snap
	if snap then
		Air.reset(self.air, anchor_pt.y, grounded)
	end
	local air_out = Air.update(self.air, dt, air_in, cs.air)
	local held_ref = air_out.reference_height
	-- Landing response (Alpha 5): the strength comes from how far the skater fell plus a little horizontal speed.
	if not snap and self.was_air and grounded then
		self.last_landing_fall = max(0.0, self.air_peak_y - pos.y)
		self.last_landing_fraction = landing_fraction_of(self, self.last_landing_fall, horizontal_speed)
		Shake.landing_impulse_fraction(self.shake, self.last_landing_fraction, cs.shake)
	end
	-- ---- prepare 2: incline (after the landing response has read the previous normal)
	self.incline_degrees = incline_of(s, normal)

	-- ---- graph select. The apex is latched over the flight.
	if air and prediction.status ~= "Invalid" then
		self.flight_max_height = max(self.flight_max_height, prediction.predicted_max_height + self.prediction_offset)
	end
	local max_height = air and self.flight_max_height or 0.0
	local pick = Graph.select(graph, fill_graph_input(self, s, dt, touchdown, max_height, speed, normal), cs.graph)
	local pick_shot, pick_blend, pick_landing = pick.shot, pick.chase_blend, pick.landing_active
	local flight_max_height = self.flight_max_height

	-- ---- air camera (Alpha 4). air_w is the eased "in the air" weight.
	local ac = cs.air_camera
	local rise_goal = 0.0
	if air and ac.rise_degrees > 0.0 then
		local drop_below = landed and -(prediction.predicted_landing_height + self.prediction_offset) or 0.0
		rise_goal = clamp01(max(flight_max_height, drop_below) / max(ac.rise_full_height, 0.1))
	end
	if not snap then
		-- Quick in, slow out.
		local build_time = 0.5 * max(ac.ease_time, min_ease_time)
		local release_time = max(ac.ease_time, min_ease_time)
		local follow_goal = air and 1.0 or 0.0
		self.air_w_stage, self.air_w = ease2(self.air_w_stage, self.air_w, follow_goal, follow_goal > self.air_w_stage and build_time or release_time, dt)
		self.rise_w_stage, self.rise_w = ease2(self.rise_w_stage, self.rise_w, rise_goal, rise_goal > self.rise_w_stage and build_time or release_time, dt)
		-- The big-air room (below, at the distance): only for a big air, whatever the rise is set to.
		local room_goal = 0.0
		if air then
			local drop_below = landed and -(prediction.predicted_landing_height + self.prediction_offset) or 0.0
			room_goal = clamp01((max(flight_max_height, drop_below) - big_air_from) / (big_air_full - big_air_from))
		end
		self.air_room_w_stage, self.air_room_w = ease2(self.air_room_w_stage, self.air_room_w, room_goal, room_goal > self.air_room_w_stage and build_time or release_time, dt)
		-- The keep-in-frame weight: a big air, a ramp (the transition, last step's), and an air taken off a steep ramp.
		local ramp_air = air and self.last_ground_normal.y < keep_ramp_normal_y
		local keep_goal = max(room_goal, self.transition and 1.0 or 0.0, ramp_air and 1.0 or 0.0)
		self.keep_w_stage, self.keep_w = ease2(self.keep_w_stage, self.keep_w, keep_goal, keep_goal > self.keep_w_stage and keep_in_time or release_time, dt)
	end
	local rise_rad = self.rise_w * ac.rise_degrees * DEG
	-- In the air, and while the air weight is still easing out after a landing (the collision's air rules).
	local in_air_layer = air or self.air_w > 0.02
	local keep_lead = vel * (1.0 * dt) + vcreate(0.0, min(vel.y, 0.0) * dt, 0.0)
	local ref_y = held_ref + ac.follow_height * self.air_w * (anchor_pt.y - held_ref)

	-- ---- shot blend (previous = interpolated at the change, eased by elapsed / duration)
	local changed = snap or pick_shot ~= self.id or cs.angle ~= self.angle
	-- Leaving a manual / grind close-up for any other kind of shot: a longer transition (and an eased distance).
	local leaving_closeup = changed and not snap and closeup_kind(self.id) ~= 0 and closeup_kind(pick_shot) ~= closeup_kind(self.id)
	if changed then
		self.shots = lookup_shots(pick_shot, cs.angle) -- cached until the selection changes
	end
	-- The player's framing is part of the resolved shot, every step.
	local leaf = self.leaf
	blend_shots(self.shots, pick_blend, leaf)
	framed(self, leaf, pick_shot, speed)
	local current = self.current
	if changed then
		self.chase_lens = chase_lens_of[cs.angle]
		if snap then
			copy_shot(self.from, leaf)
			self.limits_from.min, self.limits_from.max = active_limits(self)
		else
			copy_shot(self.from, current)
			self.limits_from.min, self.limits_from.max = self.limits.min, self.limits.max
		end
		self.shot_elapsed = 0.0
		self.shot_duration = snap and 0.0 or ease_time(self, Graph.transition_time(cs.graph, pick_shot))
		if leaving_closeup then
			self.shot_duration = exit_time(self) -- the player's ease-out time
			self.exit_active = true
			self.exit_start_distance = self.distance_used -- continuous with the camera's last distance
			self.exit_elapsed = 0.0
			self.exit_duration = self.shot_duration
		end
		-- Back into a close-up (from a shot of another kind) while the way out of the last one still runs: that exit is over.
		if not snap and self.exit_active and not leaving_closeup and closeup_kind(pick_shot) ~= 0 then
			self.exit_active = false
			self.exit_blend = 1.0
			Rig.reset_distance(rig, self.distance_used)
			self.from.distance = self.distance_used
		end
		if snap then
			self.exit_active = false
		end
		self.id = pick_shot
		self.angle = cs.angle
	end
	self.shot_elapsed = self.shot_elapsed + dt
	local shot_fraction = self.shot_duration <= 0.0 and 1.0 or clamp01(self.shot_elapsed / max(self.shot_duration, 1e-6))
	self.shot_fraction = shot_fraction
	Shots.interpolate(self.from, leaf, shot_fraction, current)
	current.position_heading = blend_angle(self.from.position_heading, leaf.position_heading, sine_blend(shot_fraction))
	-- The distance limits follow the angle with the shot, no faster than the rig's distance tracker (limits_rate).
	local lmin, lmax = active_limits(self)
	local lf = self.limits_from
	local sb = sine_blend(shot_fraction)
	local wanted_min = lerp_f(lf.min, lmin, sb)
	local wanted_max = lerp_f(lf.max, lmax, sb)
	local limits = self.limits
	if snap then
		limits.min = wanted_min
		limits.max = wanted_max
	else
		limits.min = limits.min + clamp(wanted_min - limits.min, -limits_rate * dt, limits_rate * dt)
		limits.max = limits.max + clamp(wanted_max - limits.max, -limits_rate * dt, limits_rate * dt)
	end

	-- ---- board anchoring (Alpha 6): in manuals and grinds the real board point replaces the root-based estimate.
	local board_estimate = pos + vcreate(0.0, -cs.points.board_drop, 0.0)
	-- The board's offset ALONG its length (the skater's forward) is dropped.
	local board_rel_raw = (s.board_valid and s.board_position or board_estimate) - pos
	do
		local fwd = s.forward
		local flat = sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
		if flat > 1e-4 then
			local fx, fz = fwd.x / flat, fwd.z / flat
			local along = board_rel_raw.x * fx + board_rel_raw.z * fz
			board_rel_raw = vcreate(board_rel_raw.x - along * fx, board_rel_raw.y, board_rel_raw.z - along * fz)
		end
	end
	local board_wanted = cs.look.board_anchor and closeup_kind(pick_shot) ~= 0
	if snap then
		self.board_rel = board_rel_raw
		self.board_rel_stage = board_rel_raw
	elseif board_wanted then
		self.board_rel_stage, self.board_rel = ease2(self.board_rel_stage, self.board_rel, board_rel_raw, board_smooth_time, dt)
	end
	local board_real = pos + self.board_rel
	local board_goal = board_wanted and 1.0 or 0.0
	if snap then
		self.board_w = board_goal
		self.board_w_stage = board_goal
	else
		self.board_w_stage, self.board_w = ease2(self.board_w_stage, self.board_w, board_goal,
			board_goal > self.board_w_stage and enter_time(self) or exit_time(self) * 0.5, dt)
	end
	local board_w = self.board_w
	local board_point = board_estimate + (board_real - board_estimate) * board_w
	-- The Trajectory point's lead along the ballistic arc comes in at the take-off and goes at the landing through the look's ease.
	do
		local t = cs.points.trajectory_lookahead
		local arc_goal = ZERO
		if air then
			arc_goal = vcreate(vel.x * t, vel.y * t - 0.5 * cs.trajectory.gravity * t * t, vel.z * t)
		end
		if snap then
			self.trajectory_arc = arc_goal
			self.trajectory_arc_stage = arc_goal
		else
			self.trajectory_arc_stage, self.trajectory_arc = ease2(self.trajectory_arc_stage, self.trajectory_arc, arc_goal, response_time(self), dt)
		end
	end
	-- The ten reference points (Head, Hips, Grind, COM, Board, Trajectory, Anchor, Feet, DampedCOM, unnamed).
	local points = self.points
	local trajectory_point = board_point + self.trajectory_arc
	local com = pos + vcreate(0.0, cs.points.com_height, 0.0)
	points[1] = pos + vcreate(0.0, cs.points.head_height, 0.0)
	points[2] = pos
	points[3] = board_point
	points[4] = com
	points[5] = board_point
	points[6] = trajectory_point
	points[7] = pos
	points[8] = board_point
	points[9] = com
	points[10] = pos
	ly.board_target = board_point
	-- The rig's anchor: the board + a small fixed height (blended from the root-based one).
	local rig_point = anchor_pt + (board_real + vcreate(0.0, board_anchor_height, 0.0) - anchor_pt) * board_w
	local rig_ref_y = ref_y + (rig_point.y - anchor_pt.y)
	-- reference_now: the weighted mean of the points with the blended weights (the board if the weights vanish): framing only.
	local reference_now
	do
		local weights = current.reference_weights
		local sum, total = ZERO, 0.0
		for i = 1, 10 do
			local w = weights[i]
			if w > 0.0 then
				sum = sum + points[i] * w
				total = total + w
			end
		end
		reference_now = total > 1e-4 and sum * (1.0 / total) or points[5]
	end

	-- Manual / grind focus: eased with the shot transition, then with the look response time if a setting moves.
	local focus_goal = focus_of(self, pick_shot)
	if snap then
		self.focus_value = focus_goal
		self.focus_from = focus_goal
	else
		if changed then
			self.focus_from = self.focus_value
		end
		if shot_fraction < 1.0 then
			self.focus_value = lerp_f(self.focus_from, focus_goal, sine_blend(shot_fraction))
		else
			self.focus_value = ease_to(self.focus_value, focus_goal, response_time(self), dt)
		end
	end

	-- ---- FOV extras: shot, speed and air terms, eased by one exponential filter.
	local fv = cs.fov
	local fov_target = 0.0
	if fv.shot_fov then
		fov_target = fov_target + lens_field_of_view_degrees(current.lens_length, self.aspect) - lens_field_of_view_degrees(self.chase_lens, self.aspect)
	end
	if fv.speed_fov then
		fov_target = fov_target + fv.speed_fov_degrees * clamp01((horizontal_speed - fv.speed_fov_min) / max(fv.speed_fov_max - fv.speed_fov_min, 1e-3))
	end
	if fv.air_fov and air then
		fov_target = fov_target + fv.air_fov_degrees * clamp01(flight_max_height / max(fv.air_fov_full_height, 1e-3))
	end
	if not snap then
		self.fov_extra_stage, self.fov_extra = ease2(self.fov_extra_stage, self.fov_extra, fov_target, fv.smoothing_time, dt)
	end

	-- ---- Fixed distance keeps its zoom: the base is the game's resting lens, taken only while he is slow on the ground.
	local ebf = self.extras_base_fov
	if isfinite(ebf) and ebf > 0.0 then
		if snap or not self.rest_fov_valid then
			self.rest_fov = ebf
			self.rest_fov_stage = ebf
			self.rest_fov_target = ebf
			self.rest_fov_valid = true
		else
			if grounded and horizontal_speed < rest_fov_max_speed then
				self.rest_fov_target = ebf
			end
			self.rest_fov_stage, self.rest_fov = ease2(self.rest_fov_stage, self.rest_fov, self.rest_fov_target, rest_fov_ease_time, dt)
		end
	end
	local rest_goal = active_ride(self).mode == FIXED and 1.0 or 0.0
	if snap then
		self.rest_fov_w = rest_goal
		self.rest_fov_w_stage = rest_goal
	else
		self.rest_fov_w_stage, self.rest_fov_w = ease2(self.rest_fov_w_stage, self.rest_fov_w, rest_goal, rest_fov_ease_time, dt)
	end

	-- ---- shoulder side: a sine ease over switch_time from wherever the side value is now.
	local sh_set = cs.shoulder
	local side_target = 0.0
	if sh_set.mode == SHOULDER_MANUAL then
		side_target = sh_set.side
	elseif sh_set.mode == SHOULDER_AUTO then
		side_target = (sh_set.goofy ~= s.switch_stance) and -1.0 or 1.0
	end
	if snap then
		self.shoulder_value = side_target
		self.shoulder_start = side_target
		self.shoulder_target = side_target
		self.shoulder_elapsed = sh_set.switch_time
	else
		if side_target ~= self.shoulder_target then
			self.shoulder_start = self.shoulder_value
			self.shoulder_target = side_target
			self.shoulder_elapsed = 0.0
		end
		self.shoulder_elapsed = self.shoulder_elapsed + dt
		local slide = sh_set.switch_time > 1e-4 and clamp01(self.shoulder_elapsed / max(sh_set.switch_time, 1e-4)) or 1.0
		self.shoulder_value = self.shoulder_start + (self.shoulder_target - self.shoulder_start) * sine_blend(slide)
	end
	local shoulder_metres = self.shoulder_value * sh_set.offset

	-- ---- rig, orientation and framing
	local out = self.out
	out.pos = ZERO
	out.yaw = 0.0
	out.pitch = 0.0
	out.roll = 0.0
	out.localpos = ZERO
	out.anchor = ZERO
	out.skater_anchor = ZERO
	out.subject = pos
	local roll_step = min(1.0, cs.orientation.roll_response * dt)

	-- Follow strength: k scales the shot's smoothing (s -> s^k) and shortens the anchor lag. Boosted with speed when follow.dynamic.
	local fo = cs.follow
	local follow_k = clamp(fo.strength + (fo.dynamic and fo.dynamic_boost * clamp01(horizontal_speed / max(fo.dynamic_speed, 0.5)) or 0.0), 0.2, 7.0)

	local ri = self.rig_in
	local ria = ri.anchor
	ria.position = rig_point
	ria.reference_height = rig_ref_y
	ria.velocity = vel
	ria.push_state = push_state
	ria.push_kick = push_kick
	ria.pump_acceleration = accel_filtered
	ria.no_lag = no_lag
	update_transition(self, snap, grounded, normal, vel, dt)
	local ric = ri.compass
	ric.hold = self.transition_hold
	ric.position = pos
	ric.forward = s.forward
	local flat_velocity = vcreate(vel.x, 0.0, vel.z)
	ric.grind_direction = horizontal_speed > 0.5 and normalized(flat_velocity, s.forward) or s.forward
	ric.grinding = grinding
	ric.wiping_out = s.bailing
	ric.crouching = phys == PS_CROUCH
	ri.heading_from_compass = true
	ri.shot_heading = current.position_heading
	local cur_smoothing = current.smoothing
	ri.heading_smoothing = clamp01(cur_smoothing[1]) ^ follow_k -- manager_rig.rs bind_shot: direction smoothing
	ri.elevation_target = current.position_elevation
	ri.elevation_smoothing = clamp01(cur_smoothing[2]) ^ follow_k -- and elevation smoothing
	local rid = ri.distance
	rid.target = current.distance
	rid.fast = air or pick_landing or s.bailing
	rid.wipeout = s.bailing
	rid.snap = snap
	if snap then
		Rig.reset(rig, ri, cs.rig)
	end
	local rig_out = Rig.update(rig, dt, ri, cs.rig)
	local rig_anchor = rig_out.anchor
	local rig_heading, rig_elevation, rig_distance = rig_out.heading, rig_out.elevation, rig_out.distance

	-- Anchor lag / follow_k, on the OUTPUT only. Only X and Z are scaled. In a transition the anchor lag is cut (eased).
	local follow_inverse = (1.0 - transition_lag_cut * self.transition_w) / max(follow_k, 0.2)
	rig_anchor = vcreate(rig_point.x + (rig_anchor.x - rig_point.x) * follow_inverse, rig_anchor.y,
		rig_point.z + (rig_anchor.z - rig_point.z) * follow_inverse)
	self.last_rig_anchor_lag = vmag(vcreate(rig_point.x, rig_ref_y, rig_point.z) - rig_anchor)
	self.last_rig_heading = rig_heading
	self.last_rig_elevation = rig_elevation
	self.last_rig_distance = rig_distance

	-- Trick yaw: orbit the anchor by the swing angle. Horizontal follow: the orbit heading is pulled onto the (filtered) travel
	-- heading, the trick yaw goes on top.
	local swinging = self.swing -- the swing may end this step; it still moves the camera this one
	local follow_heading = apply_swing(self, snap, update_horizontal_follow(self, s, snap, grounded and not self.transition_hold, horizontal_speed, rig_heading, dt), vel, dt)
	local look_base = reference_now + vcreate(0.0, current.board_offset, 0.0)
	update_trick_yaw(self, query, s, snap, dt, look_base, follow_heading, shoulder_metres)
	local trick_value = self.trick_yaw.value
	-- Ramps: slide the camera round to the side until the line to it is clear.
	update_ramp_side(self, query, snap, look_base, pos, air, rig_anchor, follow_heading - trick_value, dt)
	local ramp_side = self.ramp_side
	local heading_used = follow_heading + ramp_side - trick_value
	self.last_view_heading = follow_heading
	local orbit_rate = snap and 0.0 or abs(wrap_angle(follow_heading + ramp_side - self.prev_heading_used)) / dt -- without the trick yaw
	self.prev_heading_used = follow_heading + ramp_side
	-- The big-air rise rides on the rig's tracked elevation; the framing height is an eased offset after the tracker.
	local height_goal = height_goal_of(self, pick_shot)
	if snap then
		self.height_off = height_goal
		self.height_stage = height_goal
	else
		self.height_stage, self.height_off = ease2(self.height_stage, self.height_off, height_goal, height_ease_time, dt)
	end
	-- The framing pitch (look.response_time ease). With board anchoring it is measured around the board.
	local framing_pitch_goal = pitch_goal_of(self, pick_shot)
	if snap then
		self.framing_pitch = framing_pitch_goal
	else
		self.framing_pitch = ease_to(self.framing_pitch, framing_pitch_goal, response_time(self), dt)
	end
	local framing_pitch = self.framing_pitch
	-- Riding downhill: the camera rises until it is above the slope behind him, eased in and out.
	local base_elevation = rig_elevation + rise_rad + self.height_off - board_w * framing_pitch
	local grade_used
	if self.transition then
		grade_used = self.downhill_rise and self.downhill_grade or 0.0
	else
		grade_used = self.hill_grade
	end
	local lift_goal = 0.0
	if grade_used > 0.0 then
		lift_goal = clamp(grade_used + downhill_lift_margin * DEG - base_elevation, 0.0, downhill_lift_max * DEG)
	end
	if snap then
		self.downhill_lift = lift_goal
		self.downhill_lift_stage = lift_goal
	else
		self.downhill_lift_stage, self.downhill_lift = ease2(self.downhill_lift_stage, self.downhill_lift, lift_goal, downhill_lift_time, dt)
	end
	local elevation_used = clamp(base_elevation + self.downhill_lift, -85.0 * DEG, 85.0 * DEG)
	self.last_elevation_used = elevation_used
	-- Leaving a manual / grind close-up: the distance follows a sine ease over the player's ease-out time.
	local distance_now = rig_distance
	if self.exit_active and not snap then
		self.exit_elapsed = self.exit_elapsed + dt
		local exit_fraction = clamp01(self.exit_elapsed / max(self.exit_duration, 1e-3))
		distance_now = lerp_f(self.exit_start_distance, current.distance, sine_blend(exit_fraction))
		self.exit_blend = exit_fraction
		if exit_fraction >= 1.0 then
			self.exit_active = false
			Rig.reset_distance(rig, distance_now)
		end
	else
		self.exit_blend = 1.0
	end
	-- One distance rule (Alpha 6): the orbit distance is held inside the angle's DistanceLimits here.
	local dmin = distance_min(self)
	distance_now = clamp(distance_now, dmin, max(distance_max(self), dmin))
	-- Big-air room: in a big air the camera goes out to the distance at which he fits.
	local floor_w = self.floor_w
	local room_w = self.air_room_w * (1.0 - floor_w)
	local room_goal = 0.0
	if room_w > 0.0 then
		local riding_max = max(distance_max(self), dmin)
		local table_air = air_big_distance[cs.angle]
		local fit = min(air_fit_distance(self), max(riding_max, table_air))
		if fit > distance_now then
			room_goal = room_w * (fit - distance_now)
		end
	end
	if snap then
		self.air_room_extra = room_goal
	else
		self.air_room_extra = self.air_room_extra + clamp(room_goal - self.air_room_extra, -big_air_room_rate * dt, big_air_room_rate * dt)
	end
	distance_now = distance_now + self.air_room_extra
	self.air_room_max = self.air_room_extra > 0.0 and max(max(distance_max(self), dmin), distance_now) or 0.0
	self.distance_used = distance_now
	local cos_e, sin_e = cos(elevation_used), sin(elevation_used)
	local offset_dir = vcreate(-sin(heading_used), 0.0, cos(heading_used))
	local camera = rig_anchor + offset_dir * (distance_now * cos_e) + vcreate(0.0, distance_now * sin_e, 0.0)
	-- Only while the ground under the skater is measured.
	if pl.floor_clearance > 0.0 and s.ground_clearance < 3.0 then
		camera = vcreate(camera.x, max(camera.y, pos.y - clearance_now + pl.floor_clearance), camera.z)
	end
	-- Manuals and grinds: the camera stays at least manual_grind_min_height above the board.
	local floor_goal = closeup_kind(pick_shot) ~= 0 and 1.0 or 0.0
	if snap then
		self.floor_w = floor_goal
		self.floor_w_stage = floor_goal
	else
		self.floor_w_stage, self.floor_w = ease2(self.floor_w_stage, self.floor_w, floor_goal,
			floor_goal > self.floor_w_stage and enter_time(self) or exit_time(self) * floor_out_share, dt)
	end
	floor_w = self.floor_w
	camera = camera + vcreate(0.0, floor_w * max(0.0, board_point.y + manual_grind_min_height - camera.y), 0.0)

	-- ---- look target. a) landing look.
	local lk = cs.look
	local landing_known = air and landed
	local landing_goal = 0.0
	if landing_known then
		local predicted_point = prediction.landing_position + vcreate(0.0, self.last_clearance - cs.points.board_drop, 0.0)
		if self.landing_w < 0.01 or snap then
			self.landing_point = predicted_point
			self.landing_point_stage = predicted_point
		else
			self.landing_point_stage, self.landing_point = ease2(self.landing_point_stage, self.landing_point, predicted_point, response_time(self), dt)
		end
		local drop = prediction.predicted_landing_height + self.prediction_offset
		if lk.landing_look and drop < 0.0 then
			landing_goal = lk.landing_look_strength * clamp01(-drop / max(lk.landing_look_full_drop, 0.1))
		end
	end
	-- b) slope look: on the ground the pitch follows the incline (+ uphill, so downhill looks down).
	local slope_goal = (lk.slope_look and grounded) and lk.slope_look_strength * self.incline_degrees * DEG or 0.0
	if not snap then
		self.landing_w_stage, self.landing_w = ease2(self.landing_w_stage, self.landing_w, landing_goal, response_time(self), dt)
		self.look_pitch_stage, self.look_pitch = ease2(self.look_pitch_stage, self.look_pitch, slope_goal, response_time(self), dt)
	end
	local focused_base = self.focus_value >= 1.0 and look_base or (board_point + (look_base - board_point) * self.focus_value)
	local look_target = focused_base + (self.landing_point - focused_base) * self.landing_w
	-- c) vertical follow
	local held_y = ref_y
	look_target = vcreate(look_target.x, held_y + lk.vertical_follow * (look_target.y - held_y), look_target.z)

	-- ---- shoulder: slide the camera along its own right.
	local to_pre = look_target - camera
	local yaw_pre = self.pan.position
	if to_pre.x * to_pre.x + to_pre.z * to_pre.z > 1e-8 then
		yaw_pre = atan2(-to_pre.x, to_pre.z)
	end
	local framing3 = current.framing
	local yaw_now = snap and wrap_angle(yaw_pre + framing3[2]) or self.pan.position
	local shoulder_dir = vcreate(-cos(yaw_now), 0.0, -sin(yaw_now))
	local shift = shoulder_dir * limited_shoulder(self, query, camera, shoulder_dir, vel, shoulder_metres, snap, horizontal_speed)
	camera = camera + shift
	-- Fixed distance: measured from the skater's own anchor, at the distance the orbit uses.
	local fixed_goal = active_ride(self).mode == FIXED and 1.0 or 0.0
	if snap then
		self.fixed_w = fixed_goal
		self.fixed_w_stage = fixed_goal
	else
		self.fixed_w_stage, self.fixed_w = ease2(self.fixed_w_stage, self.fixed_w, fixed_goal, fixed_ease_time, dt)
	end
	local fixed_w = self.fixed_w * (1.0 - floor_w)
	if fixed_w > 0.0 then
		local own = vcreate(rig_point.x, rig_anchor.y, rig_point.z)
		local off = camera - own
		local span = vmag(off)
		local dir = span > 1e-4 and off * (1.0 / span) or offset_dir
		camera = camera + (own + dir * self.distance_used - camera) * fixed_w
	end
	camera = limiter_update(self.ramp_limit, camera, pos, snap, self.transition or self.swing, rel_max_speed, rel_accel, fixed_step, rel_max_orbit)

	-- ---- collision
	local free_camera = camera
	self.last_shift = shift
	self.orbit_reach = sqrt(self.distance_used * self.distance_used + vdot(shift, shift))
	local pulled
	pulled, camera = collide(self, query, look_base, camera, pos, board_point, vel, snap, in_air_layer, horizontal_speed)
	camera = clamp_distance(self, camera, rig_anchor, offset_dir)
	-- On the ground the maximum also holds from the skater's own anchor.
	local skater_anchor = vcreate(rig_point.x, rig_anchor.y, rig_point.z)
	do
		local held = clamp_distance(self, camera, skater_anchor, offset_dir)
		local cut = held - camera
		local cut_len = vmag(cut)
		local excess = cut_len * (1.0 - self.air_w)
		if snap then
			self.rider_hold = excess
		else
			self.rider_hold = self.rider_hold + clamp(excess - self.rider_hold, -rider_hold_rate * dt, rider_hold_rate * dt)
		end
		local toward = cut_len > 1e-4 and cut * (1.0 / cut_len) or normalized(skater_anchor - camera, ZERO)
		camera = camera + toward * self.rider_hold
	end
	camera = apply_hard_collision(self, camera, snap)
	-- The lifts and the maximum above can still bring the camera a few cm inside the personal space: pushed out radially.
	camera = keep_out_of(camera, pos, min(personal_root(self) + personal_margin, vmag(free_camera - pos)))
	camera = keep_out_of(camera, board_point, min(personal_board(self) + personal_margin, vmag(free_camera - board_point)))

	-- Look at the actual reference point (not the lagged anchor). The up-tilt is capped (frame_composer.rs).
	local to_ref = look_target + shift - camera
	local to_len = vmag(to_ref)
	local pan, tilt = self.pan, self.tilt
	local yaw_target = pan.position
	local pitch_target = tilt.position
	if to_len > 1e-4 then
		local horizontal = sqrt(to_ref.x * to_ref.x + to_ref.z * to_ref.z)
		if horizontal > 1e-4 then
			yaw_target = atan2(-to_ref.x, to_ref.z)
		end
		local ceiling = sin(cs.orientation.max_pitch_degrees * DEG)
		pitch_target = asin(min(to_ref.y / max(to_len, 1e-4), ceiling))
	end
	yaw_target = wrap_angle(yaw_target + framing3[2])
	-- The player's pitch offset goes in after the look offsets and before the clamp; Low and High each have their own pitch.
	local view_pitch_offset = (1.0 - board_w) * framing_pitch
	pitch_target = clamp(pitch_target + framing3[3] + self.look_pitch + view_pitch_offset, -89.0 * DEG, 89.0 * DEG)
	-- Manuals and grinds never look up: the pitch above the player's own offset is taken off by the floor's eased weight.
	pitch_target = pitch_target - floor_w * max(0.0, pitch_target - max(view_pitch_offset, 0.0))
	if snap then
		T.angle_reset(pan, yaw_target)
		T.angle_reset(tilt, pitch_target)
		self.roll = framing3[1]
	else
		-- In any fast orbit round the skater the lazy pan would trail the orbit, so it takes the aim directly (not while he is
		-- almost straight above the camera).
		local fast_orbit = (swinging or ramp_side ~= 0.0 or orbit_rate > pan_lock_rate * DEG)
			and sqrt(to_ref.x * to_ref.x + to_ref.z * to_ref.z) > pan_lock_min_span
		local pan_set = self.pan_set
		fill_tracker(pan_set, cs.orientation.pan, clamp01(cur_smoothing[3]) ^ follow_k, cs.orientation)
		if fast_orbit then
			pan_set.smoothing_min = 0.0
			pan_set.smoothing_max = 0.0
			pan_set.acceleration_min_degrees = aim_fast_acceleration
			pan_set.acceleration_max_degrees = aim_fast_acceleration
			pan_set.delta_umbra_degrees = 0.0
			pan_set.delta_penumbra_degrees = max(pan_set.delta_penumbra_degrees, 1.0)
		end
		pan_set.speed_clamp_degrees = min(pan_set.speed_clamp_degrees, aim_max_yaw_rate)
		-- (And while it follows an orbit, no faster than that orbit plus a margin.)
		if fast_orbit then
			local ramp_orbit = swinging or ramp_side ~= 0.0
			pan_set.speed_clamp_degrees = min(pan_set.speed_clamp_degrees, ramp_orbit and (orbit_rate / DEG * 1.25 + 140.0) or (orbit_rate / DEG + 35.0))
		end
		local tilt_set = self.tilt_set
		fill_tracker(tilt_set, cs.orientation.tilt, clamp01(cur_smoothing[4]) ^ follow_k, cs.orientation)
		tilt_set.speed_clamp_degrees = min(tilt_set.speed_clamp_degrees, aim_max_pitch_rate)
		T.angle_update(pan, yaw_target, dt, pan_set)
		T.angle_update(tilt, pitch_target, dt, tilt_set)
		self.roll = self.roll + (framing3[1] - self.roll) * roll_step
	end
	-- Keep the skater in the vertical view in the air, and on a ramp. The head too.
	local kp = self.keep_points
	kp[1] = look_base + keep_lead
	kp[2] = board_point + keep_lead
	kp[3] = pos + keep_lead
	kp[4] = pos + vcreate(0.0, big_air_head, 0.0) + keep_lead
	local keep_w = self.keep_w * (1.0 - floor_w)
	local keep_pitch = update_keep_in_frame(self, camera, tilt.position + self.last_shake_pitch, kp, 4, 3, keep_w, snap)
	out.pos = camera
	out.yaw = pan.position
	out.pitch = tilt.position + keep_pitch
	out.roll = self.roll
	ly.look_target = look_target
	ly.keep_weight = keep_w
	ly.camera_free = free_camera
	out.anchor = rig_anchor
	out.skater_anchor = skater_anchor
	local shake_distance = vmag(camera - rig_anchor)
	ly.collision_pull = pulled
	out.shoulder = shoulder_metres
	out.fov_extra = self.fov_extra
	ly.landing_look_weight = self.landing_w
	ly.look_pitch_offset = self.look_pitch
	ly.follow_strength = follow_k
	ly.trick_yaw = self.trick_yaw.value
	ly.air_follow_weight = self.air_w
	ly.air_reference_height = ref_y
	ly.air_rise = rise_rad
	ly.keep_pitch_offset = self.keep_off
	ly.focus_weight = self.focus_value
	ly.follow_weight = self.hf_w
	ly.floor_weight = floor_w
	ly.height_offset = self.height_off
	ly.board_weight = board_w

	-- ---- shake. Speed shake: the rumble is rebuilt per step from a copy of the settings.
	local shake_cfg = self.shake_cfg
	local base_shake = cs.shake
	shake_cfg.amplitude_min = base_shake.amplitude_min
	shake_cfg.amplitude_max = base_shake.amplitude_max
	shake_cfg.amplitude_top_speed = base_shake.amplitude_top_speed
	shake_cfg.frequency_top_speed = base_shake.frequency_top_speed
	local rumble = cs.speed_shake
	if not rumble.enabled then
		shake_cfg.amplitude_min = 0.0
		shake_cfg.amplitude_max = 0.0
	else
		local downhill = 1.0
		if rumble.downhill_boost and self.incline_degrees < 0.0 then
			downhill = 1.0 + (rumble.downhill_scale - 1.0) * clamp01(-self.incline_degrees / max(rumble.downhill_full_degrees, 1.0))
		end
		shake_cfg.amplitude_max = shake_cfg.amplitude_max * rumble.strength * downhill
		shake_cfg.amplitude_top_speed = rumble.top_speed
		shake_cfg.frequency_top_speed = rumble.top_speed
	end
	local shake_on = cs.shake_enabled
	local sh = Shake.update(self.shake, dt, horizontal_speed, shake_distance * pl.shake_distance_scale, shake_on and not s.bailing, shake_cfg)
	out.yaw = out.yaw + sh.yaw
	out.pitch = out.pitch + sh.pitch
	self.last_shake_pitch = sh.pitch -- the next step's keep-in-frame counts it (the shake is computed after)
	out.roll = out.roll + sh.roll
	out.localpos = sh.translation

	-- ---- write (a non-finite step is dropped: the previous output stays)
	self.was_air = air
	self.last_pick_chase_blend = pick_blend
	self.last_pick_landing_active = pick_landing
	self.last_speed = speed
	self.last_push_state = push_state
	self.last_push_kick = push_kick
	self.kick_in_update = self.kick_in_update or push_kick
	self.last_hold = ref_y - anchor_pt.y
	if step_out_finite(out) then
		local old_prev = self.prev_out
		self.prev_out = self.curr_out
		self.curr_out = out
		self.out = old_prev
	end
	self.update_rays = self.update_rays + self.step_rays
	self.update_rays_max = max(self.update_rays_max, self.step_rays)
end

-- Camera cut: every tracker lands on this frame's targets with zero velocity, shake and dip clear.
local function cut_to(self, s, query)
	copy_snapshot(self.cur_snap, s)
	self.acc = 0.0
	Graph.reset(self.graph)
	Shake.reset(self.shake)
	self.accel_ready = false
	self.accel_filtered = 0.0
	self.prev_accel = 0.0
	self.push_timer = 0.0
	self.was_air = false
	self.air_time = 0.0
	self.prediction = EMPTY_PREDICTION
	-- Layers: the FOV extras and look offsets restart from 0 and ease in; the shoulder side and the collision state land on this
	-- frame's targets.
	self.fov_extra = 0.0
	self.landing_w = 0.0
	self.look_pitch = 0.0
	self.air_w = 0.0
	self.rise_w = 0.0
	self.keep_off = 0.0
	self.keep_rate = 0.0
	self.framing_pitch = 0.0
	self.last_shake_pitch = 0.0
	self.fov_extra_stage = 0.0
	self.landing_w_stage = 0.0
	self.look_pitch_stage = 0.0
	self.air_w_stage = 0.0
	self.rise_w_stage = 0.0
	self.air_room_w = 0.0
	self.air_room_w_stage = 0.0
	self.air_room_max = 0.0
	self.air_room_extra = 0.0
	self.keep_w = 0.0
	self.keep_w_stage = 0.0
	self.landing_point_stage = self.landing_point
	held_reset(self.pull)
	held_reset(self.shoulder_clip)
	self.coll_fast = 0.0
	self.coll_lift = 0.0
	self.coll_lift_stage = 0.0
	self.coll_lift_fast = 0.0
	self.coll_wall = 0.0
	self.coll_wall_stage = 0.0
	trick_yaw_reset(self.trick_yaw)
	self.hf_w = 0.0
	self.hf_w_stage = 0.0
	self.travel_heading = 0.0
	self.travel_stage = 0.0
	self.exit_active = false
	self.exit_blend = 1.0
	self.transition = false
	self.transition_w = 0.0
	self.transition_w_stage = 0.0
	self.transition_shallow = 0.0
	self.ramp_space_w = 0.0
	self.transition_hold = false
	self.swing = false
	self.transition_up_seen = false
	self.downhill_grade = 0.0
	self.downhill_lift = 0.0
	self.downhill_lift_stage = 0.0
	self.downhill_time = 0.0
	self.hill_grade = 0.0
	self.transition_from_hill = false
	self.downhill_rise = false
	self.fixed_w = 0.0
	self.fixed_w_stage = 0.0
	self.rider_hold = 0.0
	self.rest_fov = 0.0
	self.rest_fov_stage = 0.0
	self.rest_fov_target = 0.0
	self.rest_fov_w = 0.0
	self.rest_fov_w_stage = 0.0
	self.rest_fov_valid = false
	self.swing_dir = 0.0
	self.ramp_side = 0.0
	self.ramp_clear_time = 0.0
	self.ramp_side_rate = 0.0
	self.ramp_probe_clock = 0.0
	self.ramp_zero_clear = false
	self.last_shift = ZERO
	local l = self.ramp_limit
	l.valid = false
	l.engaged = false
	self.floor_w = 0.0
	self.floor_w_stage = 0.0
	self.height_off = 0.0
	self.height_stage = 0.0
	self.board_w = 0.0
	self.board_w_stage = 0.0
	self.board_rel = ZERO
	self.board_rel_stage = ZERO
	self.trajectory_arc = ZERO
	self.trajectory_arc_stage = ZERO
	self.air_peak_y = 0.0
	self.last_landing_fall = 0.0
	self.last_landing_fraction = 0.0
	layers_reset(self.layers)
	self.no_lag_timer = self.settings.pipeline.no_lag_after_reset
	step_once(self, s, query, true)
	copy_step_out(self.prev_out, self.curr_out)
end

-- ---------------------------------------------------------------- publish

-- The frame from the last two steps, interpolated by the accumulator.
local function hold(self)
	local d = self.frame.debug
	d.held = true
	d.reset = false
	d.steps = 0
	return self.frame
end

local function publish(self, was_reset, steps, extras_unused)
	local cs = self.settings
	local alpha = clamp01(self.acc * fixed_hz)
	local po, co = self.prev_out, self.curr_out
	local o_pos = po.pos + (co.pos - po.pos) * alpha
	local o_yaw = blend_angle(po.yaw, co.yaw, alpha)
	local o_pitch = lerp_f(po.pitch, co.pitch, alpha)
	local o_roll = lerp_f(po.roll, co.roll, alpha)
	local o_local = po.localpos + (co.localpos - po.localpos) * alpha
	local o_anchor = po.anchor + (co.anchor - po.anchor) * alpha
	local o_skater = po.skater_anchor + (co.skater_anchor - po.skater_anchor) * alpha
	local o_fov_extra = lerp_f(po.fov_extra, co.fov_extra, alpha)
	local o_shoulder = lerp_f(po.shoulder, co.shoulder, alpha)
	-- The interpolated pose is the one of a step ago; the game draws him where he is now, so it moves with him by that step,
	-- its place relative to him unchanged.
	local cur = self.cur_snap
	local carried = cur.position - (po.subject + (co.subject - po.subject) * alpha)
	-- At most what his speed covers in 1.5 steps.
	local most = vmag(cur.velocity) * 1.5 * fixed_step + 0.01
	local cl = vmag(carried)
	if cl > most then
		carried = carried * (most / cl)
	end
	-- Not down: the step held the camera above the ground and the deck.
	carried = vcreate(carried.x, max(carried.y, 0.0), carried.z)
	local carried_by = ZERO
	if finite3(carried) then
		o_pos = o_pos + carried
		o_anchor = o_anchor + carried
		o_skater = o_skater + carried
		carried_by = carried
	end

	local fov_base = fov_base_deg(self)
	local right, up, back = basis_from_angles(o_yaw, o_pitch, o_roll)
	local position = o_pos + right * o_local.x + up * o_local.y + back * o_local.z
	local fov = clamp(fov_base + o_fov_extra, 1.0, 170.0)
	if not finite3(right) or not finite3(up) or not finite3(back) or not finite3(position) or not isfinite(fov) then
		hold(self)
		return
	end
	local frame = self.frame
	frame.right = right
	frame.up = up
	frame.back = back
	frame.pos = position
	frame.fov_deg = fov
	frame.shot = self.id
	frame.valid = true

	local d = frame.debug
	local ly = self.layers
	local pred = self.prediction
	local planded = pred.status == "Landed"
	local was_air = self.was_air
	d.shot_name = Graph.shot_id_name(self.id)
	d.reset = was_reset
	d.held = false
	d.preset = cs.preset
	d.steps = steps
	d.accumulator = self.acc
	d.airborne = was_air
	d.landing_active = self.last_pick_landing_active
	d.transitioning = self.shot_fraction < 1.0
	d.shot_fraction = self.shot_fraction
	d.chase_blend = self.last_pick_chase_blend
	d.prediction_valid = planded
	d.predicted_max_height = was_air and self.flight_max_height or 0.0
	d.predicted_air_time = planded and (self.prediction_time_base + pred.predicted_air_time) or 0.0
	d.predicted_landing_delta = planded and (pred.predicted_landing_height + self.prediction_offset) or 0.0
	d.air_hold_delta = self.last_hold
	d.anchor_lag = self.last_rig_anchor_lag
	d.heading = self.last_rig_heading
	d.elevation = self.last_elevation_used -- with the rise, so camera = anchor + distance * sin(elevation)
	d.distance = self.distance_used -- with the exit ease
	d.impulse = self.shake.impulse
	d.landing_dip = 0.0
	d.speed = self.last_speed
	d.incline_degrees = self.incline_degrees
	d.forward_acceleration = self.accel_filtered
	d.push_state = self.last_push_state
	d.push_kick = self.kick_in_update
	d.fov_base = fov_base
	d.fov_extra = o_fov_extra
	d.landing_look_weight = ly.landing_look_weight
	d.look_pitch_offset = ly.look_pitch_offset
	d.shoulder = o_shoulder
	d.follow_strength = ly.follow_strength
	d.collision_pull = ly.collision_pull
	d.collision_pivot = ly.coll_pivot
	d.collision_full = ly.coll_full
	d.collision_hard = ly.coll_hard
	d.collision_floor = ly.coll_floor
	d.collision_goal = ly.coll_goal
	d.collision_fast = ly.coll_fast
	d.trick_yaw = ly.trick_yaw
	d.air_follow_weight = ly.air_follow_weight
	d.air_reference_height = ly.air_reference_height
	d.air_rise = ly.air_rise
	d.keep_pitch_offset = ly.keep_pitch_offset
	d.focus_weight = ly.focus_weight
	d.look_target = ly.look_target
	d.landing_fall = self.last_landing_fall
	d.landing_fraction = self.last_landing_fraction
	d.follow_weight = ly.follow_weight
	d.travel_heading = self.travel_heading
	d.exit_blend = self.exit_blend
	d.floor_weight = ly.floor_weight
	d.height_offset = ly.height_offset
	d.board_weight = ly.board_weight
	d.orbit_anchor = o_anchor
	d.skater_anchor = o_skater
	d.view_heading = self.last_view_heading
	d.ramp_side = self.ramp_side
	d.keep_weight = ly.keep_weight
	d.board_target = ly.board_target
	d.camera_free = ly.camera_free
	d.carried = carried_by
	d.collision_rays = self.update_rays
	d.collision_rays_max = self.update_rays_max
end

-- ---------------------------------------------------------------- update

-- The snapshot `f` of the way from `a` to `b`. Continuous fields interpolate; discrete ones switch at the midpoint.
local function blend_snapshot(self, a, b, f)
	local out = self.sub_snap
	local src = f >= 0.5 and b or a
	out.physics_state = src.physics_state
	out.onboard = src.onboard
	out.bailing = src.bailing
	out.manual = src.manual
	out.grind_side = src.grind_side
	out.switch_stance = src.switch_stance
	out.board_valid = src.board_valid
	out.board_position = src.board_position
	out.time = lerp_f(a.time, b.time, f)
	out.position = a.position + (b.position - a.position) * f
	out.velocity = a.velocity + (b.velocity - a.velocity) * f
	out.forward = normalized(a.forward + (b.forward - a.forward) * f, b.forward)
	out.ground_normal = normalized(a.ground_normal + (b.ground_normal - a.ground_normal) * f, b.ground_normal)
	out.ground_clearance = lerp_f(a.ground_clearance, b.ground_clearance, f)
	if a.board_valid and b.board_valid then
		out.board_position = a.board_position + (b.board_position - a.board_position) * f
	end
	out.valid = true
	return out
end

-- One rendered frame. `dt` is the real frame time in seconds; `query` is the world ray. Returns the new frame, or the previous
-- one with debug.held set when `dt` or the snapshot is unusable.
function Camera:update(dt, subject, query, extras)
	local dt_ok = isfinite(dt) and dt >= 0.0
	if not dt_ok or not Subject.usable(subject) then
		if dt_ok then
			self.invalid_time = self.invalid_time + dt
		end
		return hold(self)
	end
	local cs = self.settings
	local aspect = extras and extras.aspect
	if aspect ~= nil and isfinite(aspect) and aspect > 0.0 then
		self.aspect = aspect
	end
	-- What the steps need of the extras: the keep-in-frame layer reads the lens (fov_base_deg).
	self.extras_base_fov = extras and extras.base_fov_deg or 0.0

	local pipe = cs.pipeline
	local cut = self.reset_requested or not self.initialized or self.last_preset ~= cs.preset
		or self.invalid_time > pipe.resume_reset_time
		or vmag(subject.position - self.cur_snap.position) > pipe.teleport_distance
	self.invalid_time = 0.0

	self.kick_in_update = false
	self.update_rays = 0
	self.update_rays_max = 0
	local steps = 0
	if cut then
		self.reset_requested = false
		self.initialized = true
		self.last_preset = cs.preset
		cut_to(self, subject, query)
	else
		local step = fixed_step
		local carry = self.acc
		-- The C++ accumulator is a float: the same rounding here makes a frame of exactly N steps run N steps (and the same
		-- frames run the same steps as the C++ at 144 fps).
		dt = f32(dt)
		-- Clamp BEFORE the int conversion: a huge dt would freeze the camera.
		local limit = f32((pipe.max_steps_per_update + 1) * step)
		local sum = f32(carry + dt)
		local capped = sum >= limit -- a long stall: the steps are capped below
		local acc = min(sum, limit)
		steps = floor(f32(acc / step))
		if steps > pipe.max_steps_per_update then -- drop the surplus rather than spiral
			local fraction = max(0.0, f32(acc - f32(steps * step)))
			steps = pipe.max_steps_per_update
			acc = f32(f32(steps * step) + fraction)
		end
		self.acc = acc
		local cur = self.cur_snap
		for i = 1, steps do
			-- Where in this frame's interval the step lands: the sim clock lags the snapshot clock by the accumulator carried in,
			-- so the subject is interpolated, never extrapolated.
			local f
			if capped then
				f = i / steps
			elseif dt > 0.0 then
				f = clamp01((i * step - carry) / max(dt, 1e-9))
			else
				f = 1.0
			end
			step_once(self, blend_snapshot(self, cur, subject, f), query, false)
		end
		acc = f32(self.acc - f32(steps * step))
		if acc < 0.0 then
			acc = 0.0
		end
		self.acc = acc
		copy_snapshot(cur, subject)
	end
	publish(self, cut, steps)
	return self.frame
end

return Camera
