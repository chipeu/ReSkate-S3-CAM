-- Actual App/Glue camera in a corridor, with large turn and shoulder preferences.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("adaptive camera 129")
local function box(a,b,lo,hi)
    local near,far=0,1
    for _,axis in {"x","y","z"} do
        local d=b[axis]-a[axis]
        if math.abs(d)<1e-8 then
            if a[axis]<lo[axis] or a[axis]>hi[axis] then return nil end
        else
            local x,y=(lo[axis]-a[axis])/d,(hi[axis]-a[axis])/d
            if x>y then x,y=y,x end
            near,far=math.max(near,x),math.min(far,y)
            if near>far then return nil end
        end
    end
    return a+(b-a)*near,v(0,1,0)
end

local function drive(fps,both,jitter)
 local m=Mock.install({limit_rays=true})
 m.reskate.input.gamepad=function() return nil end
 m.reskate.menu.game=function() return {open=false} end
 local app=require("app").start()
 local s=Settings.defaults()
 s.follow.trick_pop=false;s.follow.crouch_enabled=false
 s.shake_enabled=false;s.native_plus.landing_dip=false
 s.trick_yaw.enabled=true;s.trick_yaw.side=-1;s.trick_yaw.angle_degrees=45
 s.trick_yaw.min_air_time=0
 s.shoulder.mode=Settings.ShoulderSide.Manual;s.shoulder.side=1;s.shoulder.offset=0.45
 s.ride_distance.mode=Settings.DistanceMode.Fixed;s.ride_distance.fixed=1.8
 assert(app.store:set_settings(s))
 local walls={{v(0.45,-1,10),v(0.7,4,100)}}
 if both then walls[#walls+1]={v(-0.7,-1,10),v(-0.45,4,100)} end
 local out={penetrations=0,max_rays=0,observed=0,full=0,yaw=0,shoulder=0,max_step=0,errors=0,max_correction=0,max_x=0}
 local previous
 local t=0
 for i=1,7*fps do
  local dt=jitter and i%61==0 and 0.085 or 1/fps
  t+=dt;local air=t>=2 and t<6
  local root=v(0,0.95,5*t)
  m.state.skater.position=root
  m.state.telemetry.physics_state=air and 201 or 100;m.state.telemetry.airborne=air
  m.state.board.deck={position=root-v(0,0.95,0),rotation={0,0,0,1}}
  m.state.board.velocity=v(0,0,5)
  m.state.raycast=function(a,b)
   local hit,n
   if a.y>=0 and b.y<=0 and a.y~=b.y then hit=a+(b-a)*(a.y/(a.y-b.y));n=v(0,1,0) end
   for _,wall in walls do
    local q,normal=box(a,b,wall[1],wall[2])
    if q and (not hit or mag(q-a)<mag(hit-a)) then hit,n=q,normal end
   end
   return hit,n
  end
  m.fire("physics_step",{at=m.clock_ms+dt*1000,seconds=dt,velocity={0,0,5},ragdoll=false})
  m.tick(dt*1000)
  out.max_rays=math.max(out.max_rays,m.state.raycasts)
  local shown=m.last_call("set")
  if shown and app.glue.source=="ride" and app.glue.blend>=1 then
   local p=shown.position
   if t>3 and t<5.8 then
    out.observed+=1
    out.max_correction=math.max(out.max_correction,app.glue.body_correction or 0)
    out.max_x=math.max(out.max_x,math.abs(p.x))
    for _,wall in walls do
     local a,b=wall[1],wall[2]
     if p.x>a.x+1e-4 and p.x<b.x-1e-4 and p.y>a.y and p.y<b.y and p.z>a.z and p.z<b.z then out.penetrations+=1 end
    end
    local d=app.glue.frame.debug
    out.yaw=math.max(out.yaw,math.abs(d.trick_yaw or 0))
    out.shoulder=math.max(out.shoulder,math.abs(d.motion_shoulder_applied or 0))
    if previous then out.max_step=math.max(out.max_step,mag((p-root)-previous)) end
    previous=p-root
   end
  end
 end
 out.errors=app.errors
 T.expect(s.shoulder.side==app.store.settings.shoulder.side and s.trick_yaw.side==app.store.settings.trick_yaw.side,"adaptive framing keeps saved preferences")
 return out
end
for _,fps in {30,60,144} do
 for _,both in {false,true} do
  local a=drive(fps,both)
  print("adaptive corridor",fps,both,"samples",a.observed,"solid clips",a.penetrations,"rays",a.max_rays,"turn",math.deg(a.yaw),"shoulder",a.shoulder,"step",a.max_step,"correction",a.max_correction,"maxX",a.max_x)
  T.expect(a.observed>fps and a.errors==0,"corridor fixture runs camera without errors")
  T.expect(a.penetrations==0,"displayed eye stays outside wall solids")
  T.expect(a.max_rays<=64,"shared solver respects SDK ray cap")
  if both then
   T.expect(a.yaw<math.rad(20) and a.shoulder<0.4,"narrow corridor reduces orbit and shoulder together")
   T.expect(a.max_x<0.35,"constrained eye retains lateral room inside corridor")
  end
  T.expect(a.max_step<math.max(0.25,12/fps),"settled constrained framing avoids large relative jumps")
 end
end
for _,both in {false,true} do
 local a=drive(60,both,true)
 print("adaptive long frames",both,"clips",a.penetrations,"rays",a.max_rays,"errors",a.errors)
 T.expect(a.observed>60 and a.errors==0 and a.penetrations==0,"long frames retain valid collision-safe camera")
 T.expect(a.max_rays<=64,"future fixed steps retain SDK headroom")
end
T.done()
if T.failures>0 then error("adaptive camera integration regressions") end
