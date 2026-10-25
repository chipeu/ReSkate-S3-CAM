-- manual.lua: manuals from the physics state (101), the trick list only for the log.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_manual.lua
local T = require("tlib")
local Manual = require("manual")
T.group("manual")
local expect = T.expect

local function name(entry, text) return { entry = tostring(entry), kind = "n", text = text } end
local function note(entry, kind, text) return { entry = tostring(entry), kind = kind, text = text } end

-- Ticks at 60 Hz from t0 for `seconds` in `state` (a number, or a function of the time since t0); returns whether the detector was
-- on at the end and at any time, and the end time.
local function run(m, t0, seconds, state, onboard, airborne, grinding, pitch_at)
	local on, ever = false, false
	local n = math.floor(seconds * 60 + 0.5)
	for i = 1, n do
		local t = t0 + i / 60
		local st = type(state) == "function" and state(t - t0) or state or 100
		on = m:update(t, st, onboard ~= false, airborne == true or st == 201 or st == 200, grinding == true, pitch_at and pitch_at(t - t0) or nil)
		ever = ever or on
	end
	return on, ever, t0 + n / 60
end

-- 1. Rolling (100) with the feet wobbling 10-15 degrees and a Manual note: never on. The source is the physics state.
do
	local m = Manual.new()
	expect(m.source == "physics state", "the source is the physics state from the start")
	m:on_notes({ name(1, "Manual") }, 0.5)
	local _, ever = run(m, 0, 5, 100, true, false, false, function(t) return 12.5 + 2.5 * math.sin(t * 9) end)
	expect(not ever, "feet and even a Manual note never start a manual while the state is 100")
	expect(m.count == 0, "nothing counted")
end

-- 2. State 101 for 0.06 s: on, once, counted once.
do
	local m = Manual.new()
	local _, _, t = run(m, 0, 1, 100)
	expect(m:update(t + 1 / 60, 101, true, false, false, nil) == false, "the first tick of 101: not yet")
	expect(m:update(t + 2 / 60, 101, true, false, false, nil) == false, "two ticks: not yet (0.033 s)")
	expect(m:update(t + 3 / 60, 101, true, false, false, nil) == false, "three ticks: not yet")
	expect(m:update(t + 4 / 60, 101, true, false, false, nil) == false, "four ticks: 0.05 s in the state, not yet")
	expect(m:update(t + 5 / 60, 101, true, false, false, nil) == true, "five ticks: 0.067 s in the state, on")
	expect(m.count == 1, "counted")
	expect(m.last_event ~= "" and string.find(m.last_event, "101", 1, true) ~= nil, "an event text for the log naming the state: " .. m.last_event)
	local on = run(m, t + 5 / 60, 1.5, 101)
	expect(on and m.count == 1, "stays on, counted once")
end

-- 3. A single tick of 101 is not a manual.
do
	local m = Manual.new()
	local _, ever = run(m, 0, 1, function(t) return (t > 0.5 and t < 0.52) and 101 or 100 end)
	expect(not ever and m.count == 0, "one tick of 101 does not start a manual")
end

-- 4. Off once the state has been anything else for 0.15 s; a one-tick flicker does not end it.
do
	local m = Manual.new()
	local _, _, t = run(m, 0, 0.5, 101)
	expect(m.on, "on")
	expect(m:update(t + 1 / 60, 100, true, false, false, nil) == true, "one tick of 100: still on")
	expect(m:update(t + 2 / 60, 101, true, false, false, nil) == true, "back to 101: on")
	local on_mid, _, t1 = run(m, t + 2 / 60, 0.1, 100)
	expect(on_mid, "0.1 s in another state: still on")
	local on_end = run(m, t1, 0.1, 100)
	expect(on_end == false and not m.on, "0.15 s in another state: off")
	expect(string.find(m.last_event, "off", 1, true) ~= nil, "an off event text: " .. m.last_event)
	-- and it can start again
	local again = run(m, t1 + 0.1, 0.3, 101)
	expect(again and m.count == 2, "a second manual is counted")
end

-- 5. Landing straight into a manual: 201 then 101.
do
	local m = Manual.new()
	local _, ever_air, t = run(m, 0, 0.5, 201)
	expect(not ever_air, "in the air: no manual")
	local on = run(m, t, 0.1, 101)
	expect(on and m.count == 1, "201 -> 101: on 0.06 s after the landing")
	local off = run(m, t + 0.1, 0.3, 100)
	expect(not off, "then 100: off")
	-- a manual, then a pop (200/201): it ends in 0.15 s and does not stay on through the air
	local o = Manual.new()
	local _, _, t2 = run(o, 0, 0.5, 101)
	local still = run(o, t2, 0.3, 201)
	expect(not still, "101 -> 201: off")
