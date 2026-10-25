-- The live settings of the camera (CameraSettings + the glue's options + the on/off switch) and their persistence.
-- This is what the DLL keeps in s3cam.cpp's Settings (s3cam_settings / s3cam_options) and s3cam_config.cpp (the profile).
-- Current settings persist in reskate.storage: key "settings" holds the values table (the same S3Cam.* keys as a preset's
-- "values"), key "enabled" the on/off switch, key "ui" small page choices.
--
--   local st = Store.new(); st:load()
--   st:set_settings(camera_settings) -> bool   (refuses invalid ones; bumps st.revision; saves)
--   st:set_options(options)
--   st:swap_side(side)                         0 swaps, +1 right, -1 left (switches the shoulder mode to Manual)
--   st:toggle_height()                         Low <-> High (only while options.follow_game_height)
--   st:set_enabled(bool)
--   st:reset()                                 defaults
-- st.revision grows with every settings / options change: the glue applies the new settings when it sees it.

local Settings = require("settings")
local Presets = require("presets")

local Store = {}
Store.__index = Store

function Store.new()
	return setmetatable({
		settings = Settings.defaults(),
		options = Presets.new_options(),
		enabled = true, -- the plugin exists to be the camera: installed means on (dyncam 0 or the bind switches it off)
		show_help = true, -- the menu's description lines
		revision = 0,
		load_report = nil,
	}, Store)
end

local function safe(fn, ...)
	local ok, a = pcall(fn, ...)
	if ok then
		return a
	end
	return nil
end

function Store:load()
	local values = safe(reskate.storage.get, "settings")
	if type(values) == "table" then
		local camera, options, report = Presets.from_values(values)
		self.settings, self.options, self.load_report = camera, options, report
		if report.refused > 0 then
			reskate.log(string.format("dyncam: %d saved value(s) were out of range or of the wrong type and keep their defaults (first: %s).",
				report.refused, report.first_refused), "warn")
		end
	end
	local enabled = safe(reskate.storage.get, "enabled")
	if type(enabled) == "boolean" then
		self.enabled = enabled
	end
	local ui = safe(reskate.storage.get, "ui")
	if type(ui) == "table" and type(ui.show_help) == "boolean" then
		self.show_help = ui.show_help
	end
	self.revision += 1
end

function Store:save()
	pcall(reskate.storage.set, "settings", Presets.collect_values(self.settings, self.options))
end

function Store:save_flags()
	pcall(reskate.storage.set, "enabled", self.enabled)
	pcall(reskate.storage.set, "ui", { show_help = self.show_help })
end

function Store:set_settings(s)
	if not Settings.valid(s) then
		return false
	end
	s.preset = Settings.CameraPreset.FullS3
	self.settings = s
	self.revision += 1
	self:save()
	return true
end

function Store:set_options(o)
	self.options = o
	self.revision += 1
	self:save()
end

function Store:set_enabled(on)
	self.enabled = on and true or false
	self:save_flags()
end

function Store:set_show_help(on)
	self.show_help = on and true or false
	self:save_flags()
end

function Store:swap_side(side)
	local s = Settings.copy(self.settings)
	local shoulder = s.shoulder
	-- Swapping from Off or Auto takes manual control: the swap is the player's choice.
	local current = shoulder.mode == Settings.ShoulderSide.Off and -1 or shoulder.side
	shoulder.side = side == 0 and -current or (side > 0 and 1 or -1)
	shoulder.mode = Settings.ShoulderSide.Manual
	return self:set_settings(s)
end

function Store:toggle_height()
	if not self.options.follow_game_height then
		return false
	end
	local s = Settings.copy(self.settings)
	s.angle = s.angle == Settings.CameraAngle.High and Settings.CameraAngle.Low or Settings.CameraAngle.High
	return self:set_settings(s)
end

function Store:reset()
	self.settings = Settings.defaults()
	self.options = Presets.new_options()
	self.revision += 1
	self:save()
end

return Store
