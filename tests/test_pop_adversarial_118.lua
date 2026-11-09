-- Integration scenarios deliberately absent from the former flat, warmed-up
-- pop fixture. No fixed world-Y assertion for large drops: following the actual
-- route and retaining the skater are more important than preserving old height.
local T=require("tlib")
local Mock,Settings,Camera=require("mock_reskate"),require("settings"),require("camera")
local vc=vector.create
T.group("pop_adversarial_118")

local function scene(kind,t)
	local z=t*6
	local state,y,vy,floor,slope=100,0.95,0,0,0
	if kind=="cold_crouch" then
		y=0.65;state=103
		local a=t-1.4
		if a>0 and a<0.8 then state=201;y+=0.25*math.sin(a*math.pi/0.8);vy=0.25*math.pi/0.8*math.cos(a*math.pi/0.8) end
	elseif kind=="held_crouch" then
		local a=t-2.4
		local drop=t>1 and math.clamp((t-1)*0.6,0,0.3) or 0
		if t>1 and a<=0 then state=103 end
		if a>0 and a<0.8 then
			state=201;drop=0.3*math.exp(-a/0.12)
			y=0.95-drop+0.25*math.sin(a*math.pi/0.8)
			vy=2.5*math.exp(-a/0.12)+0.25*math.pi/0.8*math.cos(a*math.pi/0.8)
		else y=0.95-(t<2.4 and drop or 0) end
	elseif kind=="rail_pop" then
		floor=3*math.clamp(t-1,0,1)
		y=floor+0.95;vy=t>1 and t<2 and 3 or 0
		if t>1 then state=403 end
		local a=t-3
		if a>0 and a<0.8 then state=201;y+=0.4*math.sin(a*math.pi/0.8);vy=0.4*math.pi/0.8*math.cos(a*math.pi/0.8) end
	elseif kind=="drop" then
		local a=t-3
		floor=z<18 and 20 or 0
		if a<=0 then y=20.95
		elseif a<2 then state=201;y=20.95-5*a*a;vy=-10*a
		else y=0.95 end
	elseif kind=="slope" then
		slope=0.18;floor=slope*z;y=floor+0.95;vy=slope*6
		local a=t-2.4
		if a>0 and a<0.9 then state=201;y+=0.25*math.sin(a*math.pi/0.9);vy+=0.25*math.pi/0.9*math.cos(a*math.pi/0.9) end
	elseif kind=="fov_cycles" then
		if t>2 then
			local a=(t-2)%1.0
			if a>0 and a<0.6 then state=201;y+=1.2*math.sin(a*math.pi/0.6);vy=1.2*math.pi/0.6*math.cos(a*math.pi/0.6) end
		end
	elseif kind=="small_pop" or kind=="native_fov" then
		local a=t-2
		if a>0 and a<0.8 then state=201;y+=0.25*math.sin(a*math.pi/0.8);vy=0.25*math.pi/0.8*math.cos(a*math.pi/0.8) end
	else error("unknown scenario") end
	return {root=vc(0,y,z),state=state,vy=vy,floor=floor,slope=slope}
end

local function surface(kind,x,z,t)
	if kind=="drop" then return z<18 and 20 or 0 end
	if kind=="rail_pop" then return 3*math.clamp(t-1,0,1) end
	if kind=="slope" then return z*0.18 end
	return 0
end

