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

local function setup()
    local m = mock.install({ limit_rays = true })
    add_missing_api(m)
    local app = require("app").start({ camera = camera })
    m.fire("load")
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
    local m, app = setup()
    ride(m, 0.5)
    expect(m.camera_held_by == "me", "riding: the camera is taken")
    local c = m.last_call("set")
    expect(c ~= nil and vector.dot(vector.normalize(c.forward), vc(0, 0, 1)) > (real and 0.8 or 0.999), "the view looks along the skater's +Z")
    expect(c.position.z < m.state.skater.position.z and c.position.y > 0, "camera behind the skater")
    expect(c.fov == nil or (c.fov >= 10 and c.fov <= 150), "fov in range")
    expect(app.glue:status() == "Enabled", "status says Enabled")
    m.state.telemetry.physics_state = 504
    ride(m, 0.3)
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
    local m = setup()
    ride(m, 0.4)
    m.state.telemetry.physics_state = 504
    m.state.telemetry.watch = { ragdoll_known = true, ragdoll = true }
    ride(m, 1.0)
    expect(m.camera_held_by == "me", "bail (ragdoll): the camera stays")
    m.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
    ride(m, 0.3)
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

    local m3 = setup()
    ride(m3, 0.4)
    m3.state.telemetry.physics_state = 504
    m3.state.telemetry.watch = { ragdoll_known = true, ragdoll = false }
    m3.run(0.4, 60, function(i) m3.state.skater.position = vc(0, 0.95, 2.4 + i * 0.01); m3.fire("physics_step", { seconds = 1 / 60, velocity = { 0, 0.5, 1 }, ragdoll = false }) end)
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
    for tab = 1, 7 do
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
    m.build_page({ tabs = 7, reset_all = true })
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
    expect(m.binds["Dynamic Camera on / off"] == false and m.binds["Switch shoulder side"] == false, "both binds registered, unbound by default")
    local was = app.store.enabled
    m.fire("action", "Dynamic Camera on / off")
    expect(app.store.enabled == not was, "bind toggles the camera")
    app.store.enabled = true
    m.fire("action", "Switch shoulder side")
    expect(app.store.settings.shoulder.side == 1 and app.store.settings.shoulder.mode == Settings.ShoulderSide.Manual, "bind: from Off the swap takes manual control, camera on the right")
    m.fire("action", "Switch shoulder side")
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

T.done()
if T.failures > 0 then error("glue tests failed") end
