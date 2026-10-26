-- manual.lua: manuals from the game's trick list (a "Manual" note on a new entry starts one, its first landing note ends it).
-- The sequences are the ones in a real game log. Physics state 101 is a Powerslide or a Revert, never a manual.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_manual.lua
local T = require("tlib")
local Manual = require("manual")
T.group("manual")
local expect = T.expect

local function name(entry, text) return { entry = tostring(entry), kind = "n", text = text } end
local function land(entry, text) return { entry = tostring(entry), kind = "l", text = text or "ID_TRICK_LANDING_OK" } end

-- Ticks at 60 Hz from t0 for `seconds` in `state` (a number, or a function of the time since t0); returns whether the detector was
-- on at the end and at any time, and the end time. 200 and 201 count as the air.
local function run(m, t0, seconds, state, onboard, grinding)
	local on, ever = false, false
	local n = math.floor(seconds * 60 + 0.5)
	for i = 1, n do
		local t = t0 + i / 60
		local st = type(state) == "function" and state(t - t0) or state or 100
		on = m:update(t, st, onboard ~= false, st == 201 or st == 200, grinding == true, nil)
		ever = ever or on
	end
	return on, ever, t0 + n / 60
end

-- k. Manual, revert, manual in one line: each manual gets its own entry and the line's end writes one landing note, for the
-- first of them. That note ends the close-up, and the line counts as one manual.
do
	local m = Manual.new()
	local _, _, t = run(m, 0, 0.5, 100)
	m:on_notes({ name(99732, "Manual") }, t)
	local on1, _, t1 = run(m, t, 1.0, 100)
	m:on_notes({ name(4295066924, "Manual") }, t1)
	local on2, _, t2 = run(m, t1, 0.5, 101)
	m:on_notes({ name(4295066988, "Manual") }, t2)
	local on3, _, t3 = run(m, t2, 1.0, 100)
	m:on_notes({ land(99732, "ID_TRICK_LANDING_OK") }, t3)
	local on4, ever4 = run(m, t3, 1.0, 100)
	expect(on1 and on2 and on3, "a manual linked through more manuals stays on")
	expect(not on4 and not ever4, "the first landing note of any manual in the line ends it")
	expect(m.count == 1, "the line counts as one manual")
end

-- a. Ollie -> 201 -> 101 "Powerslide", "Revert" named at 101: no manual at any point.
do
	local m = Manual.new()
	expect(m.source == "trick list", "the source is the trick list")
	local _, e1, t = run(m, 0, 1, 100)
	m:on_notes({ name(99732, "Ollie") }, t)
	local _, e2, t2 = run(m, t, 0.5, 201)
	m:on_notes({ name(4295066924, "Powerslide") }, t2)
	local _, e3, t3 = run(m, t2, 0.4, 101)
	m:on_notes({ name(4295066988, "Revert"), land(99732, "Ollie") }, t3)
	local _, e4, t4 = run(m, t3, 0.5, 101)
	local _, e5 = run(m, t4, 0.5, 100)
	expect(not (e1 or e2 or e3 or e4 or e5) and m.count == 0, "a revert and a powerslide at state 101 never give a manual")
end

-- b. Manual named at state 100 on a new entry: on at once; first landing note: off; repeated landing notes: nothing.
do
	local m = Manual.new()
	local _, _, t = run(m, 0, 2, 100)
	m:on_notes({ name(12885001598, "Manual") }, t)
	expect(m:update(t + 1 / 60, 100, true, false, false, nil) == true, "named at state 100: on at once")
	expect(m.count == 1 and string.find(m.last_event, "on", 1, true) ~= nil, "counted, with an event text: " .. m.last_event)
	local on, _, t1 = run(m, t, 1.7, 100)
	expect(on, "stays on for the 1.7 s of the manual")
	m:on_notes({ land(12885001598, "Manual") }, t1)
	expect(m:update(t1 + 1 / 60, 100, true, false, false, nil) == false, "its first landing note: off")
	expect(string.find(m.last_event, "off", 1, true) ~= nil, "an off event text: " .. m.last_event)
	-- the same landing note comes again every few seconds
	local _, ever = run(m, t1, 1, 100)
	m:on_notes({ land(12885001598, "Manual") }, t1 + 1)
	m:on_notes({ land(12885001598, "Manual") }, t1 + 2)
	local _, ever2 = run(m, t1 + 1, 2, 100)
	expect(not ever and not ever2 and m.count == 1, "repeated landing notes change nothing")
	-- and the same name again for the same entry is a repeat, not a second manual
	m:on_notes({ name(12885001598, "Manual") }, t1 + 3)
	expect(m:update(t1 + 3.02, 100, true, false, false, nil) == false and m.count == 1, "a repeated name of an old entry starts nothing")
