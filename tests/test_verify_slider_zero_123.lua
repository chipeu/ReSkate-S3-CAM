-- A clean body-only oracle for Crouch Off through displayed App/Glue output.
-- The board and ground do not move while only the skater animation lowers.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v=vector.create
T.group("crouch_display_123")
local function drop_at(t)
    if t<1 then return 0 end
    if t<1.25 then return 0.3*(t-1)/0.25 end
    if t<2 then return 0.3 end
    if t<2.25 then return 0.3*(1-(t-2)/0.25) end
    if t<2.5 then return -0.08*math.sin(math.pi*(t-2.25)/0.25) end
    return 0
end
local function drive(fps,angle,animated)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local s=Settings.defaults()
    s.angle=angle
    s.follow.crouch_enabled=true
    s.follow.crouch_amount=0 -- Verify zero strength independently of the toggle
    s.follow.trick_pop=true
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.5
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,1.5
    s.shake_enabled=false
    s.native_plus.landing_dip=false
    s.collision.enabled=false
    s.points.floor_clearance=0
    assert(app.store:set_settings(s))
    local out={samples={},frames=0,manual=false,max_rays=0}
    for i=1,math.floor(3.5*fps) do
        local t=i/fps
        local drop=animated and drop_at(t) or 0
        local state=t>=1.2 and t<2 and 103 or 100
        local root=v(0,0.95-drop,0)
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=false
        m.state.board.deck={position=v(0,0,0),rotation={x=0,y=0,z=0,w=1}}
        m.state.board.velocity=v(0,0,0)
        m.state.ground_y=0
        m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,0,0},ragdoll=false})
        m.tick(1000/fps)
        out.max_rays=math.max(out.max_rays,m.state.raycasts)
        local shown=m.last_call("set")
        if shown and app.glue.source=="ride" and app.glue.blend>=1 then
            out.samples[i]={t=t,pos=shown.position,pitch=math.deg(math.asin(-shown.forward.y)),state=state}
            out.frames+=1
            out.manual=out.manual or app.glue.snap.manual
        end
    end
    T.expect(app.errors==0 and not out.manual and out.max_rays<=64,"flat body-only fixture displays without callback, manual or ray errors")
    return out
end
for _,fps in {30,60,144} do
    for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
        local a,b=drive(fps,angle,true),drive(fps,angle,false)
        local eye,aim,frames=0,0,0
        for i,p in a.samples do
            local q=b.samples[i]
            if q and p.t>=1.1 and p.t<=3 then
                eye=math.max(eye,math.abs(p.pos.y-q.pos.y))
                aim=math.max(aim,math.abs(p.pitch-q.pitch))
                frames+=1
            end
        end
        print(string.format("flat Crouch Off %d fps angle %s: world eye %.4f m, aim %.3f deg, %d matched frames",
            fps,tostring(angle),eye,aim,frames))
        T.expect(frames>fps,"flat body-only animation is shown in both runs")
        T.expect(eye<0.01 and aim<0.5,"Crouch Off rejects body-only lowering and rebound in shown camera")
    end
end
T.done()
if T.failures>0 then error("crouch display tests failed") end
