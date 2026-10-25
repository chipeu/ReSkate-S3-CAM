-- Port of Engine/Game/Camera/s3_settings.h: every Dynamic Camera tunable, as plain tables with the C++
-- defaults and the C++ field names (snake_case), plus a valid function for each group. There is no I/O here;
-- presets.lua turns these into/out of JSON.
--
-- Settings.camera() builds a whole CameraSettings. Its groups are tables of the same names as the C++:
--   preset, angle, fov_override_deg, shake_enabled,
--   rig = { anchor, heading, elevation, distance, compass }   (rig.lua RigSettings)
--   orientation, air, shake, trajectory, graph, points, native_plus, pipeline, look, shoulder, follow, fov,
--   speed_shake, collision, framing, framing_high, trick_yaw, air_camera, landing_shake,
--   distance, distance_high (legacy limits), ride_distance, ride_distance_high
-- Settings.valid(camera_settings) is CameraSettings::valid(): every group must be valid.
--
-- Enums are small integers with the C++ values; the name tables map names to them:
--   Settings.CameraPreset   = { FullS3 = 0, NativePlus = 1 }
--   Settings.CameraAngle    = { Low = 0, High = 1 }                (same as Shots.Low / Shots.High)
--   Settings.ShoulderSide   = { Off = 0, Manual = 1, Auto = 2 }
--   Settings.DistanceMode   = { Speed = 0, Fixed = 1 }
--   Settings.ManualDistanceMode = { Fixed = 0, Speed = 1 }
--   shoulder.side, trick_yaw.side are the C++ ints (+1 / -1 / 0).
--
-- Per-group constructors (all return a fresh table with the C++ defaults) and validators:
--   Settings.orientation()   / Settings.valid_orientation(t)
--   Settings.points()        / Settings.valid_points(t)            (SubjectPointSettings)
--   Settings.native_plus()   / Settings.valid_native_plus(t)
--   Settings.pipeline()      / Settings.valid_pipeline(t)
--   Settings.look()          / Settings.valid_look(t)
--   Settings.shoulder()      / Settings.valid_shoulder(t)
--   Settings.follow()        / Settings.valid_follow(t)
--   Settings.fov()           / Settings.valid_fov(t)
--   Settings.speed_shake()   / Settings.valid_speed_shake(t)
--   Settings.distance_limits() / Settings.valid_distance_limits(t)  (DistanceLimits)
--   Settings.ride_distance(angle) / Settings.valid_ride_distance(t) (RideDistance; default per angle)
--   Settings.landing_shake() / Settings.valid_landing_shake(t)
--   Settings.collision()     / Settings.valid_collision(t)
--   Settings.framing()       / Settings.valid_framing(t)
--   Settings.air_camera()    / Settings.valid_air_camera(t)
--   Settings.trick_yaw()     / Settings.valid_trick_yaw(t)
--   and the groups that live in their own modules, re-exported: Settings.rig() (rig.lua), Settings.air() (air.lua),
--   Settings.shake() (shake.lua), Settings.trajectory() (the camera's { 10.1, 1/20, 3.0 }), Settings.graph() (graph.lua),
--   with Settings.valid_rig / valid_air / valid_shake / valid_trajectory / valid_graph.
-- Helpers: Settings.copy(t) deep copy; Settings.chase_slow_distance(angle), Settings.chase_fast_distance(angle),
--   Settings.default_ride_distance(angle), Settings.ride_distance_from_legacy(limits, scale, angle);
--   constants Settings.closeup_min_distance = 0.5, Settings.manual_full_speed = 8.

local Tracker = require("tracker")
local Rig = require("rig")
local Air = require("air")
local Shake = require("shake")
local Traj = require("trajectory")
local Graph = require("graph")
local Shots = require("shots")

local M = {}

local max, min, clamp = math.max, math.min, math.clamp

M.CameraPreset = { FullS3 = 0, NativePlus = 1 } -- FullS3: the whole Skate 3 pipeline owns the camera; NativePlus: the game's own pose plus only the S3 layers
M.CameraAngle = { Low = 0, High = 1 }
M.ShoulderSide = { Off = 0, Manual = 1, Auto = 2 } -- Off: centred. Manual: `side`, swapped by the player (L3). Auto: the stance's toe side
M.DistanceMode = {
	Speed = 0, -- eased from `slow` to `fast` with speed, as the built-in chase shots go from slow to fast
	Fixed = 1, -- `fixed` at every speed, measured from the skater himself; only a big air's room (and a wall) changes it
}
M.ManualDistanceMode = {
	Fixed = 0, -- the player's manual distance at every speed
	Speed = 1, -- eased from manual_min_distance (standing) to manual_max_distance (8 m/s and faster)
}

M.closeup_min_distance = 0.5 -- The nearest any close-up may come (its own floor, in place of DistanceLimits::min)
M.manual_full_speed = 8.0 -- m/s: the speed at which a Speed manual reaches its maximum

local function ok(v, lo, hi)
	return v - v == 0 and v >= lo and v <= hi
end

local function fin(v)
	return v - v == 0
end

function M.copy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in t do
		out[k] = M.copy(v)
	end
	return out
end

-- ---------------------------------------------------------------- orientation

-- AngleTrackerSettings{ umbra, penumbra, speed, acc_min, acc_max, smoothing_min, smoothing_max, overshoot }
local function angle_tracker(umbra, penumbra, speed, acc_min, acc_max)
	return {
		delta_umbra_degrees = umbra,
		delta_penumbra_degrees = penumbra,
		speed_clamp_degrees = speed,
		acceleration_min_degrees = acc_min,
		acceleration_max_degrees = acc_max,
		smoothing_min = 0.0,
		smoothing_max = 0.0,
		overshoot_zeroes_velocity = true,
	}
end

-- Where the shot's reference weights look and how fast the camera turns to it (rig_orientation.rs).
function M.orientation()
	return {
		pan = angle_tracker(0.5, 20.0, 720.0, 1500.0, 3000.0), -- TUNE; smoothing comes from the shot
		tilt = angle_tracker(0.5, 15.0, 360.0, 1200.0, 2400.0), -- TUNE
		max_pitch_degrees = 60.0, -- FrameSettings.maximum_pitch_degrees: the look direction never tilts up past this; TUNE
		roll_response = 6.0, -- 1/s, FrameSettings.roll_response: how fast roll follows the shot's framing roll; TUNE
		smoothing_cap = 0.9, -- rig_orientation.rs cap_smoothing (0x3f666666)
	}
end

function M.valid_orientation(s)
	return Tracker.valid_angle(s.pan) and Tracker.valid_angle(s.tilt) and fin(s.max_pitch_degrees)
		and s.max_pitch_degrees > 0.0 and s.max_pitch_degrees < 90.0 and fin(s.roll_response)
		and s.roll_response >= 0.0 and s.roll_response <= 1000.0 and fin(s.smoothing_cap) and s.smoothing_cap >= 0.0
		and s.smoothing_cap <= 1.0
end

-- ---------------------------------------------------------------- subject points

-- Reference points the shot weights mix, derived from the snapshot's root position (the snapshot
-- has no skeleton). All metres, TUNE.
function M.points()
	return {
		board_drop = 0.9, -- root -> board (measured in game: board is ~0.9 m below the root riding)
		anchor_height = 0.32, -- board -> orbit anchor (Rust: subject.anchors[shot.anchor]); sets the standing camera height (Low ~0.59 m, High ~1.85 m above the ground); TUNE
		head_height = 0.7, -- root -> head
		com_height = 0.05, -- root -> centre of mass
		trajectory_lookahead = 0.25, -- s ahead on the ballistic arc the "Trajectory" point sits while airborne
	}
