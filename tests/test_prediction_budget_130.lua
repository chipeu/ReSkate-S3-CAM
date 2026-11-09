local T,Camera,Settings,Subject=require("tlib"),require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("prediction budget 130")
for _,fps in {30,60,144} do
 local settings=Settings.defaults()
 settings.follow.trick_pop=false;settings.follow.crouch_enabled=false
 settings.trick_yaw.enabled=false;settings.shake_enabled=false;settings.native_plus.landing_dip=false
 settings.trajectory.step=0.1
 local cam=Camera.new();assert(cam:set_settings(settings))
 local landed,max_rays,deferred=0,0,0
 local left=60
 local extras={base_fov_deg=65,query_remaining=function() return math.max(0,left-8) end}
 local function query(a,b)
  left-=1
  T.expect(left>=0,"budgeted prediction never consumes all collision headroom")
  if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),v(0,1,0) end
 end
 for i=1,4*fps do
  local t=i/fps;local u=t-1.5;local air=u>=0 and u<1
  local y=0.95+(air and 2*math.sin(math.pi*u) or 0)
  local vy=air and 2*math.pi*math.cos(math.pi*u) or 0
  local snap=Subject.new_snapshot()
  snap.valid,snap.onboard,snap.board_valid,snap.ground_valid=true,true,true,true
  snap.physics_state=air and 201 or 100;snap.time=t
  snap.position=v(0,y,6*t);snap.board_position=snap.position-v(0,0.95,0)
  snap.velocity=v(0,vy,6);snap.physical_velocity=snap.velocity;snap.physical_height=y
  snap.forward=v(0,0,1);snap.ground_normal=v(0,1,0);snap.ground_height=0;snap.ground_clearance=y
  left=60
  local frame=cam:update(1/fps,snap,query,extras)
  T.expect(frame.valid,"camera remains valid under prediction budget")
  max_rays=math.max(max_rays,60-left)
  if air and cam.prediction.status=="Landed" then landed+=1 end
  if cam.prediction_deferred then deferred+=1 end
 end
 print("prediction headroom",fps,"landed",landed,"max rays",max_rays,"deferred",deferred)
 T.expect(landed>fps/4,"30fps multi-step updates still obtain landing predictions")
 T.expect(max_rays<=52,"search retains SDK space for final presentation")
 T.expect(settings.trajectory.max_time==3 and cam.settings.trajectory.max_time==3,"budget never changes saved search horizon")
end
T.done()
if T.failures>0 then error("prediction budget regressions") end
