-- Draw-command recording only; no real game input or installation.
local Mock,Host=require("mock_reskate"),require("ui_host_126")
local m=Host.enable(Mock.install());m.reskate.input.gamepad=function()return nil end
local app=require("app").start();app.store:set_show_help(false)
app.ui.news:acknowledge();app.ui:show("menu")
local frames={};local grip_x,grip_y
for i=0,59 do
 if i==5 then app.ui:select_tab(2) end
 if i==12 then app.ui:change("pop_amount",50) end
 if i==17 then app.ui:change("pop_follow",false) end
 if i==22 then
  local b=app.ui.view.metrics;grip_x=b.x+b.width-1;grip_y=b.y+b.h*0.5
  m.cursor.position=vector.create(grip_x,grip_y,0);m.cursor.left=true
 elseif i>22 and i<44 then m.cursor.position=vector.create(grip_x+(i-22)*12,grip_y,0)
 elseif i==44 then m.cursor.left=false
 elseif i==49 then app.ui:select_tab(8)
 elseif i==55 then app.ui:close() end
 local d=m.draw(1920,1080)
 frames[#frames+1]={name=string.format("frame-%03d",i),width=1280,commands=d.commands}
 m.tick(50)
end
print("PREVIEW_JSON "..m.reskate.json.encode(frames))
