-- Flight recorder: every riding frame goes into a ring of numbers in memory. When a frame looks wrong, or on Ctrl+Shift+R,
-- the seconds around it are saved as one text file in recorder/ in the data folder. It only observes: no rays, no effect on
-- the camera. Frames are stored as plain numbers; text is built a few lines per tick, and the one file write waits until the
-- rider has been on the ground for a moment. Switch off with dyncam_rec 0.
local M = {}
local R = {}
R.__index = R

M.BEFORE, M.AFTER = 3.0, 3.0 -- s kept around a trigger
M.CAP = 2000 -- frames in the ring: 8 s at the 250 Hz the recorder stores at most
M.MIN_DT = 1 / 250
M.LINES_PER_TICK = 24
M.MAX_BYTES = 950000 -- a file is at most 1 MB
M.KEEP = 40 -- newest clips kept in the folder
M.MAX_CLIPS = 200 -- per session
M.COOLDOWN = 1.5 -- s from one clip's write to the next trigger
M.SETTLE = 0.5 -- s after a break in the camera before triggers count
M.GROUND_WAIT, M.MAX_WAIT = 0.5, 2.0 -- s on the ground before the write, and the longest it waits
M.FOLDER = "recorder"
M.STORE_KEY = "recorder_off"
M.HOTKEY = "R"

-- Triggers, per second so they mean the same at any frame rate.
M.BEHIND_DEPTH = 0.3 -- m in front of the eye
M.YAW_RATE, M.PITCH_RATE = 480, 360 -- deg/s (8 and 6 degrees per frame at 60 FPS)
M.EYE_RATE = 27 -- m/s of the eye relative to the rider (0.45 m per frame at 60 FPS)
M.ORBIT_DEG = 39 -- degrees: at the limit of the measured-eye hold
M.FRAME_LIMIT, M.FRAME_FRAMES = 1.25, 8 -- screen edge is 1; frames in a row beyond this
M.MAX_EVENTS = 16

M.COLUMNS = {
	{ "t", "%.4f" }, { "dt", "%.4f" }, { "state", "%d" }, { "flags", "%d" }, { "shot", "%s" }, { "cause", "%s" }, { "cont", "%d" },
	{ "px", "%.3f" }, { "py", "%.3f" }, { "pz", "%.3f" }, { "rx", "%.3f" }, { "ry", "%.3f" }, { "rz", "%.3f" },
	{ "vx", "%.3f" }, { "vy", "%.3f" }, { "vz", "%.3f" }, { "fx", "%.3f" }, { "fy", "%.3f" }, { "fz", "%.3f" },
	{ "clr", "%.3f" }, { "gy", "%.3f" }, { "nx", "%.3f" }, { "ny", "%.3f" }, { "nz", "%.3f" }, { "gv", "%d" },
	{ "ex", "%.3f" }, { "ey", "%.3f" }, { "ez", "%.3f" }, { "dx", "%.4f" }, { "dy", "%.4f" }, { "dz", "%.4f" },
	{ "ux", "%.3f" }, { "uy", "%.3f" }, { "uz", "%.3f" }, { "fov", "%.2f" },
	{ "cex", "%.3f" }, { "cey", "%.3f" }, { "cez", "%.3f" }, { "cyaw", "%.2f" }, { "cpitch", "%.2f" }, { "yaw", "%.2f" }, { "pitch", "%.2f" },
	{ "fxp", "%.2f" }, { "corr", "%.3f" }, { "align", "%.3f" }, { "guard", "%.3f" }, { "safety", "%.3f" },
	{ "orb", "%.2f" }, { "con", "%d" }, { "trick", "%.2f" }, { "dist", "%.3f" }, { "elev", "%.2f" }, { "lift", "%.2f" }, { "rise", "%.2f" }, { "pull", "%.3f" },
	{ "rays", "%d" }, { "depth", "%.3f" }, { "sx", "%.3f" }, { "sy", "%.3f" }, { "hx", "%.3f" }, { "hy", "%.3f" }, { "hz", "%.3f" },
}
local N = #M.COLUMNS

