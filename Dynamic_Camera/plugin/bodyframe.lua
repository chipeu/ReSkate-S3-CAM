-- Align the final translation with the sampled body instead of independently leading the mesh.
local S3=require("s3math")
local M={}
local UP=vector.create(0,1,0)
local AIM_NEAR,AIM_FAR=0.35,0.9 -- m of horizontal eye distance
function M.new() return {have=false} end
function M.reset(c) c.have=false end
function M.reposition(origin,old,new,forward,up,subject_depth)
	local reach=math.max(vector.dot(origin-old,forward),0.5)
	if subject_depth then reach=math.max(reach,vector.magnitude(origin-old)) end
	local f=S3.normalized(old+forward*reach-new,forward)
	local fallback=S3.normalized(UP-f*vector.dot(UP,f),vector.create(1,0,0))
	return f,S3.normalized(up-f*vector.dot(up,f),fallback)
end
-- Preserve the authored aim through a recovering eye, bounded by the same
-- rider envelope used by the core. A fixed aim point alone does not preserve
-- screen framing when its distance changes.
function M.reframe(origin,old,new,forward,up,bounds,fov,horizontal)
	local f,u=M.reposition(origin,old,new,forward,up,true)
	horizontal=horizontal or S3.normalized(vector.create(f.x,0,f.z),vector.create(0,0,1))
	local span=math.max(vector.dot(origin-new,horizontal),0.01)
	local half=math.rad(0.45*math.clamp(fov or 65,1,170))
	local head=origin+(bounds.head or vector.create(0,bounds.top,0))
	local head_span=math.max(vector.dot(head-new,horizontal),0.01)
	local lo=math.atan2(head.y-new.y,head_span)-half
	local hi=math.atan2(origin.y+bounds.bottom-new.y,span)+half
	local pitch=math.asin(math.clamp(f.y,-1,1))
	pitch=lo<=hi and math.clamp(pitch,lo,hi) or (lo+hi)*0.5
	f=horizontal*math.cos(pitch)+UP*math.sin(pitch)
	return f,S3.normalized(u-f*vector.dot(u,f),UP)
end
-- One horizontal aim on the subject plane, independent of animated root Y.
-- Vertical intent remains with Pop/Crouch and the existing pitch recovery.
function M.horizontal(origin,old,new,authored,aim_point)
 local flat=S3.normalized(vector.create(authored.x,0,authored.z),vector.create(0,0,1))
 local span=math.max(vector.dot(vector.create(origin.x-old.x,0,origin.z-old.z),flat),0.5)
 local point=aim_point or vector.create(old.x,0,old.z)+flat*span
 local towards=vector.create(point.x-new.x,0,point.z-new.z)
 local aimed=S3.normalized(towards,flat)
 -- Right over the aim point the direction to it is noise: a few centimetres
 -- of eye motion would swing the view. Hand the yaw back to the core there.
 local w=math.clamp((vector.magnitude(towards)-AIM_NEAR)/(AIM_FAR-AIM_NEAR),0,1)
 if w>=1 then return aimed end
 return S3.normalized(flat+(aimed-flat)*(w*w*(3-2*w)),flat)
end
function M.with_horizontal(forward,up,horizontal)
 local pitch=math.asin(math.clamp(forward.y,-1,1))
 local f=horizontal*math.cos(pitch)+UP*math.sin(pitch)
 return f,S3.normalized(up-f*vector.dot(up,f),UP)
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
