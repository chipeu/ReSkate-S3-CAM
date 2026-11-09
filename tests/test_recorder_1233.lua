-- Contracts of the 1.2.33 flight recorder: quiet when nothing is wrong, one complete clip around a fault, text built a few
-- lines per tick, the write held off while airborne, file limits, off switch, and a fault in it never reaching the camera.
local T = require("tlib")
local Mock = require("mock_reskate")
local v = vector.create
T.group("recorder 1233")

local function fresh()
	local m = Mock.install({})
	local Recorder = require("recorder")
	return m, Recorder, Recorder.new("test")
end
local UP = v(0, 1, 0)

-- A glue-shaped observer stub: eye 2 m behind a rider moving along +z.
local function drive(rec, m, fps, seconds, opts)
	opts = opts or {}
	local now = opts.start or 100
	local dt = 1 / fps
	local g = { snap = { position = v(0, 1, 0), velocity = v(0, 0, 8), forward = v(0, 0, 1), ground_normal = UP, physics_state = 100, ground_clearance = 0.95, ground_height = 0, ground_valid = true },
		skater_position = v(0, 1, 0), frame = { debug = { shot_name = "chase" } }, cam = { adaptive_orbit = { yaw = 0 } }, rays_total = 0, display_flags = 0 }
	local z, ticks = 0, 0
	local settings = { follow = { camera_style = "classic", trick_pop = false, crouch_enabled = true }, angle = 0, ride_distance = { mode = 1, fixed = 1.53 }, ride_distance_high = { mode = 1, fixed = 2.4 } }
	local steps = math.floor(seconds * fps + 0.5)
	for i = 1, steps do
		now += dt
		z += 8 * dt
		local rider = v(0, 1, z)
		local eye = rider + v(0, 0.5, -2)
		local forward = vector.normalize(rider - eye)
		g.snap.position, g.skater_position = rider, rider
		if opts.state then g.snap.physics_state = opts.state(i * dt) end
		if opts.at and opts.at(i * dt, g) == "behind" then eye = rider + v(0, 0, 0.2) end
		if opts.at and opts.at(i * dt, g) == "orbit" then g.cam.adaptive_orbit.yaw = math.rad(39.5) elseif g.cam.adaptive_orbit.yaw ~= 0 then g.cam.adaptive_orbit.yaw = 0 end
		rec:frame(g, now, i > 1, nil, 0, eye, eye, eye, eye, forward, UP, 65, 0, -14, 0, -14, 0, nil)
		rec:pump(now, settings)
		ticks += 1
		if opts.tick then opts.tick(now, i * dt) end
		if opts.stop and opts.stop() then break end
	end
	return now
