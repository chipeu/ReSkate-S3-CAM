local T=require("tlib")
local Camera,Before,Settings,Subject=require("camera"),require("ref_1114/camera"),require("settings"),require("subject")
local P=require("presets")
local vc=vector.create
T.group("pop_pitch_214")
local function plane(a,b)
	if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),vc(0,1,0) end
end
local function snapshot(t,drop,air)
	local s=Subject.new_snapshot();s.valid,s.onboard,s.ground_valid=true,true,true
	s.time=t;s.position=vc(0,0.95-drop,t*6);s.board_position=vc(0,air and s.position.y-0.5 or 0,t*6)
	s.board_valid=true;s.ground_height=0;s.ground_clearance=s.position.y;s.velocity=vc(0,0,6)
	s.physics_state=air and 201 or (drop>0 and 103 or 100)
	return s
end
local function settings()
	local s=Settings.defaults();s.shake_enabled=false;s.native_plus.landing_dip=false
	s.fov.speed_fov=false;s.angle=Settings.CameraAngle.High
	return s
end

-- Old profiles/default mode must keep the complete previous camera output.
for _,fps in {30,60,144} do
	local a,b=Camera.new(),Before.new();local s=settings();a:set_settings(s);b:set_settings(s)
	for i=1,5*fps do
		local t=i/fps;local air=t>2 and t<3;local y=air and math.sin((t-2)*math.pi)*1.3 or 0
		local snap=snapshot(t,t>1 and t<1.5 and 0.3 or -y,air)
		local x=a:update(1/fps,snap,plane,{base_fov_deg=65});local old=b:update(1/fps,snap,plane,{base_fov_deg=65})
		T.expect(T.vnear(x.pos,old.pos,0.00001) and T.vnear(x.back,old.back,0.00001) and x.fov_deg==old.fov_deg,"Height + pop On preserves 1.1.14 camera behavior")
	end
end

