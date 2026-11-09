-- Gameplay-like App/Glue regression for the reported 1.1.22 profile.
-- Camera output is compared in world space with an upright rider on the same
-- terrain; a camera which still follows the animated body fails that oracle.
local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local Crouch=require("crouch")
local v,mag=vector.create,vector.magnitude
T.group("reported_profile_123")

local function floor_at(z)
    if z<14 then return -0.18*z end
    if z<21 then return -2.52 end
    return -2.52-0.34*(z-21)
end
local function floor_slope(z)
    if z<14 then return -0.18 end
    if z<21 then return 0 end
    return -0.34
end
local function world(a,b)
    local pieces={{-1e5,14,-0.18,0},{14,21,0,-2.52},{21,1e5,-0.34,4.62}}
    local hit,best,normal
    for _,p in pieces do
        local slope,intercept=p[3],p[4]
        local da,db=a.y-(slope*a.z+intercept),b.y-(slope*b.z+intercept)
        if da>=0 and db<=0 and da~=db then
            local u=da/(da-db)
            local q=a+(b-a)*u
            if q.z>=p[1] and q.z<=p[2] and (not best or u<best) then
                hit,best,normal=q,u,vector.normalize(v(0,1,-slope))
            end
        end
    end
    if hit then return hit,normal end
end
local function flat_world(a,b)
    if a.y>=0 and b.y<=0 and a.y~=b.y then
        return a+(b-a)*(a.y/(a.y-b.y)),v(0,1,0)
    end
end
local function phase(t)
    local cycle=math.floor(t/2.8)
    local u=t-cycle*2.8
    local state=100
    if cycle%2==0 then
        if u>=0.48 and u<0.94 then state=103
        elseif u>=0.94 and u<1.02 then state=200
        elseif u>=1.02 and u<1.72 then state=201 end
    else
        if u<0.55 then state=400
        elseif u<0.64 then state=701
        elseif u<0.70 then state=200
        elseif u<1.5 then state=201
        else state=400 end
    end
    return state,u
