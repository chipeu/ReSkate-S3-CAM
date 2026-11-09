-- Shared runtime clearance for trick yaw and shoulder. Probes use camera.lua's counted cast.
local M = {}
M.TRUE_REACH = 0.75 -- share of the orbit distance at which a measured eye angle can be trusted
M.TRUE_MIN = 0.8 -- m: nearer than this the eye is over the rider and its angle means nothing, however short the arm
M.HOLD_MAX = math.rad(40) -- widest angle a measured eye may be held at
local abs, min, max, sin, cos, sqrt = math.abs, math.min, math.max, math.sin, math.cos, math.sqrt
local create, magnitude = vector.create, vector.magnitude

function M.reset(st)
	st.yaw, st.shoulder, st.yaw_rate, st.shoulder_rate = 0, 0, 0, 0
	st.clear_time, st.side_time = 0, 0
	st.preferred_time, st.eye = 0, nil
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
	requested_yaw, requested_shoulder, radius, ahead, dt, snap, available, shoulder_dir, previous_eye)
	if snap then
		M.reset(st)
		st.yaw, st.shoulder = requested_yaw, requested_shoulder
		return st.yaw, st.shoulder
	end
	if available < 3 then
		st.preferred_time = 0
		return st.yaw, st.shoulder
	end
	local yaw, shoulder = requested_yaw, requested_shoulder
	local ok, used
	local preferred_clear = false
	local old_eye = previous_eye or st.eye or eye(anchor, base, st.yaw, reach, height, st.shoulder, shoulder_dir)
		ok, used = candidate(owner, query, cast, pivot, anchor, base, yaw, reach, height, shoulder, radius, ahead, available, shoulder_dir)
		available -= used
		preferred_clear = ok
		-- Recovery needs continuous evidence for the preferred side. A blocked
		-- or unmeasured frame must not inherit dwell earned on the alternate.
		st.preferred_time = ok and min(st.preferred_time + dt, 1) or 0
		if not ok and used == 0 then return st.yaw, st.shoulder end
		if ok and not st.constrained then
			local wanted_eye = eye(anchor, base, yaw, reach, height, shoulder, shoulder_dir)
			local path_ok
			path_ok, used = transit(owner, query, cast, old_eye, wanted_eye, radius, available)
			if path_ok then
				st.yaw, st.shoulder = yaw, shoulder
				st.eye = wanted_eye
				return yaw, shoulder -- ordinary open-world timing stays exactly as requested
			end
			if used == 0 then return st.yaw, st.shoulder end -- no ray allowance is not clearance
			ok = false
		end
		local saved_yaw = st.yaw
		if (st.constrained or not ok) and reach > 0.05 then
			-- Keep the last physical eye laterally placed when reach or heading
			-- changes. Reusing its old angle would swing a growing orbit into a
			-- parallel wall before the contraction rate can turn around.
			local right = create(cos(base), 0, sin(base))
			local back = create(-sin(base), 0, cos(base))
			local sx = shoulder_dir and shoulder_dir.x or -cos(base - st.yaw)
			local sz = shoulder_dir and shoulder_dir.z or -sin(base - st.yaw)
			local relative = old_eye - anchor - create(sx * st.shoulder, 0, sz * st.shoulder)
			local lateral = relative.x * right.x + relative.z * right.z
			local longitudinal = relative.x * back.x + relative.z * back.z
			if lateral * lateral + longitudinal * longitudinal > 0.01 then
				local measured = math.atan2(lateral, longitudinal)
				-- An eye that collision has pulled in close reads as a huge angle for the same small
				-- sideways offset, and would then be put back out at full reach. Only an eye that is
				-- really out at its distance may report an angle wider than the orbit asked for.
				if lateral * lateral + longitudinal * longitudinal < max(reach * M.TRUE_REACH, M.TRUE_MIN) ^ 2 then
					local limit = max(abs(st.yaw), abs(requested_yaw))
					measured = max(-limit, min(limit, measured))
				end
				-- Holding the eye only keeps it off a wall a little to one side. A wider angle means the
				-- heading has turned away from the eye, as on a halfpipe return: left alone it holds the eye
				-- on the wrong side while the rider passes it. The eye follows the camera's turn past this.
				local hold = max(M.HOLD_MAX, abs(requested_yaw))
				st.yaw = max(-hold, min(hold, measured))
			end
		end
		if ok then
			if st.alternate and st.preferred_time < 0.30 then
				yaw, shoulder = st.yaw, st.shoulder
			else
				st.side_time = 0
			end
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
	-- When clearance contracts, old outward momentum must not take even one
	-- more step into the obstacle while the rate limiter changes direction.
	if contracting and dy * (yaw - st.yaw) <= 0 then next_yaw_rate, dy = 0, 0 end
	if contracting and ds * (shoulder - st.shoulder) <= 0 then next_shoulder_rate, ds = 0, 0 end
	local next_yaw = abs(dy) >= abs(yaw - st.yaw) and yaw or st.yaw + dy
	local next_shoulder = abs(ds) >= abs(shoulder - st.shoulder) and shoulder or st.shoulder + ds
	local next_eye = eye(anchor, base, next_yaw, reach, height, next_shoulder, shoulder_dir)
	local path_ok
	path_ok, used = transit(owner, query, cast, old_eye, next_eye, radius, available)
	if not path_ok then
		available -= used
		-- If a side step is blocked, try the same bounded step toward centre.
		-- This can free a pose carried into a wall by rider movement.
		if available >= 3 and (abs(yaw) > 0.01 or abs(shoulder) > 0.02) then
			local center_yaw = st.yaw + max(-4 * dt, min(4 * dt, -st.yaw))
			local center_shoulder = st.shoulder + max(-4 * dt, min(4 * dt, -st.shoulder))
			local center_eye = eye(anchor, base, center_yaw, reach, height, center_shoulder, shoulder_dir)
			path_ok = transit(owner, query, cast, old_eye, center_eye, radius, available)
			if path_ok then
				st.yaw, st.shoulder = center_yaw, center_shoulder
				st.yaw_rate, st.shoulder_rate = 0, 0
				st.eye = center_eye
				st.clear_time = 0
				return st.yaw, st.shoulder
			end
		end
		st.yaw = saved_yaw
		return st.yaw, st.shoulder
	end
	st.yaw, st.shoulder = next_yaw, next_shoulder
	st.eye = next_eye
	st.yaw_rate, st.shoulder_rate = next_yaw_rate, next_shoulder_rate
	if preferred_clear and abs(next_yaw - requested_yaw) < 1e-4
		and abs(next_shoulder - requested_shoulder) < 1e-3 and st.clear_time >= 0.25 then
		st.constrained = false
		st.alternate = false
	end
	return st.yaw, st.shoulder
end

return M
