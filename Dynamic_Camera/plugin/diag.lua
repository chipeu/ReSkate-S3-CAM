-- Port of Extension/Camera/s3cam_diag.h: Dynamic Camera diagnostics (dyncam_log 1). One sample per drawn frame of where the
-- skater and his board are, what the camera tracks and how each stage moved it, kept in a short ring. A frame that looks like
-- a fault (the view pitching or turning too fast, the camera jumping relative to the skater, a sudden collision pull, the board
-- or the skater leaving the frame) dumps the half second before and after it, at most once per cooldown and max_dumps times in a run.
--
-- Differences from the DLL: reskate.log takes 50 lines a second, so the per-frame samples and the dumps go to files in the data
-- folder (diag/snap_1.txt .. snap_10.txt, taken in turn) and the log gets one summary line per dump. The running log (state and
-- shot changes, manuals, landings, the once-a-second summary) goes to diag/camera_log.txt, the last 5000 lines, and every line of
-- it is also sent to ReSkate.log with a "dyncam: " prefix: that is the file a player sends, so the story of a ride has to be in
-- it. Never more than M.log_burst of those a second, the rest are counted in one line. Nothing is recorded or written while
-- logging is off.
--
--   local d = Diag.new()
--   d:begin_run(); d:push(Diag.sample_of(t, state, manual, frame, snapshot)); d:note("line"); d:tick(now); d:end_run(reason)
--   Diag.fault(prev, now) -> text or ""      Diag.Recorder.new():push(sample) -> lines

local M = {}

M.pre_frames = 30 -- frames dumped up to the faulty one (included): ~0.5 s at 60 fps
M.post_frames = 30
M.cooldown = 2.0 -- s between two dumps
M.max_dumps = 30 -- dumps in one run
M.snap_files = 10 -- snapshot files in turn
M.log_lines = 5000 -- lines kept in camera_log.txt
M.log_bytes = 900000 -- and at most this much text: ReSkate writes a file of 1 MB at most, and the summary lines are long
M.log_burst = 30 -- lines a second sent on to ReSkate.log (it takes 50 from the whole plugin)
M.log_path = "Mods\\.reskate_plugin_data\\Dynamic_Camera\\diag\\camera_log.txt"
M.log_flush = 3.0 -- s between writes of the running log

-- What counts as a fault. The gates' own limits where there is one, with room for the vert swing.
M.pitch_rate_limit = 90.0 -- deg/s of view pitch
M.yaw_rate_limit = 250.0 -- deg/s of view yaw
M.camera_step_limit = 10.0 -- m/s of the camera relative to the skater
M.pull_step_limit = 0.25 -- m of collision pull gained or lost in one frame
M.out_of_frame = 100.0 -- % of the half vertical fov

local ZERO = vector.create(0, 0, 0)
local RAD = math.pi / 180
local atan2 = function(y, x)
	return math.atan2(y, x)
end

local function in_frame(f, point)
	local d = point - f.pos
	local len = vector.magnitude(d)
	local to = len > 1e-9 and d / len or vector.create(0, 0, 1)
	local half = 0.5 * math.max(f.fov_deg, 1.0) * RAD
	return atan2(vector.dot(to, f.up), vector.dot(to, -f.back)) / half * 100.0
end

local function num(x)
	return type(x) == "number" and x or 0
end
local function vec(x)
	return x or ZERO
end

function M.sample_of(t, state, manual, frame, s)
	local d = frame.debug or {}
	local function deg(r)
		return num(r) / RAD
	end
	local look_dir = -frame.back
	local out = {
		t = t,
		state = state,
		shot = d.shot_name or "",
		air = d.airborne and true or false,
		manual = manual and true or false,
		steps = num(d.steps),
		skater = s.position,
		velocity = s.velocity,
		board = s.board_position,
		board_valid = s.board_valid and true or false,
		forward_yaw = deg(atan2(-s.forward.x, s.forward.z)),
		board_target = vec(d.board_target),
		look = vec(d.look_target),
		orbit_anchor = vec(d.orbit_anchor),
		skater_anchor = vec(d.skater_anchor),
		camera = frame.pos,
		camera_free = vec(d.camera_free),
		carried = vec(d.carried),
		yaw = deg(atan2(-look_dir.x, look_dir.z)),
		pitch = deg(math.asin(math.clamp(look_dir.y, -1, 1))),
		fov = frame.fov_deg,
		distance = num(d.distance),
		elevation = deg(d.elevation),
		keep = deg(d.keep_pitch_offset),
		keep_w = num(d.keep_weight),
		pull = num(d.collision_pull),
		board_w = num(d.board_weight),
		floor_w = num(d.floor_weight),
		landing_w = num(d.landing_look_weight),
		focus_w = num(d.focus_weight),
		trick_yaw = deg(d.trick_yaw),
		view_heading = deg(d.view_heading),
		travel_heading = deg(d.travel_heading),
		follow_w = num(d.follow_weight),
		anchor_lag = num(d.anchor_lag),
		follow_k = num(d.follow_strength),
		speed = num(d.speed),
	}
	out.root_v = in_frame(frame, s.position)
	out.board_v = in_frame(frame, s.board_valid and s.board_position or out.board_target)
	return out
