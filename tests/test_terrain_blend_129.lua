local T,Terrain=require("tlib"),require("terrain_context")
local Camera,Settings,Subject=require("camera"),require("settings"),require("subject")
local v=vector.create
T.group("terrain blend 129")
for _,fps in {30,60,144} do
 local c=Terrain.new()
 local prior_w,prior_v=0,0
 local reversals=0
 local previous_target=0
 for i=1,4*fps do
  local steep=i<=math.floor(0.5*fps) or (i>fps and i<=math.floor(1.3*fps))
  local s={position=v(0,0.95,0),velocity=v(5,steep and 2 or 0,0),state=100,
   ground_valid=true,ground_height=0,ground_normal=steep and v(-0.7,0.714,0) or v(0,1,0)}
  local out=c:update(s,1/fps,function(a,b)
   if a.y>=0 and b.y<=0 then return v(a.x,0,a.z) end
  end)
  local vel=c.weight_velocity or 0
  T.expect(out.weight>=0 and out.weight<=1,"blend stays bounded")
  T.expect(math.abs(vel-prior_v)<160/fps,"blend velocity changes through bounded acceleration")
  T.expect(math.abs(out.weight-prior_w)<8/fps,"no single-frame blend jump")
  if out.target~=previous_target then reversals+=1 end
  previous_target,prior_w,prior_v=out.target,out.weight,vel
  if i==1 then
   T.expect(out.weight<0.04*60/fps,"entry starts gently instead of changing follow strength at once")
   T.expect(vel>0,"blend carries explicit velocity")
  end
 end
 T.expect(reversals>=4,"fixture repeatedly enters and leaves steep terrain")
 T.expect(c.weight==0 and c.weight_velocity==0,"settled flat retires blend and velocity")
 c:reset()
 T.expect(c.weight==0 and c.weight_velocity==0,"session cut resets both blend states")
end
for _,fps in {30,60,144} do -- Camera consumes the continuous share even after reason becomes flat.
 local settings=Settings.defaults();settings.follow.trick_pop=false
 settings.follow.crouch_enabled=false;settings.shake_enabled=false
 settings.native_plus.landing_dip=false;settings.trick_yaw.enabled=false
 local cam=Camera.new();assert(cam:set_settings(settings))
 local previous,saw_flat,had_ramp=nil,false,false
 for i=1,math.floor(1.8*fps) do
  local t=i/fps
  local ramp=t<0.8 or t>=1.3
  local snap=Subject.new_snapshot()
  snap.valid,snap.onboard,snap.board_valid,snap.ground_valid=true,true,true,true
  snap.physics_state=100;snap.time=t;snap.position=v(0,0.95,5*t)
  snap.board_position=snap.position-v(0,0.95,0)
  snap.velocity=v(0,ramp and 2 or 0,5);snap.physical_velocity=snap.velocity
  snap.physical_height=snap.position.y;snap.forward=v(0,0,1)
  snap.ground_normal=ramp and v(0,0.714,-0.7) or v(0,1,0)
  snap.ground_height=0;snap.ground_clearance=0.95
  cam:update(1/fps,snap,function() return nil end,{base_fov_deg=65})
  local context=cam.terrain_context_result
  local share=cam.ramp_render_follow
  T.expect(share==context.transition_weight,"camera uses terrain ramp share")
  if previous then T.expect(math.abs(share-previous)<0.17,"camera ramp share remains frame-continuous") end
  if t>0.65 and t<0.8 and share>0.9 then had_ramp=true end
  if t>=0.8 and t<1.3 and context.reason=="flat" and context.weight>0 and share>0 then saw_flat=true end
  previous=share
 end
 T.expect(had_ramp and saw_flat,"camera carries ramp view through flat reason at "..fps.." Hz")
end
do -- The ramp view must outlive a detector reason change and ease through re-entry.
 local c=Terrain.new()
 local s={position=v(0,0.95,0),velocity=v(5,2,0),state=100,
  ground_valid=true,ground_height=0,ground_normal=v(-0.7,0.714,0)}
 local function flat_query(a,b)
  if a.y>=0 and b.y<=0 then return v(a.x,0,a.z) end
 end
 local out
 for _=1,60 do out=c:update(s,1/60,flat_query) end
 T.expect(out.reason=="transition" and out.transition_weight>0.99,"ramp share reaches full weight")
 s.velocity,s.ground_normal=v(5,0,0),v(0,1,0)
 local saw_flat=false
 local previous=out.transition_weight
 for _=1,18 do
  out=c:update(s,1/60,flat_query)
  T.expect(math.abs(out.transition_weight-previous)<0.06,"ramp release has no frame jump")
  T.expect(out.transition_weight<=previous,"ramp share releases monotonically")
  if out.reason=="flat" then
   saw_flat=true
   T.expect(out.transition_weight>0 and out.weight>0,"reason change preserves releasing ramp and terrain shares")
  end
  previous=out.transition_weight
 end
 T.expect(saw_flat,"flat runout clears ramp detector")
 s.velocity,s.ground_normal=v(5,2,0),v(-0.7,0.714,0)
 out=c:update(s,1/60,flat_query)
 T.expect(out.reason=="transition" and math.abs(out.transition_weight-previous)<0.06,
  "ramp re-entry resumes the continuous share")
 for _=1,20 do out=c:update(s,1/60,flat_query) end
 T.expect(out.transition_weight>previous,"re-entered ramp share grows toward full")
 c:reset()
 T.expect(c.transition_weight==0 and c.transition_velocity==0,"cut clears ramp share")
 s.velocity,s.ground_normal=v(5,5,0),v(0,1,0)
 for _=1,60 do out=c:update(s,1/60,flat_query) end
 T.expect(out.reason=="flat" and out.transition_weight==0,"flat vertical motion never activates ramp view")
end
T.done()
if T.failures>0 then error("terrain blend regressions") end
