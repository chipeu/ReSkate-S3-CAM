local T=require("tlib")
local Terrain,Manual=require("terrain_context"),require("manual")
local v=vector.create
T.group("context ownership 125")
local function flat(a,b)
 if a.y>=0 and b.y<=0 then return a+(b-a)*(a.y/(a.y-b.y)) end
end
for _,fps in {30,60,144} do
 local c=Terrain.new()
 local input={position=v(0,0.95,0),velocity=v(0,4,4),state=100,
  ground_valid=true,ground_height=0,ground_normal=vector.normalize(v(0,1,-1))}
 for i=1,fps do c:update(input,1/fps,flat) end
 T.expect(c.steep_seen and c.weight>0.99,"fixture establishes ramp ownership")
 input.velocity=v(0,0,0.7);input.ground_normal=v(0,1,0)
 for i=1,math.ceil(fps*0.25) do c:update(input,1/fps,flat) end
 T.expect(not c.steep_seen and c.steep_hold==0,"slow level support retires ramp before the next pop")
 input.state=201;input.velocity=v(0,4,0.7);input.ground_valid=false
 local initial=c.weight
 for i=1,math.ceil(fps*0.4) do c:update(input,1/fps,flat) end
 T.expect(c.reason=="flat" and c.weight<initial*0.4,"flat slow pop cannot relatch an expired ramp")
end

-- Pose alone is ambiguous, including sustained level-support wheelie shapes.
-- The previous pose-lifetime tests are superseded by test_manual_score_129.
for _,state in {100,101,103} do
 local m=Manual.new()
 for i=1,120 do T.expect(not m:update(i/60,state,true,false,false,14,3),"silent HUD/list cannot infer a manual from board tilt") end
end
do
 local m=Manual.new();m:update(0,100,true,false,false,nil)
 m:on_notes({{kind="n",entry=42,text="Manual"}},0.51)
 T.expect(m:update(0.52,103,true,false,false,14,nil),"named manual remains available without the score HUD")
end
T.done()
if T.failures>0 then error("context ownership regression") end
