-- Camera-only sampling. Physics events and time.now share the host's steady-clock epoch.
local M = {}
local ZERO = vector.create(0,0,0)
local function finite(n) return type(n)=="number" and n-n==0 end

function M.new() return {root=nil,at=0,seen=0,age=0,clock=false} end
function M.reset(c) c.root=nil; c.age=0; c.clock=false end

function M.update(c,now,root,velocity,step,source_at,air,reset)
	if reset then M.reset(c) end
	local changed=c.root==nil or root~=c.root
	if changed then
		c.root,c.seen=root,now
		c.clock=not reset and finite(source_at) and source_at<=now+0.001 and now-source_at<=0.10
		c.at=c.clock and math.min(source_at,now) or now
	end
	-- Predict only while the last sample is fresh. A pause cannot keep moving the view.
	local limit=math.min(1/30,finite(step) and step>0 and step*1.5 or 1/30)
	local age=math.clamp(now-c.at,0,limit)
	if changed and not c.clock then age=0 end
	if now-c.seen>0.10 then age*=math.clamp(1-(now-c.seen-0.10)/0.10,0,1) end
	c.age=age
	local delta=velocity*age
	if air then delta+=vector.create(0,-0.5*10.1*age*age,0) end
	local length=vector.magnitude(delta)
	if length>1 then delta/=length end
	local sum=delta.x+delta.y+delta.z
	if sum-sum~=0 then delta=ZERO end
	return root+delta,delta
end
return M
