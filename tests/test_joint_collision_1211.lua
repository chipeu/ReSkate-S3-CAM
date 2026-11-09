-- The requested 1.1.14 Classic collision contract: solid eye/swept clearance
-- and no greater contraction step than the actual reference release.
-- The conservative radius envelope is reported separately, not hidden.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("joint collision 1211")
local function box(a,b,radius)
    radius=radius or 0
    local lo,hi=0,1
    for _,axis in {"x","y","z"} do
        local low=(axis=="x" and -0.38 or axis=="y" and 0 or 20)-radius
        local high=(axis=="x" and 0.38 or axis=="y" and 0.75 or 20.18)+radius
        local d=b[axis]-a[axis]
        if math.abs(d)<1e-8 then
            if a[axis]<low or a[axis]>high then return nil end
        else
            local x,y=(low-a[axis])/d,(high-a[axis])/d
            if x>y then x,y=y,x end
            lo,hi=math.max(lo,x),math.min(hi,y)
            if lo>hi then return nil end
        end
    end
    return a+(b-a)*lo
end
local function world(a,b)
    local wall=box(a,b)
    local floor
    if a.y>=0 and b.y<=0 and a.y~=b.y then floor=a+(b-a)*(a.y/(a.y-b.y)) end
    if wall and floor then return mag(wall-a)<mag(floor-a) and wall or floor,v(0,1,0) end
    if wall then return wall,v(0,0,-1) end
    if floor then return floor,v(0,1,0) end
end
local m=Mock.install({limit_rays=true})
m.reskate.input.gamepad=function() return nil end
m.reskate.menu.game=function() return {open=false} end
local app=require("app").start()
local s=Settings.defaults()
s.angle=Settings.CameraAngle.Low
s.follow.trick_pop=false;s.follow.pop_amount=1
s.follow.crouch_enabled=false;s.follow.crouch_amount=1
s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.53
s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.40
s.shoulder.mode=Settings.ShoulderSide.Manual;s.shoulder.side=1;s.shoulder.offset=0.6
s.shake_enabled=false;s.native_plus.landing_dip=false
assert(app.store:set_settings(s))
local envelope=0
local max_pull,max_step,max_rays,penetrations,min_x,max_x,frames=0,0,0,0,1e3,-1e3,0
local prior
local max_ray_segment=0
for i=1,240 do
    local t=i/60
    local z=5+10*t
    m.state.skater.position=v(0.6,0.95,z)
    m.state.joints[103]=m.state.skater.position+v(0,0.8,0)
    m.state.joints[7]=m.state.skater.position
    m.state.telemetry.physics_state=100
    m.state.telemetry.airborne=false
    m.state.board.deck={position=v(0.6,0,z),rotation={0,0,0,1}}
    m.state.board.velocity=v(0,0,10)
    m.state.raycast=function(a,b)
        max_ray_segment=math.max(max_ray_segment,mag(b-a))
        return world(a,b)
    end
    m.fire("physics_step",{at=i*1000/60,seconds=1/60,velocity={0,0,10},ragdoll=false})
    m.tick(1000/60)
    local shown=m.last_call("set")
    local g=app.glue
    if shown and g.source=="ride" and g.blend>=1 then
        local p=shown.position
        if p.z>12 and p.z<23 then
            frames+=1
            min_x,max_x=math.min(min_x,p.x),math.max(max_x,p.x)
            max_pull=math.max(max_pull,g.frame.debug.collision_pull or 0)
            max_rays=math.max(max_rays,g.rays_tick)
            if box(p,p) or (prior and box(prior.pos,p)) then penetrations+=1 end
            if box(p,p,0.25) or (prior and box(prior.pos,p,0.25)) then envelope+=1 end
            if prior then
                local step=mag((p-m.state.skater.position)-prior.rel)
                max_step=math.max(max_step,step)
            end
            prior={pos=p,rel=p-m.state.skater.position}
        end
    end
end
print(string.format("Glue fast Low: frames %d x %.2f..%.2f pull %.3f step %.3f rays %d penetrations %d",
    frames,min_x,max_x,max_pull,max_step,max_rays,penetrations))
T.expect(app.errors==0 and frames>40 and max_rays<=64,"fast Low fixture runs within ray budget")
T.expect(penetrations==0,"final shown eye and swept path do not enter the solid lip")
T.expect(max_step<0.25 and max_pull<0.85,"classic contraction stays within the actual 1.1.14 reference motion bounds")
print("Conservative radius envelope samples (diagnostic only):",envelope)
-- A marker/level cut must discard both the desired-eye velocity history and
-- the previous safe-eye sweep origin before any new predictive cast.
if app.glue.collision_escape then
app.glue.eye_base_last=v(10000,10000,10000)
app.glue.collision_escape.last_output=v(10000,10000,10000)
app.glue.cam:cut()
max_ray_segment=0
m.state.skater.position=v(0.6,0.95,50)
m.state.board.deck={position=v(0.6,0,50),rotation={0,0,0,1}}
m.fire("physics_step",{at=241*1000/60,seconds=1/60,velocity={0,0,10},ragdoll=false})
m.tick(1000/60)
T.expect(max_ray_segment<=32.1 and (app.glue.eye_base_last==nil or mag(app.glue.eye_base_last-v(10000,10000,10000))>100),
    "camera cut clears predictive eye cache and keeps forecast rays bounded")
end
T.done()
if T.failures>0 then error("Classic collision regressions failed") end
