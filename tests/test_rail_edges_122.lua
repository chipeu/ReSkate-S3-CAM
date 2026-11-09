-- Independent displayed-pose rail checks: slowing/stopping, deck roll and
-- confined floor/ceiling geometry through the actual App/Glue output path.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local OldCamera,OldEscape=require("ref_1121/camera"),require("ref_1121/collision_escape")
local v,mag=vector.create,vector.magnitude
T.group("rail_edges_122")

local slope=-0.45
local function floor(z) return slope*z end
local function motion(t)
    if t<1.5 then return 7*t,7 end
    if t<3 then
        local u=(t-1.5)/1.5
        return 10.5+1.5*(7*u-3.25*u*u),7-6.5*u
    end
    if t<4 then return 16.125+0.5*(t-3),0.5 end
    if t<4.8 then return 16.625,0 end
    local u=math.min((t-4.8)/1.2,1)
    return 16.625+1.2*(3.5*u*u),7*u
end
local function quat_roll(deg)
    local a=math.rad(deg)/2
    return {x=0,y=0,z=math.sin(a),w=math.cos(a)}
end
local function world(confined)
    return function(a,b)
        local best,best_t,best_n=nil,2,nil
        local function offer(t,n)
            if t>=0 and t<=1 and t<best_t then best,best_t,best_n=a+(b-a)*t,t,n end
        end
        local da,db=a.y-floor(a.z),b.y-floor(b.z)
        if da>=0 and db<=0 and da~=db then offer(da/(da-db),vector.normalize(v(0,1,-slope))) end
        if confined then
            -- A roof over the rail: enough room for the skater, but low enough
            -- to exercise eye protection when the camera rises on a slope.
            local ca,cb=a.y-floor(a.z)-1.35,b.y-floor(b.z)-1.35
            if ca<=0 and cb>=0 and ca~=cb then offer(-ca/(cb-ca),vector.normalize(v(0,-1,slope))) end
            -- A nearby side wall. The root travels at x=0 and cannot cross it.
            if a.x<0.32 and b.x>=0.32 and a.x~=b.x then offer((0.32-a.x)/(b.x-a.x),v(-1,0,0)) end
            if a.x>-0.32 and b.x<=-0.32 and a.x~=b.x then offer((-0.32-a.x)/(b.x-a.x),v(1,0,0)) end
        end
        return best,best_n
    end
