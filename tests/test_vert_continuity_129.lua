-- Full App/Glue regression: raw terrain classification cannot own the pose.
-- Hold measured blend identical while changing detector target/confidence.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("vert continuity 129")
local function drive(fps,target)
 local m=Mock.install({limit_rays=true})
 m.reskate.input.gamepad=function() return nil end
 m.reskate.menu.game=function() return {open=false} end
 local app=require("app").start()
 local cs=Settings.defaults()
 cs.follow.trick_pop=false;cs.follow.crouch_enabled=false
 cs.trick_yaw.enabled=false;cs.shoulder.mode=Settings.ShoulderSide.Off
 cs.shake_enabled=false;cs.native_plus.landing_dip=false
 cs.ride_distance.mode=Settings.DistanceMode.Fixed;cs.ride_distance.fixed=1.53
 assert(app.store:set_settings(cs))
 local t=0
 app.glue.cam.terrain_context.update=function()
  local u=t-1.3
  local w=0
  if u>=0 and u<0.6 then w=0.5-0.5*math.cos(math.pi*u/0.6)
  elseif u>=0.6 and u<1.1 then w=1
  elseif u>=1.1 and u<1.7 then w=0.5+0.5*math.cos(math.pi*(u-1.1)/0.6) end
  return {weight=w,target=target,reason="transition",confidence=target,rays=0}
 end
 local out={rows={},errors=0,peak_pitch=0,peak_eye=0,full=0,flight=nil,changed=0}
 local prev
 for i=1,math.floor(4.5*fps) do
  t=i/fps
  local u=t-1.2
  local air=u>=0 and u<2
  local dy=air and 2*math.sin(math.pi*u/2) or 0
  local vy=air and math.pi*math.cos(math.pi*u/2) or 0
  local root=v(0,0.95+dy,6*t)
  m.state.skater.position=root
  m.state.telemetry.physics_state=air and (u<0.08 and 200 or 201) or 100
  m.state.telemetry.airborne=air
  m.state.board.deck={position=root-v(0,0.95,0),rotation={0,0,0,1}}
  m.state.board.velocity=v(0,vy,6)
  m.state.raycast=function(a,b)
   if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),v(0,1,0) end
  end
  m.fire("physics_step",{at=m.clock_ms+1000/fps,seconds=1/fps,velocity={0,vy,6},ragdoll=false})
  m.tick(1000/fps)
  local shown=m.last_call("set")
  if shown and app.glue.source=="ride" and app.glue.blend>=1 then
   local pitch=math.deg(math.asin(shown.forward.y))
   out.rows[i]={pos=shown.position,forward=shown.forward,fov=shown.fov}
   if air and app.glue.cam.pop_w==1 then out.full+=1 end
   if air and app.glue.cam.pop_flight then
    if out.flight and out.flight~=app.glue.cam.pop_flight then out.changed+=1 end
    out.flight=app.glue.cam.pop_flight
   end
   if prev and air and prev.air then
    out.peak_pitch=math.max(out.peak_pitch,math.abs(pitch-prev.pitch))
    out.peak_eye=math.max(out.peak_eye,mag((shown.position-root)-prev.relative))
   end
   prev={air=air,pitch=pitch,relative=shown.position-root}
  end
 end
 out.errors=app.errors
 T.expect(app.store.settings.follow.trick_pop==false,"terrain cannot rewrite saved Pop Off")
 return out
end
for _,fps in {30,60,144} do
 local a,b=drive(fps,0),drive(fps,1)
 local eye,aim,n=0,0,0
 for i,x in a.rows do
  local y=b.rows[i]
  if y then
   eye=math.max(eye,mag(x.pos-y.pos));aim=math.max(aim,mag(x.forward-y.forward));n+=1
  end
 end
 print("terrain target ownership",fps,"samples",n,"eye",eye,"aim",aim,"pitchStep",a.peak_pitch,"relativeStep",a.peak_eye)
 T.expect(n>fps*2 and eye<1e-5 and aim<1e-5,"detector target cannot switch reference/aim ownership at fixed blend")
 T.expect(a.full>0 and b.full>0,"fixture includes full normal terrain follow and exit")
 T.expect(a.changed==0 and b.changed==0,"one flight reference survives full-follow entry/exit")
 T.expect(a.peak_pitch<150/fps and b.peak_pitch<150/fps,"vert pitch changes remain bounded at full-follow handoff")
 T.expect(a.peak_eye<12/fps and b.peak_eye<12/fps,"vert eye moves continuously relative to physical rider")
 T.expect(a.errors==0 and b.errors==0,"no App/Glue errors")
end
T.done()
if T.failures>0 then error("vert continuity regressions failed") end
