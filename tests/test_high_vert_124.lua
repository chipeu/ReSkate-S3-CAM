-- Long vert air after a brief level lip, with a real 60Hz physics clock.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("high vert 124")
local function pose(t)
 local takeoff=3
 local duration=64/9.8
 local u=t-takeoff
 local z,y,vy,vz,state
 if u>=0 and u<duration then
  z=36+12*duration/math.pi*math.sin(math.pi*u/duration)
  vz=12*math.cos(math.pi*u/duration)
  y=24.45+32*u-4.9*u*u;vy=32-9.8*u
  state=u<0.08 and 200 or 201
 elseif u>=duration then
  z=36-12*(u-duration);vz=-12
  y=0.95+math.clamp(z-12,0,23.5);vy=z>12 and z<35.5 and -12 or 0
  state=100
 else
  z=12*t;vz=12
  y=0.95+math.clamp(z-12,0,23.5);vy=z>12 and z<35.5 and 12 or 0
  state=100
 end
 return v(0,y,z),v(0,vy,vz),state
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
local function drive(fps,framing,pop,crouch,angle,missing)
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
 assert(app.store:set_settings(s))
 local out={framed=0,high=0,above=0,down=0,post_step=0,post_pitch=0,max_roll=0,landing=0,air=0,min_w=1,peak_gap=0,peak_step=0,peak_pitch=0,max_rays=0,errors=0,descending=0,wall_clips=0}
 local phys_t=0
 local epoch=m.clock_ms
 local previous
 for i=1,math.floor(12*fps) do
  local t=i/fps
  local root,velocity,state=pose(t)
  m.state.skater.position=root
  m.state.joints[103]=root+v(0,0.8,0)
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
   local _,pv=pose(phys_t)
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
   if t>4.4 and t<7.5 and not framing then
    out.high+=1
    if shown.position.y>root.y+0.8 then out.above+=1 end
    if shown.forward.y<0 then out.down+=1 end
    local all=true
    for _,point in {root+v(0,0.8,0),root-v(0,0.95,0)} do
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
   if t>9.3 and t<11.3 and previous then
    out.post_step=math.max(out.post_step,mag(rel-previous.rel))
    out.post_pitch=math.max(out.post_pitch,math.abs(pitch-previous.pitch))
   end
   if t>3.8 and t<8.8 then
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
for _,fps in {30,60,144} do
 local a=drive(fps)
 print("mega vert",fps,"air",a.air,"weight",a.min_w,"gap",a.peak_gap,"step",a.peak_step,"pitch",a.peak_pitch,"rays",a.max_rays,"errors",a.errors)
 print("high vert touchdown",fps,a.post_step,a.post_pitch)
 T.expect(a.post_pitch<math.max(6,120/fps),"high vert touchdown pitch remains bounded")
 T.expect(a.post_step<math.max(0.3,12/fps),"high vert touchdown has no large relative camera jump")
 print("high vert body",fps,a.high,a.above,a.down,a.framed,"landing",a.landing,"roll",a.max_roll)
 T.expect(a.high>fps and a.above==a.high and a.down==a.high,"high air elevates above rider and looks down")
 T.expect(a.landing==a.high,"return corridor stays ahead and below the player in high air")
 T.expect(a.framed==a.high,"head and feet stay in the displayed high-air vertical view")
 T.expect(a.max_roll<0.01,"vert flight and landing do not invent roll with shake off")
 T.expect(a.air>fps*3 and a.descending>fps,"fixture covers long ascent/apex/descent with physics60")
 T.expect(a.min_w>0.99,"brief level lip cannot release verified ramp follow during long air")
 T.expect(a.peak_gap<3.5,"mega flight eye stays with physical rider height")
 T.expect(a.peak_step<6/fps,"mega flight has no large relative camera jump")
 T.expect(a.peak_pitch<120/fps,"mega flight pitch remains bounded without random down snaps")
 T.expect(a.max_rays<=64 and a.errors==0,"mega view stays within SDK budget without errors")
end
for _,fps in {30,60,144} do
 local a=drive(fps,true)
 print("mega vert with framing/walls",fps,"clips",a.wall_clips,"step",a.peak_step,"pitch",a.peak_pitch,"rays",a.max_rays)
 T.expect(a.wall_clips==0 and a.errors==0,"combined mega ramp/framing stays inside wall boundaries")
 T.expect(a.min_w>0.99 and a.peak_gap<3.5,"wall avoidance cannot release mega-ramp height follow")
 T.expect(a.max_rays<=64,"combined ramp/wall view respects SDK budget")
 T.expect(a.peak_step<math.max(0.15,12/fps),"combined ramp/wall framing avoids large relative camera snaps")
end
for _,fps in {30,60,144} do
 for _,pop in {false,true} do
  for _,crouch in {false,true} do
   for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
    local a=drive(fps,false,pop,crouch,angle,true)
    local label=string.format("%d pop=%s crouch=%s angle=%s",fps,tostring(pop),tostring(crouch),tostring(angle))
    print("high vert matrix",label,"body",a.framed,a.high,"above",a.above,"roll",a.max_roll,"step",a.peak_step)
    T.expect(a.framed==a.high and a.above==a.high and a.down==a.high,label.." preserves high-air body framing through missing/stale bone reads")
    T.expect(a.post_step<math.max(0.3,12/fps),label.." bounds touchdown relative movement")
    T.expect(a.post_pitch<math.max(6,120/fps),label.." bounds touchdown pitch change")
    T.expect(a.max_roll<0.01 and a.errors==0 and a.max_rays<=64,label.." keeps roll and API budget stable")
   end
  end
 end
end
T.done()
if T.failures>0 then error("mega transition regression") end