end
local function drive(fps,roll,confined,prior)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start(prior and {camera=OldCamera} or nil)
    if prior then
        app.glue.collision_escape=OldEscape.new()
        app.glue.soft_pull_guard_enabled=false
    end
    local s=Settings.defaults()
    s.shake_enabled=false;s.native_plus.landing_dip=false
    s.framing.grind_pitch_degrees=0;s.framing_high.grind_pitch_degrees=0
    if confined then
        s.shoulder.mode=Settings.ShoulderSide.Manual
        s.shoulder.side=1
        s.shoulder.offset=0.4
    end
    assert(app.store:set_settings(s))
    local metrics={frames=0,rays=0,obstacle_hits=0,min_reach=10,min_floor=10,min_roof=10,
        min_wall=10,max_pull=0,pull_peak_t=0,slow_pull=0,stop_pull=0,regain_pull=0,
        max_relative_step=0,settled_y=nil,settled_yaw=nil,slow_reach=10,slow_pitch=-90}
    local last
    for i=1,math.floor(6.4*fps) do
        local t=i/fps
        local z,speed=motion(t)
        local root=v(0,floor(z)+0.95,z)
        m.state.skater.position=root
        m.state.telemetry.physics_state=403
        m.state.telemetry.airborne=false
        m.state.board.deck={position=v(0,floor(z),z),rotation=quat_roll(roll)}
        m.state.board.velocity=v(0,slope*speed,speed)
        local ray=world(confined)
        m.state.raycast=function(a,b)
            local hit,n=ray(a,b)
            if hit and n and (n.y<0 or math.abs(n.x)>0.5) then metrics.obstacle_hits+=1 end
            return hit,n
        end
        m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,slope*speed,speed},ragdoll=false})
        m.tick(1000/fps)
        metrics.rays=math.max(metrics.rays,m.state.raycasts)
        local shown=m.last_call("set")
        if shown and app.glue.source=="ride" and app.glue.blend>=1 and t>1 then
            local p=shown.position
            local rel=p-root
            local reach=mag(v(rel.x,0,rel.z))
            local floor_gap=p.y-floor(p.z)
            local roof_gap=floor(p.z)+1.35-p.y
            metrics.frames+=1
            metrics.min_reach=math.min(metrics.min_reach,reach)
            metrics.min_floor=math.min(metrics.min_floor,floor_gap)
            if confined then
                metrics.min_roof=math.min(metrics.min_roof,roof_gap)
                metrics.min_wall=math.min(metrics.min_wall,0.32-math.abs(p.x))
            end
            local pulled=app.glue.frame and app.glue.frame.debug.collision_pull or 0
            if pulled>metrics.max_pull then metrics.max_pull,metrics.pull_peak_t=pulled,t end
            if t>=3.5 and t<4 then metrics.slow_pull=math.max(metrics.slow_pull,pulled) end
            if t>=4 and t<4.8 then metrics.stop_pull=math.max(metrics.stop_pull,pulled) end
            if t>=4.8 then metrics.regain_pull=math.max(metrics.regain_pull,pulled) end
            if last then metrics.max_relative_step=math.max(metrics.max_relative_step,mag(rel-last)) end
            last=rel
            if t>=3.5 and t<4 then
                metrics.slow_reach=math.min(metrics.slow_reach,reach)
                metrics.slow_pitch=math.max(metrics.slow_pitch,math.deg(math.asin(-shown.forward.y)))
            end
            if t>6.1 then
                metrics.settled_y=rel.y
                metrics.settled_yaw=math.atan2(shown.forward.x,shown.forward.z)
            end
            T.expect(floor_gap>=-0.03 and (not confined or (roof_gap>=-0.03 and metrics.min_wall>=-0.03)),
                "shown eye stays outside sloped floor and nearby roof")
            T.expect(reach>0.65,"shown eye retains personal distance")
        end
    end
    T.expect(app.errors==0 and metrics.rays<=64,"rail edge App/Glue stays within callback and ray limits")
    T.expect(metrics.frames>fps*4,"rail edge fixture displays sustained riding frames")
    T.expect(metrics.slow_reach<10 and metrics.slow_pitch>-90,"slow rail interval is observed")
    if confined then T.expect(metrics.obstacle_hits>0,"rail eye rays encounter nearby wall or roof") end
    return metrics
end

for _,fps in {30,60,144} do
    local level=drive(fps,0,false)
    local nose=drive(fps,70,false)
    local crook=drive(fps,-70,false)
    local confined=drive(fps,0,true)
    local old=drive(fps,0,false,true)
    print(string.format("rail edge %d: reach %.3f old %.3f nose %.3f crook %.3f confined %.3f, pull %.3f@%.2f old %.3f slow %.3f stop %.3f regain %.3f floor %.3f roof %.3f wall %.3f step %.3f rays %d",
        fps,level.min_reach,old.min_reach,nose.min_reach,crook.min_reach,confined.min_reach,
        level.max_pull,level.pull_peak_t,old.max_pull,level.slow_pull,level.stop_pull,level.regain_pull,
        confined.min_floor,confined.min_roof,confined.min_wall,confined.max_relative_step,confined.rays))
    T.expect(math.abs(nose.settled_y-level.settled_y)<0.15 and math.abs(crook.settled_y-level.settled_y)<0.15,
        "nose/crook roll does not greatly change settled rail eye height")
    T.expect(math.abs(nose.settled_yaw-level.settled_yaw)<math.rad(4)
        and math.abs(crook.settled_yaw-level.settled_yaw)<math.rad(4),
        "nose/crook roll does not swing settled travel yaw")
    T.expect(level.slow_reach>1.25 and confined.slow_reach>1.25,
        "slow/near-stop rail keeps the camera away from the skater")
    T.expect(level.min_reach>old.min_reach+0.3 and level.max_pull<old.max_pull-0.3
        and level.slow_pull<0.1 and level.stop_pull<0.1 and level.regain_pull<0.1,
        "slowing, stopping and regaining speed retain improved rail distance and clearance")
end
T.done()
if T.failures>0 then error("rail edge tests failed") end
