local T=require("tlib")
local Mock,Settings,Store=require("mock_reskate"),require("settings"),require("store")
local Glue,Camera=require("glue"),require("camera")
local vc=vector.create
T.group("render_transitions")

local function scene(module)
	local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end
	m.reskate.menu.game=function() return {open=false} end
	local st=Store.new();st:load()
	local s=Settings.defaults();s.shake_enabled=false
	s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2
	s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,4
	assert(st:set_settings(s))
	local g=module.new({store=st,camera=Camera})
	return m,st,s,g
end

local function height(module,fps,stable)
	local m,st,s,g=scene(module)
	local o=Settings.copy(st.options);o.stable_timing=stable;st:set_options(o)
	g.snap_guard_on=false -- inspect the requested transition, before recovery
	local worst=0
	for i=1,5*fps do
		local t=i/fps
		if i==2*fps or i==3*fps then st:toggle_height() end
		m.state.skater.position=vc(0,0.95,0);m.state.board.velocity=vc(0,0,0)
		m.state.board.deck={position=vc(0,0,0),rotation={0,0,0,1}}
		m.clock_ms=1000+t*1000;m.state.raycasts=0
		g:on_physics_step({at=m.clock_ms,seconds=1/60,velocity={0,0,0},ragdoll=false})
		g:tick(1000/fps)
		local c=m.last_call("set")
		if not c or i<2*fps then continue end
		local anchor=m.state.skater.position+vc(0,s.points.anchor_height-s.points.board_drop,0)
		local radius=vector.magnitude(c.position-anchor)
		worst=math.max(worst,math.abs(radius-g.frame.debug.render_distance))
	end
	return worst
end
for _,fps in {60,144,240} do
	for _,stable in {true,false} do
		local before=height(require("ref_1112/glue"),fps,stable)
		local after=height(Glue,fps,stable)
		print(string.format("rendered Low/High radius error %d FPS stability %s: old %.3f mm -> %.3f mm",fps,tostring(stable),before*1000,after*1000))
		T.expect(before>0.005 and after<0.002,"Low/High radius and pose use the same interpolation clock")
	end
end

-- A returned camera correction must not become the next filter input.
do
	local B=require("bodyframe")
	local c=B.new()
	for i=1,180 do
		local origin=vc(i*0.1,1,0)
		local delta=vc(0.04,0.002,0)
		local wanted=origin+vc(0,0.5+0.1*math.sin(i/15),-3)
		local f=vector.normalize(vc(0,-0.2,1));local u=vc(0,1,0)
		local p,forward,up=B.update(c,i/144,origin,wanted+delta,f,u,delta,"ride",false)
		T.expect(T.vnear(p,wanted,0.00001) and forward==f and up==u,"phase alignment adds no second pose ease or aim wobble")
		c.offset=vc(0,2,-1) -- simulate a collision/guard output differing from the request
	end
end

-- Keep sway enabled across an active off-board look, remount and onboard marker
-- return. Compare actual camera output to a never-enabled run, including the
-- first remount frame, and verify effects are fully cleared at the return.
local function remount(sway)
	local m,st,s,g=scene(Glue)
	local pad={right_x=0.7,right_y=0.2}
	m.reskate.input.gamepad=function() return pad end
	local o=Settings.copy(st.options);o.camera_sway=sway;st:set_options(o)
	local result={}
	for i=1,480 do
		local t=i/60
		local foot=i>=60 and i<180
		local root=vc(i>=240 and 80 or 0,0.95,t*1.5)
		m.state.skater.position=root;m.state.telemetry.physics_state=foot and 504 or 100
		m.state.telemetry.watch={ragdoll_known=true,ragdoll=false}
		m.state.board.deck={position=root-vc(0,0.95,0),rotation={0,0,0,1}}
		m.clock_ms=1000+t*1000;m.state.raycasts=0
		g:on_physics_step({at=m.clock_ms,seconds=1/60,velocity={0,0,1.5},ragdoll=false})
		g:tick(1000/60)
		local c=m.last_call("set")
		if c and not foot then
			result[i]={p=c.position,f=c.forward,u=c.up}
			T.expect(g.sway_applied==false,"sway is never applied onboard, including first remount frame")
			T.expect(not g.guard.continuous,"onboard has no continuous offboard recovery")
		end
		if i==240 then
			T.expect(g.frame.debug.reset and not g.guard.smoothing,"onboard marker return cuts all camera histories")
			T.expect(g.frame.debug.landing_dip==0 and g.frame.debug.impulse==0,"marker cut has no retained landing bounce or impulse")
		end
	end
	return result
end
local off,on=remount(false),remount(true)
for i,a in off do
	-- The mount blend starts at the actual swayed view to avoid a cut. Once
	-- that ordinary handover finishes, all riding output must match.
	if i>=180 and i<270 then continue end
	local b=on[i]
	T.expect(T.vnear(a.p,b.p,0.00001) and T.vnear(a.f,b.f,0.00001) and T.vnear(a.u,b.u,0.00001),"onboard output is independent of the enabled offboard sway option")
end

do
	local m=Mock.install();m.reskate.input.gamepad=function() return nil end
	local app=require("app").start({camera=Camera})
	m.build_page({tabs=2})
	local found=false
	for _,w in m.widgets do if w.id=="o_stability" then found=true end end
	T.expect(not found,"Stability test is absent from CAMERA")
	m.build_page({tabs=8,o_stability=false})
	T.expect(app.store.options.stable_timing==false,"Stability test is editable in ADVANCED")
end
T.done()
if T.failures>0 then error("render transition tests failed") end
