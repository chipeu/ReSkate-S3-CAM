-- Contracts of the 1.2.19 final-pose repairs. Each failed against frozen 1.2.18, or guards an interaction it changed.
local T,Mock=require("tlib"),require("mock_reskate")
local SnapGuard,TerrainContext=require("snapguard"),require("terrain_context")
local v,mag=vector.create,vector.magnitude
T.group("final pose 1219")
local F,U=v(0,0,1),v(0,1,0)
local function setup(state)
 local m=Mock.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end;m.reskate.menu.game=function()return {open=false}end
 local app=require("app").start();for i=1,120 do m.tick(1000/60)end
 local g=app.glue;g.source="ride";g.blend=1;g.snap.onboard=true;g.snap.manual=false;g.snap.bailing=false;g.snap.physics_state=state or 100
 g.snap.position=v(0,1,0);g.skater_position=g.snap.position;g.snap.velocity=v(0,0,0);g.snap.ground_height=0
 g.snap.physical_height=nil;g.render_delta=v(0,0,0);g.cam.crouch=nil;g.cam.pop_flight=nil
 g.store.settings.follow.trick_pop=false;g.frame={debug={},back=v(0,0,-1)};g.view_blend=nil;g.frame_bounds=nil;g.pulled=false
 return m,app,g
end
local function frame(m,g,dt) m.clock_ms+=(dt or 1/60)*1000;m.state.raycasts=0;g.rays_tick=0;g.capped_this_tick=false;g.impact=0;g.rattle=nil end

-- A riding recovery ends, although the shown view feeds back a forward the guard never asked for.
do
 local g=SnapGuard.new();g.stable=true;g.rotation_passthrough=true;g.finite_recovery=true;g.restart_finishing=true;g.finish_rate=0.1;g.finish_settled=true
 local sub=v(0,1,0);local now=10
 g:filter(now,v(0,2,-2),F,U,70,sub,false)
 local cleared
 for i=1,240 do
  now+=1/60
  g:filter(now,v(0,i==1 and 3 or 2,-2),F,U,70,sub,false)
  g.o_fwd=vector.normalize(v(0.02,0.01,1)) -- the final aim always differs from the guard's input
  if not g.smoothing then cleared=i;break end
 end
 T.expect(cleared~=nil and cleared<120,"a riding recovery settles and ends despite view feedback")
end

