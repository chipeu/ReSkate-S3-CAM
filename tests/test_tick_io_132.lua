local T,Mock=require("tlib"),require("mock_reskate")
T.group("tick IO 132")
local m=Mock.install()
local app=require("app").start()
local o=require("settings").copy(app.store.options);o.verbose=true
app.store:set_options(o)
local calls=0
local write=reskate.files.write
reskate.files.write=function(path,data)
 if string.find(path,"diag/",1,true) then calls+=1 end
 return write(path,data)
end
for i=1,600 do
 m.fire("physics_step",{at=m.clock_ms+1000/60,seconds=1/60,velocity={0,0,0},ragdoll=false})
 m.tick(1000/60)
end
T.expect(app.errors==0,"verbose gameplay remains valid")
T.expect(app.store.options.verbose==true,"saved logging preference preserved")
app.glue:release("test return to menus")
T.expect(calls==0,"no synchronous diagnostic writes during gameplay or camera release")
T.done()
if T.failures>0 then error("tick IO regression") end
