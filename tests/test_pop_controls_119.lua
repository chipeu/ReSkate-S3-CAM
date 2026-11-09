local T=require("tlib")
local Camera,Before,Settings,Subject=require("camera"),require("ref_1118/camera"),require("settings"),require("subject")
local vc=vector.create
T.group("pop_controls_119")

local function sample(t,state,y,vy,ground)
	local s=Subject.new_snapshot()
	s.valid,s.onboard,s.ground_valid=true,true,true
	s.time,s.physics_state=t,state
	s.position=vc(0,y,t*5);s.velocity=vc(0,vy or 0,5)
	s.board_valid=true;s.board_position=s.position-vc(0,0.95,0)
	s.ground_height=ground or 0;s.ground_clearance=y-s.ground_height
	return s
end
local function plane(a,b)
	if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),vc(0,1,0) end
end
local function config(mode,amount,on)
	local s=Settings.defaults()
	s.follow.pop_mode,s.follow.pop_amount,s.follow.trick_pop=mode,amount,on
	s.shake_enabled=false;s.native_plus.landing_dip=false
	s.fov.speed_fov=false
	return s
end
local function run(fps,mode,amount,on,drop,stall,amplitude,high)
	local c=Camera.new();local settings=config(mode,amount,on)
	settings.angle=high and Settings.CameraAngle.High or Settings.CameraAngle.Low
	assert(c:set_settings(settings))
	local before,pre_pitch,small_y,peak_pitch,drop_weight,lowest=0,0,0,-math.huge,0,math.huge
	local baseline_fov,largest_fov_step,board_angle,root_angle=0,0,0,0
	local t=0
	while t<3.0 do
		local dt=1/fps
		if stall and t>2.1 and t<2.1+dt then dt=0.085 end
		t+=dt
		local a=t-1.2
		local air=a>0 and a<1.4
		local y,vy=0.95,0
		if air then
			if drop then y=0.95-4.0*math.max(0,a-0.25);vy=a>0.25 and -4 or 0
			else local lift=amplitude or 0.28;y=0.95+lift*math.sin(math.pi*a/1.4);vy=lift*math.pi/1.4*math.cos(math.pi*a/1.4) end
		elseif drop and a>=1.4 then y=0.95-4.0*1.15 end
		local f=c:update(dt,sample(t,air and 201 or 100,y,vy,drop and a>=1.4 and y-0.95 or 0),plane,{base_fov_deg=65})
		if a<=0 then before=f.pos.y;baseline_fov=f.fov_deg;pre_pitch=math.atan2(-f.back.y,math.sqrt(f.back.x*f.back.x+f.back.z*f.back.z)) end
		if air then
			small_y=math.max(small_y,math.abs(f.pos.y-before))
			local pitch=math.atan2(-f.back.y,math.sqrt(f.back.x*f.back.x+f.back.z*f.back.z))
			peak_pitch=math.max(peak_pitch,pitch-pre_pitch)
			drop_weight=math.max(drop_weight,c.pop_drop_w or 0)
			lowest=math.min(lowest,f.pos.y-y)
			largest_fov_step=math.max(largest_fov_step,math.abs(f.fov_deg-baseline_fov))
			local root=vc(0,y,t*5)-f.pos
			root_angle=math.max(root_angle,math.abs(math.atan2(vector.dot(root,f.up),vector.dot(root,-f.back))))
			if not drop then
				for _,point in {vc(0,y-0.95,t*5),vc(0,y+0.95,t*5)} do
					local v=point-f.pos
					board_angle=math.max(board_angle,math.abs(math.atan2(vector.dot(v,f.up),vector.dot(v,-f.back))))
				end
			end
			if drop and a>0.8 then
				local board=vc(0,y-0.95,t*5)
				local v=board-f.pos
				board_angle=math.max(board_angle,math.abs(math.atan2(vector.dot(v,f.up),vector.dot(v,-f.back))))
			end
		end
	end
	return small_y,peak_pitch,drop_weight,lowest,largest_fov_step,board_angle,root_angle
end

