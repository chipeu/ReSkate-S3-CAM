local T=require("tlib")
T.group("uneven tracking 1210")
local Mock,S=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
local function ground(z) return 0.12*(1-math.cos(z*2*math.pi/3)) end
local function grade(z) return 0.12*2*math.pi/3*math.sin(z*2*math.pi/3) end
local function world(a,b)
 local last=a.y-ground(a.z)
 for j=1,16 do
  local f=j/16;local q=a+(b-a)*f;local next=q.y-ground(q.z)
  if last>=0 and next<=0 then
   local lo,hi=(j-1)/16,f
   for k=1,12 do local m=(lo+hi)/2;local q=a+(b-a)*m;if q.y-ground(q.z)>0 then lo=m else hi=m end end
   local q=a+(b-a)*((lo+hi)/2);return q,vector.normalize(v(0,1,-grade(q.z)))
  end
  last=next
 end
end
for _,fps in {30,60,144} do
 for _,rendered in {false,true} do
  for _,pop in {false,true} do
   for _,crouch in {false,true} do
    for _,angle in {S.CameraAngle.Low,S.CameraAngle.High} do
   local m=Mock.install({limit_rays=true});m.reskate.input.gamepad=function()return nil end;m.reskate.menu.game=function()return {open=false} end
   local app=require("app").start();local s=S.defaults();s.follow.trick_pop=pop;s.follow.crouch_enabled=crouch;s.angle=angle;s.trick_yaw.enabled=false;s.shoulder.mode=S.ShoulderSide.Off
   s.shake_enabled=false;s.native_plus.landing_dip=false;s.ride_distance.mode=S.DistanceMode.Fixed;s.ride_distance.fixed=1.53;s.ride_distance_high.mode=S.DistanceMode.Fixed;s.ride_distance_high.fixed=2.40
   app.store:set_settings(s)
   local epoch=m.clock_ms;local lastseq=0;local prev,prevdelta;local metrics={step=0,xz=0,accel=0,pitch=0,minspan=100,framed=0,n=0,velerr=0,rays=0,guard=0}
   for i=1,8*fps do
    local t=i/fps;local seq=math.floor(t*60+1e-7);local rt=rendered and t or seq/60;local z=6*rt;local root=v(0,0.95+ground(z),z)
    m.state.skater.position=root;m.state.telemetry.physics_state=100;m.state.telemetry.airborne=false
    m.state.joints[103]=root+v(0,0.8,0);m.state.joints[7]=root
    m.state.board.deck={position=root-v(0,0.95,0),rotation={0,0,0,1}};m.state.board.velocity=v(0,6*grade(z),6);m.state.raycast=world
    for n=lastseq+1,seq do local pz=6*n/60;m.fire("physics_step",{at=epoch+n*1000/60,seconds=1/60,velocity={0,6*grade(pz),6},ragdoll=false}) end
    lastseq=seq;m.tick(1000/fps)
    local shown=m.last_call("set");local g=app.glue
    if t>2 and shown then
     local rel=shown.position-root;local pitch=math.deg(math.asin(shown.forward.y));local delta=prev and rel-prev.rel
     if delta then metrics.step=math.max(metrics.step,mag(delta));metrics.xz=math.max(metrics.xz,mag(v(delta.x,0,delta.z))*fps);metrics.pitch=math.max(metrics.pitch,math.abs(pitch-prev.pitch));if prevdelta then metrics.accel=math.max(metrics.accel,mag(delta-prevdelta)*fps*fps) end;prevdelta=delta end
     prev={rel=rel,pitch=pitch};metrics.minspan=math.min(metrics.minspan,mag(v(rel.x,0,rel.z)));metrics.velerr=math.max(metrics.velerr,math.abs(g.snap.velocity.z-6));metrics.rays=math.max(metrics.rays,g.rays_tick);metrics.guard=math.max(metrics.guard,g.body_correction or 0)
     local inside=true
     for _,q in {m.state.joints[103],root-v(0,0.95,0)} do
      local ray=q-shown.position;local depth=vector.dot(ray,shown.forward)
      if depth<=0 or math.abs(vector.dot(ray,shown.up))/depth>math.tan(math.rad(shown.fov*0.48)) then inside=false end
     end
     if inside then metrics.framed+=1 end;metrics.n+=1
    end
   end
   print("UNEVEN",fps,rendered,pop,crouch,angle,"step",metrics.step,"accel",metrics.accel,"pitch",metrics.pitch,"span",metrics.minspan,"framed",metrics.framed,metrics.n,"xzspeed",metrics.xz,"velerr",metrics.velerr,"rays",metrics.rays,"correction",metrics.guard)
   T.expect(metrics.velerr<0.01,"root velocity follows API sample cadence instead of render/physics aliasing")
   T.expect(metrics.framed==metrics.n,"sampled head and estimated feet stay inside 96 percent of vertical view")
   T.expect(metrics.minspan>1.4,"skater retains comfortable horizontal camera spacing")
   T.expect(metrics.xz<1.0,"floor clearance cannot reintroduce horizontal physics-age kicks")
   T.expect(metrics.pitch<120/fps,"small ramps retain smooth pitch within shared recovery budget")
   T.expect(metrics.rays<=64 and app.errors==0,"sampling and framing respect host budgets")
    end
   end
  end
 end
end

T.done()
if T.failures>0 then error("uneven tracking regression") end
