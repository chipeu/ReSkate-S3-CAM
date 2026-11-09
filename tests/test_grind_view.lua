local T = require("tlib")
local Camera, Before = require("camera"), require("ref_117/camera")
local Subject, Settings, Presets = require("subject"), require("settings"), require("presets")
local vc = vector.create
T.group("grind_view")

local function sample(t,state,slope,pose)
	local s=Subject.new_snapshot()
	s.valid,s.onboard,s.board_valid,s.ground_valid=true,true,true,true
	s.time,s.physics_state=t,state
	s.position=vc(0,0.95+slope*6*t,6*t)
	s.board_position=s.position+vc(pose or 0,-0.95+(pose or 0)*0.3,0)
	s.velocity=vc(0,slope*6,6)
	s.forward=vc(0,0,1)
	s.ground_clearance,s.ground_height=0.95,slope*6*t
	s.ground_normal=vector.normalize(vc(0,1,-slope))
	return s
end
local function plane(slope)
	return function(a,b)
		local x,y=a.y-slope*a.z,b.y-slope*b.z
		if x>=0 and y<=0 and x~=y then return a+(b-a)*(x/(x-y)),vector.normalize(vc(0,1,-slope)) end
		return nil
	end
end
local function config(angle)
	local s=Presets.builtin_values(1)
	s.angle=angle; s.shake_enabled=false
	s.fov.speed_fov=false -- FOV lock in Fixed chase has its own regression suite
	return s
end

-- A ray-free downhill rail reproduces the reported bug independently of collision.
do
	local a,b=Camera.new(),Before.new()
	assert(a:set_settings(config(Settings.CameraAngle.Low)))
	assert(b:set_settings(config(Settings.CameraAngle.Low)))
	local fa,fb
	for i=1,180 do
		local s=sample(i/60,403,-0.5)
		fa=a:update(1/60,s,function() return nil end,{base_fov_deg=65})
		fb=b:update(1/60,s,function() return nil end,{base_fov_deg=65})
	end
	local pitch=math.deg(math.asin(-fa.back.y))
	local old_pitch=math.deg(math.asin(-fb.back.y))
	print(string.format("downhill grind: 1.1.7 pitch %.2f; patched %.2f; lift %.2f",old_pitch,pitch,math.deg(a.downhill_lift)))
	T.expect(old_pitch < -45,"packaged 1.1.7 reproduces steep downward view")
	T.expect(pitch >= -40 and a.downhill_lift>math.rad(10),"downhill grind rises above rail while keeping forward visibility")
end

-- All grind states share the fix; simulated board offsets cover nose/crook-like poses.
for _,fps in {30,60,144} do
	for _,angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
		for _,state in {400,401,402,403,406,499} do
			for _,slope in {0,-0.5,0.5} do
				local c=Camera.new(); assert(c:set_settings(config(angle)))
				local f,s
				for i=1,fps*2 do
					local t=i/fps
					s=sample(t,state,slope,0.15*math.sin(t*3))
					f=c:update(1/fps,s,plane(slope),{base_fov_deg=65})
				end
				local flat=s.position-f.pos; flat=vc(flat.x,0,flat.z)
				T.expect(f.valid and vector.dot(flat,vc(0,0,1))>0.5,"grind stays behind travel with floor collision at "..fps.." fps, state "..state)
				T.expect(math.deg(math.asin(-f.back.y))>=(slope<0 and -40 or -25.5),"flat ledge stays forward; confirmed downhill rail can pitch along its descent")
				T.expect(f.pos.y-slope*f.pos.z>=0.05,"camera remains above the sloped floor")
				if slope<0 then
                    local ahead=s.position+vc(0,slope*3,3)-f.pos
                    local view_error=math.abs(math.atan2(vector.dot(ahead,f.up),vector.dot(ahead,-f.back)))
                    T.expect(view_error<math.rad(35),"descending rail route ahead stays inside the vertical view")
					T.expect(c.downhill_lift>math.rad(10),"downhill rail raises the eye from travel grade")
				else
					T.expect(math.abs(c.downhill_lift)<0.001,"flat or uphill grind has no downhill lift")
				end
			end
		end
	end
end

-- A steep approach can leave a ramp heading hold and terrain lift alive on grind entry.
for _,fps in {30,60,144} do
	local c=Camera.new(); assert(c:set_settings(config(Settings.CameraAngle.Low)))
	local f,s
	local held=false
	for i=1,fps*4 do
		local t=i/fps
		local grinding=t>1
		s=sample(t,grinding and 401 or 100,grinding and -0.5 or 0.9)
		if grinding then
			s.position=vc(0,0.95+5.4-3*(t-1),6*t)
			s.board_position=s.position-vc(0,0.95,0)
			s.ground_height=s.position.y-0.95
			-- Nose/crook animation can face across the rail; travel is still along +Z.
			s.forward=vc(1,0,0)
		end
		f=c:update(1/fps,s,function() return nil end,{base_fov_deg=65})
		if not grinding then held=held or c.transition_hold end
		if t>2 then
			T.expect(not c.transition_hold and not c.swing,"grind releases the ramp hold/swing")
			T.expect(vector.dot(s.position-f.pos,vc(0,0,1))>0.5,"grind follows rail travel despite sideways body facing")
			T.expect(math.deg(math.asin(-f.back.y))>=-40,"ramp hold cannot make a 26-degree descending rail point straight down")
		end
	end
	T.expect(held,"approach fixture really entered ramp heading hold")
	-- Exit to ordinary downhill riding: terrain response is restored, not disabled globally.
	for i=1,fps*2 do
		local t=4+i/fps
		s=sample(t,100,-0.5)
		s.position=vc(0,0.95+5.4-3*(t-1),6*t)
		s.board_position=s.position-vc(0,0.95,0)
		f=c:update(1/fps,s,function() return nil end,{base_fov_deg=65})
	end
	T.expect(c.hill_grade>math.rad(20) and c.downhill_lift>=0,"ordinary downhill clearance responds to measured support after grind exit")
end

-- Air/manual/non-riding responses remain strict against the packaged oracle.
-- Ordinary 100/103 downhill clearance intentionally changes in 1.2.9 and is
-- measured against solid support in test_downhill_clearance_129 instead.
for _,state in {100,200,201,300,701} do
	local a,b=Camera.new(),Before.new()
	local cfg=config(Settings.CameraAngle.Low)
	assert(a:set_settings(cfg)); assert(b:set_settings(cfg))
	for i=1,120 do
		local s=sample(i/60,state,-0.5)
		s.manual=state==100
		local f=a:update(1/60,s,plane(-0.5),{base_fov_deg=65})
		local old=b:update(1/60,s,plane(-0.5),{base_fov_deg=65})
		T.expect(T.vnear(f.pos,old.pos,1e-7) and T.vnear(f.back,old.back,1e-7) and f.fov_deg==old.fov_deg,
			"non-grind behavior unchanged, state "..state)
	end
end

T.done()
if T.failures>0 then error("grind view tests failed") end
