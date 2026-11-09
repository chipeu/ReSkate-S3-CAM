local T,Mock,G=require("tlib"),require("mock_reskate"),require("glue")
local v=vector.create
T.group("peak attribution 1213")
local m=Mock.install()
local function forward(deg)return v(0,math.sin(math.rad(deg)),math.cos(math.rad(deg)))end
local g=setmetatable({source="ride",blend=1,store={options={verbose=false}},snap={onboard=true,physics_state=100},
 skater_position=v(0,1,0),frame={debug={},back=-forward(0)},render_dt=1/60},{__index=G})
local p=v(0,2,-2)
g:trace_camera_frame(0,p,p,p,p,nil,0,forward(0),70)
g.frame.back=-forward(2);g.frame.debug.shake_pitch=math.rad(5)
g:trace_camera_frame(0.02,p+v(0.1,0,0),p+v(0.2,0,0),p+v(0.4,0,0),p+v(0.8,0,0),nil,0.7,forward(10),70)
T.expect(math.abs(g.camera_trace.peak_core-0.1)<1e-5 and math.abs(g.camera_trace.peak_align-0.1)<1e-5,"core/alignment contributions use the relative-step peak frame")
T.expect(math.abs(g.camera_trace.peak_guard-0.2)<1e-5 and math.abs(g.camera_trace.peak_safety-0.4)<1e-5,"guard/safety contributions refer to that same frame")
T.expect(math.abs(g.camera_trace.pitch_core-2)<1e-4 and math.abs(g.camera_trace.pitch_correction-8)<1e-4 and math.abs(g.camera_trace.pitch_effects-5)<1e-4,"pitch peak separates core/correction and effect change")
g.snap.physics_state=103
g:trace_camera_frame(1.01,p+v(0.1,0,0),p+v(0.2,0,0),p+v(0.4,0,0),p+v(0.8,0,0),nil,0.7,forward(10),70)
local line=m.logs[1][2]
T.expect(string.find(line,"peak=0.020/100",1,true)~=nil and string.find(line,"pPeak=0.020/100",1,true)~=nil,"peak time/state remain distinct from current report state")
T.expect(#line<512 and next(m.files)==nil,"one compact SDK line, no diagnostic file IO")
T.expect(g.camera_trace.peak_at==nil and g.camera_trace.pitch_at==nil,"window attribution resets")
T.done()
if T.failures>0 then error("peak attribution regression") end
