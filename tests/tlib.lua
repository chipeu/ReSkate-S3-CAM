-- Tiny test helpers shared by the tests (not shipped). Each test file calls T.group(name) first and
-- T.done() last; the counters are global to the process so run_core.lua can print one total.
local T = {}
T.checks = 0
T.failures = 0
local group = "?"
local group_failures, group_checks = 0, 0

function T.group(name)
	group = name
	group_failures, group_checks = 0, 0
end

function T.expect(cond, what)
	T.checks += 1
	group_checks += 1
	if not cond then
		T.failures += 1
		group_failures += 1
		print("FAIL [" .. group .. "]: " .. what)
	end
end

function T.near(a, b, tol)
	tol = tol or 1e-5
	return math.abs(a - b) <= tol
end

-- expect_near(a, b, tol, what): reports both numbers on failure.
function T.expect_near(a, b, tol, what)
	local ok = type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tol or 1e-5)
	T.expect(ok, what .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

function T.vnear(a, b, tol)
	return vector.magnitude(a - b) <= (tol or 1e-5)
end

function T.done()
	print(string.format("%-14s %d checks, %d failed", group, group_checks, group_failures))
end

return T