end
local function drive(angle,effects,animated,hot,flat,abrupt)
    local m=Mock.install({limit_rays=true})
    m.reskate.input.gamepad=function() return nil end
    m.reskate.menu.game=function() return {open=false} end
    local app=require("app").start()
    local show=app.glue.show
    app.glue.show=function(self,pos,forward,...)
        self._pre_show=pos
        self._pre_forward=forward
        return show(self,pos,forward,...)
    end
    local s=Settings.defaults()
    s.angle=angle
    s.follow.crouch_enabled=hot and true or false
    s.follow.crouch_amount=1
    s.follow.trick_pop=hot and true or false
    s.follow.pop_amount=1
    s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,1.5
    s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,1.5
    s.framing.grind_distance=1.6
    s.shake_enabled=effects
    s.native_plus.landing_dip=effects
    assert(app.store:set_settings(s))
    local out={samples={},max_rays=0,max_step=0,max_aim_step=0,seen={},applied={},manual_seen=false}
    local previous,t= nil,0
    for i=1,math.floor(8.4*60) do
        local dt=(i==164 or i==330) and 0.085 or 1/60
        t+=dt
        local state,u=phase(t)
        if hot and not out.applied.crouch and t>=0.7 then
            m.build_page({tabs=2,crouch_on=false})
            T.expect(not app.store.settings.follow.crouch_enabled and app.store.settings.follow.crouch_amount==1,
                "menu Crouch Off keeps retained slider strength")
            out.applied.crouch=app.store.revision
        end
        if hot and not out.applied.pop and t>=1.2 then
            m.build_page({tabs=2,pop_follow=false})
            T.expect(not app.store.settings.follow.trick_pop and app.store.settings.follow.pop_amount==1,
                "menu Pop Off keeps retained slider strength")
            out.applied.pop=app.store.revision
        end
        local z=5*t
        local base=flat and 0 or floor_at(z)
        local crouch=0
        if math.floor(t/2.8)%2==0 then
            if u>=0.32 and u<0.50 then crouch=0.33*(u-0.32)/0.18
            elseif u>=0.50 and u<0.94 then crouch=0.33
            elseif not abrupt and u>=0.94 and u<1.16 then crouch=0.33*(1-(u-0.94)/0.22) end
        end
        local compression=(state==100 or state==400) and u>=1.72 and u<1.96 and 0.16*math.sin(math.pi*(u-1.72)/0.24) or 0
        local drop=animated and crouch+compression or 0
        local air_u=u-0.94
        local flight=(state==200 or state==201) and math.max(0,1.8*air_u-2.3*air_u^2) or 0
        local root=v(0,base+0.95+flight-drop,z)
        -- Physical support velocity is independent of animated crouch/root dip.
        local vy=(flat and 0 or 5*floor_slope(z))+((state==200 or state==201) and (1.8-4.6*air_u) or 0)
        m.state.skater.position=root
        m.state.telemetry.physics_state=state
        m.state.telemetry.airborne=state==200 or state==201
        local grade=flat and 0 or floor_slope(z)
        local deck_angle=math.atan(-grade)
        m.state.board.deck={position=v(0,base+flight,z),
            rotation={x=math.sin(deck_angle/2),y=0,z=0,w=math.cos(deck_angle/2)}}
        m.state.board.velocity=v(0,vy,5)
        m.state.joints[103]={position=root+v(0,0.85,0),rotation={x=0,y=0,z=0,w=1}}
        m.state.joints[10]={position=root+v(0,-0.75,0),rotation={x=0,y=0,z=0,w=1}}
        m.state.joints[343]={position=root+v(0,-0.77,0),rotation={x=0,y=0,z=0,w=1}}
        m.state.raycast=(i%61==0 or i%61==1) and function() return nil end or (flat and flat_world or world)
        m.fire("physics_step",{at=m.clock_ms,seconds=dt,velocity={0,vy,5},ragdoll=false})
        m.tick(dt*1000)
        if hot and out.applied.pop and not out.applied.confirmed and app.glue.applied_revision==out.applied.pop then out.applied.confirmed=true end
        out.max_rays=math.max(out.max_rays,m.state.raycasts)
        local shown=m.last_call("set")
        if shown and app.glue.source=="ride" and app.glue.blend>=1 then
            local pitch=math.deg(math.asin(-shown.forward.y))
            local frame=app.glue.frame
            local snap=app.glue.snap
            local c=app.glue.cam.crouch
            local flight=app.glue.cam.pop_flight
            local seed=app.glue.extras.pop_seed
            local point={t=t,state=state,u=u,root=root,pos=shown.position,core=frame and frame.pos,pre=app.glue._pre_show,
                compensation=frame and frame.debug and frame.debug.crouch_compensation or 0,
                landing_eye=app.glue.cam.landing_eye_y,render_delta=app.glue.render_delta,
                guard_smoothing=app.glue.guard.smoothing,stable_timing=app.store.options.stable_timing,
                guard_subject=app.glue.guard.subject,guard_w_rel=app.glue.guard.w_rel,guard_o_rel=app.glue.guard.o_rel,
                look_y=frame.debug.look_target.y,air_ref=frame.debug.air_reference_height,
                board_w=frame.debug.board_weight,landing_w=frame.debug.landing_look_weight,
                look_pitch=frame.debug.look_pitch_offset,floor_w=frame.debug.floor_weight,
                tilt=app.glue.cam.tilt.position,shot=frame.debug.shot_name,
                core_pull=frame.debug.collision_pull,free=frame.debug.camera_free,
                shot_fraction=frame.debug.shot_fraction,distance=frame.debug.render_distance,
                fixed_w=app.glue.cam.fixed_w,impact=frame.debug.impact_y,
                room_w=app.glue.cam.air_room_w,room_extra=app.glue.cam.air_room_extra,
                flight_max=app.glue.cam.flight_max_height,
                flight_height=app.glue.cam.pop_flight and app.glue.cam.pop_flight.height,
                flight_eye=flight and flight.eye_y,flight_root=flight and flight.root_y,
                flight_virtual=flight and flight.virtual_root_y,flight_board=flight and flight.board_y,
                flight_up=flight and flight.up,flight_down=flight and flight.down,
                flight_tight=flight and flight.tight_up,flight_wide=flight and flight.wide_up,
                flight_reach=flight and flight.reach,flight_pitch=flight and flight.pitch,
                flight_large=flight and flight.large,board_y=snap.board_position.y,raw_board_y=m.state.board.deck.position.y,
                seed_world=seed and seed.world_position and seed.world_position.y,
                seed_guard=seed and seed.guard_subject_y,seed_board=seed and seed.board_y,
                drop_w=app.glue.cam.pop_drop_w,
                ground_valid=snap.ground_valid,ground_height=snap.ground_height,
                ground_normal_y=snap.ground_normal.y,onboard=snap.onboard,manual=snap.manual,bailing=snap.bailing,
                baseline=c.baseline,weight=c.weight,offset=c.offset,sample_lift=Crouch.sample(c,snap),
                missing_time=c.missing_time,last_ground=c.last_ground_height,board_baseline=c.board_baseline,
                rig_anchor_y=frame.debug.orbit_anchor.y,skater_anchor_y=frame.debug.skater_anchor.y,
                rail_land=app.glue.cam.rail_land_rel,pop_land=app.glue.cam.pop_land_rel,
                carried_y=frame.debug.carried.y,
                core_pitch=frame and math.deg(math.asin(frame.back.y)),
                pre_pitch=math.deg(math.asin(-app.glue._pre_forward.y)),
                forward=shown.forward,fov=shown.fov,pitch=pitch,drop=drop,ground=flat and 0 or floor_at(shown.position.z)}
            out.samples[i]=point
            out.seen[state]=true
            out.manual_seen=out.manual_seen or snap.manual
            if previous then
                local step=mag(point.pos-previous.pos)-mag(point.root-previous.root)
                out.max_step=math.max(out.max_step,step)
                out.max_aim_step=math.max(out.max_aim_step,math.abs(pitch-previous.pitch))
            end
            previous=point
        end
    end
    T.expect(app.errors==0 and out.max_rays<=64,"App/Glue profile runs within callback and ray budget")
    T.expect(not out.manual_seen,"fixture maintains a physically aligned deck without a manual")
    return out
