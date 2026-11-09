local T=require("tlib")
local Camera,Before,Ref1120,Settings,Subject=require("camera"),require("ref_1117/camera"),require("ref_1120/camera"),require("settings"),require("subject")
local vc=vector.create
T.group("pop_deadzone_118")
local function plane(a,b)
	if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),vc(0,1,0) end
end
local function sample(t,state,y,vy)
	local s=Subject.new_snapshot();s.valid,s.onboard,s.ground_valid=true,true,true
	s.time=t;s.physics_state=state;s.position=vc(0,y,t*6);s.velocity=vc(0,vy or 0,6)
	s.board_valid=true;s.board_position=s.position-vc(0,0.95,0);s.ground_height=0;s.ground_clearance=y
	return s
end

-- The normal mode remains equivalent before touchdown. The 1.1.21 landing
-- bounce and same-level eye handoff intentionally change the later poses.
for _,fps in {30,60,144} do
	local a,b=Camera.new(),Before.new();local set=Settings.defaults();set.shake_enabled=false
	assert(a:set_settings(set));assert(b:set_settings(set))
	for i=1,6*fps do
		local t=i/fps;local state,y,vy=100,0.95,0
		if t>1 and t<2 then state=103;y=0.65 end
		if t>=2 and t<3 then state=201;y+=math.sin((t-2)*math.pi);vy=math.pi*math.cos((t-2)*math.pi) end
		if t>=3 and t<4 then state=403;y+=0.3*(t-3) end
		if t>=4 and t<5 then state=201;y+=0.3+0.5*math.sin((t-4)*math.pi) end
		local s=sample(t,state,y,vy)
		local x=a:update(1/fps,s,plane,{base_fov_deg=65});local old=b:update(1/fps,s,plane,{base_fov_deg=65})
		if t<3 then
			T.expect(T.vnear(x.pos,old.pos,0.00001) and T.vnear(x.back,old.back,0.00001) and x.fov_deg==old.fov_deg,"Pop On retains the 1.1.17 path before touchdown")
		end
	end
end

-- An unrelated default-On ride, manual, grind and uninterrupted flight must
-- still match the pinned 1.1.20 plugin at every frame.
for _,fps in {30,60,144} do
	local a,b=Camera.new(),Ref1120.new()
	local set=Settings.defaults();set.shake_enabled=false;set.native_plus.landing_dip=false
	assert(a:set_settings(set));assert(b:set_settings(set))
	for i=1,6*fps do
		local t=i/fps;local state,y,vy=100,0.95,0
		if t>1 and t<2 then state=103;y=0.65 end
		if t>=2 and t<3 then state=403;y=0.95 end
		if t>=3 then state=201;y=0.95+0.5*(t-3);vy=0.5 end
		local s=sample(t,state,y,vy)
		local x=a:update(1/fps,s,plane,{base_fov_deg=65})
		local old=b:update(1/fps,s,plane,{base_fov_deg=65})
		T.expect(T.vnear(x.pos,old.pos,0.00001) and T.vnear(x.back,old.back,0.00001) and x.fov_deg==old.fov_deg,
			"default On matches actual 1.1.20 through ride, manual, grind and unlanded air "..fps)
	end
end

for _,fps in {30,60,144} do
	for _,high in {false,true} do
		local set=Settings.defaults();set.follow.trick_pop=false;set.shake_enabled=false;set.native_plus.landing_dip=false
		set.angle=high and Settings.CameraAngle.High or Settings.CameraAngle.Low
		set.ride_distance.mode,set.ride_distance.fixed=Settings.DistanceMode.Fixed,2.5
		set.ride_distance_high.mode,set.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.5
		local c=Camera.new();assert(c:set_settings(set))
		local pre,heldFov;local maxSmall=0
		for i=1,4*fps do
			local t=i/fps;local a=t-2;local air=a>0 and a<0.8
			local y=0.65+(air and 0.25*math.sin(a*math.pi/0.8) or 0)
			local s=sample(t,air and 201 or 103,y,0)
			local f=c:update(1/fps,s,plane,{base_fov_deg=65})
			if i==2*fps then pre=f.pos.y;heldFov=f.fov_deg end
			if air then
				maxSmall=math.max(maxSmall,math.abs(f.pos.y-pre))
				T.expect(math.abs(f.fov_deg-heldFov)<0.001,"small pop holds its actual pre-flight absolute lens")
				T.expect(f.debug.pop_vertical_weight<0.001,"small pop stays inside a zero-follow height deadzone")
			end
		end
		T.expect(maxSmall<0.08,"cold crouch starts from its actual view, without searching for an unobserved neutral pose")

		-- Travel up an elevated grind before jumping; the takeoff pose must come
		-- from that rail, never the ordinary ground pose cached seconds earlier.
		c=Camera.new();c:set_settings(set);local before,minimum=0,math.huge
		for i=1,5*fps do
			local t=i/fps;local rail=3*math.clamp(t-1,0,1);local a=t-3
			local air=a>0 and a<0.8
			local y=0.95+rail+(air and 0.25*math.sin(a*math.pi/0.8) or 0)
			local f=c:update(1/fps,sample(t,air and 201 or t>1 and 403 or 100,y,0),plane,{base_fov_deg=65})
			if i==3*fps then before=f.pos.y end
			if air and a<0.25 then minimum=math.min(minimum,f.pos.y) end
		end
		T.expect(before-minimum<0.15,"elevated grind hop does not dip toward an old walking/chase height")

		-- A tall ascent followed by a long drop keeps a bounded body-relative
		-- vertical gap, while local ordinary pops remain level.
		c=Camera.new();c:set_settings(set);local worst=0;local followed=false;local body_angle=0
		for i=1,6*fps do
			local t=i/fps;local a=t-2;local air=a>0
			local y=20.95+(air and (a<1 and 4*a or 4-5*(a-1)^2) or 0)
			local s=sample(t,air and 201 or 100,y,air and (a<1 and 4 or -10*(a-1)) or 0)
			local f=c:update(1/fps,s,function() return nil end,{base_fov_deg=65})
			if air then
				if y<19.95 then worst=math.max(worst,math.abs(f.pos.y-y)) end
				followed=followed or f.debug.pop_vertical_weight>0.9
				local reach=vector.magnitude(vc(f.pos.x,y,f.pos.z)-vc(s.position.x,y,s.position.z))
				T.expect(reach<3.2,"large elevation changes never add distance pullback")
				if y<19.95 then
					for _,point in {s.board_position,s.position+vc(0,0.95,0)} do
						local v=point-f.pos
						body_angle=math.max(body_angle,math.abs(math.atan2(vector.dot(v,f.up),vector.dot(v,-f.back))))
					end
				end
			end
		end
		print(string.format("bounded core %d FPS %s: local height drift %.4f m, large-route Y gap %.3f m",fps,high and "High" or "Low",maxSmall,worst))
		T.expect(worst<3 and followed,"real drop follows below the held takeoff level")
		T.expect(body_angle<math.rad(34),"large-drop minimum aim retains board/head angle="..math.deg(body_angle))
	end
end
T.done()
if T.failures>0 then error("bounded pop core tests failed") end
