-- Final ramp orientation handoff, after all positional safety corrections.
-- Usually passes through. A discontinuous target uses one finite angular recovery.
local S=require("s3math")
local M={}
local v=vector.create
local UP=v(0,1,0)
-- Transfer only the authored roll, never the skew between two directions.
function M.preserve_roll(forward,source_forward,source_up)
 local sr=S.normalized(vector.cross(source_forward,UP),v(-1,0,0))
 local su=vector.cross(sr,source_forward)
 local roll=math.atan2(-vector.dot(source_up,sr),vector.dot(source_up,su))
 local r=S.normalized(vector.cross(forward,UP),sr)
 local u=vector.cross(r,forward)
 return u*math.cos(roll)-r*math.sin(roll)
end
function M.new()return {have=false,recovering=false,rate=0}end
local function update_pitch(st,now,forward,up,active,cut,core_forward)
 local dt=math.clamp(now-(st.at or now),0,0.1)
 local relative=core_forward~=nil
 -- The core already budgets its pitch. Recover only the extra pitch from
 -- presentation safety; filtering the whole pose adds a second lag which
 -- can point outside the body envelope even when the core frames it correctly.
 local base=core_forward and math.asin(math.clamp(core_forward.y,-1,1)) or 0
 if st.have and st.relative~=relative then
  st.pitch=math.asin(math.clamp(st.forward.y,-1,1))-base
 end
 st.relative=relative
 local wanted_pitch=math.asin(math.clamp(forward.y,-1,1))-base
 st.at=now
 if cut or not st.have or dt<=0 then
  st.have=true;st.forward=forward;st.pitch=wanted_pitch;st.recovering=false;st.rate=0
  return forward,up
 end
 local pitch=st.pitch
 local delta=wanted_pitch-pitch
 local angle=math.abs(delta)
 local speed,accel=math.rad(100),math.rad(600)
 if active and angle>speed*dt+1e-5 then st.recovering=true end
 if st.recovering and angle>1e-5 then
  local wanted=(delta<0 and -1 or 1)*math.min(speed,math.sqrt(2*accel*angle),angle/dt)
  st.rate=st.rate+math.clamp(wanted-st.rate,-accel*dt,accel*dt)
  local step=st.rate*dt
  if step*delta>0 and math.abs(step)>angle then step=delta end
  -- Only pitch recovers here. Delaying the core yaw can point past the rider
  -- during a fakie turnaround, even when both target frames are correctly aimed.
  pitch+=step
  local horizontal=S.normalized(v(forward.x,0,forward.z),v(st.forward.x,0,st.forward.z))
  local out=horizontal*math.cos(pitch+base)+UP*math.sin(pitch+base)
  local out_up=M.preserve_roll(out,forward,up)
  st.forward=out;st.pitch=pitch
  if math.abs(delta-step)<=1e-5 then st.recovering=false;st.rate=0 end
  return out,out_up
 end
 st.forward=forward;st.pitch=wanted_pitch;st.rate=0;st.recovering=false
 return forward,up
end
local YAW_EXTRA=math.rad(180) -- rad/s the view may turn beyond what the core itself turned
local function yaw_of(f) return math.atan2(f.x,f.z) end
local function wrapped(a) return (a+math.pi)%(2*math.pi)-math.pi end
-- The core owns yaw and is never held back. What the safety layers add on top
-- of it is bounded, so a correction can never swing the view in one frame.
local function update_yaw(st,dt,forward,up,active,cut,core_forward)
 if not core_forward then st.yaw_have=false;return forward,up end
 local core,yaw=yaw_of(core_forward),yaw_of(forward)
 if cut or not active or not st.yaw_have or dt<=0 then
  st.yaw_have,st.yaw_last,st.yaw_core=true,yaw,core
  return forward,up
 end
 local step=wrapped(yaw-st.yaw_last)
 local allowed=math.abs(wrapped(core-st.yaw_core))+YAW_EXTRA*dt
 st.yaw_core=core
 if math.abs(step)<=allowed then st.yaw_last=yaw;return forward,up end
 local y=wrapped(st.yaw_last+(step<0 and -allowed or allowed))
 st.yaw_last=y
 local cp=math.sqrt(math.max(0,1-forward.y*forward.y))
 local out=v(math.sin(y)*cp,forward.y,math.cos(y)*cp)
 return out,M.preserve_roll(out,forward,up)
end
function M.update(st,now,forward,up,active,cut,core_forward,correction_only)
 local previous,at,have=st.forward,st.at,st.have
 local out,out_up=update_pitch(st,now,forward,up,active,cut,core_forward)
 out,out_up=update_yaw(st,math.clamp(now-(at or now),0,0.1),out,out_up,active,cut,core_forward)
 st.forward=out
 if core_forward and active and not correction_only and not cut and have and previous then
  -- Core motion and an eye-reprojection correction share the ramp budget.
  local dt=math.clamp(now-(at or now),0,0.1)
  local before=math.asin(math.clamp(previous.y,-1,1))
  local pitch=math.asin(math.clamp(out.y,-1,1))
  -- Vectors are float32 in the host; leave a numerical margin when their
  -- reconstructed pitch lands exactly on the aggregate speed bound.
  local cap=math.max(0,math.rad(120)*dt-1e-6)
  if dt>0 and math.abs(pitch-before)>cap then
   pitch=before+math.clamp(pitch-before,-cap,cap)
   local horizontal=S.normalized(v(out.x,0,out.z),v(previous.x,0,previous.z))
   out=horizontal*math.cos(pitch)+UP*math.sin(pitch)
   out_up=M.preserve_roll(out,forward,up)
   st.forward=out;st.pitch=pitch-math.asin(math.clamp(core_forward.y,-1,1))
   st.recovering=true
  end
 end
 return out,out_up
end
return M
