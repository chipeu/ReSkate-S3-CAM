local T = require("tlib")
T.group("collision prediction 121")
local New = require("collision_escape")
local Old = require("ref_1120/collision_escape")
local v = vector.create
local mag = vector.magnitude

-- A narrow, chest-height ledge. Segment/box intersection returns the first
-- contact point, like the game's point-only world ray.
local function box(a, b, half, z0, z1, ylow, yhigh)
    local lo, hi = 0, 1
    for _, axis in ipairs({"x", "y", "z"}) do
        local low = axis == "x" and -half or axis == "y" and (ylow or 0.35) or z0
        local high = axis == "x" and half or axis == "y" and (yhigh or 1.8) or z1
        local d = b[axis] - a[axis]
        if math.abs(d) < 1e-8 then
            if a[axis] < low or a[axis] > high then return nil end
        else
            local t0, t1 = (low-a[axis])/d, (high-a[axis])/d
            if t0 > t1 then t0,t1=t1,t0 end
            lo,hi=math.max(lo,t0),math.min(hi,t1)
            if lo > hi then return nil end
        end
    end
    return a + (b-a)*lo
end

local function trace(module, fps, wall, predictive)
    local e=module.new()
    local first_offset, first_pull, rays_max, max_step = nil,nil,0,0
    local ahead_count, max_pull, previous = 0, 0, nil
    local speed=5
    for i=1,math.floor(1.2*fps) do
        local t=(i-1)/fps
        local z=-1.6+speed*t
        local pivot, ideal=v(0.4,1,z),v(0,1,z-2)
        local arm=mag(ideal-pivot)
        local direction=(ideal-pivot)/arm
        local count=0
        local function cast(a,b)
            count+=1
            return box(a,b,wall.half,wall.z0,wall.z1)
        end
        local target=ideal
        if predictive then
            count=0
            target=e:step(ideal,pivot,arm,0,t,1/fps,cast,10,true,v(0,0,speed))
            rays_max=math.max(rays_max,count)
            T.expect(count<=10,"bounded predictive rays at "..fps)
            local offset=mag(target-ideal)
            if offset>0.005 and not first_offset then first_offset=i end
            if not first_pull and offset>0.005 then ahead_count+=1 end
        end
        local hit=cast(pivot,target)
        local base,pull=target,0
        if hit then
            local clear=math.max(0.25,mag(hit-pivot)-0.08)
            base=pivot+(target-pivot)/mag(target-pivot)*clear
            pull=mag(target-pivot)-clear
            if not first_pull then first_pull=i end
        end
        max_pull=math.max(max_pull,pull)
        local eye=base
        if not predictive then
            count=0
            eye=e:step(base,pivot,arm,pull,t,1/fps,cast,10,true,v(0,0,speed))
            rays_max=math.max(rays_max,count)
            T.expect(count<=10,"bounded old helper rays at "..fps)
        end
        if mag(eye-base)>1e-5 then
            T.expect(not box(base,eye,wall.half,wall.z0,wall.z1),"correction sweep stays outside ledge")
            T.expect(not box(pivot,eye,wall.half,wall.z0,wall.z1),"shown view stays outside ledge")
        end
        T.expect(mag(eye-base)<=0.47,"small local correction")
        local relative=eye-pivot
        if previous then max_step=math.max(max_step,mag(relative-previous)) end
        previous=relative
        if not predictive then
            local offset=mag(eye-base)
            if offset>0.005 and not first_offset then first_offset=i end
            if not first_pull and offset>0.005 then ahead_count+=1 end
        end
    end
    return {first_offset=first_offset,first_pull=first_pull,ahead_count=ahead_count,
        max_pull=max_pull,max_step=max_step,rays_max=rays_max}
end

