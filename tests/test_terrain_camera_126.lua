-- Full App/Glue terrain follow: the displayed view, not only an inferred weight.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local v,mag=vector.create,vector.magnitude
T.group("terrain_camera_126")
local function box(a,b,lo,hi)
    local near,far=0,1
    for _,axis in {"x","y","z"} do
        local d=b[axis]-a[axis]
        if math.abs(d)<1e-8 then
            if a[axis]<lo[axis] or a[axis]>hi[axis] then return nil end
        else
            local x,y=(lo[axis]-a[axis])/d,(hi[axis]-a[axis])/d
            if x>y then x,y=y,x end
            near,far=math.max(near,x),math.min(far,y)
            if near>far then return nil end
        end
    end
    return a+(b-a)*near,v(0,1,0)
end
local function ground(kind,z)
    if kind=="vert" then return math.max(0,1.2*(z-6)) end
    if kind=="rail" then return -0.65*z end
    if kind=="stairs" then return z<16.2 and -0.65*0.6*math.floor(z/0.6) or -0.65*z end
    if kind=="ledge" then return z>=14 and 1 or 0 end
    if kind=="drop" then return z<12 and 3 or 0 end
    return 0
end
local function world(kind,a,b)
    local slope=kind=="rail" and -0.65 or kind=="vert" and 1.2 or 0
    local offset=kind=="vert" and -7.2 or 0
    local da,db=a.y-(a.z*slope+offset),b.y-(b.z*slope+offset)
    local hit,normal
    if da>=0 and db<=0 and da~=db then
        local q=a+(b-a)*(da/(da-db))
        if kind~="vert" or q.z>=6 then hit,normal=q,vector.normalize(v(0,1,-slope)) end
    end
    if kind=="vert" and a.y>=0 and b.y<=0 and a.y~=b.y then
        local q=a+(b-a)*(a.y/(a.y-b.y))
        if q.z<=6 and (not hit or mag(q-a)<mag(hit-a)) then hit,normal=q,v(0,1,0) end
    end
    local other,on
    if kind=="ledge" then other,on=box(a,b,v(-2,-4,14),v(2,1,40))
    elseif kind=="drop" then other,on=box(a,b,v(-50,-4,-50),v(50,3,12)) end
    if other and (not hit or mag(other-a)<mag(hit-a)) then hit,normal=other,on end
    if kind=="stairs" then
        hit,normal=nil,nil
        for k=-10,26 do
            local q,n=box(a,b,v(-50,-100,0.6*k),v(50,-0.65*0.6*k,0.6*(k+1)))
            if q and (not hit or mag(q-a)<mag(hit-a)) then hit,normal=q,n end
        end
        local da,db=a.y+0.65*a.z,b.y+0.65*b.z
        if da>=0 and db<=0 and da~=db then
            local q=a+(b-a)*(da/(da-db))
            if q.z>=16.2 and (not hit or mag(q-a)<mag(hit-a)) then hit,normal=q,vector.normalize(v(0,1,0.65)) end
        end
    end
    return hit,normal
end
local function sample(kind,t)
    local z=6*t
    local y,state,vy=ground(kind,z)+0.95,100,0
    if kind=="vert" then vy=z>6 and 7.2 or 0 end
    if kind=="rail" or kind=="stairs" then y,state,vy=-0.65*z+1.55,403,-3.9 end
    if t>=2 and t<3 then
        local u=t-2
        state=u<0.08 and 200 or 201
        if kind=="flat" then y=0.95+1.4*math.sin(math.pi*u);vy=1.4*math.pi*math.cos(math.pi*u)
        elseif kind=="ledge" then y=0.95+u+0.9*math.sin(math.pi*u);vy=1+0.9*math.pi*math.cos(math.pi*u)
        elseif kind=="drop" then y=3.95-3*u*u;vy=-6*u
        elseif kind=="vert" then y=8.15+10*u-2.8*u*u;vy=10-5.6*u
        elseif kind=="rail" or kind=="stairs" then
            if u<0.7 then y=-6.25-(1.257142857*u)-5*u*u;vy=-1.257142857-10*u
            else y,state,vy=ground(kind,z)+0.95,100,-3.9 end
        end
    elseif (kind=="rail" or kind=="stairs") and t>=3 then y,state,vy=ground(kind,z)+0.95,100,-3.9 end
    return v(0,y,z),state,vy
