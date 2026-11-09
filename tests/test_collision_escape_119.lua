local T = require("tlib")
T.group("collision escape 119")
local Escape = require("collision_escape")
local v = vector.create
local mag = vector.magnitude
local base, pivot = v(0, 1, -1), v(0, 1, 0)

local function simulate(fps, ray, frames)
    local e, count, poses = Escape.new(), 0, {}
    local function cast(a, b)
        count += 1
        return ray(a, b)
    end
    for i = 1, frames do
        count = 0
        poses[i] = e:step(base, pivot, 2, 1, i / fps, 1 / fps, cast, 8)
        T.expect(count <= 4, "bounded search rays")
        T.expect(mag(poses[i] - base) <= 0.47, "eye stays within small local correction")
    end
    return e, poses
end

-- A post blocks one shoulder. The other has a genuinely open line of sight.
local function one_side(a, b)
    if a.z == 0 and b.x < -0.01 then return a + (b - a) * 0.35 end
    return nil
end
for _, fps in ipairs({30, 60, 144}) do
    local e, p = simulate(fps, one_side, fps * 2)
    T.expect(e.offset < -0.17 and p[#p].x > 0.17, "open shoulder found at " .. fps .. " fps")
    local last = base
    for index, eye in ipairs(p) do
        T.expect(mag(eye - last) <= 0.90 / fps, "smooth bounded motion at " .. fps .. " fps")
        last = eye
    end
end

-- Every direction is blocked: the camera must hold the core position.
local e, enclosed = simulate(60, function(a, b)
    if a.z == 0 then return a + (b - a) * 0.2 end
    return nil
end, 150)
T.expect(e.offset == 0 and T.vnear(enclosed[#enclosed], base), "fully enclosed: no hunting")

local close = Escape.new()
local near_eye = v(0,1,-0.8)
for i=1,90 do
    local eye=close:step(near_eye,pivot,1.8,1,i/60,1/60,one_side,8)
    T.expect(mag(eye-near_eye)<=0.21,"close arm shifts at most one fifth of its reach")
end

-- An open candidate with a blocked lateral sweep is rejected. This is the
-- sudden side-wall case which a pivot-to-eye ray alone cannot catch.
local wall = Escape.new()
for i = 1, 30 do
    local eye = wall:step(base, pivot, 2, 1, i / 60, 1 / 60, function(a, b)
        if a.z == -1 and b.x ~= 0 then return a + (b - a) * 0.5 end
        if a.z == 0 and b.x < 0 then return a + (b - a) * 0.3 end
        return nil
    end, 8)
    T.expect(T.vnear(eye, base), "side wall rejects sweep")
end

-- Release after obstruction clears is eased and never flips to the other side.
local escape = Escape.new()
for i = 1, 90 do escape:step(base, pivot, 2, 1, i / 60, 1 / 60, one_side, 8) end
local previous = escape.offset
for i = 91, 210 do
    local eye = escape:step(base, pivot, 2, 0, i / 60, 1 / 60, function() return nil end, 8)
    T.expect(escape.offset <= 1e-6 and escape.offset >= previous - 1e-6, "eased return without flip")
    T.expect(mag(eye - base) <= 0.47, "return stays bounded")
    previous = escape.offset
end
T.expect(escape.offset < 0.002, "returns to neutral")

-- Pressure from a crowded tick: do not spend a probe or assume free space.
local crowded = Escape.new()
local rays = 0
for i = 1, 90 do crowded:step(base, pivot, 2, 1, i / 60, 1 / 60, function() rays += 1; return nil end, 4) end
T.expect(rays == 0 and crowded.offset == 0, "ray pressure leaves core alone")

-- Exercise the real Glue output path with Pop On, including the reserved
-- final floor ray. A simple post closes one side of a short camera arm.
do
    local Mock, Settings, Store, Glue = require("mock_reskate"), require("settings"), require("store"), require("glue")
    local m = Mock.install({limit_rays=true})
    m.reskate.input.gamepad = function() return nil end
    m.reskate.menu.game = function() return {open=false} end
    local store = Store.new(); store:load()
    local settings = Settings.defaults()
    settings.shake_enabled = false
    T.expect(settings.follow.trick_pop == true and settings.collision.automatic == true, "test covers default Pop On and automatic collision")
    assert(store:set_settings(settings))
    local Stub = {new=function() return {cut=function() end} end}
    local g = Glue.new({store=store,camera=Stub})
    g.source,g.blend,g.snap_guard_on="ride",1,false
    g.snap.valid,g.snap.onboard,g.snap.physics_state=true,true,100
    g.snap.position,g.snap.forward=pivot,v(0,0,1)
    g.skater_position=pivot
    g.frame={debug={collision_pull=1,collision_pivot=pivot,collision_full=2}}
    m.state.raycast=function(a,b)
        if a.z==0 and b.x < -0.01 then return a+(b-a)*0.35 end
        if a.y>=0 and b.y<0 then return a+(b-a)*(a.y/(a.y-b.y)) end
        return nil
    end
    local moved=false
    for i=1,90 do
        m.clock_ms=i*1000/60
        m.state.raycasts,g.rays_tick=0,0
        assert(g:show(base,v(0,0,1),v(0,1,0),65,"riding"))
        local p=m.last_call("set").position
        if p.x>0.1 then moved=true end
        T.expect(p.y>=0.3 and m.state.raycasts<=64 and g.rays_tick<=64,"Pop On final eye and ray cap")
    end
    T.expect(moved,"Glue finds the open side while Pop On")
    m.clock_ms=1517;m.state.raycasts,g.rays_tick=0,60
    assert(g:show(base,v(0,0,1),v(0,1,0),65,"riding"))
    T.expect(m.last_call("set").position.x>0.1 and g.rays_tick<=64,
        "crowded frame retains latched side with reserved final validation")
    g.snap.physics_state=201;g.snap.velocity=v(0,-2,0)
    m.clock_ms=1534;m.state.raycasts,g.rays_tick=0,0
    assert(g:show(base,v(0,0,1),v(0,1,0),65,"riding"))
    T.expect(m.last_call("set").position.x>0.1,"slow airborne collision can retain view room")
    g.snap.velocity=v(0,-7,0)
    m.clock_ms=1551;m.state.raycasts,g.rays_tick=0,0
    assert(g:show(base,v(0,0,1),v(0,1,0),65,"riding"))
    T.expect(m.last_call("set").position.x>0.1 and m.state.raycasts<=3,
        "fast drop holds visible side without a new search")
    g.snap.physics_state=100;g.snap.velocity=v(0,0,0)
    settings.collision.automatic=false;assert(store:set_settings(settings))
    m.clock_ms=2000;m.state.raycasts,g.rays_tick=0,0
    assert(g:show(base,v(0,0,1),v(0,1,0),65,"riding"))
    T.expect(T.vnear(m.last_call("set").position,base),"manual collision setting leaves camera unchanged")
end

T.done()
if T.failures>0 then error("collision escape tests failed") end
