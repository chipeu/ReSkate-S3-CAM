local T=require("tlib")
local BodyFrame,Off,Before=require("bodyframe"),require("offboard"),require("ref_1110/offboard")
local vc=vector.create
local UP,FWD=vc(0,1,0),vc(0,0,1)
T.group("body_sway")

-- Same 60 Hz body, but 8-13 ms camera lead as in the supplied log. A smooth
-- world-space prediction still moves the skater around in the camera image.
for _,fps in {30,60,144,240} do
	local c=BodyFrame.new()
	local minimum,maximum,oldmin,oldmax=math.huge,-math.huge,math.huge,-math.huge
	for i=1,fps*2 do
		local t=i/fps
		local root=vc(0,0.95,6*math.floor(t*60)/60)
		local delta=vc(0,0,6*(0.008+(i%2)*0.005))
		local eye=root+delta+vc(0,0.4,-2)
		local p=BodyFrame.update(c,t,root,eye,FWD,UP,delta,"ride",false)
		minimum,maximum=math.min(minimum,p.z-root.z),math.max(maximum,p.z-root.z)
		oldmin,oldmax=math.min(oldmin,eye.z-root.z),math.max(oldmax,eye.z-root.z)
	end
	T.expect(oldmax-oldmin>0.029,"reference reproduces body-relative lead wobble")
	T.expect(maximum-minimum<0.00001,"render body lock removes varying lead at "..fps.." fps")
	if fps==60 then print(string.format("body-relative phase range: predicted %.3f mm, body locked %.3f mm",(oldmax-oldmin)*1000,(maximum-minimum)*1000)) end
	local p=BodyFrame.update(c,3,vc(50,1,0),vc(50,2,-2),FWD,UP,vc(0,0,0),"ride",true)
	T.expect(p==vc(50,2,-2),"cut/collision bypasses relative smoothing")
end

local function body(t)
	local c=vc(t<2 and t*1.5 or 3,1,0)
	return {valid=true,centre=c,hips=c-vc(0,0.2,0),head=c+vc(0,0.7,0),heading=0,
		velocity=t<2 and vc(1.5,0,0) or vc(0,0,0),ragdoll=t>1 and t<1.6}
end
-- Camera Sway now uses the original final recovery filter in Glue. The pure
-- off-board rig itself must remain identical to its pre-overlay baseline.
for _,fps in {30,60,144} do
	for _,style in {"orbit","shoulder"} do
		local settings=Off.defaults();Off.apply_style(settings,style,65)
		local a,b=Off.new(settings),Before.new(settings)
		local start={pos=vc(0,2,-3),forward=FWD,up=UP,fov=65}
		a:start(start,body(0));b:start(start,body(0))
		for i=1,fps*6 do
			local t=i/fps
			local input={look_x=t<2 and 0.8 or 0,look_y=t<2 and 0.4 or 0,left_x=0,left_y=0}
			local p,f,u,fov=a:update(1/fps,input,body(t),nil)
			local op,of,ou,ov=b:update(1/fps,input,body(t),nil)
			T.expect(T.vnear(p,op,1e-7) and T.vnear(f,of,1e-7) and T.vnear(u,ou,1e-7) and fov==ov,"base offboard rig retains pre-overlay behavior")
		end
	end
end

-- Full camera pipeline with the same varying event age, while the native body
-- stays on a regular 60 Hz path. Compare actual shown eye offsets, not only input samples.
do
	local Mock,Store,Settings=require("mock_reskate"),require("store"),require("settings")
	local Glue,Old=require("glue"),require("ref_1110/glue")
	local function run(module)
		local m=Mock.install({limit_rays=true})
		m.reskate.input.gamepad=function() return nil end
		m.reskate.menu.game=function() return {open=false} end
		local store=Store.new();store:load()
		local settings=Settings.defaults();settings.shake_enabled=false
		settings.ride_distance.mode=Settings.DistanceMode.Speed
		settings.ride_distance.slow,settings.ride_distance.fast=3,3
		assert(store:set_settings(settings))
		local g=module.new({store=store,camera=require("camera")})
		local lo,hi=math.huge,-math.huge
		for i=1,240 do
			local t=i/60;local root=vc(0,0.95,6*t)
			m.state.skater.position=root;m.state.raycasts=0;m.clock_ms=(10+t)*1000
			m.state.board.deck={position=root-vc(0,0.95,0),rotation={0,0,0,1}}
			g:on_physics_step({at=(10+t-0.008-(i%2)*0.005)*1000,seconds=1/60,velocity={0,0,6},ragdoll=false})
			g:tick(1000/60)
			if i>120 then
				local offset=g.last_shown.pos.z-root.z
				lo,hi=math.min(lo,offset),math.max(hi,offset)
			end
			T.expect(m.state.skater.position==root,"body alignment does not write native skater poses")
		end
		return hi-lo
	end
	local before,after=run(Old),run(Glue)
	print(string.format("shown camera/body offset range: old %.3f mm, patched %.3f mm",before*1000,after*1000))
	T.expect(before>0.025 and after<0.001,"shown camera no longer breathes ahead of the native body")
end

do
	local m=require("mock_reskate").install()
	m.reskate.input.gamepad=function() return nil end
	local app=require("app").start({camera=require("camera")})
	T.expect(app.store.options.camera_sway==false,"new feature defaults Off for existing settings")
	m.build_page({tabs=7,ob_sway=true})
	T.expect(app.store.options.camera_sway and m.storage.settings["S3Cam.Options.CameraSway"]==true,"Camera Sway toggle saves")
	local store=require("store").new();store:load()
	T.expect(store.options.camera_sway,"Camera Sway survives reload")
	local P=require("presets")
	local parsed=P.parse_preset(P.preset_text("Sway",store.settings,store.options))
	T.expect(parsed.options.camera_sway,"Camera Sway round-trips through presets")
end
T.done()
if T.failures>0 then error("body/sway tests failed") end
