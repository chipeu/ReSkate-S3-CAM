-- Contracts of the 1.2.25 slope-landing repair: a trick landed on a descent keeps the eye behind the rider,
-- riding back into the ramp he left keeps that ramp's rules, and a walled-in slide holds its side.
local T,C,S,U,Orbit=require("tlib"),require("camera"),require("settings"),require("subject"),require("adaptive_orbit")
local v=vector.create
T.group("slope landing 1225")

local function settings(pop)
 local cs=S.defaults();cs.angle=S.CameraAngle.Low;cs.follow.trick_pop=pop;cs.follow.crouch_enabled=false
 cs.shoulder.mode=S.ShoulderSide.Off;cs.shake_enabled=false;cs.native_plus.landing_dip=false
 cs.ride_distance.mode=S.DistanceMode.Fixed;cs.ride_distance.fixed=1.53
 return cs
end

-- pose(t) gives position, velocity, state, ground normal, ground height.
local function drive(cs,height,pose,fps,seconds)
 local c=C.new();assert(c:set_settings(cs))
 local function query(a,b)
  local last=a.y-height(a.z)
  for j=1,48 do
   local f=j/48;local q=a+(b-a)*f;local nxt=q.y-height(q.z)
   if last>=0 and nxt<=0 then return q,v(0,1,0) end
   last=nxt
  end
 end
 local out={side=0,orbit=0,flips=0,up_after=false}
 local prev_side=0
 for i=1,math.floor(seconds*fps) do
  local t=i/fps
  local p,vel,state,normal,ground=pose(t)
  local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true
  s.physics_state=state;s.time=t;s.position=p;s.velocity=vel;s.physical_velocity=vel;s.physical_height=p.y
  s.forward=v(0,0,1);s.board_position=p-v(0,0.95,0)
  local air=state>=200 and state<300
  s.ground_valid=not air;s.ground_normal=normal;s.ground_height=ground;s.ground_clearance=p.y-ground
  local f=c:update(1/fps,s,query,{base_fov_deg=70})
  if t>0.5 then
   local side=c.ramp_side or 0
   out.side=math.max(out.side,math.abs(math.deg(side)))
   if side*prev_side<0 then out.flips+=1 end
   prev_side=side
   out.orbit=math.max(out.orbit,math.abs(math.deg(c.adaptive_orbit.yaw)))
   if air then out.touch=nil elseif out.touch==nil then out.touch=t end
   if out.touch and t<out.touch+0.4 and t>out.touch+0.1 then out.up_after=c.transition_up_seen==true end
   out.last=f
  end
 end
 return out,c
end

local G=10.1
local LAND=2.2
local function kicker_onto_hill(deg,launch_ramp)
 local grade=math.tan(math.rad(deg))
 local speed,pop=14,6
 local z_lip=speed*1.0
 local t_air=LAND
 local y_land=1.0+pop*t_air-0.5*G*t_air*t_air-0.95
 local z_land=z_lip+speed*t_air
 local function height(z)
  if z<=z_lip then return launch_ramp and math.max(0,(z-(z_lip-2.0))*1.2) or 0 end
  if z<z_land-6 then return -30 end
  if z<z_land+60 then return y_land-(z-z_land)*grade end
  return y_land-60*grade
 end
 local flat_n=v(0,1,0)
 local slope_n=vector.normalize(v(0,1,grade))
 local up_n=vector.normalize(v(0,1,-1.2))
 local function pose(t)
  if t<1.0 then
   local z=speed*t
   local on_ramp=launch_ramp and z>z_lip-2.0
   local g=height(z)
   return v(0,g+0.95,z),on_ramp and vector.normalize(v(0,1.2,1))*speed or v(0,0,speed),100,on_ramp and up_n or flat_n,g
  end
  local a=t-1.0
  if a<t_air then
   local z=z_lip+speed*a
   return v(0,height(z_lip)+0.95+pop*a-0.5*G*a*a,z),v(0,pop-G*a,speed),a<0.08 and 200 or 201,flat_n,height(z)
  end
  local r=(a-t_air)*(speed+3)
  local c,sn=math.cos(math.rad(deg)),math.sin(math.rad(deg))
  local dz,dy=r*c,r*sn
  return v(0,y_land-dy,z_land+dz)+slope_n*0.95,v(0,-sn,c)*(speed+3),100,slope_n,y_land-dy
 end
 return height,pose
end

