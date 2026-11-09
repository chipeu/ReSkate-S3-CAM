-- Full App/Glue ramp regression using the user's saved profile, a 60 Hz
-- physics clock, and the camera's actual modeled plane queries.
local T=require("tlib")
local Mock,Settings,Presets=require("mock_reskate"),require("settings"),require("presets")
local v,mag=vector.create,vector.magnitude
T.group("full crouch 122")

local lip,air_time=2.5,14/9.8
local land=lip+air_time
local function surface(z)
 if z<8 then return 0,0 end
 if z<20 then return 1.2*(z-8),1.2 end
 if z<32 then return 14.4,0 end
 return 14.4-0.5*(z-32),-0.5
end
local function pose(t)
 local z=8*t
 local support=surface(z)
 local state=100
 local vy=0
 local y=0.95+support
 if t>=lip and t<land then
  local u=t-lip
  y=15.35+7*u-4.9*u*u
  vy=7-9.8*u
  state=u<0.08 and 200 or 201
 elseif z>=8 and z<20 then vy=9.6
 elseif z>=32 then vy=-4 end
 -- A drawn body compression/lean is independent of board travel. It is
 -- largest at the lip, where a vertical crouch reference is most exposed.
 local compression=0
 if t<lip and z>13 then compression=0.5*math.sin(0.5*math.pi*(z-13)/7)
 elseif t>=lip and t<lip+0.12 then compression=0.5*(1-(t-lip)/0.12) end
 if z>3 and z<7 then compression=0.5*math.sin(math.pi*(z-3)/4) end
 local deck_y=state==100 and support or y-0.95
 return v(0,y-compression,z),v(0,vy,8),state,v(0,deck_y,z),compression
end
local planes={{0,0,-1000,8},{1.2,-9.6,8,20},{0,14.4,20,32},{-0.5,30.4,32,1000}}
local function world(a,b)
 local hit,normal
 for _,p in planes do
  local grade,offset,lo,hi=table.unpack(p)
  local da,db=a.y-grade*a.z-offset,b.y-grade*b.z-offset
  if da~=db then
   local f=da/(da-db)
   if f>=0 and f<=1 then
    local q=a+(b-a)*f
    if q.z>=lo and q.z<=hi and (not hit or mag(q-a)<mag(hit-a)) then
     hit,normal=q,vector.normalize(v(0,1,-grade))
    end
   end
  end
 end
 return hit,normal
end

