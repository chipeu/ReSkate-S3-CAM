-- diag.lua: the running log goes to the file and to ReSkate.log, the file keeps 5000 lines under the 1 MB file limit.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_diag.lua
local T = require("tlib")
local mock = require("mock_reskate")
local Diag = require("diag")
T.group("diag")
local expect = T.expect

local function logged_with(m, text)
	local n = 0
	for _, l in ipairs(m.logs) do
		if string.find(l[2], text, 1, true) then n += 1 end
	end
	return n
end

-- 1. A note reaches both places, with the prefix; the path is told once.
do
	local m = mock.install()
	local d = Diag.new()
	d:begin_run()
	d:note("s3cam state 100 -> 103 after 1.20 s")
	d:note("s3cam manual on (Manual)")
	expect(logged_with(m, "dyncam: s3cam state 100 -> 103 after 1.20 s") == 1, "an event line is in ReSkate.log with the prefix")
	expect(logged_with(m, "dyncam: s3cam manual on (Manual)") == 1, "a second line too")
	expect(logged_with(m, "Mods\\.reskate_plugin_data\\Dynamic_Camera\\diag\\camera_log.txt") == 1, "the path of the file is told once")
	d:tick(10)
	expect(m.files["diag/camera_log.txt"] ~= nil and string.find(m.files["diag/camera_log.txt"], "manual on", 1, true) ~= nil, "and in the file")
	-- a line the caller logged itself is not repeated
	d:note("on: angle low", true)
	expect(logged_with(m, "on: angle low") == 0, "a line already logged is not logged again")
	expect(string.find(m.files["diag/camera_log.txt"] or "", "on: angle low", 1, true) == nil, "(file written at the next tick)")
	d:end_run("test")
	expect(string.find(m.files["diag/camera_log.txt"], "on: angle low", 1, true) ~= nil, "but it is in the file")
end

-- 2. Per-frame samples stay out of ReSkate.log.
do
	local m = mock.install()
	local d = Diag.new()
	d:begin_run()
	local before = #m.logs
	for i = 1, 100 do
		local s = { t = i / 60, state = 100, shot = "x", air = false, manual = false, steps = 1, skater = vector.create(0, 0, i * 0.1),
			velocity = vector.create(0, 0, 6), board = vector.create(0, 0, i * 0.1), board_valid = true, board_target = vector.create(0, 0, 0),
			look = vector.create(0, 0, 0), orbit_anchor = vector.create(0, 0, 0), skater_anchor = vector.create(0, 0, 0),
			camera = vector.create(0, 2, i * 0.1 - 4), camera_free = vector.create(0, 0, 0), carried = vector.create(0, 0, 0),
			pitch = 10, yaw = 0, fov = 60, pull = 0, board_v = 0, root_v = 0, floor_w = 1 }
		d:push(s)
	end
	expect(#m.logs == before, "calm samples write nothing to ReSkate.log")
end

-- 3. The file keeps 5000 lines and stays under 1 MB, even with the long summary lines.
do
	local m = mock.install()
	local d = Diag.new()
	d:begin_run()
	for i = 1, 6200 do
		d:note(string.format("line %d", i), true)
	end
	d:end_run("test")
	local text = m.files["diag/camera_log.txt"]
	local lines = 0
	for _ in string.gmatch(text, "[^\n]+") do lines += 1 end
	expect(lines <= 5000 and lines >= 4900, "about 5000 lines kept (got " .. lines .. ")")
	expect(Diag.log_lines == 5000, "the cap is 5000")
	expect(string.find(text, "line 6200\n", 1, true) ~= nil and string.find(text, "line 1200\n", 1, true) == nil, "the newest are kept, the oldest dropped")
	local long = string.rep("x", 400)
	local m2 = mock.install()
	local d2 = Diag.new()
	for i = 1, 5000 do d2:note(long .. i, true) end
	d2:end_run("test")
	local size = #m2.files["diag/camera_log.txt"]
	expect(size <= 1048576 and size <= Diag.log_bytes + 1000, "long lines: the file stays under the 1 MB limit (" .. size .. " bytes)")
	expect(m2.files["diag/camera_log.txt"] ~= nil, "and it is written")
end

-- 4. A burst of lines does not use up ReSkate's 50 lines a second: the rest is counted.
do
	local m = mock.install()
	local d = Diag.new()
	d:begin_run()
	local before = #m.logs
	for i = 1, 200 do d:note("burst " .. i) end
	local sent = #m.logs - before
	expect(sent <= Diag.log_burst, "a burst sends at most log_burst lines (sent " .. sent .. ")")
	m.tick(1500)
	d:note("after")
	expect(logged_with(m, "more lines in a second are only in camera_log.txt") == 1, "the next second says how many were left out")
	expect(logged_with(m, "dyncam: after") == 1, "and logging goes on")
end

T.done()
if T.failures > 0 then error("test_diag failed") end
