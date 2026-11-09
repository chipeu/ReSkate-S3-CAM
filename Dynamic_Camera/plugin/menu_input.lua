-- Dedicated shortcut: raw keys + focus gates, stored independently of presets.
-- The host exposes no API to enumerate other plugins' shortcuts. Refuse known
-- reserved/game-menu keys and our existing combos; let the player choose others.
local M={}
local C={};C.__index=C
local KEY="menu_shortcut"
local reserved={Escape=true,Insert=true,Enter=true,Space=true,Tab=true,
 -- Reserved function keys; preserve the existing shortcut exclusions.
 F5=true,F6=true,F7=true,F8=true,F9=true,F10=true,
 ["Ctrl+Shift+D"]=true,["Ctrl+Shift+V"]=true,["Ctrl+Shift+End"]=true,["Alt+F4"]=true}
local keys={}
for i=0,9 do keys[#keys+1]=tostring(i) end
for i=65,90 do keys[#keys+1]=string.char(i) end
for i=1,12 do keys[#keys+1]="F"..i end
local function code(key)
 -- Never pass a digit string: the native lua_isnumber branch coerces it
 -- into a VK number ("0" becomes invalid VK 0; "1" becomes mouse VK 1).
 if #key==1 then return string.byte(key) end
 local n=key:match("^F(%d+)$")
 return n and 111+tonumber(n) or key
end
function M.valid(binding)
 if type(binding)~="string" or #binding>48 or reserved[binding] then return false end
 local rest=binding
 for _,mod in {"Ctrl","Shift","Alt"} do
  if rest:sub(1,#mod+1)==mod.."+" then rest=rest:sub(#mod+2) end
 end
 if reserved[rest] then return false end
 for _,key in keys do if rest==key then return true end end
 return false
end
function M.new()
 local ok,saved=pcall(reskate.storage.get,KEY)
 return setmetatable({binding=ok and M.valid(saved) and saved or "0",was=false,armed=false},C)
end
function C:set(binding)
 if not M.valid(binding) then return false,"That shortcut is reserved or unsupported" end
 local ok,result=pcall(reskate.storage.set,KEY,binding)
 if not ok or result==false then return false,"Could not save the shortcut" end
 self.binding=binding;self.was=true;self.armed=false
 return true
end
local function down(key)
 local ok,value=pcall(reskate.input.key,code(key))
 return ok and value==true
end
function C:held()
 if self.parsed_binding~=self.binding then
  local mods={Ctrl=false,Shift=false,Alt=false}
  local key
  for part in self.binding:gmatch("[^+]+") do
   if mods[part]~=nil then mods[part]=true else key=part end
  end
  self.parsed_binding,self.mods,self.key=self.binding,mods,key
 end
 if not self.key then return false end
 -- Exact modifiers stop a plain 0 binding firing on Ctrl+0.
 for mod,wanted in self.mods do if down(mod)~=wanted then return false end end
 return down(self.key)
end
function C:pressed(allowed)
 local held=self:held()
 local pressed=allowed and self.armed and held and not self.was
 self.was=held
 if not allowed then self.armed=false elseif not held then self.armed=true end
 return pressed
end
function C:capture()
 if down("Escape") then return nil,"cancel" end
 local prefix=""
 for _,mod in {"Ctrl","Shift","Alt"} do if down(mod) then prefix..=mod.."+" end end
 for _,key in keys do
  if down(key) then
   local binding=prefix..key
   if not M.valid(binding) then return nil,"That shortcut is reserved" end
   return binding
  end
 end
 return nil
end
return M
