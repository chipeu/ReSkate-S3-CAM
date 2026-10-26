-- Plugin test build 4: manual detection and board centre from the feet (ReSkate 2.1.2 gives no deck pose), and the eased hand-back
-- when the rider steps off. Run:  tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_dyncam4.lua
local T = require("tlib")
local mock = require("mock_reskate")
local Settings = require("settings")
local Store = require("store")

T.group("dyncam4")
local expect = T.expect
local vc = vector.create
local tan, rad = math.tan, math.rad

-- A stand-in camera for the manual tests (the hand-back tests use the real one).
local Stub = {}
Stub.__index = Stub
function Stub.new() return setmetatable({}, Stub) end
function Stub:set_settings(s) return Settings.valid(s) end
function Stub:cut() end
function Stub:update(dt, snap, query, extras)
    local back = -snap.forward
    return { valid = true, pos = snap.position - snap.forward * 3 + vc(0, 1, 0), right = vector.cross(vc(0, 1, 0), back),
        up = vc(0, 1, 0), back = back, fov_deg = 60, debug = { shot_name = "chase", steps = 1, speed = 6 } }
end

local function add_missing_api(m)
    local r = m.reskate
    r.input.gamepad = function() return nil end
    r.menu.game = function() return { open = m.menu_open == true, skaters = false, buttons = {} } end
    r.ui.dialog = function(id, d) m.dialog = { id = id, d = d }; return true end
    r.ui.close_dialog = function() m.dialog = nil end
    r.files.reveal = function() return true end
end

local function setup(camera, keep_storage)
    local m = mock.install({ limit_rays = true })
    add_missing_api(m)
    if keep_storage then m.storage = keep_storage end
    local app = require("app").start({ camera = camera })
    m.fire("load")
    if not keep_storage then
        -- These tests are about the game's camera on foot (the eased hand-back), which is the "game" option now; the default keeps the view.
        local o = Settings.copy(app.store.options)
        o.offboard_mode = "game"
        app.store:set_options(o)
    end
    return m, app
end

-- One run of `seconds` at 60 fps: `each(i)` sets the scene, then the physics step goes out (it must come every tick or the glue
-- takes the game for paused).
local function go(m, seconds, each, velocity)
    m.run(seconds, 60, function(i)
        if each then each(i) end
        m.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = velocity or { 0, 0, 6 } })
    end)
end

local function logged(m, text)
    for _, l in ipairs(m.logs) do
        if string.find(l[2], text, 1, true) then return l[2] end
    end
    return nil
end

local RIGHT_FOOT, LEFT_FOOT = 10, 343

-- ================================================================ manual from the trick list, board pitch from the feet
-- A trick-list note as the game sends it (entry ids are not ordered numbers).
local function named(m, entry, text) m.trick_notes({ { entry = tostring(entry), kind = "n", text = text } }) end
local function landed(m, entry) m.trick_notes({ { entry = tostring(entry), kind = "l", text = "ID_TRICK_LANDING_OK" } }) end

-- A rider rolling along +Z at 6 m/s. `tilt` is the board's pitch in degrees, nose up positive, read off the feet: the front foot is
-- the one further along the travel. `front` is the joint that is in front (the stance).
local function rider(heading, front)
    local sc = { z = 0, tilt = 0, spacing = 0.6, front = front or RIGHT_FOOT, ground = false }
    return sc, function()
        return function(i, m)
            sc.z += 0.1
            local s = m.state.skater
            s.position = vc(0, 0.95, sc.z)
            s.heading = heading
            s.switch = heading ~= 0
            m.state.telemetry.physics_state = sc.state or 100
            local back_joint = sc.front == RIGHT_FOOT and LEFT_FOOT or RIGHT_FOOT
            local dy = sc.spacing * tan(rad(sc.tilt))
            m.state.joints[sc.front] = vc(0.1, 0.12 + dy / 2, sc.z + sc.spacing / 2)
            m.state.joints[back_joint] = vc(-0.1, 0.12 - dy / 2, sc.z - sc.spacing / 2)
        end
    end
end

local function drive(m, sc, make, seconds)
    local each = make()
    go(m, seconds, function(i) each(i, m) end)
end

