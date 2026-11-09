local T=require("tlib")
local Mock=require("mock_reskate")
local Settings,Presets=require("settings"),require("presets")
local Before=require("ref_118/presets")
T.group("preset_119")
Mock.install()
local defaults=Presets.collect_values(Settings.defaults(),Presets.new_options())
local function same(a,b) return type(a)=="number" and type(b)=="number" and T.near(a,b,1e-6) or a==b end
local function preserved(values,label)
	local parsed=assert(Presets.parse_preset(reskate.json.encode({name=label,version=1,values=values})))
	local got=Presets.collect_values(parsed.camera,parsed.options)
	T.expect(Settings.valid(parsed.camera) and parsed.report.refused==0,label.." is accepted")
	for key,value in values do
		if got[key]~=nil then T.expect(same(got[key],value),label.." preserves "..key) end
	end
	return parsed,got
end

local old=require("fixtures/preset_110_default")
T.expect(old["S3Cam.Follow.CrouchAmount"]==nil and old["S3Cam.Follow.CrouchEnabled"]==nil,"actual 1.1.0 preset predates crouch controls")
local parsed,got=preserved(old,"1.1.0 Default")
T.expect(got["S3Cam.Follow.CrouchAmount"]==defaults["S3Cam.Follow.CrouchAmount"]
	and got["S3Cam.Follow.CrouchEnabled"]==defaults["S3Cam.Follow.CrouchEnabled"],"missing crouch controls use current defaults")
T.expect(got["S3Cam.Follow.PopAmount"]==1 and got["S3Cam.Follow.PopMode"]==0 and got["S3Cam.Follow.TrickPop"]==true,
	"older presets retain full camera-height pop follow")
local user=require("fixtures/preset_legacy_user")
preserved(user.values,"Actual older saved preset")
local latest=Settings.copy(user.values)
latest["S3Cam.Follow.CrouchAmount"],latest["S3Cam.Follow.CrouchEnabled"]=0.37,false
latest["S3Cam.Follow.PopAmount"],latest["S3Cam.Follow.PopMode"],latest["S3Cam.Follow.TrickPop"]=0.43,1,true
preserved(latest,"Current controls")
do
	local c,o=Presets.from_values(latest)
	local saved=Presets.preset_text("Pop controls",c,o)
	local reloaded=assert(Presets.parse_preset(saved))
	T.expect(reloaded.camera.follow.pop_amount==0.43 and reloaded.camera.follow.pop_mode==1
		and reloaded.camera.follow.trick_pop==true,"pop strength and mode survive save/reload")
end

-- Every persisted scalar rejects bad data individually; unrelated valid values survive.
for _,field in Presets.fields do
	local key=field[1]
	for _,bad in field[4]=="f" and {"wrong type",0/0,math.huge,1e99} or {"wrong type",0} do
		local input=Settings.copy(defaults)
		local other=key=="S3Cam.Follow.Strength" and "S3Cam.Shoulder.Offset" or "S3Cam.Follow.Strength"
		input[other]=other=="S3Cam.Shoulder.Offset" and 0.73 or 2.75
		input[key]=bad
		local c,o,report=Presets.from_values(input)
		local output=Presets.collect_values(c,o)
		T.expect(Settings.valid(c),"bad scalar leaves a safe camera: "..key)
		T.expect(same(output[key],defaults[key]),"bad scalar uses that field's default: "..key)
		T.expect(same(output[other],input[other]),"bad scalar keeps unrelated valid value: "..key)
		T.expect(report.refused>=1,"bad scalar is reported: "..key)
	end
end

-- Valid data can have a wider range than the interactive sliders offer.
do
	local input=Settings.copy(defaults)
	input["S3Cam.Shoulder.Offset"]=2.5
	input["S3Cam.Collision.PullInTime"]=0
	input["S3Cam.AirCamera.FollowHeight"]=0
	input["S3Cam.Look.ResponseTime"]=0.02
	local before=Before.from_values(input)
	T.expect(before.shoulder.offset==1 and before.collision.pull_in_time==0.05,"1.1.8 reference reproduces loader retuning")
	preserved(input,"Valid legacy ranges")
end

do
	local input=Settings.copy(defaults)
	input["S3Cam.Fov.SpeedFovMin"],input["S3Cam.Fov.SpeedFovMax"]=20,40
	preserved(input,"Dependent range pair")
	input["S3Cam.Fov.SpeedFovMin"],input["S3Cam.Fov.SpeedFovMax"]=20,10
	input["S3Cam.Follow.Strength"]=2.75
	local c,_,report=Presets.from_values(input)
	T.expect(Settings.valid(c) and report.refused>=1,"conflicting range pair remains safe")
	T.expect(c.follow.strength==2.75,"conflicting pair does not discard unrelated settings")
	local old_keys=Before.collect_values(Settings.defaults(),Before.new_options())
	for key in defaults do T.expect(old_keys[key]~=nil or key=="S3Cam.Options.StableTiming" or key=="S3Cam.Options.CameraSway"
		or key=="S3Cam.Follow.CrouchMode" or key=="S3Cam.Follow.TrickPop" or key=="S3Cam.Follow.PopAmount" or key=="S3Cam.Follow.PopMode"
		or key=="S3Cam.Follow.CameraStyle" or key=="S3Cam.Follow.JointTarget" or key=="S3Cam.Follow.JointDamping",
		"existing key retained or explicit option addition: "..key) end
	T.expect(defaults["S3Cam.Options.StableTiming"]==true,"old presets enable the stability test by default")
	for key in old_keys do T.expect(defaults[key]~=nil,"no persisted key removed: "..key) end
end

T.done()
if T.failures>0 then error("preset compatibility tests failed") end
