-- Diagnostics must work with verbose disabled, stay bounded, and never cast/change a pose.
local T=require("tlib")
require("mock_reskate").install()
local Glue,Settings=require("glue"),require("settings")
local v=vector.create
T.group("motion diagnostics 127")
local function make()
 local logs={}
 local g=setmetatable({source="ride",blend=1,store={options={verbose=false},settings=Settings.defaults()},
  snap={onboard=true,physics_state=100,velocity=v(0,0,6)},skater_position=v(0,1,0),
  frame={pos=v(0,2,-2),debug={collision_pivot=v(0,1,0),collision_full=2}},render_dt=1/144,
  note=function(_,s) logs[#logs+1]=s end,
  query=function() error("diagnostics cast an extra ray") end}, {__index=Glue})
 return g,logs
end
local function tick(g,t,correction)
 local pos=v(0,2,-2)
 g:trace_camera_frame(t,pos,pos,pos,pos,nil,correction or 0,v(0,0,1),60)
 T.expect(g.frame.pos==pos and g.snap.physics_state==100,"diagnostic cannot change camera pose or state")
end
for _,fps in {30,60,144} do
 local g,logs=make()
 for i=1,10*fps do tick(g,i/fps) end
 T.expect(#logs>=40 and #logs<=51,"automatic steady sampling bounded near 5 Hz, fps "..fps)
 T.expect(#g.camera_trace.ring<=10,"history bounded")
 T.expect(string.find(logs[1],"diag=127",1,true)~=nil,"schema identifies diagnostics build")
 T.expect(string.find(logs[1],"coreFull=2.000",1,true)~=nil,"scalar collision distance formatted safely")
 T.expect(string.find(logs[1],"pitch=0.00",1,true)~=nil,"shown pitch is recorded")
 T.expect(g.store.options.verbose==false,"saved verbosity not changed")
end
do
 local g,logs=make()
 tick(g,1)
 g.frame.debug.motion_pop_follow=true;g.frame.debug.terrain_target=1
 tick(g,1.02)
 local found=false
 for _,s in logs do if string.find(s,"follow handoff",1,true) then found=true end end
 T.expect(found,"boolean/target handoff triggers a context window")
 for i=1,600 do tick(g,1.02+i/144,0.3) end
 T.expect(g.camera_trace.count<=4,"repeated collision event bursts are capped")
 T.expect(#logs<100,"collision flood remains bounded")
 g.source="offboard";tick(g,6)
 T.expect(g.camera_trace==nil,"off-board gap retires previous pose history")
 g.source="ride";tick(g,7)
 T.expect(g.camera_trace.count==0,"remount is not compared with stale pose")
end
T.done()
if T.failures>0 then error("motion diagnostics failed") end