end

local function v3(v)
	return string.format("(%.2f,%.2f,%.2f)", v.x, v.y, v.z)
end

-- One sample as a log line (every line starts "s3cam diag").
function M.line(s)
	return string.format(
		"s3cam diag f t=%.3f state %d shot %s air %d manual %d steps %d | skater %s vel %s fwd %.1f | board %s%s board_target %s | "
			.. "look %s orbit %s skater_anchor %s lag %.2f k %.2f | cam %s free %s carried %s | yaw %.1f pitch %.1f fov %.1f | "
			.. "dist %.2f elev %.1f keep %.1f keep_w %.2f pull %.2f | board_w %.2f floor_w %.2f landing_w %.2f focus %.2f | "
			.. "trick %.1f view %.1f travel %.1f follow_w %.2f speed %.1f | root %.0f%% board %.0f%%",
		s.t, s.state or 0, tostring(s.shot), s.air and 1 or 0, s.manual and 1 or 0, s.steps or 0, v3(s.skater), v3(s.velocity),
		s.forward_yaw or 0, v3(s.board), s.board_valid and "" or " (estimate)", v3(s.board_target), v3(s.look), v3(s.orbit_anchor),
		v3(s.skater_anchor), s.anchor_lag or 0, s.follow_k or 0, v3(s.camera), v3(s.camera_free), v3(s.carried), s.yaw or 0,
		s.pitch or 0, s.fov or 0, s.distance or 0, s.elevation or 0, s.keep or 0, s.keep_w or 0, s.pull or 0, s.board_w or 0,
		s.floor_w or 0, s.landing_w or 0, s.focus_w or 0, s.trick_yaw or 0, s.view_heading or 0, s.travel_heading or 0,
		s.follow_w or 0, s.speed or 0, s.root_v or 0, s.board_v or 0)
end

local function remainder360(a)
	return a - 360.0 * math.floor(a / 360.0 + 0.5)
end

-- Why `now` looks like a fault next to `prev`, or "". Edge-triggered for the framing (a point that was in and is out).
function M.fault(prev, now)
	local dt = now.t - prev.t
	if not (dt > 0.0) or dt > 0.1 then
		return ""
	end
	local hz = 1.0 / dt
	local pitch_rate = math.abs(now.pitch - prev.pitch) * hz
	if pitch_rate > M.pitch_rate_limit then
		return string.format("pitch %.0f deg/s", pitch_rate)
	end
	local yaw_rate = math.abs(remainder360(now.yaw - prev.yaw)) * hz
	if yaw_rate > M.yaw_rate_limit then
		return string.format("yaw %.0f deg/s", yaw_rate)
	end
	local rel, rel_prev = now.camera - now.skater, prev.camera - prev.skater
	local step = vector.magnitude(rel - rel_prev) * hz
	if step > M.camera_step_limit then
		return string.format("camera step %.1f m/s relative to the skater", step)
	end
	if math.abs(now.pull - prev.pull) > M.pull_step_limit then
		return string.format("collision pull %.2f -> %.2f m", prev.pull, now.pull)
	end
	if math.abs(now.board_v) > M.out_of_frame and math.abs(prev.board_v) <= M.out_of_frame then
		return string.format("board out of the frame (%.0f%%)", now.board_v)
	end
	-- In a close-up the camera looks at the board: the root above the frame is the player's framing there.
	if now.floor_w < 0.5 and math.abs(now.root_v) > M.out_of_frame and math.abs(prev.root_v) <= M.out_of_frame then
		return string.format("skater out of the frame (%.0f%%)", now.root_v)
	end
	return ""
end

-- ---------------------------------------------------------------- the ring and the dump state of one run
local Recorder = {}
Recorder.__index = Recorder
M.Recorder = Recorder

function Recorder.new()
	return setmetatable({ ring = {}, next = 0, count = 0, post_left = 0, dumps = 0, last_dump = 0.0, dumped = false }, Recorder)
end

