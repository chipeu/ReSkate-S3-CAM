local T=require("tlib")
local Mock,Host=require("mock_reskate"),require("ui_host_126")
local Input,Layout=require("menu_input"),require("ui_layout")
local v=vector.create
T.group("responsive UI 127")
for digit=0,9 do
 local m=Host.enable(Mock.install());local input=Input.new()
 input:set(tostring(digit));input:pressed(true)
 m.keys[48+digit]=true
 T.expect(input:pressed(true),"number-row key uses its real VK: "..digit)
 T.expect(not input:pressed(true),"holding number-row key does not repeat")
end
do
 local m=Mock.install();m.storage.menu_layout={schema=1,width="invalid"}
 T.expect(Layout.new().width==960,"corrupt layout uses a safe default")
 m.storage.menu_layout={schema=1,width=1000000}
 T.expect(Layout.new().width==1440,"out-of-range layout is bounded")
 local layout=Layout.new();layout:set(1100,1888);layout:save()
 m.reskate.storage.set=function()error("full")end
 layout:set(1200,1888)
 T.expect(not layout:save() and layout.dirty,"failed layout write stays dirty without changing camera data")
end
local function setup()
 local m=Host.enable(Mock.install());m.reskate.input.gamepad=function()return nil end
 local app=require("app").start();app.ui.news:acknowledge();app.ui:show("menu")
 m.tick(250);m.draw();return m,app,app.ui
end
do
 local m,app,ui=setup()
 m.keys={};m.draw();m.native_open=true;m.keys[48]=true;m.draw()
 T.expect(not ui.open,"own screen can close above an underlying native page")
end
do
 local m,app,ui=setup()
 local width=ui.view.metrics.width;local font=ui.view.metrics.text_scale
 local grip
 for _,hit in ui.view.hits do if hit.id=="resize" then grip=hit end end
 assert(grip)
 local start_x=(grip.x+grip.w/2)*ui.view.scale
 local y=(grip.y+grip.h/2)*ui.view.scale
 m.cursor.position=v(start_x,y,0);m.cursor.left=false;m.draw()
 m.cursor.left=true;m.draw()
 m.cursor.position=v(start_x+300,y,0);m.tick(16);m.draw()
 T.expect(ui.view.metrics.width>width+250,"right-edge drag widens continuously")
 T.expect(ui.view.metrics.text_scale>font,"content text grows with the panel")
 T.expect(m.storage.menu_layout==nil,"width is not written on every drag frame")
 m.cursor.left=false;m.draw()
 T.expect(m.storage.menu_layout and Layout.new().width==ui.layout.width,"released width survives a new layout instance")
 for _,wanted in {760,960,1280,1440} do
  ui.layout:set(wanted,1888)
  for tab=1,8 do
   ui:select_tab(tab);m.tick(200)
   local d=m.draw()
   T.expect(app.errors==0 and #d.commands<1000,"every tab renders at resized width "..wanted)
   for _,cmd in d.commands do
    if cmd.kind=="rect" then T.expect(cmd.a[1]>=0 and cmd.b[1]<=1920 and cmd.a[2]>=0 and cmd.b[2]<=1080,"resized cards remain clipped inside the viewport")end
   end
  end
 end
 ui.layout:set(1440,1888);m.draw(1280,720)
 T.expect(ui.view.metrics.width*ui.view.scale<1280,"wide saved layout clamps to a smaller window")
 T.expect(app.errors==0,"resize and reflow never reach the guarded error handler")
end
do
 local m,app,ui=setup();ui:close();m.tick(200)
 ui:show("menu");local first=m.draw();m.tick(90);local middle=m.draw();m.tick(150);local final=m.draw()
 local a=first.commands[1].style.colour:sub(-2)
 local b=middle.commands[1].style.colour:sub(-2)
 local c=final.commands[1].style.colour:sub(-2)
 T.expect(tonumber(a,16)<tonumber(b,16) and tonumber(b,16)<=tonumber(c,16),"opening opacity eases monotonically")
 ui:close();local fading=m.draw();m.tick(150);local closed=m.draw()
 T.expect(not ui.open and not m.open_screen,"closing releases input immediately")
 T.expect(#fading.commands>0 and #closed.commands==0,"close animation ends without retaining a screen")
 ui:show("menu");m.tick(40);local opening=m.draw()
 local before=tonumber(opening.commands[1].style.colour:sub(-2),16)
 ui:close();local closing=m.draw()
 T.expect(tonumber(closing.commands[1].style.colour:sub(-2),16)<=before,"closing during entrance cannot flash to full opacity")
end
do
 local m,app,ui=setup()
 ui.view.measure_cache={};ui.view.measure_count=0
 local cold=m.draw();local warm=m.draw()
 T.expect(cold.measure_calls>0 and warm.measure_calls<cold.measure_calls*0.5,"steady animation frames reuse measured text")
 T.expect(ui.view.measure_count<=2048,"text measurement cache remains bounded")
end
T.done()
if T.failures>0 then error("responsive UI regressions")end
