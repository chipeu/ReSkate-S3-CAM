-- A stand-in camera that returns the recorded outputs: a replay of the replay. It proves the harness (parsing, settings, ray
-- answering, comparison) before camera.lua exists. replay.run calls Fake.bind_trace(trace) before Fake.new().
--
-- Fake.perturb = { position = 0.01 } adds 1 cm to every output's position, { fov = 0.1 } adds 0.1 deg, { ray = 0.002 } asks the
-- world about a ray 2 mm off, { extra_ray = true } casts one ray too many, { drop_ray = true } one too few. The self-test
-- (run_parity.lua self) expects the clean fake to pass and each perturbation to fail.
local Fake = {}
Fake.__index = Fake

Fake.perturb = {}

local trace
function Fake.bind_trace(t)
    trace = t
end

function Fake.new()
    return setmetatable({ frame = 0 }, Fake)
end

function Fake:set_settings(settings)
    self.settings = settings
    return true
end

function Fake:cut() end

function Fake:update(dt, snapshot, query, extras)
    self.frame += 1
    local recorded = trace.frames[self.frame]
    assert(recorded, "the fake camera ran past the end of its trace")
    -- Answer for the recorded inputs: the harness must have handed the same dt and snapshot over.
    assert(math.abs(dt - recorded.dt) < 1e-12, "dt differs from the recording")
    assert(vector.magnitude(snapshot.position - recorded.snapshot.position) < 1e-12, "snapshot position differs from the recording")

    local p = Fake.perturb
    local rays = recorded.rays
    local count = #rays
    if p.drop_ray and count > 0 and self.frame == 3 then count -= 1 end
    for i = 1, count do
        local ray = rays[i]
        local from, to = ray.from, ray.to
        if p.ray and self.frame == 3 and i == 1 then from = from + vector.create(p.ray, 0, 0) end
        query(from, to)
    end
    if p.extra_ray and self.frame == 3 then query(vector.create(0, 0, 0), vector.create(0, -1, 0)) end

    local out = recorded.output
    local pos, fov = out.pos, out.fov_deg
    if p.position and self.frame % 7 == 0 then pos = pos + vector.create(0, p.position, 0) end
    if p.fov and self.frame % 7 == 0 then fov += p.fov end
    return {
        valid = out.valid,
        pos = pos,
        right = out.right,
        up = out.up,
        back = out.back,
        fov_deg = fov,
        debug = {
            shot_name = out.shot,
            distance = out.fields.distance,
            elevation = out.fields.elevation,
            heading = out.fields.heading,
            collision_pull = out.fields.collision_pull,
            keep_weight = out.fields.keep_weight,
            chase_blend = out.fields.chase_blend,
            orbit_anchor = out.fields.orbit_anchor,
            skater_anchor = out.fields.skater_anchor,
            look_target = out.fields.look_target,
        },
    }
end

return Fake
