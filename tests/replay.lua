-- Replay harness: feeds a golden trace (tools/trace, recorded from the C++ camera) to a Luau camera module and compares.
--
--   local replay = require("replay")
--   local result = replay.run("trace_flat_slow", require("camera"))      -- prints one line, returns the result table
--
-- The camera module follows PORT_PLAN.md: Camera.new(), cam:set_settings(s), cam:update(dt, snapshot, query, extras).
-- The world is answered from the recording: the n-th query of a frame must match the n-th recorded ray (from / to within
-- 1e-3 m), otherwise the port diverged from the C++ and the scenario fails at that frame and ray (the run then stops: later
-- frames would only repeat it). The format is in tools/trace/FORMAT.md.
local replay = {}

-- Tolerances (PORT_PLAN.md).
replay.tolerance = {
    position = 0.005, -- m
    angle = 0.1,      -- degrees, between the recorded and the produced right / up / back
    fov = 0.05,       -- degrees
    ray = 1e-3,       -- m, a ray's from / to
}

-- Debug fields compared as well (FrameDebug). They explain a failure and are checked with their own tolerance; a mismatch
-- fails the scenario only when opts.strict_debug is set, otherwise it is counted and reported as a note.
local debug_numbers = {
    { "distance", 0.005 }, { "elevation", 0.0018 }, { "heading", 0.0018 }, { "collision_pull", 0.005 },
    { "keep_weight", 0.01 }, { "chase_blend", 0.01 }, { "shot_fraction", 0.01 }, { "fov_base", 0.05 }, { "fov_extra", 0.05 },
    { "shoulder", 0.005 }, { "follow_strength", 0.01 }, { "trick_yaw", 0.0018 }, { "view_heading", 0.0018 },
    { "ramp_side", 0.0018 }, { "focus_weight", 0.01 }, { "board_weight", 0.01 }, { "floor_weight", 0.01 },
    { "height_offset", 0.0018 }, { "follow_weight", 0.01 }, { "speed", 0.05 },
}
local debug_vectors = { { "orbit_anchor", 0.005 }, { "skater_anchor", 0.005 }, { "look_target", 0.005 } }
local debug_angles = { heading = true, view_heading = true, trick_yaw = true, ramp_side = true }

local vec = vector.create

-- ---------------------------------------------------------------- parsing

local function vec_of(fields, name)
    return vec(fields[name .. "_x"], fields[name .. "_y"], fields[name .. "_z"])
end

local function parse_fields(line, from)
    local fields = {}
    for key, value in string.gmatch(line:sub(from), "([%w_]+)=(%S+)") do
        fields[key] = tonumber(value) or value
    end
    return fields
end