end

for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
    for _,effects in {false,true} do
        local moving=drive(angle,effects,true)
        local upright=drive(angle,effects,false)
        local worst_eye,worst_pitch,worst_fov=0,0,0
        local crouch_eye,landing_eye,late_eye=0,0,0
        local worst_t,worst_state=0,0
        local worst_a,worst_b
        local first_guard
        local first_core
        local comparisons=0
        for i,a in moving.samples do
            local b=upright.samples[i]
            if b and a.state==b.state and a.state~=201 and a.drop>0.08 then
                local eye=math.abs(a.pos.y-b.pos.y)
                if eye>worst_eye then worst_eye,worst_t,worst_state,worst_a,worst_b=eye,a.t,a.state,a,b end
                worst_pitch=math.max(worst_pitch,math.abs(a.pitch-b.pitch))
                worst_fov=math.max(worst_fov,math.abs(a.fov-b.fov))
                if a.state==103 then crouch_eye=math.max(crouch_eye,eye) end
                if a.state==100 or a.state==400 then landing_eye=math.max(landing_eye,eye) end
                if a.t>3 then late_eye=math.max(late_eye,eye) end
                comparisons+=1
            end
            if b and not first_guard and math.abs(a.guard_o_rel.y-b.guard_o_rel.y)>0.05 then
                first_guard={a,b}
            end
            if b and not first_core and a.t>1.7 and math.abs(a.core.y-b.core.y)>0.05 then first_core={a,b} end
        end
        print(string.format("reported profile angle %s effects %s: eye %.3f at %.2f state %d (crouch %.3f landing %.3f late %.3f), pitch %.2f, fov %.2f, step %.3f/%.3f, aim step %.2f/%.2f, samples %d",
            tostring(angle),tostring(effects),worst_eye,worst_t,worst_state,crouch_eye,landing_eye,late_eye,worst_pitch,worst_fov,moving.max_step,upright.max_step,moving.max_aim_step,upright.max_aim_step,comparisons))
        if worst_a and worst_b then
            print(string.format("  worst split coreY %.3f/%.3f preShowY %.3f/%.3f shownY %.3f/%.3f rootY %.3f/%.3f compensation %.3f/%.3f renderDeltaY %.3f/%.3f smoothing %s/%s stable %s/%s landingEye %s/%s",
                worst_a.core.y,worst_b.core.y,worst_a.pre.y,worst_b.pre.y,worst_a.pos.y,worst_b.pos.y,worst_a.root.y,worst_b.root.y,
                worst_a.compensation,worst_b.compensation,worst_a.render_delta.y,worst_b.render_delta.y,
                tostring(worst_a.guard_smoothing),tostring(worst_b.guard_smoothing),tostring(worst_a.stable_timing),tostring(worst_b.stable_timing),
                tostring(worst_a.landing_eye),tostring(worst_b.landing_eye)))
            print(string.format("  guard subjectY %.3f/%.3f wantedRelY %.3f/%.3f outRelY %.3f/%.3f preRelY %.3f/%.3f",
                worst_a.guard_subject.y,worst_b.guard_subject.y,worst_a.guard_w_rel.y,worst_b.guard_w_rel.y,
                worst_a.guard_o_rel.y,worst_b.guard_o_rel.y,worst_a.pre.y-worst_a.root.y,worst_b.pre.y-worst_b.root.y))
            print(string.format("  aim core %.2f/%.2f preShow %.2f/%.2f shown %.2f/%.2f",
                worst_a.core_pitch,worst_b.core_pitch,worst_a.pre_pitch,worst_b.pre_pitch,worst_a.pitch,worst_b.pitch))
            print(string.format("  core inputs lookY %.3f/%.3f airRef %.3f/%.3f boardW %.2f/%.2f landingW %.2f/%.2f lookPitch %.2f/%.2f floorW %.2f/%.2f tilt %.2f/%.2f shot %s/%s",
                worst_a.look_y,worst_b.look_y,worst_a.air_ref,worst_b.air_ref,worst_a.board_w,worst_b.board_w,
                worst_a.landing_w,worst_b.landing_w,math.deg(worst_a.look_pitch),math.deg(worst_b.look_pitch),
                worst_a.floor_w,worst_b.floor_w,math.deg(worst_a.tilt),math.deg(worst_b.tilt),
                tostring(worst_a.shot),tostring(worst_b.shot)))
        end
        if first_guard then
            local a,b=first_guard[1],first_guard[2]
            print(string.format("  first guard divergence t %.3f state %d drop %.3f, subject %.3f/%.3f wantedRel %.3f/%.3f outRel %.3f/%.3f preY %.3f/%.3f coreAim %.2f/%.2f",
                a.t,a.state,a.drop,a.guard_subject.y,b.guard_subject.y,a.guard_w_rel.y,b.guard_w_rel.y,
                a.guard_o_rel.y,b.guard_o_rel.y,a.pre.y,b.pre.y,a.core_pitch,b.core_pitch))
            print(string.format("  crouch sample valid %s/%s ground %.3f/%.3f root-ground %.3f/%.3f baseline %s/%s weight %s/%s offset %.3f/%.3f sampleLift %s/%s boardW %.2f/%.2f",
                tostring(a.ground_valid),tostring(b.ground_valid),a.ground_height,b.ground_height,
                a.root.y-a.ground_height,b.root.y-b.ground_height,tostring(a.baseline),tostring(b.baseline),
                tostring(a.weight),tostring(b.weight),a.offset,b.offset,tostring(a.sample_lift),tostring(b.sample_lift),a.board_w,b.board_w))
            print(string.format("  flags onboard %s/%s manual %s/%s bail %s/%s normalY %.3f/%.3f",
                tostring(a.onboard),tostring(b.onboard),tostring(a.manual),tostring(b.manual),
                tostring(a.bailing),tostring(b.bailing),a.ground_normal_y,b.ground_normal_y))
        end
        if first_core then
            local a,b=first_core[1],first_core[2]
            print(string.format("  first core divergence t %.3f state%d coreY %.3f/%.3f aim %.2f/%.2f rootY %.3f/%.3f ground %.3f/%.3f comp %.3f/%.3f lookY %.3f/%.3f airRef %.3f/%.3f landingW %.2f/%.2f landingEye %s/%s flightHeight %s/%s pull %.3f/%.3f free %s/%s shotFrac %.2f/%.2f dist %.2f/%.2f fixedW %.2f/%.2f impact %.3f/%.3f guardOutRel %.3f/%.3f",
                a.t,a.state,a.core.y,b.core.y,a.core_pitch,b.core_pitch,a.root.y,b.root.y,
                a.ground_height,b.ground_height,a.compensation,b.compensation,a.look_y,b.look_y,
                a.air_ref,b.air_ref,a.landing_w,b.landing_w,tostring(a.landing_eye),tostring(b.landing_eye),
                tostring(a.flight_height),tostring(b.flight_height),a.core_pull,b.core_pull,
                tostring(a.free),tostring(b.free),a.shot_fraction,b.shot_fraction,a.distance,b.distance,
                a.fixed_w,b.fixed_w,a.impact,b.impact,a.guard_o_rel.y,b.guard_o_rel.y))
            print(string.format("  flight eye %s/%s height %s/%s root %s/%s virtual %s/%s board %s/%s liveBoard %.3f/%.3f up %s/%s down %s/%s tight %s/%s wide %s/%s reach %s/%s pitch %s/%s large %s/%s seedEye %s/%s seedGuard %s/%s seedBoard %s/%s dropW %s/%s",
                tostring(a.flight_eye),tostring(b.flight_eye),tostring(a.flight_height),tostring(b.flight_height),
                tostring(a.flight_root),tostring(b.flight_root),tostring(a.flight_virtual),tostring(b.flight_virtual),
                tostring(a.flight_board),tostring(b.flight_board),a.board_y,b.board_y,
                tostring(a.flight_up),tostring(b.flight_up),tostring(a.flight_down),tostring(b.flight_down),
                tostring(a.flight_tight),tostring(b.flight_tight),tostring(a.flight_wide),tostring(b.flight_wide),
                tostring(a.flight_reach),tostring(b.flight_reach),tostring(a.flight_pitch),tostring(b.flight_pitch),
                tostring(a.flight_large),tostring(b.flight_large),tostring(a.seed_world),tostring(b.seed_world),
                tostring(a.seed_guard),tostring(b.seed_guard),tostring(a.seed_board),tostring(b.seed_board),
                tostring(a.drop_w),tostring(b.drop_w)))
        end
        T.expect(comparisons>20 and moving.seen[103] and moving.seen[200] and moving.seen[201] and moving.seen[400] and moving.seen[701],"both repeated hop and grind paths displayed")
        -- 1.2.19: was 0.08. 1.2.18 passed only because a landing recovery never ended and low-passed the core.
        T.expect(worst_eye<0.11,"Crouch Off holds the world eye through body animation and landing compression")
        T.expect(worst_pitch<2.5,"Crouch Off holds world aim through body animation")
        local toggled=drive(angle,effects,true,true)
        T.expect(toggled.applied.crouch and toggled.applied.pop and toggled.applied.confirmed,
            "Crouch Off while crouched and Pop Off midair reach displayed Glue settings")
        local hot_eye,hot_pitch=0,0
        for i,a in toggled.samples do
            local b=moving.samples[i]
            if b and a.t>4 and a.state==b.state then
                hot_eye=math.max(hot_eye,math.abs(a.pos.y-b.pos.y))
                hot_pitch=math.max(hot_pitch,math.abs(a.pitch-b.pitch))
            end
        end
        print(string.format("reported hot-toggle angle %s effects %s: settled eye %.3f pitch %.2f",tostring(angle),tostring(effects),hot_eye,hot_pitch))
        T.expect(hot_eye<0.10 and hot_pitch<3,
            "hot Crouch Off and Pop Off converge to startup Off framing")
    end
