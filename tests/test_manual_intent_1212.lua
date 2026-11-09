local T,M=require("tlib"),require("manual")
T.group("manual intent 1212")
local blank={manual=false,in_trick=true,trick="",detail="ID_SCORING_TIER_2"}
local function tick(m,t,pitch,pad,state,score,speed)
 state=state or 100
 return m:update(t,state,state~=504,state==201,state==403,pitch,speed or 3,score or blank,pad)
end
for _,fps in {30,60,144} do
 for _,pitch in {12,-12} do
  local m=M.new();local pad={right_x=0,right_y=pitch>0 and -0.5 or 0.5};local first
  for i=1,fps do if tick(m,i/fps,pitch,pad) and not first then first=i/fps end end
  T.expect(first and first<=0.20+1e-6 and m.count==1,"unlabelled-HUD manual/nose manual activates from input plus pose")
  T.expect(tick(m,1.01,pitch,nil),"one unavailable input sample has bounded grace")
  T.expect(not tick(m,1.12,pitch,nil),"released/unavailable input ends corroborated close-up")
  for i=1,fps do T.expect(not tick(m,1.2+i/fps,pitch,nil),"pose cannot resurrect a released manual") end
 end
 for _,case in {{pad=nil,pitch=12},{pad={right_x=0,right_y=0},pitch=12},
  {pad={right_x=0,right_y=1},pitch=12},{pad={right_x=0.8,right_y=0.5},pitch=12},
  {pad={right_x=0,right_y=0.5},pitch=0},{pad={right_x=0,right_y=0.5},pitch=40},
  {pad={right_x=0,right_y=0.5},pitch=12,state=101},{pad={right_x=0,right_y=0.5},pitch=12,state=103},
  {pad={right_x=0,right_y=0.5},pitch=12,state=201},{pad={right_x=0,right_y=0.5},pitch=12,state=403},
  {pad={right_x=0,right_y=0.5},pitch=12,state=504}} do
  local m=M.new()
  for i=1,fps do T.expect(not tick(m,i/fps,case.pitch,case.pad,case.state),"drift/full flick/level/crouch/revert/air/grind/offboard cannot trigger fallback") end
 end
 local m=M.new();local pad={right_x=0,right_y=0.5}
 for i=1,fps do T.expect(not tick(m,i/fps,i%2==0 and -12 or 12,pad),"unstable landing tilt cannot acquire input manual") end
 local veto=M.new()
 for i=1,fps do T.expect(not tick(veto,i/fps,12,pad,100,{manual=false,in_trick=true,trick="Powerslide"}),"current named non-manual vetoes input fallback") end
 local fresh=M.new();tick(fresh,0,12,nil)
 fresh:on_notes({{entry=42,kind="n",text="Nose Manual"}},0.1)
 T.expect(tick(fresh,0.11,-12,nil),"fresh trick note wins over blank name-derived false")
 local h=M.new();T.expect(tick(h,0,0,nil,100,{manual=false,in_trick=true,detail="Nose Manual"}),"current manual descriptor works during boolean publication mismatch")
end
-- Actual App/Glue path, false HUD throughout, no trick notes.
local Mock,S=require("mock_reskate"),require("settings")
local v=vector.create
for _,pitch in {12,-12} do
 local h=Mock.install({limit_rays=true});local pad={right_x=0,right_y=pitch>0 and -0.5 or 0.5}
 h.reskate.input.gamepad=function()return pad end;h.reskate.menu.game=function()return {open=false} end
 h.reskate.score={current=function()return blank end}
 local app=require("app").start();local s=S.defaults();s.framing.manual_camera=true;s.framing.manual_distance=0.9;s.shake_enabled=false;app.store:set_settings(s)
 local active=false
 for i=1,180 do
  local t=i/60;local tilt=t>1 and t<2.3 and math.rad(pitch) or 0
  h.state.skater.position=v(0,0.95,3*t);h.state.telemetry.physics_state=100
  h.state.board.deck={position=v(0,0,3*t),rotation={math.sin(tilt/2),0,0,math.cos(tilt/2)}}
  h.fire("physics_step",{at=h.clock_ms,seconds=1/60,velocity={0,0,3},ragdoll=false});h.tick(1000/60)
  if t>1.7 and t<2.2 then
   active=true;T.expect(app.glue.snap.manual and string.find(app.glue.frame.debug.shot_name,"manual",1,true)~=nil,"manual/nose-manual shot actually selected")
   T.expect(app.glue.frame.debug.distance<1.1,"actual close-up uses configured manual distance")
  end
 end
 T.expect(active and app.manual.count==1 and not app.glue.snap.manual and app.errors==0,"one real corroborated manual, released cleanly")
end
T.done()
if T.failures>0 then error("manual intent regression") end
