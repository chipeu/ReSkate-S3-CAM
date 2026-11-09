-- Sub-four-metre vert with changing body heading and a lateral animated head.
-- The real App/Glue/core run against solid ramp geometry and a 60 Hz clock.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("reference recovery 1213")
local DURATION=3.38
local DROP=3.39
local SHIFT=DROP+0.5
local UP=(4.9*DURATION*DURATION-DROP)/DURATION
local function pose(t)
 local u=t-3
 if u>=0 and u<DURATION then
  local f=u/DURATION
  local z=36+12*DURATION/math.pi*math.sin(math.pi*f)-SHIFT*f^3
  local vz=12*math.cos(math.pi*f)-3*SHIFT*f*f/DURATION
  return v(0,24.45+UP*u-4.9*u*u,z),v(0,UP-9.8*u,vz),u<0.08 and 200 or 201
 elseif u>=DURATION then
  local z=36-SHIFT-12*(u-DURATION)
  return v(0,0.95+math.clamp(z-12,0,23.5),z),v(0,z>12 and z<35.5 and -12 or 0,-12),100
 end
 local z=12*t
 return v(0,0.95+math.clamp(z-12,0,23.5),z),v(0,z>12 and z<35.5 and 12 or 0,12),100
end
local function world(a,b)
 local hit,normal
 for _,part in {{0,0,-10000,12},{1,-12,12,35.5},{0,23.5,35.5,10000}} do
  local grade,offset,lo,hi=table.unpack(part)
  local da,db=a.y-grade*a.z-offset,b.y-grade*b.z-offset
  if da~=db then
   local f=da/(da-db)
   if f>=0 and f<=1 then
    local p=a+(b-a)*f
    if p.z>=lo and p.z<=hi and (not hit or mag(p-a)<mag(hit-a)) then
     hit,normal=p,vector.normalize(v(0,1,-grade))
    end
   end
  end
 end
 return hit,normal