-- Exercise the actual camera and Glue output path with a raised ledge in the
-- trailing eye's route. The skater's root remains above it.
do
    local Mock,Settings,Camera,Before=require("mock_reskate"),require("settings"),require("camera"),require("ref_1120/camera")
    local function live(module)
        local m=Mock.install({limit_rays=true})
        m.reskate.input.gamepad=function() return nil end
        m.reskate.menu.game=function() return {open=false} end
        local app=require("app").start({camera=module})
        if module==Before then app.glue.collision_prediction_enabled=false end
        local s=Settings.defaults();s.shake_enabled=false
        s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2
        s.shoulder.mode=Settings.ShoulderSide.Manual;s.shoulder.side=1;s.shoulder.offset=0.4
        assert(app.store:set_settings(s))
        local max_rays,max_pull,first_side,first_pull=0,0,nil,nil
        local min_eye_gap,penetrations=10,0
        m.state.raycast=function(a,b)
            local hit=box(a,b,0.12,2.5,2.62)
            if hit then return hit end
            if a.y>=0 and b.y<0 then return a+(b-a)*(a.y/(a.y-b.y)) end
            return nil
        end
        for i=1,180 do
            m.state.skater.position=v(0.4,0.95,-1.6+i*5/60)
            m.state.board.velocity=v(0,0,5)
            m.fire("physics_step",{at=i*1000/60,seconds=1/60,velocity={0,0,5},ragdoll=false})
            m.tick(1000/60)
            max_rays=math.max(max_rays,m.state.raycasts)
            local g=app.glue
            local d=g.frame and g.frame.debug
            if d and g.source=="ride" and g.blend>=1 then
                max_pull=math.max(max_pull,d.collision_pull or 0)
                if (d.collision_pull or 0)>0.01 and not first_pull then first_pull=i end
                if math.abs(g.collision_escape.offset)>0.01 and not first_side then first_side=i end
                local shown=m.last_call("set")
                if shown then
                    local p=shown.position
                    if box(p,p,0.12,2.5,2.62) then penetrations+=1 end
                    if p.z>=2.3 and p.z<=2.8 then
                        min_eye_gap=math.min(min_eye_gap,math.abs(p.x-0.4))
                    end
                    T.expect(p.y>=0.3,"Glue floor clearance")
                end
            end
            T.expect(m.state.raycasts<=64 and g.rays_tick<=64,"Glue stays under 64 rays")
        end
        T.expect(app.errors==0,"live collision fixture has no app errors")
        return {max_rays=max_rays,max_pull=max_pull,first_side=first_side,first_pull=first_pull,
            min_eye_gap=min_eye_gap,penetrations=penetrations}
    end
    local new,old=live(Camera),live(Before)
    print(string.format("Glue 60 fps: side %s vs %s, pull %s vs %s, peak pull %.3f vs %.3f, rays %d vs %d, penetrations %d vs %d",
        tostring(new.first_side),tostring(old.first_side),tostring(new.first_pull),tostring(old.first_pull),
        new.max_pull,old.max_pull,new.max_rays,old.max_rays,new.penetrations,old.penetrations))
    T.expect(new.max_rays<=64 and new.first_side and old.first_pull and new.first_side<old.first_pull,
        "Glue shown path moves before contact within ray budget")
    T.expect(new.max_pull<old.max_pull-0.3 and new.penetrations==0,
        "Glue pre-core target reduces pull and stays outside ledge")
end

-- Two finite obstructions in sequence: first a wide low lip with only an
-- upward route, then a taller narrow lip with a side route. Neither object
-- changes shape while the camera approaches it.
do
    local e=New.new()
    local velocity=v(0,0,5)
    local last=v(0,0,0)
    local saw_up,saw_side=false,false
    local function cast(a,b)
        local first=box(a,b,1.0,0,0.12,0,1.05)
        local second=box(a,b,0.12,5.0,5.12,0,2.0)
        if first and second then return mag(first-a)<mag(second-a) and first or second end
        return first or second
    end
    for i=1,300 do
        local z=-8+5*(i-1)/60
        local base,pivot=v(0,1,z),v(0.5,1.3,z+2)
        local eye=e:step(base,pivot,mag(base-pivot),0,i/60,1/60,cast,10,true,velocity)
        local rel=eye-base
        T.expect(mag(rel-last)<=0.90/60+1e-5,
            string.format("upward-to-side return has bounded local step (%d %.3f side %d offset %.3f)",
                i,mag(rel-last),e.side,e.offset))
        T.expect(mag(eye-base)<=0.47,"upward correction remains local")
        if z<1 and eye.y>1.02 then saw_up=true end
        if z>1 and math.abs(eye.x)>0.02 then saw_side=true end
        last=rel
    end
    T.expect(saw_up and saw_side,"upward opening and later side opening both used")
    local enclosed=New.new()
    local base,pivot=v(0,1,-2),v(0,1,0)
    for i=1,120 do
        local rays=0
        local eye=enclosed:step(base,pivot,2,0,i/60,1/60,function(a,b)
            rays+=1
            return a+(b-a)*0.4
        end,10,true,velocity)
        T.expect(T.vnear(eye,base) and rays<=10,"enclosed space stays neutral within budget")
    end
    local still=New.new()
    local still_rays=0
    for i=1,120 do
        local eye=still:step(base,pivot,2,0,i/60,1/60,function() still_rays+=1;return nil end,10,true,v(0,0,0))
        T.expect(T.vnear(eye,base),"stationary camera stays neutral")
    end
    T.expect(still_rays==0,"stationary camera spends no prediction rays")
end

for _,fps in ipairs({30,60,144}) do
    local wall={half=0.12,z0=0,z1=0.12}
    local new=trace(New,fps,wall,true)
    local old=trace(Old,fps,wall,false)
    print(string.format("prediction %d fps: first %s vs %s pull %s vs %s, pre-pull %d vs %d frames, max pull %.3f vs %.3f, step %.3f vs %.3f, rays %d",
        fps,tostring(new.first_offset),tostring(old.first_offset),tostring(new.first_pull),
        tostring(old.first_pull),new.ahead_count,old.ahead_count,new.max_pull,old.max_pull,new.max_step,old.max_step,new.rays_max))
    T.expect(new.first_offset and (not new.first_pull or new.first_offset<new.first_pull),
        "movement begins before core pull at "..fps)
    T.expect(new.ahead_count>=2 and old.ahead_count==0,"sustained pre-contact clearance at "..fps)
    T.expect(new.max_pull<old.max_pull,"pre-core target reduces reactive pull at "..fps)
end

T.done()
if T.failures>0 then error("collision prediction tests failed") end