local abs, atan2, tan, rad, deg = math.abs, math.atan2, math.tan, math.rad, math.deg
local function delta(a, b) return (a - b + 180) % 360 - 180 end
local function mag(v) return vector.magnitude(v) end
local ZERO = vector.create(0, 0, 0)

local function saved_off()
	local ok, value = pcall(reskate.storage.get, M.STORE_KEY)
	return ok and value == true
end

function M.new(version)
	local self = setmetatable({ version = version or "?", off = saved_off(), head = 0, count = 0, clips = 0, session = nil, was_down = false,
		last_t = nil, settle_until = 0, cooldown_until = 0, ground_since = nil, off_frames = 0, last_rays = 0, written = 0, c = nil }, R)
	self.line_format = {}
	for i, col in M.COLUMNS do self.line_format[i] = col[2] end
	self.line_format = table.concat(self.line_format, "\t")
	self.buf = table.create(N, 0)
	return self
end

function R:set_off(off)
	self.off = off == true
	pcall(reskate.storage.set, M.STORE_KEY, self.off or nil)
	if self.off then self.phase, self.parts, self.c, self.count, self.head = nil, nil, nil, 0, 0 end
end

function R:ensure_ring()
	if self.c then return end
	local c = table.create(N)
	for i = 1, N do c[i] = table.create(M.CAP, 0) end
	self.c = c
end

function R:event(now, name, value)
	local ev = self.events
	for i = #ev, 1, -1 do
		if ev[i].name == name and now - ev[i].t < 0.25 then
			if abs(value) > abs(ev[i].value) then ev[i].value = value end
			return
		end
	end
	if #ev < M.MAX_EVENTS then ev[#ev + 1] = { t = now, name = name, value = value } end
end

-- A clip starts here, or an extra event joins the one being captured.
function R:trigger(now, name, value)
	if self.off then return false end
	if self.phase == "capture" then self:event(now, name, value); return true end
	if self.phase or now < self.cooldown_until or self.clips >= M.MAX_CLIPS then return false end
	self.phase, self.at, self.stop_at, self.why, self.value = "capture", now, now + M.AFTER, name, value
	self.events = { { t = now, name = name, value = value } }
	return true
end

