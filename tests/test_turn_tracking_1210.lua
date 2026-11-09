local T=require("tlib")
T.group("turn tracking 1210")
local Mock,S=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
for _,fps in {30,60,144} do
 for _,pop in {false,true} do
  local m=Mock.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end;m.reskate.menu.game=function()return {open=false} end
  local app=require("app").start();local s=S.defaults();s.follow.trick_pop=pop;s.follow.crouch_enabled=false;s.shake_enabled=false;s.native_plus.landing_dip=false;s.trick_yaw.enabled=false
  s.ride_distance.mode=S.DistanceMode.Fixed;s.ride_distance.fixed=1.53
  app.store:set_settings(s)
  local pos=v(0,0.95,0);local epoch=m.clock_ms;local n0=0;local minimum=100;local framed,n=0,0;local peak=0;local prior
  for i=1,7*fps do
   local t=i/fps;local h=math.pi*math.clamp((t-2)/1.2,0,1);local velocity=v(6*math.sin(h),0,6*math.cos(h));pos+=velocity/fps
   m.state.skater.position=pos;m.state.skater.heading=h;m.state.joints[103]=pos+v(0.2*math.sin(h),0.8,0);m.state.joints[7]=pos
   m.state.telemetry.physics_state=100;m.state.board.deck={position=pos-v(0,0.95,0),rotation={0,0,0,1}};m.state.board.velocity=velocity
   local seq=math.floor(t*60+1e-7)
   for j=n0+1,seq do m.fire("physics_step",{at=epoch+j*1000/60,seconds=1/60,velocity={velocity.x,velocity.y,velocity.z},ragdoll=false}) end
   n0=seq;m.tick(1000/fps)
   local shown=m.last_call("set")
   if t>1.8 and shown then
    minimum=math.min(minimum,mag(shown.position-pos));local inside=true
    local right=vector.normalize(vector.cross(shown.forward,shown.up))
    for _,p in {m.state.joints[103],pos-v(0,0.95,0)} do
     local ray=p-shown.position;local depth=vector.dot(ray,shown.forward)
     if depth<=0 or math.abs(vector.dot(ray,shown.up))/depth>math.tan(math.rad(shown.fov*0.49)) or math.abs(vector.dot(ray,right))/depth>math.tan(math.rad(shown.fov*0.49))*16/9 then inside=false end
    end
    if inside then framed+=1 end;n+=1
    local rel=shown.position-pos
    if prior then peak=math.max(peak,mag(rel-prior)) end;prior=rel
   end
  end
  print("TURN",fps,pop,"min",minimum,"framed",framed,n,"step",peak,"errors",app.errors)
  T.expect(minimum>1.4 and framed==n,"180 degree travel turn keeps joints framed and skater outside eye")
  T.expect(peak<2/fps and app.errors==0,"responsive turn stays continuous without camera snaps")
 end
end

T.done()
if T.failures>0 then error("turn tracking regression") end
