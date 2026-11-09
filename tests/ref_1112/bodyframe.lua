-- Filter the camera's offset, not the native skater's position. Align the final
-- translation with the sampled body instead of independently leading the mesh.
local S3=require("s3math")
local M={}
local UP=vector.create(0,1,0)
function M.new() return {have=false} end
function M.reset(c) c.have=false end
function M.reposition(origin,old,new,forward,up)
	local reach=math.max(vector.dot(origin-old,forward),0.5)
	local f=S3.normalized(old+forward*reach-new,forward)
	local fallback=S3.normalized(UP-f*vector.dot(UP,f),vector.create(1,0,0))
	return f,S3.normalized(up-f*vector.dot(up,f),fallback)
end
function M.update(c,now,origin,eye,forward,up,delta,path,instant)
	local aligned=eye-delta
	local offset=aligned-origin
	local dt=c.at and math.clamp(now-c.at,0,0.1) or 0
	if not c.have or c.path~=path or instant or vector.magnitude(offset-(c.offset or offset))>0.25
		or vector.magnitude(origin-(c.origin or origin))>4 then
		c.offset=offset
	else
		c.offset+=(offset-c.offset)*(1-math.exp(-dt/0.035))
	end
	c.have,c.at,c.path,c.origin=true,now,path,origin
	local p=origin+c.offset
	local f,u=M.reposition(origin,aligned,p,forward,up)
	return p,f,u
end
return M
