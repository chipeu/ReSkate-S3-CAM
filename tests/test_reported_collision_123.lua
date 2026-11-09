-- A physical ledge drop with a vertical lip, driven through App/Glue.
-- Compare Pop Off and On under the reported close Fixed profile.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("reported_collision_123")
local edge=12.6
local function floor(z) return z<edge and 2.5 or 0 end
local function world(a,b)
    local hit,best,normal
    for _,h in {0,2.5} do
        if a.y>=h and b.y<=h and a.y~=b.y then
            local u=(h-a.y)/(b.y-a.y)
            local p=a+(b-a)*u
            if floor(p.z)==h and (not best or u<best) then hit,best,normal=p,u,v(0,1,0) end
        end
    end
    if a.z~=b.z then
        local u=(edge-a.z)/(b.z-a.z)
        if u>=0 and u<=1 then
            local p=a+(b-a)*u
            if p.y>=0 and p.y<=2.5 and (not best or u<best) then
                hit,best,normal=p,u,v(0,0,a.z<edge and -1 or 1)
            end
        end
    end
    if hit then return hit,normal end
end
local function motion(t)
    local z=6*t
    local state,y,vy
    if t<1.95 then state,y,vy=400,3.45,0
    elseif t<2.10 then state,y,vy=701,3.45,0
    elseif t<2.16 then state,y,vy=200,3.45,0
    elseif t<2.70 then
        local u=(t-2.16)/0.54
        state,y,vy=201,3.45-2.5*u*u,-5*u/0.54
    else state,y,vy=400,0.95,0 end
    return v(0,y,z),state,vy
end
local function drive(pop)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local s=Settings.defaults()
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.5
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,1.5
    s.framing.grind_distance=1.6
    s.framing_high.grind_distance=1.6
    s.follow.crouch_enabled=false
    s.follow.crouch_amount=1
    s.follow.trick_pop=pop
    s.follow.pop_amount=1
    s.shake_enabled=false
    s.native_plus.landing_dip=false
    assert(app.store:set_settings(s))
    local out={min_reach=1e6,min_floor=1e6,max_pull=0,max_step=0,max_pitch=0,max_fov=0,frames=0,max_rays=0,manual=false}
    local prev,t=nil,0
    for i=1,240 do
        local dt=i==147 and 0.085 or 1/60
        t+=dt
        local root,state,vy=motion(t)
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=state==200 or state==201
        m.state.board.deck={position=root-v(0,0.95,0),rotation={x=0,y=0,z=0,w=1}}
        m.state.board.velocity=v(0,vy,6)
        m.state.raycast=world
        m.fire("physics_step",{at=m.clock_ms,seconds=dt,velocity={0,vy,6},ragdoll=false})
        m.tick(dt*1000)
        out.max_rays=math.max(out.max_rays,m.state.raycasts)
        local shown=m.last_call("set")
        local g=app.glue
        if shown and g.source=="ride" and g.blend>=1 then
            local p=shown.position
            local rel=p-root
            local reach=mag(v(rel.x,0,rel.z))
            local gap=p.y-floor(p.z)
            local pitch=math.deg(math.asin(-shown.forward.y))
            local d=g.frame.debug
            local flight=g.cam.pop_flight
            local sample={rel=rel,pitch=pitch,fov=shown.fov,root=root,board=m.state.board.deck.position,
                core_pitch=math.deg(math.asin(g.frame.back.y)),
                predicted=d.predicted_landing_delta,drop_w=d.pop_drop_weight,height_w=d.pop_height_weight,
                pitch_w=d.pop_pitch_weight,vertical_w=d.pop_vertical_weight,air_rise=d.air_rise,
                keep_pitch=d.keep_pitch_offset,pull=d.collision_pull,
                flight_pitch=flight and math.deg(flight.pitch),flight_height=flight and flight.height,
                tilt=math.deg(g.cam.tilt.position),shown_y=p.y,fov=shown.fov}
            out.min_reach=math.min(out.min_reach,reach)
            out.min_floor=math.min(out.min_floor,gap)
            out.max_pull=math.max(out.max_pull,g.frame and g.frame.debug and g.frame.debug.collision_pull or 0)
            out.manual=out.manual or g.snap.manual
            if prev and t>1.8 and t<3.2 then
                out.max_step=math.max(out.max_step,mag(rel-prev.rel))
                local dp=math.abs(pitch-prev.pitch)
                if dp>out.max_pitch then
                    out.max_pitch,out.pitch_at,out.pitch_state,out.pitch_before,out.pitch_after=dp,t,state,prev.pitch,pitch
                    out.pitch_before_sample,out.pitch_after_sample=prev,sample
                end
                out.max_fov=math.max(out.max_fov,math.abs(shown.fov-prev.fov))
            end
            prev=sample
            out.frames+=1
        end
    end
    T.expect(app.errors==0 and out.max_rays<=64 and not out.manual,
        "ledge fixture has physical deck pose, no manual and stays within ray budget")
    return out
end
local off,on=drive(false),drive(true)
print(string.format("reported ledge collision Pop Off/On: reach %.3f/%.3f floor %.3f/%.3f pull %.3f/%.3f step %.3f/%.3f pitch %.2f/%.2f FOV %.3f/%.3f rays %d/%d frames %d/%d",
    off.min_reach,on.min_reach,off.min_floor,on.min_floor,off.max_pull,on.max_pull,
    off.max_step,on.max_step,off.max_pitch,on.max_pitch,off.max_fov,on.max_fov,
    off.max_rays,on.max_rays,off.frames,on.frames))
print(string.format("Pop Off largest pitch step t %.3f state%d: %.2f -> %.2f deg",
    off.pitch_at or 0,off.pitch_state or 0,off.pitch_before or 0,off.pitch_after or 0))
for _,p in {off.pitch_before_sample,off.pitch_after_sample} do
    if p then print(string.format("  core %.2f shown %.2f tilt %.2f predicted %.3f dropW %.2f heightW %.2f pitchW %.2f verticalW %.2f airRise %.2f keep %.2f pull %.3f flightPitch %s flightHeight %s rootY %.3f boardY %.3f shownY %.3f fov %.2f",
        p.core_pitch,p.pitch,p.tilt,p.predicted or -99,p.drop_w or -1,p.height_w or -1,p.pitch_w or -1,
        p.vertical_w or -1,p.air_rise or -99,p.keep_pitch or -99,p.pull or -99,
        tostring(p.flight_pitch),tostring(p.flight_height),p.root.y,p.board.y,p.shown_y,p.fov)) end
end
T.expect(off.frames>120 and on.frames>120,"both settings display sustained ledge drop frames")
T.expect(off.min_reach>0.7 and off.min_floor>=-0.02,"Pop Off keeps rider reach and terrain clearance through the ledge")
T.expect(off.max_fov<0.2,"Pop Off keeps lens stable through the ledge")
T.expect(off.max_pitch<5,"Pop Off ledge collision does not jerk the view by more than five degrees")
T.done()
if T.failures>0 then error("reported collision tests failed") end
