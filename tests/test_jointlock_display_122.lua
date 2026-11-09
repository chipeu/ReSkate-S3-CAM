-- Independent actual App/Glue display checks. All joint positions are native
-- Luau vectors, matching reskate.skater.joint's runtime contract.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("jointlock_display_122")

local function height(t)
    if t<1 then return 0 end
    if t<2.2 then return t-1 end
    if t<3.2 then return 1.2 end
    if t<4.4 then return 1.2-(t-3.2) end
    return 0
end
local function finite3(p)
    return p and p.x==p.x and p.y==p.y and p.z==p.z
        and math.abs(p.x)<1e6 and math.abs(p.y)<1e6 and math.abs(p.z)<1e6
end
local function yaw(f)
    return math.atan2(f.x,f.z)
end
local function drive(fps,damping,variant,mode)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local s=Settings.defaults()
    s.follow.camera_style="joint_lock"
    s.follow.joint_target="head"
    s.follow.joint_damping=damping
    s.shake_enabled=false
    s.native_plus.landing_dip=false
    s.collision.enabled=false -- isolate the vertical filter from terrain correction
    s.points.floor_clearance=0
    assert(app.store:set_settings(s))
    local out={shown={},valid=0,max_rays=0,max_step=0,marker_delta=nil,switch_step=0,missing_step=0}
    local previous
    local switched=false
    local q=variant=="bone" and {x=0.31,y=-0.47,z=0.18,w=0.80} or {x=0,y=0,z=0,w=1}
    local board_q=variant=="board" and {x=0,y=0,z=math.sin(math.rad(70)/2),w=math.cos(math.rad(70)/2)}
        or {x=0,y=0,z=0,w=1}
    for i=1,math.floor(6.7*fps) do
        local t=i/fps
        local h=(mode=="bursts" or mode=="static") and 0 or height(t)
        local marker_shift=mode=="marker" and t>=3.6 and 80 or 0
        local root=v(marker_shift,0.95+h,6*t)
        m.state.skater.position=root
        m.state.telemetry.physics_state=100
        m.state.telemetry.airborne=false
        local burst=false
        if mode=="bursts" and t>=1 and t<6.1 then
            local phase=(t-1)%0.25
            burst=phase<2/fps
        end
        if (mode=="missing" and t>=1.9 and t<3.3) or burst then
            m.state.joints[103]=nil
        else
            m.state.joints[103]={position=root+v(0,0.85,0),rotation=q}
        end
        m.state.joints[10]={position=root+v(0,-0.77,0),rotation=q}
        m.state.joints[343]={position=root+v(0,-0.79,0),rotation=q}
        if mode=="target" and t>=2 and not switched then
            local changed=Settings.copy(s)
            changed.follow.joint_target="feet"
            assert(app.store:set_settings(changed))
            switched=true
        end
        m.state.board.deck={position=root-v(0,0.95,0),rotation=board_q}
        m.state.board.velocity=v(0,0,6)
        m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,0,6},ragdoll=false})
        m.tick(1000/fps)
        out.max_rays=math.max(out.max_rays,m.state.raycasts)
        local g=app.glue
        if g.joint_valid then out.valid+=1 end
        local shown=m.last_call("set")
        if shown and g.source=="ride" and g.blend>=1 then
            T.expect(finite3(shown.position) and finite3(shown.forward) and finite3(shown.up),
                "shown JointLock pose stays finite")
            local sample={t=t,root=root,pos=shown.position,rel=shown.position-root,
                forward=shown.forward,up=shown.up,delta=g.joint_delta}
            out.shown[i]=sample
            if previous then
                local step=mag(sample.rel-previous.rel)
                out.max_step=math.max(out.max_step,step)
                if mode=="target" and t>=1.95 and t<2.3 then out.switch_step=math.max(out.switch_step,step) end
                if mode=="missing" and t>=1.85 and t<3.5 then out.missing_step=math.max(out.missing_step,step) end
            end
            previous=sample
            if mode=="marker" and t>=3.6 and not out.marker_delta then out.marker_delta=g.joint_delta end
        end
    end
    T.expect(app.errors==0 and out.max_rays<=64,"JointLock App/Glue stays within callback and ray limits")
    T.expect(out.valid>fps*4,"native vector joint samples reach the live Glue filter")
    if mode=="marker" then T.expect(out.marker_delta~=nil,"marker return displays a riding pose") end
    return out
