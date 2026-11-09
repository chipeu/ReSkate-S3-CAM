local Settings,Presets=require("settings"),require("presets")
local values={
	["S3Cam.Shoulder.Offset"]=2.5,
	["S3Cam.Collision.PullInTime"]=0,
	["S3Cam.AirCamera.FollowHeight"]=0,
	["S3Cam.Follow.Strength"]=2.75,
	["S3Cam.Follow.CrouchAmount"]="invalid",
}
local c=Settings.defaults()
c.shoulder.offset=2.5; c.collision.pull_in_time=0; c.air_camera.follow_height=0
print("values are valid in current camera:",Settings.valid(c))
local loaded,_,report=Presets.from_values(values)
print("loaded shoulder offset",loaded.shoulder.offset,"collision entry",loaded.collision.pull_in_time,
	"air follow",loaded.air_camera.follow_height,"unrelated follow",loaded.follow.strength,
	"invalid crouch default",loaded.follow.crouch_amount,"reported invalid",report.refused)
