-- The rendered subject is ahead of the interpolated fixed-step pose. Downhill
-- travel must be carried in both directions from physical support, independent
-- of the crouch animation in the rider root.
local T=require("tlib")
local Camera=require("camera")
local Subject=require("subject")
local Settings=require("settings")
local v=vector.create
T.group("render_vertical_124")

local function run(drop, slope)
    local s=Settings.defaults()
    s.follow.trick_pop=false;s.follow.pop_amount=1
    s.follow.crouch_enabled=false;s.follow.crouch_amount=1
    s.shake_enabled=false;s.native_plus.landing_dip=false
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.53
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.40
    local cam=Camera.new();assert(cam:set_settings(s))
    local min_carry,max_carry=1e3,-1e3
    local query=function(a,b)
        local da=a.y-slope*a.z;local db=b.y-slope*b.z
        if da>=0 and db<=0 and da~=db then
            return a+(b-a)*(da/(da-db)),vector.normalize(v(0,1,-slope))
        end
    end
    for i=1,180 do
        local t=i/60
        local z=7*t
        local board=slope*z
        local snap=Subject.new_snapshot()
        snap.time=t;snap.valid=true;snap.board_valid=true;snap.ground_valid=true
        snap.position=v(0,board+0.95-drop,z)
        snap.board_position=v(0,board,z)
        snap.velocity=v(0,7*slope,7)
        snap.physical_velocity=snap.velocity
        snap.ground_height=board;snap.ground_clearance=0.95-drop
        snap.ground_normal=vector.normalize(v(0,1,-slope))
        snap.physics_state=drop>0 and 103 or 100
        local frame=cam:update(1/60,snap,query)
        if i>60 then
            local y=frame.debug.carried.y
            min_carry=math.min(min_carry,y);max_carry=math.max(max_carry,y)
        end
    end
    return min_carry,max_carry
end

local down,down_max=run(0,-0.35)
local crouch,crouch_max=run(0.25,-0.35)
local up,up_max=run(0,0.35)
T.expect(down< -0.01 and down_max< -0.005,"descending board travel reaches rendered eye")
T.expect(math.abs(down-crouch)<0.003 and math.abs(down_max-crouch_max)<0.003,
    "animated crouch does not change physical vertical carry")
T.expect(up_max>0.01,"ascending board travel reaches rendered eye")
T.done()
