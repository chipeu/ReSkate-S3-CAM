-- Fast camera-path obstruction with a finite side opening. Clearance must
-- begin early enough for the helper's own bounded lateral motion.
local T=require("tlib")
local New,Old=require("collision_escape"),require("ref_1123/collision_escape")
local v,mag=vector.create,vector.magnitude
T.group("collision_fast_124")
local function box(a,b)
    local lo,hi=0,1
    for _,axis in {"x","y","z"} do
        local low=axis=="x" and -0.38 or axis=="y" and 0 or 0
        local high=axis=="x" and 0.38 or axis=="y" and 0.75 or 0.18
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
local function drive(module,speed)
    local esc=module.new()
    local first_offset,first_pull,max_pull,max_step,rays,penetrations= nil,nil,0,0,0,0
    local prev,prior_eye
    for i=1,math.floor(1.4*60) do
        local t=(i-1)/60
        local z=-12+speed*t
        local base,pivot=v(0,0.5,z),v(0.6,1.2,z+1.53)
        local count=0
        local function cast(a,b) count+=1;return box(a,b) end
        local target=esc:step(base,pivot,mag(base-pivot),0,t,1/60,cast,10,true,v(0,0,speed))
        rays=math.max(rays,count)
        if not first_offset and mag(target-base)>0.005 then first_offset=t end
        local hit=cast(pivot,target)
        local pull=0
        if hit then
            local clear=math.max(0.25,mag(hit-pivot)-0.08)
            pull=math.max(0,mag(target-pivot)-clear)
            if not first_pull then first_pull=t end
        end
        max_pull=math.max(max_pull,pull)
        if prev then max_step=math.max(max_step,mag((target-pivot)-prev)) end
        prev=target-pivot
        if prior_eye and box(prior_eye,target) then penetrations+=1 end
        prior_eye=target
    end
    return {offset=first_offset,pull=first_pull,max_pull=max_pull,step=max_step,rays=rays,penetrations=penetrations}
end
for _,speed in {10,12} do
    local a,b=drive(New,speed),drive(Old,speed)
    print(string.format("fast %d: lead %.3f/%.3f s max pull %.3f/%.3f step %.3f rays %d penetrations %d",
        speed,12/speed-(a.offset or 12/speed),12/speed-(b.offset or 12/speed),
        a.max_pull,b.max_pull,a.step,a.rays,a.penetrations))
    T.expect(a.offset and 12/speed-a.offset>0.35,
        "fast camera route starts clearance while bounded shift remains feasible")
    T.expect(a.max_pull<b.max_pull and a.step<0.1 and a.rays<=10 and a.penetrations==0,
        "fast route reduces pull without a large local step or extra rays")
end
-- The requested eye can descend nearly vertically while Pop Off holds its
-- horizontal orbit. The eye velocity, rather than horizontal skater speed,
-- must arm the lookahead before a narrow shelf enters the swept eye path.
do
    local esc=New.new()
    local first,prior,penetrations,max_step=nil,nil,0,0
    local function shelf(a,b)
        local lo,hi=0,1
        for _,axis in {"x","y","z"} do
            local low=axis=="x" and -0.10 or axis=="y" and 0.5 or -2.2
            local high=axis=="x" and 0.10 or axis=="y" and 0.7 or -1.8
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
    for i=1,65 do
        local t=(i-1)/60
        local base,pivot=v(0,7-10*t,-2),v(0.6,7-10*t,-0.5)
        local eye=esc:step(base,pivot,mag(base-pivot),0,t,1/60,shelf,10,true,
            v(0,-10,0),false,v(0,-10,0))
        if not first and mag(eye-base)>0.005 then first=t end
        if prior then
            if shelf(prior.pos,eye) then penetrations+=1 end
            max_step=math.max(max_step,mag((eye-base)-prior.rel))
        end
        prior={pos=eye,rel=eye-base}
    end
    print(string.format("vertical eye: first %s penetrations %d step %.3f",tostring(first),penetrations,max_step))
    T.expect(first and first<0.25,"vertical eye motion activates future clearance")
    T.expect(penetrations==0 and max_step<0.1,"vertical eye sweep remains clear and bounded")
end
T.done()
