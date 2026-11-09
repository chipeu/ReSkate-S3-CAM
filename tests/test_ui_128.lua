local T=require("tlib")
local Mock,Host=require("mock_reskate"),require("ui_host_126")
local Notes=require("release_notes")
T.group("manual menus 128")
local function setup(storage)
 local m=Host.enable(Mock.install())
 if storage then m.storage=storage end
 m.reskate.input.gamepad=function()return nil end
 return m,require("app").start()
end
T.expect(#Notes==0,"unapproved public notes and internal build history are absent")
for _,storage in {{},{release_acknowledgments="corrupt"},{release_acknowledgments={schema=1,versions={["1.2.7"]=true}}}} do
 local m,app=setup(storage)
 for _,ms in {16,2500,60000,3600000} do
  m.tick(ms);m.draw()
  T.expect(not app.ui.open and m.open_screen==nil and m.opens==0,"fresh/upgrade/corrupt startup never opens a screen")
 end
 T.expect(app.errors==0,"closed startup has no guarded errors")
 app.ui:changelogs();local d=m.draw()
 local empty=false
 for _,cmd in d.commands do if cmd.kind=="text" and cmd.b=="No public release notes are available yet." then empty=true end end
 T.expect(empty,"unapproved changelogs have a clear empty state")
 local before=m.storage.release_acknowledgments
 app.ui:okay()
 T.expect(m.storage.release_acknowledgments==before,"empty changelogs do not acknowledge an internal version")
 app.ui:close();m.tick(60000)
 T.expect(not app.ui.open,"manually dismissed screens do not reopen themselves")
end
do
 local m,app=setup()
 local Angle=require("settings").CameraAngle
 m.build_page({tabs=2,cam_height=2})
 T.expect(not app.ui.open and app.store.settings.angle==Angle.High,"native page edits camera settings without opening custom menu")
 m.build_page({tabs=2,ui_open_custom=true})
 T.expect(app.ui.open,"native page can explicitly open custom menu")
 app.ui:select_tab(2)
 local high=false
 for _,row in app.ui.model.rows do if row.id=="cam_height" then high=row.value==2 end end
 T.expect(high,"custom menu reads native changes from the same store")
 app.ui:change("cam_height",1);app.ui:rebuild();app.ui:close()
 m.build_page({tabs=2})
 local low=false
 for _,row in m.widgets do if row.id=="cam_height" then low=row.value==1 end end
 T.expect(low and app.store.settings.angle==Angle.Low,"native page reads custom changes from the same store")
 local next_m,next_app=setup(m.storage)
 next_m.tick(60000)
 T.expect(next_app.store.settings.angle==Angle.Low and not next_app.ui.open,"shared settings persist while menu visibility resets closed")
end
-- Future approved public notes track their public version, independently of test build IDs.
do
 Notes[1]={version="9.0.0",title="Fixture",sections={}}
 local m,app=setup();m.tick(60000)
 T.expect(not app.ui.open and app.ui.news.current=="9.0.0","approved notes never force startup opening")
 app.ui:changelogs();app.ui:okay()
 local seen=m.storage.release_acknowledgments.versions
 T.expect(seen["9.0.0"]==true and seen[app.ui.version]==nil,"manual acknowledgment records public release version only")
 Notes[1]=nil
end
T.done()
