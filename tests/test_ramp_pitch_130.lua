local T,Camera,Settings,Subject=require("tlib"),require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("ramp pitch 130")
for _,fps in {30,60,144} do
 local s=Settings.defaults();s.follow.trick_pop=false;s.follow.crouch_enabled=false
 s.shake_enabled=false;s.native_plus.landing_dip=false;s.trick_yaw.enabled=false
 local cam=Camera.new();assert(cam:set_settings(s))
 local previous,peak=nil,0
 local frames=0
 for i=1,4*fps do
  local t=i/fps;local normal=vector.normalize(v(0,1,1+0.35*math.sin(t*16)))
  local snap=Subject.new_snapshot()
  snap.valid,snap.onboard,snap.board_valid,snap.ground_valid=true,true,true,true
  snap.physics_state=100;snap.time=t;snap.position=v(0,0.95-12*t,12*t)
  snap.board_position=snap.position-v(0,0.95,0);snap.velocity=v(0,-12,12)
  snap.physical_velocity=snap.velocity;snap.physical_height=snap.position.y
  snap.forward=v(0,0,1);snap.ground_normal=normal;snap.ground_height=snap.position.y-0.95;snap.ground_clearance=0.95
  local frame=cam:update(1/fps,snap,function() return nil end,{base_fov_deg=65})
  local pitch=math.deg(math.asin(-frame.back.y))
  if previous and t>1.5 then peak=math.max(peak,math.abs(pitch-previous));frames+=1 end
  previous=pitch
 end
 print("ramp pitch combined",fps,"peak step",peak)
 T.expect(frames>fps and peak<120/fps+0.02,"ramp aim and framing guard share one pitch movement budget")
end
T.done()
if T.failures>0 then error("ramp pitch regression") end
