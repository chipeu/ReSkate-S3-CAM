-- Current strict goldens only where the old ordered ray transcript is valid.
-- Actual shipped 128 is separately checked against the full original policy.
local replay,Camera,Settings=require("replay"),require("camera"),require("settings")
local full,prefix,excluded,checked,revised=0,0,0,0,0
for _,name in require("trace_index") do
 if name=="trace_mixed_fixed_low" or name=="trace_mixed_fixed_high_144" then
  print("FIXED/FOV revision",name)
 elseif name=="trace_carve_horizontal10" or name=="trace_carve_horizontal10_144" or name=="trace_carve_h5_follow4" then
  revised+=1
  print("REVISED direct cruising yaw 10; old oracle retained in shipped128 parity, current geometry/control tested in test_turn_follow_134",name)
 elseif name=="trace_downhill" then
  revised+=1
  print("REVISED 1.2.22 hill framing: the slope look no longer stacks on the clearance lift; test_hill_framing_1222 owns it",name)
 else
  local trace=replay.load(name)
  local set=replay.build_settings(trace,{})
  local boundary
  if set.collision.enabled and set.shoulder.mode~=Settings.ShoulderSide.Off and set.shoulder.offset>0.02 then
   boundary=trace.frames[1].index
  elseif set.collision.enabled and set.trick_yaw.enabled then
   for _,frame in trace.frames do
    local s=frame.snapshot
    local state=s.physics_state
    if ((state==200 or state==201) and set.trick_yaw.in_air)
     or (state>=400 and state<500 and set.trick_yaw.on_grinds)
     or (s.manual and set.trick_yaw.on_manuals) then boundary=frame.index;break end
   end
  end
  -- Pop On ramp safety now owns the finished collision pose. Ordered rays
  -- recorded before that owner existed are valid only before ramp entry.
  if set.follow.trick_pop then
   for _,frame in trace.frames do
    local s=frame.snapshot;local state=s.physics_state
    local speed=vector.magnitude(s.velocity)
    if state~=200 and state~=201 and s.ground_normal.y<math.cos(math.rad(40))
     and (speed<1 or math.abs(s.velocity.y)>=0.5*speed) then
     if not boundary or frame.index<boundary then boundary=frame.index;print("COMMON RAMP revision prefix",name,boundary) end
     break
    end
   end
  end
  if boundary==trace.frames[1].index then
   excluded+=1;print("ADAPTIVE from first frame; solid-geometry suite owns coverage",name)
  else
   local result=replay.run(name,Camera,{strict_debug=true,quiet=true,stop_before_frame=boundary})
   assert(result.pass,name..": "..(result.first_fail and result.first_fail.message or "strict prefix failed"))
   assert((result.checked_frames or 0)>0,"empty prefix")
   checked+=result.checked_frames
   if boundary then prefix+=1 else full+=1 end
   print("STRICT current",name,boundary and "prefix" or "full",result.checked_frames)
  end
 end
end
print("current golden coverage",full,"full",prefix,"strict prefixes",excluded,"adaptive from start",revised,"intentional cruising yaw revisions",checked,"checked frames")
assert(full>=12 and prefix>=11 and revised==4,"unexpected coverage reduction beyond three cruising yaw revisions and the 1.2.22 hill revision")
