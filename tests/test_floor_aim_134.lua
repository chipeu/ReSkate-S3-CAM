local T,B=require("tlib"),require("bodyframe")
local v=vector.create
T.group("floor aim 134")
local old=v(0,0,0);local origin=v(0,0,3);local raised=v(0,0.768,0)
local forward=vector.normalize(v(0,0.3,1));local up=v(0,1,0)
local legacy=B.reposition(origin,old,raised,forward,up)
-- The view faces the ground away from the rider, so its projection has no
-- usable focus depth. A safety translation must not invent a nearby target.
forward=vector.normalize(v(0,-1,-0.1))
local shallow=B.reposition(origin,old,raised,forward,up)
local subject=B.reposition(origin,old,raised,forward,up,true)
local function angle(a,b)return math.deg(math.acos(math.clamp(vector.dot(a,b),-1,1)))end
T.expect(angle(subject,forward)<angle(shallow,forward),"live rider distance bounds correction instead of half-metre focus")
T.expect(vector.magnitude(subject)>0.999 and vector.magnitude(subject)<1.001,"correction view remains normalized")
local unchanged=B.reposition(origin,old,raised,vector.normalize(v(0,0.3,1)),up,false)
T.expect(vector.magnitude(unchanged-legacy)<1e-6,"other camera paths retain original projection")
T.done()
if T.failures>0 then error("floor aim regression") end
