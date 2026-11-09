local T=require("tlib")
local Mock,Host=require("mock_reskate"),require("ui_host_126")
local News,Input,Model=require("version_news"),require("menu_input"),require("ui_model")
local Menu,Store=require("menu"),require("store")
local v=vector.create
T.group("custom UI 126")
local function setup(storage)
 local m=Host.enable(Mock.install({limit_rays=true}))
 if storage then m.storage=storage end
 m.reskate.input.gamepad=function()return nil end
 local app=require("app").start()
 return m,app
end
do
 local m=Mock.install();m.reskate.ui.screen=nil
 m.reskate.input.gamepad=function()return nil end
 m.reskate.menu.game=function()return {open=false}end
 local app=require("app").start()
 T.expect(not app.ui.available and m.page_title=="Dynamic Camera","unsupported custom screens retain the native menu")
 m.tick(2500);T.expect(app.errors==0,"unsupported custom UI cannot stop the camera startup")
end
-- Durable, version-specific acknowledgment, independent from camera data.
do
 local m=Mock.install();m.storage.settings={sentinel=42}
 local n=News.new("1.2.6")
 T.expect(n:pending(),"fresh version needs acknowledgment")
 n:offer();T.expect(not n:pending(),"dismissal does not repeat within a launch")
 T.expect(News.new("1.2.6"):pending(),"dismissal does not acknowledge across restarts")
 T.expect(n:acknowledge() and not News.new("1.2.6"):pending(),"Okay persists the version")
 T.expect(News.new("1.2.7"):pending(),"genuinely new version appears")
 local down=News.new("1.2.5");T.expect(down:pending() and down:acknowledge(),"unseen downgrade is acknowledged independently")
 T.expect(not News.new("1.2.6"):pending(),"returning to acknowledged version stays acknowledged")
 T.expect(m.storage.settings.sentinel==42,"news does not replace camera settings")
 m.storage.release_acknowledgments={schema=1,versions={["bad"]=true,["1.2.6"]="true"}}
 T.expect(News.new("1.2.6"):pending(),"malformed entries are treated as unseen")
 m.storage.release_acknowledgments="broken"
 T.expect(News.new("1.2.6"):pending(),"corrupt ledger does not throw")
 local n2=News.new("1.2.6");m.reskate.storage.set=function()error("full")end
 T.expect(not n2:acknowledge() and News.new("1.2.6"):pending(),"failed save never claims acknowledgment")
end
do
 local m=Host.enable(Mock.install());local input=Input.new()
 T.expect(input.binding=="0","default shortcut is number-row zero")
 T.expect(not Input.valid("F9") and not Input.valid("Ctrl+Shift+D") and not Input.valid("Insert"),"known plugin and native keys are refused")
 T.expect(input:set("Ctrl+K") and Input.new().binding=="Ctrl+K","binding persists independently")
 input:pressed(true);m.keys.Ctrl=true;m.keys.K=true
 T.expect(input:pressed(true) and not input:pressed(true),"combo fires once per press")
 input:pressed(false);T.expect(not input:pressed(true),"held keys do not fire on focus regain")
 m.keys={};input:pressed(true);m.keys.Ctrl=true;m.keys.K=true
 T.expect(input:pressed(true),"release rearms the shortcut")
 m.storage.menu_shortcut={bad=true};T.expect(Input.new().binding=="0","corrupt shortcut falls back safely")
 T.expect(not Input.valid("Ctrl+F9") and not Input.valid("Alt+F4"),"known raw-key and OS conflicts are refused with modifiers")
end
-- Existing tabs and every control/range remain present in the adapter.
do
 local m=Mock.install();local store=Store.new();store:load()
 Menu.install{store=store,glue={status=function()return "Enabled"end,base_fov=65}}
 for tab=1,8 do
  m.build_page({tabs=tab});local old={}
  for _,row in m.widgets do if row.id then old[row.id]=row end end
  local model=Model.new({},tab);Menu.build(model)
  local seen={}
  for _,row in model.rows do
   if row.id then
    seen[row.id]=true;local before=old[row.id]
    T.expect(before and before.kind==row.kind,"custom control keeps native kind: "..row.id)
    if before then for _,key in {"min","max","format","value"} do T.expect(before[key]==row[key],"custom control keeps "..key..": "..row.id)end end
   end
  end
  for id in old do T.expect(id=="tabs" or seen[id],"all native controls stay available: "..id)end
 end
 local model=Model.new({main_on=false},2);Menu.build(model)
 T.expect(store.enabled==false,"false-valued toggles survive the adapter")
