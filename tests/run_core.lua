-- Runs every core module test and prints a summary.
--   tools\luau_run.exe -I Dynamic_Camera\plugin tests\run_core.lua
-- (the tests directory is on the search path automatically: it is this script's own folder)
local T = require("tlib")

local files = { "test_math", "test_tracker", "test_rig", "test_shots", "test_graph", "test_trajectory", "test_air",
	"test_shake", "test_misc" }

local crashed = 0
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
