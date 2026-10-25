-- Runs every golden trace through the Luau camera and prints one PASS / FAIL line each.
--
--   luau_run.exe -I Dynamic_Camera\plugin -I tests -I tools\trace\out tests\run_parity.lua [options]
--
--   (no option)     every trace through require("camera")
--   self            the harness self-test: the fake camera (recorded outputs) must pass, and each perturbation must fail
--   only <text>     only the traces whose name contains <text>
--   strict          debug fields (distance, elevation, anchors, ...) fail the scenario too
--   all             keep going after a failed frame (worst errors over the whole trace)
--
-- The traces come from tools\trace\regen.ps1 (tools\trace\out\trace_*.lua, listed by trace_index.lua).
local replay = require("replay")

local self_test, only, strict, keep_going = false, nil, false, false
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        if a == "self" then self_test = true
        elseif a == "strict" then strict = true
        elseif a == "all" then keep_going = true
        elseif a == "only" then
            i += 1
            only = arg[i]
        else
            error("unknown option " .. a)
        end
        i += 1
    end
end

local ok, names = pcall(require, "trace_index")
if not ok then
    error("no traces: run tools\\trace\\regen.ps1 and pass -I tools\\trace\\out (" .. tostring(names) .. ")")
end

local function selected()
    local list = {}
    for _, name in ipairs(names) do
        if not only or name:find(only, 1, true) then list[#list + 1] = name end
    end
    return list
end

local function run_all(camera_module, opts)
    local passed, failed = 0, 0
    local failed_names = {}
    local started = os.clock()
    for _, name in ipairs(selected()) do
        local result = replay.run(name, camera_module, opts)
        if result.pass then
            passed += 1
        else
            failed += 1
            failed_names[#failed_names + 1] = result.name
        end
    end
    return passed, failed, failed_names, os.clock() - started
end

if self_test then
    local Fake = require("fake_camera")
    local failures = 0
    local function expect(label, passed, failed, want_failing)
        local good
        if want_failing then
            good = failed > 0
        else
            good = failed == 0 and passed > 0
        end
        print(string.format("self-test: %-34s %d passed, %d failed -> %s", label, passed, failed, good and "ok" or "WRONG"))
        if not good then failures += 1 end
    end

    Fake.perturb = {}
    local passed, failed, _, seconds = run_all(Fake, { strict_debug = true, quiet = true })
    expect("clean fake passes every trace", passed, failed, false)
    print(string.format("self-test: %d traces replayed in %.1f s", passed + failed, seconds))

    for _, case in ipairs({
        { "position +1 cm on every 7th frame", { position = 0.01 }, true },
        { "position +4 mm (inside 5 mm)", { position = 0.004 }, false },
        { "fov +0.1 deg", { fov = 0.1 }, true },
        { "ray 2 mm off (beyond 1 mm)", { ray = 0.002 }, true },
        { "ray 0.5 mm off (inside 1 mm)", { ray = 0.0005 }, false },
        { "one ray too many", { extra_ray = true }, true },
        { "one ray too few", { drop_ray = true }, true },
    }) do
        Fake.perturb = case[2]
        local p, f = run_all(Fake, { quiet = true })
        if case[3] then
            expect(case[1], p, f, true)
        else
            expect(case[1], p, f, false)
        end
    end
    Fake.perturb = {}
    if failures > 0 then error(string.format("self-test failed (%d wrong)", failures)) end
    print("self-test: harness ok")
    return
end

local loaded, camera_module = pcall(require, "camera")
if not loaded then
    error("camera.lua is not there yet (" .. tostring(camera_module) .. ")\nrun the self-test with: run_parity.lua self")
end
local passed, failed, failed_names, seconds = run_all(camera_module, { strict_debug = strict, keep_going = keep_going })
print(string.format("parity: %d passed, %d failed in %.1f s", passed, failed, seconds))
if failed > 0 then error("parity failed: " .. table.concat(failed_names, ", ")) end
