local T=require("tlib")
local Mock,Settings=require("mock_reskate"),require("settings")
local Old=require("ref_1113/snapguard")
local vc=vector.create
local UP=vc(0,1,0)
T.group("bail_sway")

local function setup()
	local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end
	m.state.raycast=function() return nil end
	local app=require("app").start({camera=require("camera")})
	local opts=Settings.copy(app.store.options);opts.stable_timing=true;opts.camera_sway=false;app.store:set_options(opts)
	local g=app.glue
	g.source="foot";g.running=true;g.snap.valid=true;g.snap.onboard=false
	g.skater_position=vc(0,1,0);g.snap.position=g.skater_position;g.body.centre=g.skater_position
	return m,app,g
end
local function pose(t,root)
	local yaw=math.sin(t*1.7)*0.9
	local pitch=math.sin(t*1.3)*0.35
	local f=vc(math.sin(yaw)*math.cos(pitch),math.sin(pitch),math.cos(yaw)*math.cos(pitch))
	local r=vector.normalize(vector.cross(f,UP));local u=vector.cross(r,f)
	return root+vc(0,0.8,0)-f*3,f,u
end
local function show(m,g,t,p,f,u)
	m.clock_ms=10000+t*1000;m.state.raycasts=0;g.rays_tick=0;g.capped_this_tick=false
	assert(g:show(p,f,u,65,"offboard"))
	return m.last_call("set")
end

-- The oracle is the exact recovery algorithm from the installed 1.1.13 ZIP.
-- Force the old accidental persistent state explicitly, rather than compare
-- with the artificial banking effect the user rejected.
for _,stable in {true,false} do
for _,fps in {30,60,144} do
	local m,app,g=setup()
	local opts=Settings.copy(app.store.options);opts.stable_timing=stable;app.store:set_options(opts)
	m.build_page({tabs=7,ob_sway=true})
	local old=Old.new();old.stable=true
	local maximum=0
	for i=1,6*fps do
		local t=i/fps
		local p,f,u=pose(t,g.skater_position)
		g.snap.bailing=t>=2 and t<3
		if i>1 then old.smoothing=true;old.duration=0.6;old.move_velocity=old.move_velocity or vc(0,0,0) end
		local op,of,ou=old:filter(10+t,p,f,u,65,g.skater_position,false)
		local c=show(m,g,t,p,f,u)
		T.expect(T.vnear(c.position,op,0.00001) and T.vnear(c.forward,of,0.00001) and T.vnear(c.up,ou,0.00001),"On reproduces the original bail-recovery motion at "..fps.." FPS")
		T.expect(g.sway_applied and g.guard.continuous,"On works before, during and after a bail")
		T.expect(math.abs(vector.dot(c.forward,c.up))<0.0001,"recovery supplies an orthogonal camera basis")
		maximum=math.max(maximum,vector.magnitude(c.forward-f))
	end
	T.expect(maximum>0.03,"On gives perceptible look momentum without a slam")
	-- Toggle through the real settings widget, with no marker/teleport event.
	for _,enabled in {false,true,false,true,false} do
		m.build_page({tabs=7,ob_sway=enabled})
		local t=m.clock_ms/1000-10+1/fps
		local p,f,u=pose(t,g.skater_position)
		g.snap.bailing=true
		local c=show(m,g,t,p,f,u)
		T.expect(app.store.options.camera_sway==enabled and m.storage.settings["S3Cam.Options.CameraSway"]==enabled,"live toggle saves the requested value")
		T.expect(g.guard.continuous==enabled and g.sway_applied==enabled,"toggle takes effect on the very next shown frame, even during a bail")
		T.expect(T.vnear(c.position,p,0.00001) and T.vnear(c.forward,f,0.00001),"toggle changes discard prior recovery and start from the current base pose")
	end
	-- A slam with Off may need a finite safe position recovery, but must never
	-- create angular sway or a persistent orbit mode until the next marker.
	for i=1,8*fps do
		local t=7+i/fps
		local p,f,u=pose(t,g.skater_position)
		if i<fps then p+=vc(2,0.3,0) end
		g.snap.bailing=i<fps
		local c=show(m,g,t,p,f,u)
		T.expect(not g.sway_applied and not g.guard.continuous and not app.store.options.camera_sway,"slam cannot enable sway with Off")
		T.expect(T.vnear(c.forward,f,0.00001),"Off follows look direction directly before/during/after a slam")
		if i>3*fps then T.expect(not g.guard.smoothing,"Off cannot remain in accidental recovery mode") end
	end
end

end

-- A continuous lagged orbit must not be left behind a newly encountered wall,
-- or accept an unchecked position when the plugin's ray budget is exhausted.
for _,budget in {false,true} do
	local m,app,g=setup();m.build_page({tabs=7,ob_sway=true})
	local p,f,u=pose(0,g.skater_position);show(m,g,0,p,f,u)
	p,f,u=pose(0.4,g.skater_position)
	m.state.raycast=function(a,b) return a+(b-a)*0.5 end
	m.clock_ms=10400;m.state.raycasts=0;g.rays_tick=budget and 64 or 0;g.capped_this_tick=false
	assert(g:show(p,f,u,65,"offboard"))
	T.expect(T.vnear(m.last_call("set").position,p,0.00001),"collision/budget keeps the already checked base camera position")
end

-- Cut must erase continuous velocity too: no pre-return inertia on a marker.
do
	local m,app,g=setup();m.build_page({tabs=7,ob_sway=true})
	for i=1,120 do local p,f,u=pose(i/60,g.skater_position);show(m,g,i/60,p,f,u) end
	g.guard:cut()
	local p,f,u=pose(2.1,g.skater_position);local c=show(m,g,2.1,p,f,u)
	T.expect(T.vnear(c.position,p,0.00001) and T.vnear(c.forward,f,0.00001),"marker cut starts at the current view without old momentum")
	T.expect(g.guard.move_velocity==vc(0,0,0),"cut clears the recovery velocity")
end
T.done()
if T.failures>0 then error("bail sway tests failed") end
