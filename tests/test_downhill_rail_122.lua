local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local New,Old=require("camera"),require("ref_1121/camera")
local OldEscape=require("ref_1121/collision_escape")
local v,mag=vector.create,vector.magnitude
T.group("downhill_rail_122")

local slope=-0.45
local speed=7.0
local function floor_at(z) return slope*z end
local function world(a,b)
    local da=a.y-floor_at(a.z)
    local db=b.y-floor_at(b.z)
    if da>=0 and db<=0 and da~=db then
        local p=a+(b-a)*(da/(da-db))
        return p,vector.normalize(v(0,1,-slope))
    end
    return nil
end

-- Full App/Glue output, including the camera's core rays, prediction, the
-- display guard, and short post-grind/air recontacts. The prior ZIP's camera
-- and helper are loaded byte-for-byte from ref_1121.
local function ride(module,fps,old,popoff,deep)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start({camera=module})
    if old then app.glue.collision_escape=OldEscape.new();app.glue.soft_pull_guard_enabled=false end
    local s=Settings.defaults()
    s.shake_enabled=false
    s.native_plus.landing_dip=false
    s.follow.trick_pop=not popoff
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2.2
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.2
    assert(app.store:set_settings(s))
    local metrics={pull=0,reach=10,gap=10,pitch=-90,step=0,rays=0,violations=0,frames=0,escape_side=false}
    local prev
    for i=1,math.floor(fps*5) do
        local t=i/fps
        local z=speed*t
        local y=floor_at(z)+0.95
        local state=403
        local phase=t%1.5
        if deep then
            if t>=1.5 and t<1.58 then state=701
            elseif t>=1.58 and t<2.08 then state=201 end
        else
            if t>1.5 and phase<0.09 then state=701
            elseif t>1.5 and phase<0.22 then state=201 end
        end
        local root=v(0,y,z)
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=state==201
        m.state.board.deck={position=v(0,floor_at(z),z),rotation={0,0,0,1}}
        m.state.board.velocity=v(0,slope*speed,speed)
        m.state.raycast=world
        m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,slope*speed,speed},ragdoll=false})
        m.tick(1000/fps)
        metrics.rays=math.max(metrics.rays,m.state.raycasts)
        local shown=m.last_call("set")
        local g=app.glue
        local d=g.frame and g.frame.debug
        if shown and g.source=="ride" and g.blend>=1 and t>0.8 then
            local p=shown.position
            local reach=mag(v(p.x-root.x,0,p.z-root.z))
            metrics.reach=math.min(metrics.reach,reach)
            metrics.gap=math.min(metrics.gap,p.y-floor_at(p.z))
            metrics.pitch=math.max(metrics.pitch,math.deg(math.asin(-shown.forward.y)))
            metrics.pull=math.max(metrics.pull,d and d.collision_pull or 0)
            if prev then
                local step=mag((p-root)-prev)
                if step>metrics.step then metrics.step,metrics.step_at,metrics.step_state=step,t,state end
            end
            prev=p-root
            metrics.frames+=1
            if g.collision_escape.side~=0 and g.collision_escape.side~=2 then metrics.escape_side=true end
            if p.y<floor_at(p.z)-0.02 or reach<0.75 or g.rays_tick>64 then metrics.violations+=1 end
        end
    end
    T.expect(app.errors==0 and metrics.rays<=64,"App/Glue rail fixture runs within ray budget")
    return metrics
end

for _,fps in {30,60,144} do
    local a,b=ride(New,fps,false),ride(Old,fps,true)
    print(string.format("rail %d: pull %.3f/%.3f reach %.3f/%.3f floor %.3f/%.3f step %.3f/%.3f rays %d/%d side %s/%s frames %d/%d",
        fps,a.pull,b.pull,a.reach,b.reach,a.gap,b.gap,a.step,b.step,a.rays,b.rays,tostring(a.escape_side),tostring(b.escape_side),a.frames,b.frames))
    T.expect(a.frames>fps*2 and b.frames>fps*2,"both versions display sustained rail frames")
    T.expect(a.violations==0 and a.gap>=-0.02 and a.reach>=0.75,"shown rail eye stays clear and keeps rider distance")
    T.expect(not a.escape_side,"rail clearance uses no lateral axis")
    T.expect(a.pull<b.pull,"rail eye has less core collision pull than 1.1.21")
    local po,prior=ride(New,fps,false,true),ride(Old,fps,true,true)
    print(string.format("rail Pop Off %d: pull %.3f/%.3f reach %.3f/%.3f step %.3f@%.3f state%d / %.3f@%.3f state%d floor %.3f/%.3f",
        fps,po.pull,prior.pull,po.reach,prior.reach,po.step,po.step_at or 0,po.step_state or 0,prior.step,prior.step_at or 0,prior.step_state or 0,po.gap,prior.gap))
    T.expect(po.violations==0 and po.pull<prior.pull and po.step<prior.step,
        "Pop Off rail recontacts keep clearance with smaller displayed steps")
    local deep_now,deep_old=ride(New,fps,false,true,true),ride(Old,fps,true,true,true)
    print(string.format("rail deep Pop Off %d: pull %.3f/%.3f reach %.3f/%.3f step %.3f@%.3f / %.3f@%.3f floor %.3f/%.3f",
        fps,deep_now.pull,deep_old.pull,deep_now.reach,deep_old.reach,deep_now.step,deep_now.step_at or 0,
        deep_old.step,deep_old.step_at or 0,deep_now.gap,deep_old.gap))
    T.expect(deep_now.violations==0 and deep_now.gap>=-0.02 and deep_now.rays<=64,
        "deep rail recontact remains outside terrain within budget")
    T.expect(deep_now.pull<deep_old.pull and deep_now.reach>deep_old.reach,
        "deep rail recontact keeps more distance without severe collision pull")
    T.expect(deep_now.step<deep_old.step*0.6,
        "deep downhill Pop Off return has a bounded displayed step")
end
T.done()
if T.failures>0 then error("downhill rail tests failed") end