end
local function near_time(out,target,fps)
    local i=math.floor(target*fps+0.5)
    return assert(out.shown[i],"missing shown sample at "..target)
end
for _,fps in {30,60,144} do
    local immediate=drive(fps,0,false,false)
    local damped=drive(fps,100,false,false)
    local rotated=drive(fps,100,"bone",false)
    local board_rotated=drive(fps,100,"board",false)
    local up0,up100=near_time(immediate,1.9,fps),near_time(damped,1.9,fps)
    local down0,down100=near_time(immediate,4.0,fps),near_time(damped,4.0,fps)
    local end0,end100=near_time(immediate,6.4,fps),near_time(damped,6.4,fps)
    print(string.format("JointLock shown %d: rise eye %.3f immediate %.3f damped (delta %.3f/%.3f), fall %.3f immediate %.3f damped (delta %.3f/%.3f), settle %.3f/%.3f (delta %.3f/%.3f), valid %d",
        fps,up0.pos.y,up100.pos.y,up0.delta,up100.delta,
        down0.pos.y,down100.pos.y,down0.delta,down100.delta,
        end0.pos.y,end100.pos.y,end0.delta,end100.delta,damped.valid))
    T.expect(up100.pos.y<up0.pos.y-0.08,"100% damping visibly lags rigid upward body motion")
    T.expect(down100.pos.y>down0.pos.y+0.08,"100% damping visibly lags rigid downward body motion")
    T.expect(math.abs(end100.pos.y-end0.pos.y)<0.06,"damped eye converges after rigid rise and fall")
    for i,a in damped.shown do
        local b=rotated.shown[i]
        T.expect(b and mag(a.pos-b.pos)<1e-5 and mag(a.forward-b.forward)<1e-5
            and mag(a.up-b.up)<1e-5,"joint rotation does not affect shown position or axes")
        local c=board_rotated.shown[i]
        T.expect(c and math.abs(yaw(a.forward)-yaw(c.forward))<math.rad(4),
            "board roll does not steer JointLock camera yaw")
    end
    local returned=drive(fps,100,false,"marker")
    T.expect(math.abs(returned.marker_delta)<0.05,"marker return clears stale JointLock vertical delta")
    local retargeted=drive(fps,100,false,"target")
    local missing=drive(fps,100,false,"missing")
    local clean_static=drive(fps,100,false,"static")
    local bursts=drive(fps,100,false,"bursts")
    print(string.format("JointLock transitions %d: target switch step %.3f, nil/reacquire step %.3f, marker delta %.3f",
        fps,retargeted.switch_step,missing.missing_step,returned.marker_delta))
    T.expect(retargeted.switch_step<0.25*60/fps+0.05,"target switch has bounded shown eye step")
    T.expect(missing.missing_step<0.25*60/fps+0.05,"missing joint and reacquire have bounded shown eye step")
    local clean_end=near_time(clean_static,6.4,fps)
    local burst_end=near_time(bursts,6.4,fps)
    print(string.format("JointLock repeated nil %d: final eye %.3f vs clean %.3f, delta %.3f vs %.3f",
        fps,burst_end.pos.y,clean_end.pos.y,burst_end.delta,clean_end.delta))
    T.expect(math.abs(burst_end.pos.y-clean_end.pos.y)<0.01 and math.abs(burst_end.delta-clean_end.delta)<0.01,
        "repeated short nil reads do not accumulate a permanent camera rise")
end
T.done()
if T.failures>0 then error("JointLock displayed-pose tests failed") end