do
    local m, app = setup(Stub)
    local g = app.glue
    local sc, make = rider(0)
    drive(m, sc, make, 1.0)
    expect(m.camera_held_by == "me", "feet: riding, the camera is taken")
    expect(g.board_pitch_ok and math.abs(g.board_pitch) < 0.5, "feet level: pitch reads about 0 (" .. tostring(g.board_pitch) .. ")")
    expect(g.snap.manual == false, "feet level: no manual")
    expect(g.snap.board_valid, "feet: the board centre is known")
    local c = g.snap.board_position
    expect(c ~= nil and math.abs(c.z - sc.z) < 0.05 and math.abs(c.x) < 0.05, "centre is between the feet along the travel")
    expect(c ~= nil and math.abs(c.y - (0.12 - 0.08)) < 0.01, "centre is 0.08 m below the feet's midpoint (y " .. tostring(c and c.y) .. ")")

    sc.tilt = 12 -- the feet tilted with no Manual named (a pop setup, pushing): not a manual
    drive(m, sc, make, 0.5)
    expect(g.board_pitch > 11 and g.board_pitch < 13, "feet tilted 12 deg nose up: pitch " .. string.format("%.2f", g.board_pitch))
    expect(g.snap.manual == false, "nose up 12 deg, nothing named: no manual (the trick list decides)")
    sc.state = 101
    drive(m, sc, make, 0.5)
    expect(g.snap.manual == false, "state 101 (a revert or powerslide) for 0.5 s with the nose up: no manual")
    sc.state = 100
    named(m, 11, "Manual")
    drive(m, sc, make, 0.5)
    expect(g.snap.manual == true, "Manual named with the nose up: manual on")
    expect(g.snap.board_valid and g.snap.board_position.z > sc.z - 0.3 and g.snap.board_position.z < sc.z + 0.3, "manual: centre between the feet")
    sc.tilt = 0
    drive(m, sc, make, 0.5)
    expect(g.snap.manual == true, "level feet: still a manual (the feet do not end it)")
    landed(m, 11)
    drive(m, sc, make, 0.5)
    expect(g.snap.manual == false, "its landing note: manual off")
    sc.tilt = -12
    named(m, 12, "Nose Manual")
    drive(m, sc, make, 0.5)
    expect(g.board_pitch < -11 and g.snap.manual == true, "Nose Manual with the nose down 12 deg: manual on, negative pitch")
    landed(m, 12)
    sc.tilt = 0
    drive(m, sc, make, 0.5)
    expect(app.errors == 0, "no handler errors")

    -- the note of the source, once; and the manual count in the off line
    local notes = 0
    for _, l in ipairs(m.logs) do if string.find(l[2], "board pitch", 1, true) then notes += 1 end end
    expect(notes == 1 and logged(m, "board pitch from the feet") ~= nil, "one note: board pitch from the feet")
    expect(logged(m, "manual detection: trick list") ~= nil, "the once-a-run note says manual detection: trick list")
    local o = Settings.copy(app.store.options)
    o.release_blend_time = 0
    app.store:set_options(o)
    m.state.telemetry.physics_state = 504
    m.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
    go(m, 0.4, nil, { 0, 0, 0 })
    local off = logged(m, "off (")
    expect(off ~= nil and string.find(off, "2 manuals", 1, true) ~= nil, "the off line counts the manuals: " .. tostring(off))
end

-- the other way round: the left foot in front (goofy), and a switch rider facing against the travel
for _, case in ipairs({ { "left foot in front", 0, LEFT_FOOT }, { "switch (facing -Z, travelling +Z)", math.pi, RIGHT_FOOT },
    { "switch, left foot in front", math.pi, LEFT_FOOT } }) do
    local name = case[1]
    local m, app = setup(Stub)
    local g = app.glue
    local sc, make = rider(case[2], case[3])
    drive(m, sc, make, 0.8)
    expect(g.snap.manual == false and math.abs(g.board_pitch) < 0.5, name .. ": level, no manual")
    sc.tilt = 12
    named(m, 21, "Manual")
    drive(m, sc, make, 0.5)
    expect(g.snap.manual == true and g.board_pitch > 11, name .. ": nose up reads +12 (" .. string.format("%.2f", g.board_pitch) .. ")")
    sc.tilt = -12
    drive(m, sc, make, 0.5)
    expect(g.snap.manual == true and g.board_pitch < -11, name .. ": nose down reads -12 (" .. string.format("%.2f", g.board_pitch) .. ")")