end

-- c. The song ticker sends its text every 0.17 s under one entry during a manual: the manual stays on.
do
	local m = Manual.new()
	local t = 0
	for i = 1, 6 do -- the ticker was already running before the manual
		m:on_notes({ name(4295033426, "Behemoth") }, t)
		_, _, t = run(m, t, 0.17, 100)
	end
	m:on_notes({ name(12885001598, "Manual") }, t)
	local on = false
	local ever_off = false
	for i = 1, 12 do
		m:on_notes({ name(4295033426, i % 2 == 0 and "Behemoth" or "No More Fighting") }, t)
		on, _, t = run(m, t, 0.17, 100)
		if not on then ever_off = true end
	end
	expect(on and not ever_off and m.count == 1, "the music ticker never ends a manual (even when the song changes)")
	m:on_notes({ name(4295033426, "Another Band") }, t)
	expect(m:update(t + 1 / 60, 100, true, false, false, nil), "a new text under the ticker's id is still the ticker")
end
do
	-- an entry re-sent 3 times is ignored from then on, whatever it says
	local m = Manual.new()
	m:on_notes({ name(77, "Song") }, 0)
	m:on_notes({ name(77, "Song"), name(77, "Song"), name(77, "Song") }, 0.5)
	m:on_notes({ name(78, "Manual") }, 1)
	m:update(1.02, 100, true, false, false, nil)
	m:on_notes({ name(77, "Other song") }, 1.2)
	expect(m:update(1.22, 100, true, false, false, nil), "after three repeats the entry is ignored whatever it says")
end