end
local function drive(kind,fps,on,repeat_flat)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local filter=app.glue.guard.filter
    app.glue.guard.filter=function(guard,now,pos,...)
        app.glue._test_guard_in=pos
        local result=table.pack(filter(guard,now,pos,...))
        app.glue._test_guard_out=result[1]
        return table.unpack(result,1,result.n)
    end
    local s=Settings.defaults()
    s.follow.trick_pop=on;s.follow.crouch_enabled=false
    s.trick_yaw.enabled=false;s.shake_enabled=false;s.native_plus.landing_dip=false
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.53
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.40
    assert(app.store:set_settings(s))
    -- Establish the same upright body datum as a normal session before a rail.
    -- Starting cold in a compressed contact would test baseline learning instead.
    local initial_ground=ground(kind,0)
    for k=1,math.floor(1.2*fps) do
        local root=v(0,initial_ground+0.95,-7.2+6*k/fps)
        m.state.skater.position=root
        m.state.telemetry.physics_state=100;m.state.telemetry.airborne=false
        m.state.board.deck={position=root-v(0,0.95,0),rotation={0,0,0,1}}
        m.state.board.velocity=v(0,0,6)
        m.state.raycast=function(a,b)
            if a.y>=initial_ground and b.y<=initial_ground and a.y~=b.y then return a+(b-a)*((a.y-initial_ground)/(a.y-b.y)),v(0,1,0) end
        end
        m.fire("physics_step",{at=m.clock_ms+1000/fps,seconds=1/fps,velocity={0,0,6},ragdoll=false})
        m.tick(1000/fps)
    end
    local out={rows={},rays=0,errors=0,first_follow=nil,first_rise=nil,baseline=nil,flat_y=0,flat_pitch=0,max_step=0,max_gap=0,min_floor=1e3,exit_rise=0}
    local prior,first_pitch
    for i=1,math.floor(4.5*fps) do
        local t=i/fps
        local root,state,vy=sample(kind,t)
        if repeat_flat and t>=3.6 and t<4.3 then
            local u=t-3.6
            root=v(0,1.95+math.sin(math.pi*u/0.7),6*t)
            state=u<0.08 and 200 or 201
            vy=math.pi/0.7*math.cos(math.pi*u/0.7)
        end
        m.state.skater.position=root
        m.state.telemetry.physics_state=state;m.state.telemetry.airborne=state==200 or state==201
        m.state.board.deck={position=root-v(0,0.95,0),rotation={0,0,0,1}}
        m.state.board.velocity=v(0,vy,6)
        m.state.raycast=function(a,b) return world(kind,a,b) end
        m.fire("physics_step",{at=m.clock_ms+1000/fps,seconds=1/fps,velocity={0,vy,6},ragdoll=false})
        m.tick(1000/fps)
        out.rays=math.max(out.rays,m.state.raycasts)
        local shown=m.last_call("set")
        local g=app.glue
        if shown and g.frame and g.source=="ride" and g.blend>=1 then
            local p=shown.position
            local pitch=math.deg(math.asin(shown.forward.y))
            local d=g.frame.debug
            local weight=d.terrain_weight or 0
            if t>1.7 and t<1.85 then out.baseline=p.y;first_pitch=pitch end
            if weight>0.1 and not out.first_follow then out.first_follow=t end
            if kind=="ledge" and t>=2 and out.baseline and p.y>out.baseline+0.15 and not out.first_rise then out.first_rise=t end
            if kind=="flat" and t>2.12 and t<2.88 and out.baseline then
                out.flat_y=math.max(out.flat_y,math.abs(p.y-out.baseline))
                out.flat_pitch=math.max(out.flat_pitch,math.abs(pitch-first_pitch))
            end
            if t>2 and t<3.5 then
                out.max_gap=math.max(out.max_gap,math.abs(p.y-root.y))
                out.min_floor=math.min(out.min_floor,p.y-ground(kind,p.z))
                if prior then
                    local step=mag((p-root)-prior)
                    if step>out.max_step then
                        out.max_step=step
                        out.peak={t=t,state=state,y=p.y,core=g.frame.pos.y,root=root.y,lift=d.collision_lift or 0,wall=d.collision_wall or 0,fast=d.collision_lift_fast or 0,pull=d.collision_pull or 0,gin=g._test_guard_in and g._test_guard_in.y,gout=g._test_guard_out and g._test_guard_out.y,delta=g.render_delta.y,correction=g.body_correction,ground=g.snap.ground_height,liftc=d.crouch_compensation,clear=g.snap.ground_clearance,base=g.cam.crouch.baseline}
                    end
                end
                local before=out.rows[i-1]
                if before and t<2.7 and root.y<before.root.y then out.exit_rise=math.max(out.exit_rise,p.y-before.pos.y) end
            end
            prior=p-root
            out.rows[i]={t=t,pos=p,root=root,pitch=pitch,weight=weight,reason=d.terrain_reason,state=state,core=g.frame.pos}
        end
    end
    out.errors=app.errors
    T.expect(app.errors==0 and out.rays<=64,"full terrain scene stays within host budget "..kind.." "..fps)
    T.expect(app.store.settings.follow.trick_pop==on,"terrain context does not change saved Pop toggle")
    return out