-- Settings overrides: "set <dotted.path> <value>" lines become a nested table; numbers, true / false and enum names (strings).
local function set_path(root, path, value)
    local node = root
    local parts = {}
    for part in string.gmatch(path, "[^.]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
        local child = node[parts[i]]
        if child == nil then
            child = {}
            node[parts[i]] = child
        end
        node = child
    end
    node[parts[#parts]] = value
end

local function parse_value(token)
    if token == "true" then return true end
    if token == "false" then return false end
    return tonumber(token) or token
end

function replay.parse(text)
    local trace = { overrides = {}, frames = {}, override_list = {} }
    local frame
    for line in string.gmatch(text, "[^\n]+") do
        local tag = line:sub(1, 1)
        if tag == "F" then
            local index = tonumber(line:match("^F (%d+)"))
            local f = parse_fields(line, 3 + #tostring(index))
            frame = {
                index = index,
                dt = f.dt,
                base_fov = f.base_fov,
                snapshot = {
                    time = f.t,
                    position = vec_of(f, "position"),
                    forward = vec_of(f, "forward"),
                    velocity = vec_of(f, "velocity"),
                    physics_state = f.physics_state,
                    onboard = f.onboard == 1,
                    bailing = f.bailing == 1,
                    manual = f.manual == 1,
                    grind_side = f.grind_side,
                    switch_stance = f.switch_stance == 1,
                    board_position = vec_of(f, "board_position"),
                    board_valid = f.board_valid == 1,
                    ground_normal = vec_of(f, "ground_normal"),
                    ground_clearance = f.ground_clearance,
                    valid = f.valid == 1,
                },
                rays = {},
            }
            trace.frames[#trace.frames + 1] = frame
        elseif tag == "R" then
            local f = parse_fields(line, 2)
            local ray = { from = vec_of(f, "from"), to = vec_of(f, "to"), hit = f.hit == 1 }
            if ray.hit then
                ray.point = vec_of(f, "point")
                ray.normal = vec_of(f, "normal")
            end
            frame.rays[#frame.rays + 1] = ray
        elseif tag == "O" then
            local f = parse_fields(line, 2)
            local out = {
                valid = f.valid == 1,
                pos = vec_of(f, "pos"),
                right = vec_of(f, "right"),
                up = vec_of(f, "up"),
                back = vec_of(f, "back"),
                fov_deg = f.fov_deg,
                shot = f.shot,
                fields = f,
            }
            for _, entry in ipairs(debug_vectors) do out.fields[entry[1]] = vec_of(f, entry[1]) end
            frame.output = out
        elseif line:sub(1, 4) == "set " then
            local path, token = line:match("^set (%S+) (%S+)")
            local value = parse_value(token)
            set_path(trace.overrides, path, value)
            trace.override_list[#trace.override_list + 1] = { path, value }
        elseif line:sub(1, 9) == "scenario " then
            trace.name = line:sub(10)
        elseif line:sub(1, 5) == "note " then
            trace.note = line:sub(6)
        elseif line:sub(1, 4) == "fps " then
            trace.fps = tonumber(line:sub(5))
        end
    end
    return trace
end

-- Loads a trace by module name ("trace_flat_slow", found in tools/trace/out through -I), or accepts a parsed one.
function replay.load(scenario)
    if type(scenario) == "table" then return scenario end
    local text = require(scenario)
    return replay.parse(text)
end

-- ---------------------------------------------------------------- settings

-- The settings table for a trace: the port's defaults (settings.lua: defaults() or new(), when that module exists) with the
-- trace's overrides laid over, field by field. Without a settings module the table holds the overrides only.
local function merge(into, from)
    for key, value in pairs(from) do
        if type(value) == "table" and type(into[key]) == "table" then
            merge(into[key], value)
        else
            into[key] = value
        end
    end
    return into
end

function replay.build_settings(trace, opts)
    local base = {}
    local ok, settings_module = pcall(require, "settings")
    if ok and type(settings_module) == "table" then
        local make = settings_module.defaults or settings_module.new
        if make then base = make() end
    end
    if opts and opts.settings_hook then opts.settings_hook(base, trace) end
    local merged = merge(base, trace.overrides)
    -- Enum overrides arrive as C++ enumerator names; settings.lua uses integers.
    local ok2, S = pcall(require, "settings")
    if ok2 then
        local function map(node, key, names)
            if node and type(node[key]) == "string" then node[key] = names[node[key]] or node[key] end
        end
        map(merged, "preset", S.CameraPreset)
        map(merged, "angle", S.CameraAngle)
        map(merged.shoulder, "mode", S.ShoulderSide)
        map(merged.ride_distance, "mode", S.DistanceMode)
        map(merged.ride_distance_high, "mode", S.DistanceMode)
        map(merged.framing, "manual_mode", S.ManualDistanceMode)
        map(merged.framing_high, "manual_mode", S.ManualDistanceMode)
    end
    return merged
end

-- ---------------------------------------------------------------- comparison

local function angle_between(a, b)
    local d = vector.dot(a, b) / math.max(vector.magnitude(a) * vector.magnitude(b), 1e-12)
    return math.deg(math.acos(math.clamp(d, -1, 1)))
end

local function wrap(a)
    return (a + math.pi) % (2 * math.pi) - math.pi
end

local function finite(v)
    return v == v and v ~= math.huge and v ~= -math.huge
end
local function finite_vec(v)
    return typeof(v) == "vector" and finite(v.x) and finite(v.y) and finite(v.z)
end

-- Runs one trace. Returns { name, pass, frames, worst = {position, angle, fov}, first_fail = {frame, message}, notes }.
function replay.run(scenario, camera_module, opts)
    opts = opts or {}
    local trace = replay.load(scenario)
    local tol = replay.tolerance
    local result = {
        name = trace.name or tostring(scenario),
        note = trace.note,
        pass = true,
        frames = #trace.frames,
        worst = { position = 0, angle = 0, fov = 0 },
        debug_worst = 0,
        debug_count = 0,
    }

    local function fail(frame, message)
        if result.pass then
            result.pass = false
            result.first_fail = { frame = frame, message = message }
        end
    end

    if camera_module.bind_trace then camera_module.bind_trace(trace) end
    local cam = camera_module.new()
    local settings = replay.build_settings(trace, opts)
    local accepted = cam:set_settings(settings)
    if accepted == false then
        fail(0, "set_settings refused the settings of this trace")
        replay.report(result, opts)
        return result
    end

    -- The recording answers the camera's rays in order.
    local frame_rays, ray_count, ray_frame = nil, 0, 0
    local diverged = false
    local function query(from, to)
        ray_count += 1
        local ray = frame_rays[ray_count]
        if not ray then
            diverged = true
            fail(ray_frame, string.format("extra ray #%d: the port cast a ray the C++ did not (from %s to %s); the C++ cast %d rays this frame",
                ray_count, tostring(from), tostring(to), #frame_rays))
            return nil
        end
        local df, dt_ = vector.magnitude(from - ray.from), vector.magnitude(to - ray.to)
        if df > tol.ray or dt_ > tol.ray then
            diverged = true
            fail(ray_frame, string.format("ray #%d differs: from off by %.4f m, to off by %.4f m\n      port: %s -> %s\n      C++ : %s -> %s",
                ray_count, df, dt_, tostring(from), tostring(to), tostring(ray.from), tostring(ray.to)))
            return nil
        end
        if ray.hit then return ray.point, ray.normal end
        return nil
    end

    for i, frame in ipairs(trace.frames) do
        frame_rays, ray_count, ray_frame = frame.rays, 0, frame.index
        local extras = { base_fov_deg = frame.base_fov }
        local out = cam:update(frame.dt, frame.snapshot, query, extras)
        if diverged then break end
        if ray_count < #frame_rays then
            fail(frame.index, string.format("missing rays: the port cast %d rays, the C++ cast %d (ray #%d is the first it did not cast: %s -> %s)",
                ray_count, #frame_rays, ray_count + 1, tostring(frame_rays[ray_count + 1].from), tostring(frame_rays[ray_count + 1].to)))
            break
        end

        local want = frame.output
        local why
        if out == nil then
            why = "update returned nothing"
        elseif out.valid ~= want.valid then
            why = string.format("valid is %s, the C++ has %s", tostring(out.valid), tostring(want.valid))
        elseif want.valid then
            if not (finite_vec(out.pos) and finite_vec(out.right) and finite_vec(out.up) and finite_vec(out.back) and finite(out.fov_deg)) then
                why = "the frame holds a NaN or infinity"
            else
                local dp = vector.magnitude(out.pos - want.pos)
                local worst_angle, which = 0, ""
                for _, name in ipairs({ "right", "up", "back" }) do
                    local a = angle_between(out[name], want[name])
                    if a > worst_angle then worst_angle, which = a, name end
                end
                local df = math.abs(out.fov_deg - want.fov_deg)
                result.worst.position = math.max(result.worst.position, dp)
                result.worst.angle = math.max(result.worst.angle, worst_angle)
                result.worst.fov = math.max(result.worst.fov, df)
                if dp > tol.position then
                    why = string.format("position off by %.2f mm (tolerance %.0f mm)\n      port: %s\n      C++ : %s", dp * 1000, tol.position * 1000, tostring(out.pos), tostring(want.pos))
                elseif worst_angle > tol.angle then
                    why = string.format("%s off by %.3f deg (tolerance %.1f)", which, worst_angle, tol.angle)
                elseif df > tol.fov then
                    why = string.format("fov %.3f vs %.3f deg (off by %.3f, tolerance %.2f)", out.fov_deg, want.fov_deg, df, tol.fov)
                end
            end
        end
        if why then
            fail(frame.index, why .. (want.shot and ("  [C++ shot " .. want.shot .. "]") or ""))
            if not opts.keep_going then break end
        end

        -- The debug fields: informative, fatal only in strict mode.
        local debug = out and out.debug
        if debug and want.valid then
            for _, entry in ipairs(debug_numbers) do
                local key, tolerance = entry[1], entry[2]
                local got, expect = debug[key], want.fields[key]
                if type(got) == "number" and expect then
                    local diff = debug_angles[key] and math.abs(wrap(got - expect)) or math.abs(got - expect)
                    if diff > tolerance then
                        result.debug_count += 1
                        if diff / tolerance > result.debug_worst then
                            result.debug_worst = diff / tolerance
                            result.debug_worst_field = string.format("%s at frame %d (port %.5f, C++ %.5f)", key, frame.index, got, expect)
                        end
                        if opts.strict_debug then fail(frame.index, string.format("debug.%s is %.5f, the C++ has %.5f", key, got, expect)) end
                    end
                end
            end
            for _, entry in ipairs(debug_vectors) do
                local key, tolerance = entry[1], entry[2]
                local got, expect = debug[key], want.fields[key]
                if typeof(got) == "vector" and expect then
                    local diff = vector.magnitude(got - expect)
                    if diff > tolerance then
                        result.debug_count += 1
                        if diff / tolerance > result.debug_worst then
                            result.debug_worst = diff / tolerance
                            result.debug_worst_field = string.format("%s at frame %d (off by %.4f m)", key, frame.index, diff)
                        end
                        if opts.strict_debug then fail(frame.index, string.format("debug.%s off by %.4f m", key, diff)) end
                    end
                end
            end
            if debug.shot_name and want.shot and debug.shot_name ~= want.shot then
                result.debug_count += 1
                result.debug_worst_field = result.debug_worst_field or string.format("shot_name at frame %d (port %s, C++ %s)", frame.index, tostring(debug.shot_name), want.shot)
                if opts.strict_debug then fail(frame.index, string.format("debug.shot_name is %s, the C++ has %s", tostring(debug.shot_name), want.shot)) end
            end
        end
        if not result.pass and not opts.keep_going then break end
    end

    replay.report(result, opts)
    return result
end

function replay.report(result, opts)
    if opts and opts.quiet then return end
    local w = result.worst
    local line = string.format("%s  %-26s %5d frames  worst: %.2f mm, %.3f deg, fov %.3f", result.pass and "PASS" or "FAIL", result.name, result.frames,
        w.position * 1000, w.angle, w.fov)
    if result.debug_count > 0 then
        line ..= string.format("  (debug diffs: %d, worst %s)", result.debug_count, result.debug_worst_field or "?")
    end
    print(line)
    if not result.pass then
        print(string.format("      first failure: frame %d: %s", result.first_fail.frame, result.first_fail.message))
    end
end

return replay
