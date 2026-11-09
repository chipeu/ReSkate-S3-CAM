local T=require("tlib")
local Mock,Settings,Camera,Before=require("mock_reskate"),require("settings"),require("camera"),require("ref_1110/camera")
local Subject=require("subject")
local vc=vector.create
T.group("fixed_chase")

for _,fps in {30,60,144} do
	for _,high in {false,true} do
		for _,extra in {false,true} do
			local m=Mock.install({limit_rays=true})
			m.reskate.input.gamepad=function() return nil end
			m.reskate.menu.game=function() return {open=false} end
			local app=require("app").start({camera=Camera})
			local s=Settings.defaults();s.shake_enabled=false
			s.angle=high and Settings.CameraAngle.High or Settings.CameraAngle.Low
			s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2
			s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2
			s.fov.speed_fov=extra
			assert(app.store:set_settings(s))
			local o=Settings.copy(app.store.options);o.shot_fov=false;app.store:set_options(o)
			local last=-1
			for i=1,fps*6 do
				local t=i/fps;local n=math.floor(t*60+1e-7);local nt=n/60
				local v=nt<=1 and 0 or nt<4 and 8*(nt-1) or 24
				local z=nt<=1 and 0 or nt<4 and 4*(nt-1)^2 or 36+24*(nt-4)
				local root=vc(0,0.95+0.04*math.sin(nt*6),z)
				m.state.skater.position=root
				m.state.telemetry.physics_state=t>1 and 101 or 100
				m.state.board.velocity=vc(0,0,v)
				m.state.board.deck={position=root-vc(0,0.95,0),rotation={0,0,0,1}}
				m.state.game_camera.fov=60+v*0.5
				for k=last+1,n do m.fire("physics_step",{at=1000+k*1000/60,seconds=1/60,velocity={0,0,v},ragdoll=false}) end
				last=n
				m.tick(1000/fps)
				if t>2 then
					local shown=m.last_call("set")
					local anchor=root+vc(0,s.points.anchor_height-s.points.board_drop,0)
					local distance=vector.magnitude(shown.position-anchor)
					T.expect(math.abs(distance-2)<0.002,"Fixed chase stays body-clamped through full push at "..fps.." fps ("..distance..")")
					T.expect(shown.fov~=nil and math.abs(shown.fov-60)<0.01,"Fixed chase holds FOV through full push with speed-FOV flag "..tostring(extra))
				end
			end
			T.expect(app.errors==0 and app.store.settings.fov.speed_fov==extra,"fixed lock preserves saved FOV preference")
		end
	end
end

-- Speed-based mode retains the original camera mathematics and FOV behavior.
for _,extra in {false,true} do
	local s=Settings.defaults();s.shake_enabled=false;s.fov.speed_fov=extra
	s.ride_distance.mode=Settings.DistanceMode.Speed
	local a,b=Camera.new(),Before.new();assert(a:set_settings(s));assert(b:set_settings(s))
	for i=1,300 do
		local t=i/60
		local subject=Subject.new_snapshot()
		subject.valid,subject.onboard=true,true
		subject.position=vc(0,0.95,2*t*t);subject.velocity=vc(0,0,4*t);subject.time=t
		subject.physics_state=i%60<30 and 100 or 101
		local f=a:update(1/60,subject,function() return nil end,{base_fov_deg=65})
		local old=b:update(1/60,subject,function() return nil end,{base_fov_deg=65})
		T.expect(T.vnear(f.pos,old.pos,1e-7) and T.vnear(f.back,old.back,1e-7) and f.fov_deg==old.fov_deg,"Speed-based camera remains unchanged")
	end
end
do
	local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end
	m.reskate.menu.game=function() return {open=false} end
	m.state.skater.position=vc(0,0.95,0);m.state.board.velocity=vc(0,0,0)
	m.state.raycast=function(a,b)
		local hit,share
		if a.z>-.75 and b.z<=-.75 then share=(-.75-a.z)/(b.z-a.z);hit=a+(b-a)*share end
		if a.y>=0 and b.y<0 then
			local f=-a.y/(b.y-a.y)
			if not share or f<share then hit=a+(b-a)*f end
		end
		return hit
	end
	local app=require("app").start({camera=Camera})
	local s=Settings.defaults();s.shake_enabled=false
	s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,3
	assert(app.store:set_settings(s))
	for i=1,180 do
		m.fire("physics_step",{at=m.clock_ms,seconds=1/60,velocity={0,0,0},ragdoll=false})
		m.tick(1000/60)
	end
	local eye=m.last_call("set").position
	T.expect(eye.z>-.751,"strict Fixed mode cannot push the camera through a wall")
	T.expect(vector.magnitude(eye-vc(0,0.37,0))<2.9,"collision may shorten Fixed distance for safety")
end
T.done()
if T.failures>0 then error("fixed chase tests failed") end
