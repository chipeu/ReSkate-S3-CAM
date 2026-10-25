-- main.lua loads with the real camera.lua, rides, and the ray use per tick is measured.
local mock = require("mock_reskate")
local m = mock.install({ limit_rays = true })
local r = m.reskate
r.input.gamepad = function() return nil end
r.menu.game = function() return { open = false } end
r.ui.dialog = function() return true end
r.files.reveal = function() return true end
dofile_ok = pcall(require, "main")
assert(dofile_ok, "main.lua loads")
m.fire("load")
local worst, total, n = 0, 0, 0
local z0 = 0
m.run(6, 60, function(i)
    local s = m.state.skater
    s.position = vector.create(0, 0.95, i * 0.1)
    m.fire("physics_step", { seconds = 1 / 60, velocity = { 0, 0, 6 }, ragdoll = false })
    worst = math.max(worst, m.state.raycasts)
    m.state.raycasts = 0
end)
assert(m.camera_held_by == "me", "the real camera is shown")
print("max rays in a tick: " .. worst)
print("main ok; camera calls: " .. #m.calls .. ", log lines: " .. #m.logs)

-- A jump: air state, rising then falling; the ray use per tick stays under the API's 64.
m.state.telemetry.physics_state = 201
local worst_air, capped_before = 0, 0
m.run(1.6, 60, function(i)
    local t = i / 60
    local s = m.state.skater
    s.position = vector.create(0, 0.95 + 4.0 * t - 0.5 * 10.1 * t * t, 60 + i * 0.1)
    s.airborne = true
    m.fire("physics_step", { seconds = 1 / 60, velocity = { 0, 4.0 - 10.1 * t, 6 }, ragdoll = false, airborne = true })
    worst_air = math.max(worst_air, m.state.raycasts)
    m.state.raycasts = 0
end)
print("max rays in a tick, in the air: " .. worst_air)
assert(m.camera_held_by == "me")
for _, l in ipairs(m.logs) do if l[1] == "error" then error(l[2]) end end
m.command("dyncam_dump")
print(m.console_lines[#m.console_lines - 1] or m.console_lines[#m.console_lines])
