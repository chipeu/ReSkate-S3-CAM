-- Offline host contract for the documented custom-screen/drawing APIs.
local M={}
local v=vector.create
function M.enable(m)
 local r=m.reskate
 m.screens={};m.keys={};m.focused=true;m.native_open=false;m.opens=0
 m.cursor={position=v(0,0,0),left=false,wheel=0,over_screen=false}
 r.ui.screen=function(title,build,options)
  assert(not m.screens[title] and #title<=40 and type(build)=="function")
  assert(options.panel==false and options.dock==nil,"custom screen cannot be docked")
  m.screens[title]={build=build,options=options}
 end
 r.ui.open=function(title)
  assert(m.screens[title],"screen was not registered");m.open_screen=title;m.opens+=1
 end
 r.ui.close=function()m.open_screen=nil end
 r.input.key=function(key)
  -- Luau's lua_isnumber accepts numeric strings: the native host tests that
  -- before named keys. In particular string "0" is invalid VK zero.
  local number=type(key)=="number" and key or tonumber(key)
  if number then
   assert(number>=1 and number<=254,"virtual key from 1 to 254")
   local named=(number>=48 and number<=90) and string.char(number) or nil
   return m.keys[number]==true or (named and m.keys[named]==true) or false
  end
  return m.keys[key]==true
 end
 r.input.allowed=function()return m.focused and not m.native_open and m.open_screen==nil and not m.dialog end
 r.input.focus=function()return {focused=m.focused,interface_open=m.native_open or m.open_screen~=nil or m.dialog~=nil,gameplay=not m.native_open}end
 r.input.cursor=function()
  if not m.open_screen then return nil end
  local c=table.clone(m.cursor);m.cursor.wheel=0;return c
 end
 local bind=r.input.bind
 r.input.bind=function(action,key)
  if key==nil then m.binds[action]=false;return true end
  return bind(action,key)
 end
 r.ui.dialog=function(id,body)m.dialog={id=id,body=body};return true end
 r.ui.close_dialog=function()m.dialog=nil end
 r.menu.game=function()return {known=true,open=m.native_open}end
 function m.escape()
  local title=m.open_screen;m.open_screen=nil
  if title then m.fire("screen_closed",title)end
 end
 function m.new_draw(width,height)
  width,height=width or 1920,height or 1080
  local d={commands={},text_bytes=0,depth=0,measure_calls=0}
  local function point(p)return {p.x,p.y}end
  local function record(kind,a,b,style)
   d.commands[#d.commands+1]={kind=kind,a=a,b=b,style=style}
   assert(#d.commands<=4000,"shape budget")
  end
  function d:size()return v(width,height,0)end
  function d:measure(text,style)
   self.measure_calls+=1
   return v(utf8.len(text)*(style.size or 18)*0.48*height/1080,(style.size or 18)*height/1080,0)
  end
  function d:rect(a,b,style)
   assert(b.x>=a.x and b.y>=a.y,"nonnegative rectangle")
   record("rect",point(a),point(b),style)
  end
  function d:line(a,b,style) record("line",point(a),point(b),style) end
  function d:circle(a,radius,style)
   assert(radius>=0,"nonnegative circle");record("circle",point(a),radius,style)
  end
  function d:text(a,text,style)
   assert(#text<=500,"text per shape");self.text_bytes+=#text
   assert(self.text_bytes<=65536,"text budget")
   record("text",point(a),text,style)
  end
  function d:clip(a,b)
   if a then self.depth+=1;record("clip",point(a),point(b))
   else self.depth-=1;assert(self.depth>=0,"balanced clips");record("unclip") end
  end
  return d
 end
 function m.draw(width,height)
  local d=m.new_draw(width,height);m.fire("draw",d);assert(d.depth==0);return d
 end
 return m
end
return M
