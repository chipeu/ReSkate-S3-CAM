-- A small mock of the `reskate` table (plugin API 1) so the plugin's glue (main.lua and friends) loads and runs ticks offline.
-- It follows docs-ref\plugins_api_*.md and records what the plugin does so a test can look at it.
--
--   local mock = require("mock_reskate")
--   local m = mock.install()              -- sets the global `reskate`, returns the controller
--   dofile-style:  require("main")        -- the plugin registers its events, commands, binds and page
--   m.state.skater = {...}                -- what reskate.skater.get() returns (m.skater_default() builds one)
--   m.tick(16.7)                          -- fires `tick` with dt in ms (timers due first, as in the game)
--   m.fire("action", "swap_shoulder")     -- fires any event
--   m.build_page({ toggle_id = false })   -- builds the plugin's page; the table sets what the "player" changed
--   m.command("dyncam log 1")             -- types a console line
--
-- Everything the plugin did is in m.calls (camera), m.logs, m.console_lines, m.toasts, m.binds, m.pages, m.widgets.
local json = require("json")

local mock = {}

-- The events of docs-ref\plugins_events.md; reskate.on raises for any other name, as the game does.
local EVENTS = {
    "load", "unload", "tick", "level_loaded", "level_unloading", "trick_started", "trick_landed", "line_broken", "trick_notes",
    "skater_state", "bail", "board_landed", "body_hit", "bail_end", "launch", "physics_step", "draw", "player_joined", "player_left",
    "touch", "touch_end", "message", "chat", "poll_answer", "poll_closed", "throwdown", "throwdown_ui", "action", "camera_cycle",
    "screen_closed", "track_changed",
}

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deep_copy(x) end
    return out
end

local function freeze_check(v, depth)
    -- storage / json values: nil, booleans, finite numbers, strings, tables of those (no vectors, functions)
    local t = type(v)
    if t == "number" then
        assert(v == v and v ~= math.huge and v ~= -math.huge, "storage: NaN or infinity cannot be stored")
    elseif t == "table" then
        assert(depth < 32, "storage: nested deeper than 32")
        for _, x in pairs(v) do freeze_check(x, depth + 1) end
    elseif t ~= "nil" and t ~= "boolean" and t ~= "string" then
        error("storage: a " .. typeof(v) .. " cannot be stored")
    end
end

-- A skater as reskate.skater.get() returns it, riding forward along +Z at 6 m/s.
function mock.skater_default()
    return {
        position = vector.create(0, 0.95, 0),
        heading = 0,
        speed = 6,
        vertical_speed = 0,
        airborne = false,
        air_time = 0,
        right = vector.create(-1, 0, 0),
        switch = false,
    }
end

function mock.telemetry_default()
    return {
        skater = true,
        airborne = false,
        position = vector.create(0, 0.95, 0),
        heading = 0, -- degrees
        speed = 6,
        vertical = 0,
        air_time = 0,
        height = 0,
        top_speed = 6,
        physics_state = 100,
        last = { serial = 0, takeoff_speed = 0, takeoff_angle = 0, air_time = 0, height = 0 },
        watch = {},
        teleport_pending = false,
        slam = false,
        struck = false,
    }
end

