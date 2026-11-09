-- Contracts of the 1.2.29 landing bound: right over the aim point the body-frame yaw goes back to the core,
-- the view blend caps what a safety layer adds to the core yaw, and a big-air landing on a 60 degree face
-- never throws the eye more than 0.40 m around the rider in one step or to his front.
-- Failure is counted by tlib; the file errors at the end so the gate sees a non-zero exit.
local T,Body,Blend,Mock,Settings=require("tlib"),require("bodyframe"),require("view_blend"),require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
local started=os.clock()

local function yaw_of(f) return math.atan2(f.x,f.z) end
local function deg(a) return math.deg(a) end
local function wrap(a) return (a+math.pi)%(2*math.pi)-math.pi end
local function dir(yaw_deg) local a=math.rad(yaw_deg);return v(math.sin(a),0,math.cos(a)) end

T.group("body frame aim 1229")
do
 local origin,old=v(0,1,0),v(0,1,-2)
 local authored=dir(10)
 local aim=v(0.3,0,1.0)
 local ok,far=pcall(Body.horizontal,origin,old,v(0.2,1,-2),authored,aim)
 T.expect(ok,"horizontal runs")
 if ok then
  local want=vector.normalize(v(aim.x-0.2,0,aim.z+2))
  T.expect(mag(far-want)<1e-6,"an eye farther than 0.9 m looks exactly at the aim point")
  local far2=Body.horizontal(origin,old,v(-1.5,1,0.2),authored,aim)
  T.expect(mag(far2-vector.normalize(v(aim.x+1.5,0,aim.z-0.2)))<1e-6,"the same from the side at 1.8 m")
  local flat=vector.normalize(v(authored.x,0,authored.z))
  local near=Body.horizontal(origin,old,v(0.1,1,0.2),authored,v(0.1,0,0.3))
  T.expect(mag(near-flat)<1e-6,"an eye within 0.35 m keeps the authored horizontal direction")
  local near2=Body.horizontal(origin,old,v(0.3,1.4,0),authored,v(0,0,0))
  T.expect(mag(near2-flat)<1e-6,"the same at 0.3 m with the aim off to one side")
  local a=Body.horizontal(origin,old,v(-0.025,1,0.1),authored,v(0,0,0.1))
  local b=Body.horizontal(origin,old,v(0.025,1,0.1),authored,v(0,0,0.1))
  local swing=deg(math.abs(wrap(yaw_of(a)-yaw_of(b))))
  T.expect(swing<5,"5 cm of eye motion across the aim point does not swing the yaw ("..string.format("%.1f",swing)..")")
 end
end

T.group("view blend yaw 1229")
do
 local dt=1/60
 local function fresh()
  local st=Blend.new()
  Blend.update(st,0,dir(0),v(0,1,0),true,false,dir(0),false)
  return st
 end
 do -- a 137 degree safety swing while the core turns 2 degrees
  local st=fresh()
  local out=Blend.update(st,dt,dir(137),v(0,1,0),true,false,dir(2),false)
  local turn=deg(math.abs(wrap(yaw_of(out))))
  T.expect(turn<=2+180*dt+0.01,"a 137 degree correction is limited to the core turn plus 180 deg/s ("..string.format("%.2f",turn)..")")
  T.expect(turn>0.5,"the limited view still moves toward the correction ("..string.format("%.2f",turn)..")")
  local again=Blend.update(st,dt*2,dir(137),v(0,1,0),true,false,dir(2),false)
  local total=deg(math.abs(wrap(yaw_of(again))))
  T.expect(total<=2+180*dt*2+0.01,"and it stays limited on the next frame ("..string.format("%.2f",total)..")")
 end
 do -- a core that jumps by itself is not held back
  local out=Blend.update(fresh(),dt,dir(50),v(0,1,0),true,false,dir(50),false)
  T.expect(math.abs(deg(wrap(yaw_of(out)-math.rad(50))))<0.01,"a 50 degree jump of the core itself passes through")
 end
 do -- ordinary small corrections
  local out=Blend.update(fresh(),dt,dir(2),v(0,1,0),true,false,dir(0),false)
  T.expect(math.abs(deg(yaw_of(out))-2)<0.01,"a small correction passes through unchanged")
  local out2=Blend.update(fresh(),dt,dir(-2.5),v(0,1,0),true,false,dir(0),true)
  T.expect(math.abs(deg(yaw_of(out2))+2.5)<0.01,"a small correction passes through when correction-only")
 end
 do -- cut passes everything
  local out=Blend.update(fresh(),dt,dir(137),v(0,1,0),true,true,dir(2),false)
  T.expect(math.abs(deg(yaw_of(out))-137)<0.01,"a cut passes everything")
 end
