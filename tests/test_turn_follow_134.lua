local T,C,S,U=require("tlib"),require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("turn follow 134")
for _,fps in {30,60,144} do
for _,amount in {2,5,10} do
 local headings={}
 for _,responsiveness in {0.2,4} do
  local set=S.defaults();set.follow.horizontal=amount;set.follow.strength=responsiveness
  set.follow.trick_pop=false;set.follow.crouch_enabled=false;set.shake_enabled=false;set.trick_yaw.enabled=false
  local c=C.new();assert(c:set_settings(set));local sampled={};local initial_air;local position=v(0,0.95,0)
  for i=1,4*fps do
   local t=i/fps;local air=i>2*fps and i<3*fps
   local angle=i<fps and 0 or math.rad(35)
   local vel=v(math.sin(angle)*7,0,math.cos(angle)*7)
   local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true;s.ground_valid=not air
   s.physics_state=air and 201 or 100;s.time=t;position+=vel/fps;s.position=position
   s.velocity=vel;s.physical_velocity=vel;s.physical_height=0.95
   local flip=air and t*25 or 0;s.forward=v(math.sin(flip),0,math.cos(flip))
   s.board_position=s.position+v(air and math.sin(flip)*0.4 or 0,-0.95,0)
   s.ground_normal=v(0,1,0);s.ground_height=0;s.ground_clearance=0.95
   c:update(1/fps,s,function()return nil end,{base_fov_deg=70})
   if i>fps+1 and i<1.9*fps then sampled[#sampled+1]=c.last_view_heading end
   if i==2*fps+1 then initial_air=c.last_view_heading end
   if i>2*fps+1 and i<3*fps-1 then T.expect_near(c.last_view_heading,initial_air,1e-5,"flip pose cannot steer the travel-follow heading") end
   if amount==10 and i>fps+1 and i<1.9*fps then T.expect_near(c.last_view_heading,require("s3math").wrap_angle(-angle+c.current.position_heading),1e-5,"10 directly chases cruising travel heading") end
  end
  headings[#headings+1]=sampled
 end
 for i,h in headings[1] do T.expect_near(h,headings[2][i],1e-5,"general responsiveness cannot rescale cruising turn response") end
end
end
T.done()
if T.failures>0 then error("turn follow regression") end
