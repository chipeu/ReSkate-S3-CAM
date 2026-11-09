local T=require("tlib")
local Camera,Settings,Subject=require("camera"),require("settings"),require("subject")
local vc=vector.create
T.group("pop_manual_116")
local function plane(a,b)
	if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),vc(0,1,0) end
end
for _,fps in {30,60,144} do
	for _,mode in {0,1} do
		for _,amount in {0,0.5,1} do
			local c=Camera.new();local s=Settings.defaults();s.shake_enabled=false;s.native_plus.landing_dip=false
			s.follow.trick_pop=false;s.follow.crouch_mode=mode;s.follow.crouch_amount=amount
			s.angle=Settings.CameraAngle.Low;c:set_settings(s)
			local takeoff,last,grounded;local worst_y,worst_angle,extra=0,0,0
			for i=1,5*fps do
				local t=i/fps;local a=t-2
				local air=a>0 and a<1.4
				local crouch=t>1 and t<=2 and math.min((t-1)*0.6,0.3) or 0
				local rise=air and (7*a-5*a*a) or 0
				local snap=Subject.new_snapshot();snap.valid,snap.onboard,snap.ground_valid=true,true,true
				snap.physics_state=air and 201 or crouch>0 and 103 or 100
				snap.position=vc(0,0.95-crouch+rise,t*6);snap.board_position=vc(0,air and rise or 0,t*6)
				snap.board_valid=true;snap.ground_height=0;snap.ground_clearance=snap.position.y
				snap.velocity=vc(0,air and 7-10*a or 0,6)
				local f=c:update(1/fps,snap,plane,{base_fov_deg=65})
				if i==2*fps then takeoff=f.pos.y end
				if air then
					if last then worst_y=math.max(worst_y,math.abs(f.pos.y-last)) end
					for _,p in {snap.board_position,snap.position,snap.position+vc(0,0.9,0)} do
						local v=p-f.pos;local depth=vector.dot(v,-f.back)
						local angle=math.abs(math.atan2(vector.dot(v,f.up),depth))
						worst_angle=math.max(worst_angle,angle)
					end
					extra=math.max(extra,vector.magnitude(vc(f.pos.x-snap.position.x,0,f.pos.z-snap.position.z)))
					T.expect(f.pos.y<takeoff+(a<1 and 0.08 or 0.16),"grounded takeoff/apex; bounded clearance adjustment near landing")
				end
				last=f.pos.y
			end
			print(string.format("grounded pop %d FPS mode %d amount %.1f: Y step %.3f m, frame %.1f deg, horizontal room %.2f m",fps,mode,amount,worst_y,math.deg(worst_angle),extra))
			T.expect(worst_y<0.15,"crouch to pop has no vertical recenter snap")
			T.expect(worst_angle<math.rad(35),"high trick, board and head remain inside the 65 degree view with a small framing margin")
			T.expect(extra>3,"grounded framing makes horizontal room for the high trick")
		end
	end
end

do
	local Mock=require("mock_reskate");local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end;m.reskate.menu.game=function() return {open=false} end
	local app=require("app").start({camera=Camera});local s=Settings.defaults();s.shake_enabled=false
	s.framing.manual_camera=true;s.framing.manual_distance=0.9;app.store:set_settings(s)
	local found=false
	for i=1,300 do
		local t=i/60;local tilt=t>1 and t<3 and math.rad(12) or 0
		local root=vc(0,0.95,t*3)
		m.state.skater.position=root;m.state.telemetry.physics_state=100
		m.state.board.deck={position=vc(0,0,t*3),rotation={math.sin(tilt/2),0,0,math.cos(tilt/2)}}
		m.fire("physics_step",{at=m.clock_ms,seconds=1/60,velocity={0,0,3},ragdoll=false});m.tick(1000/60)
		if t>1.7 and t<2.8 then
			local d=app.glue.frame.debug
			T.expect(app.glue.snap.manual and string.find(d.shot_name,"manual",1,true)~=nil,"sustained deck tilt activates the actual manual camera with no trick notes")
			T.expect(d.distance<1.1,"manual close-up uses its configured distance")
			found=true
		end
	end
	T.expect(found and app.manual.count==1 and not app.glue.snap.manual,"one manual detected and cleared after the board levels")
	T.expect(app.errors==0,"manual fallback introduces no callback errors")
end

do
	local Manual=require("manual")
	for _,state in {103,201,403,504} do
		local m=Manual.new()
		for i=1,120 do T.expect(not m:update(i/60,state,state~=504,state==201,state==403,12,3),"crouches, air, grinds and offboard cannot trigger tilt manuals") end
	end
	local m=Manual.new()
	for i=1,120 do T.expect(not m:update(i/60,100,true,false,false,i%30<5 and 12 or 0,3),"brief push/landing rocking cannot trigger manuals") end
	m:on_notes({{kind="n",entry="revert",text="Revert"}},2)
	for i=1,24 do T.expect(not m:update(2+i/60,101,true,false,false,12,3),"named reverts suppress pose fallback") end
end
T.done()
if T.failures>0 then error("grounded pop/manual tests failed") end
