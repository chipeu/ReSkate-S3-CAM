-- Acknowledgments never touch camera settings. Esc/Close is not acknowledgment.
local M={}
local C={};C.__index=C
local KEY="release_acknowledgments"
local function version(v)
 return type(v)=="string" and #v<=32 and v:match("^%d+%.%d+%.%d+$")~=nil
end
function M.new(current)
 assert(version(current),"invalid news version")
 local self=setmetatable({current=current,seen={},offered=false},C)
 local ok,saved=pcall(reskate.storage.get,KEY)
 if ok and type(saved)=="table" and saved.schema==1 and type(saved.versions)=="table" then
  local count=0
  for k,v in saved.versions do
   if version(k) and v==true and count<128 then self.seen[k]=true;count+=1 end
  end
 end
 return self
end
function C:pending() return not self.offered and self.seen[self.current]~=true end
function C:offer() self.offered=true end
function C:acknowledge()
 if self.seen[self.current] then return true end
 local copy={}
 local count=0
 for k,v in self.seen do if count<127 then copy[k]=v;count+=1 end end
 copy[self.current]=true
 local ok,result=pcall(reskate.storage.set,KEY,{schema=1,versions=copy})
 if not ok or result==false then return false,"Could not save acknowledgment; try Okay again" end
 self.seen=copy
 return true
end
return M
