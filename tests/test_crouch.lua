-- Tests of the body-follow feature against the packaged 1.1.3 camera and independent terrain motion.
local T = require("tlib")
local Crouch = require("crouch")
local Camera = require("camera")
local Before = require("ref_113/camera")
local Subject = require("subject")
local Settings = require("settings")
local Presets = require("presets")
local vc = vector.create
T.group("crouch")

local function snapshot(t, drop, state, slope)
	local ground = slope * t * 6
	local s = Subject.new_snapshot()
	s.valid, s.onboard, s.ground_valid = true, true, true
	s.time, s.physics_state = t, state or 100
	s.position, s.board_position = vc(0, ground + 0.95 - drop, t * 6), vc(0, ground, t * 6)
	s.board_valid, s.ground_height, s.ground_clearance = true, ground, 0.95 - drop
	s.ground_normal = vector.normalize(vc(0, 1, -slope))
	s.velocity = vc(0, slope * 6, 6)
	return s
end

local function settings(amount, enabled)
	local s = Presets.builtin_values(1)
	s.follow.crouch_amount, s.follow.crouch_enabled = amount, enabled ~= false
	s.shake_enabled = false
	s.fov.speed_fov = false -- isolate crouch behavior from the revised Fixed chase FOV rule
	s.angle = Settings.CameraAngle.High -- keep the amplitude tests away from the Low camera's floor clamp
	return s
end

local function plane(slope)
	return function(a, b)
		local da, db = a.y - slope * a.z, b.y - slope * b.z
		if da >= 0 and db <= 0 and da ~= db then
			return a + (b-a) * (da/(da-db)), vector.normalize(vc(0, 1, -slope))
		end
		return nil
	end
end

local function profile(t)
	if t <= 1 then return 0, 100 end
	if t < 1.25 then return 0.3 * (t-1)/0.25, 103 end
	if t < 2 then return 0.3, 103 end
	if t < 2.25 then return 0.3 * (1-(t-2)/0.25), 100 end
	return 0, 100
end

-- Pure framing controller: strength is amplitude, including a held crouch and moving terrain.
for _, slope in {0, 0.2, -0.2} do
	local off, half, full = Crouch.new(), Crouch.new(), Crouch.new()
	local fo0, fo50, fo100 = settings(0).follow, settings(0.5).follow, settings(1).follow
	for i=1,180 do
		local t=i/60
		local drop, state=profile(t)
		local s=snapshot(t,drop,state,slope)
		Crouch.update(off,1/60,s,fo0,i==1)
		Crouch.update(half,1/60,s,fo50,i==1)
		Crouch.update(full,1/60,s,fo100,i==1)
		if i==115 then
			T.expect_near(off.offset,0.3,0.001,"Off compensates held body lowering on slope "..slope)
			T.expect_near(half.offset,0.15,0.001,"50 percent follows half the lowering")
			T.expect(full.offset==0,"100 percent has no compensation")
		end
	end
	T.expect(off.offset<0.0001,"cancellation releases compensation")
end

do
	local c=Crouch.new()
	local fo=settings(0).follow
	for i=1,90 do Crouch.update(c,1/60,snapshot(i/60,i>30 and 0.3 or 0,i>30 and 103 or 100,0),fo,i==1) end
	local held=c.offset
	T.expect(held>0.29,"fixture has compensation")
	local s=snapshot(2,0.3,103,0)
	s.ground_valid=false
	Crouch.update(c,1/60,s,fo,false)
	T.expect_near(c.offset,held,1e-6,"one missing grounded ray retains crouch compensation")
	Crouch.update(c,1/60,snapshot(2+1/60,0.3,103,0),fo,false)
	T.expect_near(c.offset,held,1e-6,"ground return after one missed ray has no compensation pulse")
	for i=1,90 do Crouch.update(c,1/60,s,fo,false) end
	T.expect(c.offset==0 and math.abs(c.baseline-0.95)<1e-5,"missing ground fades out but retains neutral body height")
	Crouch.update(c,1/60,snapshot(3.5,0.3,100,0),fo,false)
	T.expect_near(c.offset,0.3,0.0001,"returning ground cannot learn a compressed landing as neutral")
	Crouch.update(c,1/60,snapshot(3.6,-0.1,100,0),fo,false)
	T.expect_near(c.offset,-0.1,0.0001,"body rebound receives signed correction")
	s=snapshot(3.7,-0.1,200,0)
	Crouch.update(c,1/60,s,fo,false)
	T.expect(c.offset<0 and c.offset>-0.1,"negative correction fades on takeoff rather than snapping to zero")
	Crouch.update(c,1/60,snapshot(4,0,100,0),fo,true)
	T.expect(c.offset==0,"cut clears the prior compensation")
	for _, state in {200,201,400,701,504} do
		Crouch.reset(c)
		for i=1,60 do Crouch.update(c,1/60,snapshot(i/60,0.3,state,0),fo,i==1) end
		T.expect(c.offset==0,"no compensation invented in state "..state)
	end
	Crouch.reset(c)
	for i=1,60 do Crouch.update(c,1/60,snapshot(i/60,0.3,103,0),fo,i==1) end
	T.expect(c.offset==0,"start already crouched does not guess an upright height")
