local T,C,U=require("tlib"),require("crouch"),require("subject")
local v=vector.create
T.group("crouch depth 122")
for _,degrees in {0,15,30,45,60,75,85} do
 local c=C.new();c.terrain_support=true;local s=U.new_snapshot()
 s.onboard=true;s.board_valid=true;s.ground_valid=true;s.physics_state=100;s.board_position=v(0,0,0);s.ground_height=0
 s.position=v(0,0.95,0);s.ground_normal=v(0,1,0)
 local f={crouch_enabled=true,crouch_amount=1,crouch_mode=0};C.update(c,1/60,s,f,false)
 local a=math.rad(degrees);local axis=v(0,math.cos(a),math.sin(a))
 s.position=axis*0.95;s.ground_normal=axis;C.update(c,1/60,s,f,false)
 T.expect_near(C.depth(c,s),0,1e-5,"ramp lean cannot create takeoff crouch lift")
 T.expect_near(c.offset,0,1e-6,"100 percent retains the original zero compensation")
 s.position=axis*0.65;s.physics_state=103;C.update(c,1/60,s,f,false)
 T.expect_near(C.depth(c,s),0.3*math.cos(a),1e-5,"takeoff depth matches the vertical part of actual compression")
 T.expect_near(c.offset,0,1e-6,"full body crouch is still followed without suppression")
end
T.done()
if T.failures>0 then error("crouch takeoff depth regression") end
