-- The plugin's wiring: settings, glue, menu page, binds, console commands and events. main.lua runs App.steps() one step a
-- tick; the tests call App.start() which runs them all, with a stand-in camera (deps.camera).
--
--   App.start{ camera = <module with .new()> }   camera defaults to require("camera")
--   App.steps{ camera = ... } -> app, { step1, step2, ... }   the same work in pieces, none of them two heavy things
-- Returns { store, glue, diag, manual } so a test can look inside.

local Store = require("store")
local Glue = require("glue")
local DiagModule = require("diag")
local Menu = require("menu")
local Commands = require("commands")
local ManualModule = require("manual")

local App = {}

-- Settings > Binds lists these as "<plugin id>: <action>", so the names do not repeat the plugin's. ReSkate 2.1.2 lists an action
-- only when it is bound to a real key (a nil key is refused), so each has a default key; the player can record another or clear it.
App.ACTION_TOGGLE = "camera on / off"
App.ACTION_SIDE = "switch shoulder side"
App.KEY_TOGGLE = "Ctrl+Shift+D"
App.KEY_SIDE = "Ctrl+Shift+S"

-- ReSkate stops a plugin whose handler runs longer than 50 ms (wall clock, so a busy disk or CPU counts), and loading a level keeps
-- both busy. So the start is cut into steps, main.lua runs one a tick and waits after a slow one: nothing here does two heavy things.
function App.steps(deps)
	deps = deps or {}
	local app = { errors = 0 }
	local store, glue, diag, camera

	-- Handlers never raise: an error in one counts towards the plugin's error limit (the plugin would be stopped), and a
	-- camera that cannot run should hand the game its camera back, not freeze the view.
	local last_error_at = -100
	local function guarded(name, fn)
		return function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				app.errors += 1
				local now = reskate.time.now() / 1000
				if now - last_error_at > 5 then
					last_error_at = now
					reskate.log("dyncam: " .. name .. " raised an error: " .. tostring(err), "error")
				end
				if name == "tick" and app.errors >= 20 then
					pcall(function() glue:release("too many errors") end)
					store.enabled = false -- until the player switches it on again
				end
			end
		end
	end

	local steps = {}

	-- 1. The saved settings (reads the plugin's storage).
	steps[#steps + 1] = function()
		camera = deps.camera or require("camera")
		store = Store.new()
		store:load()
		diag = DiagModule.new()
		app.store, app.diag = store, diag
	end

	-- 2. The glue, and the manual detector it reads (the physics state tells it when a manual starts and ends).
	steps[#steps + 1] = function()
		glue = Glue.new{ store = store, camera = camera, diag = diag }
		app.glue = glue
		app.manual = ManualModule.new()
		glue.manual_detector = app.manual
	end

	-- 3. The menu page.
	steps[#steps + 1] = function()
		Menu.install{ store = store, glue = glue }
	end

	-- 4. Keys and console commands.
	steps[#steps + 1] = function()
		local unbound = {}
		for _, bind in { { App.ACTION_TOGGLE, App.KEY_TOGGLE }, { App.ACTION_SIDE, App.KEY_SIDE } } do
			local ok, bound, why = pcall(reskate.input.bind, bind[1], bind[2])
			if not ok or not bound then
				unbound[#unbound + 1] = string.format("'%s' (%s)", bind[1], tostring(ok and why or bound))
			end
		end
		if #unbound > 0 then
			reskate.log("dyncam: could not bind " .. table.concat(unbound, ", ") .. "; the console commands dyncam toggle / dyncam_side still work.", "warn")
		end
		Commands.install{ store = store, glue = glue }
		for _, why in Commands.skipped do
			reskate.log("dyncam: console command skipped: " .. why, "warn")
		end
	end

	-- 5. The events (last, so nothing runs against a half-built plugin), the trick list and the "loaded" line.
	steps[#steps + 1] = function()
		reskate.on("action", guarded("action", function(name)
			if name == App.ACTION_TOGGLE then
				store:set_enabled(not store.enabled)
				reskate.log("dyncam: " .. (store.enabled and "on" or "off"))
			elseif name == App.ACTION_SIDE then
				store:swap_side(0)
			end
		end))
		reskate.on("physics_step", guarded("physics_step", function(e) glue:on_physics_step(e) end))
		reskate.on("level_unloading", guarded("level_unloading", function() glue:release("level change") end))
		reskate.on("level_loaded", guarded("level_loaded", function() glue.cam:cut() end))
		reskate.on("unload", guarded("unload", function() glue:release("unload") end))
		reskate.on("throwdown_ui", guarded("dialog", function(e) Menu.on_dialog(e) end))
		-- The trick list's notes go to the manual detector for the log only (a manual is found from the physics state). Without the feed
		-- (the game refuses, or the permission is missing) the log just has no trick names.
		local fed, why = pcall(reskate.tricks.feed, true)
		if not fed then
			reskate.log("dyncam: the trick list could not be read (" .. tostring(why) .. "); trick names will be missing from the log", "warn")
		else
			reskate.on("trick_notes", guarded("trick_notes", function(e)
				app.manual:on_notes(e.notes, reskate.time.now() / 1000)
			end))
		end
		reskate.on("tick", guarded("tick", function(dt) glue:tick(dt) end))
		reskate.log("dyncam: loaded (" .. (store.enabled and "on" or "off") .. ")")
	end

	return app, steps
end

function App.start(deps)
	local app, steps = App.steps(deps)
	for _, step in steps do
		step()
	end
	return app
end

return App
