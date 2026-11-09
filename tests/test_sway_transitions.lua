local T=require("tlib")
local Mock,Settings,Store=require("mock_reskate"),require("settings"),require("store")
local Off,Glue=require("offboard"),require("glue")
local vc=vector.create
local UP,FWD=vc(0,1,0),vc(0,0,1)
T.group("sway_transitions")

-- Run the real output pipeline twice: enabling sway must not change the base
-- handover, guard history, position or FOV, and Off must immediately match.
local function sequence(sway,fps)
	local m=Mock.install({limit_rays=true})
	local pad={right_x=0.7,right_y=0.3}
	m.reskate.input.gamepad=function() return pad end
	m.reskate.menu.game=function() return {open=false} end
	local st=Store.new();st:load()
	local s=Settings.defaults();s.shake_enabled=false;assert(st:set_settings(s))
	local o=Settings.copy(st.options);o.offboard_mode="dynamic";o.camera_sway=sway;st:set_options(o)
	local g=Glue.new({store=st,camera=require("camera")})
	local result={}
	for i=1,8*fps do
		local t=i/fps
		local foot=t>=1 and t<7
		local ragdoll=t>=2 and t<3
		local marker=t>=4
		local root=vc(marker and 60 or 0,0.95,t*1.5)
		local v=ragdoll and vc(i%2==0 and 80 or -80,-50,30) or vc(0,0,1.5)
		m.state.skater.position=root
		m.state.telemetry.physics_state=foot and 504 or 100
		m.state.telemetry.watch={ragdoll_known=true,ragdoll=ragdoll}
		m.state.board.deck={position=root-vc(0,0.95,0),rotation={0,0,0,1}}
		if t>=5 and st.options.camera_sway then
			local opts=Settings.copy(st.options);opts.camera_sway=false;st:set_options(opts)
		end
		m.clock_ms=1000+t*1000;m.state.raycasts=0
		g:on_physics_step({at=m.clock_ms,seconds=1/fps,velocity={v.x,v.y,v.z},ragdoll=ragdoll})
		g:tick(1000/fps)
		local c=m.last_call("set")
		if not c then continue end
		T.expect(g.running,"scripted pipeline produces a view")
		result[i]={pos=c.position,f=c.forward,u=c.up,fov=c.fov,base=g.last_shown.forward,
			guard=g.guard.o_fwd,active=g.sway_applied,enabled=st.options.camera_sway}
		if t>=5 then
			T.expect(not g.guard.continuous and not g.sway_applied,"Off clears persistent recovery state")
		end
		if t>=5 then T.expect(st.options.camera_sway==false,"bail/remount cannot enable the saved toggle") end
		if i==4*fps then T.expect(not g.guard.smoothing,"marker return clears recovery immediately") end
	end
	return result
end
for _,fps in {30,60,144} do
	local off,on=sequence(false,fps),sequence(true,fps)
	local visible=false
	for i,a in off do
		local b=on[i]
		T.expect(a.fov==b.fov,"sway leaves the existing offboard FOV unchanged")
		T.expect(T.vnear(a.base,b.base,1e-6),"the recovery effect never enters the base handover direction")
		if i>=5*fps then T.expect(T.vnear(a.f,b.f,1e-6) and T.vnear(a.u,b.u,1e-6),"Off exactly matches never-enabled output") end
		if vector.magnitude(a.f-b.f)>0.001 then visible=true end
		T.expect(b.enabled or not b.active,"Off cannot apply the motion effect")
	end
	T.expect(visible,"On retains a visible gentle look effect")
end

-- Compare the reproduced 1.1.11 radius snap with the core's original eased
-- distance during actual Low/High switches, in both directions and frame rates.
local function height_run(module,fps)
	local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end
	m.reskate.menu.game=function() return {open=false} end
	local st=Store.new();st:load()
	local s=Settings.defaults();s.shake_enabled=false
	s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2
	s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,4
	assert(st:set_settings(s))
	local g=module.new({store=st,camera=require("camera")});g.snap_guard_on=false
	local first,worst,error_radius=0,0,0
	local last
	for i=1,7*fps do
		local t=i/fps
		if i==2*fps or i==5*fps then st:toggle_height() end
		m.state.skater.position=vc(0,0.95,0);m.state.board.velocity=vc(0,0,0)
		m.state.board.deck={position=vc(0,0,0),rotation={0,0,0,1}}
		m.clock_ms=1000+t*1000;m.state.raycasts=0
		g:on_physics_step({at=m.clock_ms,seconds=1/fps,velocity={0,0,0},ragdoll=false})
		g:tick(1000/fps)
		local c=m.last_call("set")
		if not c then continue end
		local anchor=m.state.skater.position+vc(0,s.points.anchor_height-s.points.board_drop,0)
		local radius=vector.magnitude(c.position-anchor)
		if i>=2*fps then
			error_radius=math.max(error_radius,math.abs(radius-(g.frame.debug.render_distance or g.frame.debug.distance)))
			if last then worst=math.max(worst,math.abs(radius-last)) end
			if i==2*fps then first=math.abs(radius-last) end
		end
		last=radius
	end
	return first,worst,error_radius
end
for _,fps in {30,60,144} do
	local a=height_run(require("ref_1111/glue"),fps)
	local b,worst,err=height_run(Glue,fps)
	print(string.format("Low/High %d fps first radius step: 1.1.11 %.3f m, patched %.3f m; core trajectory error %.5f m",fps,a,b,err))
	T.expect(a>1.5 and b<0.1,"regression reproduces instant radius snap and restores gradual switch")
	T.expect(worst<0.4 and err<0.002,"both switch directions follow the existing core distance ease")
end
T.done()
if T.failures>0 then error("sway transition tests failed") end

