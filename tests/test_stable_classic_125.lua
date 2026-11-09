-- Full App/Glue regression for a delayed air-to-landing shot and a high flat pop.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("stable_classic_125")

local function world(a,b,drop)
    local hit,nearest
    for _,h in {0,1} do
        if (h==0 or (drop and (a.z<6 or b.z<6))) and a.y>=h and b.y<=h and a.y~=b.y then
            local u=(h-a.y)/(b.y-a.y)
            local p=a+(b-a)*u
            if (h==0 or p.z<6) and (not nearest or u<nearest) then hit,nearest=p,u end
        end
    end
    if hit then return hit,v(0,1,0) end
end
local function run(kind,hz,angle,crouch)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local s=Settings.defaults()
    s.angle=angle or Settings.CameraAngle.Low
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.53
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.40
    s.follow.trick_pop=false;s.follow.pop_amount=1
    s.follow.crouch_enabled=crouch==true;s.follow.crouch_amount=1
    s.trick_yaw.enabled=false
    s.shake_enabled=false;s.native_plus.landing_dip=false
    assert(app.store:set_settings(s))
    local dt=1/hz
    local out={samples={},max_rays=0,shot_changes=0}
    local previous_shot
    for i=1,math.floor(5*hz) do
        local t=i*dt-1
        local state,dy,vy=100,0,0
        if t>=1 and t<2 then
            state=t<1.08 and 200 or 201
            local u=t-1
            if kind=="flat" then dy=1.4*math.sin(math.pi*u);vy=1.4*math.pi*math.cos(math.pi*u)
            else dy=-1.0*u;vy=-1.0 end
        elseif kind=="drop" and t>=2 then
            dy=-1.0
        end
        local compression=crouch and t>=0.6 and t<1 and 0.3*math.min((t-0.6)/0.15,1) or 0
        if compression>0 then state=103 end
        local root=v(0,(kind=="drop" and 1.95 or 0.95)+dy-compression,6*t)
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=state==200 or state==201
        m.state.board.deck={position=v(0,(kind=="drop" and 1 or 0)+dy,6*t),rotation={0,0,0,1}}
        m.state.board.velocity=v(0,vy,6)
        m.state.raycast=function(a,b) return world(a,b,kind=="drop") end
        m.fire("physics_step",{at=i*1000*dt,seconds=dt,velocity={0,vy,6},ragdoll=false})
        m.tick(1000*dt)
        out.max_rays=math.max(out.max_rays,m.state.raycasts)
        local shown=m.last_call("set")
        local g=app.glue
        if shown and g.source=="ride" and g.blend>=1 then
            local shot=g.frame.debug.shot_name
            if previous_shot and shot~=previous_shot then out.shot_changes+=1 end
            previous_shot=shot
            out.samples[#out.samples+1]={t=t,state=state,shot=shot,root=root,
                eye=shown.position,core=g.frame.pos,pitch=math.deg(math.asin(-shown.forward.y)),
                core_pitch=math.deg(math.asin(g.frame.back.y)),pull=g.frame.debug.collision_pull or 0,
                correction=g.body_correction or 0, free=g.frame.debug.camera_free, floor=g.frame.debug.collision_floor, hard=g.frame.debug.collision_hard, ret=g.cam.stable_return and g.cam.stable_return.offset.y, hold=g.cam.rider_hold}

        end
    end
    T.expect(app.errors==0 and out.max_rays<=64 and #out.samples>hz*2,
        kind.." App/Glue runs within ray budget at "..hz.." Hz")
    return out
end

local function measure(out,kind)
    local first,prior,max_core_step,max_shown_step,max_pitch_step,max_div=out.samples[1],nil,0,0,0,0
    local eye0,pitch0
    local flat_eye,flat_pitch,flat_at=0,0,0
    for _,p in out.samples do
        if p.t>0.8 and p.t<0.98 then eye0,pitch0=p.eye.y,p.pitch end
        if p.t>=1.12 and p.t<1.88 and eye0 then
            if math.abs(p.eye.y-eye0)>flat_eye then flat_eye,flat_at=math.abs(p.eye.y-eye0),p.t end
            flat_pitch=math.max(flat_pitch,math.abs(p.pitch-pitch0))
        end
        if prior and p.t>1.8 and p.t<2.6 then
            local core_rel=p.core-p.root
            local old_rel=prior.core-prior.root
            max_core_step=math.max(max_core_step,mag(core_rel-old_rel))
            max_shown_step=math.max(max_shown_step,mag((p.eye-p.root)-(prior.eye-prior.root)))
            max_pitch_step=math.max(max_pitch_step,math.abs(p.pitch-prior.pitch))
            max_div=math.max(max_div,mag(p.eye-p.core))
        end
        prior=p
    end
    return max_core_step,max_shown_step,max_pitch_step,max_div,flat_eye,flat_pitch,flat_at
end

for _,hz in {30,60,144} do
for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
    local flat=run("flat",hz,angle)
    local cs,ss,ps,div,eye,pitch,flat_at=measure(flat,"flat")
    print(string.format("stable flat %d Hz: eye %.3f at %.3f pitch %.2f coreStep %.3f shownStep %.3f div %.3f",hz,eye,flat_at,pitch,cs,ss,div))
    T.expect(eye<0.03 and pitch<0.5,"high flat Pop Off holds selected eye height and pitch at "..hz.." Hz")
    local drop=run("drop",hz,angle)
    cs,ss,ps,div=measure(drop,"drop")
    print(string.format("stable landing %d Hz: coreStep %.3f shownStep %.3f pitchStep %.2f div %.3f shots %d",hz,cs,ss,ps,div,drop.shot_changes))
    T.expect(drop.shot_changes>=2 and cs<0.18 and ss<0.18 and div<0.3,
        "delayed landing shot retains one continuous eye target at "..hz.." Hz")
    local crouched=run("flat",hz,angle,true)
    local baseline,settled,previous,maxstep
    maxstep=0
    for _,p in crouched.samples do
        if p.t>0.5 and p.t<0.58 then baseline=p.eye.y end
        if p.t>1.6 and p.t<1.8 then settled=p.eye.y end
        if previous and p.t>0.98 and p.t<1.5 then
            maxstep=math.max(maxstep,math.abs(p.eye.y-previous.eye.y))
        end
        previous=p
    end
    print("Crouch release",hz,angle,baseline,settled,maxstep)
    T.expect(baseline and settled and math.abs(settled-baseline)<0.05 and maxstep<0.12,
        "crouch release eases to neutral without following the high pop")
end
end
T.done()
if T.failures>0 then error("stable Classic regressions failed") end