end

T.group("landing bound 1229")
-- The bigland_60 geometry of tests/testbox/routes.lua (route_bigland): 16.6 m/s, 12.1 m drop, 3.02 s of air onto a
-- 60 degree face with a 7 m run-out. Whole App on a stepped host at 60 FPS (jittered like the testbox), Pop Off,
-- trick yaw default, Low angle, fixed distance 1.53.
local HIP,AIR=0.95,{[200]=true,[201]=true}
local function build()
 local g,speed,drop,t_air,dg,R,top_off,below=10.1,16.6,12.1,3.02,math.rad(60),7,5,8
 local after=speed+2
 local z_pop=25
 local vy=(-drop+0.5*g*t_air*t_air)/t_air
 local zl,yl=z_pop+speed*t_air,HIP-drop
 local c,sn=math.cos(dg),math.sin(dg)
 local s0z,s0y=zl-HIP*sn,yl-HIP*c
 local kz,ky=s0z-top_off*c,s0y+top_off*sn
 local az,ay=s0z+below*c,s0y-below*sn
 local cz,cy=az+R*sn,ay+R*c
 local y_flat=cy-R
 local face={{kz,ky},{s0z,s0y},{az,ay}}
 for i=1,24 do local phi=-dg+dg*i/24;face[#face+1]={cz+R*math.sin(phi),cy-R*math.cos(phi)} end
 face[#face+1]={cz+400,y_flat}
 local prof={{-200,0},{z_pop,0},{z_pop+0.01,y_flat},{kz-0.01,y_flat}}
 for _,p in face do prof[#prof+1]=p end
 local path={}
 for i=2,#face do path[#path+1]=face[i] end
 local cum,total={0},0
 for i=2,#path do total+=math.sqrt((path[i][1]-path[i-1][1])^2+(path[i][2]-path[i-1][2])^2);cum[i]=total end
 local function walk(s)
  s=math.clamp(s,0,total)
  local i=2
  while i<#path and cum[i]<s do i+=1 end
  local len=math.max(cum[i]-cum[i-1],1e-6)
  local u=(s-cum[i-1])/len
  local z1,y1,z2,y2=path[i-1][1],path[i-1][2],path[i][1],path[i][2]
  local tz,ty=(z2-z1)/len,(y2-y1)/len
  return z1+(z2-z1)*u,y1+(y2-y1)*u,-ty,tz,tz,ty
 end
 local t_pop=z_pop/speed
 local function pose(t)
  if t<t_pop then return v(0,HIP,speed*t),v(0,0,speed),100 end
  t-=t_pop
  if t<t_air then return v(0,HIP+vy*t-0.5*g*t*t,z_pop+speed*t),v(0,vy-g*t,speed),t<0.08 and 200 or 201 end
  t-=t_air
  local z,y,nz,ny,tz,ty=walk(after*t)
  return v(0,y+ny*HIP,z+nz*HIP),v(0,ty*after,tz*after),100
 end
 return prof,pose,t_pop+t_air+4.5,t_pop+t_air
end
local function ray_profile(p,a,b)
 local best
 for i=1,#p-1 do
  local z1,y1,z2,y2=p[i][1],p[i][2],p[i+1][1],p[i+1][2]
  local dz,dy=z2-z1,y2-y1
  local da=(a.z-z1)*dy-(a.y-y1)*dz
  local db=(b.z-z1)*dy-(b.y-y1)*dz
  if da~=db and da*db<=0 then
   local t=da/(da-db)
   local q=a+(b-a)*t
   local u=math.abs(dz)>math.abs(dy) and (q.z-z1)/dz or (q.y-y1)/dy
   if u>=0 and u<=1 and (not best or t<best) then best=t end
  end
 end
 if best then return a+(b-a)*best end
end

local function drive()
 local prof,pose,duration,t_land=build()
 local m=Mock.install({limit_rays=true})
 m.reskate.input.gamepad=function() return nil end
 m.reskate.menu.game=function() return {open=false} end
 local app=require("app").start()
 local s=Settings.defaults()
 s.follow.camera_style="classic";s.follow.trick_pop=false;s.follow.crouch_enabled=true;s.follow.crouch_amount=1;s.follow.crouch_mode=0
 s.angle=Settings.CameraAngle.Low
 s.ride_distance.mode=Settings.DistanceMode.Fixed;s.ride_distance.fixed=1.53
 s.shake_enabled=false;s.native_plus.landing_dip=false
 assert(app.store:set_settings(s))
 m.state.raycast=function(a,b) return ray_profile(prof,a,b) end
 local PHYS=1/60
 local epoch,phys_t,t,seed=m.clock_ms,0,0,12345
 local out={step=0,front=-99,frames=0,landed=0}
 local prev
 for i=1,math.floor(duration*60) do
  seed=(seed*1103515245+12345)%2147483648
  local dt=(1/60)*(1+((seed/2147483648)*2-1)*0.12)
  t+=dt
  while phys_t+PHYS<=t+1e-9 do
   phys_t+=PHYS
   local _,pv=pose(phys_t)
   m.fire("physics_step",{at=epoch+phys_t*1000,seconds=PHYS,velocity={pv.x,pv.y,pv.z},ragdoll=false})
  end
  local root,vel,state=pose(phys_t) -- stepped host: the root moves on physics steps only
  m.state.skater.position=root;m.state.skater.heading=0;m.state.skater.airborne=AIR[state]==true
  m.state.telemetry.physics_state=state;m.state.telemetry.airborne=AIR[state]==true
  m.state.telemetry.position=root;m.state.telemetry.heading=0
  m.state.board.deck={position=root-v(0,0.6,0),rotation={0,0,0,1}}
  m.state.board.velocity=vel
  m.tick(dt*1000)
  local shown=m.last_call("set")
  local g=app.glue
  if shown and g.source=="ride" and g.blend>=1 and t>1.0 then
   local rel=shown.position-root
   out.frames+=1
   if prev and t>t_land-0.5 then out.step=math.max(out.step,mag(rel-prev)) end
   -- the travel direction is +z, so the front is rel.z>0; an eye almost overhead may lean a few cm either way
   if t>t_land+0.1 then out.front=math.max(out.front,rel.z);out.landed+=1 end
   prev=rel
  end
 end
 return out
end

local ok,r=pcall(drive)
T.expect(ok,"the bigland_60 drive runs"..(ok and "" or " ("..tostring(r)..")"))
if ok then
 T.expect(r.frames>200,"the drive produced frames ("..r.frames..")")
 T.expect(r.landed>60,"the drive covers the landing ("..r.landed..")")
 print(string.format("landing bound 1229: worst eye step %.3f m, front-most eye rel.z %.3f m",r.step,r.front))
 T.expect(r.step<=0.40,"the eye never moves more than 0.40 m around the rider in one step ("..string.format("%.3f",r.step)..")")
 T.expect(r.front<=0.30,"the eye never crosses to the front of the rider, beyond 0.30 m of overhead slack ("..string.format("%.3f",r.front)..")")
end

T.done()
print(string.format("elapsed %.2f s",os.clock()-started))
if T.failures>0 then error("landing bound regression") end
