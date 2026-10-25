-- Loading from the main menu: no skater in the world. main.lua waits 20 s for one, then loads anyway (the menu page has to appear).
-- With arg "slow" the game never gets steady (every tick 80 ms): it begins after a minute whatever the frame rate.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\time_load_menu.lua [slow]
local T = require("tlib")
T.group("load menu")
local expect = T.expect
local mock = require("mock_reskate")
local m = mock.install()
local r = m.reskate
r.input.gamepad = function() return nil end
r.menu.game = function() return { open = false } end
r.ui.dialog = function() return true end
r.files.reveal = function() return true end
m.state.skater = nil

local slow = arg and arg[1] == "slow"
local dt = slow and 80 or 1000 / 60
local started_at = m.clock_ms
local real_require = require
local count = 0
local depth = 0
require = function(name)
	if depth == 0 then count += 1 end
	depth += 1
	local ok, result = pcall(real_require, name)
	depth -= 1
	if not ok then error(result, 0) end
	return result
end
real_require("main")

local limit_s = slow and 60 or 20
local begun_at
for _ = 1, 20000 do
	m.tick(dt)
	if count > 0 and not begun_at then begun_at = (m.clock_ms - started_at) / 1000 end
	if m.page_title ~= nil then break end
end
expect(begun_at ~= nil, "loading began")
expect(begun_at >= limit_s - 0.5, string.format("not before %d s without a skater (began at %.1f s)", limit_s, begun_at or -1))
expect(begun_at <= limit_s + 1.5, string.format("and soon after it (began at %.1f s)", begun_at or -1))
expect(m.page_title ~= nil, "the menu page appears")
for _, l in ipairs(m.logs) do
	expect(l[1] ~= "error", "no error logged: " .. l[2])
end
T.done()
if T.failures > 0 then error("time_load_menu failed") end