-- Records `s`; returns the lines to write now (none, a dump's header and the frames before, or a frame after).
function Recorder:push(s)
	local out = {}
	local n = M.pre_frames
	local have_prev = self.count > 0
	local prev = have_prev and self.ring[(self.next + n - 1) % n] or nil
	self.ring[self.next] = s
	self.next = (self.next + 1) % n
	self.count = math.min(self.count + 1, n)
	if self.post_left > 0 then
		self.post_left -= 1
		out[1] = M.line(s)
		return out
	end
	if not have_prev or self.dumps >= M.max_dumps or (self.dumped and s.t - self.last_dump < M.cooldown) then
		return out
	end
	local why = M.fault(prev, s)
	if why == "" then
		return out
	end
	self.dumps += 1
	self.dumped = true
	self.last_dump = s.t
	local before = math.min(M.pre_frames, self.count)
	out[1] = string.format("s3cam diag #%d: %s at t=%.3f (%d frames before it, %d after)", self.dumps, why, s.t, before, M.post_frames)
	for i = before, 1, -1 do
		out[#out + 1] = M.line(self.ring[(self.next + n - i) % n])
	end
	self.post_left = M.post_frames
	return out
end

-- ---------------------------------------------------------------- files
local Diag = {}
Diag.__index = Diag

function M.new()
	return setmetatable({ rec = Recorder.new(), dump = nil, dump_count = 0, log = {}, log_bytes = 0, log_dirty = false, log_at = 0.0,
		written = 0, path_told = false, mirror_second = -1, mirror_count = 0, mirror_left_out = 0 }, Diag)
end

local function write(path, text)
	local ok, wrote = pcall(reskate.files.write, path, text)
	return ok and wrote == true
end

-- Sends a line to ReSkate.log, at most M.log_burst a second; what does not fit is counted and told in the next second.
function Diag:mirror(text)
	local ok_now, ms = pcall(reskate.time.now)
	local second = ok_now and math.floor(ms / 1000) or 0
	if second ~= self.mirror_second then
		self.mirror_second = second
		self.mirror_count = 0
		if self.mirror_left_out > 0 then
			local left = self.mirror_left_out
			self.mirror_left_out = 0
			pcall(reskate.log, string.format("dyncam: %d more lines in a second are only in camera_log.txt", left))
		end
	end
	if self.mirror_count >= M.log_burst then
		self.mirror_left_out += 1
		return
	end
	self.mirror_count += 1
	pcall(reskate.log, "dyncam: " .. text)
end

-- Where the file is, said once.
function Diag:tell_path()
	if not self.path_told then
		self.path_told = true
		pcall(reskate.log, "dyncam: detailed log in " .. M.log_path)
	end
end

function Diag:begin_run()
	self.rec = Recorder.new()
	self.dump = nil
	self:tell_path()
end

function Diag:flush_dump(reason)
	local dump = self.dump
	if not dump then
		return
	end
	self.dump = nil
	self.dump_count += 1
	local file = string.format("diag/snap_%d.txt", (self.dump_count - 1) % M.snap_files + 1)
	local ok = write(file, table.concat(dump.lines, "\n") .. "\n")
	self.written += ok and 1 or 0
	reskate.log(string.format("dyncam diag: %s%s -> %s", dump.header, reason and (" (" .. reason .. ")") or "",
		ok and ("data folder, " .. file) or "could not write the file"))
end

function Diag:push(sample)
	for _, line in self.rec:push(sample) do
		if string.sub(line, 1, 13) == "s3cam diag #" then
			self:flush_dump("run went on before the dump was complete")
			self.dump = { header = line, lines = { line }, want = 1 + math.min(M.pre_frames, self.rec.count) + M.post_frames }
			self:note(line)
		elseif self.dump then
			self.dump.lines[#self.dump.lines + 1] = line
			if #self.dump.lines >= self.dump.want then
				self:flush_dump(nil)
			end
		end
	end
end

-- Drops the oldest lines until the log fits M.log_lines (less `extra_lines`) and M.log_bytes (a line costs its length and a newline).
function Diag:trim(extra_lines)
	local log = self.log
	local drop, bytes = 0, self.log_bytes
	while #log - drop > M.log_lines - (extra_lines or 0) or (bytes > M.log_bytes and #log - drop > 1) do
		drop += 1
		bytes -= #log[drop] + 1
	end
	if drop > 0 then
		local count = #log
		table.move(log, drop + 1, count, 1)
		for i = count, count - drop + 1, -1 do
			log[i] = nil
		end
		self.log_bytes = bytes
	end
end

-- A line for the running log (state changes, shot changes, the once-a-second status, landings). It goes to the file and to
-- ReSkate.log; `logged` says the caller has put it in ReSkate.log already (Glue:note does).
function Diag:note(line, logged)
	self:tell_path()
	local log = self.log
	log[#log + 1] = line
	self.log_bytes += #line + 1
	-- Trimmed in steps of 50 lines so that a full log does not shift 5000 entries for every new one.
	if #log > M.log_lines + 50 or self.log_bytes > M.log_bytes + 50000 then
		self:trim(50)
	end
	self.log_dirty = true
	if not logged then
		self:mirror(line)
	end
end

function Diag:write_log()
	self:trim(0)
	write("diag/camera_log.txt", table.concat(self.log, "\n") .. "\n")
end

function Diag:tick(now)
	if self.log_dirty and now - self.log_at >= M.log_flush then
		self.log_at = now
		self.log_dirty = false
		self:write_log()
	end
end

function Diag:end_run(reason)
	self:flush_dump(reason or "run ended")
	if self.log_dirty then
		self.log_dirty = false
		self:write_log()
	end
end

return M