for _,fps in {30,60,144} do
 local name=fps.." FPS "
 for _,pop in {false,true} do
  local tag=(pop and "pop on " or "pop off ")
  for _,deg in {30,42} do
   local height,pose=kicker_onto_hill(deg,false)
   local r,c=drive(settings(pop),height,pose,fps,7)
   T.expect(r.side<1,name..tag..deg.." degree landing does not slide sideways ("..string.format("%.1f",r.side)..")")
   T.expect(r.orbit<=25.5,name..tag..deg.." degree landing keeps the orbit at the trick angle ("..string.format("%.1f",r.orbit)..")")
  end
  local height,pose=kicker_onto_hill(35,true)
  local r=drive(settings(pop),height,pose,fps,7)
  T.expect(r.side<1,name..tag.."launching off a ramp onto a hill does not slide sideways ("..string.format("%.1f",r.side)..")")
  T.expect(not r.up_after,name..tag.."the hill is a new descent, not the ramp he left")
 end
end

do -- Riding back into the ramp he left keeps its rules.
 local radius=2 -- steep enough at the top of the ride to count as a transition
 local function height(z) return z<20 and 0 or math.min(40,(z-20)*(z-20)/(2*radius)) end
 local function steep_n(z) local d=(z-20)/radius;return vector.normalize(v(0,1,-d)) end
 local function pose(t)
  local cycle=1.5
  if t<1.5 then
   local z=20+1.6*math.min(t,1.5)
   return v(0,height(z)+0.95,z),vector.normalize(v(0,1.1,1))*6,100,steep_n(z),height(z)
  end
  local a=t-1.5
  if a<cycle then
   local z=22.4
   return v(0,height(z)+0.95+6*a-0.5*G*a*a,z),v(0,6-G*a,0.05),201,steep_n(z),height(z)
  end
  local r=(a-cycle)*1.6
  local z=math.max(20,22.4-r)
  return v(0,height(z)+0.95,z),vector.normalize(v(0,-1.1,-1))*6,100,steep_n(z),height(z)
 end
 local r=drive(settings(true),height,pose,60,4.5)
 T.expect(r.up_after,"a return into the same ramp is still that ramp")
end

do -- A rebase may bring the orbit in, never push it out.
 local function blocked() return v(0,1,0),v(0,1,0) end
 local st={}
 Orbit.reset(st)
 st.yaw,st.constrained=math.rad(25),true
 local cast=function(_,_,a,b) return blocked() end
 local close_eye=v(1.0,1.5,0.2)
 local anchor=v(0,1,0)
 local y=Orbit.solve(st,{},nil,cast,anchor,anchor,0,1.5,2,math.rad(25),0,0.2,nil,1/60,false,7,nil,close_eye)
 T.expect(math.abs(y)<=math.rad(25)+1e-6,"a pulled-in eye cannot read as a bigger orbit ("..string.format("%.1f",math.deg(y))..")")
 local st2={}
 Orbit.reset(st2)
 st2.yaw,st2.constrained=math.rad(-25),true
 local y2=Orbit.solve(st2,{},nil,cast,anchor,anchor,0,1.5,2,math.rad(-25),0,0.2,nil,1/60,false,7,nil,close_eye)
 T.expect(math.abs(y2)<=math.rad(25)+1e-6,"the bound holds on the other side and across centre")
end

do -- Walled in on every side with Pop On, the slide holds one side.
 local function height(z) return z<20 and 0 or (z-20)*1.5 end
 local c=C.new();assert(c:set_settings(settings(true)))
 local function query(a,b) local d=b-a;return a+d*0.02,v(0,1,0) end
 local flips,prev=0,0
 local n=vector.normalize(v(0,1,-1.5))
 for i=1,240 do
  local t=i/60;local z=20+t*2
  local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true
  s.physics_state=100;s.time=t;s.position=v(0,height(z),z)+n*0.95;s.velocity=vector.normalize(v(0,1.5,1))*3
  s.physical_velocity=s.velocity;s.physical_height=s.position.y;s.forward=v(0,0,1);s.board_position=s.position-n*0.95
  s.ground_valid=true;s.ground_normal=n;s.ground_height=height(z);s.ground_clearance=0.95
  c:update(1/60,s,query,{base_fov_deg=70})
  local side=c.ramp_side or 0
  if side*prev<0 then flips+=1 end
  if side~=0 then prev=side end
 end
 T.expect(flips<=1,"a walled-in slide does not keep changing sides ("..flips..")")
end

T.done()
if T.failures>0 then error("slope landing regression") end
