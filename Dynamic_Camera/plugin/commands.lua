-- Console commands (Extension/Skater/console_commands.cpp): dyncam, dyncam_preset, dyncam_angle, dyncam_shake, dyncam_fov,
-- dyncam_shotfov, dyncam_log, dyncam_side, dyncam_shoulder, dyncam_dump, each also as the earlier s3cam / s3cam_* name, plus
-- dyncam_presets (list, load, save, delete) for the presets. A command with no argument prints its current value.
-- A name the game's own console already has (the DLL build has dyncam and s3cam) is refused by the console: that one is skipped
-- and the others still register (the refusals are collected in Commands.skipped).

local Settings = require("settings")
local Presets = require("presets")

local Commands = {}
Commands.skipped = {}

local function say(text)
	reskate.console.print(text)
end
local function err(text)
	reskate.console.print("error: " .. text)
end

local function parse_bool(word)
	if word == nil then
		return nil
	end
	word = string.lower(word)
	if word == "1" or word == "on" or word == "true" then
		return true
	elseif word == "0" or word == "off" or word == "false" then
		return false
	end
	return nil
end

local function bool_text(v)
	return v and "1" or "0"
end

function Commands.install(deps)
	local store, glue = deps.store, deps.glue

	local function register(name, help, fn, subs)
		local names = { name }
		if name == "dyncam" then
			names[2] = "s3cam"
		elseif string.sub(name, 1, 7) == "dyncam_" then
			names[2] = "s3cam_" .. string.sub(name, 8)
		end
		for _, n in names do
			local ok, why = pcall(reskate.console.command, n, help, fn, subs)
			if not ok then
				Commands.skipped[#Commands.skipped + 1] = n .. ": " .. tostring(why)
			end
		end
	end

	local function update(change)
		local s = Settings.copy(store.settings)
		change(s)
		if store:set_settings(s) then
			return true
		end
		err("out of range; nothing changed.")
		return false
	end

	register("dyncam", "Use Dynamic Camera while riding (the game's camera is used off the board and in menus): dyncam 0|1|toggle", function(args)
		local word = args[1] and string.lower(args[1])
		if word == nil then
			say("dyncam = " .. bool_text(store.enabled) .. " (" .. glue:status() .. ")")
			return
		end
		local value = word == "toggle" and not store.enabled or parse_bool(word)
		if value == nil then
			err("dyncam 0|1|toggle")
			return
		end
		store:set_enabled(value)
		say("dyncam = " .. bool_text(value))
	end, { { name = "0", help = "Off" }, { name = "1", help = "On" }, { name = "toggle", help = "Switch on or off" } })

	register("dyncam_preset", "Dynamic Camera style: full (controls the whole view). Native+ is not in the plugin: dyncam_preset full|native",
		function(args)
			local word = args[1] and string.lower(args[1])
			if word == nil then
				say("dyncam_preset = full")
			elseif word == "full" then
				say("dyncam_preset = full")
			elseif word == "native" then
				err("the Native+ style is not in the plugin; the Full style is used.")
			else
				err("dyncam_preset full|native")
			end
		end, { { name = "full" }, { name = "native", help = "Not in the plugin" } })

	register("dyncam_angle", "Dynamic Camera view: low or high", function(args)
		local word = args[1] and string.lower(args[1])
		if word == nil then
			say("dyncam_angle = " .. (store.settings.angle == Settings.CameraAngle.High and "high" or "low"))
		elseif word == "low" or word == "high" then
			update(function(s)
				s.angle = word == "high" and Settings.CameraAngle.High or Settings.CameraAngle.Low
			end)
		else
			err("dyncam_angle low|high")
		end
	end, { { name = "low" }, { name = "high" } })

	register("dyncam_shake", "Dynamic Camera shake: speed, downhill and landing shake: dyncam_shake 0|1", function(args)
		if args[1] == nil then
			say("dyncam_shake = " .. bool_text(store.settings.shake_enabled))
			return
		end
		local v = parse_bool(args[1])
		if v == nil then
			err("dyncam_shake 0|1")
			return
		end
		update(function(s)
			s.shake_enabled = v
		end)
	end)

	register("dyncam_fov", "Dynamic Camera base FOV in degrees (30-120; 0 = the game's FOV)", function(args)
		if args[1] == nil then
			say("dyncam_fov = " .. tostring(store.settings.fov_override_deg))
			return
		end
		local degrees = tonumber(args[1])
		if degrees == nil or degrees ~= degrees or degrees < 0 or degrees > 120 then
			err("dyncam_fov degrees (0, or 30-120)")
			return
		end
		if degrees ~= 0 and degrees < 30 then
			err("Use 0 or 30-120.")
			return
		end
		update(function(s)
			s.fov_override_deg = degrees
		end)
	end)

	register("dyncam_shotfov", "Dynamic Camera FOV override: 1 lets it set the FOV (speed-based and big-air FOV increase), 0 keeps the game's", function(args)
		if args[1] == nil then
			say("dyncam_shotfov = " .. bool_text(store.options.shot_fov))
			return
		end
		local v = parse_bool(args[1])
		if v == nil then
			err("dyncam_shotfov 0|1")
			return
		end
		local o = Settings.copy(store.options)
		o.shot_fov = v
		store:set_options(o)
	end)

	register("dyncam_log", "Dynamic Camera logging: writes camera state and faults to files in the data folder (diag/): dyncam_log 0|1", function(args)
		if args[1] == nil then
			say("dyncam_log = " .. bool_text(store.options.verbose))
			return
		end
		local v = parse_bool(args[1])
		if v == nil then
			err("dyncam_log 0|1")
			return
		end
		local o = Settings.copy(store.options)
		o.verbose = v
		store:set_options(o)
		if v then
			say("Logging to the plugin's data folder (diag/camera_log.txt and diag/snap_N.txt).")
		end
	end)

	register("dyncam_side", "Dynamic Camera shoulder side: switch (bind 'Switch shoulder side' on the Binds page), left or right: dyncam_side swap|left|right",
		function(args)
			local word = args[1] and string.lower(args[1])
			local sh = store.settings.shoulder
			if word == nil then
				local mode = sh.mode == Settings.ShoulderSide.Off and "off" or (sh.mode == Settings.ShoulderSide.Auto and "auto" or "manual")
				say("dyncam_side = " .. mode .. (sh.side > 0 and ", right" or ", left"))
			elseif word == "swap" or word == "left" or word == "right" then
				store:swap_side(word == "left" and -1 or (word == "right" and 1 or 0))
			else
				err("dyncam_side swap|left|right")
			end
		end, { { name = "swap" }, { name = "left" }, { name = "right" } })

	register("dyncam_shoulder", "Dynamic Camera shoulder camera: off (centred), manual (dyncam_side) or auto (toe side of your stance)", function(args)
		local word = args[1] and string.lower(args[1])
		local names = { off = Settings.ShoulderSide.Off, manual = Settings.ShoulderSide.Manual, auto = Settings.ShoulderSide.Auto }
		if word == nil then
			local mode = store.settings.shoulder.mode
			say("dyncam_shoulder = " .. (mode == Settings.ShoulderSide.Off and "off" or (mode == Settings.ShoulderSide.Auto and "auto" or "manual")))
		elseif names[word] ~= nil then
			update(function(s)
				s.shoulder.mode = names[word]
			end)
		else
			err("dyncam_shoulder off|manual|auto")
		end
	end, { { name = "off" }, { name = "manual" }, { name = "auto" } })

	register("dyncam_dump", "Show Dynamic Camera's settings and what the camera is doing now", function()
		for line in string.gmatch(glue:dump() .. "\n", "([^\n]*)\n") do
			if line ~= "" then
				say(line)
			end
		end
	end)

	-- Presets from the console (the menu's window does the same with buttons).
	local function preset_name(args)
		return table.concat(args, " ", 2)
	end
	register("dyncam_presets", "Dynamic Camera presets: dyncam_presets list | load <name> | save <name> | delete <name>", function(args)
		local word = args[1] and string.lower(args[1])
		if word == nil or word == "list" then
			local names = {}
			for _, e in Presets.refresh() do
				names[#names + 1] = e.name .. (e.built_in and " (built in)" or "")
			end
			say("presets: " .. table.concat(names, ", "))
		elseif word == "load" or word == "save" or word == "delete" then
			local name = preset_name(args)
			if name == "" then
				err("dyncam_presets " .. word .. " <name>")
				return
			end
			local r
			if word == "load" then
				r = Presets.load(store, name)
			elseif word == "save" then
				r = Presets.save(store, name, true)
			else
				r = Presets.delete(name)
			end
			if r.ok then
				say(r.message)
			else
				err(r.message)
			end
		else
			err("dyncam_presets list | load <name> | save <name> | delete <name>")
		end
	end, { { name = "list" }, { name = "load", args = "<name>" }, { name = "save", args = "<name>" }, { name = "delete", args = "<name>" } })
end

return Commands
