local T = require("tlib")
local Settings, Presets = require("settings"), require("presets")
local JointLock = require("jointlock")
local Mock, Store, Menu = require("mock_reskate"), require("store"), require("menu")

T.group("jointlock_122")
local function pts(root, head, chest, feet_l, feet_r, knee_l, knee_r, hips, board)
	return {
		root = vector.create(0, root, 0), head = head and vector.create(0, head, 0) or nil,
		chest = chest and vector.create(0, chest, 0) or nil,
		spine = vector.create(0, root + 0.4, 0), spine2 = vector.create(0, root + 0.8, 0),
		left_foot = feet_l and vector.create(0, feet_l, 0) or nil, right_foot = feet_r and vector.create(0, feet_r, 0) or nil,
		left_knee = knee_l and vector.create(0, knee_l, 0) or nil, right_knee = knee_r and vector.create(0, knee_r, 0) or nil,
		hips = hips and vector.create(0, hips, 0) or nil, skateboard = board and vector.create(0, board, 0) or nil,
	}
end
local function cfg(target, damping)
	return { camera_style = "joint_lock", joint_target = target, joint_damping = damping }
end

-- Targets use multi-joint weighting; the module consumes only world Y.
do
	local s = JointLock.new()
	T.expect_near(JointLock.update(s, 1/60, cfg("feet", 0), 1, pts(1, 2.4, 1.8, 0.1, 0.3, 0.7, 0.9, 1, -0.2)).offset, -0.8, 1e-6,
		"feet use the average of both ankle joints")
	T.expect_near(JointLock.update(JointLock.new(), 1/60, cfg("knee", 0), 0, pts(0, 2.4, 1.8, 0, 0, 0.55, 0.75, 0, -0.2)).offset, 0.65, 1e-6,
		"knees use the average of both lower-leg origins")
	T.expect_near(JointLock.update(JointLock.new(), 1/60, cfg("chest", 0), 0, pts(0, 2.4, nil, 0, 0, 0, 0, 0, 0)).offset, 0.66, 1e-6,
		"chest derives from weighted spine and chest joints")
	T.expect_near(JointLock.update(JointLock.new(), 1/60, cfg("hips", 0), 0, pts(0, 2.4, nil, 0, 0, 0, 0, 0.2, 0)).offset, 0.26, 1e-6,
		"hips target blends hips and lower spine")
	T.expect_near(JointLock.update(JointLock.new(), 1/60, cfg("skateboard", 0), 0, pts(0, 2.4, 1.8, 0, 0, 0, 0, 0, -0.35)).offset, -0.35, 1e-6,
		"skateboard uses its centre height")
end

