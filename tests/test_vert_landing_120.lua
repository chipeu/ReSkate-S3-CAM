local T,C,S,U=require("tlib"),require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("vert landing 120")
for _,fps in {30,60,144} do
 for _,duration in {0.2,0.4,1.6} do
 for _,downhill in {false,true} do
  local set=S.defaults();set.follow.trick_pop=false;set.follow.crouch_enabled=false
  set.follow.horizontal=10;set.shake_enabled=false;set.native_plus.landing_dip=false;set.trick_yaw.enabled=false
  set.ride_distance.mode=S.DistanceMode.Fixed;set.ride_distance.fixed=1.53
  local c=C.new();assert(c:set_settings(set));local prior_rise;local bump=0;local had_return=false
  local final_heading=100;local landed=0;local recovery=nil
  for i=1,math.floor((3+duration)*fps) do
   local t=i/fps;local u=t-1;local p,vel,state,normal
   if u<0 then p=v(0,0.95+8*t,8*t);vel=v(0,8,8);state=100;normal=vector.normalize(v(0,1,-1))
   elseif u<duration then
    p=v(0,8.95+4*math.sin(math.pi*u/duration),8+8*duration/math.pi*math.sin(math.pi*u/duration))
    vel=v(0,4*math.pi/duration*math.cos(math.pi*u/duration),8*math.cos(math.pi*u/duration))
    state=201;normal=vector.normalize(v(0,1,-1))
   else
    local g=u-duration;local slope=downhill and g<0.8
    p=v(0,8.95-(downhill and 6*math.min(g,0.8) or 0),8-8*g)
    vel=v(0,slope and -6 or 0,-8);state=100;normal=slope and vector.normalize(v(0,1,-0.75)) or v(0,1,0)
   end
   local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true;s.ground_valid=state==100
   s.physics_state=state;s.time=t;s.position=p;s.velocity=vel;s.physical_velocity=vel;s.physical_height=p.y
   s.board_position=p-v(0,0.95,0);s.forward=v(0,0,1);s.ground_normal=normal;s.ground_height=p.y-0.95;s.ground_clearance=0.95
   local frame=c:update(1/fps,s,function()return nil end,{base_fov_deg=70})
   if u>=duration then
    landed+=1
    local rel=frame.pos-p
    local bearing=math.abs(require("s3math").wrap_angle(math.atan2(-rel.x,rel.z)))
    if bearing<math.rad(15) and not recovery then recovery=u-duration end
    local rise=c.layers.air_rise or 0
    if prior_rise then bump=math.max(bump,rise-prior_rise) end
    prior_rise=rise
    final_heading=math.abs(require("s3math").wrap_angle(c.last_view_heading-(math.pi+c.current.position_heading)))
   end
  end
  print("landing",fps,duration,downhill,"rise increase",math.deg(bump),"heading error",math.deg(final_heading),"actual recovery",recovery)
  T.expect(landed>fps and recovery and recovery<0.9,"actual eye recentres behind rider within landing recovery window")
  T.expect(bump<1e-5,"no new air-elevation build after touchdown")
  T.expect(final_heading<math.rad(10),"landed camera returns behind travel")
 end
end
end
T.done()
if T.failures>0 then error("vert landing regression") end