-- d. The ids from the log, in its order, are not ordered numbers: each "Manual" is accepted.
do
	local m = Manual.new()
	local t = 0
	local ids = { 99732, 4295066924, 4295066988, 4295067006, 4295067011, 12885001598 }
	for i, id in ipairs(ids) do
		m:on_notes({ name(id, "Manual") }, t)
		local on
		on, _, t = run(m, t, 0.5, 100)
		expect(on, "entry " .. id .. " (number " .. i .. "): on")
		m:on_notes({ land(id, "Manual") }, t)
		on, _, t = run(m, t, 0.2, 100)
		expect(not on, "entry " .. id .. ": off at its landing note")
	end
	expect(m.count == #ids, "all six counted (" .. m.count .. ")")
	-- after a very high id, a lower one is still a trick
	local o = Manual.new()
	o:on_notes({ name(4295033426, "Behemoth") }, 0)
	o:on_notes({ name(60129641854, "Kickflip") }, 1)
	o:on_notes({ name(8590034324, "Manual") }, 2)
	expect(o:update(2.02, 100, true, false, false, nil), "a lower id after a higher one is accepted")
end

-- e. Nose Manual and One Foot Manual
do
	for _, text in { "Nose Manual", "One Foot Manual", "MANUAL" } do
		local m = Manual.new()
		run(m, 0, 0.5, 100)
		m:on_notes({ name(5, text) }, 0.5)
		expect(m:update(0.52, 100, true, false, false, nil), text .. ": on")
	end
end

-- f. A flip trick named in the air, then Manual named while still airborne; the landing: on within 0.5 s of rolling.
do
	local m = Manual.new()
	local _, _, t = run(m, 0, 1, 100)
	local _, _, t1 = run(m, t, 0.3, 201)
	m:on_notes({ name(60129641854, "Kickflip") }, t1)
	local _, _, t2 = run(m, t1, 0.2, 201)
	m:on_notes({ name(8590034324, "Manual") }, t2)
	local _, ever_air, t3 = run(m, t2, 0.2, 201)
	expect(not ever_air and m.count == 0, "named in the air: not yet")
	local on = run(m, t3, 0.1, 100)
	expect(on and m.count == 1, "rolling again within 0.5 s: on")
	-- too late: the skater lands after the 0.5 s wait
	local late = Manual.new()
	late:on_notes({ name(9, "Manual") }, 0)
	local _, _, tl = run(late, 0, 0.7, 201)
	local _, ever = run(late, tl, 0.5, 100)
	expect(not ever, "landing after the 0.5 s wait: no manual")
	-- a new trick named while waiting cancels it
	local c = Manual.new()
	run(c, 0, 0.3, 201)
	c:on_notes({ name(9, "Manual") }, 0.3)
	c:on_notes({ name(10, "Heelflip") }, 0.4)
	local _, ever_c = run(c, 0.4, 0.1, 100)
	expect(not ever_c, "a non-manual trick named while waiting cancels the manual")
end

-- g. A landing note for a different entry during a manual: stays on. A new non-manual trick ends it.
do
	local k = Manual.new()
	k:on_notes({ name(60129641854, "Kickflip") }, 0)
	k:on_notes({ name(12885001598, "Manual") }, 0.5)
	k:update(0.52, 100, true, false, false, nil)
	k:on_notes({ land(60129641854, "Kickflip") }, 0.6)
	expect(k:update(0.62, 100, true, false, false, nil), "a landing note for another entry does not end it")
	k:on_notes({ land(12885001598, "Manual") }, 0.7)
	expect(k:update(0.72, 100, true, false, false, nil) == false, "its own landing note does")
	local n = Manual.new()
	n:on_notes({ name(3, "Manual") }, 0)
	n:update(0.02, 100, true, false, false, nil)
	n:on_notes({ name(4, "Revert") }, 0.5)
	expect(n:update(0.52, 100, true, false, false, nil) == false, "a new non-manual trick (a Revert) ends it")
	local r = Manual.new()
	r:on_notes({ name(3, "Manual") }, 0)
	r:update(0.02, 100, true, false, false, nil)
	r:on_notes({ name(3, "Manual"), name(3, "Manual") }, 0.5)
	expect(r:update(0.52, 100, true, false, false, nil), "the same name again for the same entry is a repeat: still on")
end

-- h. State 101 for a second with no notes: no manual.
do
	local m = Manual.new()
	local _, ever = run(m, 0, 1, 101)
	expect(not ever and m.count == 0, "state 101 alone is nothing")
end

-- i. Transition text and location names: not manuals.
do
	local m = Manual.new()
	run(m, 0, 0.5, 100)
	m:on_notes({ name(4295033677, "ID_TRANSITION_TEXT"), name(4295033700, "SeaSide Skatepark - Plot 01 - FIN") }, 0.5)
	local _, ever = run(m, 0.5, 0.5, 100)
	expect(not ever, "transition text and a location name start nothing")
	-- ID_ text does not end a manual
	local o = Manual.new()
	o:on_notes({ name(1, "Manual") }, 0)
	o:update(0.02, 100, true, false, false, nil)
	o:on_notes({ name(2, "ID_TRANSITION_TEXT") }, 0.3)
	expect(o:update(0.32, 100, true, false, false, nil), "ID_ text does not end a manual")
end

-- j. 15 s cap.
do
	local m = Manual.new()
	run(m, 0, 0.1, 100)
	m:on_notes({ name(1, "Manual") }, 0.1)
	local on_14, _, t = run(m, 0.1, 14.5, 100)
	expect(on_14, "still on after 14.5 s")
	local on_15 = run(m, t, 1, 100)
	expect(not on_15 and string.find(m.last_event, "15", 1, true) ~= nil, "off after 15 s: " .. m.last_event)
end

-- k. Leaving the ground, grinding or leaving the board ends it.
do
	local function started()
		local m = Manual.new()
		m:update(0.01, 100, true, false, false, nil)
		m:on_notes({ name(1, "Manual") }, 0.02)
		expect(m.on, "started")
		return m
	end
	expect(started():update(0.1, 201, true, true, false, nil) == false, "airborne: off")
	expect(started():update(0.1, 300, true, false, true, nil) == false, "grinding: off")
	expect(started():update(0.1, 504, false, false, false, nil) == false, "off the board: off")
	local g = Manual.new()
	g:update(0.01, 300, true, false, true, nil)
	g:on_notes({ name(1, "Manual") }, 0.02)
	g:update(0.03, 300, true, false, true, nil)
	expect(not g.on, "named while grinding: never on")
end

-- l. The notes go to the log: each new name and first landing note, with the state and time; repeats are left out.
do
	local m = Manual.new()
	run(m, 0, 0.5, 100)
	m:on_notes({ name(3, "Manual"), land(3, "x"), land(3, "x"), name(4, "Kickflip"), name(4, "Kickflip") }, 0.55)
	local lines = {}
	m:drain_log(function(text) lines[#lines + 1] = text end)
	expect(#lines == 3, "three log lines, no repeats (" .. #lines .. ")")
	expect(string.find(lines[1], "Manual", 1, true) and string.find(lines[1], "state 100", 1, true), "the name and the state: " .. tostring(lines[1]))
	expect(string.find(lines[2], "landing", 1, true) and string.find(lines[2], "Manual", 1, true), "the landing note says which trick: " .. tostring(lines[2]))
	expect(string.find(lines[3], "Kickflip", 1, true) ~= nil and string.find(lines[3], "t=0.55", 1, true) ~= nil, "and the time: " .. tostring(lines[3]))
	local again = 0
	m:drain_log(function() again += 1 end)
	expect(again == 0, "drained once")
	for i = 1, 100 do m:on_notes({ name(1000 + i, "T" .. i) }, i) end
	local n = 0
	m:drain_log(function() n += 1 end)
	expect(n == Manual.max_log, "the log queue is bounded (" .. n .. ")")
	m:on_notes("not a table", 0)
	m:on_notes(nil, 0)
	expect(true, "bad notes are ignored")
end

-- m. Names
do
	expect(Manual.is_manual_name("Manual") and Manual.is_manual_name("one foot MANUAL") and not Manual.is_manual_name("Kickflip")
		and not Manual.is_manual_name(nil), "is_manual_name")
end

-- n. reset
do
	local m = Manual.new()
	m:update(0.01, 100, true, false, false, nil)
	m:on_notes({ name(1, "Manual") }, 0.02)
	m:reset()
	expect(m.source == "trick list" and not m.on, "reset forgets the manual and keeps the source")
	m:update(0.5, 100, true, false, false, nil)
	m:on_notes({ name(1, "Manual") }, 1)
	expect(m.on, "and the old entry is new again")
end

-- o. The app: notes reach the detector and start a manual; a refused feed warns once and nothing starts.
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
	app.manual:update(4.99, 100, true, false, false, nil)
	m.trick_notes({ name(4, "Manual") })
	expect(app.manual.on, "a Manual note from the trick_notes event starts a manual")
	local bad, bad_app = setup("permission")
	local warns = 0
	for _, l in ipairs(bad.logs) do
		if l[1] == "warn" and string.find(l[2], "trick list", 1, true) then warns += 1 end
	end
	expect(warns == 1 and bad_app.manual ~= nil, "a refused feed logs one warning and the app still starts")
	local _, ever = run(bad_app.manual, 0, 0.5, 101)
	expect(not ever, "and state 101 starts nothing")
end

T.done()
if T.failures > 0 then error("test_manual failed") end
