-- Independent displayed App/Glue Pop Off check through a rail exit and a
-- descending step. Shake/dip are disabled to isolate framing. One render
-- interval is 85 ms to exercise recovery without asserting impossible
-- continuity across a physically large displacement.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local New,Old,OldEscape=require("camera"),require("ref_1121/camera"),require("ref_1121/collision_escape")
local v,mag=vector.create,vector.magnitude
T.group("popoff_step_122")
local edge_z=12.6
local function floor(z) return z<edge_z and 2.5 or 0 end
local function sample(t)
    local z=6*t
    local state,y,vy
    if t<2 then state,y,vy=400,3.45,0
    elseif t<2.1 then state,y,vy=701,3.45,0
    elseif t<2.7 then
        local u=(t-2.1)/0.6
        state,y,vy=201,3.45-2.5*u*u,-5*u/0.6
    else state,y,vy=400,0.95,0 end
    return v(0,y,z),state,vy
end
local function world(a,b)
    local hit,best
    for _,h in {0,2.5} do
        if a.y~=b.y then
            local u=(h-a.y)/(b.y-a.y)
            if u>=0 and u<=1 and (not best or u<best) then
                local p=a+(b-a)*u
                if floor(p.z)==h then hit,best=p,u end
            end
        end
    end
    if hit then return hit,v(0,1,0) end
end
local function drive(fps,prior)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start({camera=prior and Old or New})
    if prior then
        app.glue.collision_escape=OldEscape.new()
        app.glue.soft_pull_guard_enabled=false
    end
    local s=Settings.defaults()
    s.follow.trick_pop=false
    s.shake_enabled=false
    s.native_plus.landing_dip=false
    assert(app.store:set_settings(s))
    local t=0
    local long_used=false
    local out={step=0,step_t=0,step_state=0,landing_step=0,pitch_step=0,fov_step=0,min_reach=10,min_floor=10,frames=0,rays=0,
        long_eye=0,long_root=0,final_rel_y=nil}
    local previous
    while t<4.0 do
        local dt=1/fps
        if not long_used and t>=2.4 then dt=0.085;long_used=true end
        t+=dt
        local root,state,vy=sample(t)
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=state==201
        m.state.board.deck={position=root-v(0,0.95,0),rotation={x=0,y=0,z=0,w=1}}
        m.state.board.velocity=v(0,vy,6)
        m.state.raycast=world
        m.fire("physics_step",{at=m.clock_ms,seconds=dt,velocity={0,vy,6},ragdoll=false})
        m.tick(dt*1000)
        out.rays=math.max(out.rays,m.state.raycasts)
        local shown=m.last_call("set")
        if shown and app.glue.source=="ride" and app.glue.blend>=1 then
            local pos=shown.position
            local rel=pos-root
            local reach=mag(v(rel.x,0,rel.z))
            out.min_reach=math.min(out.min_reach,reach)
            out.min_floor=math.min(out.min_floor,pos.y-floor(pos.z))
            out.frames+=1
            if previous and t>=2 and t<=3 then
                local step=mag(rel-previous.rel)
                if step>out.step then out.step,out.step_t,out.step_state=step,t,state end
                if state==400 then out.landing_step=math.max(out.landing_step,step) end
                out.pitch_step=math.max(out.pitch_step,math.deg(math.acos(math.clamp(vector.dot(shown.forward,previous.forward),-1,1))))
                out.fov_step=math.max(out.fov_step,math.abs(shown.fov-previous.fov))
            end
            if dt>0.08 and previous then
                out.long_eye=previous.pos.y-pos.y
                out.long_root=previous.root.y-root.y
            end
            if t>3.7 then out.final_rel_y=rel.y end
            previous={pos=pos,root=root,rel=rel,forward=shown.forward,fov=shown.fov}
            T.expect(reach>0.7 and pos.y>=floor(pos.z)-0.03,
                "Pop Off shown camera retains rider distance and floor clearance")
        end
    end
    T.expect(long_used and out.long_root>0.3 and out.frames>fps*2,
        "85ms descending interval and sustained App/Glue poses were observed")
    T.expect(app.errors==0 and out.rays<=64,"Pop Off App/Glue stays within callback and ray budget")
    return out
end
for _,fps in {30,60,144} do
    local a,b=drive(fps,false),drive(fps,true)
    print(string.format("Pop Off step %d: rel step %.3f@%.3f state%d / %.3f@%.3f state%d landing %.3f/%.3f pitch %.2f/%.2f FOV %.3f/%.3f reach %.3f/%.3f floor %.3f long eye/root %.3f/%.3f final Y %.3f/%.3f rays %d",
        fps,a.step,a.step_t,a.step_state,b.step,b.step_t,b.step_state,a.landing_step,b.landing_step,a.pitch_step,b.pitch_step,a.fov_step,b.fov_step,a.min_reach,b.min_reach,
        a.min_floor,a.long_eye,a.long_root,a.final_rel_y,b.final_rel_y,a.rays))
    T.expect(a.landing_step<b.landing_step-0.02 or (fps==144 and a.landing_step<=b.landing_step+0.01),
        "new Pop Off rail/step handoff improves touchdown or retains high-rate behavior")
    T.expect(a.fov_step<0.2 and a.min_reach>0.7,"Pop Off does not zoom or collapse horizontal reach")
    T.expect(a.long_eye>0.05,"camera follows a substantial descent across the 85ms frame")
    T.expect(math.abs(a.final_rel_y-b.final_rel_y)<0.1,"Pop Off settles to previous riding height")
end
T.done()
if T.failures>0 then error("Pop Off step tests failed") end