local function drive(fps,angle,pop,crouch)
 local m=Mock.install({limit_rays=true})
 m.reskate.input.gamepad=function() return nil end
 m.reskate.menu.game=function() return {open=false} end
 local app=require("app").start()
 local cs,opts=Presets.from_values(require("user_values_121"))
 cs.angle=angle
 cs.follow.trick_pop=pop
 cs.follow.crouch_enabled=crouch
 cs.follow.crouch_amount=1
 cs.follow.camera_style="classic"
 cs.shake_enabled=false
 cs.native_plus.landing_dip=false
 opts.camera_sway=false
 opts.stable_timing=true
 assert(app.store:set_settings(cs))
 app.store:set_options(opts)
 local out={frames=0,air=0,down=0,peak_step=0,peak_turn=0,peak_correction=0,
  peak_fov_step=0,floor_clips=0,peak_floor_depth=0,floor_times={},peak_gap=0,max_rays=0,errors=0,body_lift=0,land_steps=0,
  step_at=0,turn_at=0,correction_at=0,postlanding_turn=0}
 local previous,phys_t,epoch=nil,0,m.clock_ms
 for i=1,math.floor(7*fps) do
  local t=i/fps
  local root,velocity,state,deck,compression=pose(t)
  m.state.skater.position=root
  m.state.telemetry.physics_state=state
  m.state.telemetry.airborne=state==200 or state==201
  m.state.board.deck={position=deck,rotation={0,0,0,1}}
  m.state.board.velocity=velocity
  m.state.raycast=world
  while phys_t+1/60<=t+1e-8 do
   phys_t+=1/60
   local _,pv=pose(phys_t)
   m.fire("physics_step",{at=epoch+phys_t*1000,seconds=1/60,
    velocity={pv.x,pv.y,pv.z},ragdoll=false})
  end
  m.tick(1000/fps)
  out.max_rays=math.max(out.max_rays,m.state.raycasts)
  local shown=m.last_call("set")
  if shown and app.glue.source=="ride" and app.glue.blend>=1 then
   local rel=shown.position-root
   local pitch=math.deg(math.asin(shown.forward.y))
   local fov=shown.fov or 65
   local d=app.glue.frame and app.glue.frame.debug or {}
   out.frames+=1
   if t>=lip and t<land then
    out.air+=1
    if velocity.y<0 then out.down+=1 end
   end
   if t>=land and t<land+0.25 then out.land_steps+=1 end
   if compression>0.1 then out.body_lift=math.max(out.body_lift,math.abs(d.crouch_compensation or 0)) end
   if t>1 and t<5 then
    out.peak_gap=math.max(out.peak_gap,math.abs(rel.y))
    if (app.glue.body_correction or 0)>out.peak_correction then
     out.peak_correction=app.glue.body_correction;out.correction_at=t
    end
    if previous then
     if mag(rel-previous.rel)>out.peak_step then out.peak_step=mag(rel-previous.rel);out.step_at=t end
     if math.abs(pitch-previous.pitch)>out.peak_turn then out.peak_turn=math.abs(pitch-previous.pitch);out.turn_at=t end
     if t>land+0.1 then out.postlanding_turn=math.max(out.postlanding_turn,math.abs(pitch-previous.pitch)) end
    end
    local floor=world(shown.position+v(0,1,0),shown.position-v(0,2,0))
    if floor and shown.position.y<floor.y+0.25 then
     out.floor_clips+=1
     out.peak_floor_depth=math.max(out.peak_floor_depth,floor.y+0.25-shown.position.y)
     if #out.floor_times<3 then table.insert(out.floor_times,string.format("%.3f:%.3f",t,floor.y+0.25-shown.position.y)) end
    end
   end
   previous={rel=rel,pitch=pitch,fov=fov}
  end
 end
 out.errors=app.errors
 return out
end

for _,fps in {30,60,144} do
 for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
  for _,pop in {false} do
   for _,crouch in {true} do
    local o=drive(fps,angle,pop,crouch)
    local name=string.format("%d %s Pop%s Crouch%s",fps,
     angle==Settings.CameraAngle.Low and "Low" or "High",pop and "On" or "Off",crouch and "On" or "Off")
    print("vert121",name,"frames",o.frames,"air",o.air,"down",o.down,
     "step",o.peak_step,o.step_at,"turn",o.peak_turn,o.turn_at,"postlandingTurn",o.postlanding_turn,
     "correction",o.peak_correction,o.correction_at,
     "gap",o.peak_gap,"floor",o.floor_clips,o.peak_floor_depth,table.concat(o.floor_times,","),"rays",o.max_rays)
    T.expect(o.frames>fps*5 and o.air>fps and o.down>fps*0.4 and o.land_steps>0,name.." covers ramp, air descent, landing")
    T.expect(o.max_rays<=64 and o.errors==0,name.." respects SDK ray cap without errors")
    T.expect(o.floor_clips==0,name.." keeps the displayed eye above modeled floor")
    T.expect(o.peak_step<(pop and 0.22 or 0.31),name.." bounds subject-relative displayed movement")
    T.expect(o.postlanding_turn<math.max(6,120/fps),name.." bounds post-landing displayed pitch change")
    T.expect(o.peak_turn<math.max(6,120/fps),name.." full crouch takeoff retains continuous pitch")
    T.expect(o.peak_fov_step<0.01,name.." full crouch cannot change FOV")
    T.expect(o.peak_correction<0.7,name.." bounds post-core safety and guard reposition")
    T.expect(o.peak_gap<4,name.." follows physical vert travel")
    if not crouch then T.expect(o.body_lift>0.05,name.." neutralizes drawn body compression") end
   end
  end
 end
end
T.done()
if T.failures>0 then error("Pop On vert regression") end
