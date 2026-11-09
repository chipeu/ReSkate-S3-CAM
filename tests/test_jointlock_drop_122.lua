-- JointLock App/Glue large drop: a 20 m descent must follow the rider rather
-- than keep an old world eye height. The piecewise floor models an upper deck
-- and lower landing, and the camera's own collision remains enabled.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("jointlock_drop_122")
local function floor(z) return z<12 and 20 or 0 end
local function world(a,b)
    local hit,best
    for _,h in {20,0} do
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
local function sample(t)
    local z=6*t
    if t<2 then return v(0,20.95,z),100,0 end
    if t<4 then
        local a=t-2
        return v(0,20.95-5*a*a,z),201,-10*a
    end
    return v(0,0.95,z),100,0
end
local function drive(fps,target)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local s=Settings.defaults()
    s.follow.camera_style="joint_lock"
    s.follow.joint_target=target
    s.follow.joint_damping=100
    assert(app.store:set_settings(s))
    local out={valid=0,air_frames=0,min_floor=10,min_reach=10,max_gap=0,
        start_eye=nil,late_eye=nil,final_delta=nil,final_gap=nil,max_angle=0,rays=0}
    for i=1,math.floor(6.5*fps) do
        local t=i/fps
        local root,state,vy=sample(t)
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=state==201
        m.state.joints[103]=root+v(0,0.85,0)
        m.state.joints[10]=root+v(0,-0.78,0)
        m.state.joints[343]=root+v(0,-0.80,0)
        m.state.board.deck={position=root-v(0,0.95,0),rotation={x=0,y=0,z=0,w=1}}
        m.state.board.velocity=v(0,vy,6)
        m.state.raycast=world
        m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,vy,6},ragdoll=false})
        m.tick(1000/fps)
        local g=app.glue
        if g.joint_valid then out.valid+=1 end
        out.rays=math.max(out.rays,m.state.raycasts)
        local shown=m.last_call("set")
        if shown and g.source=="ride" and g.blend>=1 then
            local eye=shown.position
            local rel=eye-root
            local reach=mag(v(rel.x,0,rel.z))
            local gap=eye.y-floor(eye.z)
            local to_head=vector.normalize(root+v(0,0.85,0)-eye)
            local angle=math.deg(math.acos(math.clamp(vector.dot(to_head,shown.forward),-1,1)))
            if t>=1.8 and t<2 then out.start_eye=eye.y end
            if t>=3.8 and t<4 then out.late_eye=eye.y end
            if state==201 and t>2.3 then
                out.air_frames+=1
                out.max_gap=math.max(out.max_gap,math.abs(rel.y))
                out.max_angle=math.max(out.max_angle,angle)
            end
            if t>5.8 then out.final_delta=g.joint_delta;out.final_gap=rel.y end
            out.min_floor=math.min(out.min_floor,gap)
            out.min_reach=math.min(out.min_reach,reach)
            T.expect(eye.x==eye.x and eye.y==eye.y and eye.z==eye.z and gap>=-0.03,
                "20m JointLock drop eye stays finite and above modeled floor")
        end
    end
    T.expect(app.errors==0 and out.rays<=64,"20m JointLock drop stays inside callback and ray limits")
    T.expect(out.valid>fps*3 and out.air_frames>fps,"selected native joint is used during long fall")
    return out
end
for _,fps in {30,60,144} do
    for _,target in fps==60 and {"head","feet","skateboard"} or {"head"} do
        local r=drive(fps,target)
        print(string.format("JointLock 20m %d %s: eye %.2f->%.2f, max relY %.2f, angle %.1f, floor %.2f, reach %.2f, final delta %.3f gap %.3f rays %d",
            fps,target,r.start_eye or 0,r.late_eye or 0,r.max_gap,r.max_angle,r.min_floor,r.min_reach,
            r.final_delta or 0,r.final_gap or 0,r.rays))
        T.expect(r.start_eye and r.late_eye and r.start_eye-r.late_eye>15,
            "20m descent moves the shown eye down with the skater")
        T.expect(r.max_gap<5 and r.max_angle<70 and r.min_reach>0.7,
            "20m fall keeps a bounded rider-relative eye and view")
        T.expect(r.final_delta and math.abs(r.final_delta)<0.08,
            "JointLock damping converges after large landing")
    end
end
T.done()
if T.failures>0 then error("JointLock large-drop tests failed") end
