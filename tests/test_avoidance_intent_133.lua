local T,C,S,U,A=require("tlib"),require("camera"),require("settings"),require("subject"),require("adaptive_orbit")
local v=vector.create
T.group("avoidance intent 133")
local original=A.solve
local function drive(disturb)
 local ahead={}
 A.solve=function(...)
  local a={...};ahead[#ahead+1]=a[13]
  return a[10],a[11]
 end
 local set=S.defaults();set.shoulder.mode=S.ShoulderSide.Manual;set.shoulder.offset=0.45
 set.shake_enabled=false;set.native_plus.landing_dip=false
 local c=C.new();assert(c:set_settings(set))
 for i=1,240 do
  local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true;s.ground_valid=true
  s.physics_state=100;s.time=i/60;s.position=v(0,0.95+i*5/60,i*5/60);s.velocity=v(0,5,5)
  s.physical_velocity=s.velocity;s.physical_height=s.position.y;s.board_position=s.position-v(0,0.95,0)
  s.forward=v(0,0,1);s.ground_height=s.position.y-0.95;s.ground_normal=vector.normalize(v(0,1,-1));s.ground_clearance=0.95
  c:update(1/60,s,function()return nil end,{base_fov_deg=70})
  if disturb then
   -- Prior output corrections are observations, not a requested movement.
   c.curr_out.pos+=v((i%2==0 and 1 or -1)*0.4,-0.2,0)
  end
 end
 A.solve=original
 return ahead
end
local a,b=drive(false),drive(true)
local peak=0
for i=120,math.min(#a,#b) do peak=math.max(peak,vector.magnitude(a[i]-b[i])) end
print("output disturbances change predicted intent by",peak)
T.expect(#a>200 and #b==#a,"predictor exercised every riding step")
T.expect(peak<1e-4,"collision/dip output cannot feed the next requested clearance prediction")
T.done()
if T.failures>0 then error("avoidance intent regression") end
