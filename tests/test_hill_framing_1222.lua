-- Contracts of the 1.2.22 hill repair: the eye rises before a crest, the slope look does not stack
-- on the clearance lift, and neither a ledge nor a small roller is mistaken for a hill.
local T,C,S,U=require("tlib"),require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("hill framing 1222")

local function drive(height,fps,seconds,speed)
 local cs=S.defaults();cs.angle=S.CameraAngle.Low;cs.follow.trick_pop=false;cs.follow.crouch_enabled=false
 cs.trick_yaw.enabled=false;cs.shoulder.mode=S.ShoulderSide.Off;cs.shake_enabled=false;cs.native_plus.landing_dip=false
 cs.ride_distance.mode=S.DistanceMode.Fixed;cs.ride_distance.fixed=1.53
 local c=C.new();assert(c:set_settings(cs))
 local function query(a,b)
  local last=a.y-height(a.z)
  for j=1,48 do
   local f=j/48;local q=a+(b-a)*f;local nxt=q.y-height(q.z)
   if last>=0 and nxt<=0 then return q,v(0,1,0) end
   last=nxt
  end
 end
 local out={pull=0,lift_before=0,look=0,seen=false,steady_look=0}
 for i=1,math.floor(seconds*fps) do
  local t=i/fps;local z=speed*t
  local dy=(height(z+0.05)-height(z-0.05))/0.1
  local normal=vector.normalize(v(0,1,-dy))
  local s=U.new_snapshot();s.valid=true;s.onboard=true;s.board_valid=true;s.ground_valid=true
  s.physics_state=100;s.time=t;s.position=v(0,height(z),z)+normal*0.95;s.velocity=v(0,dy*speed,speed)
  s.physical_velocity=s.velocity;s.physical_height=s.position.y;s.forward=v(0,0,1)
  s.board_position=s.position-normal*0.95;s.ground_normal=normal;s.ground_height=height(z);s.ground_clearance=0.95
  local f=c:update(1/fps,s,query,{base_fov_deg=70})
  if t>0.5 then
   out.pull=math.max(out.pull,f.debug.collision_pull or 0)
   if (c.hill_ahead_for or 0)>0 then out.seen=true end
   
   if t>seconds-0.4 then out.steady_look=math.min(out.steady_look,math.deg(f.debug.look_pitch_offset)) end
  end
 end
 return out
end

local CREST=24
local function hill(deg) return function(z) if z<=CREST then return 0 end return -(z-CREST)*math.tan(math.rad(deg)) end end
local function ledge(z) if z<=CREST then return 0 end return -1.0 end
local function rollers(z) return 0.12*(1-math.cos(z*2*math.pi/3)) end

for _,fps in {30,60,144} do
 local name=fps.." FPS "
 local h=drive(hill(25),fps,4.5,12)
 T.expect(h.seen,name.."a 25 degree hill is seen from the flat before it")
 T.expect(h.pull<0.35,name.."the crest does not drag the eye in")
 T.expect(math.abs(h.steady_look)<0.6*25*0.5,name.."the slope look does not stack on the clearance lift")
 local l=drive(ledge,fps,3.2,8)
 T.expect(not l.seen,name.."a drop off a ledge is not treated as a hill")
 local r=drive(rollers,fps,5,6)
 T.expect(not r.seen,name.."small rollers are not treated as a hill")
end
do -- 1.2.24: above the physics rate a stepped rider's stairs are not camera jumps, and a real jump still is.
 local SnapGuard=require("snapguard")
 local F,Up=v(0,0,1),v(0,1,0)
 local function ride(jump)
  local g=SnapGuard.new();g.stable=true;g.finite_recovery=true
  local at,count,eye=0,0,0
  for i=1,120 do
   local dt=1/144;at+=dt;eye+=8.5*dt
   local z=math.floor(eye*60/8.5)*8.5/60
   local wanted=v(0,1,eye-2)
   if jump and i>=90 then wanted+=v(0,0.6,0) end
   local _,_,_,_,cause=g:filter(at,wanted,F,Up,70,v(0,1,z),false)
   if cause and i>6 then count+=1 end
  end
  return count
 end
 T.expect(ride(false)==0,"a stepped rider at 144 FPS raises no false jump")
 T.expect(ride(true)>=1,"a real 60 cm eye jump is still caught at 144 FPS")
end
T.done()
if T.failures>0 then error("hill framing regression") end
