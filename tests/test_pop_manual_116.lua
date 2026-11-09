local T=require("tlib")
local Camera,Settings,Subject=require("camera"),require("settings"),require("subject")
local vc=vector.create
T.group("pop_manual_116")
local function plane(a,b)
	if a.y>=0 and b.y<=0 and a.y~=b.y then return a+(b-a)*(a.y/(a.y-b.y)),vc(0,1,0) end
end
-- The pullback/frustum assertions from 1.1.16 are superseded by the
-- user-approved level chase contract in test_level_pop_117.lua.

do
	local Mock=require("mock_reskate");local m=Mock.install({limit_rays=true})
	m.reskate.input.gamepad=function() return nil end;m.reskate.menu.game=function() return {open=false} end
	local app=require("app").start({camera=Camera});local s=Settings.defaults();s.shake_enabled=false
	s.framing.manual_camera=true;s.framing.manual_distance=0.9;app.store:set_settings(s)
	local found=false
	m.reskate.score={current=function() return {manual=m.clock_ms>2000 and m.clock_ms<4000,in_trick=true} end}
	for i=1,300 do
		local t=i/60;local tilt=t>1 and t<3 and math.rad(12) or 0
		local root=vc(0,0.95,t*3)
		m.state.skater.position=root;m.state.telemetry.physics_state=100
		m.state.board.deck={position=vc(0,0,t*3),rotation={math.sin(tilt/2),0,0,math.cos(tilt/2)}}
		m.fire("physics_step",{at=m.clock_ms,seconds=1/60,velocity={0,0,3},ragdoll=false});m.tick(1000/60)
		if t>1.7 and t<2.8 then
			local d=app.glue.frame.debug
			T.expect(app.glue.snap.manual and string.find(d.shot_name,"manual",1,true)~=nil,"current score manual activates the actual manual camera with no trick notes")
			T.expect(d.distance<1.1,"manual close-up uses its configured distance")
			found=true
		end
	end
	T.expect(found and app.manual.count==1 and not app.glue.snap.manual,"one score manual detected and cleared when the current score ends")
	T.expect(app.errors==0,"score manual introduces no callback errors")
end

do
	local Manual=require("manual")
	for _,state in {103,201,403,504} do
		local m=Manual.new()
		for i=1,120 do T.expect(not m:update(i/60,state,state~=504,state==201,state==403,12,3),"crouches, air, grinds and offboard cannot trigger tilt manuals") end
	end
	local m=Manual.new()
	for i=1,120 do T.expect(not m:update(i/60,100,true,false,false,i%30<5 and 12 or 0,3),"brief push/landing rocking cannot trigger manuals") end
	m:on_notes({{kind="n",entry="revert",text="Revert"}},2)
	for i=1,24 do T.expect(not m:update(2+i/60,101,true,false,false,12,3),"named reverts suppress pose fallback") end
end
T.done()
if T.failures>0 then error("grounded pop/manual tests failed") end
