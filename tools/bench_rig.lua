-- Offline cost of the Luau rig (the same ride as the C++ bench: flat, 12 m/s, a hop every 2 s), per 1/60 s step.
local Rig = require("rig")
local set = Rig.default_settings()
local inp = Rig.new_input()
local r = Rig.new()
local frames = 60 * 120
local dt = 1 / 60
local function at(t)
    local y, vy = 0.95, 0
    local phase = t % 2
    if phase > 1 and phase < 1.5 then local u = phase - 1; y = y + 2.5 * u - 5.05 * u * u; vy = 2.5 - 10.1 * u end
    return vector.create(0, y, 12 * t), vector.create(0, vy, 12)
end
inp.elevation_target = math.rad(7)
inp.distance.target = 2.0
local t0 = os.clock()
for i = 0, frames - 1 do
    local p, v = at(i * dt)
    inp.anchor.position = p
    inp.anchor.reference_height = p.y
    inp.anchor.velocity = v
    inp.compass.position = p
    if i == 0 then Rig.reset(r, inp, set) else Rig.update(r, dt, inp, set) end
end
local us = (os.clock() - t0) * 1e6 / frames
print(string.format("Luau rig %.2f us a step (C++ rig 0.344 us); whole camera at 5x: %.3f ms a frame at 60 fps, %.3f ms at 144 fps (1 step every 2.4 frames)", us, us * 5 / 1000, us * 5 / 1000))
