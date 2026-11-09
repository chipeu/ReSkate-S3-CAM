-- An adapter over the existing menu builder. IDs, values, conversions and
-- persistence remain owned by menu.lua; this module only describes widgets.
local M={}
function M.new(changes,chosen)
 local self={rows={},changes=changes or {},chosen=chosen,custom=true}
 local function row(kind,id,fields)
  fields.kind,fields.id=kind,id;self.rows[#self.rows+1]=fields
  return fields
 end
 local function changed(id,value)
  local v=self.changes[id]
  if v==nil then return value end
  return v
 end
 function self:tabs(id,names,value) self.tab_names=names;return self.chosen or changed(id,value) end
 function self:card(title,subtitle) row("card",nil,{text=title,help=subtitle}) end
 function self:note(text) row("note",nil,{text=text}) end
 function self:warn(text) row("warn",nil,{text=text}) end
 function self:info(label,value) row("info",nil,{text=label,value=tostring(value)}) end
 function self:button(id,text,primary)
  row("button",id,{text=text,primary=primary});return changed(id,false)==true
 end
 function self:toggle(id,text,value,help)
  row("toggle",id,{text=text,value=value,help=help});return changed(id,value)
 end
 function self:slider(id,text,value,lo,hi,format)
  row("slider",id,{text=text,value=value,min=lo,max=hi,format=format})
  return math.clamp(changed(id,value),lo,hi)
 end
 function self:dropdown(id,text,choices,value,help)
  row("dropdown",id,{text=text,choices=choices,value=value,help=help})
  return math.clamp(changed(id,value),1,#choices)
 end
 return self
end
return M
