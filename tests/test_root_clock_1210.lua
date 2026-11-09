local T=require("tlib")
T.group("root clock 1210")
local R=require("rider")
local v=vector.create
for _,fps in {30,60,75,144,240} do
 for _,rendered in {false,true} do
  local r=R.new();local worst=0;local last
  for i=1,5*fps do
   local t=i/fps;local seq=math.floor(t*60+1e-7)
   local clock=rendered and t or seq/60
   local velocity=R.update(r,t,v(0,0.95,6*clock),v(0,0,6),true,1/60,seq)
   if t>2 then worst=math.max(worst,math.abs(velocity.z-6)) end
   last=velocity
  end
  print("ROOT",fps,rendered,last,worst)
  T.expect(worst<0.001,"rendered and stepped roots both measure six m/s at "..fps.." fps")
 end
end

-- The root, rather than kicked/spinning board velocity, owns tracking after warmup.
for _,fps in {75,144,240} do
 local r=R.new();local peak=0
 for i=1,4*fps do
  local t=i/fps;local seq=math.floor(t*60+1e-7)
  local p=v(0,0.95,3*t*t)
  local measured=R.update(r,t,p,v(12*math.sin(t*40),0,30*math.cos(t*30)),true,1/60,seq)
  if t>1 then peak=math.max(peak,vector.magnitude(measured-v(0,0,6*t))) end
 end
 T.expect(peak<0.01,"accelerating API root ignores animated board velocity")
 R.reset(r)
 T.expect(not r.render_sampled and r.count==0,"marker/source reset retires sample clock")
end
T.done()
if T.failures>0 then error("root clock regression") end
