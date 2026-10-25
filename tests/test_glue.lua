-- Offline tests of the plugin's glue, settings storage, presets, menu, binds and console against tests\mock_reskate.lua.
--   tools\luau_run.exe -I Dynamic_Camera\plugin -I tests tests\test_glue.lua [real]
-- Default camera: a small stub (casts rays, returns a pose behind the skater). With the argument `real`, the real camera.lua.
local T = require("tlib")
local mock = require("mock_reskate")
local Settings = require("settings")
local Presets = require("presets")

T.group("glue")
local expect = T.expect
local vc = vector.create
local real = arg[1] == "real"

local Stub = {}
Stub.__index = Stub
Stub.rays_per_update = 12
function Stub.new() return setmetatable({ updates = 0, cuts = 0 }, Stub) end
function Stub:set_settings(s) self.settings = s; return Settings.valid(s) end
function Stub:cut() self.cuts += 1 end
function Stub:update(dt, snap, query, extras)
    self.updates += 1
    self.last_extras = extras
    for i = 1, Stub.rays_per_update do query(snap.position, snap.position - vc(0, 5 + i * 0.01, 0), false) end
    local back = -snap.forward
    return { valid = true, pos = snap.position - snap.forward * 3 + vc(0, 1, 0), right = vector.cross(vc(0, 1, 0), back),
        up = vc(0, 1, 0), back = back, fov_deg = 60, debug = { shot_name = "chase", steps = 1, speed = 6 } }
end
local camera = real and require("camera") or Stub

local function add_missing_api(m)
    local r = m.reskate
    r.input.gamepad = function() return m.pad end
    r.menu.game = function() return { open = m.menu_open == true, skaters = false, buttons = {} } end
    r.ui.dialog = function(id, d) m.dialog = { id = id, d = d }; return true end
    r.ui.close_dialog = function() m.dialog = nil end
    r.files.reveal = function() m.revealed = true; return true end
end

local function setup(mode_name)
    local m = mock.install({ limit_rays = true })
    add_missing_api(m)
    local app = require("app").start({ camera = camera })
    m.fire("load")
    if mode_name then
        local o = Settings.copy(app.store.options)
        o.offboard_mode = mode_name
        app.store:set_options(o)
    end
    return m, app
end

local function ride(m, seconds)
    local z0 = m.state.skater and m.state.skater.position.z or 0
    m.run(seconds, 60, function(i)
        local s = m.state.skater
        if not s then return end
        s.position = vc(s.position.x, 0.95, z0 + i * 0.1)
        m.fire("physics_step", { at = 0, seconds = 1 / 60, wipeout = false, airborne = false, ragdoll = false, velocity = { 0, 0, 6 } })
    end)
end

-- 1. takes the camera when riding, shows a view, releases on foot
do
    local m, app = setup("game")
    ride(m, 0.5)
    expect(m.camera_held_by == "me", "riding: the camera is taken")
    local c = m.last_call("set")
    expect(c ~= nil and vector.dot(vector.normalize(c.forward), vc(0, 0, 1)) > (real and 0.8 or 0.999), "the view looks along the skater's +Z")
    expect(c.position.z < m.state.skater.position.z and c.position.y > 0, "camera behind the skater")
    expect(c.fov == nil or (c.fov >= 10 and c.fov <= 150), "fov in range")
    expect(app.glue:status() == "Enabled", "status says Enabled")
    m.state.telemetry.physics_state = 504
    ride(m, 0.8) -- 0.1 s to decide + the 0.45 s hand-back ease
    expect(m.camera_held_by == nil, "on foot: the camera is released")
    expect(m.last_call("release") ~= nil, "release was called")
    expect(app.glue:status() == "Disabled off board", "status off board")
    m.state.telemetry.physics_state = 100
    ride(m, 0.4)
    expect(m.camera_held_by == "me", "back on the board: taken again")
    m.state.skater = nil
    ride(m, 0.2)
    expect(m.camera_held_by == nil, "no skater: released")
    expect(app.errors == 0, "no handler errors with a nil skater")
    m.state.skater = mock.skater_default()
    ride(m, 0.4)
    expect(m.camera_held_by == "me", "skater back: taken")
    m.menu_open = true
    ride(m, 0.1)
    expect(m.camera_held_by == nil, "game menu open: released")
    m.menu_open = false
    ride(m, 0.4)
    expect(m.camera_held_by == "me", "menu closed: taken")
    m.command("dyncam 0")
    ride(m, 0.1)
    expect(m.camera_held_by == nil, "dyncam 0: released")
    m.command("dyncam toggle")
    ride(m, 0.4)
    expect(m.camera_held_by == "me", "dyncam toggle: on again")
    m.state.spectating = true
    ride(m, 0.2)
    expect(m.camera_held_by == "me", "Spectate: we keep holding")
    m.state.spectating = false
    ride(m, 0.1)
    expect(m.camera_held_by == "me" and app.errors == 0, "Spectate over: running again, no errors")
