local T=require("tlib")
local Mock,Settings,Store=require("mock_reskate"),require("settings"),require("store")
local vc=vector.create
T.group("frame_clock")
local function run(module,jitter)
	local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end
	m.reskate.menu.game=function() return {open=false} end
	local st=Store.new();st:load();local s=Settings.defaults();s.shake_enabled=false
	s.ride_distance.mode,s.ride_distance.fixed=Settings.DistanceMode.Fixed,2
	s.ride_distance_high.mode,s.ride_distance_high.fixed=Settings.DistanceMode.Fixed,4
	assert(st:set_settings(s))
	local g=module.new({store=st,camera=require("camera")});g.snap_guard_on=false
	local frames={}
	for i=1,144*5 do
		local t=i/144
		m.clock_ms=1000+t*1000+(jitter and (i%3-1)*2 or 0);m.state.raycasts=0
		m.state.skater.position=vc(0,0.95,0);m.state.board.velocity=vc(0,0,0)
		m.state.board.deck={position=vc(0,0,0),rotation={0,0,0,1}}
		if i==144 then g.cam:cut() end
		if i==288 or i==432 then st:toggle_height() end
		g:on_physics_step({at=m.clock_ms,seconds=1/60,velocity={0,0,0},ragdoll=false})
		g:tick(1000/144)
		if i>=288 then frames[i]=m.last_call("set").position end
	end
	return frames
end
local function error_of(module)
	local normal,noisy=run(module,false),run(module,true)
	local worst=0
	for i,p in normal do worst=math.max(worst,vector.magnitude(p-noisy[i])) end
	return worst
end
local old,new=error_of(require("ref_1114/glue")),error_of(require("glue"))
print(string.format("144 FPS / +/-2 ms handler dispatch: previous %.3f mm, frame clock %.3f mm",old*1000,new*1000))
T.expect(old>0.003 and new<0.0001,"host frame dt removes dispatch-clock jitter from camera easing")
T.done()
if T.failures>0 then error("frame clock tests failed") end
