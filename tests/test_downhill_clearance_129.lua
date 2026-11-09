local T,C,S,U=require("tlib"),require("camera"),require("settings"),require("subject")
local v,mag=vector.create,vector.magnitude
T.group("downhill clearance 129")
for _,fps in {30,60,144} do
 for _,pop in {false,true} do
  for _,angle in {S.CameraAngle.Low,S.CameraAngle.High} do
   local cs=S.defaults();cs.angle=angle;cs.follow.trick_pop=pop;cs.follow.crouch_enabled=false
   cs.trick_yaw.enabled=false;cs.shoulder.mode=S.ShoulderSide.Off
   cs.shake_enabled=false;cs.native_plus.landing_dip=false
   cs.ride_distance.mode=S.DistanceMode.Fixed;cs.ride_distance.fixed=1.53
   cs.ride_distance_high.mode=S.DistanceMode.Fixed;cs.ride_distance_high.fixed=1.53
   local c=C.new();assert(c:set_settings(cs))
   local slope=-0.45;local normal=vector.normalize(v(0,1,-slope))
   local gap=100;local maxlift=0;local n=0
   local function query(a,b)
    local da,db=a.y-slope*a.z,b.y-slope*b.z
    if da>=0 and db<=0 and da~=db then return a+(b-a)*(da/(da-db)),normal end
   end
   for i=1,5*fps do
    local t=i/fps;local z=7*t
    local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true;s.ground_valid=true
    s.physics_state=100;s.time=t;s.position=v(0,0.95+slope*z,z);s.velocity=v(0,7*slope,7)
    s.physical_velocity=s.velocity;s.physical_height=s.position.y;s.forward=v(0,0,1)
    s.board_position=s.position-v(0,0.95,0);s.ground_normal=normal;s.ground_height=slope*z;s.ground_clearance=0.95
    local f=c:update(1/fps,s,query,{base_fov_deg=70})
    if t>4 then
     n+=1;gap=math.min(gap,f.pos.y-slope*f.pos.z)
     maxlift=math.max(maxlift,math.deg(f.debug.downhill_lift))
    end
   end
   print("downhill129",fps,pop,angle,"lift",maxlift,"gap",gap)
   T.expect(n>0 and gap>=0.29,"downhill eye retains automatic floor clearance")
   T.expect(maxlift<(angle==S.CameraAngle.Low and 10 or 2),"only the lift needed above measured support is applied")
   if angle==S.CameraAngle.Low then T.expect(gap<0.4,"low eye stays near clearance instead of parallel-to-grade excess lift") end
  end
 end
end
T.done()
if T.failures>0 then error("downhill clearance regression") end