end

-- 2. bail and hippy jump
do
    local m = setup("game")
    ride(m, 0.4)
    m.state.telemetry.physics_state = 504
    m.state.telemetry.watch = { ragdoll_known = true, ragdoll = true }
    ride(m, 1.0)
    expect(m.camera_held_by == "me", "bail (ragdoll): the camera stays")
    m.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
    ride(m, 0.8) -- the hand-back ease takes 0.45 s
    expect(m.camera_held_by == nil, "ragdoll over, off the board: released")

    local m2 = setup()
    ride(m2, 0.4)
    m2.state.telemetry.physics_state = 504
    m2.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
    m2.run(0.5, 60, function(i)
        m2.state.skater.position = vc(0, 0.95 + i * 0.01, 2.4 + i * 0.05)
        m2.fire("physics_step", { seconds = 1 / 60, velocity = { 0, 4.1, 3 }, ragdoll = false })
    end)
    expect(m2.camera_held_by == "me", "hippy jump keeps the camera")

    local m3 = setup("game")
    ride(m3, 0.4)
    m3.state.telemetry.physics_state = 504
    m3.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
    m3.run(0.8, 60, function(i) m3.state.skater.position = vc(0, 0.95, 2.4 + i * 0.01); m3.fire("physics_step", { seconds = 1 / 60, velocity = { 0, 0.5, 1 }, ragdoll = false }) end)
    expect(m3.camera_held_by == nil, "dismount releases")
end

-- 3. raycast budget
do
    local m, app = setup()
    Stub.rays_per_update = 100
    ride(m, 1.0)
    expect(app.errors == 0 and m.camera_held_by == "me", "100 camera rays an update: no API error (capped)")
    expect(real or app.glue.rays_capped > 0, "the cap was reported")
    Stub.rays_per_update = 12
end

-- 4. another plugin holds the camera
do
    local m, app = setup()
    m.camera_held_by = "OtherMod"
    ride(m, 1.0)
    expect(m.camera_held_by == "OtherMod" and app.glue.running == false, "another holder keeps the camera")
    m.camera_held_by = nil
    ride(m, 1.0)
    expect(m.camera_held_by == "me", "free again: taken")
end

