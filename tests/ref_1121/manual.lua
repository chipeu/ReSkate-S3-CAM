-- Manual detection from the game's trick list. The HUD names a manual the moment it starts (a "Manual" or "Nose Manual" note on a
-- new entry) and sends a landing note for that entry when it ends, so those two notes are the manual's start and end. The physics
-- state says nothing about manuals: state 101 is what the game shows for a Powerslide or a Revert, and during a real manual the
-- state stays 100. The board's pitch is used for one thing only, to end a manual whose landing note comes late: the game writes
-- that note when the whole trick line ends, so a manual could otherwise stay on (with its close-up) until the next ollie, long
-- after the board lay level. It is too noisy to start or hold a manual with.
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
--     Powerslide included), when the skater leaves the ground, grinds or leaves the board, when the board has lain level (pitch
--     within level_pitch degrees) for level_time seconds in a row once the manual has been on for level_min_on seconds, or after 15 s
--     (a safety net). A pitch that cannot be read never ends a manual and breaks a level stretch; a pop's setup (the board rocking
--     far past level) and a manual that stays nose-up into an ollie are not level.
--
--   local m = Manual.new()
--   m:on_notes(notes, now)                                          -- the trick_notes event's e.notes, now in seconds
--   local on = m:update(now, state, onboard, airborne, grinding, feet_pitch)   -- once a tick; feet_pitch is the board's pitch in
--                                                                              -- degrees, or nil when it cannot be read
--   m:drain_log(fn)                                                 -- hands each pending log text to fn(text)
--   m.source ("trick list"), m.count (manuals since load), m.last_event (short text, for the log)

local M = {}

M.wait_for_ground = 0.5 -- s a manual named in the air waits for the skater to roll
M.max_time = 15.0 -- s, a manual never lasts longer than this
M.level_pitch = 4.0 -- degrees, the board is level when its pitch is within this
M.level_time = 0.4 -- s, the board must stay level this long, without a break, to end the manual
M.level_min_on = 0.5 -- s, the manual must have been on this long before a level board can end it
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
	self.level_since = nil -- when the board became level (and stayed level), nil while it is not
	self.pending = nil -- { key, until }: a manual named while the skater was not rolling
	self.rolling = false -- from the last update: on the board, on the ground, not grinding
	self.state = 0 -- the last state seen, for the log
	self.now = 0.0
	self.pose_since,self.pose_pitch=nil,nil
	self.pose_block_until=0
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
	self.level_since = nil
	self.pending = nil
	self.last_event = "manual off (" .. why .. ")"
end

function Manual:turn_on(key, now, text)
	if not self.on then
		self.count += 1 -- a manual linked into another (manual, revert, manual) is one close-up
		self.on_since = now
		self.level_since = nil
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
		-- A named non-manual also suppresses pose fallback through reverts/powerslides.
		self.pose_block_until=now+0.65
		self.pose_since=nil
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

function Manual:update(now, state, onboard, airborne, grinding, feet_pitch, speed)
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
		elseif feet_pitch == nil or not (math.abs(feet_pitch) < M.level_pitch) then
			self.level_since = nil -- not level, or not readable: the level stretch starts again
		else
			if self.level_since == nil then
				self.level_since = now
			end
			if now - self.on_since >= M.level_min_on and now - self.level_since >= M.level_time then
				self:turn_off("board level")
			end
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
	-- 2.1.4's gated name feed can be silent until a line ends. A sustained
	-- wheelie/nose-wheelie pose is an independent, ground-relative signal.
	local tilt=type(feet_pitch)=="number" and math.abs(feet_pitch) or 0
	local candidate=rolling and (state==100 or state==101) and speed~=nil and speed>0.5
		and tilt>=6 and tilt<=30 and now>=self.pose_block_until
	if candidate then
		if not self.pose_since or (self.pose_pitch and math.abs(feet_pitch-self.pose_pitch)>4) then self.pose_since=now end
		self.pose_pitch=feet_pitch
		if now-self.pose_since>=0.20 then self:turn_on("pose",now,"board tilt");self.pose_since=nil end
	else self.pose_since,self.pose_pitch=nil,nil end
	return self.on
end

return M
