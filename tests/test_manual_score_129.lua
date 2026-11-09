local T,M=require("tlib"),require("manual")
T.group("manual score 129")
local function tick(m,t,score,pitch,state)
 state=state or 100
 return m:update(t,state,state~=504,state==201,state==403,pitch,3,score)
end
for _,fps in {30,60,144} do
 for _,pitch in {8.9,-16.3,-13.3,10.9,-26} do
  for _,hud in {"missing","false","malformed"} do
   local m=M.new();local score
   if hud=="false" then score={manual=false,in_trick=true} elseif hud=="malformed" then score={manual="true",in_trick=true} end
   tick(m,0,score,0,201)
   for i=1,3*fps do T.expect(not tick(m,i/fps,score,pitch),"recorded tilt/landing shapes cannot start a manual") end
   T.expect(m.count==0,"ambiguous pose never increments manual count")
  end
 end
 local m=M.new();local yes={manual=true,in_trick=true}
 T.expect(tick(m,0,yes,0),"current manual starts immediately even with level deck")
 for i=1,fps do T.expect(tick(m,i/fps,yes,0),"current manual is not cancelled by level animation") end
 T.expect(m.count==1,"one continuous current manual")
 T.expect(not tick(m,1.01,{manual=true,in_trick=false},12),"retained label outside current trick ends manual")
 T.expect(not tick(m,1.02,nil,12),"lost HUD cannot resurrect a manual from pose")
 for _,state in {201,403,504} do
  local blocked=M.new();T.expect(not tick(blocked,0,yes,12,state),"physical air/grind/offboard vetoes current HUD manual")
 end
 local hidden=M.new();tick(hidden,0,nil,12)
 hidden:on_notes({{kind="n",entry=1,text="Nose Manual"}},0.1)
 T.expect(tick(hidden,0.11,nil,-12),"named nose manual works with missing HUD")
 T.expect(tick(hidden,0.12,{manual=false,in_trick=true,trick="",detail="ID_SCORING_TIER_2"},-12),"unlabelled HUD cannot veto a fresh named manual")
 T.expect(not tick(hidden,0.13,{manual=false,in_trick=true,trick="Revert"},-12),"current named non-manual ends fallback")
 local lost=M.new();tick(lost,0,yes,12)
 T.expect(tick(lost,0.01,nil,12) and tick(lost,0.1,nil,12),"single HUD dropout has bounded grace")
 T.expect(tick(lost,0.11,yes,12),"current state recovers from dropout")
 T.expect(tick(lost,0.2,nil,12),"new dropout starts fresh grace")
 T.expect(not tick(lost,0.71,nil,12),"persistent missing HUD cannot strand score-owned close-up")
end
-- Real Glue reads the API once per sample and guards unsupported/erroring hosts.
local Mock=require("mock_reskate")
for _,mode in {"true","false","nil","error","absent","malformed"} do
 local h=Mock.install({limit_rays=true});local calls=0
 h.reskate.input.gamepad=function()return nil end;h.reskate.menu.game=function()return {open=false} end
 if mode~="absent" then h.reskate.score={current=function()
  calls+=1
  if mode=="error" then error("unavailable") end
  if mode=="nil" then return nil end
  if mode=="malformed" then return true end
  return {manual=mode=="true",in_trick=true}
 end} end
 local app=require("app").start()
 for i=1,120 do
  local t=i/60
  h.state.skater.position=vector.create(0,0.95,3*t)
  h.state.telemetry.physics_state=100
  h.state.board.deck={position=vector.create(0,0,3*t),rotation={math.sin(math.rad(6)),0,0,math.cos(math.rad(6))}}
  h.fire("physics_step",{at=h.clock_ms,seconds=1/60,velocity={0,0,3},ragdoll=false});h.tick(1000/60)
 end
 T.expect(app.glue.snap.manual==(mode=="true"),"Glue respects score tri-state: "..mode)
 T.expect(app.errors==0,"optional score API cannot fault callback: "..mode)
 T.expect(mode=="absent" or calls>0,"optional API actually observed")
end
T.done()
if T.failures>0 then error("manual score regression") end