end
for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
    local a,b=drive(angle,false,true,false,false,true),drive(angle,false,false,false,false,true)
    local eye,aim=0,0
    local worst_eye,worst_aim,first_guard,first_core
    for i,p in a.samples do
        local q=b.samples[i]
        if q and p.state==q.state and (p.drop>0.08 or p.u>=0.94 and p.u<1.96) then
            local de,da=math.abs(p.pos.y-q.pos.y),math.abs(p.pitch-q.pitch)
            if de>eye then eye,worst_eye=de,{p,q} end
            if da>aim then aim,worst_aim=da,{p,q} end
        end
        if q and not first_guard and math.abs(p.guard_o_rel.y-q.guard_o_rel.y)>0.05 then first_guard={p,q} end
        if q and not first_core and math.abs(p.core.y-q.core.y)>0.05 then first_core={p,q} end
    end
    print(string.format("abrupt IK rebound angle %s: eye %.3f aim %.2f",tostring(angle),eye,aim))
    for label,pair in {worst_eye=worst_eye,worst_aim=worst_aim,first_guard=first_guard,first_core=first_core} do
        if pair then
            local p,q=pair[1],pair[2]
            print(string.format("  %s t %.3f state%d drop %.3f rootY %.3f/%.3f rawBoardY %.3f/%.3f renderBoardY %.3f/%.3f coreY %.3f/%.3f shownY %.3f/%.3f coreAim %.2f/%.2f shownAim %.2f/%.2f guardSubject %.3f/%.3f guardRel %.3f/%.3f flightHeight %s/%s",
                label,p.t,p.state,p.drop,p.root.y,q.root.y,p.raw_board_y,q.raw_board_y,p.board_y,q.board_y,p.core.y,q.core.y,p.pos.y,q.pos.y,
                p.core_pitch,q.core_pitch,p.pitch,q.pitch,p.guard_subject.y,q.guard_subject.y,
                p.guard_o_rel.y,q.guard_o_rel.y,tostring(p.flight_height),tostring(q.flight_height)))
        end
    end
    for label,pair in {first_core=first_core,worst_eye=worst_eye} do
        if pair then
        local p,q=pair[1],pair[2]
        print(string.format("  %s posture: groundValid %s/%s groundY %.3f/%.3f rootGround %.3f/%.3f normalY %.3f/%.3f baseline %s/%s offset %.3f/%.3f sample %s/%s dComp %.3f/%.3f missing %.3f/%.3f lastGround %s/%s boardBaseline %s/%s boardW %.2f/%.2f floorW %.2f/%.2f landingEye %s/%s railLand %s/%s popLand %s/%s airRef %.3f/%.3f dist %.2f/%.2f carryY %.3f/%.3f fixedW %.2f/%.2f rigAnchorY %.3f/%.3f skaterAnchorY %.3f/%.3f lookY %.3f/%.3f",
            label,
            tostring(p.ground_valid),tostring(q.ground_valid),p.ground_height,q.ground_height,
            p.root.y-p.ground_height,q.root.y-q.ground_height,
            p.ground_normal_y,q.ground_normal_y,tostring(p.baseline),tostring(q.baseline),
            p.offset,q.offset,tostring(p.sample_lift),tostring(q.sample_lift),p.compensation,q.compensation,
            p.missing_time,q.missing_time,
            tostring(p.last_ground),tostring(q.last_ground),tostring(p.board_baseline),tostring(q.board_baseline),
            p.board_w,q.board_w,p.floor_w,q.floor_w,tostring(p.landing_eye),tostring(q.landing_eye),
            tostring(p.rail_land),tostring(q.rail_land),tostring(p.pop_land),tostring(q.pop_land),
            p.air_ref,q.air_ref,p.distance,q.distance,p.carried_y,q.carried_y,p.fixed_w,q.fixed_w,
            p.rig_anchor_y,q.rig_anchor_y,p.skater_anchor_y,q.skater_anchor_y,p.look_y,q.look_y))
        print(string.format("  %s airroom: weight %.3f/%.3f extra %.3f/%.3f maxheight %.3f/%.3f",label,
            p.room_w,q.room_w,p.room_extra,q.room_extra,p.flight_max,q.flight_max))
        end
    end
    -- 1.2.19: was 0.08, see the note above.
    T.expect(eye<0.11 and aim<2.5,"Pop Off and Crouch Off reject an abrupt body animation rebound")
end
for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
    local flat=drive(angle,false,true,false,true)
    local before,low_pitch,high_pitch,air_frames=nil,90,-90,0
    for _,p in flat.samples do
        if p.t>=0.75 and p.t<0.9 then before=p.pitch end
        if p.t>=1.15 and p.t<1.60 and p.state==201 then
            low_pitch=math.min(low_pitch,p.pitch)
            high_pitch=math.max(high_pitch,p.pitch)
            air_frames+=1
        end
    end
    print(string.format("flat Pop Off angle %s: pre %.2f air pitch %.2f..%.2f (%d frames)",
        tostring(angle),before or -99,low_pitch,high_pitch,air_frames))
    T.expect(before and air_frames>15,"flat Pop Off flight and preflight shown")
    T.expect(low_pitch>=before-3,"flat Pop Off does not tilt farther upward than its grounded framing")
end
T.done()
if T.failures>0 then error("reported profile tests failed") end
