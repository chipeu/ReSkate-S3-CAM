local T,Mock,S=require("tlib"),require("mock_reskate"),require("settings")
local v=vector.create
T.group("joint sampling 1216")
local m=Mock.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end;m.reskate.menu.game=function()return {open=false}end
local old=m.reskate.skater.joint;local counts={}
m.reskate.skater.joint=function(id)counts[id]=(counts[id] or 0)+1;return old(id)end
local app=require("app").start();local o=S.copy(app.store.options);o.offboard_mode="dynamic";app.store:set_options(o)
for i=1,180 do
 table.clear(counts);local root=v(0,0.95,i/60*6)
 m.state.skater.position=root;m.state.joints[7]=root;m.state.joints[44]=root+v(0,0.3,0);m.state.joints[103]=root+v(0,i<120 and 0.8 or 1,0)
 m.fire("physics_step",{at=m.clock_ms,seconds=1/60,velocity={0,0,6},ragdoll=false});m.tick(1000/60)
 if i>30 then
  local valid=true;for _,n in counts do if n>1 then valid=false end end
  T.expect(valid,"body/frame/selected-joint readers share one native request per joint per tick")
 end
end
T.expect(app.glue.frame_bounds and app.glue.frame_bounds.top>0.99,"shared joint samples refresh and track changing head position")
T.expect(app.errors==0 and app.glue.rays_tick<=64,"joint reuse preserves callbacks and geometry budget")
T.done()
if T.failures>0 then error("joint sampling regression") end
