-- Controlled evidence for the grind-angle audit, not a replacement for a game capture.
local Camera, Subject, Settings = require("camera"), require("subject"), require("settings")
for _, slope in {0, -0.5} do
	local cam=Camera.new()
	local cfg=Settings.defaults(); cfg.shake_enabled=false
	assert(cam:set_settings(cfg))
	local frame
	for i=1,240 do
		local t=i/60
		local s=Subject.new_snapshot()
		s.valid,s.onboard,s.board_valid=true,true,true
		s.time,s.physics_state=t,400
		s.position=vector.create(0,0.95+slope*6*t,6*t)
		s.board_position=s.position-vector.create(0,0.95,0)
		s.velocity=vector.create(0,slope*6,6)
		s.forward=vector.create(0,0,1)
		s.ground_clearance=0.95
		s.ground_normal=vector.normalize(vector.create(0,1,-slope))
		frame=cam:update(1/60,s,function() return nil end,{base_fov_deg=65})
	end
	print(string.format("grind slope %.1f: elevation %.2f deg; terrain lift %.2f deg; air rise %.2f deg; view pitch %.2f deg; collision pull %.3f m",
		slope,math.deg(frame.debug.elevation),math.deg(cam.downhill_lift),math.deg(frame.debug.air_rise),
		math.deg(math.asin(-frame.back.y)),frame.debug.collision_pull))
end