end

-- 6. Not on the board, or grinding, is not a manual; leaving the board ends one at once.
do
	local m = Manual.new()
	local _, ever = run(m, 0, 0.5, 101, false)
	expect(not ever, "state 101 off the board: no manual")
	local g = Manual.new()
	local _, ever_g = run(g, 0, 0.5, 101, true, false, true)
	expect(not ever_g, "state 101 while grinding: no manual")
	local b = Manual.new()
	run(b, 0, 0.5, 101)
	expect(b:update(0.6, 504, false, false, false, nil) == false, "off the board: off at once")
end

-- 7. The trick list does not start or end a manual.
do
	local m = Manual.new()
	m:on_notes({ name(7, "Manual") }, 2.0)
	local _, ever = run(m, 2.0, 1, 100)
	expect(not ever, "a Manual note with the state at 100: nothing")
	local _, _, t = run(m, 3.0, 0.5, 101)
	expect(m.on, "state 101: on")
	m:on_notes({ name(8, "Kickflip"), note(7, "l", "ID_TRICK_LANDING_OK") }, t)
	local on = run(m, t, 0.5, 101)
	expect(on, "Kickflip and landing notes do not end it while the state is 101")
end

-- 8. The notes go to the log: each name with the state and time it came at.
do
	local m = Manual.new()
	run(m, 0, 0.5, 101)
	m:on_notes({ name(3, "Manual"), note(3, "l", "x"), name(4, "Kickflip") }, 0.55)
	local lines = {}
	m:drain_log(function(text) lines[#lines + 1] = text end)
	expect(#lines == 3, "three log lines (" .. #lines .. ")")
	expect(string.find(lines[1], "Manual", 1, true) and string.find(lines[1], "state 101", 1, true) and string.find(lines[1], "manual on", 1, true),
		"the name, the state and whether the manual was on: " .. tostring(lines[1]))
	expect(string.find(lines[2], "landing", 1, true) and string.find(lines[2], "Manual", 1, true), "the landing note says which trick: " .. tostring(lines[2]))
	expect(string.find(lines[3], "Kickflip", 1, true) ~= nil and string.find(lines[3], "t=0.55", 1, true) ~= nil, "and the time: " .. tostring(lines[3]))
	local again = 0
	m:drain_log(function() again += 1 end)
	expect(again == 0, "drained once")
	for i = 1, 100 do m:on_notes({ name(i, "T" .. i) }, i) end
	local n = 0
	m:drain_log(function() n += 1 end)
	expect(n == Manual.max_log, "the log queue is bounded (" .. n .. ")")
	m:on_notes("not a table", 0)
	m:on_notes(nil, 0)
	expect(true, "bad notes are ignored")
end

-- 9. Names
do
	expect(Manual.is_manual_name("Manual") and Manual.is_manual_name("one foot MANUAL") and not Manual.is_manual_name("Kickflip")
		and not Manual.is_manual_name(nil), "is_manual_name")
end

-- 10. reset
do
	local m = Manual.new()
	run(m, 0, 0.5, 101)
	m:reset()
	expect(m.source == "physics state" and not m.on, "reset forgets the manual and keeps the source")
	expect(m:update(0.52, 101, true, false, false, nil) == false, "and the 101 timer starts again")
end

-- 11. The app: notes reach the detector (the log), the glue gets it, a manual comes from the state; a refused feed warns once.
do
	local mock = require("mock_reskate")
	local function setup(refuse)
		local m = mock.install()
		local r = m.reskate
		r.input.gamepad = function() return nil end
		r.menu.game = function() return { open = false } end
		r.ui.dialog = function() return true end
		r.files.reveal = function() return true end
		m.state.tricks_refuse = refuse
		return m, require("app").start()
	end
	local m, app = setup(nil)
	expect(m.tricks_feeding, "reskate.tricks.feed(true) is called at start")
	expect(app.manual ~= nil and app.glue.manual_detector == app.manual, "app.manual is the glue's manual_detector")
	m.clock_ms = 5000
	m.trick_notes({ name(4, "Manual") })
	expect(#app.manual.log == 1, "trick_notes reach the detector (for the log)")
	expect(app.manual:update(5.02, 100, true, false, false, nil) == false, "and start nothing")
	local bad, bad_app = setup("permission")
	local warns = 0
	for _, l in ipairs(bad.logs) do
		if l[1] == "warn" and string.find(l[2], "trick list", 1, true) then warns += 1 end
	end
	expect(warns == 1 and bad_app.manual ~= nil, "a refused feed logs one warning and the app still starts")
	local _, ever = run(bad_app.manual, 0, 0.5, 101)
	expect(ever, "and a manual is still found from the state")
end

T.done()
if T.failures > 0 then error("test_manual failed") end
