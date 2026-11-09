local T=require("tlib")
local Mock=require("mock_reskate")
local Settings,Presets=require("settings"),require("presets")
T.group("style_persistence_122")
Mock.install()

-- Style switches are a view choice. Neither the switch nor a preset round trip
-- may retune the Classic controls that the user has already saved.
local c=Settings.defaults()
c.follow.camera_style="joint_lock"
c.follow.joint_target="knee"
c.follow.joint_damping=100
c.follow.trick_pop=false
c.follow.pop_amount=0.27
c.follow.pop_mode=1
c.follow.crouch_enabled=false
c.follow.crouch_amount=0.34
c.follow.crouch_mode=1
c.native_plus.landing_dip=false
T.expect(Settings.valid(c),"combined JointLock and Classic settings accepted")
local encoded=Presets.preset_text("Style roundtrip",c,Presets.new_options())
local parsed=assert(Presets.parse_preset(encoded))
T.expect(parsed.report.refused==0,"style preset has no refused fields")
local f=parsed.camera.follow
T.expect(f.camera_style=="joint_lock" and f.joint_target=="knee" and f.joint_damping==100,
    "JointLock selection, target and damping survive preset roundtrip")
T.expect(f.trick_pop==false and f.pop_amount==0.27 and f.pop_mode==1,
    "Classic Pop Off and its tuning survive while JointLock is selected")
T.expect(f.crouch_enabled==false and f.crouch_amount==0.34 and f.crouch_mode==1,
    "Classic crouch controls survive while JointLock is selected")
T.expect(parsed.camera.native_plus.landing_dip==false,"disabled artificial dip survives style roundtrip")
f.camera_style="classic"
T.expect(Settings.valid(parsed.camera) and f.trick_pop==false and f.crouch_amount==0.34
    and parsed.camera.native_plus.landing_dip==false,"returning to Classic exposes the saved tuning unchanged")

local legacy=require("fixtures/preset_110_default")
local old,_,report=Presets.from_values(legacy)
T.expect(report.refused==0 and old.follow.camera_style=="classic",
    "old preset with no style key opens in Classic")

T.done()
if T.failures>0 then error("style persistence tests failed") end
