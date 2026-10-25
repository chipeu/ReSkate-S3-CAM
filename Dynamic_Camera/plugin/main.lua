-- Dynamic Camera for ReSkate: the Skate 3 riding camera as a plugin. Entry file; the work is in app.lua.
--
-- ReSkate gives the entry file and every later call 50 ms of WALL-CLOCK time, and `require` reads the .lua file from disk and compiles
-- it inside our handler. Compiling all the modules in one go took 28 ms with the files cached and over 200 ms from a cold disk.
-- And while the game loads a level the disk and the CPU are busy, so even one module (a few ms normally) can take over 50 ms and
-- the game stops the plugin ("the tick handler ran longer than 50 ms"). So loading is slow on purpose:
--  * It does not begin until the game has settled: 30 ticks in a row under 40 ms, and a skater in the world (or 20 s gone, for the
--    main menu, which has no skater but needs the plugin's page). If the game never settles it begins after a minute anyway.
--  * One module, or one step of App.steps(), a tick.
--  * After one that took over 15 ms, 10 ticks of rest before the next.
-- An optional module that is missing is reported and skipped; a missing required one stops the start.
local modules = { "s3math", "tracker", "rig", "shots", "graph", "trajectory", "air", "shake", "subject", "rider", "offboard",
	"settings", "camera", "store", "presets", "snapguard", "glue", "diag", "manual", "menu", "commands", "app" }
local optional = { offboard = true }

local STEADY_TICKS = 30 -- ticks in a row under STEADY_MS before loading begins
local STEADY_MS = 40
local NO_SKATER_WAIT = 20000 -- ms after load: begin without a skater (main menu)
local GIVE_UP_WAIT = 60000 -- ms after load: begin whatever the frame rate is
local SLOW_MS = 15 -- a require or step longer than this is followed by a rest
local REST_TICKS = 10

local now_ms = reskate.time.now
local loaded_at = now_ms()
local steady = 0
local begun = false
local finished = false
local rest = 0
local queue = {} -- { name, fn }: what is left to do, one a tick
local next_item = 1
local worst_name, worst_ms = "", 0

for _, name in modules do
	if name == "app" then
		-- App comes last; it hands over its steps, which are queued behind it.
		queue[#queue + 1] = { name, function()
			local _, steps = require("app").steps()
			for i, step in steps do
				queue[#queue + 1] = { "app step " .. i, step }
			end
		end }
	else
		queue[#queue + 1] = { name, function() require(name) end }
	end
end

local function settled()
	if steady < STEADY_TICKS then
		return false
	end
	if now_ms() - loaded_at >= NO_SKATER_WAIT then
		return true
	end
	local ok, skater = pcall(reskate.skater.get)
	return ok and skater ~= nil
end

reskate.on("tick", function(dt)
	if finished then
		return
	end
	if type(dt) == "number" and dt >= STEADY_MS then
		steady = 0
	else
		steady += 1
	end
	if not begun then
		if not (settled() or now_ms() - loaded_at >= GIVE_UP_WAIT) then
			return
		end
		begun = true
	end
	if rest > 0 then
		rest -= 1
		return
	end
	local item = queue[next_item]
	if item == nil then
		finished = true
		return
	end
	next_item += 1
	local started = now_ms()
	local ok, err = pcall(item[2])
	local took = now_ms() - started
	if took > worst_ms then
		worst_name, worst_ms = item[1], took
	end
	if took > SLOW_MS then
		rest = REST_TICKS
	end
	if not ok then
		if optional[item[1]] then
			reskate.log("dyncam: optional module " .. item[1] .. " did not load: " .. tostring(err), "warn")
		else
			finished = true
			reskate.log("dyncam: stopped starting at " .. item[1] .. ": " .. tostring(err), "error")
		end
		return
	end
	if next_item > #queue then
		finished = true
		reskate.log(string.format("dyncam: started %.1f s after load, slowest step %s %.1f ms", (now_ms() - loaded_at) / 1000, worst_name, worst_ms))
	end
end)