end
local function clips(m)
	local out = {}
	for path, text in pairs(m.files) do
		if string.sub(path, 1, 9) == "recorder/" then out[#out + 1] = { path = path, text = text } end
	end
	table.sort(out, function(a, b) return a.path < b.path end)
	return out
end

-- 1: nothing wrong, nothing saved.
do
	local m, Recorder, rec = fresh()
	drive(rec, m, 60, 12)
	T.expect(#clips(m) == 0, "1: ten quiet seconds save nothing")
	T.expect(rec.count == 12 * 60, "1: the frames are in the ring")
end

-- 2: rider at the camera at 6 s: one clip, about 3 s each side, one line per frame, every column filled.
do
	local m, Recorder, rec = fresh()
	drive(rec, m, 60, 12, { at = function(t) return (t > 6 and t < 6.05) and "behind" or nil end })
	local c = clips(m)
	T.expect(#c == 1, "2: one clip (" .. #c .. ")")
	local head, n, cols, bad, prev, mono = nil, 0, #Recorder.COLUMNS, 0, -1, true
	local trigger
	for line in string.gmatch(c[1].text, "[^\n]+") do
		if string.sub(line, 1, 1) == "#" then
			trigger = trigger or string.match(line, "trigger=(%S+)")
		elseif not head then head = line
		else
			n += 1
			local fields = string.split(line, "\t")
			if #fields ~= cols then bad += 1 end
			local t = tonumber(fields[1])
			if t <= prev then mono = false end
			prev = t
		end
	end
	T.expect(trigger == "rider_behind", "2: names the trigger (" .. tostring(trigger) .. ")")
	T.expect(n >= 355 and n <= 365, "2: six seconds of frames (" .. n .. ")")
	T.expect(bad == 0, "2: every line has every column")
	T.expect(mono, "2: time only goes forward")
end

-- 3: text is spread over ticks.
do
	local m, Recorder, rec = fresh()
	local most, last_left = 0, nil
	drive(rec, m, 60, 12, { at = function(t) return (t > 4 and t < 4.03) and "behind" or nil end, tick = function()
		if rec.phase == "format" and last_left then most = math.max(most, last_left - rec.left) end
		last_left = rec.phase == "format" and rec.left or nil
	end })
	T.expect(most > 0 and most <= Recorder.LINES_PER_TICK, "3: at most " .. Recorder.LINES_PER_TICK .. " lines a tick (" .. most .. ")")
end

-- 4: the write waits for the ground, and not forever.
do
	local m, Recorder, rec = fresh()
	local in_air_write = false
	drive(rec, m, 60, 12, { at = function(t) return (t > 3 and t < 3.03) and "behind" or nil end,
		state = function(t) return (t > 5.8 and t < 7.0) and 201 or 100 end,
		tick = function(_, t) if t > 6.3 and t < 7.0 and #clips(m) > 0 then in_air_write = true end end })
	T.expect(not in_air_write and #clips(m) == 1, "4: held while airborne, written after landing")
	local m2, Recorder2, rec2 = fresh()
	drive(rec2, m2, 60, 12, { at = function(t) return (t > 3 and t < 3.03) and "behind" or nil end, state = function(t) return t > 5.5 and 201 or 100 end })
	T.expect(#clips(m2) == 1, "4: written within the limit in a long air")
end

-- 5: events join the clip being captured; nothing new starts during the cooldown.
do
	local m, Recorder, rec = fresh()
	T.expect(rec:trigger(10, "yaw_kick", 500), "5: first trigger starts a clip")
	rec:trigger(10.1, "yaw_kick", 700)
	rec:trigger(11, "eye_jump", 30)
	T.expect(#rec.events == 2 and rec.events[1].value == 700, "5: repeats merge, others are listed")
	rec.phase, rec.cooldown_until = nil, 20
	T.expect(not rec:trigger(19, "yaw_kick", 500), "5: the cooldown holds")
	T.expect(rec:trigger(20.1, "yaw_kick", 500), "5: and ends")
end

-- 6: the folder stays bounded and each file under the limit, at 240 FPS.
do
	local m, Recorder, rec = fresh()
	for i = 1, 45 do m.files[string.format("recorder/rec_100_%03d.tsv", i)] = "x" end
	drive(rec, m, 240, 12, { at = function(t) return (t > 6 and t < 6.01) and "behind" or nil end })
	local c = clips(m)
	T.expect(#c == Recorder.KEEP, "6: oldest clips are removed (" .. #c .. ")")
	local biggest = 0
	for _, f in c do biggest = math.max(biggest, #f.text) end
	T.expect(biggest > 1000 and biggest < 1000000, "6: a 240 FPS clip fits in a file (" .. biggest .. ")")
end

-- 7: hotkey fires once per press; off stays off across a restart.
do
	local m, Recorder, rec = fresh()
	m.keys[string.byte("R")], m.keys.Ctrl, m.keys.Shift = true, true, true
	rec:pump(50, nil)
	local first = rec.phase
	rec.phase = nil
	rec:pump(50.1, nil)
	T.expect(first == "capture" and rec.phase == nil, "7: holding the keys marks one clip")
	rec:set_off(true)
	T.expect(Recorder.new("x").off, "7: off is remembered")
	T.expect(not rec:trigger(60, "console", 1), "7: off saves nothing")
	rec:set_off(false)
	T.expect(not Recorder.new("x").off, "7: on is remembered")
end

-- 8: a fault in the recorder stops it and leaves the camera running.
do
	local m = Mock.install({})
	m.reskate.input.gamepad = function() return nil end
	m.reskate.menu.game = function() return { open = false } end
	local app = require("app").start()
	local glue = app.glue
	T.expect(glue.recorder ~= nil, "8: the app starts a recorder")
	glue.recorder.frame = function() error("boom") end
	glue.source, glue.blend, glue.snap.onboard, glue.skater_position = "ride", 1, true, v(0, 1, 0)
	local eye, fwd = v(0, 1.5, -2), v(0, 0, 1)
	local ok, why = pcall(glue.trace_camera_frame, glue, 1, eye, eye, eye, eye, nil, 0, fwd, 65, UP)
	T.expect(ok, "8: a fault does not reach the camera: " .. tostring(why))
	T.expect(glue.recorder == nil, "8: and stops the recorder")
end

T.done()
if T.failures > 0 then error("recorder regression") end
