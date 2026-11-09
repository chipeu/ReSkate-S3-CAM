local T,Mock,G=require("tlib"),require("mock_reskate"),require("glue")
local v=vector.create
T.group("recovery diagnostics 1216")
local m=Mock.install()
local function f(a)local r=math.rad(a);return v(math.sin(r),0,math.cos(r))end
local p=v(0,2,-2)
local g=setmetatable({source="ride",blend=1,store={options={verbose=false}},snap={onboard=true,physics_state=201},
 skater_position=v(0,1,0),frame={debug={},back=-f(179)},render_dt=1/60,rays_tick=17,tick_cost_max=0.75}, {__index=G})
g:trace_camera_frame(100000,p,p,p,p,nil,0,f(179),65)
g.frame.debug.motion_trick_target=math.rad(25);g.frame.debug.motion_trick_value=math.rad(-30)
g.frame.back=-f(-177);g.frame.debug.motion_recovery_gap=0.4;g.display_flags=0x1802
g:trace_camera_frame(100000.02,p+v(0.5,0,0),p+v(0.5,0,0),p+v(0.5,0,0),p+v(0.5,0,0),nil,0.3,f(-161),65)
T.expect(math.abs((g.camera_trace.peak_yaw or 0)-20)<0.01,"yaw peaks use wrapped angles across 180 degrees")
T.expect(math.abs((g.camera_trace.yaw_core or 0)-4)<0.01 and math.abs((g.camera_trace.yaw_correction or 0)-16)<0.01,"horizontal jolt separates core and presentation at the exact frame")
g.display_flags=0;g.snap.physics_state=100;g.rays_tick=2
g:trace_camera_frame(100001.01,p+v(0.5,0,0),p+v(0.5,0,0),p+v(0.5,0,0),p+v(0.5,0,0),nil,0,f(-161),65)
local line=m.logs[1][2]
T.expect(string.find(line,"peak=100000.020/201/1802",1,true)~=nil,"position peak retains safety decisions, not report-frame flags")
T.expect(string.find(line,"yPeak=100000.020/201/4.00/16.00/1802",1,true)~=nil,"yaw peak keeps common-frame attribution")
T.expect(string.find(line,"rays=17",1,true)~=nil and string.find(line,"workMax=0.75ms",1,true)~=nil,"window maxima retain native ray and full callback costs")
T.expect(string.find(line,"/1802/55.0 body=",1,true)~=nil,"yaw attribution records orbit target error at that same peak")
T.expect(#line<512 and next(m.files)==nil,"richer recovery evidence retains one-line and no-file budgets")
-- A marker/cut isn't tracking jitter and must not poison the next window.
g.frame.debug.reset=true
g:trace_camera_frame(100001.02,p+v(20,0,0),p,p,p+v(20,0,0),nil,0,f(20),65)
T.expect(g.camera_trace.peak_relative==0 and (g.camera_trace.peak_yaw or 0)==0,"deliberate camera cuts are excluded from continuity peaks")
T.done()
if T.failures>0 then error("recovery diagnostics regression") end
