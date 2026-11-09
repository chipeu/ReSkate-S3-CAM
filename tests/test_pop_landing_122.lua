local T=require("tlib")
local Settings,Subject=require("settings"),require("subject")
local New,Old=require("camera"),require("ref_1121/camera")
local v,mag=vector.create,vector.magnitude
T.group("pop_landing_122")

local function ride(module,drop,fps)
    local cs=Settings.camera()
    cs.follow.trick_pop=false
    cs.shake_enabled=false
    cs.native_plus.landing_dip=true
    local c=module.new(); assert(c:set_settings(cs))
    local gravity,hop=10.1,0.05
    local rise=math.sqrt(2*hop/gravity)
    local air_time=rise+math.sqrt(2*(hop+drop)/gravity)
    local land=1+air_time
    local world=function(a,b)
        if a.y>=-drop and b.y < -drop then return a+(b-a)*((-drop-a.y)/(b.y-a.y)) end
    end
    local m={peak_dip=0,first_dip=0,pitch_up=0,fov_step=0,reach=10,last_fov=nil,frames=0,drop_frame=0}
    local takeoff_pitch
    for i=0,math.floor(3*fps) do
        local t=i/fps
        local s=Subject.new_snapshot()
        s.valid,s.onboard,s.board_valid,s.ground_valid=true,true,true,true
        s.position=v(0,0.95,6*t)
        s.velocity=v(0,0,6)
        s.ground_clearance=0.95
        s.board_position=s.position-v(0,0.95,0)
        s.time=t
        local a=t-1
        if a>=0 and a<air_time then
            local vy=math.sqrt(2*gravity*hop)-gravity*a
            s.position=v(0,0.95+math.sqrt(2*gravity*hop)*a-0.5*gravity*a*a,6*t)
            s.velocity=v(0,vy,6)
            s.physics_state=Subject.physics_state.air
            s.ground_clearance=s.position.y+drop
        elseif a>=air_time then
            s.position=v(0,0.95-drop,6*t)
        end
        local f=c:update(1/fps,s,world,{base_fov_deg=65})
        local pitch=math.deg(math.asin(-f.back.y))
        if t<1 and t>0.9 then takeoff_pitch=pitch end
        if a>=0 and a<air_time then
            m.pitch_up=math.max(m.pitch_up,pitch-(takeoff_pitch or pitch))
            m.reach=math.min(m.reach,mag(v(f.pos.x-s.position.x,0,f.pos.z-s.position.z)))
            m.frames+=1
        end
        if t>=land and t<land+0.3 then
            m.peak_dip=math.max(m.peak_dip,f.debug.landing_dip or 0)
            if m.first_dip==0 then m.first_dip=f.debug.landing_dip or 0 end
        end
        if m.last_fov then m.fov_step=math.max(m.fov_step,math.abs(f.fov_deg-m.last_fov)) end
        m.last_fov=f.fov_deg
    end
    return m
end

for _,fps in {30,60,144} do
    for _,drop in {0,1.5,4} do
        local a,b=ride(New,drop,fps),ride(Old,drop,fps)
        print(string.format("Pop Off %d %.1fm: peak dip %.3f/%.3f, first %.3f/%.3f, pitch up %.2f, FOV step %.3f, reach %.2f",
            fps,drop,a.peak_dip,b.peak_dip,a.first_dip,b.first_dip,a.pitch_up,a.fov_step,a.reach))
        T.expect(a.frames>0 and a.reach>0.75,"Pop Off retains horizontal rider distance")
        T.expect(a.pitch_up<0.5 and a.fov_step<0.1,"Pop Off stays level without a zoom")
        if drop>0 then
            T.expect(a.peak_dip<b.peak_dip*0.4 and a.peak_dip>b.peak_dip*0.3,
                "Pop Off dip scales saved depth while reducing harsh touchdown")
        end
    end
end
T.done()
if T.failures>0 then error("Pop Off landing tests failed") end
