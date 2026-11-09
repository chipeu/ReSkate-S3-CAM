local T=require("tlib")
local Mock,Settings,Presets,Store=require("mock_reskate"),require("settings"),require("presets"),require("store")
local Menu,Before=require("menu"),require("ref_118/menu")
T.group("menu_119")
local function render(module,tab,high,speed,help)
	local m=Mock.install()
	local st=Store.new();st:load()
	local cfg=Settings.copy(st.settings)
	cfg.angle=high and Settings.CameraAngle.High or Settings.CameraAngle.Low
	for _,fr in {cfg.framing,cfg.framing_high} do
		fr.manual_mode=speed and Settings.ManualDistanceMode.Speed or Settings.ManualDistanceMode.Fixed
	end
	for _,rd in {cfg.ride_distance,cfg.ride_distance_high} do rd.mode=speed and Settings.DistanceMode.Speed or Settings.DistanceMode.Fixed end
	assert(st:set_settings(cfg));st:set_show_help(help)
	module.state.position_for=nil;module.state.selected=nil;module.state.scan_at=0;module.state.result="";module.state.feedback=nil
	module.install({store=st,glue={status=function() return "Enabled" end,base_fov=65}})
	Presets.refresh()
	local initial=Presets.collect_values(st.settings,st.options)
	m.build_page({tabs=tab})
	local final=Presets.collect_values(st.settings,st.options)
	for key,value in initial do T.expect(final[key]==value,"opening a tab does not edit "..key) end
	local widgets={}
	for _,w in m.widgets do if w.id then widgets[w.id]=w end end
	return widgets,m.widgets
end

for tab=1,8 do
	for _,high in {false,true} do
		for _,speed in {false,true} do
			for _,help in {false,true} do
				local previous=render(Before,tab,high,speed,help)
				local current,list=render(Menu,tab,high,speed,help)
				for id,w in previous do
					local n=current[id]
					T.expect(n~=nil,"control remains available: "..id)
					if n then
						for _,key in {"kind","value","min","max","format"} do T.expect(w[key]==n[key],"control semantics retained: "..id.." "..key) end
						if w.choices then T.expect(#w.choices==#n.choices,"choice order/count unchanged: "..id) end
					end
				end
				for id in current do
					T.expect(previous[id]~=nil or id=="o_stability" or id=="ob_sway" or id=="cam_style"
						or id=="joint_target" or id=="joint_damping" or id=="pop_follow" or id=="pop_mode"
						or id=="pop_amount" or id=="crouch_mode","no unexpected control: "..id)
				end
				for _,w in list do
					if w.kind=="card" then
						T.expect(w.text==string.upper(w.text) and w.subtitle==nil,"uppercase cards have no subtitles")
					end
					for _,text in {w.help or "",w.kind=="note" and w.text or ""} do
						local lower=string.lower(text)
						T.expect(#text<=180 and not string.find(lower,"blend smoothly",1,true)
							and not string.find(lower,"shot blend",1,true) and not string.find(lower,"100% keeps",1,true),"descriptions are short and direct")
					end
				end
			end
		end
	end
end

local camera=render(Menu,2,false,false,true)
T.expect(camera.cam_style.text=="Camera style" and camera.cam_style.choices[1]=="Classic" and camera.cam_style.choices[2]=="Joint lock (Experimental)",
	"camera style selector keeps Classic first and offers Joint Lock")
T.expect(camera.pop_follow.text=="Follow pop height" and camera.pop_mode.choices[1]=="Camera height" and camera.pop_mode.choices[2]=="Camera pitch","pop controls have independent height and pitch modes")
T.expect(camera.pop_amount.min==0 and camera.pop_amount.max==100 and camera.pop_amount.text=="Pop follow strength","pop strength spans zero to 100 percent")
T.expect(camera.crouch_on.text=="Follow crouching" and camera.crouch_on.help=="Follow the skater lowering into a crouch.","approved crouch wording")
T.expect(camera.crouch_amount.text=="Crouch follow strength","approved crouch strength label")
local foot=render(Menu,7,false,false,true)
T.expect(foot.ob_style.text=="Camera type" and foot.ob_style.choices[1]=="Orbit" and foot.ob_style.choices[2]=="Shoulder","Orbit/Shoulder uses Camera type")

T.done()
if T.failures>0 then error("menu wording tests failed") end