-- 5. settings: console -> storage -> reload
do
    local m, app = setup()
    expect(m.command("dyncam_fov 90"), "dyncam_fov exists")
    expect(m.command("s3cam_angle high"), "s3cam_angle alias exists")
    expect(m.command("dyncam_shoulder auto"), "dyncam_shoulder")
    expect(m.command("dyncam_side swap"), "dyncam_side")
    expect(m.command("dyncam_shake 0") and m.command("dyncam_shotfov 0") and m.command("dyncam_log 1"), "shake / shotfov / log")
    expect(m.command("dyncam_preset native") and m.command("dyncam_preset full"), "dyncam_preset")
    expect(m.command("dyncam_dump") and m.command("dyncam"), "dump / status")
    m.command("dyncam_fov 10")
    expect(string.find(m.console_lines[#m.console_lines], "error", 1, true) ~= nil, "dyncam_fov 10 refused")
    local s = app.store.settings
    expect(s.fov_override_deg == 90 and s.angle == Settings.CameraAngle.High and not s.shake_enabled, "settings changed")
    expect(s.shoulder.mode == Settings.ShoulderSide.Manual, "dyncam_side swap took manual control")
    expect(not app.store.options.shot_fov and app.store.options.verbose, "options changed")
    local saved = m.storage.settings
    expect(saved ~= nil and saved["S3Cam.FovOverride"] == 90 and saved["S3Cam.Angle"] == "high", "saved under S3Cam.* keys")
    local keep = m.storage
    local m2 = mock.install({ limit_rays = true })
    add_missing_api(m2)
    m2.storage = keep
    local app2 = require("app").start({ camera = camera })
    expect(app2.store.settings.fov_override_deg == 90 and app2.store.settings.angle == Settings.CameraAngle.High, "reloaded from storage")
    expect(app2.store.options.verbose and not app2.store.options.shot_fov, "options reloaded")
end

-- 6. presets: round trip, old preset conversion, refusals, names
do
    local m, app = setup()
    local st = app.store
    local r = Presets.save(st, "Park cam", false)
    expect(r.ok and m.files["presets/Park cam.json"] ~= nil, "preset saved as a file")
    expect(Presets.save(st, "Park cam", false).confirm == true, "a taken name asks first")
    expect(not Presets.save(st, "Skate 3", false).ok, "a built-in name is refused")
    local doc = reskate.json.decode(m.files["presets/Park cam.json"])
    expect(doc.name == "Park cam" and doc.version == 1 and doc.values["S3Cam.Distance.Slow"] ~= nil, "format: name, version, values")
    local old = reskate.json.encode({ name = "Old one", version = 1, values = {
        ["S3Cam.Framing.DistanceScale"] = 0.85, ["S3Cam.Distance.Min"] = 1.2, ["S3Cam.Distance.Max"] = 3.0,
        ["S3Cam.Fov.SpeedFovMin"] = 20, ["S3Cam.Fov.SpeedFovMax"] = 40, ["S3Cam.Framing.HeightDegrees"] = 40, ["S3Cam.Shoulder.Offset"] = 2.5, ["S3Cam.Follow.Strength"] = "x",
    } })
    local parsed = Presets.parse_preset(old)
    expect(parsed ~= nil, "old preset parses")
    local c = parsed.camera
    local want = Settings.ride_distance_from_legacy({ min = 1.2, max = 3.0 }, 0.85, Settings.CameraAngle.Low)
    expect(T.near(c.ride_distance.slow, want.slow) and T.near(c.ride_distance.fast, want.fast), "ride distance converted from the legacy keys")
    expect(c.distance_high.max == 3.0 and c.distance_high.min == 1.2, "High copies the old shared limits")
    expect(c.fov.speed_fov_min == 20 and c.fov.speed_fov_max == 40, "a pair loads whole in either order (second pass)")
    expect(c.shoulder.offset == 1 and c.framing.height_degrees == 40, "valid but out of menu range is clamped (shoulder offset 2.5 -> 1)")
    expect(parsed.report.refused >= 1 and c.follow.strength == 1, "wrong type refused, default kept")
    expect(Presets.parse_preset("not json") == nil and Presets.parse_preset('{"a":1}') == nil, "refusals")
    expect(Presets.import_text(old).ok and m.files["presets/Old one.json"] ~= nil, "import writes a file")
    expect(Presets.import_text(old).name == "Old one (2)", "import picks a free name")
    expect(Presets.load(st, "Old one").ok and st.settings.framing.distance_scale == 0.85, "load applies")
    expect(Presets.load(st, "Close & low").ok and T.near(st.settings.ride_distance.slow, 1.53), "built-in loads")
    expect(Presets.rename("Old one", "Renamed").ok and m.files["presets/Renamed.json"] ~= nil and m.files["presets/Old one.json"] == nil, "rename")
    expect(Presets.delete("Renamed").ok and m.files["presets/Renamed.json"] == nil, "delete")
    expect(Presets.sanitize_name("CON") == "CON_" and Presets.sanitize_name("a/b:c") == "abc" and Presets.sanitize_name("  .") == "", "names")
    local rt = Presets.parse_preset(Presets.preset_text("rt", st.settings, st.options))
    expect(Settings.valid(rt.camera) and rt.report.refused == 0, "round trip loads clean")
end

-- 7. menu
do
    local m, app = setup()
    local st = app.store
    for tab = 1, 8 do
        Presets.refresh()
        local ok, err = pcall(function() m.build_page({ tabs = tab }) end)
        expect(ok, "tab " .. tab .. " builds: " .. tostring(err))
        local n = #m.widgets
        expect(n <= 160 and n > 5, "tab " .. tab .. " has " .. n .. " widgets (limit 160)")
        for _, w in ipairs(m.widgets) do
            if w.text then expect(#w.text <= ((w.kind == "note" or w.kind == "warn") and 300 or 60), "text length: " .. w.text) end
            if w.help then expect(#w.help <= 300, "help length: " .. w.help) end
            if w.kind == "slider" then
                local f = string.gsub(w.format, "%%%%", "")
                local _, count = string.gsub(f, "%%%.?%d?[fd]", "")
                expect(count == 1, "format has one number: " .. w.format)
            end
        end
    end
    m.build_page({ tabs = 3, fl_strength = 2.5 })
    expect(st.settings.follow.strength == 2.5, "a slider applies at once")
    expect(m.storage.settings["S3Cam.Follow.Strength"] == 2.5, "and is saved")
    m.build_page({ tabs = 3 })
    expect(st.settings.follow.strength == 2.5, "stays")
    m.build_page({ tabs = 2, cam_height = 2 })
    expect(st.settings.angle == Settings.CameraAngle.High, "dropdown applies")
    m.build_page({ tabs = 2, o_r3 = false })
    expect(st.options.follow_game_height == false, "an option toggles")
    m.build_page({ tabs = 1, main_on = false })
    expect(st.enabled == false, "main switch")
    local s2 = Settings.copy(st.settings)
    s2.look.landing_look_full_drop = 0.2
    st:set_settings(s2)
    local rev = st.revision
    m.build_page({ tabs = 5 })
    m.build_page({ tabs = 5 })
    expect(st.revision == rev, "builds do not touch settings that were not edited")
    m.build_page({ tabs = 8, reset_all = true })
    expect(st.settings.follow.strength == 1.0, "reset all")
    m.build_page({ tabs = 1, preset_manage = true })
    expect(m.dialog ~= nil and m.dialog.id == "dyncam_presets", "Manage presets opens the dialog")
    m.build_page({ tabs = 1, preset_folder = true })
    expect(m.revealed == true, "Open preset folder")
end

-- 8. the presets dialog
do
    local m = setup()
    local Menu = require("menu")
    Menu.open_dialog("")
    m.fire("throwdown_ui", { action = "dialog", mode = "", args = { "dyncam_presets", "save", "From dialog", "0", "" } })
    expect(m.files["presets/From dialog.json"] ~= nil, "dialog Save as new writes the file")
    local idx
    for i, r in ipairs(m.dialog.d.list.rows) do if r.text == "From dialog" then idx = i end end
    expect(idx ~= nil, "dialog lists it")
    m.fire("throwdown_ui", { action = "dialog", mode = "", args = { "dyncam_presets", "Delete", "From dialog", tostring(idx), "" } })
    expect(m.files["presets/From dialog.json"] ~= nil, "first Delete only asks")
    m.fire("throwdown_ui", { action = "dialog", mode = "", args = { "dyncam_presets", "Delete", "From dialog", tostring(idx), "" } })
    expect(m.files["presets/From dialog.json"] == nil, "second Delete deletes")
    m.fire("throwdown_ui", { action = "dialog", mode = "", args = { "dyncam_presets", "file", "", "0", reskate.json.encode({ name = "Imp", version = 1, values = {} }) } })
    expect(m.files["presets/Imp.json"] ~= nil, "dialog file import")
    m.fire("throwdown_ui", { action = "dialog", mode = "", args = { "dyncam_presets", "cancel", "", "0", "" } })
    expect(m.dialog == nil, "cancel closes")
end

-- 9. binds and the rest
do
    local m, app = setup()
    -- 2.1.2 lists an action on Settings > Binds only when it is bound to a real key (a nil key raises); the row reads "<plugin id>: <action>".
    expect(m.binds["camera on / off"] == "Ctrl+Shift+D" and m.binds["switch shoulder side"] == "Ctrl+Shift+S", "both binds registered, on Ctrl+Shift+D / Ctrl+Shift+S")
    expect(not pcall(reskate.input.bind, "x", nil) and not pcall(reskate.input.bind, "x", "Ctrl+Shift+Banana"), "the mock refuses a nil or invalid key as 2.1.2 does")
    expect(select("#", pcall(reskate.input.bind, "x", "F7")) >= 2 and m.binds.x == "F7", "a valid key binds")
    for _, l in ipairs(m.logs) do expect(l[1] ~= "warn" and l[1] ~= "error", "no warning at start: " .. l[2]) end
    local was = app.store.enabled
    m.fire("action", "camera on / off")
    expect(app.store.enabled == not was, "bind toggles the camera")
    app.store.enabled = true
    m.fire("action", "switch shoulder side")
    expect(app.store.settings.shoulder.side == 1 and app.store.settings.shoulder.mode == Settings.ShoulderSide.Manual, "bind: from Off the swap takes manual control, camera on the right")
    m.fire("action", "switch shoulder side")
    expect(app.store.settings.shoulder.side == -1, "bind swaps the shoulder")
    local angle = app.store.settings.angle
    m.pad = { buttons = { right_stick = true } }
    m.tick(16)
    m.pad = { buttons = { right_stick = false } }
    m.tick(16)
    expect(app.store.settings.angle ~= angle, "R3 switches Low / High")
    ride(m, 0.4)
    m.fire("level_unloading", "x")
    expect(m.camera_held_by == nil, "level change releases")
    m.fire("unload")
end

-- 10. diagnostics
do
    local Diag = require("diag")
    local rec = Diag.Recorder.new()
    local function sample(t, pitch)
        return { t = t, state = 100, shot = "chase", skater = vc(0, 1, t * 6), velocity = vc(0, 0, 6), board = vc(0, 0, t * 6), board_target = vc(0, 0, 0),
            look = vc(0, 0, 0), orbit_anchor = vc(0, 0, 0), skater_anchor = vc(0, 0, 0), camera = vc(0, 1.4, t * 6 - 1.5), camera_free = vc(0, 0, 0),
            carried = vc(0, 0, 0), yaw = 0, pitch = pitch, fov = 60, pull = 0, board_v = -60, root_v = 20, floor_w = 0 }
    end
    local lines = 0
    for i = 0, 179 do
        local p = -5
        if i >= 100 and i < 104 then p = -5 - 3 * (i - 99) elseif i >= 104 then p = -17 end
        lines += #rec:push(sample(i / 60, p))
    end
    expect(lines == 1 + Diag.pre_frames + Diag.post_frames, "a pitch snap dumps the half second around it")
    local calm = Diag.Recorder.new()
    local n = 0
    for i = 0, 599 do n += #calm:push(sample(i / 60, -5)) end
    expect(n == 0, "calm riding dumps nothing")
    local m, app = setup()
    m.command("dyncam_log 1")
    ride(m, 1.0)
    expect(m.camera_held_by == "me", "running with logging on")
    ride(m, 4.0)
    expect(m.files["diag/camera_log.txt"] ~= nil, "the running log is written to a file")
    expect(app.errors == 0, "no errors with logging on")
end

-- ================================================================ the off-board camera (Dynamic) on foot
-- A skater on foot walking along +Z at `speed`: joints for hips (7), spine2 (44) and head (103), the physics step, and `each(i)`.
local function foot(m, ragdoll)
    m.state.telemetry.physics_state = 504
    m.state.telemetry.watch = { ragdoll_known = true, ragdoll = ragdoll == true }
end
local function walk(m, seconds, opts)
    opts = opts or {}
    local z0 = m.state.skater.position.z
    local speed = opts.speed or 2
    m.run(seconds, 60, function(i)
        local s = m.state.skater
        local z = z0 + speed * i / 60
        s.position = vc(0, 0.95, z)
        s.heading = opts.heading or 0
        m.state.joints[7] = vc(0, 0.95, z)
        m.state.joints[44] = vc(0, 1.4, z)
        m.state.joints[103] = vc(0, 1.75, z)
        if opts.each then opts.each(i) end
        m.fire("physics_step", { seconds = 1 / 60, ragdoll = opts.ragdoll or false, velocity = { 0, 0, speed } })
    end)
end
-- Largest step between two consecutive views shown since call number `since`, and how many times the camera was released.
local function audit(m, since)
    local worst, releases, sets, last = 0, 0, 0, nil
    for i = since + 1, #m.calls do
        local c = m.calls[i]
        if c.fn == "set" then
            sets += 1
            if last then worst = math.max(worst, vector.magnitude(c.position - last)) end
            last = c.position
        elseif c.fn == "release" then
            releases += 1
        end
    end
    return worst, releases, sets
end

-- 11. dismount, remount, hippy landing: the view changes hands without a jump and without a release
do
    local m, app = setup()
    local g = app.glue
    expect(app.store.options.offboard_mode == "dynamic", "the default is the Dynamic off-board camera")
    ride(m, 1.0)
    expect(g.source == "ride", "riding: the riding camera draws")
    local mark = #m.calls
    foot(m)
    walk(m, 1.5)
    local worst, releases, sets = audit(m, mark)
    expect(m.camera_held_by == "me" and releases == 0, "dismount: no camera.release (" .. releases .. ")")
    expect(g.source == "foot", "dismount: the off-board camera draws")
    expect(worst < 0.25, "dismount: no pose step over 0.25 m (" .. string.format("%.3f", worst) .. ")")
    expect(sets >= 85, "dismount: a view every tick (" .. sets .. ")")
    expect(app.glue:status() == "Enabled", "status while on foot")
    expect(m.joint_calls > 0 and app.errors == 0, "the joints are read, no handler errors")
    local c = m.last_call("set")
    expect(c.fov >= 10 and c.fov <= 150, "a foot view carries a plausible fov")
    expect(vector.dot(vector.normalize(c.forward), vc(0, 0, 1)) > 0.8, "and looks the way he walks")

    mark = #m.calls
    m.state.telemetry.physics_state = 100
    ride(m, 1.5)
    worst, releases = audit(m, mark)
    expect(g.source == "ride" and m.camera_held_by == "me" and releases == 0, "remount: back to the riding camera, no release")
    expect(worst < 0.25, "remount: no pose step over 0.25 m (" .. string.format("%.3f", worst) .. ")")
    expect(app.errors == 0, "no errors")
end

do
    -- a hippy jump keeps the riding air camera, then hands over at the landing on foot
    local m, app = setup()
    local g = app.glue
    ride(m, 0.8)
    local mark = #m.calls
    foot(m)
    local during, switched
    m.run(1.6, 60, function(i)
        local t = i / 60
        local y = math.max(0.95, 0.95 + 4.1 * t - 5 * t * t)
        local vy = t < 0.82 and 4.1 - 10 * t or 0
        m.state.skater.position = vc(0, y, 2.4 + i * 0.03)
        m.state.joints[7] = m.state.skater.position
        m.state.joints[44] = m.state.skater.position + vc(0, 0.45, 0)
        m.state.joints[103] = m.state.skater.position + vc(0, 0.8, 0)
        m.fire("physics_step", { seconds = 1 / 60, ragdoll = false, velocity = { 0, vy, 1.8 } })
        if t < 0.6 then during = g.source end
        if g.source == "foot" and not switched then switched = #m.calls end
    end)
    local _, releases = audit(m, mark)
    local worst = audit(m, math.max(mark, (switched or #m.calls) - 3)) -- the hand-over and what follows (the riding camera in the air moves as it likes)
    expect(during == "ride" and g.hippy == false and g.source == "foot", "hippy jump: the riding camera in the air, the off-board one after landing")
    expect(releases == 0 and m.camera_held_by == "me", "hippy landing: no release")
    expect(worst < 0.25, "hippy landing: no pose step over 0.25 m (" .. string.format("%.3f", worst) .. ")")
end

-- the game's camera on foot: today's eased hand-back, and the switches that bring it
do
    local m, app = setup("game")
    ride(m, 0.8)
    local mark = #m.calls
    foot(m)
    walk(m, 0.3)
    expect(m.camera_held_by == "me", "game mode: still easing 0.3 s after stepping off")
    walk(m, 0.6)
    local _, releases = audit(m, mark)
    expect(m.camera_held_by == nil and releases == 1, "game mode: eased, then released once (" .. releases .. ")")

    local m2, app2 = setup()
    ride(m2, 0.8)
    foot(m2)
    walk(m2, 1.0)
    expect(m2.camera_held_by == "me" and app2.glue.source == "foot", "dynamic: on foot the camera is ours")
    local o = Settings.copy(app2.store.options)
    o.offboard_mode = "game"
    app2.store:set_options(o)
    walk(m2, 0.3)
    expect(m2.camera_held_by == "me", "choosing Game while on foot eases first")
    walk(m2, 0.8)
    expect(m2.camera_held_by == nil, "and then hands the camera back")

    local m3, app3 = setup()
    ride(m3, 0.8)
    foot(m3)
    walk(m3, 1.0)
    m3.command("dyncam 0")
    walk(m3, 0.2)
    expect(m3.camera_held_by == "me", "switching Dynamic Camera off on foot eases out (still ours after 0.2 s)")
    walk(m3, 0.8)
    expect(m3.camera_held_by == nil, "and then lets go")
    expect(app3.errors == 0, "no errors")
end

-- menu, pause, no skater: handed back at once even on foot
do
    local m, app = setup()
    ride(m, 0.6)
    foot(m)
    walk(m, 1.0)
    m.menu_open = true
    walk(m, 0.1)
    expect(m.camera_held_by == nil, "a game menu open on foot: released at once")
    m.menu_open = false
    local mark = #m.calls
    walk(m, 0.5)
    local c
    for i = mark + 1, #m.calls do if m.calls[i].fn == "set" then c = m.calls[i]; break end end
    expect(m.camera_held_by == "me" and c ~= nil, "menu closed on foot: taken again")
    expect(c ~= nil and vector.magnitude(c.position - m.state.game_camera.position) < 1.0, "the take on foot starts from the game's own camera")
    m.state.skater = nil
    m.run(0.2, 60)
    expect(m.camera_held_by == nil and app.errors == 0, "no skater on foot: released")
end

-- a bail off the board: the body is framed
do
    local m, app = setup()
    local g = app.glue
    ride(m, 0.6)
    foot(m, true)
    m.state.telemetry.body = vc(0, 0.4, 2.4)
    local mark = #m.calls
    m.run(2.5, 60, function(i)
        local a = i * 0.04
        local hips = vc(0.2 * math.sin(a), 0.4, 2.4)
        local head = hips + vc(1.3 * math.cos(a), 0.2, 1.3 * math.sin(a))
        m.state.telemetry.body = hips
        m.state.skater.position = hips + vc(0, 0.2, 0)
        m.state.joints[7], m.state.joints[44], m.state.joints[103] = hips, (hips + head) * 0.5, head
        m.fire("physics_step", { seconds = 1 / 60, ragdoll = true, velocity = { 0, 0, 0 } })
    end)
    local worst, releases = audit(m, mark)
    expect(g.source == "foot" and m.camera_held_by == "me" and releases == 0, "bail: the off-board camera frames it, no release")
    expect(worst < 0.25, "bail: no pose step over 0.25 m (" .. string.format("%.3f", worst) .. ")")
    local c = m.last_call("set")
    local half = c.fov * 0.5 * math.pi / 180
    for _, p in { m.state.joints[7], m.state.joints[103] } do
        local ang = math.acos(math.min(1, vector.dot(vector.normalize(p - c.position), vector.normalize(c.forward))))
        expect(ang <= 0.8 * half + 1e-3, "bail: hips and head inside 80% of the half FOV")
    end
    -- the board bail (state 300, still on the board) keeps the riding camera's wipeout shot
    local m2, app2 = setup()
    ride(m2, 0.6)
    m2.state.telemetry.physics_state = 300
    ride(m2, 0.5)
    expect(app2.glue.source == "ride" and m2.camera_held_by == "me", "a bail still on the board (state 300): the riding camera")
    -- Game mode: a bail off the board keeps the wipeout shot
    local m3, app3 = setup("game")
    ride(m3, 0.6)
    foot(m3, true)
    ride(m3, 0.5)
    expect(app3.glue.source == "ride" and m3.camera_held_by == "me", "Game mode: the ragdoll bail keeps the riding wipeout shot")
end

-- the sticks, R3, and the verbose line
do
    local m, app = setup()
    local g = app.glue
    ride(m, 0.6)
    foot(m)
    walk(m, 0.8)
    local before = vector.normalize(m.last_call("set").forward)
    m.pad = { right_x = 1, right_y = 0, left_x = 0, left_y = 0, buttons = {} }
    walk(m, 0.5)
    local after = vector.normalize(m.last_call("set").forward)
    expect(vector.dot(vector.normalize(vc(before.x, 0, before.z)), vector.normalize(vc(after.x, 0, after.z))) < 0.5, "the right stick turns the view on foot")
    local angle = app.store.settings.angle
    m.pad = { buttons = { right_stick = true } }
    walk(m, 0.05)
    m.pad = { buttons = { right_stick = false } }
    walk(m, 0.5)
    expect(app.store.settings.angle == angle, "R3 on foot does not switch Low / High")
    m.pad = nil
    walk(m, 1.0)
    expect(g.off.rays <= 3 and app.errors == 0, "at most 3 rays a tick from the off-board camera")
    m.command("dyncam_log 1")
    m.pad = { right_x = 0, right_y = 0, left_x = 0, left_y = 1, buttons = {} }
    walk(m, 6)
    local lines = table.concat(app.diag.log, "\n")
    expect(string.find(lines, "walking dir estimate", 1, true) ~= nil, "the once-a-second line carries the walking-direction estimate")
    expect(app.errors == 0, "no errors with logging on, on foot")
end

-- old stores and presets load with the defaults
do
    local m = mock.install({ limit_rays = true })
    add_missing_api(m)
    m.storage.settings = { ["S3Cam.FovOverride"] = 90, ["S3Cam.Options.TakeBlendTime"] = 0.3 }
    local app = require("app").start({ camera = camera })
    local o = app.store.options
    local d = require("offboard").defaults()
    expect(o.offboard_mode == "dynamic" and o.offboard.distance == d.distance and o.offboard.level == d.level and o.offboard.style == "orbit",
        "an old store loads with the off-board defaults")
    expect(o.take_blend_time == 0.3 and app.store.settings.fov_override_deg == 90, "and keeps what it had")

    local old = reskate.json.encode({ name = "Old", version = 1, values = { ["S3Cam.Follow.Strength"] = 2 } })
    local parsed = Presets.parse_preset(old)
    expect(parsed.options.offboard_mode == "dynamic" and parsed.options.offboard.bob == d.bob and parsed.report.refused == 0, "an old preset loads with the defaults")

    local st = app.store
    local ob = Settings.copy(st.options)
    ob.offboard_mode = "game"
    ob.offboard.distance = 4.5
    ob.offboard.style = "shoulder"
    ob.offboard.invert_y = true
    ob.offboard.fov = 80
    st:set_options(ob)
    local rt = Presets.parse_preset(Presets.preset_text("rt", st.settings, st.options))
    expect(rt.report.refused == 0 and rt.options.offboard_mode == "game" and rt.options.offboard.distance == 4.5 and rt.options.offboard.style == "shoulder"
        and rt.options.offboard.invert_y == true and rt.options.offboard.fov == 80, "the off-board options round-trip through a preset")
    local doc = reskate.json.decode(Presets.preset_text("rt", st.settings, st.options))
    expect(doc.values["S3Cam.OffBoard.Distance"] == 4.5 and doc.values["S3Cam.OffBoard.Mode"] == "game" and doc.version == 1, "saved under S3Cam.OffBoard.* keys, same format")
    local bad = Presets.parse_preset(reskate.json.encode({ name = "Bad", version = 1, values = { ["S3Cam.OffBoard.Distance"] = 50,
        ["S3Cam.OffBoard.Mode"] = "sideways", ["S3Cam.OffBoard.Level"] = "x" } }))
    expect(bad.report.refused == 3 and bad.options.offboard.distance == d.distance and bad.options.offboard_mode == "dynamic", "out-of-range and wrong-type values are refused, defaults kept")
    local keep = m.storage
    local m2 = mock.install({ limit_rays = true })
    add_missing_api(m2)
    m2.storage = keep
    local app2 = require("app").start({ camera = camera })
    expect(app2.store.options.offboard_mode == "game" and app2.store.options.offboard.distance == 4.5, "the options come back after a restart")
end

-- the menu tab
do
    local m, app = setup()
    local st = app.store
    m.build_page({ tabs = 7 })
    local ids = { "ob_mode", "ob_style", "ob_dist", "ob_height", "ob_look", "ob_offset", "ob_fov", "ob_follow", "ob_turn", "ob_stick", "ob_invert",
        "ob_recentre", "ob_match", "ob_level", "ob_bob", "ob_bail", "ob_trans" }
    for _, id in ipairs(ids) do expect(m.find_widget(id) ~= nil, "OFF THE BOARD has " .. id) end
    expect(#m.widgets <= 160, "OFF THE BOARD: " .. #m.widgets .. " widgets")
    m.build_page({ tabs = 7, ob_dist = 4.2, ob_recentre = 0 })
    expect(st.options.offboard.distance == 4.2 and st.options.offboard.recentre_after == 0, "sliders apply at once")
    expect(m.storage.settings["S3Cam.OffBoard.Distance"] == 4.2, "and are saved")
    m.build_page({ tabs = 7, ob_style = 2 })
    local ob = st.options.offboard
    expect(ob.style == "shoulder" and ob.distance == 1.6 and ob.offset == 0.55 and ob.fov > 0 and ob.recentre_after == 0, "Shoulder fills the sliders")
    m.build_page({ tabs = 7, ob_offset = 0.9 })
    expect(st.options.offboard.offset == 0.9 and st.options.offboard.style == "shoulder", "and they stay editable")
    m.build_page({ tabs = 7, ob_style = 1 })
    expect(st.options.offboard.distance == 2.8, "Orbit puts them back")
    m.build_page({ tabs = 7, ob_mode = 2 })
    expect(st.options.offboard_mode == "game", "the mode dropdown")
    m.build_page({ tabs = 7, ob_invert = true, ob_match = false })
    expect(st.options.offboard.invert_y and not st.options.offboard.match_walking, "toggles")
    local rev = st.revision
    m.build_page({ tabs = 7 })
    m.build_page({ tabs = 7 })
    expect(st.revision == rev, "building the tab changes nothing by itself")
    m.build_page({ tabs = 8, reset_all = true })
    expect(st.options.offboard_mode == "dynamic" and st.options.offboard.distance == 2.8 and not st.options.offboard.invert_y, "Reset all brings the off-board options back")
end

-- the shoulder side bind flips the off-board shoulder
do
    local m, app = setup()
    ride(m, 0.5)
    local o = Settings.copy(app.store.options)
    require("offboard").apply_style(o.offboard, "shoulder", 60)
    app.store:set_options(o)
    foot(m)
    walk(m, 3.0)
    local c = m.last_call("set")
    local right = vc(-1, 0, 0)
    local lateral1 = vector.dot(c.position - vc(0, 0, m.state.skater.position.z), right)
    m.fire("action", "switch shoulder side")
    m.fire("action", "switch shoulder side")
    walk(m, 3.0)
    local c2 = m.last_call("set")
    local lateral2 = vector.dot(c2.position - vc(0, 0, m.state.skater.position.z), right)
    expect(lateral1 * lateral2 < 0 and math.abs(lateral1) > 0.3 and math.abs(lateral2) > 0.3,
        "the shoulder-side bind flips the side the camera sits on (" .. string.format("%.2f, %.2f", lateral1, lateral2) .. ")")
end

T.done()
if T.failures > 0 then error("glue tests failed") end
