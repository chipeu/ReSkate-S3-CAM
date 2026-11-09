-- Width is a UI preference, independent of camera tuning and presets.
local M={};local C={};C.__index=C
local KEY="menu_layout"
function M.new()
 local ok,saved=pcall(reskate.storage.get,KEY)
 local width=ok and type(saved)=="table" and saved.schema==1 and saved.width or nil
 if type(width)~="number" or width-width~=0 then width=960 end
 return setmetatable({width=math.clamp(width,760,1440),dirty=false},C)
end
function C:set(width,available)
 self.width=math.clamp(width,math.min(760,available),math.min(1440,available));self.dirty=true
end
function C:save()
 if not self.dirty then return true end
 local ok,value=pcall(reskate.storage.set,KEY,{schema=1,width=self.width})
 if ok and value~=false then self.dirty=false;return true end
 return false
end
return M
