-- Manual detection from the game's trick list. The HUD names a manual the moment it starts (a "Manual" or "Nose Manual" note on a
-- new entry) and sends a landing note for that entry when it ends, so those two notes are the manual's start and end. The physics
-- state says nothing about manuals: state 101 is what the game shows for a Powerslide or a Revert, and during a real manual the
-- state stays 100. The feet pitch was too noisy to end a manual with and is not used any more.
--
-- Things about the list that this module has to live with (all seen in game logs):
--  * Entry ids are not ordered numbers (they look like slot << 32 | counter), so notes are handled strictly in the order they
--    arrive and an id is never compared with another.
--  * The same note comes again and again: the music ticker re-sends the song or band under one fixed id about every 0.17 s, and the
--    landing note of the last trick of a line repeats every few seconds. A name for an entry that already has that text is a
--    repeat and is dropped; only the first landing note of an entry counts. An entry that has repeated 3 times is a ticker and is
--    ignored from then on, whatever text it carries (the song changes under the same id).
--  * Names that start with "ID_" (transition text) and location names are not tricks. The ID_ ones are dropped; a location name
--    looks like a new trick, and ends a manual like any other new name would (it only arrives between lines of play).
--
-- ON  when a new entry is named with a name that contains "manual" while the skater rolls on the board (not in the air, not
--     grinding). If it arrives in the air (a flip trick landing straight into a manual) it waits up to 0.5 s for the skater to roll.
-- OFF when the first landing note of the manual's entry arrives, when a new entry is named with a non-manual trick (a Revert or a
--     Powerslide included), when the skater leaves the ground, grinds or leaves the board, or after 15 s (a safety net).
--
--   local m = Manual.new()
--   m:on_notes(notes, now)                                          -- the trick_notes event's e.notes, now in seconds
--   local on = m:update(now, state, onboard, airborne, grinding, feet_pitch)   -- once a tick; feet_pitch is not used any more
--   m:drain_log(fn)                                                 -- hands each pending log text to fn(text)
--   m.source ("trick list"), m.count (manuals since load), m.last_event (short text, for the log)

local M = {}

M.wait_for_ground = 0.5 -- s a manual named in the air waits for the skater to roll
M.max_time = 15.0 -- s, a manual never lasts longer than this
M.ticker_repeats = 3 -- an entry re-sent with the same text this many times is a ticker (music), not a trick
M.max_log = 24 -- trick log entries kept between two drains

-- A trick name that contains one of these (any case) is a manual.
M.words = { "manual" }

local Manual = {}
Manual.__index = Manual

function M.new()
	local self = setmetatable({}, Manual)
	self.count = 0
	self:reset()
	return self
end

function M.is_manual_name(name)
	if type(name) ~= "string" then
		return false
	end
	local lower = string.lower(name)
	for _, word in M.words do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

function Manual:reset()
	self.source = "trick list"
	self.last_event = ""
	self.on = false
	self.active = nil -- the entry key of the manual that is on
	self.on_since = 0.0
	self.pending = nil -- { key, until }: a manual named while the skater was not rolling
	self.rolling = false -- from the last update: on the board, on the ground, not grinding
	self.state = 0 -- the last state seen, for the log
	self.now = 0.0
	self.entries = {} -- entry key -> { text, repeats, landed }
	self.log = {}
end

function Manual:queue(text)
	local log = self.log
	if #log >= M.max_log then
		table.remove(log, 1)
	end
	log[#log + 1] = text
end

function Manual:turn_off(why)
	self.on = false
	self.active = nil
	self.pending = nil
	self.last_event = "manual off (" .. why .. ")"
end

function Manual:turn_on(key, now, text)
	if not self.on then
		self.count += 1 -- a manual linked into another (manual, revert, manual) is one close-up
		self.on_since = now
	end
	self.on = true
	self.active = key
	self.pending = nil
	self.last_event = string.format("manual on (\"%s\" named, entry %s)", tostring(text), key)
end

function Manual:on_name(key, text, now)
	if type(text) ~= "string" or text == "" then
		return
	end
	local entry = self.entries[key]
	if entry == nil then
		entry = { text = nil, repeats = 0, landed = false }
		self.entries[key] = entry
	end
	if entry.text == text then
		entry.repeats += 1
	end
	if entry.repeats >= M.ticker_repeats then
		return -- the music ticker (or anything else re-sent over and over)
	end
	if entry.text == text then
		return -- a repeat of a name already handled
	end
	entry.text = text
	entry.landed = false
	self:queue(string.format("s3cam trick \"%s\" (entry %s) named at state %d, t=%.2f, manual %s", text, key, self.state, now,
		self.on and "on" or "off"))
	if string.sub(text, 1, 3) == "ID_" then
		return -- transition text, not a trick
	end
	if M.is_manual_name(text) then
		if self.rolling then
			self:turn_on(key, now, text)
		else
			self.pending = { key = key, text = text, deadline = now + M.wait_for_ground }
		end
	else
		-- A new trick that is not a manual: it ends one that is on and cancels one that is waiting.
		self.pending = nil
		if self.on then
			self:turn_off(string.format("\"%s\" named", text))
		end
	end
end

function Manual:on_landing(key, now)
	local entry = self.entries[key]
	if entry == nil or entry.landed then
		return -- unknown entry, or a repeated landing note
	end
	entry.landed = true
	self:queue(string.format("s3cam trick landing note (entry %s: %s) at state %d, t=%.2f, manual %s", key, tostring(entry.text),
		self.state, now, self.on and "on" or "off"))
	-- In a manual, revert, manual line each manual gets its own entry and only the line's end writes a landing note, for
	-- whichever of them: the first landing note of any manual ends the close-up.
	if self.on and (self.active == key or M.is_manual_name(entry.text)) then
		self:turn_off("its landing note")
	elseif self.pending and self.pending.key == key then
		self.pending = nil
	end
end

-- The trick list: starts and ends manuals.
function Manual:on_notes(notes, now)
	if type(notes) ~= "table" then
		return
	end
	now = now or self.now
	for _, note in notes do
		local key = tostring(note.entry)
		if note.kind == "n" then
			self:on_name(key, note.text, now)
		elseif note.kind == "l" then
			self:on_landing(key, now)
		end
	end
end

function Manual:drain_log(fn)
	local log = self.log
	if #log == 0 then
		return
	end
	self.log = {}
	for _, text in log do
		fn(text)
	end
end

function Manual:update(now, state, onboard, airborne, grinding, feet_pitch)
	self.state, self.now = state, now
	local rolling = onboard and not airborne and not grinding
	self.rolling = rolling
	if self.on then
		if not onboard then
			self:turn_off("off the board")
		elseif grinding then
			self:turn_off("grinding")
		elseif airborne then
			self:turn_off("left the ground")
		elseif now - self.on_since >= M.max_time then
			self:turn_off("15 s limit")
		end
		return self.on
	end
	local p = self.pending
	if p then
		if now > p.deadline then
			self.pending = nil
		elseif rolling then
			self:turn_on(p.key, now, p.text)
		end
	end
	return self.on
end

return M
