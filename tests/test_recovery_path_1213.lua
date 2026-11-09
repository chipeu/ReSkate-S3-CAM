local T,Mock,S=require("tlib"),require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("recovery path 1213")
-- The two valid endpoints lie on opposite sides of a wall. The displayed
-- camera is already on the recovering side, so the imaginary core->recovery
-- segment is blocked even though the actual next displayed motion is clear.
for _,fps in {30,60,144} do
 local m=Mock.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end;m.reskate.menu.game=function()return {open=false} end
 local app=require("app").start();local g=app.glue
 for i=1,120 do m.tick(1000/60) end
 g.source="ride";g.blend=1;g.snap.onboard=true;g.snap.physics_state=100
 g.snap.position=v(0,1,0);g.skater_position=g.snap.position;g.snap.velocity=v(0,0,0)
 g.snap.ground_height=0;g.snap.ground_normal=v(0,1,0);g.snap.manual=false
 g.render_delta=v(0,0,0);g.cam.ramp_render_follow=1
 g.frame={debug={collision_pivot=v(0,1,0)}}
 g.last_shown={pos=v(1,2,-2),root=g.skater_position,source="ride",forward=v(0,0,1),up=v(0,1,0),at=m.clock_ms/1000}
 local desired=v(1.02,2,-2);local core=v(-1,2,-2);local F,U=v(0,0,1),v(0,1,0)
 g.guard.filter=function() return desired,F,U,65 end
 g.pulled=false;g.cam.body_ground_active=false
 m.state.raycast=function(a,b)
  -- A vertical wall at x=0; ground elsewhere.
  if a.x*b.x<0 then return a+(b-a)*(-a.x/(b.x-a.x)) end
  if a.y>=0 and b.y<0 then return a+(b-a)*(a.y/(a.y-b.y)) end
 end
 g.rays_tick=0;m.state.raycasts=0
 local ok=g:show(core,F,U,65)
 local shown=m.last_call("set")
 T.expect(ok and mag(shown.position-desired)<1e-5,"clear actual recovery path is not discarded by unrelated core path")
 T.expect(g.rays_tick<=64 and app.errors==0,"recovery validation stays inside host budget")
 -- A deliberate cut must use the new scene/core, not stale camera history.
 g.frame.debug.reset=true;g.rays_tick=0;m.state.raycasts=0
 g:show(core,F,U,65)
 T.expect(m.last_call("set").position==core,"cut does not reuse old scene path")
end
T.done()
if T.failures>0 then error("recovery path regression") end