end

local samples={}
for _, fps in {30,60,144} do
	local cameras, configs = {}, {}
	for i, amount in {0,0.5,1} do
		configs[i]=settings(amount)
		cameras[i]=Camera.new()
		assert(cameras[i]:set_settings(configs[i]))
	end
	local old=Before.new(); assert(old:set_settings(configs[3]))
	local query=plane(0)
	local heights={}
	local previous
	local worst=0
	for i=1,fps*3 do
		local t=i/fps
		local drop,state=profile(t)
		local s=snapshot(t,drop,state,0)
		local raw_position, raw_velocity, raw_clearance = s.position, s.velocity, s.ground_clearance
		local frames={}
		for j=1,3 do frames[j]=cameras[j]:update(1/fps,s,query,{base_fov_deg=65}) end
		local before=old:update(1/fps,s,query,{base_fov_deg=65})
		T.expect(T.vnear(frames[3].pos,before.pos,1e-7) and T.vnear(frames[3].back,before.back,1e-7)
			and frames[3].fov_deg==before.fov_deg,"100 percent is unchanged at "..fps.." fps, frame "..i)
		T.expect(s.position==raw_position and s.velocity==raw_velocity and s.ground_clearance==raw_clearance
			and s.ground_height==0,"raw snapshot is not modified")
		if previous then worst=math.max(worst,math.abs(frames[1].pos.y-previous)) end
		previous=frames[1].pos.y
		if i==fps then for j=1,3 do heights[j]=frames[j].pos.y end end
		if i==fps*1.5 then
			local dip0=heights[1]-frames[1].pos.y
			local dip50=heights[2]-frames[2].pos.y
			local dip100=heights[3]-frames[3].pos.y
			print(string.format("crouch %d fps: dip 0%% %.4f m; 50%% %.4f m; 100%% %.4f m",fps,dip0,dip50,dip100))
			T.expect(math.abs(dip0)<0.035,"Off holds level during setup")
			T.expect(math.abs(dip50-dip100*0.5)<0.035,"50 percent gives half the camera dip away from collision")
			T.expect(dip100>0.2,"100 percent keeps the existing crouch dip")
			samples[fps]=frames[1].pos.y
		end
	end
	T.expect(worst<0.075,"setup/cancel has no large one-frame vertical snap at "..fps.." fps ("..worst..")")
end
T.expect(math.abs(samples[30]-samples[60])<0.015 and math.abs(samples[144]-samples[60])<0.015,"similar held framing at 30/60/144 fps")

-- Follow the surface on hills: Off matches an upright rider travelling over the same slope.
for _, slope in {0.2,-0.2} do
	local crouched, upright = Camera.new(), Camera.new()
	assert(crouched:set_settings(settings(0)))
	assert(upright:set_settings(settings(1)))
	local query=plane(slope)
	local a,b
	for i=1,115 do
		local t=i/60
		local drop,state=profile(t)
		a=crouched:update(1/60,snapshot(t,drop,state,slope),query,{base_fov_deg=65})
		b=upright:update(1/60,snapshot(t,0,100,slope),query,{base_fov_deg=65})
	end
	T.expect(math.abs(a.pos.y-b.pos.y)<0.035,"Off follows hill height instead of locking world Y (slope "..slope..")")
