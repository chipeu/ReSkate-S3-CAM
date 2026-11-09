local T,Mock=require("tlib"),require("mock_reskate")
local v,mag=vector.create,vector.magnitude
T.group("contact aim 1217")
local function yaw(f)return math.deg(math.atan2(f.x,f.z))end
local function ad(a,b)return (a-b+180)%360-180 end
local function setup(state)
 local m=Mock.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end;m.reskate.menu.game=function()return {open=false}end
 local app=require("app").start();for i=1,120 do m.tick(1000/60)end
 local g=app.glue;g.source="ride";g.blend=1;g.snap.onboard=true;g.snap.manual=false;g.snap.bailing=false;g.snap.physics_state=state or 201
 g.snap.position=v(0,1,0);g.skater_position=g.snap.position;g.snap.velocity=v(0,0,0);g.snap.ground_height=0
 g.snap.physical_height=nil;g.render_delta=v(0,0,0);g.cam.crouch=nil;g.cam.pop_flight=nil
 g.store.settings.follow.trick_pop=false;g.frame={debug={},back=v(0,0,-1)};g.view_blend=nil;g.frame_bounds=nil;g.pulled=false
 return m,app,g
end
for _,fps in {30,60,144} do
 for _,next_state in {201,100,403} do
  local m,app,g=setup();local F,U=v(0,0,1),v(0,1,0);local core=v(0,2,-2);local recovery=v(1,2,-2)
  m.state.raycast=function()return nil end;g.guard.filter=function()return recovery,F,U,70 end;g.cam.ramp_render_follow=1
  m.state.raycasts=0;g.rays_tick=0;g:show(core,F,U,70);local a=m.last_call("set")
  m.clock_ms+=1000/fps;g.cam.ramp_render_follow=0;g.snap.physics_state=next_state
  m.state.raycasts=0;g.rays_tick=0;g:show(core,F,U,70);local b=m.last_call("set")
  T.expect(mag(b.position-a.position)<1e-5 and math.abs(ad(yaw(b.forward),yaw(a.forward)))<0.001,"unchanged eye/aim has no yaw cut on ramp/landing/rail owner release")
  T.expect(math.abs(vector.dot(b.forward,b.up))<1e-5,"continuous aim preserves orthogonal view axes")
 end
 for _,blocked in {false,true} do
  local m,app,g=setup();local F,U=v(0,0,1),v(0,1,0);local core=v(-1,2,-2);local recovery=v(1,1.5,-2)
  g.cam.ramp_render_follow=1;g.guard.filter=function()return recovery,F,U,70 end
  g.last_shown={pos=recovery,root=g.skater_position,source="ride",at=m.clock_ms/1000,air=true}
  m.state.raycast=function(a,b)
   local best
   for _,height in {a.x>0 and 1.1 or 0,blocked and a.x>0 and 1.55 or 100} do
    if a.y~=b.y then local f=(height-a.y)/(b.y-a.y);if f>=0 and f<=1 then local p=a+(b-a)*f;if not best or mag(p-a)<mag(best-a) then best=p end end end
   end
   return best
  end
  m.state.raycasts=0;g.rays_tick=0;g:show(core,F,U,70)
  m.clock_ms+=1000/fps;recovery=v(1,1.2,-2);m.state.raycasts=0;g.rays_tick=0;g.guard.have=true;g.guard.move_velocity=v(2,-3,4)
  g:show(core,F,U,70);local shown=m.last_call("set")
  if not blocked then
   T.expect(math.abs(shown.position.x-1)<1e-5 and math.abs(shown.position.y-1.4)<1e-5,"clear .2m floor lift keeps horizontal recovery instead of 2m core rollback")
   T.expect(math.abs(g.guard.move_velocity.x-2)<1e-5 and math.abs(g.guard.move_velocity.z-4)<1e-5 and g.guard.move_velocity.y>=0,"floor contact preserves tangential velocity and removes inward motion")
  else T.expect(shown.position==core,"overhead-blocked lift retains canonical safe fallback")end
  T.expect(g.rays_tick<=64 and app.errors==0,"local projection respects final ray and callback budgets")
 end
end
-- A paused/teleported history or insufficient rays must not authorise an untested lift.
for _,start_rays in {59,62,63} do
 local m,app,g=setup();local F,U=v(0,0,1),v(0,1,0);local core=v(-1,2,-2);local recovery=v(1,1.2,-2)
 g.cam.ramp_render_follow=1;g.guard.filter=function()return recovery,F,U,70 end
 g.last_shown={pos=v(1,1.5,-2),root=g.skater_position,source="ride",at=m.clock_ms/1000,air=true}
 m.state.raycast=function(a,b)local y=a.x>0 and 1.1 or 0;if a.y>=y and b.y<y then return a+(b-a)*((a.y-y)/(a.y-b.y))end end
 g.rays_tick=start_rays;g:show(core,F,U,70)
 T.expect(m.last_call("set").position==core and g.rays_tick<=64,"exhausted lift budget keeps a proven safe core")