end
do
 local m,app=setup();local ui=app.ui
 T.expect(ui.available and m.screens[require("custom_ui").TITLE].options.panel==false,"custom screen registered with input ownership")
 m.focused=false;m.tick(2500);T.expect(not ui.open,"startup remains closed while unfocused")
 m.focused=true;m.native_open=true;m.tick(16);T.expect(not ui.open,"startup remains closed over native menus")
 m.native_open=false;m.tick(16);T.expect(not ui.open,"startup remains closed when gameplay input becomes available")
 ui.news:acknowledge() -- Seed historical acknowledgment to test preservation below.
 local saved=m.storage
 local next_m,next_app=setup(saved)
 next_m.tick(2500);T.expect(not next_app.ui.open,"startup stays closed after restart")
 -- The primary shortcut toggles both ways, with release latching.
 next_m.keys["0"]=true;next_m.tick(16);T.expect(next_app.ui.open,"zero opens custom menu")
 next_m.draw();T.expect(next_app.ui.open,"held opening key cannot close it immediately")
 next_m.keys={};next_m.draw();next_m.keys["0"]=true;next_m.draw()
 T.expect(not next_app.ui.open,"fresh zero press closes own screen")
 next_app.ui:show("menu");next_app.ui:select_tab(8);next_app.ui:changelogs()
 T.expect(next_app.ui.mode=="news" and next_app.ui.news.seen[next_app.ui.version],"manual reopening never resets acknowledgment")
 next_app.ui:okay();T.expect(next_app.ui.mode=="menu" and next_app.ui.open,"manual notes return to settings")
 next_m.escape();T.expect(not next_app.ui.open and next_m.open_screen==nil,"Esc releases custom screen")
 next_m.native_open=true;next_m.keys["0"]=true;next_m.tick(16)
 T.expect(not next_app.ui.open,"shortcut cannot steal focus from a native menu")
 next_m.native_open=false;next_m.tick(16)
 T.expect(not next_app.ui.open,"held shortcut is ignored when a native menu closes")
