-- Contracts of the 1.2.31 vert look-down: on a vert launch with Pop On the eye still lifts to look down at the
-- landing (downhill_lift >= 25 degrees, view pitch below -35 degrees during the fall), Pop Off keeps its lift,
-- Pop On away from ramps stays at zero lift, and the lift rises eased (under 3 degrees per 60 FPS step).
-- Geometry of route_vert in tests/testbox/routes.lua (radius 4 m, 10 m/s, pop 8 m/s). Whole App on a stepped host.
-- Failure is counted by tlib; the file errors at the end so the gate sees a non-zero exit.
local T,Mock,Settings=require("tlib"),require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
local started=os.clock()

local HIP,G,AIR=0.95,9.8,{[200]=true,[201]=true}
local function ballistic(y0,vy0,u) return y0+vy0*u-0.5*G*u*u,vy0-G*u end
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

-- Vert: flat run-in, quarter arc, vertical extension; pop straight up from the lip, fall back in.
local function route_vert()
 local R,flat,speed,vy=4,18,10,8
 local prof={{-200,0},{flat,0}}
 for i=0,24 do local a=(math.pi/2)*i/24;prof[#prof+1]={flat+R*math.sin(a),R-R*math.cos(a)} end
 prof[#prof+1]={flat+R,R+2}
 local t_flat,t_arc,t_air=flat/speed,(math.pi/2)*R/speed,2*vy/G
 local function surf(a) local r=R-HIP;return v(0,R-r*math.cos(a),flat+r*math.sin(a)) end
 local top=surf(math.pi/2)
 local function pose(t)
  if t<t_flat then return v(0,HIP,speed*t),v(0,0,speed),100,0 end
  t-=t_flat
  if t<t_arc then local a=t*speed/R;return surf(a),v(0,math.sin(a),math.cos(a))*speed,100,0 end
  t-=t_arc
  if t<t_air then
   local y,w=ballistic(top.y,vy,t)
   return v(0,y,top.z),v(0,w,0),t<0.08 and 200 or 201,math.pi*math.clamp(t/t_air,0,1)
  end
  t-=t_air
  if t<t_arc then local a=math.pi/2-t*speed/R;return surf(a),v(0,-math.sin(a),-math.cos(a))*speed,100,math.pi end
  t-=t_arc
  return v(0,HIP,flat-speed*t),v(0,0,-speed),100,math.pi
 end
 local t_apex=t_flat+t_arc+t_air/2
 return {prof=prof,boxes={{v(-40,-1,flat+R+0.02),v(40,R+2,flat+R+8.02)}},pose=pose,
  duration=t_flat+t_arc+t_air+t_arc+0.8,fall0=t_apex,fall1=t_flat+t_arc+t_air+t_arc}
end

-- Flat ground: ride, pop straight up at 5 m/s, land, ride on. The normal stays up. pop=nil is a plain ride.
local function route_flat(pop)
 local speed,z_pop=6,9
 local t_pop=z_pop/speed
 local t_air=pop and 2*pop/G or 0
 local function pose(t)
  if t<t_pop then return v(0,HIP,speed*t),v(0,0,speed),100,0 end
  t-=t_pop
  if t<t_air then local y,w=ballistic(HIP,pop,t);return v(0,y,z_pop+speed*t),v(0,w,speed),t<0.08 and 200 or 201,0 end
  t-=t_air
  return v(0,HIP,z_pop+speed*(t+t_air)),v(0,0,speed),100,0
 end
 return {prof={{-300,0},{400,0}},pose=pose,duration=t_pop+t_air+2.5,fall0=t_pop,fall1=t_pop+t_air+2.5}
end

local function drive(route,pop_on)
 local m=Mock.install({limit_rays=true})
 m.reskate.input.gamepad=function() return nil end
 m.reskate.menu.game=function() return {open=false} end
 local app=require("app").start()
 local s=Settings.defaults()
 s.follow.camera_style="classic";s.follow.trick_pop=pop_on;s.follow.crouch_enabled=true;s.follow.crouch_amount=1;s.follow.crouch_mode=0
 s.angle=Settings.CameraAngle.Low
 s.ride_distance.mode=Settings.DistanceMode.Fixed;s.ride_distance.fixed=1.53
 s.shake_enabled=false;s.native_plus.landing_dip=false
 assert(app.store:set_settings(s))
 local ray_box=function(a,b)
  for _,box in route.boxes or {} do
   local t0,t1,d=0,1,b-a
   local hit=true
   for _,ax in {"x","y","z"} do
    local o,sd,lo,hi=a[ax],d[ax],box[1][ax],box[2][ax]
    if math.abs(sd)<1e-9 then if o<lo or o>hi then hit=false;break end
    else
     local n,f=(lo-o)/sd,(hi-o)/sd
     if n>f then n,f=f,n end
     t0,t1=math.max(t0,n),math.min(t1,f)
     if t0>t1 then hit=false;break end
    end
   end
   if hit then return t0 end
  end
 end
 m.state.raycast=function(a,b)
  local p=ray_profile(route.prof,a,b)
  local bt=ray_box(a,b)
  if bt and (not p or bt<mag(p-a)/math.max(mag(b-a),1e-9)) then return a+(b-a)*bt end
  return p
 end
 local PHYS,dt=1/60,1/60
 local epoch,phys_t,t=m.clock_ms,0,0
 local out={frames=0,fall=0,maxlift=0,maxflight=0,minpitch=0,step=0}
 local prev_lift
 for _=1,math.floor(route.duration*60) do
  t+=dt
  while phys_t+PHYS<=t+1e-9 do
   phys_t+=PHYS
   local _,pv=route.pose(phys_t)
   m.fire("physics_step",{at=epoch+phys_t*1000,seconds=PHYS,velocity={pv.x,pv.y,pv.z},ragdoll=false})
  end
  local root,vel,state,heading=route.pose(phys_t)
  local air=AIR[state]==true
  m.state.skater.position=root;m.state.skater.heading=heading;m.state.skater.airborne=air
  m.state.telemetry.physics_state=state;m.state.telemetry.airborne=air
  m.state.telemetry.position=root;m.state.telemetry.heading=math.deg(heading)
  m.state.board.deck={position=root-v(0,0.6,0),rotation={0,0,0,1}}
  m.state.board.velocity=vel
  m.tick(dt*1000)
  local shown=m.last_call("set")
  local g=app.glue
  if shown and g.source=="ride" and g.blend>=1 and t>1.0 then
   local d=g.frame and g.frame.debug or {}
   local lift=math.deg(d.downhill_lift or 0)
   local pitch=math.deg(math.asin(math.clamp(shown.forward.y,-1,1)))
   out.frames+=1
   if prev_lift then out.step=math.max(out.step,math.abs(lift-prev_lift)) end
   prev_lift=lift
   out.maxlift=math.max(out.maxlift,lift)
   if air then out.maxflight=math.max(out.maxflight,math.abs(lift)) end
   if t>=route.fall0 and t<=route.fall1 then
    out.fall+=1
    out.fallift=math.max(out.fallift or -99,lift)
    out.minpitch=math.min(out.minpitch,pitch)
   end
   out.alllift=math.max(out.alllift or 0,math.abs(lift))
  end
 end
 return out
end

local function run(name,route,pop_on)
 local ok,r=pcall(drive,route,pop_on)
 T.expect(ok,name.." drive runs"..(ok and "" or " ("..tostring(r)..")"))
 if ok then T.expect(r.frames>100 and r.fall>10,name.." drive covers the fall ("..r.frames.." frames, "..r.fall.." in the fall)") end
 return ok and r or nil
end

T.group("vert look-down 1231")
local on=run("vert pop on",route_vert(),true)
if on then
 print(string.format("vert pop on: fall lift %.1f deg, min pitch %.1f deg, max lift step %.2f deg",on.fallift or 0,on.minpitch,on.step))
 T.expect((on.fallift or 0)>=25,"1: pop on vert lift reaches 25 degrees in the fall ("..string.format("%.1f",on.fallift or 0)..")")
 T.expect(on.minpitch<-35,"1: pop on vert view pitches below -35 degrees in the fall ("..string.format("%.1f",on.minpitch)..")")
 T.expect(on.step<3,"4: the lift rises under 3 degrees per step ("..string.format("%.2f",on.step)..")")
end

T.group("vert pop off 1231")
local off=run("vert pop off",route_vert(),false)
if off then
 print(string.format("vert pop off: fall lift %.1f deg, min pitch %.1f deg",off.fallift or 0,off.minpitch))
 T.expect((off.fallift or 0)>=25,"2: pop off vert lift still reaches 25 degrees ("..string.format("%.1f",off.fallift or 0)..")")
end

T.group("flat ground pop on 1231")
local flat=run("flat ollie pop on",route_flat(5),true)
if flat then
 print(string.format("flat ollie pop on: largest lift %.3f deg",flat.alllift or 0))
 T.expect((flat.alllift or 0)<1,"3: a flat ollie gives under 1 degree of lift over the flight and landing ("..string.format("%.3f",flat.alllift or 0)..")")
end
local ride=run("flat ride pop on",route_flat(nil),true)
if ride then T.expect((ride.alllift or 0)<1,"3: a hill-less ride gives no lift ("..string.format("%.3f",ride.alllift or 0)..")") end

T.done()
print(string.format("elapsed %.2f s",os.clock()-started))
if T.failures>0 then error("vert look-down regression") end
