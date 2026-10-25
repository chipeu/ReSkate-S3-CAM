-- Manual detection from the game's physics state. While the skater holds a manual the game reports state 101 (a ReSkate source
-- calls it "brief after air", a guess from another project): measured in game it lasts 0.5 to 1.0 s with the board nose
-- up 10 to 16 degrees, was entered from 100 (rolling) and from 201 (landing straight into a manual), and ended back at 100.
--
-- A manual is on once the state has been 101 for ON_AFTER (a few ticks, so one stray tick of 101 does not make a close-up) and
-- off once it has been anything else for OFF_AFTER (so a one-tick flicker to another state does not end it). The trick list does
-- not start or end it any more: the HUD names a trick late (after the manual is over, or with the next trick), which made the
-- close-up come late, never, or only after a manual and its revert. Its notes are kept for the log only: every trick name with the
-- state and time it arrived at, so a log shows whether 101 really is the manual.
--
--   local m = Manual.new()
--   m:on_notes(notes, now)                                          -- the trick_notes event's e.notes, now in seconds (log only)
--   local on = m:update(now, state, onboard, airborne, grinding, feet_pitch)   -- once a tick; feet_pitch is not used any more
--   m:drain_log(fn)                                                 -- hands each pending log text to fn(text)
--   m.source ("physics state"), m.count (manuals since load), m.last_event (short text, for the log)

local M = {}

M.state = 101 -- the physics state of a manual
M.on_after = 0.06 -- s in the state before the manual is on
M.off_after = 0.15 -- s out of the state before the manual is off
M.max_log = 24 -- trick log entries kept between two drains

-- A trick name that contains one of these (any case) is a manual (only used to label the log).
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
	self.source = "physics state"
	self.last_event = ""
	self.on = false
	self.in_since = nil -- when the state became 101 (and has stayed)
	self.out_since = nil -- when it stopped being 101 while the manual was on
	self.state = 0 -- the last state seen, for the log
	self.now = 0.0
	self.names = {} -- entry key -> its name, so a landing note can say what it belongs to
	self.log = {}
end

function Manual:queue(text)
	local log = self.log
	if #log >= M.max_log then
		table.remove(log, 1)
	end
	log[#log + 1] = text
end

-- The trick list: log only. Nothing here changes whether a manual is on.
function Manual:on_notes(notes, now)
	if type(notes) ~= "table" then
		return
	end
	for _, note in notes do
		local key = tostring(note.entry)
		if note.kind == "n" then
			self.names[key] = note.text
			self:queue(string.format("s3cam trick \"%s\" (entry %s) named at state %d, t=%.2f, manual %s", tostring(note.text), key, self.state,
				now or self.now, self.on and "on" or "off"))
		elseif note.kind == "l" then
			self:queue(string.format("s3cam trick landing note (entry %s: %s) at state %d, t=%.2f, manual %s", key, tostring(self.names[key] or "?"),
				self.state, now or self.now, self.on and "on" or "off"))
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
	local in_state = state == M.state and onboard and not grinding and not airborne
	if in_state then
		self.out_since = nil
		self.in_since = self.in_since or now
		if not self.on and now - self.in_since >= M.on_after then
			self.on = true
			self.count += 1
			self.last_event = string.format("manual on (state %d for %.2f s)", state, now - self.in_since)
		end
		return self.on
	end
	self.in_since = nil
	if self.on then
		if not onboard then
			self.on = false
			self.out_since = nil
			self.last_event = "manual off (off the board)"
			return false
		end
		self.out_since = self.out_since or now
		if now - self.out_since >= M.off_after then
			self.on = false
			self.last_event = string.format("manual off (state %d for %.2f s)", state, now - self.out_since)
			self.out_since = nil
			return false
		end
		return true
	end
	return false
end

return M
