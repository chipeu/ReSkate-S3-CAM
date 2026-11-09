-- Align the final translation with the sampled body instead of independently leading the mesh.
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
	-- The camera rig already eases its pose. A second offset filter, fed with
	-- the final corrected output, fights that rig and can amplify recovery bob.
	c.have,c.at,c.path,c.origin,c.offset=true,now,path,origin,offset
	return aligned,forward,up
end
return M