for _,fps in {30,60,144} do
	local current,old=Camera.new(),Before.new()
	local defaults=Settings.defaults();defaults.shake_enabled=false
	assert(current:set_settings(defaults) and old:set_settings(defaults))
	for i=1,3*fps do
		local t=i/fps
		local a=t-1
		local air=a>0 and a<1.5
		local y=air and (a<0.5 and 0.95+2*a or 1.95-3*(a-0.5)) or 0.95
		local s=sample(t,air and 201 or 100,y,air and (a<0.5 and 2 or -3) or 0)
		local x=current:update(1/fps,s,plane,{base_fov_deg=65})
		local b=old:update(1/fps,s,plane,{base_fov_deg=65})
		if a<1.5 then -- touchdown transfer and bounce were deliberately revised in 1.1.21
			T.expect(T.vnear(x.pos,b.pos,1e-6) and T.vnear(x.back,b.back,1e-6) and x.fov_deg==b.fov_deg,
				"On/default matches actual 1.1.18 camera before touchdown "..fps)
		end
	end
end

for _,fps in {30,60,144} do
	for _,mode in {0,1} do
		local off_y,off_pitch,off_drop=run(fps,mode,1,false,false,false)
		local zero_y,zero_pitch=run(fps,mode,0,true,false,false)
		local half_y,half_pitch=run(fps,mode,0.5,true,false,false)
		local full_y,full_pitch=run(fps,mode,1,true,false,false)
		T.expect(off_y<0.09 and zero_y<0.09 and off_drop==0,"flat pop holds eye at 0 percent / Off "..fps.." mode "..mode)
		T.expect(math.deg(off_pitch)<1.5 and math.deg(zero_pitch)<1.5,"flat Pop Off does not aim up "..fps.." mode "..mode)
		if mode==0 then
			T.expect(half_y>off_y+0.03 and full_y>half_y+0.03,"height mode strength moves eye proportionally "..fps)
		else
			T.expect(full_y<0.12 and half_y<0.12,"pitch mode keeps ordinary pop eye level "..fps)
			T.expect(full_pitch>half_pitch+math.rad(0.5) and half_pitch>off_pitch+math.rad(0.5),"pitch mode follows pop aim proportionally "..fps)
		end
		local drop_y,_,safety,gap,lens_step,board_angle=run(fps,mode,1,false,true,true)
		print(string.format("large Pop Off drop %d mode %d: eye travel %.3f rider gap %.3f weight %.3f board angle %.2f lens step %.3f",fps,mode,drop_y,gap,safety,math.deg(board_angle),lens_step))
		T.expect(safety>0.8 and gap<3 and drop_y>1.0,"verified large drop restores normal follow after 85ms frame "..fps.." mode "..mode)
		T.expect(math.deg(board_angle)<36,"large drop keeps landing direction in view "..fps.." mode "..mode)
		T.expect(lens_step<0.1,"Pop Off keeps the absolute lens stable across a stalled drop "..fps.." mode "..mode)
	end
end

for _,fps in {30,60,144} do
	for _,high in {false,true} do
		for _,lift in {1.2,1.6} do
			local eye,up,_,_,_,body_angle,root_angle=run(fps,0,1,false,false,false,lift,high)
			T.expect(math.deg(up)<0.5,"high flat Pop Off never tilts upward "..fps.." "..tostring(high).." "..lift)
			-- Stable Off deliberately does not reframe a high flat pop to fit the body.
			T.expect(eye<0.03,"high flat Pop Off keeps selected camera height "..fps.." "..tostring(high).." "..lift)
		end
	end
end

for _,fps in {30,60,144} do
	local function wave(missing)
		local c=Camera.new();local cfg=config(0,1,true)
		cfg.follow.crouch_enabled=false
		assert(c:set_settings(cfg))
		local lo,hi=math.huge,-math.huge
		local heights={}
		for i=1,3*fps do
			local t=i/fps
			local body=0.95+(t>1 and 0.12*math.sin(2*math.pi*2*(t-1)) or 0)
			local s=sample(t,100,body,0,0)
			s.board_position=vc(0,0,t*5)
			if missing and i==math.floor(1.7*fps) then s.ground_valid=false end
			local f=c:update(1/fps,s,plane,{base_fov_deg=65})
			heights[i]=f.pos.y
			if t>1.25 and t<2.8 then lo=math.min(lo,f.pos.y);hi=math.max(hi,f.pos.y) end
		end
		return hi-lo,heights
	end
	local range,with_miss=wave(true)
	local _,continuous=wave(false)
	local miss_frame=math.floor(1.7*fps)
	local extra=0
	for i=miss_frame,math.min(miss_frame+math.floor(0.2*fps),#with_miss) do
		extra=math.max(extra,math.abs(with_miss[i]-continuous[i]))
	end
	T.expect(range<0.02,"Crouch Off removes grounded body wave "..fps)
	T.expect(extra<0.005,"one missed ground ray adds no visible body-follow pulse "..fps)
end

T.done()
if T.failures>0 then error("pop control tests failed") end