end
-- Finite width/cap collision must reject an upward route whose centre is clear.
do
 local m,app,g=setup();local radius=0.18;local eye=v(1,1.2,-2)
 m.state.raycast=function(a,b)
  if a.x>1.1 and a.y<1.45 and b.y>=1.45 then return a+(b-a)*((1.45-a.y)/(b.y-a.y))end
 end
 m.state.raycasts=0;g.rays_tick=0
 if g.clearance_lift then
  local p,why=g:clearance_lift(eye,eye,1.4,radius)
  T.expect(p==nil and why==1,"finite-width cap rejects lateral overhead even when central lift is clear")
  g.rays_tick=60;local before=m.state.raycasts
  p,why=g:clearance_lift(eye,eye,1.4,radius)
  T.expect(p==nil and why==2 and m.state.raycasts==before,"lift budget is checked before issuing partial probes")
 else T.expect(false,"finite-width local correction available");T.expect(false,"local correction budget policy available")end
end
-- The final centre path differs from the unraised path and the cap probes.
-- Check it explicitly: a thin obstacle between those paths must be rejected.
do
 local m,app,g=setup()
 m.state.raycast=function(a,b)
  if a.z~=b.z then local f=(-2.5-a.z)/(b.z-a.z);local p=a+(b-a)*f
   if f>=0 and f<=1 and p.y>=1.35 and p.y<=1.45 then return p end
  end
 end
 m.state.raycasts=0;g.rays_tick=0
 if g.clearance_lift then
  local p,why=g:clearance_lift(v(0,1.4,-3),v(0,1.2,-2),1.4,0.18)
  T.expect(p==nil and why==1,"actual raised-centre travel is checked separately from width/headroom probes")
 else T.expect(false,"raised centre-path validation available")end
end
-- Repeated floor pressure must not freeze tangential catch-up or strand the
-- camera in world space while a fast rider continues travelling.
for _,fps in {30,60,144} do
 local m,app,g=setup();local F,U=v(0,0,1),v(0,1,0);local root=v(0,2,0);local start=root+v(1,-0.6,-2)
 g.skater_position=root;g.snap.position=root;g.snap.velocity=v(0,0,20);g.cam.ramp_render_follow=1
 g.frame_bounds={top=0.8,centre=0.1,bottom=-0.95,head=v(0,0.8,0)};g.cam.vert_frame_w=1
 g.guard:cut();g.guard.stable=true;g.guard:filter(m.clock_ms/1000,start,F,U,70,root,false)
 g.last_shown={pos=start,root=root,source="ride",at=m.clock_ms/1000,air=true,guard_subject_y=2}
 m.state.raycast=function(a,b)if a.y>=1.1 and b.y<1.1 then return a+(b-a)*((a.y-1.1)/(a.y-b.y))end end
 local previous=start-root;local peak=0;local framed=true;local rays=0
 for i=1,3*fps do
  m.clock_ms+=1000/fps;root=v(0,2,20*i/fps);g.skater_position=root;g.snap.position=root
  local core=root+v(-1,-0.8,-2);g.frame.back=-F;m.state.raycasts=0;g.rays_tick=0;g:show(core,F,U,70)
  local shown=m.last_call("set");local relative=shown.position-root
  peak=math.max(peak,mag(relative-previous));previous=relative;rays=math.max(rays,g.rays_tick)
  for _,point in {root+v(0,0.8,0),root-v(0,0.95,0)} do
   local ray=point-shown.position;local depth=vector.dot(ray,shown.forward)
   if depth<=0 or math.abs(vector.dot(ray,shown.up))/depth>math.tan(math.rad(35)) then framed=false end
  end
 end
 T.expect(peak<6/fps,"floor-constrained recovery keeps relative motion bounded without a rollback")
 T.expect(math.abs(previous.x+1)<0.05 and math.abs(previous.z+2)<0.01,"contact recovery converges and keeps up with moving rider")
 T.expect(framed and rays<=64 and app.errors==0 and g.ray_errors==0,"long contact recovery keeps head/feet framed and remains within host budget")
 m.state.raycast=function()return nil end;m.clock_ms+=1000/fps;m.state.raycasts=0;g.rays_tick=0
 g:show(root+v(-1,-0.8,-2),F,U,70)
 T.expect(not g.floor_contact,"missing current support releases contact rather than trusting stale floor")
end
T.done()
if T.failures>0 then error("contact aim regression") end
