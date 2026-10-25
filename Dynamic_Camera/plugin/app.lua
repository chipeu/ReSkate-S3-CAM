-- The plugin's wiring: settings, glue, menu page, binds, console commands and events. main.lua calls App.start();
-- the tests call it with a stand-in camera (deps.camera).
--
--   App.start{ camera = <module with .new()> }   camera defaults to require("camera")
-- Returns { store, glue, diag } so a test can look inside.

local Store = require("store")
local Glue = require("glue")
local DiagModule = require("diag")
local Menu = require("menu")
local Commands = require("commands")

local App = {}

App.ACTION_TOGGLE = "Dynamic Camera on / off"
App.ACTION_SIDE = "Switch shoulder side"

function App.start(deps)
	deps = deps or {}
	local camera = deps.camera or require("camera")
	local store = Store.new()
	store:load()
	local diag = DiagModule.new()
	local glue = Glue.new{ store = store, camera = camera, diag = diag }
	local app = { store = store, glue = glue, diag = diag, errors = 0 }

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

	reskate.on("tick", guarded("tick", function(dt) glue:tick(dt) end))
	reskate.on("physics_step", guarded("physics_step", function(e) glue:on_physics_step(e) end))
	reskate.on("level_unloading", guarded("level_unloading", function() glue:release("level change") end))
	reskate.on("level_loaded", guarded("level_loaded", function() glue.cam:cut() end))
	reskate.on("unload", guarded("unload", function() glue:release("unload") end))
	reskate.on("throwdown_ui", guarded("dialog", function(e) Menu.on_dialog(e) end))

	reskate.input.bind(App.ACTION_TOGGLE, nil)
	reskate.input.bind(App.ACTION_SIDE, nil)
	reskate.on("action", guarded("action", function(name)
		if name == App.ACTION_TOGGLE then
			store:set_enabled(not store.enabled)
			reskate.log("dyncam: " .. (store.enabled and "on" or "off"))
		elseif name == App.ACTION_SIDE then
			store:swap_side(0)
		end
	end))

	Menu.install{ store = store, glue = glue }
	Commands.install{ store = store, glue = glue }
	for _, why in Commands.skipped do
		reskate.log("dyncam: console command skipped: " .. why, "warn")
	end
	reskate.log("dyncam: loaded (" .. (store.enabled and "on" or "off") .. ")")
	return app
end

return App