end
-- Drawing, actual hit testing, sliders, menu-side persistence and viewport bounds.
do
 local m,app=setup();app.ui.news:acknowledge();local ui=app.ui
 ui:show("menu");m.keys={};m.cursor.left=false
 for _,size in {{1920,1080},{1280,720},{2560,1440}} do
  for tab=1,8 do
   ui:select_tab(tab);local d=m.draw(size[1],size[2])
   T.expect(#d.commands<1000 and d.text_bytes<65536,"all tabs render within host budgets")
   for _,cmd in d.commands do
    if cmd.kind=="rect" then T.expect(cmd.a[1]>=0 and cmd.b[1]<=size[1] and cmd.a[2]>=0 and cmd.b[2]<=size[2],"panel rectangles stay inside viewport")end
   end
  end
 end
 ui:select_tab(2);ui.view.scroll[2]=0;m.draw()
 local function click_hit(id,fraction)
  local hit
  for _,h in ui.view.hits do if h.id==id then hit=h;break end end
  for i=1,15 do
   if hit then break end
   ui.view.scroll[ui.tab]=(ui.view.scroll[ui.tab] or 0)+120;m.draw()
   for _,h in ui.view.hits do if h.id==id then hit=h;break end end
  end
  assert(hit,"missing hit "..id)
  m.cursor.position=v((hit.x+hit.w*(fraction or 0.5))*ui.view.scale,(hit.y+hit.h*0.5)*ui.view.scale,0)
  m.cursor.left=false;m.draw();m.cursor.left=true;m.draw();m.cursor.left=false;m.tick(16);m.draw()
 end
 local enabled=app.store.enabled;click_hit("main_on")
 T.expect(app.store.enabled~=enabled,"actual custom toggle edits existing setting")
 click_hit("cam_height");T.expect(ui.view.dropdown~=nil,"dropdown remains open after its opening click")
 click_hit("choice2");T.expect(app.store.settings.angle==require("settings").CameraAngle.High,"dropdown selection edits the existing camera setting")
 ui:select_tab(8);ui.view.scroll[8]=0;m.draw()
 local before_radius=app.store.settings.collision.radius
 click_hit("mc_radius",0.9)
 T.expect(math.abs(app.store.settings.collision.radius-before_radius)>0.1,"slider dragging changes the existing numeric setting")
 ui:select_tab(8);ui.view.scroll[8]=0;m.draw();click_hit("ui_shortcut")
 m.draw();m.keys.Ctrl=true;m.keys.K=true;m.draw();m.keys={};m.tick(120);m.draw()
 T.expect(ui.input.binding=="Ctrl+K" and m.storage.menu_shortcut=="Ctrl+K","shortcut recorder persists captured combo")
 local store_again=Store.new();store_again:load()
 T.expect(math.abs(store_again.settings.collision.radius-app.store.settings.collision.radius)<1e-6,"custom slider setting survives existing serialization precision")
 app.store:reset()
 T.expect(Input.new().binding=="Ctrl+K" and not News.new(ui.version):pending(),"camera reset preserves menu key and news acknowledgment")
 ui:close();m.tick(16);m.keys.Ctrl=true;m.keys.K=true;m.tick(16)
 T.expect(ui.open,"recorded key opens the menu")
 m.fire("level_unloading");T.expect(not ui.open and m.open_screen==nil,"level unload releases input")
 T.expect(app.errors==0,"integrated UI draws without guarded errors")
end
-- Native entry to shortcut editing, and a modal preset dialog's input isolation.
do
 local m,app=setup();app.ui.news:acknowledge();m.keys={}
 m.build_page({tabs=8,ui_shortcut=true})
 T.expect(app.ui.open and app.ui.tab==8 and app.ui.capture,"native Advanced opens the custom shortcut recorder")
 app.ui.capture=false;Menu.open_dialog("")
 T.expect(app.ui.suspended and m.dialog~=nil,"preset dialog suspends custom raw input")
 Menu.on_dialog({action="dialog",args={Menu.DIALOG_ID,"close"}})
 T.expect(not app.ui.suspended and not m.dialog,"closing preset dialog restores custom input")
 app.ui:close()
end
-- Screen creation and cursor publication happen in different host phases.
do
 local m,app=setup();app.ui.news:acknowledge();app.ui:show("menu")
 local cursor=m.reskate.input.cursor
 m.reskate.input.cursor=function()return nil end
 local d=m.draw()
 T.expect(app.ui.open and #d.commands>0,"first frame renders while the host cursor warms up")
 m.reskate.input.cursor=cursor;m.draw()
 T.expect(app.ui.open,"late cursor publication restores interaction")
 m.reskate.input.cursor=function()return nil end
 m.tick(1200);m.draw()
 T.expect(not app.ui.open and m.open_screen==nil,"lost cursor eventually releases input instead of trapping an invisible screen")
end
do
 local m,app=setup();app.ui.news:acknowledge();app.ui:show("menu")
 local side,angle=app.store.settings.shoulder.side,app.store.settings.angle
 m.reskate.input.gamepad=function()return {buttons={left_stick=true,right_stick=true},right_x=1,right_y=1}end
 m.tick(16)
 T.expect(app.store.settings.shoulder.side==side and app.store.settings.angle==angle,"controller camera shortcuts are isolated while custom UI owns input")
 app.ui:close();m.tick(16)
 T.expect(app.store.settings.shoulder.side==side and app.store.settings.angle==angle,"held controller clicks cannot trigger when the menu closes")
end
T.done()
if T.failures>0 then error("custom UI regressions")end
