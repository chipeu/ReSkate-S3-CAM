local T,B=require("tlib"),require("view_blend")
local v=vector.create
local function forward(a)return v(0,math.sin(math.rad(a)),math.cos(math.rad(a)))end
local function angle(a,b)return math.deg(math.acos(math.clamp(vector.dot(a,b),-1,1)))end
T.group("view blend 123")
for _,fps in {30,60,144} do
 local st=B.new();local previous;local peak=0;local target
 for i=1,5*fps do
  local t=i/fps;target=forward(t<1 and 10 or -35)
  local f,u=B.update(st,t,target,v(0,math.cos(math.rad(t<1 and 10 or -35)),-math.sin(math.rad(t<1 and 10 or -35))),t>0.5 and t<1.1,false)
  if previous then peak=math.max(peak,angle(previous,f)) end
  T.expect(math.abs(vector.dot(f,u))<1e-5,"final view axes remain orthogonal")
  T.expect(math.abs(vector.magnitude(f)-1)<1e-5,"view direction remains normalized")
  previous=f
 end
 print("view blend",fps,"largest step",peak)
 T.expect(peak<=100/fps+0.01,"final floor target blends within one angular budget")
 T.expect(vector.magnitude(previous-target)<1e-5 and not st.recovering,"recovery finishes even after ramp owner releases")
 local f=B.update(st,6,forward(80),v(0,1,0),true,true)
 T.expect(vector.magnitude(f-forward(80))<1e-5,"marker cuts retain immediate recentering")
 local plain=B.new();B.update(plain,0,forward(0),v(0,1,0),false,false)
 f=B.update(plain,1/fps,forward(45),v(0,1,0),false,false)
 T.expect(vector.magnitude(f-forward(45))<1e-5,"ordinary non-ramp view remains unchanged")
end
-- A level yaw+pitch change must not invent bank while forward lags.
for _,fps in {30,60,144} do
 for _,roll in {0,math.rad(8)} do
  local st=B.new()
  local f0=v(0,0,1)
  local function level(f) local r=vector.normalize(vector.cross(f,v(0,1,0)));return vector.cross(r,f),r end
  for i=1,fps*3 do
   local t=i/fps;local f=i<fps and f0 or vector.normalize(v(0.8,-0.7,0.25))
   local u,r=level(f);u=u*math.cos(roll)-r*math.sin(roll)
   local out,up=B.update(st,t,f,u,true,false)
   local oh=vector.normalize(v(out.x,0,out.z));local th=vector.normalize(v(f.x,0,f.z))
   T.expect(vector.magnitude(oh-th)<1e-5,"pitch blending does not delay authored yaw")
   local lu,lr=level(out)
   local actual=math.atan2(-vector.dot(up,lr),vector.dot(up,lu))
   T.expect(math.abs(actual-roll)<1e-5,"yaw and pitch recovery preserves only authored roll")
  end
 end
end
T.done()
if T.failures>0 then error("ramp view handoff regression") end
