-- Logging-rate and side-effect regression for the 1.1.27 diagnostic hotfix.
local T=require("tlib")
local Mock,Glue=require("mock_reskate"),require("glue")
local v=vector.create
T.group("motion diagnostics 128")
local function make(verbose)
 local m=Mock.install()
 local p=v(0,2,-2)
 local g=setmetatable({source="ride",blend=1,store={options={verbose=verbose}},
  snap={onboard=true,physics_state=100},skater_position=v(0,1,0),frame={pos=p,debug={}},render_dt=1/60,
  note=function() error("compact diagnostic entered mirrored/file logger") end,
  query=function() error("diagnostic cast a ray") end}, {__index=Glue})
 return g,m,p
end
local function tick(g,t,p,c)
 g:trace_camera_frame(t,p,p,p,p,nil,c or 0,v(0,0,1),70)
end
for _,fps in {30,60,144} do
 for _,verbose in {false,true} do
  local g,m,p=make(verbose)
  for i=1,10*fps do
   local d=g.frame.debug
   d.motion_pop_follow=i%2==0;d.terrain_target=i%2;d.motion_trick_target=i%3
   tick(g,i/fps,p,0.7)
  end
  T.expect(#m.logs>=8 and #m.logs<=10,"hard one-second throttle despite continuous events")
  local bytes=0
  for _,row in m.logs do
   T.expect(#row[2]<512,"short single-line summary")
   T.expect(not string.find(row[2],"\n",1,true),"no multiline history dumps")
   bytes+=#row[2]
  end
  T.expect(bytes<5120,"ten-second diagnostic output budget")
  T.expect(next(m.files)==nil,"no diagnostic file writes")
  T.expect(g.frame.pos==p and g.snap.physics_state==100,"camera/state unchanged")
  T.expect(g.camera_trace.ring==nil,"no formatted per-frame history")
  T.expect(g.store.options.verbose==verbose,"saved verbose unchanged")
 end
end
do
 local g,m,p=make(true)
 tick(g,0,p)
 g.render_dt=0.224
 tick(g,0.224,p,0.73)
 g.render_dt=1/60
 tick(g,1.01,p)
 T.expect(#m.logs==1,"one summary emitted")
 local row=m.logs[1][2]
 T.expect(string.find(row,"dtMax=224.0ms",1,true)~=nil,"stalls survive sampling")
 T.expect(string.find(row,"corrMax=0.730",1,true)~=nil,"collision peaks survive sampling")
 tick(g,2.02,p)
 T.expect(string.find(m.logs[2][2],"corrMax=0.000",1,true)~=nil,"peaks reset per summary")
 local n=#m.logs
 g.source="offboard";tick(g,3,p)
 T.expect(g.camera_trace==nil and #m.logs==n,"off-board clears history and emits nothing")
 g.source="ride";tick(g,4,p)
 T.expect(#m.logs==n,"remount starts a fresh summary interval")
end
T.done()
if T.failures>0 then error("compact diagnostics regression") end