end
for _,fps in {30,60,144} do
    for _,kind in {"flat","ledge","vert","rail","stairs","drop"} do
        local off,on=drive(kind,fps,false),drive(kind,fps,true)
        print(string.format("terrain %s %d: start %s rise %s gap %.3f/%.3f step %.3f/%.3f floor %.3f rays %d/%d",kind,fps,
            tostring(off.first_follow),tostring(off.first_rise),off.max_gap,on.max_gap,off.max_step,on.max_step,off.min_floor,off.rays,on.rays))
        if kind=="flat" then
            T.expect(not off.first_follow and off.flat_y<0.03 and off.flat_pitch<0.5,"high flat ollie stays level without terrain override")
        else
            T.expect(off.first_follow~=nil,"measured terrain engages Pop On target "..kind)
            T.expect(off.min_floor>=0.03,"displayed eye stays over the modeled support "..kind)
            if kind=="ledge" then
                T.expect(off.first_follow and off.first_follow<2.3 and off.first_rise and off.first_rise<2.95,"raised ledge follow starts before contact, not after collision")
            end
            local delta,n,angle,views=0,0,0,0
            for i,a in off.rows do
                local b=on.rows[i]
                if b and a.t>2.2 and a.t<2.85 and a.weight>0.8 then delta+=mag(a.pos-b.pos);n+=1 end
                if b and a.t>2.2 and a.t<2.85 and a.weight>0.99 then angle+=math.abs(a.pitch-b.pitch);views+=1 end
            end
            print("  follow distance/aim from On",kind,n,n>0 and delta/n or -1,views>0 and angle/views or -1,"exitRise",off.exit_rise,on.exit_rise)
            if kind=="stairs" then T.expect(off.max_step<0.22*60/fps,"stair collision response has a frame-rate-scaled motion bound") end
            if kind=="rail" or kind=="stairs" then T.expect(views>0 and angle/views<2 and off.exit_rise<on.exit_rise+0.05*60/fps,"steep rail and exit use normal On view without an extra rise") end
            T.expect(n>0 and delta/n<0.9,"terrain camera converges toward normal On pose "..kind)
            T.expect(off.max_step<math.max(0.22*60/fps,on.max_step+0.15),"terrain handoff adds no large snap above the normal On response "..kind)
        end
    end
    local repeated=drive("ledge",fps,false,true)
    local y,pitch,dy,dp,weight=nil,nil,0,0,0
    for _,row in repeated.rows do
        if row.t<3.6 then y,pitch=row.pos.y,row.pitch end
        if row.t>3.75 and row.t<4.15 then
            dy=math.max(dy,math.abs(row.pos.y-y));dp=math.max(dp,math.abs(row.pitch-pitch));weight=math.max(weight,row.weight)
        end
    end
    print("fresh flat after ledge",fps,dy,dp,weight)
    T.expect(y and dy<0.03 and dp<0.5 and weight==0,"terrain follow cannot leak into a fresh flat trick")
end
T.done()
if T.failures>0 then error("terrain camera regressions failed") end