end

function M.valid_points(s)
	return ok(s.board_drop, 0.0, 3.0) and ok(s.anchor_height, -3.0, 3.0) and ok(s.head_height, -3.0, 3.0)
		and ok(s.com_height, -3.0, 3.0) and ok(s.trajectory_lookahead, 0.0, 2.0)
end

-- ---------------------------------------------------------------- native plus

-- The Native+ layers. Everything is toggleable; amplitudes are TUNE.
function M.native_plus()
	return {
		air_hold = true, -- hold the camera height in the air (s3_air hold delta added to the native Y)
		landing_dip = true, -- critically damped dip on touchdown
		shake = true, -- impulse + speed shake from s3_shake
		roll = true, -- the shot's framing roll (and shake roll)
		dip_depth = 0.12, -- m, deepest point of a full-strength landing; TUNE
		dip_peak_time = 0.12, -- s, time to the deepest point (the spring's 1/omega); TUNE
	}
end

function M.valid_native_plus(s)
	return fin(s.dip_depth) and s.dip_depth >= 0.0 and s.dip_depth <= 2.0 and fin(s.dip_peak_time)
		and s.dip_peak_time >= 0.02 and s.dip_peak_time <= 2.0
end

-- ---------------------------------------------------------------- pipeline

-- Plumbing that is not a Skate 3 tunable but still must not be a magic number.
function M.pipeline()
	return {
		accel_smoothing_time = 0.05, -- s, low-pass on the forward acceleration feeding pump/push; TUNE
		push_accel_threshold = 3.0, -- m/s^2, forward acceleration that counts as a push kick (upward crossing, on the ground); TUNE
		push_window = 0.5, -- s, push_state stays set this long after a kick; TUNE
		repredict_interval = 0.1, -- s between trajectory re-predictions while airborne (0: only at takeoff); TUNE
		floor_clearance = 0.15, -- m, the camera never sits lower than ground beneath the subject + this (0: off); TUNE. The collision layer adds real collision
		teleport_distance = 10.0, -- m, a snapshot farther than this from the last one is a cut: the camera resets; TUNE
		resume_reset_time = 0.5, -- s, after this long without a usable snapshot the camera resets when data returns; TUNE
		no_lag_after_reset = 0.2, -- s, the anchor follows with no lag this long after a reset ("just reset"); TUNE
		max_steps_per_update = 16, -- fixed (1/60 s) steps one update may run; extra time is dropped (spiral-of-death guard)
		shake_distance_scale = 1.0, -- multiplies the camera distance fed to the shake fade; 1 = the real distance
	}
end

function M.valid_pipeline(s)
	return ok(s.accel_smoothing_time, 0.0, 5.0) and ok(s.push_accel_threshold, 0.0, 100.0)
		and ok(s.push_window, 0.0, 5.0) and ok(s.repredict_interval, 0.0, 5.0) and ok(s.floor_clearance, 0.0, 5.0)
		and ok(s.teleport_distance, 0.1, 1.0e5) and ok(s.resume_reset_time, 0.0, 60.0)
		and ok(s.no_lag_after_reset, 0.0, 5.0) and s.max_steps_per_update >= 1 and s.max_steps_per_update <= 240
		and ok(s.shake_distance_scale, 0.0, 100.0)
end

-- ---------------------------------------------------------------- player layers

-- Pitch prediction: where the camera looks, on top of the shot's framing.
function M.look()
	return {
		landing_look = true, -- in the air, look down toward a landing below the takeoff (stairs, gaps to a lower level)
		landing_look_strength = 0.6, -- 0..1: share of the way the look target moves toward the predicted landing point
		landing_look_full_drop = 2.5, -- m the landing is below the takeoff for the full strength (scales linearly from 0)
		slope_look = true, -- on the ground, pitch with the slope: down when riding downhill, up uphill
		slope_look_strength = 0.5, -- 0..1: share of the incline angle added to the pitch
		vertical_follow = 1.0, -- 0..1: how much the pitch follows the skater's height (0: the pitch stays level with the anchor)
		response_time = 0.25, -- s: the look offsets ease in and out with this time constant
		-- Where the camera aims in manuals and grinds: 0 = the board, 1 = the shot's usual point (hips /
		-- upper body). Alpha 3 feedback: manuals should frame the lower body and the board.
		manual_focus = 0.25,
		grind_focus = 0.5,
		-- Manuals and grinds: the camera circles, aims and tilts around the real board instead of a point
		-- worked out from the hips (Alpha 6 feedback: "grind and manual cam need board anchoring").
		board_anchor = true,
		-- Leaving a manual / grind close-up (a trick, the end of the grind): how long the camera takes to ease back
		-- out to its normal view. Beta feedback: it snapped; some players want it quicker, some slower.
		closeup_exit_time = 0.9, -- s
		-- Shot blend (1.0.2): how long the shot changes take (the shot table's transitions) and the way into a close-up, as a
		-- multiplier on each one's own time. Beta feedback: trick -> manual -> grind cut from one angle to the next too fast.
		-- 1 = as before, 2 = twice as slow. The close-up return time and the trick turn's in / back times are the player's own
		-- seconds and are not multiplied.
		shot_blend = 1.0,
	}
end

function M.valid_look(s)
	return ok(s.landing_look_strength, 0.0, 1.0) and ok(s.landing_look_full_drop, 0.1, 50.0)
		and ok(s.slope_look_strength, 0.0, 1.0) and ok(s.vertical_follow, 0.0, 1.0) and ok(s.response_time, 0.0, 5.0)
		and ok(s.manual_focus, 0.0, 1.0) and ok(s.grind_focus, 0.0, 1.0) and ok(s.closeup_exit_time, 0.2, 3.0)
		and ok(s.shot_blend, 0.25, 4.0)
end

-- Over-the-shoulder offset: the camera slides sideways along its own right axis, so the skater sits
-- left or right of the screen centre. Applies in both presets.
function M.shoulder()
	return {
		mode = M.ShoulderSide.Off,
		offset = 0.45, -- m sideways when on a side
		side = 1, -- Manual: +1 the camera sits to the skater's right (skater left of centre), -1 left
		goofy = false, -- Auto: the player's stance; regular rides with the toes to the right. Riding switch flips it
		switch_time = 0.45, -- s for the camera to slide across to the other side (sine ease)
	}
end

function M.valid_shoulder(s)
	return fin(s.offset) and s.offset >= 0.0 and s.offset <= 3.0 and (s.side == 1 or s.side == -1)
		and fin(s.switch_time) and s.switch_time >= 0.0 and s.switch_time <= 5.0
end

-- How tightly the camera follows: the anchor lag and the heading / elevation / pan / tilt smoothing.
function M.follow()
	return {
		strength = 1.0, -- 1 = Skate 3. Above 1 follows tighter (less lag), below 1 looser
		dynamic = true, -- follow tighter as speed rises
		dynamic_speed = 12.0, -- m/s where the dynamic boost is full
		dynamic_boost = 0.5, -- added to strength at that speed
		-- Horizontal follow, 0-10 (Alpha 5 feedback, "like vanilla"): how firmly the camera swings round
		-- behind the direction you ride. 0 keeps the normal lazy swing, 10 locks it straight behind (a fixed
		-- chase camera).
		horizontal = 0.0,
	}
end

function M.valid_follow(s)
	return ok(s.strength, 0.2, 4.0) and ok(s.dynamic_speed, 0.5, 60.0) and ok(s.dynamic_boost, 0.0, 3.0)
		and ok(s.horizontal, 0.0, 10.0)
end

-- Field of view on top of the base FOV (the game camera's own, or fov_override_deg). Every term eases
-- with smoothing_time, so nothing snaps.
function M.fov()
	return {
		shot_fov = true, -- the shot's lens relative to the chase shot's (stock shots all share one lens: 0 today)
		speed_fov = true, -- widen with speed
		speed_fov_degrees = 6.0, -- extra degrees at speed_fov_max
		speed_fov_min = 5.0, -- m/s where widening starts
		speed_fov_max = 15.0, -- m/s where it is full
		air_fov = true, -- widen in big airs (Skate 3's high-air feel)
		air_fov_degrees = 8.0, -- extra degrees at air_fov_full_height
		air_fov_full_height = 2.5, -- m: predicted apex above takeoff for the full air FOV
		smoothing_time = 0.35, -- s, time constant of the FOV ease
	}
end

function M.valid_fov(s)
	return ok(s.speed_fov_degrees, 0.0, 40.0) and ok(s.speed_fov_min, 0.0, 60.0) and s.speed_fov_max > s.speed_fov_min
		and ok(s.speed_fov_max, 0.1, 80.0) and ok(s.air_fov_degrees, 0.0, 40.0) and ok(s.air_fov_full_height, 0.1, 50.0)
		and ok(s.smoothing_time, 0.0, 5.0)
end

-- The speed rumble ("shaky downhill / speed cam"), on top of the landing shake. Scales ShakeSettings'
-- speed terms; the landing impulse is separate (shake_enabled switches both off).
function M.speed_shake()
	return {
		enabled = true,
		strength = 1.0, -- multiplies amplitude_max
		top_speed = 15.0, -- m/s for the full rumble (replaces amplitude_top_speed / frequency_top_speed)
		downhill_boost = true, -- more rumble riding downhill
		downhill_scale = 1.5, -- multiplier at downhill_full_degrees
		downhill_full_degrees = 20.0,
	}
end

function M.valid_speed_shake(s)
	return ok(s.strength, 0.0, 10.0) and ok(s.top_speed, 0.5, 80.0) and ok(s.downhill_scale, 1.0, 10.0)
		and ok(s.downhill_full_degrees, 1.0, 80.0)
end

-- ---------------------------------------------------------------- distance

-- The main camera's distance from the skater (Alpha 6 feedback: "sometimes the grind / manual camera gets way
-- too close"), one pair for Low and one for High (1.0.2). Not the manual / grind close-ups, which have their own
-- distances. Replaces the collision's own minimum (CollisionSettings::min_distance, kept only so old presets load).
-- min == max - 0.2 is as near to a fixed riding distance as valid() allows.
function M.distance_limits()
	return {
		min = 1.2, -- m: the riding camera never comes closer than this; only a wall pulls it nearer (down to the personal space)
		max = 6.0, -- m: the camera never goes further back than this
	}
end

function M.valid_distance_limits(s)
	return fin(s.min) and fin(s.max) and s.min >= 0.2 and s.max <= 20.0 and s.max >= s.min + 0.2
end

-- The built-in chase shots' slow and fast distances of an angle (Low 1.8 / 2.5 m, High 3.0 / 4.4 m): the defaults, and the scale
-- every other riding shot's distance is placed on.
function M.chase_slow_distance(angle)
	return Graph.resolve_shot(Graph.ShotId.Chase, angle, 0.0).distance
end

function M.chase_fast_distance(angle)
	return Graph.resolve_shot(Graph.ShotId.Chase, angle, 1.0).distance
end

-- The riding camera's distance, one for Low and one for High (1.0.2 test 5: CAMERA DISTANCE). It replaces the distance scale
-- (framing.distance_scale) and the Minimum / Maximum (distance_limits), which fought each other. Those are kept only so old
-- presets load; they convert once (ride_distance_from_legacy). Not the manual / grind close-ups.
--   mode = DistanceMode.Speed: eased from `slow` to `fast` with speed; Fixed: `fixed` at every speed.
-- `angle` picks the default distances (Low if omitted).
function M.ride_distance(angle)
	angle = angle or M.CameraAngle.Low
	local slow = M.chase_slow_distance(angle)
	return {
		mode = M.DistanceMode.Speed,
		slow = slow, -- m (Speed): standing and slow
		fast = M.chase_fast_distance(angle), -- m (Speed): at top speed
		fixed = slow, -- m (Fixed)
	}
end
M.default_ride_distance = M.ride_distance

function M.valid_ride_distance(s)
	local function good(v)
		return ok(v, 0.5, 20.0)
	end
	return good(s.slow) and good(s.fast) and good(s.fixed) and s.fast >= s.slow
end

-- An old setup's distances: the scaled chase distances held inside its limits, as they framed it.
function M.ride_distance_from_legacy(limits, scale, angle)
	local hi = max(limits.max, limits.min)
	local out = M.ride_distance(angle)
	out.slow = max(0.5, clamp(M.chase_slow_distance(angle) * scale, limits.min, hi))
	out.fast = max(out.slow, clamp(M.chase_fast_distance(angle) * scale, limits.min, hi))
	out.fixed = out.slow
	return out
end

-- ---------------------------------------------------------------- landing shake, collision

-- How hard a landing was, for the landing shake (Alpha 5 feedback: a light nollie gave a full shake).
-- Measured from how far the skater fell, from the highest point of the air to the landing, which flip
-- tricks and board spin cannot fake; a little forward speed is added.
function M.landing_shake()
	return {
		min_fall = 0.5, -- m: landings that fell less than this do not shake
		full_fall = 2.5, -- m: a fall this big gives the full landing shake
		speed_weight = 0.1, -- share of the forward speed added to the impact speed
	}
end

function M.valid_landing_shake(s)
	return ok(s.min_fall, 0.0, 10.0) and ok(s.full_fall, 0.1, 30.0) and s.full_fall > s.min_fall
		and ok(s.speed_weight, 0.0, 1.0)
end

-- Camera collision: walls, poles and the ground between the skater and the camera.
function M.collision()
	return {
		enabled = true,
		-- Automatic (Beta feedback: collision should not need setting up): the values below are ignored and the
		-- camera uses these defaults, and it pulls in only for obstacles wider than a pole or a rail. Off: the values
		-- below, for testing.
		automatic = true,
		radius = 0.25, -- m kept between the camera and a hit surface (pulled in along the ray)
		min_distance = 0.5, -- m: unused since Alpha 6 (distance_limits.min is the one minimum); kept so old presets load
		pull_in_time = 0.05, -- s: how fast the camera moves in front of an obstacle (near instant)
		release_time = 0.4, -- s: how fast it eases back out once clear
		ground_clearance = 0.3, -- m above the ground under the camera itself
	}
end

function M.valid_collision(s)
	return ok(s.radius, 0.0, 2.0) and ok(s.min_distance, 0.0, 5.0) and ok(s.pull_in_time, 0.0, 2.0)
		and ok(s.release_time, 0.0, 5.0) and ok(s.ground_clearance, 0.0, 3.0)
end

-- ---------------------------------------------------------------- framing

-- The player's framing on top of every shot: distance, camera height and view pitch, and the
-- manual close-up (Alpha 3 feedback).
function M.framing()
	return {
		distance_scale = 1.0, -- multiplies every shot's camera distance
		height_degrees = 0.0, -- added to every shot's elevation: the camera sits higher (+) or lower around the skater
		pitch_degrees = 0.0, -- added to the view pitch: + looks up, - looks down
		-- The manual and grind close-ups have their own values (Beta feedback): the main distance, height and pitch above
		-- do not apply to them, and the distance limits are the main camera's only.
		manual_camera = true, -- manuals / nose manuals use the manual close-up
		manual_distance = 1.6, -- m, the camera's distance in a manual
		manual_height_degrees = 0.0, -- added to the manual shots' own elevation
		manual_pitch_degrees = 0.0, -- the view pitch in a manual: + looks up, - looks down
		grind_camera = true, -- grinds use the grind close-up
		grind_distance = 1.6, -- m, the camera's distance in a grind
		grind_height_degrees = 0.0, -- added to the grind shots' own elevation
		grind_pitch_degrees = 0.0, -- the view pitch in a grind
		-- Unused since the close-ups have their own distances (kept so old presets load).
		manual_distance_scale = 0.75,
		grind_distance_scale = 1.0,
		-- The manual's one composition (the close shot) at every speed; its distance fixed or eased with speed (1.0.2).
		manual_mode = M.ManualDistanceMode.Fixed,
		manual_min_distance = 1.4, -- m, Speed: the distance standing still
		manual_max_distance = 2.0, -- m, Speed: the distance at manual_full_speed and faster
	}
end

function M.valid_framing(s)
	local cmd = M.closeup_min_distance
	return ok(s.distance_scale, 0.2, 3.0) and ok(s.height_degrees, -30.0, 45.0) and ok(s.pitch_degrees, -30.0, 30.0)
		and ok(s.manual_distance, cmd, 8.0) and ok(s.manual_height_degrees, -30.0, 45.0)
		and ok(s.manual_pitch_degrees, -30.0, 30.0) and ok(s.grind_distance, cmd, 8.0)
		and ok(s.grind_height_degrees, -30.0, 45.0) and ok(s.grind_pitch_degrees, -30.0, 30.0)
		and ok(s.manual_distance_scale, 0.3, 1.5) and ok(s.grind_distance_scale, 0.3, 2.0)
		and (s.manual_mode == M.ManualDistanceMode.Fixed or s.manual_mode == M.ManualDistanceMode.Speed)
		and ok(s.manual_min_distance, cmd, 8.0) and ok(s.manual_max_distance, cmd, 8.0)
		and s.manual_max_distance >= s.manual_min_distance
end

-- Big airs (Alpha 3 feedback: the skater left the screen in big airs, and the camera should end up
-- above, looking down at the landing as the game's own camera does). Both presets.
function M.air_camera()
	return {
		follow_height = 1.0, -- 0: the camera stays at the takeoff height, 1: rises with the skater
		rise_degrees = 20.0, -- the camera swings up over the skater by this much in a big air
		rise_full_height = 1.5, -- m: apex above the takeoff, or drop below it, for the full rise
		ease_time = 0.35, -- s: how slowly the rise and the height follow ease back after landing (they build ~3x faster)
		keep_in_frame = true, -- aim the view so the skater never leaves the screen in the air
	}
end

function M.valid_air_camera(s)
	return ok(s.follow_height, 0.0, 1.0) and ok(s.rise_degrees, 0.0, 60.0) and ok(s.rise_full_height, 0.1, 20.0)
		and ok(s.ease_time, 0.0, 3.0)
end

-- Trick yaw: while the skater tricks, the camera swings round to the side to show the trick, holds that
-- angle while tricks keep coming, and recentres behind after landing. Nothing snaps.
function M.trick_yaw()
	return {
		enabled = true,
		angle_degrees = 25.0, -- how far round the camera swings
		side = 0, -- 0: auto (the shoulder side when Manual, else the stance's toe side), +1 right, -1 left
		in_air = true, -- airs and flip tricks
		on_grinds = false,
		on_manuals = false,
		min_air_time = 0.2, -- s in the air before the swing starts (a plain ollie stays centred)
		in_time = 0.6, -- s to swing out
		hold_time = 0.5, -- s after the trick before recentring; a new trick in this time keeps the angle
		return_time = 1.5, -- s to recentre behind
	}
end

function M.valid_trick_yaw(s)
	return ok(s.angle_degrees, 0.0, 90.0) and s.side >= -1 and s.side <= 1 and ok(s.min_air_time, 0.0, 3.0)
		and ok(s.in_time, 0.0, 5.0) and ok(s.hold_time, 0.0, 5.0) and ok(s.return_time, 0.0, 10.0)
end

-- ---------------------------------------------------------------- groups from other modules

M.rig = Rig.default_settings
M.valid_rig = Rig.valid
M.air = Air.settings
M.valid_air = Air.valid
M.shake = Shake.settings
M.valid_shake = Shake.valid
M.graph = Graph.settings
M.valid_graph = Graph.valid

-- Chords of 1/20 s (three physics steps): the contact time is refined inside the hit chord, so the
-- result matches 1/60 s chords to a few mm, with a third of the rays (a 3 s miss re-predicted every
-- 0.1 s was ~1,800 rays a second).
function M.trajectory()
	return { gravity = 10.1, step = 1.0 / 20.0, max_time = 3.0 }
end
M.valid_trajectory = Traj.valid

-- ---------------------------------------------------------------- the whole thing

function M.camera()
	return {
		preset = M.CameraPreset.FullS3,
		angle = M.CameraAngle.Low, -- S3 Low / S3 High (the shot set)
		fov_override_deg = 0.0, -- > 0 replaces the computed (or native) field of view; 0 = off
		shake_enabled = true, -- master switch for the shake layer in both presets

		rig = M.rig(),
		orientation = M.orientation(),
		air = M.air(),
		shake = M.shake(),
		trajectory = M.trajectory(),
		graph = M.graph(),
		points = M.points(),
		native_plus = M.native_plus(),
		pipeline = M.pipeline(),
		look = M.look(),
		shoulder = M.shoulder(),
		follow = M.follow(),
		fov = M.fov(),
		speed_shake = M.speed_shake(),
		collision = M.collision(),
		framing = M.framing(), -- the Low camera's position (also the default for the High one)
		framing_high = M.framing(), -- the High camera's position
		trick_yaw = M.trick_yaw(),
		air_camera = M.air_camera(),
		landing_shake = M.landing_shake(),
		distance = M.distance_limits(), -- old presets only (converted to ride_distance on load): the Low camera's distance limits
		distance_high = M.distance_limits(), -- old presets only: the High camera's (an old profile without them copies the Low pair)
		ride_distance = M.ride_distance(M.CameraAngle.Low), -- the Low camera's riding distance
		ride_distance_high = M.ride_distance(M.CameraAngle.High), -- the High camera's
	}
end
M.defaults = M.camera

function M.valid(s)
	local fo = s.fov_override_deg
	return fo - fo == 0 and fo >= 0.0 and fo < 180.0 and M.valid_rig(s.rig) and M.valid_orientation(s.orientation)
		and M.valid_air(s.air) and M.valid_shake(s.shake) and M.valid_trajectory(s.trajectory)
		and M.valid_graph(s.graph) and M.valid_points(s.points) and M.valid_native_plus(s.native_plus)
		and M.valid_pipeline(s.pipeline) and M.valid_look(s.look) and M.valid_shoulder(s.shoulder)
		and M.valid_follow(s.follow) and M.valid_fov(s.fov) and M.valid_speed_shake(s.speed_shake)
		and M.valid_collision(s.collision) and M.valid_framing(s.framing) and M.valid_trick_yaw(s.trick_yaw)
		and M.valid_framing(s.framing_high) and M.valid_air_camera(s.air_camera)
		and M.valid_landing_shake(s.landing_shake) and M.valid_distance_limits(s.distance)
		and M.valid_distance_limits(s.distance_high) and M.valid_ride_distance(s.ride_distance)
		and M.valid_ride_distance(s.ride_distance_high)
end

return M
