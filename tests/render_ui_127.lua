local Mock,Host=require("mock_reskate"),require("ui_host_126")
local m=Host.enable(Mock.install());m.reskate.input.gamepad=function()return nil end
local app=require("app").start();app.ui.news:acknowledge();app.ui:show("menu")
local frames={}
for _,item in {{"Camera",2,960},{"Wide camera",2,1280},{"Advanced",8,960},{"Changelogs",8,960,true}} do
 app.ui.layout:set(item[3],1888);app.ui:select_tab(item[2])
 if item[4] then app.ui:changelogs()end
 m.tick(350);local d=m.draw(1920,1080)
 frames[#frames+1]={name=item[1],width=item[3]+32,commands=d.commands}
end
print("PREVIEW_JSON "..m.reskate.json.encode(frames))