end

-- a bad foot spacing is unreadable, not a pitch
do
    local m, app = setup(Stub)
    local g = app.glue
    local sc, make = rider(0)
    sc.spacing = 0.1
    sc.tilt = 12
    drive(m, sc, make, 1.0)
    expect(not g.board_pitch_ok and g.snap.manual == false and not g.snap.board_valid, "feet 0.1 m apart: unreadable, no manual, no centre")
    sc.spacing = 1.2
    drive(m, sc, make, 0.5)
    expect(not g.board_pitch_ok and g.snap.manual == false, "feet 1.2 m apart: unreadable")
    sc.spacing = 0.21
    drive(m, sc, make, 0.3)
    expect(g.board_pitch_ok, "0.21 m reads (0.2 is the least)")
    drive(m, sc, make, 0.5)
    expect(logged(m, "board pitch unreadable") ~= nil or logged(m, "board pitch from the feet") ~= nil, "a source note is logged")
end

-- no joints at all (a skater that cannot be read): unreadable, and no error
do
    local m, app = setup(Stub)
    go(m, 1.5, function() m.state.skater.position = m.state.skater.position + vc(0, 0, 0.1) end)
    expect(app.glue.snap.manual == false and not app.glue.board_pitch_ok, "no joints: unreadable")
    expect(logged(m, "board pitch unreadable") ~= nil, "the note says unreadable")
    expect(app.errors == 0, "no errors without joints")
end

-- the deck pose, when a later ReSkate gives it, comes first
do
    local m, app = setup(Stub)
    local g = app.glue
    local sc, make = rider(0)
    local a = rad(-12) -- about X by -12 deg lifts the deck's +Z end: nose up
    local each = make()
    named(m, 31, "Manual")
    go(m, 1.5, function(i)
        each(i, m)
        m.state.board.deck = { position = vc(0, 0.3, sc.z), rotation = { x = math.sin(a / 2), y = 0, z = 0, w = math.cos(a / 2) } }
    end)
    expect(g.snap.manual == true and g.board_pitch > 11, "deck pose wins over level feet")
    expect(g.snap.board_valid and math.abs(g.snap.board_position.y - 0.3) < 1e-6, "board centre from the deck")
    expect(logged(m, "board pitch from the deck") ~= nil, "note: from the deck")
end

-- a steep ramp: no manual, whatever the feet say
do
    local m, app = setup(Stub)
    local g = app.glue
    local slope = tan(rad(30))
    m.state.raycast = function(from, to)
        local f0, f1 = from.y - from.z * slope, to.y - to.z * slope
        if f0 >= 0 and f1 < 0 then return from + (to - from) * (f0 / (f0 - f1)) end
        return nil
    end
    local tilt = 0
    local z = 0
    local function each(i)
        z += 0.1
        local y = z * slope
        m.state.skater.position = vc(0, y + 0.95, z)
        -- the board lies in the ramp's plane plus `tilt`
        local ang = rad(30 + tilt)
        local dz, dy = 0.3 * math.cos(ang), 0.3 * math.sin(ang)
        m.state.joints[RIGHT_FOOT] = vc(0.1, y + 0.12 + dy, z + dz)
        m.state.joints[LEFT_FOOT] = vc(-0.1, y + 0.12 - dy, z - dz)
    end
    go(m, 1.0, each)
    expect(g.ground_normal_raw.y < 0.9, "the ramp's normal is steep (" .. string.format("%.3f", g.ground_normal_raw.y) .. ")")
    expect(g.snap.manual == false, "steep ramp, feet along the ramp: no manual")
    tilt = 12
    go(m, 0.8, each)
    expect(g.snap.manual == false, "steep ramp, feet 12 deg off the ramp: still no manual")
end

-- ================================================================ hand-back when stepping off
local real = require("camera")
local UP = vc(0, 1, 0)

-- The game's own camera for a skater at `p` facing +Z: back / up / right in the skater's frame, looking at `look` above him.
local function game_camera_for(p, back, up, right, look)
    local pos = p + vc(0, 0, -back) + vc(0, up, 0) + vc(-right, 0, 0) -- facing +Z the right-hand side is -X
    local forward = vector.normalize((p + vc(0, look, 0)) - pos)
    local r = vector.normalize(vector.cross(forward, UP))
    return { position = pos, forward = forward, right = r, up = vector.cross(r, forward), fov = 60, free = false }
