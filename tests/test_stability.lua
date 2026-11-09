local T=require("tlib")
local Timing,Guard,OldGuard=require("timing"),require("snapguard"),require("ref_119/snapguard")
local vc=vector.create
local UP,FWD=vc(0,1,0),vc(0,0,1)
T.group("stability")

-- Sample a true constant-speed path at a physics rate, then deliver it at an unrelated
-- render rate. Event time and delivery time are deliberately different.
for _,hz in {30,60,120} do
	for _,fps in {30,59,60,75,120,144,165,240} do
		local c=Timing.new()
		local previous,raw_previous,seen,previous_root
		local err,old_err,n=0,0,0
		for i=1,fps*3 do
			local now=10+i/fps+0.37/hz
			local index=math.floor((now-10)*hz+1e-8)
			local at=10+index/hz
			local root=vc(0,0,6*(at-10))
			local p=Timing.update(c,now,root,vc(0,0,6),1/hz,at,false,false)
			local changed=root~=previous_root
			if changed then seen=now;previous_root=root end
			local old=root+vc(0,0,changed and 0 or 6*math.clamp(now-seen,0,1/30))
			T.expect(math.abs(p.z-6*(now-10))<0.00005,"timestamped render position matches physical path")
			if previous and i>fps then
				err+=(p.z-previous-6/fps)^2
				old_err+=(old.z-raw_previous-6/fps)^2
				n+=1
			end
			previous,raw_previous=p.z,old.z
		end
		local rms,old_rms=math.sqrt(err/n),math.sqrt(old_err/n)
		if fps==59 or fps==75 or fps==144 or fps==165 then
			T.expect(rms<0.00001 and rms<old_rms*0.05,"physics/render beat is removed at "..hz.."/"..fps)
		end
		if hz==60 and fps==144 then print(string.format("60 Hz physics / 144 fps: step error old %.3f mm, timestamped %.3f mm",old_rms*1000,rms*1000)) end
	end
end

do
	local c=Timing.new()
	local root=vc(0,2,0)
	local p=Timing.update(c,1,root,vc(0,0,10000),1/60,0.99,false,false)
	T.expect(vector.magnitude(p-root)<=1.00001,"outlier velocity has bounded camera-only lead")
	p=Timing.update(c,1.3,root,vc(0,0,6),1/60,0.99,false,false)
	T.expect(p==root,"stale data cannot move the camera indefinitely")
	p=Timing.update(c,1.4,vc(50,2,0),vc(0,0,6),1/60,1.39,false,true)
	T.expect(p==vc(50,2,0) and not c.clock,"teleport cuts without old prediction")
	p=Timing.update(c,1.5,vc(51,2,0),vc(0,0,6),1/60,999,false,false)
	T.expect(p==vc(51,2,0) and not c.clock,"future timestamp falls back safely")
	p=Timing.update(c,1.6,vc(52,2,0),vc(0,0,6),1/60,0/0,false,false)
	T.expect(p==vc(52,2,0) and not c.clock,"invalid timestamp falls back safely")
end

-- An input burst used to restart the sine ease every tick, pinning the view in place.
for _,fps in {30,60,144,240} do
	local old,new=OldGuard.new(),Guard.new();new.stable=true
	old:filter(0,vc(0,1,-3),FWD,UP,65,vc(0,0,0))
	new:filter(0,vc(0,1,-3),FWD,UP,65,vc(0,0,0))
	local a,b,previous,worst
	for i=1,fps*2 do
		local wanted=vc(i%2==0 and 3.8 or 2.2,1,-3)
		a=old:filter(i/fps,wanted,FWD,UP,65,vc(0,0,0))
		b=new:filter(i/fps,wanted,FWD,UP,65,vc(0,0,0))
		if previous then worst=math.max(worst or 0,vector.magnitude(b-previous)) end
		previous=b
	end
	T.expect(a.x<0.01,"reference reproduces recovery restart freeze")
	T.expect(b.x>2.5 and b.x<3.5,"continuous recovery advances through repeated disturbances")
	T.expect(worst<=0.25*60/fps+0.00001,"recovery rate is bounded independently of render FPS")
	if fps==60 then print(string.format("repeated corrections: old progress %.3f m, stable progress %.3f m",a.x,b.x)) end
end

for _,fps in {30,60,144,240} do
	local g=Guard.new();g.stable=true
	for i=1,fps do
		local t=i/fps
		g:filter(t,vc(8*t,1,-3),vc(math.sin(t),0,math.cos(t)),UP,65,vc(0,0,0))
	end
	T.expect(g.total==0,"smooth motion does not falsely trigger at "..fps.." fps")
	local first=g:filter(2,vc(0,1,-3),-FWD,UP,65,vc(0,0,0))
	local p,f,u
	for i=1,fps*3 do p,f,u=g:filter(2+i/fps,vc(0,1,-3),-FWD,UP,65,vc(0,0,0)) end
	T.expect(vector.dot(f,-FWD)>0.999 and math.abs(vector.dot(f,u))<0.001,"180-degree recovery reaches target with a valid basis")
	p=g:filter(6,vc(0,1,-0.5),-FWD,UP,65,vc(0,0,0),true)
	T.expect(T.vnear(p,vc(0,1,-0.5),1e-5),"wall pull bypasses recovery position lag")
end

