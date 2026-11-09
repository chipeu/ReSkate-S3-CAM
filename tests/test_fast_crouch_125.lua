local T,M,S,P=require("tlib"),require("mock_reskate"),require("settings"),require("presets")
local v=vector.create
T.group("fast crouch 125")
for _,fps in {30,60,144} do
 for _,angle in {S.CameraAngle.Low,S.CameraAngle.High} do
  local m=M.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end
  local app=require("app").start();local cs,opts=P.from_values(require("user_values_121"))
  cs.angle=angle;cs.follow.trick_pop=true;cs.follow.crouch_enabled=true;cs.follow.crouch_amount=1
  cs.shake_enabled=false;cs.native_plus.landing_dip=false;assert(app.store:set_settings(cs));app.store:set_options(opts)
  local epoch=m.clock_ms;local phys=0;local correction,turn,fov_step,floor_depth=0,0,0,0;local previous
  for i=1,7*fps do
   local t=i/fps;local u=math.clamp((t-2)/0.3,0,1);local compression=t>2 and t<2.3 and 0.5*math.sin(math.pi*u)^2 or 0
   m.state.skater.position=v(0,0.95-compression,t);m.state.telemetry.physics_state=compression>0 and 103 or 100
   m.state.telemetry.airborne=false;m.state.board.deck={position=v(0,0,t),rotation={0,0,0,1}};m.state.board.velocity=v(0,0,1)
   m.state.raycast=function(a,b)if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(-a.y/(b.y-a.y)),v(0,1,0) end end
   while phys+1/60<=t+1e-8 do phys+=1/60;m.fire("physics_step",{at=epoch+phys*1000,seconds=1/60,velocity={0,0,1},ragdoll=false}) end
   m.tick(1000/fps);local shown=m.last_call("set")
   if shown and app.glue.blend>=1 and t>1 then
    local pitch=math.deg(math.asin(shown.forward.y));local fov=shown.fov or 65
    correction=math.max(correction,app.glue.body_correction or 0)
    floor_depth=math.max(floor_depth,0.299-shown.position.y)
    if previous then turn=math.max(turn,math.abs(pitch-previous.pitch));fov_step=math.max(fov_step,math.abs(fov-previous.fov)) end
    previous={pitch=pitch,fov=fov}
   end
  end
  print("crouch122",fps,angle,"correction",correction,"pitch step",turn,"fov step",fov_step)
  T.expect(app.errors==0,"full crouch has no runtime error")
  T.expect(correction<0.05,"full crouch does not need repeated late floor raises")
  T.expect(turn<3 and fov_step<0.01,"full crouch stays smooth without lens changes")
  T.expect(floor_depth<1e-5,"full crouch keeps ground clearance")
 end
end
T.done()
if T.failures>0 then error("full crouch floor regression") end