end

local function expected_target(p, back, up, right, look)
    return p + vc(0, 0, -back) + vc(0, up, 0) + vc(-right, 0, 0), p + vc(0, look, 0)
end

local function ride_to(m, z_end)
    local z = m.state.skater.position.z
    go(m, 1.2, function()
        z = math.min(z_end, z + 0.1)
        m.state.skater.position = vc(0, 0.95, z)
    end)
end

local function dismount(m)
    m.state.telemetry.physics_state = 504
    m.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
end

local function sets_and_release(m, from_index)
    local sets, release_at, releases = {}, nil, 0
    for i = from_index, #m.calls do
        local c = m.calls[i]
        if c.fn == "set" then sets[#sets + 1] = { i = i, call = c } end
        if c.fn == "release" then
            releases += 1
            release_at = release_at or i
        end
    end
    return sets, release_at, releases
end

-- Runs the dismount `seconds` long at 60 fps and tells the time (in ticks) the camera was still being set after the dismount.
local function after_dismount(m, p, seconds)
    local first = #m.calls + 1
    dismount(m)
    local ticks_set, last_set_tick, release_tick = 0, nil, nil
    for t = 1, math.floor(seconds * 60) do
        local before = #m.calls
        go(m, 1 / 60, function() m.state.skater.position = p end, { 0, 0, 0 })
        for i = before + 1, #m.calls do
            if m.calls[i].fn == "set" then ticks_set += 1; last_set_tick = t end
            if m.calls[i].fn == "release" and not release_tick then release_tick = t end
        end
    end
    return first, ticks_set, last_set_tick, release_tick
end

-- 1. the game's camera learned while on foot is where the hand-back ends
do
    local m, app = setup(real)
    local p0 = vc(0, 0.95, 0)
    dismount(m)
    m.state.game_camera = game_camera_for(p0, 3.0, 1.8, 0.5, 1.2)
    go(m, 3.0, nil, { 0, 0, 0 }) -- on foot: nothing taken, the offset is learned
    expect(m.camera_held_by == nil, "on foot, nothing taken")
    m.state.telemetry.physics_state = 100
    ride_to(m, 20)
    expect(m.camera_held_by == "me", "riding: taken")
    local p = m.state.skater.position
    local first, ticks_set, last_set_tick, release_tick = after_dismount(m, p, 1.2)
    local sets, release_at, releases = sets_and_release(m, first)
    expect(releases == 1, "dismount: released exactly once (" .. releases .. ")")
    -- RELEASE_AFTER is 0.1 s, then 0.45 s of easing
    expect(ticks_set >= 0.45 * 60 - 3 and ticks_set <= 0.65 * 60 + 3, "camera.set kept going for the blend (" .. ticks_set .. " ticks)")
    expect(release_tick ~= nil and last_set_tick <= release_tick, "release comes after the last set")
    local last = sets[#sets].call
    local want_pos, want_look = expected_target(p, 3.0, 1.8, 0.5, 1.2)
    expect(vector.magnitude(last.position - want_pos) < 0.3, "last pose within 0.3 m of the learned on-foot camera (" ..
        string.format("%.3f", vector.magnitude(last.position - want_pos)) .. ")")
    local aim = vector.normalize(want_look - last.position)
    expect(vector.dot(vector.normalize(last.forward), aim) > 0.995, "and it looks at the skater (1.2 m up)")
    -- no jump from tick to tick
    local worst = 0
    for i = 2, #sets do worst = math.max(worst, vector.magnitude(sets[i].call.position - sets[i - 1].call.position)) end
    expect(worst < 0.5, "no cut inside the hand-back: largest step " .. string.format("%.2f", worst) .. " m")
    expect(m.camera_held_by == nil and logged(m, "off (on foot, eased 0.45 s)") ~= nil, "off line says on foot, eased 0.45 s")
    expect(app.errors == 0, "no errors")
end

-- 2. nothing learned: the riding camera offset of the take is the estimate
do
    local m, app = setup(real)
    -- the game's camera as it is at the take: 4 m back, 1.0 m up, looking 0.9 m above the skater
    local p = vc(0, 0.95, 0)
    m.state.game_camera = game_camera_for(p, 4.0, 1.0, 0, 0.9)
    go(m, 1.0, function() m.state.skater.position = p end, { 0, 0, 0 }) -- on the board, standing still: the take sees this camera
    expect(m.camera_held_by == "me", "on the board: taken")
    local first = after_dismount(m, p, 1.2)
    local sets, _, releases = sets_and_release(m, first)
    local want = expected_target(p, 4.0, 1.0, 0, 0.9)
    expect(releases == 1 and #sets > 20, "riding offset: eased then released once")
    expect(vector.magnitude(sets[#sets].call.position - want) < 0.3, "riding offset: ends near 4 m back, 1 m up (" ..
        string.format("%.3f", vector.magnitude(sets[#sets].call.position - want)) .. ")")
end

-- 3. nothing at all: 2.6 m back, 1.5 m up, looking 1.0 m above the skater
do
    local m, app = setup(real)
    m.state.game_camera = nil
    ride_to(m, 20)
    expect(m.camera_held_by == "me", "riding without a readable game camera: taken")
    local p = m.state.skater.position
    local first = after_dismount(m, p, 1.2)
    local sets, _, releases = sets_and_release(m, first)
    local want = expected_target(p, 2.6, 1.5, 0, 1.0)
    expect(releases == 1 and #sets > 20, "default estimate: eased then released once")
    expect(vector.magnitude(sets[#sets].call.position - want) < 0.3, "default estimate: ends 2.6 m back, 1.5 m up (" ..
        string.format("%.3f", vector.magnitude(sets[#sets].call.position - want)) .. ")")
    expect(vector.dot(vector.normalize(sets[#sets].call.forward), vector.normalize(p + vc(0, 1.0, 0) - sets[#sets].call.position)) > 0.995,
        "default estimate: looks 1.0 m above the skater")
end

-- 4. back on the board in the middle of the phase: no release, no cut
do
    local m, app = setup(real)
    ride_to(m, 20)
    local p = m.state.skater.position
    local first = #m.calls + 1
    dismount(m)
    go(m, 0.35, function() m.state.skater.position = p end, { 0, 0, 0 }) -- 0.1 s to decide + 0.25 s into the blend
    local _, release_at, releases = sets_and_release(m, first)
    expect(releases == 0 and m.camera_held_by == "me", "mid-phase: still ours, not released")
    m.state.telemetry.physics_state = 100
    local before = #m.calls + 1
    local zb = p.z
    go(m, 0.8, function() zb += 0.1; m.state.skater.position = vc(0, 0.95, zb) end, { 0, 0, 6 })
    local sets, _, releases2 = sets_and_release(m, first)
    expect(releases2 == 0 and m.camera_held_by == "me", "back on the board: the phase is cancelled, never released")
    local worst = 0
    for i = 2, #sets do worst = math.max(worst, vector.magnitude(sets[i].call.position - sets[i - 1].call.position)) end
    expect(worst < 0.5, "back on the board: no cut, largest step " .. string.format("%.2f", worst) .. " m")
    -- and the next dismount hands back again
    local first2 = #m.calls + 1
    dismount(m)
    go(m, 1.0, function() m.state.skater.position = p end, { 0, 0, 0 })
    local sets2, _, releases3 = sets_and_release(m, first2)
    expect(releases3 == 1 and #sets2 > 20, "a later dismount hands back as usual")
end

-- 5. a game menu in the middle of the phase: instant release
do
    local m, app = setup(real)
    ride_to(m, 20)
    local p = m.state.skater.position
    local first = #m.calls + 1
    dismount(m)
    go(m, 0.3, function() m.state.skater.position = p end, { 0, 0, 0 })
    expect(m.camera_held_by == "me", "mid-phase: still ours")
    m.menu_open = true
    local n = #m.calls
    go(m, 1 / 60, function() m.state.skater.position = p end, { 0, 0, 0 })
    expect(m.camera_held_by == nil and m.calls[#m.calls].fn == "release", "menu mid-phase: released in that tick")
    m.menu_open = false
    go(m, 0.5, function() m.state.skater.position = p end, { 0, 0, 0 })
    local _, _, releases = sets_and_release(m, first)
    expect(releases == 1, "and only once")
    expect(logged(m, "off (a game menu is open)") ~= nil, "the reason is the menu, not 'on foot'")
end

-- 6. no skater mid-phase, and switching off mid-phase: instant too
do
    local m, app = setup(real)
    ride_to(m, 20)
    local p = m.state.skater.position
    dismount(m)
    go(m, 0.3, function() m.state.skater.position = p end, { 0, 0, 0 })
    m.state.skater = nil
    go(m, 1 / 30, nil, { 0, 0, 0 })
    expect(m.camera_held_by == nil, "no skater mid-phase: released at once")
    local m2, app2 = setup(real)
    ride_to(m2, 20)
    local p2 = m2.state.skater.position
    dismount(m2)
    go(m2, 0.3, function() m2.state.skater.position = p2 end, { 0, 0, 0 })
    m2.command("dyncam 0")
    go(m2, 1 / 30, function() m2.state.skater.position = p2 end, { 0, 0, 0 })
    expect(m2.camera_held_by == nil, "switched off mid-phase: released at once")
end

-- 7. release_blend_time 0 keeps the old instant release
do
    local m, app = setup(real)
    local o = Settings.copy(app.store.options)
    o.release_blend_time = 0
    app.store:set_options(o)
    ride_to(m, 20)
    local p = m.state.skater.position
    local first, ticks_set, last_set_tick, release_tick = after_dismount(m, p, 0.5)
    local _, _, releases = sets_and_release(m, first)
    expect(releases == 1 and ticks_set <= 8 and release_tick ~= nil and release_tick <= 12, "blend time 0: released after the 0.1 s wait (" ..
        tostring(release_tick) .. " ticks), nothing eased (" .. ticks_set .. " sets)")
    expect(logged(m, "off (on foot)") ~= nil, "and the off line is plain 'on foot'")
end

-- 8. the option: default, slider, saved, old store without the field
do
    expect(Store.new().options.release_blend_time == 0.45, "default Hand-back blend time is 0.45 s")
    local m, app = setup(real)
    m.build_page({ tabs = 8 })
    local w = m.find_widget("bt_release")
    local tip = false -- the menu puts a slider's tooltip in the note under it
    for i, x in ipairs(m.widgets) do
        local n = m.widgets[i + 1]
        if x == w and n and n.kind == "note" and #n.text <= 300 and string.find(n.text, "hands back at once", 1, true) then tip = true end
    end
    expect(w ~= nil and w.kind == "slider" and string.find(w.text, "Hand-back", 1, true) ~= nil and tip, "slider on the ADVANCED tab with a tooltip")
    expect(w ~= nil and w.min == 0 and w.value == 0.45, "slider 0..., shows 0.45")
    m.build_page({ tabs = 8, bt_release = 0.8 })
    expect(app.store.options.release_blend_time == 0.8, "the slider sets it")
    expect(m.storage.settings["S3Cam.Options.ReleaseBlendTime"] == 0.8, "and it is saved")
    local m2, app2 = setup(real, m.storage)
    expect(app2.store.options.release_blend_time == 0.8, "reloaded")
    -- an old store: the key is not there
    local keep = m.storage
    keep.settings["S3Cam.Options.ReleaseBlendTime"] = nil
    local m3, app3 = setup(real, keep)
    expect(app3.store.options.release_blend_time == 0.45, "an old store without the field loads the default")
    expect(app3.store.load_report.refused == 0, "and nothing is reported as refused")
end

-- 9. a bind the game refuses (raises, or says no) is logged once as a warning and does not stop the plugin
do
    for _, how in ipairs({ "raises", "says no" }) do
        local m = mock.install({ limit_rays = true })
        add_missing_api(m)
        m.reskate.input.bind = function(action, key)
            if how == "raises" then error("reskate.input.bind: nope") end
            return false, "that is not a key or pad combo"
        end
        local app = require("app").start({ camera = Stub })
        m.fire("load")
        local warns = 0
        for _, l in ipairs(m.logs) do
            if l[1] == "warn" and string.find(l[2], "could not bind", 1, true) then warns += 1 end
        end
        expect(warns == 1, "bind " .. how .. ": one warning")
        expect(app.store ~= nil and m.page_title ~= nil, "bind " .. how .. ": the plugin still starts")
    end
end

T.done()
if T.failures > 0 then error("dyncam4 tests failed") end