for _,fps in {30,60,144} do
	local cams,base={},{}
	for _,amount in {0,0.5,1} do
		local s=settings();s.follow.crouch_mode=1;s.follow.crouch_amount=amount
		local c=Camera.new();assert(c:set_settings(s));cams[#cams+1]=c
	end
	local pitch={}
	for i=1,4*fps do
		local t=i/fps;local drop=t<=1 and 0 or t<1.5 and (t-1)*0.6 or 0.3
		for j,c in cams do
			local f=c:update(1/fps,snapshot(t,drop,false),plane,{base_fov_deg=65})
			if i==fps then base[j]=f.pos.y end
			if i==4*fps then
				T.expect(math.abs(f.pos.y-base[j])<0.035,"Pitch mode keeps camera height steady at strength "..j.." / "..fps.." FPS")
				pitch[j]=math.asin(math.clamp(-f.back.y,-1,1))
			end
		end
	end
	print(string.format("crouch pitch %d FPS: 0%% %.2f, 50%% %.2f, 100%% %.2f deg",fps,math.deg(pitch[1]),math.deg(pitch[2]),math.deg(pitch[3])))
	T.expect(pitch[3]<pitch[2]-0.005 and pitch[2]<pitch[1]-0.005,"pitch follows crouching gradually with strength")
end

for _,fps in {30,60,144} do
	for _,mode in {0,1} do
		local a,b=Camera.new(),Camera.new();local s=settings();s.follow.crouch_enabled=false;s.follow.crouch_mode=mode
		s.follow.trick_pop=false;assert(a:set_settings(s));s=Settings.copy(s);s.follow.trick_pop=true;assert(b:set_settings(s))
		local baseA,baseB;local maxA,maxB,aimA,aimB,gapA=0,0,0,0,0
		for i=1,5*fps do
			local t=i/fps;local air=t>2 and t<4
			local u=math.clamp((t-2)/2,0,1);local y=air and 1.6*math.sin(u*math.pi) or 0
			local snap=snapshot(t,-y,air);snap.velocity=vc(0,air and 0.8*math.pi*math.cos(u*math.pi) or 0,6)
			local x=a:update(1/fps,snap,plane,{base_fov_deg=65});local z=b:update(1/fps,snap,plane,{base_fov_deg=65})
			if i==2*fps then baseA,baseB=x.pos.y,z.pos.y end
			if air then
				maxA=math.max(maxA,math.abs(x.pos.y-baseA));maxB=math.max(maxB,math.abs(z.pos.y-baseB))
				aimA=math.max(aimA,x.debug.look_target.y);aimB=math.max(aimB,z.debug.look_target.y)
				gapA=math.max(gapA,math.abs(x.pos.y-snap.position.y))
				T.expect(x.debug.air_rise==0 and x.debug.keep_weight==0,"pop Off removes lift and upward framing")
			end
			T.expect(x.pos.y>=0.25,"pop Off retains floor safety")
		end
		print(string.format("trick pop %d FPS mode %d: height Off %.3f / On %.3f m, aim Off %.3f / On %.3f",fps,mode,maxA,maxB,aimA,aimB))
		T.expect(maxA<maxB*0.4,"pop Off substantially reduces trick-driven camera rise")
		T.expect(gapA<3,"pop Off keeps a bounded body-relative vertical gap rather than pinning the world aim")
	end
end

-- Live mode changes during crouching and pop changes during a jump must ease
-- from the current view instead of jumping back to the takeoff pose.
for _,fps in {30,60,144} do
	local c=Camera.new();local s=settings();c:set_settings(s)
	local previous;local worst=0
	for i=1,4*fps do
		local t=i/fps
		if i==2*fps then s.follow.crouch_mode=1;c:set_settings(s) end
		if i==3*fps then s.follow.crouch_mode=0;c:set_settings(s) end
		local f=c:update(1/fps,snapshot(t,math.clamp((t-1)*0.6,0,0.3),false),plane,{base_fov_deg=65})
		if previous then worst=math.max(worst,math.abs(f.pos.y-previous)) end
		previous=f.pos.y
	end
	T.expect(worst<0.15,"live Height/Pitch change stays gradual at "..fps.." FPS")
	c=Camera.new();s=settings();s.follow.crouch_enabled=false;c:set_settings(s);previous=nil
	local off_step,on_step=0,0
	for i=1,6*fps do
		local t=i/fps;local air=t>2 and t<5
		local u=math.clamp((t-2)/3,0,1);local y=air and 1.6*math.sin(u*math.pi) or 0
		if i==3*fps then s.follow.trick_pop=false;c:set_settings(s) end
		if i==4*fps then s.follow.trick_pop=true;c:set_settings(s) end
		local f=c:update(1/fps,snapshot(t,-y,air),plane,{base_fov_deg=65})
		if previous then
			if i==3*fps then off_step=math.abs(f.pos.y-previous) end
			if i==4*fps then on_step=math.abs(f.pos.y-previous) end
		end
		previous=f.pos.y
	end
	T.expect(off_step<0.2 and on_step<0.2,"midair pop toggle starts from the current framing without a cut")
end

do
	local m=require("mock_reskate").install()
	m.reskate.input.gamepad=function() return nil end
	local app=require("app").start({camera=Camera})
	m.build_page({tabs=2,crouch_mode=2,pop_follow=false})
	T.expect(app.store.settings.follow.crouch_mode==1 and not app.store.settings.follow.trick_pop,"both camera controls work through the real menu")
	local reload=require("store").new();reload:load()
	T.expect(reload.settings.follow.crouch_mode==1 and not reload.settings.follow.trick_pop,"menu values survive a settings reload")
	local c=Camera.new();local s=settings();s.follow.trick_pop=false;s.follow.crouch_mode=1;c:set_settings(s)
	local function wall(a,b)
		if a.z>-.75 and b.z<=-.75 then return a+(b-a)*((-.75-a.z)/(b.z-a.z)),vc(0,0,1) end
		return plane(a,b)
	end
	for i=1,240 do
		local t=i/60;local air=t>2 and t<3
		local snap=snapshot(t,air and -math.sin((t-2)*math.pi) or 0,air)
		snap.position=vc(0,snap.position.y,0);snap.board_position=vc(0,snap.board_position.y,0);snap.velocity=vc(0,0,0)
		local f=c:update(1/60,snap,wall,{base_fov_deg=65})
		T.expect(f.pos.z>-.9 and f.pos.y>0.25,"wall/floor "..i.." "..tostring(f.pos))
	end

	local old=P.collect_values(settings(),P.new_options());old["S3Cam.Follow.CrouchMode"]=nil;old["S3Cam.Follow.TrickPop"]=nil
	local s=P.from_values(old)
	T.expect(s.follow.crouch_mode==0 and s.follow.trick_pop,"older profiles retain Height and pop On")
	old["S3Cam.Follow.CrouchMode"]=1;old["S3Cam.Follow.TrickPop"]=false
	local parsed=P.parse_preset(P.preset_text("Pitch and level pop",P.from_values(old),P.new_options()))
	T.expect(parsed.camera.follow.crouch_mode==1 and not parsed.camera.follow.trick_pop,"new controls survive preset save/reload")
	old["S3Cam.Follow.CrouchMode"]=0.5;old["S3Cam.Follow.TrickPop"]="false"
	s=P.from_values(old);T.expect(s.follow.crouch_mode==0 and s.follow.trick_pop,"invalid new fields fall back safely")
end
T.done()
if T.failures>0 then error("pop/pitch tests failed") end