-- Pop Off retains a raised support seen on the approach when takeoff shortens the lookahead.
do
 local c=TerrainContext.new()
 local top=function(a,b) if a.z>=2.0 then return v(a.x,1.0,a.z) end return v(a.x,0,a.z) end
 local reasons={}
 for i=1,12 do c:update({position=v(0,0.95,i*0.1),velocity=v(0,0,7),state=100,ground_valid=true,ground_height=0,ground_normal=U},1/60,top) end
 for i=1,60 do
  local r=c:update({position=v(0,0.95+i*0.03,1.2+i*0.002),velocity=v(0,2,2.9),state=201,ground_valid=false},1/60,function(a,b) return v(a.x,0,a.z) end)
  reasons[#reasons+1]=r.reason
 end
 local flat=0
 for _,r in reasons do if r=="flat" then flat+=1 end end
 T.expect(flat==0,"a confirmed raised support is not forgotten in the middle of a flight")
end

-- Root clock at a real 60 FPS with almost no zero-step frames, on a purely vertical flight.
local function clock_case(rendered)
 local m,app,g=setup(201)
 g.store.options.stable_timing=true
 m.state.telemetry.physics_state=201;m.state.telemetry.airborne=true
 local t,phys,epoch,rs=0,0,m.clock_ms,nil
 local seed=7
 for i=1,240 do
  seed=(seed*1103515245+12345)%2147483648
  local dt=1/60*(1+(seed/2147483648*2-1)*0.12)
  t+=dt
  while phys+1/60<=t+1e-9 do phys+=1/60;m.fire("physics_step",{at=epoch+phys*1000,seconds=1/60,velocity={0,8-9.8*(phys%1.5),0},ragdoll=false}) end
  local at=rendered and t or phys
  local u=at%1.5
  m.state.skater.position=v(0,5+8*u-4.9*u*u,0);m.state.board.velocity=v(0,8-9.8*u,0)
  m.tick(dt*1000);m.state.raycasts=0
 end
 return g.root_render_sampled==true,g.render_delta
end
local yes,delta=clock_case(true)
T.expect(yes and mag(delta)<1e-6,"a render-sampled root on a vertical flight receives no second physics lead")
local no=clock_case(false)
T.expect(not no,"a physics-stepped root keeps its timing lead")

-- Floor: a step in the surface eases in, real penetration and a descending eye do not.
do
 local m,app,g=setup(100)
 local y=0
 m.state.raycast=function(a,b) if a.y>=y and b.y<y then return a+(b-a)*((a.y-y)/(a.y-b.y)) end end
 local eye=v(0,0.5,-2);local before
 for i=1,30 do frame(m,g);g:show(eye,F,U,70) end
 before=m.last_call("set").position.y
 y=0.3 -- a 30 cm curb arrives under the eye
 local steps,last=0,before
 for i=1,30 do
  frame(m,g);g:show(eye,F,U,70);local p=m.last_call("set").position.y
  steps=math.max(steps,math.abs(p-last));last=p
  T.expect(p>=y+0.1199,"eye never closer to the surface than the penetration margin")
 end
 T.expect(steps<0.05,"a curb raises the eye gradually, not in one frame")
 T.expect(math.abs(last-0.6)<0.001,"a curb still reaches full clearance")
 -- Descending onto a level floor is held at full clearance on every frame.
 local m2,_,g2=setup(100)
 m2.state.raycast=function(a,b) if a.y>=0 and b.y<0 then return a+(b-a)*(a.y/(a.y-b.y)) end end
 for i=0,40 do
  frame(m2,g2);g2:show(v(0,1.2-i*0.05,-2),F,U,70)
  T.expect(m2.last_call("set").position.y>=math.min(0.2999,1.2-i*0.05),"a descending eye keeps clearance immediately")
 end
end

-- A raw recovery candidate under a lip, but with a clear finished eye: lifted, not cut to the core.
do
 local m,app,g=setup(201)
 local core=v(-1,2,-2);local rec=v(1,1.2,-2)
 g.cam.ramp_render_follow=1;g.guard.filter=function() return rec,F,U,70 end
 m.state.raycast=function(a,b)
  local y=(a.x>=0.5 and b.x>=0.5) and 1.3 or 0
  if a.y>=y and b.y<y then return a+(b-a)*((a.y-y)/(a.y-b.y)) end
 end
 g.last_shown={pos=v(1,1.6,-2),root=g.skater_position,source="ride",at=m.clock_ms/1000,air=true}
 frame(m,g);g:show(core,F,U,70)
 local p=m.last_call("set").position
 T.expect(math.abs(p.x-1)<1e-4 and p.y>=1.3+0.2999,"a lifted candidate avoids the full core fallback")
end

-- A real obstruction ahead of the recovering eye, with a clear route to the core: a fast glide, never one frame.
do
 local m,app,g=setup(201)
 local core=v(-1,2,-2);local rec=v(1,2,-2)
 g.cam.ramp_render_follow=1;g.guard.filter=function() return rec,F,U,70 end
 m.state.raycast=function(a,b)
  -- A thin wall right of the prior eye. Only the path to the raw candidate crosses it.
  if b.x>0.6 and a.x<=0.6 then local t=(0.6-a.x)/(b.x-a.x);return a+(b-a)*t end
  if a.y>=0 and b.y<0 then return a+(b-a)*(a.y/(a.y-b.y)) end
 end
 g.last_shown={pos=v(0.2,2,-2),root=g.skater_position,source="ride",at=m.clock_ms/1000,air=true}
 frame(m,g);g:show(core,F,U,70)
 local p=m.last_call("set").position
 T.expect(mag(p-v(0.2,2,-2))<=6/60+1e-4 and mag(p-core)>0.5,"a clear route to the core is travelled, not cut")
end

-- The touchdown rebase removes a datum change and leaves the rider's own travel alone.
do
 local m,app,g=setup(100)
 local core=v(0,4,-2)
 g.guard.have=true;g.guard.stable=true;g.guard.subject=v(0,10,0);g.guard.o_rel=v(0,3,-2);g.guard.w_rel=v(0,3,-2)
 g.guard.w_fwd,g.guard.o_fwd,g.guard.o_up,g.guard.w_step=F,F,U,v(0,0,0);g.guard.w_turn,g.guard.w_dfov=0,0
 g.guard_subject_vy=-15
 g.last_shown={pos=v(0,13,-2),root=v(0,10,0),source="ride",at=m.clock_ms/1000,air=true,guard_subject_y=10}
 g.skater_position=v(0,9.75,0);g.snap.position=g.skater_position
 local rel
 local filter=g.guard.filter
 g.guard.filter=function(self,...) rel=self.o_rel;return filter(self,...) end
 frame(m,g);g:show(core+v(0,5.75,0),F,U,70)
 T.expect(math.abs(rel.y-3)<0.01,"a following datum's own fall is not treated as a datum change")
end
do
 local function jump(watch)
  local guard=SnapGuard.new();guard.stable=true;guard.finite_recovery=true
  local at,subject=0,v(0,1,0)
  for i=1,6 do at+=1/60;guard:filter(at,subject+v(0,1,-2),F,U,70,subject,false) end
  if watch then guard.watch_until=at+0.15 end
  at+=1/60
  local shown=guard:filter(at,subject+v(0,1-0.20,-2),F,U,70,subject,false)
  return shown-subject,guard.smoothing
 end
 local _,outside=jump(false)
 T.expect(not outside,"a 20 cm eye step away from touchdown remains ordinary motion")
 local shown,inside=jump(true)
 T.expect(inside and math.abs(shown.y-1)<0.05,"a body-animation eye step just after touchdown is eased, not shown in one frame")
end
T.done();if T.failures>0 then error("final pose 1219 regression") end