local function ray_for(kind,t)
	return function(a,b)
		local candidates={}
		if kind=="drop" then
			for _,y in {0,20} do
				if a.y~=b.y then
					local f=(y-a.y)/(b.y-a.y)
					if f>=0 and f<=1 then
						local p=a+(b-a)*f
						if (y==20 and p.z<18) or (y==0 and p.z>=18) then candidates[#candidates+1]={f=f,p=p} end
					end
				end
			end
		else
			local da=a.y-surface(kind,a.x,a.z,t)
			local db=b.y-surface(kind,b.x,b.z,t)
			if da>=0 and db<=0 and da~=db then candidates[1]={f=da/(da-db),p=a+(b-a)*(da/(da-db))} end
		end
		local best
		for _,c in candidates do if not best or c.f<best.f then best=c end end
		if best then return best.p,vector.normalize(vc(0,1,kind=="slope" and -0.18 or 0)) end
	end
end

local function run(kind,fps,high,crouch_on,shot_fov)
	local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end
	m.reskate.menu.game=function() return {open=false} end
	local initial=scene(kind,0)
	m.state.skater.position=initial.root
	m.state.game_camera.position=initial.root+vc(0,1.2,-3)
	m.state.game_camera.fov=65
	local app=require("app").start({camera=Camera})
	local s=Settings.defaults();s.follow.trick_pop=false;s.follow.crouch_enabled=crouch_on
	s.follow.crouch_amount=1;s.shake_enabled=false;s.native_plus.landing_dip=false
	s.angle=high and Settings.CameraAngle.High or Settings.CameraAngle.Low
	s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2.5
	s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,2.5
	assert(app.store:set_settings(s))
	local opts=Settings.copy(app.store.options);opts.shot_fov=shot_fov;app.store:set_options(opts)
	local metrics={ground=math.huge,reach=0,vertical=0,frustum=0,fovjump=0,missing_fov=0,firstpopdip=0,fovmin=math.huge,fovmax=-math.huge}
	local previous,prepop
	for i=1,6*fps do
		local t=i/fps;local b=scene(kind,t)
		m.state.skater.position=b.root;m.state.telemetry.physics_state=b.state
		m.state.telemetry.airborne=b.state==201
		m.state.board.deck={position=b.root-vc(0,0.95,0),rotation={0,0,0,1}}
		m.state.raycast=ray_for(kind,t)
		m.state.game_camera.fov=b.state==201 and (i%2==0 and 65 or 73) or 65
		m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,b.vy,6},ragdoll=false})
		m.tick(1000/fps)
		local f=m.last_call("set")
		if not f then continue end
		if t>0.9 then
			local ground=surface(kind,f.position.x,f.position.z,t)
			metrics.ground=math.min(metrics.ground,f.position.y-ground)
			if f.fov then
				metrics.fovmin=math.min(metrics.fovmin,f.fov);metrics.fovmax=math.max(metrics.fovmax,f.fov)
				if previous and previous.fov then metrics.fovjump=math.max(metrics.fovjump,math.abs(f.fov-previous.fov)) end
			end
		end
		if b.state~=201 then prepop={y=f.position.y,at=t} end
		if b.state==201 then
			metrics.reach=math.max(metrics.reach,vector.magnitude(vc(f.position.x-b.root.x,0,f.position.z-b.root.z)))
			if f.fov==nil then metrics.missing_fov+=1 end
			if prepop and t-prepop.at<0.25 then metrics.firstpopdip=math.max(metrics.firstpopdip,prepop.y-f.position.y) end
			if kind=="drop" and t>4.2 then
				metrics.vertical=math.max(metrics.vertical,math.abs(f.position.y-b.root.y))
				local v=b.root-f.position
				metrics.frustum=math.max(metrics.frustum,math.abs(math.atan2(vector.dot(v,f.up),vector.dot(v,f.forward))))
			end
		end
		previous=f
	end
	local label=string.format("%s %d FPS %s crouch %s shotFov %s",kind,fps,high and "High" or "Low",tostring(crouch_on),tostring(shot_fov))
	print(string.format("adversarial %s: floor %.3f m, reach %.2f m, Y lag %.2f m, frame %.1f deg, FOV step %.2f, nilFOV %d, takeoff dip %.3f m",label,metrics.ground,metrics.reach,metrics.vertical,math.deg(metrics.frustum),metrics.fovjump,metrics.missing_fov,metrics.firstpopdip))
	T.expect(app.errors==0,"no runtime callback errors: "..label)
	T.expect(metrics.reach<3.5,"camera keeps horizontal contact without automatic long pullback: "..label)
	T.expect(metrics.ground>=-0.025,"final shown camera never goes below the modeled terrain: "..label)
	T.expect(metrics.fovjump<0.3,"fixed lens ownership does not jitter between native and plugin FOV: "..label)
	T.expect(metrics.missing_fov==0,"Pop Off continues publishing its lens during air states: "..label)
	if kind=="rail_pop" or kind=="cold_crouch" or kind=="held_crouch" then T.expect(metrics.firstpopdip<0.25,"takeoff does not seek an old crouch/ground reference: "..label) end
	if kind=="drop" then
		T.expect(metrics.vertical<5,"large drop cannot strand the camera near old world altitude: "..label)
		T.expect(metrics.frustum<math.rad(38),"large drop keeps the root in a practical vertical view: "..label)
	end
	if kind=="fov_cycles" then T.expect(metrics.fovmax-metrics.fovmin<0.25,"repeated landings cannot reveal latent air FOV or accumulate lens drift: "..label) end
	return metrics
end

for _,fps in {60,144} do
	for _,high in {false,true} do
		for _,crouch in {false,true} do
			run("cold_crouch",fps,high,crouch,true)
			run("held_crouch",fps,high,crouch,true)
			run("rail_pop",fps,high,crouch,true)
			run("drop",fps,high,crouch,true)
		end
		run("slope",fps,high,false,true)
		run("native_fov",fps,high,false,false)
		run("fov_cycles",fps,high,false,true)
	end
end

T.done()
if T.failures>0 then error("adversarial pop tests failed") end