end

-- During a held crouch, disabling follow equals zero amount. Live changes ease rather than snap.
do
	local a,b=Crouch.new(),Crouch.new()
	local off=settings(0).follow
	local disabled=settings(0.75,false).follow
	for i=1,115 do
		local t=i/60
		local drop,state=profile(t)
		local s=snapshot(t,drop,state,0)
		Crouch.update(a,1/60,s,off,i==1)
		Crouch.update(b,1/60,s,disabled,i==1)
	end
	T.expect_near(a.offset,b.offset,1e-9,"toggle Off ignores slider and retains its remembered amount")
	local was=a.offset
	local full=settings(1).follow
	Crouch.update(a,1/60,snapshot(2,0.3,103,0),full,false)
	T.expect(a.offset>0 and was-a.offset<0.06,"live change to 100 percent eases")
	for i=1,120 do Crouch.update(a,1/60,snapshot(2+i/60,0.3,103,0),full,false) end
	T.expect(a.offset==0,"100 percent settles back to the unmodified path")
end

-- The Low camera's ground clamp and an obstructing wall still run after crouch framing.
do
	for _, angle in {Settings.CameraAngle.Low,Settings.CameraAngle.High} do
		local free,wall=Camera.new(),Camera.new()
		local cfg=settings(0); cfg.angle=angle
		cfg.follow.strength=0.3 -- keep a loose tracker from reintroducing body lag
		assert(free:set_settings(cfg)); assert(wall:set_settings(cfg))
		local ground=plane(0)
		local function blocked(a,b)
			local hit,normal=ground(a,b)
			if a.z>=-1.4 and b.z<=-1.4 and a.z~=b.z then
				local t=(-1.4-a.z)/(b.z-a.z)
				local point=a+(b-a)*t
				if not hit or vector.magnitude(point-a)<vector.magnitude(hit-a) then return point,vc(0,0,1) end
			end
			return hit,normal
		end
		local initial,final
		for i=1,120 do
			local t=i/60
			local drop,state=profile(t)
			local s=snapshot(t,drop,state,0)
			s.position=vc(0,s.position.y,0); s.board_position=vc(0,0,0); s.velocity=vc(0,0,0)
			local a=free:update(1/60,s,ground,{base_fov_deg=65})
			local b=wall:update(1/60,s,blocked,{base_fov_deg=65})
			T.expect(b.pos.z>=-1.45 and b.pos.y>=0.29,"wall/floor protection retained at angle "..angle..", frame "..i)
			if i==60 then initial=a.pos.y end
			if i==115 then final=a.pos.y end
		end
		T.expect(math.abs(initial-final)<0.035,"Off stays level with a loose tracker, angle "..angle)
	end
end

-- A real pop/landing retains raw prediction, fall strength and shake inputs; only setup framing differs.
do
	local a,b=Camera.new(),Camera.new()
	local ca,cb=settings(0),settings(1)
	ca.shake_enabled=true; cb.shake_enabled=true
	assert(a:set_settings(ca)); assert(b:set_settings(cb))
	local query=plane(0)
	local largest_step=0
	local prev_lift=0
	local seen_air=false
	local fa,fb
	for i=1,300 do
		local t=i/60
		local drop,state=profile(t)
		local s=snapshot(t,drop,state,0)
		if t>=2 and t<3 then
			local elapsed=t-2
			s.physics_state=elapsed<0.05 and 200 or 201
			s.position=vc(0,0.65+5*elapsed-0.5*10.1*elapsed*elapsed,t*6)
			s.ground_clearance=s.position.y
			s.velocity=vc(0,5-10.1*elapsed,6)
			seen_air=true
		elseif t>=3 then
			s=snapshot(t,0,100,0)
		end
		fa=a:update(1/60,s,query,{base_fov_deg=65})
		fb=b:update(1/60,s,query,{base_fov_deg=65})
		local da,db=fa.debug,fb.debug
		T.expect(da.landing_fall==db.landing_fall and da.landing_fraction==db.landing_fraction
			and da.impulse==db.impulse and da.air_reference_height==db.air_reference_height,"physics and landing inputs retained frame "..i)
		largest_step=math.max(largest_step,math.abs(da.crouch_compensation-prev_lift))
		prev_lift=da.crouch_compensation
	end
	T.expect(seen_air and largest_step<0.06,"takeoff releases the compensation without a one-frame drop")
	T.expect(fa.debug.crouch_compensation==0 and T.vnear(fa.pos,fb.pos,0.005),"after the release tail, ordinary landing framing returns")
