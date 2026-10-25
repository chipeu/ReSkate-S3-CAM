-- How loading goes. ReSkate stops a plugin whose entry file or any later call takes longer than 50 ms of wall-clock time, and a
-- level load keeps the disk and CPU busy. main.lua therefore waits for a settled game, loads one module a tick and rests after a
-- slow one. This runs one timeline against the mock (the first run of a module cache can not be repeated in one process):
--   1. the skater is there but ticks are slow (80 ms): nothing is required;
--   2. 29 steady ticks: still nothing; the 30th starts it, one module a tick;
--   3. a require that takes 20 ms is followed by 10 ticks of rest;
--   4. the app is up with its page, and no tick came near 50 ms.
-- It also prints what each module costs to compile (its first require, files warm: run it twice for warm numbers).
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\time_load.lua
local T = require("tlib")
T.group("load")
local expect = T.expect
local mock = require("mock_reskate")
local m = mock.install({ limit_rays = true })
local r = m.reskate
r.input.gamepad = function() return nil end
r.menu.game = function() return { open = false } end
r.ui.dialog = function() return true end
r.files.reveal = function() return true end

-- Count (and time) every require the plugin makes from its tick handler (not the ones modules make while loading). When
-- `slow_next` is set the next one is made to take 20 ms on the mock's clock, as a busy disk would.
local real_require = require
local required, times, depth, slow_next = {}, {}, 0, false
require = function(name)
	if depth > 0 then
		return real_require(name)
	end
	required[#required + 1] = name
	if slow_next then
		slow_next = false
		m.clock_ms += 20
	end
	depth += 1
	local a = os.clock()
	local ok, result = pcall(real_require, name)
	times[name] = times[name] or (os.clock() - a) * 1000
	depth -= 1
	if not ok then error(result, 0) end
	return result
end

local a = os.clock()
real_require("main")
local entry = (os.clock() - a) * 1000
print(string.format("entry file             %7.2f ms (limit 50)", entry))
expect(entry < 10, "the entry file only queues the modules")
expect(#required == 0, "and requires nothing")

-- 1. Slow ticks (a level loading): nothing loads, however many.
for _ = 1, 100 do m.tick(80) end
expect(#required == 0, "100 ticks of 80 ms: nothing is required")
-- a long frame in the middle of a steady run starts the count again
for _ = 1, 29 do m.tick(1000 / 60) end
m.tick(80)
for _ = 1, 29 do m.tick(1000 / 60) end
expect(#required == 0, "a slow tick inside a steady run starts the count again")

-- 2. The 30th steady tick starts it.
m.tick(1000 / 60)
expect(#required == 1, "30 steady ticks in a row: loading begins with one module (" .. #required .. ")")
m.tick(1000 / 60)
expect(#required == 2, "and then one module a tick")

-- 3. A slow module (20 ms) is followed by a rest of 10 ticks.
slow_next = true
local base = #required
m.tick(1000 / 60)
expect(#required == base + 1, "the slow module loads")
for _ = 1, 10 do m.tick(1000 / 60) end
expect(#required == base + 1, "then 10 ticks of rest: nothing is required")
m.tick(1000 / 60)
expect(#required == base + 2, "and it goes on after them")

-- 4. To the end.
local worst, ticks = 0, 0
while not (m.page_title ~= nil and m.handlers.tick and #m.handlers.tick >= 2) and ticks < 300 do
	local t = os.clock()
	m.tick(1000 / 60)
	worst = math.max(worst, (os.clock() - t) * 1000)
	ticks += 1
end
expect(m.page_title ~= nil, "the menu page exists after loading (" .. ticks .. " more ticks)")
print(string.format("slowest tick while loading %5.2f ms (limit 50) over %d ticks", worst, ticks))
expect(worst < 40, "no tick of the loading comes near the 50 ms limit")
for _, l in ipairs(m.logs) do
	expect(l[1] ~= "error", "no error logged: " .. l[2])
end
local feeding = m.tricks_feeding
expect(feeding, "the trick feed is on after loading")

-- Every module the list names, with what its first require took.
local list = {}
for name, ms in pairs(times) do list[#list + 1] = { name, ms } end
table.sort(list, function(x, y) return x[2] > y[2] end)
local over = {}
for _, item in list do
	print(string.format("  %-10s %6.2f ms", item[1], item[2]))
	if item[2] > 6 then over[#over + 1] = item[1] end
end
print(table.concat(required, " "))
print("modules over 6 ms: " .. (#over > 0 and table.concat(over, ", ") or "none"))
T.done()
if T.failures > 0 then error("time_load failed") end
