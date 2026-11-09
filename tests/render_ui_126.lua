-- Offline preview of the actual draw commands, not a separate UI mockup.
local Mock,Host=require("mock_reskate"),require("ui_host_126")
local m=Host.enable(Mock.install())
m.reskate.input.gamepad=function()return nil end
local app=require("app").start()
app.ui.news:acknowledge();app.ui:show("menu")
local frames={}
for _,item in {{"Camera",2},{"Advanced settings",8},{"Release notes",8,true}} do
 app.ui:select_tab(item[2])
 if item[3] then app.ui:changelogs()end
 local d=m.draw(1920,1080)
 frames[#frames+1]={name=item[1],commands=d.commands}
end
print("PREVIEW_JSON "..m.reskate.json.encode(frames))