-- One riding frame. Called from Glue:trace_camera_frame, numbers only.
function R:frame(g, now, continuous, cause, correction, original, before_guard, after_guard, final, forward, up, fov, core_yaw, core_pitch, yaw, pitch, effects, hips)
	if self.off then return end
	local dt = self.last_t and now - self.last_t or 0
	if dt > 0 and dt < M.MIN_DT then return end
	self:ensure_ring()
	if not continuous or not self.last_t then self.settle_until = now + M.SETTLE end
	local snap, d, rider = g.snap, (g.frame and g.frame.debug) or {}, g.skater_position
	local orbit = g.cam and g.cam.adaptive_orbit or {}
	local to_rider = rider - final
	local depth = vector.dot(to_rider, forward)
	local right = vector.normalize(vector.cross(forward, up))
	local half = tan(rad((fov or 65) * 0.5))
	local sx, sy = 99, 99
	if depth > 0.05 then sx, sy = vector.dot(to_rider, right) / (depth * half * 1.78), vector.dot(to_rider, up) / (depth * half) end
	local rays = (g.rays_total or 0) - self.last_rays
	self.last_rays = g.rays_total or 0
	local pos, vel, fwd, n = snap.position, snap.velocity, snap.forward, snap.ground_normal
	local i = self.head % M.CAP + 1
	local c, h = self.c, hips or ZERO
	local orb_deg = deg(orbit.yaw or 0)
	local state = snap.physics_state or 0
	c[1][i], c[2][i], c[3][i], c[4][i], c[5][i], c[6][i], c[7][i] = now, dt, state, g.display_flags or 0, d.shot_name or "-", cause or "-", continuous and 1 or 0
	c[8][i], c[9][i], c[10][i], c[11][i], c[12][i], c[13][i] = pos.x, pos.y, pos.z, rider.x, rider.y, rider.z
	c[14][i], c[15][i], c[16][i], c[17][i], c[18][i], c[19][i] = vel.x, vel.y, vel.z, fwd.x, fwd.y, fwd.z
	c[20][i], c[21][i], c[22][i], c[23][i], c[24][i], c[25][i] = snap.ground_clearance or 0, snap.ground_height or 0, n.x, n.y, n.z, snap.ground_valid and 1 or 0
	c[26][i], c[27][i], c[28][i], c[29][i], c[30][i], c[31][i] = final.x, final.y, final.z, forward.x, forward.y, forward.z
	c[32][i], c[33][i], c[34][i], c[35][i] = up.x, up.y, up.z, fov or 0
	c[36][i], c[37][i], c[38][i], c[39][i], c[40][i], c[41][i], c[42][i] = original.x, original.y, original.z, core_yaw, core_pitch, yaw, pitch
	c[43][i], c[44][i], c[45][i], c[46][i], c[47][i] = effects, correction or 0, mag(before_guard - original), mag(after_guard - before_guard), mag(final - after_guard)
	c[48][i], c[49][i], c[50][i], c[51][i], c[52][i] = orb_deg, orbit.constrained and 1 or 0, deg(d.motion_trick_target or 0), d.distance or 0, deg(d.elevation or 0)
	c[53][i], c[54][i], c[55][i], c[56][i] = deg(d.downhill_lift or 0), deg(d.air_rise or 0), d.collision_pull or 0, rays
	c[57][i], c[58][i], c[59][i], c[60][i], c[61][i], c[62][i] = depth, sx, sy, h.x, h.y, h.z
	self.head, self.count = i, math.min(self.count + 1, M.CAP)
	local air = state >= 200 and state < 300
	if air then self.ground_since = nil elseif not self.ground_since then self.ground_since = now end
	local pz_prev = self.prev_rel
	local rel = final - rider
	if now >= self.settle_until and continuous and dt > 0 then
		local step = math.max(dt, M.MIN_DT)
		local yaw_rate = abs(delta(yaw, self.prev_yaw or yaw)) / step
		local pitch_rate = abs((pitch - (self.prev_pitch or pitch)) - (effects - (self.prev_fx or effects))) / step
		local eye_rate = pz_prev and mag(rel - pz_prev) / step or 0
		if depth <= M.BEHIND_DEPTH then self:trigger(now, "rider_behind", depth)
		elseif eye_rate > M.EYE_RATE then self:trigger(now, "eye_jump", eye_rate)
		elseif yaw_rate > M.YAW_RATE then self:trigger(now, "yaw_kick", yaw_rate)
		elseif pitch_rate > M.PITCH_RATE then self:trigger(now, "pitch_kick", pitch_rate)
		elseif abs(orb_deg) >= M.ORBIT_DEG then self:trigger(now, "orbit_limit", orb_deg) end
		if abs(sx) > M.FRAME_LIMIT or abs(sy) > M.FRAME_LIMIT then
			self.off_frames += 1
			if self.off_frames == M.FRAME_FRAMES then self:trigger(now, "rider_off_frame", math.max(abs(sx), abs(sy))) end
		else self.off_frames = 0 end
	end
	self.prev_rel, self.prev_yaw, self.prev_pitch, self.prev_fx, self.last_t = rel, yaw, pitch, effects, now
end