-- Damping filters world height, so a rigid body translation is damped even when joint-root offset is constant.
local function translated_curve(fps)
	local s = JointLock.new()
	local c = cfg("head", 100)
	JointLock.update(s, 1/fps, c, 0, pts(0, 1.2))
	local samples = {}
	for i=1, math.floor(0.4*fps) do
		local result = JointLock.update(s, 1/fps, c, 1, pts(1, 2.2))
		if i == math.floor(0.4*fps) then samples[#samples+1] = result.offset end
	end
	for i=1, math.floor(2.0*fps) do
		local result = JointLock.update(s, 1/fps, c, 1, pts(1, 2.2))
		if i == math.floor(2.0*fps) then samples[#samples+1] = result.offset end
	end
	return samples
end
local c30, c60, c144 = translated_curve(30), translated_curve(60), translated_curve(144)
T.expect_near(c30[1], c60[1], 0.015, "100% damping is frame-rate stable at 30/60 fps")
T.expect_near(c144[1], c60[1], 0.015, "100% damping is frame-rate stable at 60/144 fps")
T.expect(c60[1] > 0 and c60[1] < 1.2, "rigid vertical body movement is visibly damped")
T.expect(math.abs(c30[2] - 1.2) < 0.015 and math.abs(c60[2] - 1.2) < 0.015 and math.abs(c144[2] - 1.2) < 0.015,
	"filtered world height converges instead of leaving a stale offset")
do
	local s = JointLock.new()
	local immediate = JointLock.update(s, 1/60, cfg("head", 0), 0, pts(0, 1.1))
	local moved = JointLock.update(s, 1/60, cfg("head", 0), 0.7, pts(0.7, 1.8))
	T.expect_near(immediate.offset, 1.1, 1e-6, "0% damping starts at the selected joint")
	T.expect_near(moved.offset, 1.1, 1e-6, "0% damping tracks rigid translation immediately")
end

-- A large drop stays bounded, then catches up; an explicit cut reset re-seats the filter.
do
	local s = JointLock.new()
	local c = cfg("head", 100)
	JointLock.update(s, 1/60, c, 0, pts(0, 1.2))
	local drop = JointLock.update(s, 1/60, c, 20, pts(20, 21.2))
	T.expect(math.abs(drop.offset) <= JointLock.max_offset, "a 20 m drop clamps the camera correction")
	local settled
	for _=1,180 do settled = JointLock.update(s, 1/60, c, 20, pts(20, 21.2)) end
	T.expect_near(settled.offset, 1.2, 0.02, "large drops converge to the selected body point")
	JointLock.reset(s, 40)
	local cut = JointLock.update(s, 1/60, c, 40, pts(40, 41.2))
	T.expect_near(cut.offset, 1.2, 1e-6, "an explicit cut re-seats without carrying prior world height")
end

-- A brief nil read is tolerated, then the filter eases to a safe live-root fallback and reacquires cleanly.
do
	local s = JointLock.new()
	local c = cfg("head", 100)
	local before = JointLock.update(s, 1/60, c, 0, pts(0, 1.0)).offset
	local p = pts(0, nil)
	for _=1,3 do
		local missing = JointLock.update(s, 1/60, c, 0, p)
		T.expect(missing.offset > 0.9, "short missing reads keep the last trusted target")
	end
	local recovered = JointLock.update(s, 1/60, c, 0, pts(0, 1.0))
	T.expect_near(recovered.offset, before, 1e-6, "target recovers without a first-read snap")
	for _=1,90 do JointLock.update(s, 1/60, c, 0, p) end
	T.expect(math.abs(JointLock.update(s, 1/60, c, 0, p).offset) < 0.05, "long loss eases back to the current root height")
end

-- The first API request is nil by contract. The first actual joint pose must seed the real baseline,
-- instead of gradually inheriting the temporary root fallback as a permanent camera offset.
do
	local s = JointLock.new()
	local c = cfg("head", 100)
	local cold = JointLock.update(s, 1/60, c, 0.95, pts(0.95, nil))
	local first = JointLock.update(s, 1/60, c, 0.95, pts(0.95, 2.35))
	local stable = JointLock.update(s, 1/60, c, 0.95, pts(0.95, 2.35))
	T.expect(not cold.valid and cold.offset == 0, "first nil joint read stays at the current root")
	T.expect_near(first.offset, 1.4, 1e-6, "first trusted joint read seeds its actual world-height baseline")
	T.expect_near(stable.offset, first.offset, 1e-6, "first-read fallback cannot cause persistent baseline drift")
	JointLock.update(s, 1/60, { camera_style = "classic", joint_target = "head", joint_damping = 100 }, 8, pts(8, 8.4))
	local reentered = JointLock.update(s, 1/60, c, 8, pts(8, 9.25))
	T.expect_near(reentered.offset, 1.25, 1e-6, "re-entering Joint Lock after Classic starts from a fresh trusted sample")
end

-- Changing targets while crouched uses the active filter instead of re-seating at the new joint.
do
	local s = JointLock.new()
	local head = JointLock.update(s, 1/60, cfg("head", 100), 0, pts(0, 1.45, nil, 0, 0, 0, 0, 0, 0)).offset
	local feet = JointLock.update(s, 1/60, cfg("feet", 100), 0, pts(0, 1.2, nil, -0.55, -0.45, -0.1, 0, 0, 0)).offset
	T.expect(feet < head and feet > -0.55, "switching targets blends from the active height")
end

-- Old settings still default to Classic; new style, target and damping persist as preset values.
do
	Mock.install()
	local defaults = Settings.defaults()
	T.expect(Settings.valid(defaults) and defaults.follow.camera_style == "classic" and defaults.follow.joint_target == "head"
		and defaults.follow.joint_damping == 50, "old/default camera settings retain Classic and receive stable Joint Lock defaults")
	local old = require("fixtures/preset_110_default")
	local parsed = assert(Presets.parse_preset(reskate.json.encode({ name = "old", version = 1, values = old })))
	T.expect(parsed.report.refused == 0 and parsed.camera.follow.camera_style == "classic", "legacy presets load unchanged as Classic")
	local c = Settings.copy(defaults)
	c.follow.camera_style, c.follow.joint_target, c.follow.joint_damping = "joint_lock", "knee", 82
	local text = Presets.preset_text("Joint Lock", c, Presets.new_options())
	local round = assert(Presets.parse_preset(text))
	T.expect(round.report.refused == 0 and round.camera.follow.camera_style == "joint_lock"
		and round.camera.follow.joint_target == "knee" and round.camera.follow.joint_damping == 82,
		"Joint Lock controls survive preset save/load")
	local bad, _, report = Presets.from_values({ ["S3Cam.Follow.JointTarget"] = "not-a-joint" })
	T.expect(bad.follow.joint_target == "head" and report.refused > 0, "invalid target text is refused safely")
end

-- The camera tab selects style and conditionally shows one coherent control set without mutating values on open.
do
	local mock = Mock.install()
	local store = Store.new(); store:load()
	Menu.state.tab, Menu.state.position_for, Menu.state.feedback = 2, nil, nil
	Menu.install({ store = store, glue = { status = function() return "Enabled" end, base_fov = 65 } })
	local before = Presets.collect_values(store.settings, store.options)
	mock.build_page({ tabs = 2 })
	local widgets = {}
	for _, w in mock.widgets do if w.id then widgets[w.id] = w end end
	T.expect(widgets.cam_style and widgets.cam_style.choices[1] == "Classic" and widgets.cam_style.choices[2] == "Joint lock (Experimental)",
		"Camera tab exposes Classic and Joint Lock style choices")
	T.expect(widgets.pop_follow and widgets.crouch_on and not widgets.joint_target,
		"Classic displays the unchanged pop/crouch controls")
	local joint = Settings.copy(store.settings); joint.follow.camera_style = "joint_lock"; store:set_settings(joint)
	mock.build_page({ tabs = 2 })
	widgets = {}
	for _, w in mock.widgets do if w.id then widgets[w.id] = w end end
	T.expect(widgets.joint_target and widgets.joint_damping and not widgets.pop_follow and not widgets.crouch_on,
		"Joint Lock shows target/damping and hides Classic-only controls")
	local after = Presets.collect_values(store.settings, store.options)
	for key, value in before do
		if key ~= "S3Cam.Follow.CameraStyle" then T.expect(after[key] == value, "opening tabs preserves setting " .. key) end
	end
end

T.done()
if T.failures > 0 then error("joint lock tests failed") end


