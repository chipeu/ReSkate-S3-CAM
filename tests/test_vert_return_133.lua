local T,C,S,U=require("tlib"),require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("vert return 133")
for _,fps in {30,60,144} do
 for _,strength in {0,2,10} do
  local set=S.defaults();set.follow.trick_pop=false;set.follow.crouch_enabled=false
  set.follow.horizontal=strength;set.trick_yaw.enabled=false;set.shake_enabled=false;set.native_plus.landing_dip=false
  set.ride_distance.mode=S.DistanceMode.Fixed;set.ride_distance.fixed=1.53
  local c=C.new();assert(c:set_settings(set));local released=false;local smallest=100;local ret=0
  for i=1,math.floor(3.35*fps) do
   local t=i/fps;local u=t-1;local p,vel,state
   if t<1 then p=v(0,0.95+8*t,8*t);vel=v(0,8,8);state=100
   else p=v(0,8.95+12*u-5*u*u,8+4*math.sin(math.pi*u/2));vel=v(0,12-10*u,2*math.pi*math.cos(math.pi*u/2));state=201 end
   local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true;s.ground_valid=state==100
   s.physics_state=state;s.time=t;s.position=p;s.velocity=vel;s.physical_velocity=vel;s.physical_height=p.y
   s.board_position=p-v(0,0.95,0);s.forward=v(0,0,1);s.ground_normal=vector.normalize(v(0,1,-1))
   s.ground_height=p.y-0.95;s.ground_clearance=0.95
   local frame=c:update(1/fps,s,function()return nil end,{base_fov_deg=70})
   if t>2.7 then
    ret+=1;released=released or not c.transition_hold
    smallest=math.min(smallest,vector.magnitude(frame.pos-p))
   end
  end
  print("return",fps,strength,"released",released,"min span",smallest,"heading error",math.deg(math.abs(require("s3math").wrap_angle(c.swing_target-c.last_view_heading))))
  T.expect(ret>0 and released,"confirmed horizontal fakie releases ascent hold before touchdown")
  T.expect(smallest>0.85,"return orbit stays outside the rider")
  T.expect(math.abs(require("s3math").wrap_angle(c.swing_target-c.last_view_heading))<math.rad(30),"return view recentres toward reverse line before landing even with low turn strength")
 end
end
T.done()
if T.failures>0 then error("vert return regression") end
