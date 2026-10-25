-- Smoke test of the mock: a tiny "plugin" uses most of the API and the mock records it.
local mock = require("mock_reskate")
local m = mock.install()

local enabled, strength = true, 1
local ticks = 0
reskate.on("load", function() reskate.log("loaded") end)
reskate.on("tick", function(dt_ms)
    ticks += 1
    local s = reskate.skater.get()
    if not s then return end
    local hit = reskate.world.raycast(s.position, s.position - vector.create(0, 5, 0))
    assert(hit and math.abs(hit.y) < 1e-6, "the default ground plane is at y = 0")
    reskate.camera.look(s.position + vector.create(0, 1, -3), s.position, 60)
end)
reskate.on("action", function(name) if name == "swap" then enabled = not enabled end end)
reskate.input.bind("swap", "F7")
reskate.console.command("dyncam log", "toggle the log", function(args) reskate.console.print("log " .. tostring(args[1])) end)
reskate.menu.page("Dynamic Camera", function(ui)
    ui:card("MAIN", "the page")
    enabled = ui:toggle("enabled", "Enabled", enabled)
    strength = ui:slider("strength", "Strength", strength, 0.2, 4)
    if ui:button("reset", "Reset") then strength = 1 end
end)
reskate.storage.set("preset", { name = "a", values = { 1, 2, 3 } })
reskate.files.write("presets/a.json", reskate.json.encode({ x = 1 }))
local timer_hits = 0
reskate.time.every(100, function() timer_hits += 1 end)

m.fire("load")
m.run(1, 60)
assert(ticks == 60 and timer_hits == 9 or timer_hits == 10, "timers fire from the tick")
assert(m.last_call("look") and m.camera_held_by == "me")
assert(select(1, reskate.camera.held()) == true)
m.fire("action", "swap")
assert(enabled == false)
m.build_page({ strength = 3, reset = false })
assert(strength == 3 and m.find_widget("strength").result == 3)
m.build_page({ reset = true })
assert(strength == 1)
assert(m.command("dyncam log 1") and m.console_lines[1] == "log 1")
assert(reskate.storage.get("preset").values[3] == 3)
assert(reskate.json.decode(reskate.files.read("presets/a.json")).x == 1)
assert(not pcall(reskate.on, "no_such_event", function() end))
assert(not pcall(reskate.storage.set, "k", { v = vector.create(1, 2, 3) }))
reskate.camera.release()
assert(m.camera_held_by == nil)
print("mock ok: " .. #m.calls .. " camera calls, " .. #m.widgets .. " widgets, " .. #m.logs .. " log lines")
