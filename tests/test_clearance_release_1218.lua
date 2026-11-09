local T=require("tlib");T.group("clearance release 1218")
local Mock=require("mock_reskate")
local v,mag=vector.create,vector.magnitude
local m=Mock.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end;m.reskate.menu.game=function()return {open=false}end
local app=require("app").start();for i=1,120 do m.tick(1000/60)end
local g=app.glue;g.source="ride";g.blend=1;g.snap.onboard=true;g.snap.manual=false;g.snap.bailing=false;g.snap.physics_state=201
local root=v(0,1,0);g.snap.position=root;g.skater_position=root;g.snap.velocity=v(0,0,0);g.snap.ground_height=0
 g.snap.physical_height=nil;g.render_delta=v(0,0,0);g.cam.crouch=nil;g.cam.pop_flight=nil
 g.store.settings.follow.trick_pop=false;g.frame={debug={},back=v(0,0,-1)};g.view_blend=nil;g.frame_bounds=nil;g.pulled=false;g.cam.ramp_render_follow=1
local F,U=v(0,0,1),v(0,1,0);local core=v(-1,2,-2);local recovery=v(0.999,1.2,-2)
g.guard.filter=function()return recovery,F,U,70 end
-- Static raised floor on one side of an edge. Both candidate centres stay
-- above solid geometry. Only .002m of horizontal requested motion occurs.
m.state.raycast=function(a,b)
 local y=a.x>=1 and 1.1 or 0
 if a.y>=y and b.y<y then return a+(b-a)*((a.y-y)/(a.y-b.y))end
end
local previous;local ypeak=0;local xpeak=0;local lo,hi=100,-100
for i=1,12 do
 m.clock_ms+=1000/60;m.state.raycasts=0;g.rays_tick=0;g.capped_this_tick=false
 recovery=v(i%2==0 and 0.999 or 1.001,1.2,-2);g.impact=0;g.rattle=nil
 g:show(core,F,U,70);local shown=m.last_call("set").position
 if previous then ypeak=math.max(ypeak,math.abs(shown.y-previous.y));xpeak=math.max(xpeak,math.abs(shown.x-previous.x))end
 lo,hi=math.min(lo,shown.y),math.max(hi,shown.y)
 print("EDGE",i,recovery.x,shown.y,g.floor_lift_need,g.floor_contact,g.rays_tick)
 previous=shown
end
print("RESULT",string.format("constant core/zero shake/zero dip: requested X step %.3fm, output Y step %.3fm, Y range %.3f..%.3fm, native ray errors %d",xpeak,ypeak,lo,hi,g.ray_errors))
T.expect(ypeak<0.01 and xpeak<0.003 and g.ray_errors==0,"millimetre edge motion cannot pump eye by20cm")
-- Free geometry lets the retained scalar offset settle, without holding a world eye.
m.state.raycast=function()return nil end
for i=1,120 do
 m.clock_ms+=1000/60;m.state.raycasts=0;g.rays_tick=0;g:show(core,F,U,70)
end
T.expect(math.abs(m.last_call("set").position.y-1.2)<0.001,"clearance offset finishes release without a permanent height bias")
-- A deliberate landing drop is immediate when there is no actual obstruction.
recovery=v(0.999,0.9,-2);g.impact=0.3;m.clock_ms+=1000/60;m.state.raycasts=0;g.rays_tick=0
g:show(core-v(0,0.3,0),F,U,70)
T.expect(math.abs(m.last_call("set").position.y-0.9)<0.001,"landing drop is not smoothed by clearance release")
-- Landing impulse remains additive even while the clearance offset is releasing.
local ys={}
for _,drop in {0,0.3} do
 recovery=v(0.999,1.2-drop,-2);m.clock_ms+=1000/60
 g.clearance_release={value=0.2,velocity=0,at=m.clock_ms/1000-1/60}
 g.last_shown={pos=v(0.999,1.4,-2),root=root,source="ride",at=m.clock_ms/1000-1/60,guard_subject_y=1,air=true}
 g.impact=drop;g.rays_tick=0;m.state.raycasts=0
 g:show(core-v(0,drop,0),F,U,70);ys[#ys+1]=m.last_call("set").position.y
end
T.expect(math.abs((ys[1]-ys[2])-0.3)<1e-5,"active clearance damping does not attenuate authored landing impulse")
-- The virtual previous eye can differ from the displayed one after correction.
-- Only actual displayed travel may authorise a hard pull.
do
 local h=Mock.install({limit_rays=true});h.reskate.input.gamepad=function()return nil end;h.reskate.menu.game=function()return {open=false}end
 local a=require("app").start();for i=1,120 do h.tick(1000/60)end
 local q=a.glue;q.source="ride";q.blend=1;q.snap.onboard=true;q.snap.manual=false;q.snap.bailing=false;q.snap.physics_state=201
 q.snap.position=v(0,1,0);q.skater_position=q.snap.position;q.snap.ground_height=0;q.render_delta=v(0,0,0)
 q.cam.crouch=nil;q.cam.pop_flight=nil;q.cam.ramp_render_follow=1;q.store.settings.follow.trick_pop=false
 q.frame={debug={collision_pivot=v(0,1,0)},back=-F};q.guard.have=true;q.guard.stable=true;q.guard.o_rel=v(0,0.5,-3)
 q.last_shown={pos=v(0,2,-3),root=q.skater_position,source="ride",at=h.clock_ms/1000,air=true}
 local hard
 q.guard.filter=function(_,now,pos,f,u,fov,subject,pulled)hard=pulled;return pos,f,u,fov end
 h.state.raycast=function(a,b)if (a.y-1.7)*(b.y-1.7)<0 then return a+(b-a)*((1.7-a.y)/(b.y-a.y))end end
 q.pulled=true;q.rays_tick=0;h.state.raycasts=0
 q:show(v(0,2,-2.5),F,U,70)
 T.expect(hard==false,"virtual-eye obstruction cannot force hard pull when actual displayed travel is clear")
 T.expect(q.rays_tick<=64 and q.ray_errors==0,"actual-path decision respects native budget")
end
T.done();if T.failures>0 then error("clearance release regression")end
