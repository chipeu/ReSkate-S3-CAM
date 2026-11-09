local T=require("tlib")
local Camera,Settings,Subject=require("camera"),require("settings"),require("subject")
local vc=vector.create
T.group("level_pop_117")
local function plane(a,b)
	if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),vc(0,1,0) end
end
for _,fps in {30,60,144} do
	for _,mode in {0,1} do
		for _,amount in {0,0.5,1} do
			local c=Camera.new();local s=Settings.defaults();s.shake_enabled=false;s.native_plus.landing_dip=false
			s.follow.trick_pop=false;s.follow.crouch_mode=mode;s.follow.crouch_amount=amount
			s.angle=Settings.CameraAngle.High;c:set_settings(s)
			local baseline,previous;local maxstep,maxreach,maxpitch,maxheight=0,0,0,0
			for i=1,6*fps do
				local t=i/fps;local a=t-3;local air=a>0 and a<1.6
				local crouch=t>1 and t<=3 and math.min((t-1)*0.6,0.3) or 0
				local rise=air and (8*a-5*a*a) or 0
				local snap=Subject.new_snapshot();snap.valid,snap.onboard,snap.ground_valid=true,true,true
				snap.physics_state=air and 201 or crouch>0 and 103 or 100
				snap.position=vc(0,0.95-crouch+rise,t*6);snap.board_position=vc(0,air and rise or 0,t*6)
				snap.board_valid=true;snap.ground_height=0;snap.ground_clearance=snap.position.y
				snap.velocity=vc(0,air and 8-10*a or 0,6)
				local f=c:update(1/fps,snap,plane,{base_fov_deg=65})
				local reach=vector.magnitude(vc(f.pos.x-snap.position.x,0,f.pos.z-snap.position.z))
				local pitch=math.asin(math.clamp(-f.back.y,-1,1))
				if i==fps then baseline={y=f.pos.y,reach=reach,pitch=pitch,fov=f.fov_deg} end
				if air then
					if previous then maxstep=math.max(maxstep,math.abs(f.pos.y-previous)) end
					maxreach=math.max(maxreach,math.abs(reach-baseline.reach))
					T.expect(math.abs(reach-baseline.reach)<0.12,"airborne height does not change horizontal chase distance")
					T.expect(math.abs(f.fov_deg-baseline.fov)<0.15,"pop Off does not zoom the FOV out")
					T.expect(f.debug.keep_weight==0,"pop Off never enables upward keep-in-frame pitching")
					if a>0.75 then
						maxpitch=math.max(maxpitch,math.abs(pitch-baseline.pitch))
						maxheight=math.max(maxheight,math.abs(f.pos.y-baseline.y))
						T.expect(math.abs(f.pos.y-baseline.y)<0.06,"camera resumes normal vertical level rather than staying crouched or following board")
						T.expect(math.abs(pitch-baseline.pitch)<math.rad(1),"camera resumes normal pitch rather than looking up at the skater")
					end
				end
				previous=f.pos.y
			end
			print(string.format("level pop %d FPS mode %d strength %.1f: step %.3f m, reach error %.3f m, level error %.3f m, pitch error %.2f deg",fps,mode,amount,maxstep,maxreach,maxheight,math.deg(maxpitch)))
			T.expect(maxstep<0.1,"crouch-to-pop level return is gradual")
		end
	end
end
-- Verify actual shown poses through App/Glue, including native frame sampling,
-- final Fixed-distance handling and snap protection; pure rig tests are not enough.
for _,fps in {30,60,144} do
	local m=require("mock_reskate").install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end;m.reskate.menu.game=function() return {open=false} end
	local app=require("app").start({camera=Camera});local s=Settings.defaults()
	s.shake_enabled=false;s.native_plus.landing_dip=false;s.follow.trick_pop=false
	s.follow.crouch_mode=0;s.follow.crouch_amount=1;s.angle=Settings.CameraAngle.High
	s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,3
	app.store:set_settings(s)
	local baseline;local previous;local worst=0
	for i=1,6*fps do
		local t=i/fps;local a=t-3;local air=a>0 and a<1.6
		local crouch=t>2 and t<=3 and math.min((t-2)*0.6,0.3) or 0
		local rise=air and (8*a-5*a*a-0.3*math.exp(-a/0.08)) or 0
		local root=vc(0,0.95-crouch+rise,t*6)
		m.state.skater.position=root;m.state.telemetry.physics_state=air and 201 or crouch>0 and 103 or 100
		m.state.board.deck={position=vc(0,air and rise or 0,t*6),rotation={0,0,0,1}}
		local vy=air and (8-10*a+3.75*math.exp(-a/0.08)) or 0
		m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,vy,6},ragdoll=false});m.tick(1000/fps)
		local f=m.last_call("set")
		if not f then continue end
		local reach=vector.magnitude(vc(f.position.x-root.x,0,f.position.z-root.z))
		if i==2*fps then baseline={reach=reach,y=f.position.y,fov=f.fov,pitch=math.asin(f.forward.y)} end
		if air then
			if previous then worst=math.max(worst,math.abs(f.position.y-previous)) end
			T.expect(math.abs(reach-baseline.reach)<0.15,"shown camera follows horizontally without leaving the skater behind")
			T.expect(math.abs(f.fov-baseline.fov)<0.15,"shown camera does not zoom out")
			if a>0.85 then
				T.expect(math.abs(f.position.y-baseline.y)<0.08,"shown camera returns to normal level after crouch preparation")
				T.expect(math.abs(math.asin(f.forward.y)-baseline.pitch)<math.rad(1),"shown camera does not pitch up at the popped board")
			end
		end
		previous=f.position.y
	end
	T.expect(worst<0.12 and app.errors==0,"full update path has no takeoff recenter snap or callback error")
end
T.done()
if T.failures>0 then error("level pop tests failed") end
