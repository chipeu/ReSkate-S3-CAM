-- Shared runtime clearance for trick yaw and shoulder. Probes use camera.lua's counted cast.
local M = {}
local abs, min, max, sin, cos, sqrt = math.abs, math.min, math.max, math.sin, math.cos, math.sqrt
local create, magnitude = vector.create, vector.magnitude

function M.reset(st)
	st.yaw, st.shoulder, st.yaw_rate, st.shoulder_rate = 0, 0, 0, 0
	st.clear_time, st.side_time = 0, 0
	st.constrained = false
	st.alternate = false
end

local function eye(anchor, base, yaw, reach, height, shoulder, shoulder_dir)
	local h = base - yaw
	local sx = shoulder_dir and shoulder_dir.x or -cos(h)
	local sz = shoulder_dir and shoulder_dir.z or -sin(h)
	return create(anchor.x - sin(h) * reach + sx * shoulder,
		height, anchor.z + cos(h) * reach + sz * shoulder)
end

-- Centre and tangential radius whiskers test a finite-width eye at its actual height.
-- An unavailable query is unknown, never clear. Returns clearance and rays used.
local function candidate(owner, query, cast, pivot, anchor, base, yaw, reach, height, shoulder, radius, ahead, available, shoulder_dir)
	if available < 3 then return false, 0 end
	local h = base - yaw
	local at = eye(anchor, base, yaw, reach, height, shoulder, shoulder_dir)
	local radial = at - pivot
	local span = magnitude(radial)
	if span < 0.01 then return true, 0 end
	local end_point = at + radial * (radius / span)
	if cast(owner, query, pivot, end_point) then return false, 1 end
	local right = create(cos(h) * radius, 0, sin(h) * radius)
	if cast(owner, query, pivot + right, end_point + right) then return false, 2 end
	if cast(owner, query, pivot - right, end_point - right) then return false, 3 end
	if ahead and magnitude(ahead) > 0.05 and available >= 4 then
		if cast(owner, query, at, at + ahead) then return false, 4 end
		return true, 4
	end
	return true, 3
end

-- Three parallel sweeps protect the actual next small orbit step, including radius.
local function transit(owner, query, cast, a, b, radius, available)
	local delta = b - a
	local distance = magnitude(delta)
	if distance < 1e-5 then return true, 0 end
	if available < 3 then return false, 0 end
	local extended = b + delta * (radius / distance)
	if cast(owner, query, a, extended) then return false, 1 end
	local flat = sqrt(delta.x * delta.x + delta.z * delta.z)
	local across = flat > 1e-5 and create(-delta.z * radius / flat, 0, delta.x * radius / flat)
		or create(radius, 0, 0)
	if cast(owner, query, a + across, extended + across) then return false, 2 end
	if cast(owner, query, a - across, extended - across) then return false, 3 end
	return true, 3
end

function M.solve(st, owner, query, cast, pivot, anchor, base, height, reach,
	requested_yaw, requested_shoulder, radius, ahead, dt, snap, available, shoulder_dir)
	if snap then
		M.reset(st)
		st.yaw, st.shoulder = requested_yaw, requested_shoulder
		return st.yaw, st.shoulder
	end
	if available < 3 then return st.yaw, st.shoulder end
	local yaw, shoulder = requested_yaw, requested_shoulder
	local ok, used
	local preferred_clear = false
		ok, used = candidate(owner, query, cast, pivot, anchor, base, yaw, reach, height, shoulder, radius, ahead, available, shoulder_dir)
		available -= used
		preferred_clear = ok
		if ok and not st.constrained then
			local old_eye = eye(anchor, base, st.yaw, reach, height, st.shoulder, shoulder_dir)
			local wanted_eye = eye(anchor, base, yaw, reach, height, shoulder, shoulder_dir)
			local path_ok
			path_ok, used = transit(owner, query, cast, old_eye, wanted_eye, radius, available)
			if path_ok then
				st.yaw, st.shoulder = yaw, shoulder
				return yaw, shoulder -- ordinary open-world timing stays exactly as requested
			end
			if used == 0 then return st.yaw, st.shoulder end -- no ray allowance is not clearance
			ok = false
		end
		if ok then
			st.side_time, st.alternate = 0, false
		else
			st.constrained = true
			st.side_time = min(st.side_time + dt, 1)
			-- An alternate is considered only after time at centre; its endpoint
			-- and every following short movement need their own clearance.
			if st.side_time >= 0.5 and (st.alternate or (abs(st.yaw) < 0.05 and abs(st.shoulder) < 0.05))
				and (abs(requested_yaw) > 0.01 or abs(requested_shoulder) > 0.02) and available >= 6 then
				yaw, shoulder = -requested_yaw, -requested_shoulder
				ok, used = candidate(owner, query, cast, pivot, anchor, base, yaw, reach, height, shoulder, radius, nil, available, shoulder_dir)
				available -= used
				if ok then st.alternate = true end
			end
			if not ok then
				yaw, shoulder = 0, 0
				ok = true -- every actual movement toward centre is still swept below
			end
		end
		if not ok then return st.yaw, st.shoulder end

	local contracting = abs(yaw) + abs(shoulder) < abs(st.yaw) + abs(st.shoulder) - 0.01
	st.clear_time = contracting and 0 or min(st.clear_time + dt, 1)
	if not contracting and st.clear_time < 0.25 then yaw, shoulder = st.yaw, st.shoulder end
	local yaw_rate_max, shoulder_rate_max = contracting and 4 or 1.8, contracting and 4 or 1.5
	local wanted_yaw_rate = max(-yaw_rate_max, min(yaw_rate_max, (yaw - st.yaw) / dt))
	local wanted_shoulder_rate = max(-shoulder_rate_max, min(shoulder_rate_max, (shoulder - st.shoulder) / dt))
	local next_yaw_rate = st.yaw_rate + max(-24 * dt, min(24 * dt, wanted_yaw_rate - st.yaw_rate))
	local next_shoulder_rate = st.shoulder_rate + max(-20 * dt, min(20 * dt, wanted_shoulder_rate - st.shoulder_rate))
	local dy, ds = next_yaw_rate * dt, next_shoulder_rate * dt
	local next_yaw = abs(dy) >= abs(yaw - st.yaw) and yaw or st.yaw + dy
	local next_shoulder = abs(ds) >= abs(shoulder - st.shoulder) and shoulder or st.shoulder + ds
	local old_eye = eye(anchor, base, st.yaw, reach, height, st.shoulder, shoulder_dir)
	local next_eye = eye(anchor, base, next_yaw, reach, height, next_shoulder, shoulder_dir)
	local path_ok
	path_ok, used = transit(owner, query, cast, old_eye, next_eye, radius, available)
	if not path_ok then
		return st.yaw, st.shoulder
	end
	st.yaw, st.shoulder = next_yaw, next_shoulder
	st.yaw_rate, st.shoulder_rate = next_yaw_rate, next_shoulder_rate
	if preferred_clear and abs(next_yaw - requested_yaw) < 1e-4
		and abs(next_shoulder - requested_shoulder) < 1e-3 and st.clear_time >= 0.25 then
		st.constrained = false
	end
	return st.yaw, st.shoulder
end

return M
