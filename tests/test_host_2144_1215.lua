local T,Mock=require("tlib"),require("mock_reskate")
local S=require("settings")
T.group("host 2144 compatibility 1215")
local function step(m,fps)
 m.state.skater.position+=vector.create(0,0,6/fps)
 m.fire("physics_step",{at=m.clock_ms,seconds=1/fps,velocity={0,0,6},ragdoll=false})
 m.tick(1000/fps)
end
local function clear()return {known=true,pause=false,reskate=false,replay_editor=false} end
for _,fps in {30,60,144} do
 for _,field in {"pause","reskate","replay_editor","unknown"} do
  local m=Mock.install({limit_rays=true,menu_state=true})
  m.reskate.menu.game=function()return {known=true,open=false} end
  local pad={buttons={}};m.reskate.input.gamepad=function()return pad end
  local state=clear();if field=="unknown" then state.known=false else state[field]=true end
  m.state.menu_state=state
  local app=require("app").start();local g=app.glue
  for i=1,2*fps do step(m,fps) end
  T.expect(not g.running and m.camera_held_by~="me","startup reads already-open host UI without waiting for an event: "..field)
  T.expect(not app.ui.open,"compatibility never automatically opens custom menu")
  m.state.menu_state=clear();m.fire("menu_changed",clear(),state)
  for i=1,2*fps do step(m,fps) end
  T.expect(g.running and m.camera_held_by=="me","camera resumes after host menu closes")
  local before=m.menu_state_reads;step(m,fps)
  T.expect(m.menu_state_reads-before==1,"one host state sample per steady camera tick")
  m.state.menu_state=state;m.fire("menu_changed",state,clear())
  T.expect(not g.running and m.camera_held_by~="me","menu event releases before the next camera tick")
  local angle,side=app.store.settings.angle,app.store.settings.shoulder.side
  pad.buttons={right_stick=true,left_stick=true}
  for i=1,fps do step(m,fps) end
  g:press_r3("action");g:swap_shoulder("action")
  T.expect(app.store.settings.angle==angle and app.store.settings.shoulder.side==side,"host UI pad/actions cannot change camera settings")
  T.expect(g.manual_pad==nil,"menu pad cannot acquire a manual close-up")
  m.state.menu_state=clear();m.fire("menu_changed",clear(),state)
  for i=1,2*fps do step(m,fps) end
  T.expect(app.store.settings.angle==angle and app.store.settings.shoulder.side==side,"held menu stick clicks cannot fire when menu closes")
  T.expect(g.running and app.errors==0 and g.rays_tick<=64,"camera reacquires with existing safety budget")
  T.expect(app.ui:show("menu"),"explicit custom screen remains available")
  step(m,fps)
  T.expect(g.running,"plugin custom screen keeps its live camera preview")
  app.ui:close()
 end
end
-- Legacy hosts still expose only menu.game. Modern failures remain unknown,
-- instead of falling through to a misleading closed pause-only snapshot.
for _,mode in {"legacy","modern_error","modern_nil"} do
 local m=Mock.install({limit_rays=true,menu_state=mode~="legacy"})
 local open=mode=="legacy";m.reskate.menu.game=function()return {known=true,open=open} end
 m.reskate.input.gamepad=function()return nil end
 if mode=="modern_error" then m.reskate.menu.state=function()error("not ready")end
 elseif mode=="modern_nil" then m.reskate.menu.state=function()return nil end end
 local app=require("app").start()
 for i=1,120 do step(m,60) end
 T.expect(not app.glue.running and app.errors==0,"unknown modern or open legacy menu cannot take camera")
 if mode=="legacy" then
  open=false;for i=1,120 do step(m,60) end
  T.expect(app.glue.running,"legacy fallback camera resumes")
 end
end
-- 2.1.4-3 restores named trick notes. String entry ids and side/spin notes
-- must keep the already working named-manual path, including nose manuals.
for _,name in {"Manual","Nose Manual"} do
 local m=Mock.install({limit_rays=true,menu_state=true})
 m.reskate.menu.game=function()return {known=true,open=false} end
 m.reskate.input.gamepad=function()return nil end
 m.reskate.score={current=function()return {manual=false,in_trick=false,trick="",detail=""} end}
 local app=require("app").start();local s=S.defaults();s.framing.manual_camera=true;s.framing.manual_distance=0.9;app.store:set_settings(s)
 for i=1,120 do step(m,60) end
 m.fire("trick_notes",{notes={{entry="8589934593",kind="n",text=name},{entry="8589934593",kind="s",text="ID_TRICK_FS"},{entry="8589934593",kind="b",text="180"}}})
 for i=1,36 do step(m,60) end
 T.expect(app.glue.snap.manual and string.find(app.glue.frame.debug.shot_name,"manual",1,true)~=nil,"restored named manual reaches actual camera graph")
 T.expect(app.glue.frame.debug.distance<1.1 and app.manual.count==1,"restored note preserves configured manual close-up")
 m.fire("trick_notes",{notes={{entry="8589934593",kind="l",text="ID_TRICK_LANDING_CLEAN"}}})
 for i=1,40 do step(m,60) end
 T.expect(not app.glue.snap.manual and app.errors==0,"named manual landing ends cleanly")
end
T.done()
if T.failures>0 then error("host 2144 compatibility regression") end