local function key_down(key)
	local ok, value = pcall(reskate.input.key, #key == 1 and string.byte(key) or key)
	return ok and value == true
end

function R:poll_hotkey(now)
	local down = key_down(M.HOTKEY) and key_down("Ctrl") and key_down("Shift")
	if down and not self.was_down then
		if self:trigger(now, "hotkey", 1) then pcall(reskate.log, "dyncam: recorder clip marked by Ctrl+Shift+R") end
	end
	self.was_down = down
end

function R:header(settings)
	local s, f = settings, settings and settings.follow or {}
	local low, high = s and s.ride_distance or {}, s and s.ride_distance_high or {}
	local lines = {
		"# dyncam-recorder 1",
		string.format("# version=%s trigger=%s value=%.3f at=%.4f before=%.1f after=%.1f", self.version, self.why, self.value, self.at, M.BEFORE, M.AFTER),
		string.format("# settings style=%s pop=%d crouch=%d angle=%s low_mode=%s low=%.2f high_mode=%s high=%.2f collision=%d",
			tostring(f.camera_style), f.trick_pop and 1 or 0, f.crouch_enabled and 1 or 0, tostring(s and s.angle), tostring(low.mode), low.fixed or 0, tostring(high.mode), high.fixed or 0,
			s and s.collision and s.collision.enabled and 1 or 0),
	}
	for _, ev in self.events do lines[#lines + 1] = string.format("# event t=%.4f name=%s value=%.3f", ev.t, ev.name, ev.value) end
	local names = {}
	for i, col in M.COLUMNS do names[i] = col[1] end
	lines[#lines + 1] = table.concat(names, "\t")
	return lines
end

function R:begin_format(settings)
	local from, seen = self.head, 1
	local first_t = self.at - M.BEFORE
	while seen < self.count do
		local prev = (from - 2) % M.CAP + 1
		if self.c[1][prev] < first_t then break end
		from, seen = prev, seen + 1
	end
	self.from, self.left, self.frames = from, seen, seen
	self.parts = self:header(settings)
	self.bytes, self.truncated = 0, false
	for _, line in self.parts do self.bytes += #line + 1 end
	self.phase = "format"
end

function R:format_some()
	local c, buf, parts, fmt = self.c, self.buf, self.parts, self.line_format
	for _ = 1, math.min(M.LINES_PER_TICK, self.left) do
		local i = self.from
		for col = 1, N do buf[col] = c[col][i] end
		local line = string.format(fmt, table.unpack(buf, 1, N))
		self.bytes += #line + 1
		if self.bytes > M.MAX_BYTES then
			self.truncated, self.left = true, 0
			break
		end
		parts[#parts + 1] = line
		self.from, self.left = i % M.CAP + 1, self.left - 1
	end
	if self.left <= 0 then self.phase, self.wait_since = "wait", nil end
end

function R:prune()
	local ok, names = pcall(reskate.files.list, M.FOLDER)
	if not ok or type(names) ~= "table" then return end
	local files = {}
	for _, name in names do
		if type(name) == "string" and string.sub(name, -4) == ".tsv" then
			files[#files + 1] = string.find(name, M.FOLDER .. "/", 1, true) == 1 and name or (M.FOLDER .. "/" .. name)
		end
	end
	table.sort(files)
	for i = 1, #files - M.KEEP do pcall(reskate.files.remove, files[i]) end
end

function R:write(now)
	if not self.session then
		local ok, t = pcall(os.time)
		self.session = ok and t or math.floor(now)
	end
	self.clips += 1
	local path = string.format("%s/rec_%d_%03d.tsv", M.FOLDER, self.session, self.clips)
	local started = os.clock()
	local ok, wrote, why = pcall(reskate.files.write, path, table.concat(self.parts, "\n") .. "\n")
	self:prune()
	local ms = (os.clock() - started) * 1000
	if ok and wrote == true then self.written += 1 end
	pcall(reskate.log, string.format("dyncam: recorder clip %d %s value=%.2f frames=%d bytes=%d write=%.1fms%s%s", self.clips, self.why, self.value, self.frames, self.bytes, ms,
		self.truncated and " truncated" or "", (ok and wrote == true) and "" or (" failed: " .. tostring(why or wrote))))
	self.phase, self.parts, self.cooldown_until = nil, nil, now + M.COOLDOWN
end

-- Once per tick, after the camera. Never does more than a few lines of text, except the one write.
function R:pump(now, settings)
	if self.off then return end
	self:poll_hotkey(now)
	local phase = self.phase
	if phase == "capture" then
		if now >= self.stop_at then
			if self.count > 0 then self:begin_format(settings) else self.phase = nil end
		end
	elseif phase == "format" then
		self:format_some()
	elseif phase == "wait" then
		self.wait_since = self.wait_since or now
		local riding = self.last_t and now - self.last_t < 0.2
		local settled = self.ground_since and now - self.ground_since >= M.GROUND_WAIT
		if not riding or settled or now - self.wait_since >= M.MAX_WAIT then self:write(now) end
	end
end

function R:status()
	if self.off then return "off" end
	return string.format("on, %d clips saved this session%s", self.written, self.phase and (", " .. self.phase) or "")
end

return M