function mock.new(opts)
    opts = opts or {}
    local m = {
        handlers = {}, -- event -> list of functions
        logs = {},     -- { level, message }
        console_lines = {},
        commands = {}, -- name -> { help, fn, subcommands }
        binds = {},    -- action -> key
        toasts = {},
        calls = {},    -- camera calls in order: { fn = "look"|"set"|"release"|"cycle", ... }
        storage = {},
        files = {},    -- path -> text
        pages = {},    -- title -> build function (reskate.menu.page and panel)
        page_title = nil,
        widgets = {},  -- widgets of the last build_page
        timers = {},
        clock_ms = opts.start_ms or 1000,
        next_timer = 1,
        ticks = 0,
        camera_held_by = nil, -- nil | "me" | other plugin's name
        camera_view = nil,
        state = {
            skater = mock.skater_default(),
            telemetry = mock.telemetry_default(),
            board = { velocity = vector.create(0, 0, 6), spin = vector.create(0, 0, 0), place = { position = vector.create(0, 0.05, 0), rotation = { x = 0, y = 0, z = 0, w = 1 } } },
            goofy = false,
            level = { name = "TestLevel" },
            ground_y = 0,        -- the default raycast: a flat plane at this height
            raycast = nil,       -- or a function(from, to) -> hit | nil
            raycasts = 0,
            game_camera = { position = vector.create(0, 2, -4), forward = vector.create(0, 0, 1), right = vector.create(-1, 0, 0), up = vector.create(0, 1, 0), fov = 60, free = false },
            camera_refuses = nil, -- set to a reason string and look / set return false, reason
        },
    }

    local function log(level, message)
        m.logs[#m.logs + 1] = { level, tostring(message) }
        if opts.echo then print("[log:" .. level .. "] " .. tostring(message)) end
    end

    local r = {}
    r.id = opts.id or "Dynamic_Camera"
    r.side = "client"
    r.api_version = 1
    r.Enums = { Side = { client = "client", server = "server", both = "both" }, Event = {} }
    for _, name in ipairs(EVENTS) do r.Enums.Event[name] = name end

    r.level = { current = function() return m.state.level end }

    function r.log(message, level)
        level = level or "info"
        assert(level == "info" or level == "warn" or level == "error", "reskate.log: level must be info, warn or error")
        log(level, message)
    end

    local known = {}
    for _, name in ipairs(EVENTS) do known[name] = true end
    function r.on(event, handler)
        assert(type(event) == "string" and known[event], "reskate.on: there is no event " .. tostring(event))
        assert(type(handler) == "function", "reskate.on: the handler must be a function")
        local list = m.handlers[event]
        if not list then
            list = {}
            m.handlers[event] = list
        end
        assert(#list < 256, "reskate.on: more than 256 handlers")
        list[#list + 1] = handler
    end

    -- time
    r.time = {}
    function r.time.now() return m.clock_ms end
    function r.time.after(ms, fn)
        local id = m.next_timer
        m.next_timer += 1
        m.timers[id] = { due = m.clock_ms + ms, fn = fn }
        return id
    end
    function r.time.every(ms, fn)
        local id = m.next_timer
        m.next_timer += 1
        m.timers[id] = { due = m.clock_ms + ms, fn = fn, every = ms }
        return id
    end
    function r.time.cancel(id) m.timers[id] = nil end
    function r.time.speed() return 1 end
    function r.time.slow() return true end

    -- skater / board
    r.skater = {}
    function r.skater.get() return m.state.skater end
    function r.skater.position() return m.state.skater and m.state.skater.position end
    function r.skater.heading() return m.state.skater and m.state.skater.heading end
    function r.skater.speed() return m.state.skater and m.state.skater.speed end
    function r.skater.on_ground() return m.state.skater ~= nil and not m.state.skater.airborne end
    function r.skater.state() return m.state.telemetry and m.state.telemetry.physics_state end
    function r.skater.telemetry() return m.state.telemetry end
    function r.skater.goofy() return m.state.goofy end
    r.board = {}
    function r.board.motion() return m.state.board end

    -- world: the plane at ground_y unless the test sets a raycast function. Counts calls (the game allows 64 a tick).
    r.world = {}
    function r.world.raycast(from, to)
        assert(vector.magnitude(to - from) <= 1000, "reskate.world.raycast: the ray is longer than 1000 m")
        m.state.raycasts += 1
        assert(m.state.raycasts <= 64 or not opts.limit_rays, "reskate.world.raycast: more than 64 raycasts in one tick")
        if m.state.raycast then return m.state.raycast(from, to) end
        local y = m.state.ground_y
        if from.y >= y and to.y < y then
            local t = (from.y - y) / (from.y - to.y)
            return from + (to - from) * t
        end
        return nil
    end

    -- camera
    r.camera = {}
    local function take(fn, ...)
        local why = m.state.camera_refuses
        if why then return false, why end
        if m.camera_held_by and m.camera_held_by ~= "me" then return false, m.camera_held_by .. " has the camera" end
        m.camera_held_by = "me"
        return true
    end
    -- The view a look / set shows: facing +Z the view's right is -X (right = forward x up).
    local function view_of(position, forward, up, fov)
        local f = vector.normalize(forward)
        local u = up - f * vector.dot(up, f)
        if vector.magnitude(u) < 1e-6 then u = vector.create(0, 0, 1) end
        u = vector.normalize(u)
        return { position = position, forward = f, right = vector.cross(f, u), up = u, fov = (fov and fov > 0) and fov or 60, free = false }
    end
    function r.camera.look(position, target, fov)
        assert(typeof(position) == "vector" and typeof(target) == "vector", "reskate.camera.look: position and target must be vectors")
        assert(vector.magnitude(target - position) > 0, "reskate.camera.look: the target is the position")
        m.calls[#m.calls + 1] = { fn = "look", position = position, target = target, fov = fov }
        local ok, why = take()
        if ok then m.camera_view = view_of(position, target - position, vector.create(0, 1, 0), fov) end
        return ok, why
    end
    function r.camera.set(position, forward, up, fov)
        assert(typeof(position) == "vector" and typeof(forward) == "vector" and typeof(up) == "vector", "reskate.camera.set: vectors expected")
        assert(vector.magnitude(forward) > 0, "reskate.camera.set: forward has no length")
        assert(fov == nil or fov == 0 or (fov >= 10 and fov <= 150), "reskate.camera.set: fov must be 10 to 150")
        m.calls[#m.calls + 1] = { fn = "set", position = position, forward = forward, up = up, fov = fov }
        local ok, why = take()
        if ok then m.camera_view = view_of(position, forward, up, fov) end
        return ok, why
    end
    function r.camera.release()
        m.calls[#m.calls + 1] = { fn = "release" }
        if m.camera_held_by == "me" then
            m.camera_held_by = nil
            m.camera_view = nil
        end
    end
    function r.camera.held()
        if m.camera_held_by ~= "me" then return false, "it does not hold the camera" end
        if m.state.spectating then return false, "Spectate has the camera" end
        return true
    end
    function r.camera.get() return m.camera_view or m.state.game_camera end
    function r.camera.cycle(state)
        m.calls[#m.calls + 1] = { fn = "cycle", state = state }
        return true
    end

    -- storage (json values, a copy each way)
    r.storage = {}
    function r.storage.get(key)
        assert(type(key) == "string" and #key >= 1 and #key <= 128, "reskate.storage.get: the key is 1 to 128 characters")
        return deep_copy(m.storage[key])
    end
    function r.storage.set(key, value)
        assert(type(key) == "string" and #key >= 1 and #key <= 128, "reskate.storage.set: the key is 1 to 128 characters")
        freeze_check(value, 1)
        m.storage[key] = deep_copy(value)
    end
    function r.storage.add(key, by)
        local value = (m.storage[key] or 0) + (by or 1)
        m.storage[key] = value
        return value
    end
    function r.storage.keys()
        local keys = {}
        for k in pairs(m.storage) do keys[#keys + 1] = k end
        table.sort(keys)
        return keys
    end

    -- files (the plugin's data folder, in memory)
    r.files = {}
    function r.files.read(path)
        local text = m.files[path]
        if text == nil then return nil, "not found" end
        return text
    end
    function r.files.write(path, text)
        assert(type(path) == "string" and type(text) == "string", "reskate.files.write: path and text must be strings")
        if #text > 1048576 then return false, "a file is at most 1 MB" end
        m.files[path] = text
        return true
    end
    function r.files.list(folder)
        folder = folder or ""
        if folder ~= "" and folder:sub(-1) ~= "/" then folder ..= "/" end
        local seen, names = {}, {}
        for path in pairs(m.files) do
            if path:sub(1, #folder) == folder then
                local rest = path:sub(#folder + 1)
                local first, slash = rest:match("^([^/]+)(/?)")
                local name = first .. slash
                if not seen[name] then
                    seen[name] = true
                    names[#names + 1] = name
                end
            end
        end
        table.sort(names)
        return names
    end
    function r.files.remove(path)
        if m.files[path] == nil then return false, "not found" end
        m.files[path] = nil
        return true
    end

    -- the plugin's own package files (read-only): the test can fill m.package
    m.package = {}
    r.package = {}
    function r.package.read(path)
        if m.package[path] == nil then return nil, "not found" end
        return m.package[path]
    end
    function r.package.read_json(path)
        local text = m.package[path]
        if text == nil then return nil, "not found" end
        return json.decode(text)
    end

    -- console
    r.console = {}
    function r.console.print(text)
        m.console_lines[#m.console_lines + 1] = tostring(text)
        if opts.echo then print("[console] " .. tostring(text)) end
    end
    function r.console.command(name, help, fn, subcommands)
        assert(type(name) == "string" and name:match("^[a-z0-9_%-]+[a-z0-9_ %-]*$"), "reskate.console.command: bad name " .. tostring(name))
        assert(type(help) == "string" and type(fn) == "function", "reskate.console.command: help and fn expected")
        m.commands[name] = { help = help, fn = fn, subcommands = subcommands }
    end

    -- json
    r.json = { encode = json.encode, decode = json.decode }

    -- input
    r.input = {}
    function r.input.bind(action, key)
        assert(type(action) == "string" and #action >= 1 and #action <= 48, "reskate.input.bind: the action is 1 to 48 characters")
        local count = 0
        for _ in pairs(m.binds) do count += 1 end
        assert(count < 16 or m.binds[action] ~= nil, "reskate.input.bind: a plugin has at most 16 actions")
        m.binds[action] = key or false
        return true
    end

    -- overlay
    r.ui = {}
    function r.ui.toast(message, level)
        m.toasts[#m.toasts + 1] = { tostring(message), level or "info" }
        return true
    end

    -- menu: page / panel record their build function; build_page runs them with a recording ui
    r.menu = {}
    function r.menu.page(title, build)
        assert(type(title) == "string" and #title >= 1 and #title <= 24, "reskate.menu.page: the title is 1 to 24 characters")
        assert(m.page_title == nil, "reskate.menu.page: a plugin has one page")
        assert(type(build) == "function", "reskate.menu.page: build must be a function")
        m.page_title = title
        m.pages[title] = build
    end
    function r.menu.panel(title, build)
        assert(type(title) == "string" and #title >= 1 and #title <= 40, "reskate.menu.panel: the title is 1 to 40 characters")
        assert(m.pages[title] == nil, "reskate.menu.panel: that title is used already")
        m.pages[title] = build
        m.panels = m.panels or {}
        m.panels[#m.panels + 1] = title
    end

    m.reskate = r
    return m
end

-- The recording ui. `changes` maps a widget id to what the player set since the last build (a button id to true).
local function make_ui(m, changes)
    local ui = { widgets = m.widgets }
    local ids = {}
    local function note(kind, id, fields)
        if id ~= nil then
            assert(type(id) == "string" and #id >= 1 and #id <= 32, kind .. ": the id is 1 to 32 characters (" .. tostring(id) .. ")")
            assert(not ids[id], kind .. ": the id " .. id .. " is used twice in one build")
            ids[id] = true
        end
        fields.kind, fields.id = kind, id
        m.widgets[#m.widgets + 1] = fields
        assert(#m.widgets <= 160, "a page holds at most 160 widgets in one build")
        return fields
    end
    local function changed(id, default)
        local v = changes[id]
        if v == nil then return default end
        return v
    end
    function ui.card(self, title, subtitle) note("card", nil, { text = title, subtitle = subtitle }) end
    function ui.tabs(self, id, names, chosen)
        assert(#names >= 1 and #names <= 8, "tabs: 1 to 8 names")
        local w = note("tabs", id, { names = names, value = chosen or 1 })
        local picked = changed(id, chosen or 1)
        w.result = math.clamp(picked, 1, #names)
        return w.result
    end
    function ui.heading(self, text) note("heading", nil, { text = text }) end
    function ui.label(self, text) note("label", nil, { text = text }) end
    function ui.note(self, text) note("note", nil, { text = text }) end
    function ui.warn(self, text) note("warn", nil, { text = text }) end
    function ui.info(self, label, value) note("info", nil, { text = label, value = value }) end
    function ui.separator(self) note("separator", nil, {}) end
    function ui.button(self, id, text, primary)
        local w = note("button", id, { text = text, primary = primary })
        w.result = changed(id, false) == true
        return w.result
    end
    function ui.toggle(self, id, text, on, help)
        local w = note("toggle", id, { text = text, value = on or false, help = help })
        w.result = changed(id, on or false)
        return w.result
    end
    function ui.slider(self, id, text, value, minimum, maximum, format)
        assert(maximum > minimum, "slider: the maximum must be above the minimum")
        local w = note("slider", id, { text = text, value = value, min = minimum, max = maximum, format = format })
        w.result = math.clamp(changed(id, value), minimum, maximum)
        return w.result
    end
    function ui.dropdown(self, id, text, choices, chosen, help)
        assert(#choices >= 1 and #choices <= 32, "dropdown: 1 to 32 choices")
        local w = note("dropdown", id, { text = text, choices = choices, value = chosen or 1, help = help })
        w.result = math.clamp(changed(id, chosen or 1), 1, #choices)
        return w.result
    end
    function ui.bar(self, text, value, minimum, maximum) note("bar", nil, { text = text, value = value, min = minimum, max = maximum }) end
    return ui
end

-- Builds the plugin's page (and panels), as the menu does. Returns the widget list (also in m.widgets).
function mock.build_page(m, changes)
    m.widgets = {}
    local titles = { m.page_title }
    for _, panel in ipairs(m.panels or {}) do titles[#titles + 1] = panel end
    for _, title in ipairs(titles) do
        local build = m.pages[title]
        local ui = make_ui(m, changes or {})
        build(ui)
    end
    return m.widgets
end

function mock.find_widget(m, id)
    for _, w in ipairs(m.widgets) do
        if w.id == id then return w end
    end
    return nil
end

function mock.fire(m, event, ...)
    for _, handler in ipairs(m.handlers[event] or {}) do handler(...) end
end

-- One game tick: the timers that fell due first, then the `tick` handlers (dt in milliseconds, as the event passes it).
function mock.tick(m, dt_ms)
    dt_ms = dt_ms or 1000 / 60
    m.clock_ms += dt_ms
    m.ticks += 1
    m.state.raycasts = 0
    local due = {}
    for id, timer in pairs(m.timers) do
        if timer.due <= m.clock_ms then due[#due + 1] = id end
    end
    table.sort(due)
    for _, id in ipairs(due) do
        local timer = m.timers[id]
        if timer then
            if timer.every then
                timer.due += timer.every
            else
                m.timers[id] = nil
            end
            timer.fn()
        end
    end
    mock.fire(m, "tick", dt_ms)
end

-- Types a console line: the longest registered command name that starts it runs with the words after.
function mock.command(m, line)
    local words = {}
    for w in string.gmatch(line, "%S+") do words[#words + 1] = w end
    for n = math.min(3, #words), 1, -1 do
        local name = table.concat(words, " ", 1, n)
        local command = m.commands[name]
        if command then
            local args = {}
            for i = n + 1, #words do args[#args + 1] = words[i] end
            command.fn(args)
            return true
        end
    end
    return false
end

-- Installs the mock as the global `reskate` and returns a controller with the helpers bound to it.
function mock.install(opts)
    local m = mock.new(opts)
    reskate = m.reskate
    m.build_page = function(changes) return mock.build_page(m, changes) end
    m.find_widget = function(id) return mock.find_widget(m, id) end
    m.fire = function(event, ...) return mock.fire(m, event, ...) end
    m.tick = function(dt_ms) return mock.tick(m, dt_ms) end
    m.command = function(line) return mock.command(m, line) end
    -- a long run: n ticks at fps, calling `each(i)` before every tick (to move the skater)
    m.run = function(seconds, fps, each)
        local n = math.floor(seconds * fps + 0.5)
        for i = 1, n do
            if each then each(i) end
            mock.tick(m, 1000 / fps)
        end
    end
    m.last_call = function(fn)
        for i = #m.calls, 1, -1 do
            if m.calls[i].fn == fn then return m.calls[i] end
        end
        return nil
    end
    return m
end

return mock
