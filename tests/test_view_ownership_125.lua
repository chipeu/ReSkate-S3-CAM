local T,B=require("tlib"),require("view_blend")
local v=vector.create
T.group("view ownership 125")
local function pose(p)
 local a=math.rad(p)
 return v(0,math.sin(a),math.cos(a)),v(0,math.cos(a),-math.sin(a))
end
for _,fps in {30,60,144} do
 local st=B.new()
 local f,u=pose(-55)
 B.update(st,0,f,u,true,true,f)
 for i=1,fps do
  local p=-55+110*i/fps
  f,u=pose(p)
  local out,up=B.update(st,i/fps,f,u,true,false,f)
  T.expect(vector.magnitude(out-f)<1e-5,"a core-framed ramp turn has no second pitch lag")
  T.expect(math.abs(vector.dot(out,up))<1e-5,"moving core preserves orthogonal axes")
 end
 -- Touchdown changes coordinates from safety offset to complete pitch.
 f,u=pose(55)
 local out=B.update(st,1+1/fps,f,u,true,false)
 T.expect(vector.magnitude(out-f)<1e-5,"air/ground coordinate handoff preserves the displayed pitch")
end
T.done()
if T.failures>0 then error("view ownership regression") end