end
local function drive(fps,framing,pop,crouch,angle,missing,spin,bias)
 local m=Mock.install({limit_rays=true})
 m.reskate.input.gamepad=function() return nil end
 m.reskate.menu.game=function() return {open=false} end
 local app=require("app").start()
 local s=Settings.defaults()
 s.follow.trick_pop=pop==true;s.follow.crouch_enabled=crouch==true
 s.angle=angle or Settings.CameraAngle.Low
 s.trick_yaw.enabled=framing==true;s.trick_yaw.side=-1
 s.shoulder.mode=framing and Settings.ShoulderSide.Manual or Settings.ShoulderSide.Off
 s.shake_enabled=false;s.native_plus.landing_dip=false
 s.ride_distance.mode=Settings.DistanceMode.Fixed;s.ride_distance.fixed=1.53
 s.ride_distance_high.mode=Settings.DistanceMode.Fixed;s.ride_distance_high.fixed=2.40
 assert(app.store:set_settings(s))
 local out={framed=0,high=0,above=0,down=0,post_step=0,post_pitch=0,max_roll=0,landing=0,air=0,min_w=1,peak_gap=0,peak_step=0,peak_pitch=0,max_rays=0,errors=0,descending=0,wall_clips=0}
 local phys_t=0
 local epoch=m.clock_ms
 local previous
 for i=1,math.floor(10*fps) do
  local t=i/fps
  local root,velocity,state=pose(t)
  m.state.skater.position=root
  m.state.skater.heading=math.rad(spin or 360)*math.clamp((t-3)/DURATION,0,1)
  m.state.joints[103]=root+v(0.4*math.sin(m.state.skater.heading),0.8,0.4*math.cos(m.state.skater.heading))
  m.state.joints[7]=root
  if missing and t>4.8 and t<5.6 then m.state.joints[103]=nil;m.state.joints[7]=nil end
  if missing and t>5.6 and t<5.8 then m.state.joints[103]=root+v(0,100,0) end
  m.state.telemetry.physics_state=state;m.state.telemetry.airborne=state==200 or state==201
  m.state.board.deck={position=root-v(0,0.95,0),rotation={0,0,0,1}}
  m.state.board.velocity=velocity
  m.state.raycast=function(a,b)
   local hit,normal=world(a,b)
   if framing and a.x~=b.x then
    for _,x in {-0.65,0.65} do
     local f=(x-a.x)/(b.x-a.x)
     if f>=0 and f<=1 then
      local q=a+(b-a)*f
      if q.y>-100 and q.y<200 and (not hit or mag(q-a)<mag(hit-a)) then hit,normal=q,v(x<0 and 1 or -1,0,0) end
     end
    end
   end
   return hit,normal
  end
  while phys_t+1/60<=t+1e-8 do
   phys_t+=1/60
   local _,pv,ps=pose(phys_t)
   if ps==200 or ps==201 then pv+=v(0,bias or 0,0) end
   m.fire("physics_step",{at=epoch+phys_t*1000,seconds=1/60,velocity={pv.x,pv.y,pv.z},ragdoll=false})
  end
  m.tick(1000/fps)
  out.max_rays=math.max(out.max_rays,m.state.raycasts)
  local shown=m.last_call("set")
  if shown and app.glue.source=="ride" and app.glue.blend>=1 then
   local pitch=math.deg(math.asin(shown.forward.y))
   local right=vector.normalize(vector.cross(shown.forward,v(0,1,0)))
   local level=vector.cross(right,shown.forward)
   local roll=math.deg(math.atan2(-vector.dot(shown.up,right),vector.dot(shown.up,level)))
   out.max_roll=math.max(out.max_roll,math.abs(roll))
   if t>3.8 and t<6.15 and not framing then
    out.high+=1
    if shown.position.y>root.y+0.8 then out.above+=1 end
    if shown.forward.y<0 then out.down+=1 end
    local all=true
    for _,point in {m.state.joints[103],root-v(0,0.95,0)} do
     local line=point-shown.position
     local depth=vector.dot(line,shown.forward)
     local ratio=math.abs(vector.dot(line,shown.up))/math.max(depth,1e-6)
     if depth<=0 or ratio>math.tan(math.rad((shown.fov or 65)*0.46)) then all=false end
    end
    if all then out.framed+=1 end
    local line=v(root.x,app.glue.cam.takeoff_surface_y,root.z)-shown.position
    local depth=vector.dot(line,shown.forward)
    if depth>0 and vector.dot(line,shown.up)<0 then out.landing+=1 end
   end
   local rel=shown.position-root
   if t>6.2 and t<8.6 and previous then
    out.post_step=math.max(out.post_step,mag(rel-previous.rel))
    out.post_pitch=math.max(out.post_pitch,math.abs(pitch-previous.pitch))
   end
   if t>6.2 and t<8.6 then
    out.air+=1
    if framing and math.abs(shown.position.x)>0.651 then out.wall_clips+=1 end
    out.min_w=math.min(out.min_w,app.glue.frame.debug.terrain_weight or 0)
    out.peak_gap=math.max(out.peak_gap,math.abs(rel.y))
    if velocity.y<0 then out.descending+=1 end
    if previous then
     out.peak_step=math.max(out.peak_step,mag(rel-previous.rel))
     out.peak_pitch=math.max(out.peak_pitch,math.abs(pitch-previous.pitch))
    end
   end
   previous={rel=rel,pitch=pitch}
  end
 end
 out.errors=app.errors
 return out
end


-- The synthetic flight lands at 3 + 14/9.8 seconds, before its six-second end.
-- Bound relative eye travel with the existing 12 m/s vert continuity allowance.
-- The old guard bypass produced 0.882 m at 144 Hz with a clear previous eye.


for _,fps in {30,60,144} do
 for _,bias in {-0.9,0,0.9} do
  for _,pop in {false,true} do
   for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
    for _,walls in {false,true} do
     local a=drive(fps,walls,pop,false,angle,false,180,bias)
     print("reference1213",fps,bias,pop,angle,walls,"framed",a.framed,a.high,"step",a.post_step,"pitch",a.post_pitch,"rays",a.max_rays)
     if not walls then T.expect(a.high>fps*2 and a.framed==a.high,"observed API head and feet remain framed despite integrated-height disagreement") end
     T.expect(a.post_step<12/fps,"long descent/touchdown retains continuous spacing")
     T.expect(a.wall_clips==0 and a.errors==0 and a.max_rays<=64,"body framing respects walls and host budgets")
    end
   end
  end
 end
end
T.done()
if T.failures>0 then error("reference recovery regression") end
