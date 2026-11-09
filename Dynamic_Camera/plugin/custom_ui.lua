-- Screen lifecycle and wiring. Camera settings are edited only by Menu.build.
local Model,View=require("ui_model"),require("ui_view")
local Input,News=require("menu_input"),require("version_news")
local Notes=require("release_notes")
local Layout=require("ui_layout")
local M={};local C={};C.__index=C
M.TITLE="Dynamic Camera controls"
M.ACTION="Open camera menu"
function M.new(deps)
 return setmetatable({store=deps.store,menu=deps.menu,version=deps.version,input=Input.new(),
  news=News.new(Notes[1] and Notes[1].version or deps.version),notes=Notes,view=View.new(),layout=Layout.new(),available=false,open=false,
  tab=1,mode="menu",changes={},next_build=0,started=reskate.time.now(),capture=false},C)
end
function C:install()
 local ok,why=pcall(reskate.ui.screen,M.TITLE,function() end,{panel=false})
 self.available=ok and why~=false
 if not self.available then
  reskate.log("dyncam: custom UI unavailable; the native menu remains available", "warn")
  return
 end
 -- Optional secondary entry uses the host's persistent Binds page. It has
 -- no default, so it cannot duplicate the dedicated, configurable shortcut.
 pcall(reskate.input.bind,M.ACTION)
end
function C:rebuild()
 local changes=self.changes;self.changes={}
 local model=Model.new(changes,self.tab)
 self.menu.state.tab=self.tab
 self.menu.build(model)
 self.model=model
 self.next_build=reskate.time.now()+100
end
function C:show(mode,manual)
 if not self.available then return false end
 local ok,result=pcall(reskate.ui.open,M.TITLE)
 if not ok or result==false then return false end
 self.open=true;self.mode=mode or "menu";self.manual_news=manual==true
 self.last_cursor_at=reskate.time.now()
 self.error=nil;self.suspended=false;self.capture=false
 self.input.was=true;self.input.armed=false
 self.view:reset(true)
 self:rebuild()
 return true
end
function C:close()
 if self.open then pcall(reskate.ui.close) end
 self:closed()
end
function C:closed()
 local was_open=self.open
 if self.view.resizing then self.layout:save() end
 self.open=false;self.capture=false;self.suspended=false;self.changes={}
 self.input.armed=false;self.view:reset()
 if was_open then self.view.close_from=self.view.opacity or 1;self.view.close_at=reskate.time.now() end
end
function C:toggle()
 if self.open then self:close() else self:show("menu") end
end
function C:select_tab(tab)
 self.tab=math.clamp(tab,1,8);self.mode="menu";self.error=nil
 self.view.page_at=reskate.time.now()
 self:rebuild()
end
function C:changelogs()
 if self.open then
  self.mode="news";self.manual_news=true;self.view.scroll.news=0
 else self:show("news",true) end
end
function C:okay()
 local ok,why=true,nil
 if #self.notes>0 then ok,why=self.news:acknowledge() end
 if not ok then self.error=why;return end
 if self.manual_news then self.mode="menu";self:rebuild() else self:close() end
end
function C:change(id,value)
 if id=="ui_changelogs" then self:changelogs()
 elseif id=="ui_shortcut" then
  if not self.open then self:show("menu");self:select_tab(8) end
  self.capture=true;self.capture_ready=false;self.error=nil
 elseif id=="ui_open_custom" then self:show("menu")
 else self.changes[id]=value;self.next_build=0 end
end
function C:tick()
 if not self.available or self.open then return end
 local ok,allowed=pcall(reskate.input.allowed)
 allowed=ok and allowed==true
 if self.input:pressed(allowed) then self:show("menu");return end
 -- Never open a screen automatically. Only explicit user actions may open it.
end
function C:draw(d)
 if not self.available then return end
 if not self.open then
  if self.view.close_at and reskate.time.now()-self.view.close_at<120 then
   self.view:draw(d,{position=vector.create(-1,-1,0),left=false,wheel=0},false,self)
  end
  return
 end
 local ok,cursor=pcall(reskate.input.cursor)
 local has_cursor=ok and cursor~=nil
 if has_cursor then self.last_cursor_at=reskate.time.now()
 elseif reskate.time.now()-(self.last_cursor_at or self.started)>1000 then
  self:close()
  pcall(reskate.ui.toast,"Custom menu closed because input was unavailable","warn")
  return
 else
  -- Opening a screen and publishing its pointer occur in different host
  -- phases. Draw immediately without accepting input during that handoff.
  cursor={position=vector.create(-1,-1,0),left=false,wheel=0}
 end
 local focused,focus=pcall(reskate.input.focus)
 local active=has_cursor and focused and focus.focused==true and not self.suspended
 -- Our registered screen owns input even when opened above a native page.
 -- Closed-menu polling still uses input.allowed(); preset dialogs suspend us.
 if self.capture and active then
  if not self.capture_ready then
   -- Opening mouse/Enter must be released before recording another key.
   local enter=reskate.input.key("Enter")
   if not cursor.left and not enter and not self.input:held() then self.capture_ready=true end
  else
   local binding,why=self.input:capture()
   if why=="cancel" then self.capture=false
   elseif binding then
    local saved,error_text=self.input:set(binding)
    self.error=saved and nil or error_text;self.capture=not saved
   elseif why then self.error=why end
  end
 elseif active and self.input:pressed(true) then
  self:close();return
 elseif not active then self.input:pressed(false) end
 if reskate.time.now()>=self.next_build then self:rebuild() end
 self.view:draw(d,cursor,active and not self.capture,self)
end
return M
