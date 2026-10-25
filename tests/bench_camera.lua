-- Times full replays of the longest traces through camera.lua: microseconds per frame (ray answers come from the recording,
-- so the replay's own bookkeeping is included; the second figure times update() alone).
local replay = require("replay")
local Camera = require("camera")
local names = { "trace_carve_horizontal10_144", "trace_mixed_high_144", "trace_mixed_jitter_144", "trace_big_air", "trace_drop_in" }
local total_frames, total_time = 0, 0
for _, name in ipairs(names) do
    local trace = replay.load(name)
    local settings = replay.build_settings(trace)
    local best = math.huge
    for _ = 1, 5 do
        local cam = Camera.new()
        cam:set_settings(settings)
        local frames = trace.frames
        local rays, n = nil, 0
        local function query(from, to)
            n += 1
            local r = rays[n]
            if r and r.hit then return r.point, r.normal end
            return nil
        end
        local t0 = os.clock()
        for i = 1, #frames do
            local f = frames[i]
            rays, n = f.rays, 0
            cam:update(f.dt, f.snapshot, query, { base_fov_deg = f.base_fov })
        end
        best = math.min(best, os.clock() - t0)
    end
    print(string.format("%-30s %5d frames  %.1f us/frame", name, #trace.frames, best / #trace.frames * 1e6))
    total_frames += #trace.frames
    total_time += best
end
print(string.format("average %.1f us/frame", total_time / total_frames * 1e6))