end

-- New settings do not alter any non-setup camera path when no compensation is active.
do
	local a,b=Camera.new(),Camera.new()
	assert(a:set_settings(settings(0))); assert(b:set_settings(settings(1)))
	for i=1,180 do
		local state=i<60 and 100 or i<120 and 400 or 100
		local s=snapshot(i/60,0,state,0)
		s.manual=i>=120
		local fa=a:update(1/60,s,plane(0),{base_fov_deg=65})
		local fb=b:update(1/60,s,plane(0),{base_fov_deg=65})
		T.expect(T.vnear(fa.pos,fb.pos,1e-7) and T.vnear(fa.back,fb.back,1e-7),"normal/grind/manual unchanged frame "..i)
	end
end

-- Body animation can begin in ordinary ride state, before the very brief 103/pop state.
for _, fps in {30,60,144} do
	local cam=Camera.new(); assert(cam:set_settings(settings(0)))
	local level=Camera.new(); assert(level:set_settings(settings(0)))
	local full=Camera.new(); assert(full:set_settings(settings(1)))
	local original=Before.new(); assert(original:set_settings(settings(1)))
	local query=plane(0)
	local reference, lowest, highest
	for i=1,fps*3 do
		local t=i/fps
		local drop=t<=1 and 0 or t<1.25 and 0.3*(t-1)/0.25 or t<2 and 0.3
			or t<2.25 and 0.3-0.4*(t-2)/0.25 or -0.1
		local f=cam:update(1/fps,snapshot(t,drop,100,0),query,{base_fov_deg=65})
		local stable=level:update(1/fps,snapshot(t,0,100,0),query,{base_fov_deg=65})
		local f100=full:update(1/fps,snapshot(t,drop,100,0),query,{base_fov_deg=65})
		local before=original:update(1/fps,snapshot(t,drop,100,0),query,{base_fov_deg=65})
		T.expect(T.vnear(f100.pos,before.pos,1e-7) and T.vnear(f100.back,before.back,1e-7),"100 percent unchanged through ride-state lowering and rebound")
		T.expect(T.vnear(f.pos,stable.pos,0.003) and T.vnear(f.back,stable.back,0.003),"Off holds both position and aim during ride-state body motion")
		if i==fps then reference=f.pos.y end
		if t>=1.5 then
			lowest=math.min(lowest or f.pos.y,f.pos.y)
			highest=math.max(highest or f.pos.y,f.pos.y)
		end
	end
	T.expect(math.abs(lowest-reference)<0.035 and math.abs(highest-reference)<0.035,
		"Off removes body lowering AND rise even without state 103 at "..fps.." fps (range "..lowest.." to "..highest..")")
end

-- Presets and old settings retain the existing feel; slider/toggle round-trip independently.
do
	local old=Presets.from_values({["S3Cam.Follow.Strength"]=2.5})
	T.expect(old.follow.crouch_enabled and old.follow.crouch_amount==1,"old presets default to current behavior")
	T.expect(old.follow.strength==2.5,"old saved fields remain intact")
	local cfg, opts=Presets.builtin_values(1)
	cfg.follow.crouch_enabled=false; cfg.follow.crouch_amount=0.37
	local restored, _, report=Presets.from_values(Presets.collect_values(cfg,opts))
	T.expect(report.refused==0 and not restored.follow.crouch_enabled and restored.follow.crouch_amount==0.37,"toggle and amount persist")
	local invalid=Settings.copy(cfg)
	invalid.follow.crouch_amount=1.01
	T.expect(not Settings.valid(invalid),"out-of-range follow amount rejected")
end

T.done()
if T.failures>0 then error("crouch tests failed") end
