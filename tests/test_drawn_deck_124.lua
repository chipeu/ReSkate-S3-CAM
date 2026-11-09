-- The board API's place/deck is a drawn bone. Its vertical trick animation
-- cannot be a Pop Off flight datum when physics velocity and terrain agree.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("drawn_deck_124")
local function plane(a,b)
    if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),v(0,1,0) end
end
local function ride(animated,angle,jitter,effects)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local s=Settings.defaults()
    s.angle=angle;s.follow.trick_pop=false;s.follow.pop_amount=1
    s.follow.crouch_enabled=false;s.follow.crouch_amount=1
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.53
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.40
    s.shake_enabled=effects;s.native_plus.landing_dip=effects
    assert(app.store:set_settings(s))
    local trace_case=jitter and animated and effects and angle==Settings.CameraAngle.Low
    if trace_case then app.store.options.verbose=true end
    local out={}
    local queued=0
    for i=1,240 do
        local t=i/60
        local u=t-1.0
        local state=t<0.6 and 100 or t<1.0 and 103 or t<1.10 and 200 or t<1.85 and 201 or 100
        local flight=(state==200 or state==201) and math.max(0,2.1*u-2.8*u*u) or 0
        local vy=(state==200 or state==201) and 2.1-5.6*u or 0
        local crouch=t>=0.6 and t<1.1 and 0.23 or 0
        local root=v(0,0.95+flight-crouch,6*t)
        local visual=animated and (state==200 or state==201) and 0.24*math.sin(21*t) or 0
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=state==200 or state==201
        m.state.board.deck={position=v(0,flight+visual,6*t),rotation={0,0,0,1}}
        m.state.board.velocity=v(0,vy,6)
        m.state.raycast=plane
        m.fire("physics_step",{at=i*1000/60,seconds=1/60,velocity={0,vy,6},ragdoll=false})
        queued+=1
        if jitter and (i%17==0 or i%17==1) then continue end
        m.tick(queued*1000/60)
        queued=0
        local shown=m.last_call("set")
        if shown and app.glue.source=="ride" and app.glue.blend>=1 then
            out[i]={pos=shown.position,pitch=math.deg(math.asin(-shown.forward.y)),
                state=state,rays=m.state.raycasts}
        end
    end
    T.expect(app.errors==0,"drawn-deck fixture runs without errors")
    if trace_case then
        local legacy,rows=0,0
        for _,entry in m.logs do
            if string.find(entry[2],"s3cam trace",1,true) then legacy+=1 end
            if string.find(entry[2],"motion128",1,true)
                and string.find(entry[2],"dtMax=",1,true)
                and string.find(entry[2],"corrMax=",1,true) then rows+=1 end
        end
        T.expect(legacy==0 and rows>=1 and rows<=4,
            "compact trace records timing/correction peaks without render-cadence dumps")
    end
    return out
end
for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
for _,jitter in {false,true} do
for _,effects in {false,true} do
    local base,drawn=ride(false,angle,jitter,effects),ride(true,angle,jitter,effects)
    local eye,aim,frames=0,0,0
    for i,a in pairs(base) do
        local b=drawn[i]
        if b and i>90 and i<180 then
            eye=math.max(eye,mag(a.pos-b.pos))
            aim=math.max(aim,math.abs(a.pitch-b.pitch))
            frames+=1
        end
    end
    print(string.format("drawn deck angle %d jitter %s effects %s: eye %.3f m aim %.2f deg, %d frames",angle,tostring(jitter),tostring(effects),eye,aim,frames))
    T.expect(frames>65 and eye<0.04 and aim<0.5,
        "drawn deck vertical animation does not steer Pop Off framing")
end
end
end
T.done()
