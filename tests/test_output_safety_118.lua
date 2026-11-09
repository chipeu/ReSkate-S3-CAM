local T=require("tlib")
local Mock,Settings,Store,Glue,Camera=require("mock_reskate"),require("settings"),require("store"),require("glue"),require("camera")
local vc=vector.create
local UP,FWD=vc(0,1,0),vc(0,0,1)
T.group("output_safety_118")
local function scene()
	local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end;m.reskate.menu.game=function() return {open=false} end
	local st=Store.new();st:load();local s=Settings.defaults();s.follow.trick_pop=false;s.shake_enabled=false
	assert(st:set_settings(s))
	local g=Glue.new({store=st,camera=Camera})
	g.source="ride";g.blend=1;g.skater_position=vc(0,1,0)
	g.snap.valid,g.snap.onboard,g.snap.physics_state=true,true,201;g.snap.position=g.skater_position
	g.snap.forward=FWD;g.render_delta=vc(0,0,0);g.snap_guard_on=false
	return m,st,g
end
local function plane(y)
	return function(a,b)
		if a.y>=y and b.y<=y and a.y~=b.y then return a+(b-a)*((y-a.y)/(b.y-a.y)) end
	end
end
local function show(m,g,p)
	m.state.raycasts=0;g.capped_this_tick=false
	assert(g:show(p,FWD,UP,65,"riding"))
	return m.last_call("set").position
end

-- Floor is sampled under the final eye, not projected from the skater's own
-- floor: a low eye over a raised landing needs its own clearance.
for _,height in {0,0.2,1.5} do
	local m,st,g=scene();m.state.raycast=plane(height)
	g.rays_tick=60 -- all normal work exhausted; final validation has reserved slack
	g.skater_position=vc(0,height+1,0);g.snap.position=g.skater_position
	local p=show(m,g,vc(0,height+0.1,-2))
	T.expect(p.y>=height+0.2999,"final floor validation raises a low eye to configured clearance")
	T.expect(g.rays_tick<=64 and m.state.raycasts<=2,"final floor validation stays inside reserved API ray slots")
end

-- Core and final eyes can both already be below a raised landing surface.
-- The rider is a current-frame height reference, so the probe must start
-- above it and accept a floor below the rider even when above both eyes.
do
	local m,st,g=scene();m.state.raycast=plane(1.5)
	g.rays_tick=60;g.skater_position=vc(0,2.5,0);g.snap.position=g.skater_position
	local p=show(m,g,vc(0,0.8,-2))
	T.expect(math.abs(p.y-1.8)<0.0001,"raised floor rescues a genuinely buried core and shown eye")
	T.expect(g.rays_tick<=62 and m.state.raycasts<=2,"buried-eye rescue uses only reserved final slots")
end

-- Snap recovery can invalidate a collision-safe rig pose after the rig ran.
do
	local m,st,g=scene();m.state.raycast=plane(0)
	g.snap_guard_on=true
	g.guard.filter=function(self,now,pos,f,u,fov)
		self.have=true;return pos-vc(0,1.2,0),f,u,fov
	end
	local original=vc(0,0.6,-2);local p=show(m,g,original)
	T.expect(p==original,"guard cannot move a currently safe pose through the floor")
	T.expect(g.guard.move_velocity==vc(0,0,0) and g.guard.o_rel==p-g.skater_position,"final correction synchronizes recovery rather than repeating its unsafe velocity")
end
do
	local m,st,g=scene()
	m.state.raycast=function(a,b)
		if a.z>-3 and b.z<=-3 then return a+(b-a)*((-3-a.z)/(b.z-a.z)) end
	end
	g.snap_guard_on=true
	g.guard.filter=function(self,now,pos,f,u,fov) self.have=true;return pos-vc(0,0,2),f,u,fov end
	local original=vc(0,1,-2);local p=show(m,g,original)
	T.expect(p==original,"guard cannot sweep the final view through a wall")
end

-- A ceiling above an already safe eye is not the floor. Also, on impossible
-- artificial full-budget exhaustion use this frame's core pose, never an old
-- world-space last_shown pose that would strand the camera after a return.
do
	local m,st,g=scene();m.state.raycast=plane(1.4)
	local p=show(m,g,vc(0,1.2,-2))
	T.expect(math.abs(p.y-1.2)<1e-6,"floor check does not lift the eye through an overhead surface")
	g.rays_tick=64;g.last_shown.pos=vc(0,1.2,-2)
	g.skater_position=vc(100,1,0);g.snap.position=g.skater_position
	p=show(m,g,vc(100,1.2,-2))
	T.expect(p.x==100,"missing final query budget cannot leave the camera at a previous marker")
end

-- Native lens changes must never take over for one air/ground frame while Pop
-- Off. Check both user shot-FOV preferences and both sampling options.
for _,shot in {false,true} do
	for _,stable in {false,true} do
		local m=Mock.install({limit_rays=true})
		m.reskate.input.gamepad=function() return nil end;m.reskate.menu.game=function() return {open=false} end
		local app=require("app").start({camera=Camera});local s=Settings.defaults()
		s.follow.trick_pop=false;s.shake_enabled=false
		s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2.5
		assert(app.store:set_settings(s))
		local o=Settings.copy(app.store.options);o.shot_fov=shot;o.stable_timing=stable;app.store:set_options(o)
		local baseline
		for i=1,420 do
			local t=i/60;local air=t>=2 and t<4
			local a=air and t-2 or 0;local y=air and 1.2*math.sin(a*math.pi/2) or 0
			local root=vc(0,0.95+y,6*t)
			m.state.skater.position=root;m.state.telemetry.physics_state=air and (i%2==0 and 200 or 201) or 100
			m.state.board.deck={position=root-vc(0,0.95,0),rotation={0,0,0,1}}
			m.state.game_camera.fov=air and (i%2==0 and 75 or 55) or 65
			m.fire("physics_step",{at=m.clock_ms,seconds=1/60,velocity={0,air and 1.2*math.pi/2*math.cos(a*math.pi/2) or 0,6},ragdoll=false})
			m.tick(1000/60)
			local c=m.last_call("set")
			if i==119 then baseline=c.fov end
			if air then
				T.expect(c.fov~=nil and math.abs(c.fov-baseline)<0.001,"absolute pre-flight FOV stays owned and stable across native lens/200/201 changes")
			end
		end
		T.expect(app.store.options.shot_fov==shot and app.store.options.stable_timing==stable,"FOV fix retains both saved preferences")
	end
end
T.done()
if T.failures>0 then error("output safety tests failed") end
