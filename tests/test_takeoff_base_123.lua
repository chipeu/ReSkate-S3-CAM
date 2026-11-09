local T,C,S,U=require("tlib"),require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("takeoff base 123")
local function drive(fps,enabled,mode,corrected)
 local set=S.defaults();set.follow.trick_pop=false;set.follow.crouch_enabled=enabled;set.follow.crouch_mode=mode;set.follow.crouch_amount=1
 set.shake_enabled=false;set.native_plus.landing_dip=false;set.collision.enabled=false;set.shoulder.mode=S.ShoulderSide.Off;set.trick_yaw.enabled=false
 local c=C.new();assert(c:set_settings(set));local frame,s
 local function snapshot(t,air)
  local q=U.new_snapshot();q.valid=true;q.onboard=true;q.board_valid=true;q.ground_valid=not air;q.physics_state=air and 201 or 100
  q.time=t;q.position=v(0,0.95+8*t,8*t);q.velocity=v(0,8,8);q.physical_velocity=q.velocity;q.physical_height=q.position.y
  q.forward=v(0,0,1);q.board_position=q.position-v(0,0.95,0);q.ground_height=q.position.y-0.95;q.ground_clearance=0.95;q.ground_normal=vector.normalize(v(0,1,-1))
  return q
 end
 for i=1,2*fps do s=snapshot(i/fps,false);frame=c:update(1/fps,s,function()return nil end,{base_fov_deg=65}) end
 local root=s.position;local eye=frame.pos;local offset=eye-root
 local seed={valid=true,world_position=eye,root=root,guard_subject_y=root.y,physics_height=root.y,board_y=root.y-0.95,
  fov=65,reach=math.sqrt(offset.x*offset.x+offset.z*offset.z),forward=corrected and v(0,math.sin(math.rad(-35)),math.cos(math.rad(-35))) or -frame.back}
 local views={}
 for i=1,math.ceil(0.15*fps) do
  s=snapshot(2+i/fps,true);frame=c:update(1/fps,s,function()return nil end,{base_fov_deg=65,pop_seed=seed})
  views[#views+1]=frame.back
 end
 return views
end
for _,fps in {30,60,144} do
 for _,cfg in {{false,0},{true,0},{true,1}} do
  local a,b=drive(fps,cfg[1],cfg[2],false),drive(fps,cfg[1],cfg[2],true)
  local worst=0
  for i,p in a do worst=math.max(worst,vector.magnitude(p-b[i])) end
  print("base seed",fps,cfg[1],cfg[2],worst)
  T.expect(worst<1e-5,"a composed floor-corrected display seed cannot retarget the base aim")
 end
end
T.done()
if T.failures>0 then error("takeoff ownership regression") end
