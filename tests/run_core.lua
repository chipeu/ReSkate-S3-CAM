-- Runs every core module test and prints a summary.
--   tools\luau_run.exe -I Dynamic_Camera\plugin tests\run_core.lua
-- (the tests directory is on the search path automatically: it is this script's own folder)
local T = require("tlib")

local files = { "test_math", "test_tracker", "test_rig", "test_shots", "test_graph", "test_trajectory", "test_air",
	"test_shake", "test_misc", "test_landing_dip", "test_landing_jolt", "test_landing_rattle", "test_landing_102", "test_crouch", "test_grind_view",
	"test_preset_119", "test_menu_119", "test_stability", "test_bodyframe_sway", "test_fixed_chase", "test_sway_transitions", "test_render_transitions", "test_bail_sway", "test_pop_pitch_214", "test_frame_clock", "test_pop_manual_116", "test_pop_deadzone_118", "test_output_safety_118", "test_pop_adversarial_118", "test_pop_controls_119", "test_landing_handoff_121",
	"test_jointlock_122", "test_jointlock_display_122", "test_jointlock_drop_122", "test_style_persistence_122", "test_downhill_rail_122", "test_rail_edges_122", "test_pop_landing_122", "test_popoff_step_122", "test_reported_profile_123", "test_crouch_display_123", "test_reported_collision_123", "test_render_vertical_124", "test_drawn_deck_124", "test_collision_fast_124", "test_stable_classic_125", "test_classic_collision_125", "test_terrain_context_126", "test_crouch_terrain_126", "test_support_reference_132", "test_vert_return_133", "test_avoidance_intent_133", "test_turn_follow_134", "test_floor_aim_134", "test_return_elevation_134", "test_vert_landing_120", "test_popon_vert_121", "test_crouch_full_122", "test_crouch_floor_122", "test_crouch_depth_122", "test_view_blend_123", "test_high_vert_124", "test_takeoff_base_123", "test_render_floor_126", "test_terrain_camera_126", "test_vert_continuity_129", "test_terrain_blend_129", "test_adaptive_orbit_129", "test_adaptive_camera_129", "test_adaptive_orbit_130", "test_mega_transition_130", "test_prediction_budget_130", "test_ramp_pitch_130" }

table.insert(files,"test_manual_score_129")
table.insert(files,"test_downhill_clearance_129")
table.insert(files,"test_landing_collision_129")
table.insert(files,"test_root_clock_1210")
table.insert(files,"test_uneven_tracking_1210")
table.insert(files,"test_turn_tracking_1210")
table.insert(files,"test_joint_collision_1211")
table.insert(files,"test_manual_intent_1212")
table.insert(files,"test_recovery_path_1213")
table.insert(files,"test_motion_diag_1213")
table.insert(files,"test_reference_recovery_1213")
table.insert(files,"test_handoff_glide_1214")
table.insert(files,"test_host_2144_1215")
table.insert(files,"test_anchor_handoff_1216")
table.insert(files,"test_motion_diag_1216")
table.insert(files,"test_joint_sampling_1216")
table.insert(files,"test_contact_aim_1217")
table.insert(files,"test_clearance_release_1218")
local crashed = 0
table.insert(files,"test_context_125")
table.insert(files,"test_fast_crouch_125")
table.insert(files,"test_low_vert_125")
table.insert(files,"test_view_ownership_125")
for _, name in files do
	local ok, err = pcall(require, name)
	if not ok then
		crashed += 1
		print("ERROR in " .. name .. ": " .. tostring(err))
	end
end

print(string.format("TOTAL %d checks, %d failed, %d test file(s) crashed", T.checks, T.failures, crashed))
if T.failures > 0 or crashed > 0 then
	error("core tests failed")
end