-- Full glue/camera sampling with coalesced physics delivery, including low render rates.
do
	local Mock,Store,Settings=require("mock_reskate"),require("store"),require("settings")
	local Glue,Before=require("glue"),require("ref_119/glue")
	local function run(module,fps,hz,stable,state,board_wiggle)
		local m=Mock.install({limit_rays=true})
		m.reskate.input.gamepad=function() return nil end
		m.reskate.menu.game=function() return {open=false} end
		local store=Store.new();store:load()
		local s=Settings.defaults();s.shake_enabled=false
		s.ride_distance.mode=Settings.DistanceMode.Speed -- compare timing independently of the revised Fixed chase contract
		assert(store:set_settings(s))
		local options=Settings.copy(store.options);options.stable_timing=stable;store:set_options(options)
		local g=module.new({store=store,camera=require("camera")})
		local result={};local last_index=-1
		for i=1,fps*3 do
			local t=i/fps+0.37/hz
			local index=math.floor(t*hz+1e-8)
			local at=10+index/hz
			m.clock_ms=(10+t)*1000
			local root=vc(0,0.95,6*(at-10))
			m.state.skater.position=root
			m.state.telemetry.physics_state=state
			m.state.board.deck={position=root-vc(0,0.95,0),rotation={0,0,0,1}}
			m.state.raycasts=0
			if index~=last_index then
				for n=last_index+1,index do
					g:on_physics_step({at=(10+n/hz)*1000,seconds=1/hz,velocity={board_wiggle and 10*math.sin(t*40) or 0,0,6},ragdoll=false})
				end
				last_index=index
			end
			g:tick(1000/fps)
			T.expect(m.state.skater.position==root,"stability sampling never writes the skater transform")
			if stable and i>fps then
				T.expect(math.abs(g.snap.position.z-6*t)<0.0001,"glue uses native source timestamp")
				T.expect(T.vnear(g.snap.board_position-g.snap.position,vc(0,-0.95,0),0.00001),"board and body share one sample phase")
			end
			if i>fps then result[#result+1]={p=g.last_shown.pos,f=g.last_shown.forward} end
		end
		return result,g
	end
	for _,fps in {30,59,60,75,144,240} do
		for _,state in {100,403} do
			local current=run(Glue,fps,60,false,state)
			local old,old_glue=run(Before,fps,60,false,state)
			for i,f in current do
				T.expect(T.vnear(f.p,old[i].p,1e-7) and T.vnear(f.f,old[i].f,1e-7),"Stability test Off matches 1.1.9: "..fps.." fps")
			end
			local _,stable_glue=run(Glue,fps,60,true,state)
			T.expect(math.abs(stable_glue.snap.velocity.z-6)<0.001,"event-count velocity stays correct")
			if fps==75 and state==100 then
				print(string.format("75 fps inferred speed old %.3f m/s, counted %.3f m/s (actual 6)",old_glue.snap.velocity.z,stable_glue.snap.velocity.z))
				T.expect(math.abs(old_glue.snap.velocity.z-6)>1,"reference reproduces wrong inferred step count")
			end
		end
	end
	for _,hz in {30,120,144,240} do
		local _,g=run(Glue,240,hz,true,100,true)
		T.expect(math.abs(g.snap.velocity.x)<0.001 and math.abs(g.snap.velocity.z-6)<0.001,"high-rate sampling follows rider, not tricking board: "..hz.." Hz")
	end
end

do
	local Mock,Store=require("mock_reskate"),require("store")
	local m=Mock.install()
	m.reskate.input.gamepad=function() return nil end
	local app=require("app").start({camera=require("camera")})
	m.build_page({tabs=8,o_stability=false})
	T.expect(not app.store.options.stable_timing and m.storage.settings["S3Cam.Options.StableTiming"]==false,"comparison switch saves Off")
	local reload=Store.new();reload:load()
	T.expect(not reload.options.stable_timing,"comparison setting survives reload")
	m.build_page({tabs=8,o_stability=true})
	T.expect(app.store.options.stable_timing,"comparison switch restores the test path")
end

do
	local c=Timing.new()
	local now=10
	for i=1,500 do
		now+=({0.004,0.009,0.016,0.028,0.006,0.05})[(i-1)%6+1]
		local at=10+math.floor((now-10)*60)/60
		local p=Timing.update(c,now,vc(0,0,6*(at-10)),vc(0,0,6),1/60,at,false,false)
		T.expect(math.abs(p.z-6*(now-10))<0.0001,"irregular render frames and coalesced samples retain source phase")
	end
end

-- Position prediction must use velocity at the same physics sample, not velocity
-- that was already advanced to a later render instant (which double-counts gravity).
do
	local Rider=require("rider")
	local c,r=Timing.new(),Rider.new()
	local worst=0
	for i=1,240 do
		local t=i/144+0.37/60
		local n=math.floor(t*60)
		local s=n/60
		local root=vc(0,8+4*s-0.5*10.1*s*s,6*s)
		local v=Rider.update(r,10+t,root,vc(0,4-10.1*s,6),true,1/60,n)
		local p=Timing.update(c,10+t,root,v,1/60,10+s,true,false)
		if i>60 then worst=math.max(worst,math.abs(p.y-(8+4*t-0.5*10.1*t*t))) end
	end
	T.expect(worst<0.0001,"air sample and velocity share one time phase (error "..worst..")")
end

T.done()
if T.failures>0 then error("stability tests failed") end
