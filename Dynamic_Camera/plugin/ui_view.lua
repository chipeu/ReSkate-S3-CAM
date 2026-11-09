-- Reference-led custom controls: responsive cards, original icons and bounded motion.
local Theme,Motion,Icons=require("ui_theme"),require("ui_motion"),require("ui_icons")
local M={};local C={};C.__index=C
local v=vector.create
local names={"Presets","Camera","Follow & movement","Tricks & close-ups","Air & landing","Camera effects","Off the board","Advanced settings"}
local symbols={"presets","camera","follow","tricks","air","effects","offboard","advanced"}
local function sentence(s)
 if s=="DYNAMIC CAMERA" then return "Session" end
 return s==string.upper(s) and s:sub(1,1)..string.lower(s:sub(2)) or s
end
local function tint(colour,alpha)
 local a=#colour==9 and tonumber(colour:sub(8,9),16) or 255
 return colour:sub(1,7)..string.format("%02X",math.floor(a*math.clamp(alpha,0,1)+0.5))
end
function M.new()
 return setmetatable({scroll={},hits={},keys={},key_armed={},anim={},was=false,measure_cache={},measure_count=0},C)
end
function C:reset(animate)
 self.was=true;self.drag=nil;self.dropdown=nil;self.focus=nil;self.keys={};self.key_armed={};self.pointer_armed=false
 self.resizing=nil
 if animate then self.open_at=reskate.time.now();self.close_at=nil;self.opacity=0 end
end
function C:frame(d,cursor,active,controller)
 local size=d:size();local dpi=math.max(size.y/1080,0.01)
 local scale=math.max(0.25,math.min(dpi,size.x/960));self.scale=scale
 local now=reskate.time.now()
 local dt=math.clamp((now-(self.at or now))/1000,0,0.1);self.at=now
 local opening=self.open_at and Motion.ease((now-self.open_at)/180) or 1
 local alpha=self.close_at and (self.close_from or 1)*(1-Motion.ease((now-self.close_at)/120)) or opening
 self.opacity=alpha
 local mx,my=cursor.position.x/scale,cursor.position.y/scale
 local available=size.x/scale-32
 local width=math.clamp(controller.layout.width,math.min(760,available),math.min(1440,available))
 if self.resizing and not active then
  controller.layout:save();self.resizing=nil
 elseif self.resizing and active and cursor.left then
  controller.layout:set(self.resizing.width+mx-self.resizing.x,available)
  width=controller.layout.width
 elseif self.resizing and not cursor.left then
  if not controller.layout:save() then controller.error="Could not save menu width" end
  self.resizing=nil
 end
 if not active then self.pointer_armed=false elseif not cursor.left then self.pointer_armed=true end
 local c={d=d,k=scale,dt=dt,alpha=alpha,x=16-8*(1-opening),y=32,w=width,h=size.y/scale-64,
  side=math.clamp(width*0.245,200,264),text_scale=math.clamp(math.sqrt(width/960),0.90,1.20),
  mx=mx,my=my,down=active and cursor.left==true,
  click=active and self.pointer_armed and cursor.left==true and not self.was,wheel=active and (cursor.wheel or 0) or 0}
 c.font_factor=scale/dpi
 self.was=c.down;if not c.down then self.drag=nil end
 self.hits={}
 function c:rect(x,y,w,h,colour,rounding)
  if self.clip then
   local right,down=math.min(x+w,self.clip[3]),math.min(y+h,self.clip[4])
   x,y=math.max(x,self.clip[1]),math.max(y,self.clip[2]);w,h=right-x,down-y
  end
  if w<=0 or h<=0 then return end
  d:rect(v(x*scale,y*scale,0),v((x+w)*scale,(y+h)*scale,0),
   {colour=tint(colour,self.alpha),fill=true,rounding=(rounding or 0)*self.font_factor})
 end
 function c:line(x1,y1,x2,y2,colour,stroke)
  d:line(v(x1*scale,y1*scale,0),v(x2*scale,y2*scale,0),{colour=tint(colour,self.alpha),thickness=(stroke or 1.5)*self.font_factor})
 end
 function c:circle(x,y,r,colour,fill)
  d:circle(v(x*scale,y*scale,0),r*scale,{colour=tint(colour,self.alpha),fill=fill,thickness=1.5*self.font_factor})
 end
 function c:text(x,y,text,colour,font_size,align,font)
  d:text(v(x*scale,y*scale,0),tostring(text):sub(1,500),{font=font or Theme.font,
   size=(font_size or Theme.size)*self.font_factor,colour=tint(colour or Theme.text,self.alpha),shadow=false,align=align or "left"})
 end
 local owner,cache=self,self.measure_cache
 function c:measure(text,font_size,font)
  local size=(font_size or Theme.size)*self.font_factor
  local key=(font or Theme.font)..string.format(":%.4f:%.4f:",size,scale)..text
  local cached=cache[key]
  if cached then return cached end
  if owner.measure_count>=2048 then owner.measure_cache={};cache=owner.measure_cache;owner.measure_count=0 end
  local measured=d:measure(text,{font=font or Theme.font,size=size}).x/scale
  cache[key]=measured;owner.measure_count+=1
  return measured
 end
 function c:fit(text,width,font_size,font)
  if self:measure(text,font_size,font)<=width then return text end
  local count=utf8.len(text) or #text
  while count>0 do
   local offset=utf8.offset(text,count+1) or #text+1
   local cut=text:sub(1,offset-1).."..."
   if self:measure(cut,font_size,font)<=width then return cut end
   count-=1
  end
  return "..."
 end
 function c:lines(text,width,font_size,font)
  local lines,line={},""
  for word in tostring(text):gmatch("%S+") do
   local next_line=line=="" and word or line.." "..word
   if line~="" and self:measure(next_line,font_size,font)>width then lines[#lines+1]=line;line=word else line=next_line end
  end
  if line~="" then lines[#lines+1]=line end
  return lines
 end
 function c:over(x,y,w,h)
  if self.clip and (self.my<self.clip[2] or self.my>=self.clip[4] or self.mx<self.clip[1] or self.mx>=self.clip[3]) then return false end
  return self.mx>=x and self.mx<x+w and self.my>=y and self.my<y+h
 end
 c:rect(c.x,c.y,c.w,c.h,Theme.background,3)
 c:rect(c.x,c.y,c.side,c.h,Theme.sidebar_colour)
 c:rect(c.x,c.y,c.w,88,Theme.header)
 c:rect(c.x+c.side,c.y+88,1,c.h-88,Theme.line)
 self.metrics={width=width,text_scale=c.text_scale,scale=scale,x=c.x,y=c.y,h=c.h}
 return c
end
function C:hit(c,id,x,y,w,h,label,primary,icon)
 local over=c:over(x,y,w,h)
 self.hits[#self.hits+1]={id=id,x=x,y=y,w=w,h=h,enabled=true}
 local hover=Motion.value(self.anim,"hover:"..id,over and 1 or 0,c.dt,0.08)
 if primary then c:rect(x,y,w,h,Theme.accent,3)
 else c:rect(x,y,w,h,Theme.surface,3);c:rect(x,y,w,h,tint(Theme.hover,hover),3) end
 if self.focus==id then c:rect(x,y,2,h,Theme.accent_light) end
 if icon then Icons.draw(c,icon,x+10,y+(h-16)/2,16,Theme.text) end
 if label then c:text(x+(icon and 34 or 12),y+(h-17)/2,c:fit(label,w-(icon and 44 or 24),17),Theme.text,17) end
 return (over and c.click) or (self.focus==id and self.enter)
end
function C:keyboard(active)
 local pressed={}
 for _,key in {"Tab","Enter","Left","Right","Up","Down","PageUp","PageDown"} do
  local ok,value=pcall(reskate.input.key,key);value=ok and value==true
  if not active then self.key_armed[key]=false elseif not value then self.key_armed[key]=true end
  pressed[key]=active and self.key_armed[key] and value and not self.keys[key];self.keys[key]=value
 end
 self.enter=pressed.Enter;return pressed
end
function C:chrome(c,controller)
 c:text(c.x+28,c.y+14,"DYNAMIC",Theme.accent,29,nil,"heading")
 c:text(c.x+28,c.y+43,"CAMERA",Theme.accent,29,nil,"heading")
 local tools_x=c.x+c.w-312
 if self:hit(c,"header_news",tools_x,c.y+24,136,36,"Changelogs",false,"news") then controller:changelogs() end
 c:text(c.x+c.w-84,c.y+20,controller.version,Theme.accent_light,23,"right","bold")
 c:text(c.x+c.w-84,c.y+48,"TEST",Theme.muted,12,"right")
 if self:hit(c,"close",c.x+c.w-60,c.y+24,36,36,nil,false) then controller:close() end
 Icons.draw(c,"close",c.x+c.w-50,c.y+34,16,Theme.secondary)
 local selected_y=c.y+116+(controller.tab-1)*56
 local nav=Motion.value(self.anim,"nav",selected_y,c.dt,0.10)
 if controller.mode=="menu" then
  c:rect(c.x+12,nav,c.side-24,48,Theme.accent,2)
  c:rect(c.x+c.side-3,nav+6,3,36,Theme.accent_light)
 end
 for i,name in names do
  local y=c.y+116+(i-1)*56
  local hover=c:over(c.x+12,y,c.side-24,48)
  self.hits[#self.hits+1]={id="tab"..i,x=c.x+12,y=y,w=c.side-24,h=48,enabled=true}
  local h=Motion.value(self.anim,"navhover"..i,hover and 1 or 0,c.dt,0.10)
  if i~=controller.tab or controller.mode~="menu" then c:rect(c.x+12,y,c.side-24,48,tint(Theme.hover,h*0.8),2) end
  local chosen=i==controller.tab and controller.mode=="menu"
  Icons.draw(c,symbols[i],c.x+24,y+15,18,chosen and Theme.text or Theme.secondary)
  local lines=c:lines(name,c.side-76,17.5,"bold")
  local ty=y+(48-#lines*20)/2
  for _,line in lines do c:text(c.x+56,ty,line,chosen and Theme.text or Theme.secondary,17.5,nil,"bold");ty+=20 end
  if (hover and c.click) or (self.focus=="tab"..i and self.enter) then controller:select_tab(i);self.dropdown=nil end
 end
 c:rect(c.x+24,c.y+c.h-100,c.side-48,1,Theme.line)
 c:text(c.x+28,c.y+c.h-82,"Menu shortcut",Theme.muted,14)
 c:rect(c.x+28,c.y+c.h-54,math.max(44,c:measure(controller.input.binding,16)+20),28,Theme.surface,3)
 c:text(c.x+38,c.y+c.h-50,controller.input.binding,Theme.text,16)
end
local function row_layout(c,row,width)
 local fs=Theme.size*c.text_scale;local small=Theme.small*c.text_scale
 local label_width=row.kind=="button" and width-32 or width*0.54-16
 local labels=c:lines(row.text or "",label_width,fs,"bold")
 local h=math.max(48,#labels*(fs+4)+20)
 if row.kind=="slider" then h=math.max(72,h) end
 if row.kind=="note" or row.kind=="warn" then
  return {row=row,labels=c:lines(row.text,width-32,small),height=#c:lines(row.text,width-32,small)*(small+7)+12}
 elseif row.kind=="info" then return {row=row,height=32} end
 local description=row.help
 -- Option lists explain the selected option; the other descriptions remain
 -- in the shared native menu. Avoid repeating every choice under each row.
 if row.kind=="dropdown" and description then
  local prefix=row.choices[row.value]..": "
  local first=description:find(prefix,1,true)
  if first then
   local last=#description+1
   for _,choice in row.choices do
    local at=description:find(choice..": ",first+#prefix,true)
    if at then last=math.min(last,at) end
   end
   description=description:sub(first+#prefix,last-1):gsub("%s+$","")
  end
 end
 local help=description and c:lines(description,width-32,small) or {}
 return {row=row,labels=labels,help=help,height=h+#help*(small+6),control_height=h}
end
function C:groups(c,rows,width)
 local groups,current={}
 for _,row in rows do
  if row.kind=="card" then
   current={title=row.text~="DYNAMIC CAMERA" and sentence(row.text) or nil,compact=row.text=="DYNAMIC CAMERA",items={},height=row.text=="DYNAMIC CAMERA" and 12 or 36}
   groups[#groups+1]=current
  else
   if not current then current={title=nil,items={},height=16};groups[#groups+1]=current end
   local item=row_layout(c,row,width)
   if current.compact then
    item.help={};item.height=row.kind=="info" and 28 or 44;item.control_height=item.height
   end
   current.items[#current.items+1]=item;current.height+=item.height
  end
 end
 for _,group in groups do group.height+=12 end
 return groups
end
function C:control(c,item,x,y,width,top,bottom,controller,keys)
 local row=item.row;local fs=Theme.size*c.text_scale;local small=Theme.small*c.text_scale
 if row.kind=="note" or row.kind=="warn" then
  for _,line in item.labels do if y+small>=top and y<bottom then c:text(x+16,y+4,line,row.kind=="warn" and Theme.danger or Theme.secondary,small) end;y+=small+7 end
  return
 end
 if row.kind=="info" then
  if y>=top and y+32<=bottom then
   c:text(x+16,y+5,row.text,Theme.muted,small)
   c:text(x+width-16,y+5,c:fit(row.value,width*0.65,small),Theme.secondary,small,"right")
  end
  return
 end
 local h=item.control_height
 local visible=y>=top and y+h<=bottom
 local field_x=x+width*0.58;local field_w=width*0.42-16
 if visible then
  local hover=not self.dropdown and not self.resizing and c:over(x+8,y,width-16,h)
  self.hits[#self.hits+1]={id=row.id,x=x+8,y=y,w=width-16,h=h,row=row,enabled=true}
  local amount=Motion.value(self.anim,"row:"..row.id,hover and 1 or 0,c.dt,0.09)
  c:rect(x+8,y,width-16,h,tint(Theme.hover,amount*0.45),3)
  if self.focus==row.id then c:rect(x+8,y+4,2,h-8,Theme.accent_light) end
  if row.kind=="button" then
   if self:hit(c,row.id,x+16,y+4,width-32,36,row.text,row.primary) and not self.dropdown then controller:change(row.id,true) end
  else
   for i,line in item.labels do c:text(x+16,y+12+(i-1)*(fs+4),line,Theme.text,fs,nil,"bold") end
   local pressed=not self.dropdown and ((hover and c.click) or (self.focus==row.id and keys.Enter))
   if row.kind=="toggle" then
    local t=Motion.value(self.anim,"toggle:"..row.id,row.value and 1 or 0,c.dt,0.07)
    local tx,ty=x+width-68,y+12
    c:rect(tx,ty,48,25,Theme.rail,3);c:rect(tx,ty,48,25,tint(Theme.accent,t),3)
    c:rect(tx+4+23*t,ty+4,17,17,Theme.text,2)
    if pressed then controller:change(row.id,not row.value) end
   elseif row.kind=="dropdown" then
    c:rect(field_x,y+7,field_w,34,Theme.surface,3)
    c:text(field_x+10,y+13,c:fit(row.choices[row.value],field_w-38,fs-1),Theme.text,fs-1)
    Icons.draw(c,"down",field_x+field_w-24,y+16,14,Theme.secondary)
    if pressed then self.dropdown={row=row,x=field_x,y=y+h,w=field_w,scroll=math.clamp(row.value-4,0,math.max(0,#row.choices-6)),opening=true} end
    if self.focus==row.id and not self.dropdown and (keys.Left or keys.Right) then controller:change(row.id,math.clamp(row.value+(keys.Left and -1 or 1),1,#row.choices)) end
   elseif row.kind=="slider" then
    local value=string.format(row.format or "%.2f",row.value)
    local badge=math.max(52,c:measure(value,small)+18)
    c:rect(field_x+field_w-badge,y+7,badge,25,Theme.surface,3)
    c:text(field_x+field_w-9,y+10,value,Theme.text,small,"right")
    local rail_y=y+43;local rail_x=field_x+4;local rail_w=field_w-8
    local target=(row.value-row.min)/(row.max-row.min)
    local ratio=Motion.value(self.anim,"slider:"..row.id,target,c.dt,0.075)
    if self.drag==row.id then ratio=target;self.anim["slider:"..row.id]=target end
    c:rect(rail_x,rail_y,rail_w,12,Theme.rail,4)
    c:rect(rail_x,rail_y,rail_w*ratio,12,Theme.accent,4)
    c:circle(rail_x+rail_w*ratio,rail_y+6,6.5,Theme.text,true)
    if not self.dropdown and c:over(field_x,y,field_w,h) and c.click then self.drag=row.id;self.focus=row.id end
    if self.drag==row.id and c.down then controller:change(row.id,row.min+math.clamp((c.mx-rail_x)/rail_w,0,1)*(row.max-row.min))
    elseif self.focus==row.id and (keys.Left or keys.Right) then controller:change(row.id,math.clamp(row.value+(keys.Left and -1 or 1)*(row.max-row.min)/100,row.min,row.max)) end
   end
  end
  if hover and c.click then self.focus=row.id end
 end
 local hy=y+h
 for _,line in item.help or {} do
  if hy+small>=top and hy<bottom then c:text(x+16,hy,line,Theme.secondary,small) end;hy+=small+6
 end
end
function C:draw(d,cursor,active,controller)
 local c=self:frame(d,cursor,active,controller);local keys=self:keyboard(active)
 local previous_focus=self.focus
 self:chrome(c,controller)
 local x=c.x+c.side+24;local width=c.w-c.side-48
 local top,bottom=c.y+108,c.y+c.h-58
 local page=controller.mode=="news" and "news" or controller.tab
 local groups
 if controller.mode=="news" then
  local rows={}
  for _,release in controller.notes do
   rows[#rows+1]={kind="card",text=release.version.." / "..release.title}
   for _,section in release.sections do
    rows[#rows+1]={kind="note",text=section[1]}
    for _,line in section[2] do rows[#rows+1]={kind="note",text=line} end
   end
  end
  if #rows==0 then
   rows={{kind="card",text="Public changelogs"},{kind="note",text="No public release notes are available yet."}}
  end
  groups=self:groups(c,rows,width)
 else groups=self:groups(c,controller.model and controller.model.rows or {},width) end
 local total=0;for _,group in groups do total+=group.height+16 end
 local maximum=math.max(0,total-(bottom-top))
 local scroll=self.scroll[page] or 0
 if c:over(x,top,width,bottom-top) and not self.dropdown and not self.resizing then scroll-=c.wheel*80 end
 if keys.PageDown then scroll+=240 elseif keys.PageUp then scroll-=240 end
 scroll=math.clamp(scroll,0,maximum);self.scroll[page]=scroll
 local fade=self.page_at and Motion.ease((reskate.time.now()-self.page_at)/140) or 1
 local y=top-scroll+6*(1-fade)
 local alpha=c.alpha;c.alpha*=0.45+0.55*fade
 d:clip(v(x*c.k,top*c.k,0),v((x+width)*c.k,bottom*c.k,0));c.clip={x,top,x+width,bottom}
 for _,group in groups do
  if y+group.height>=top and y<=bottom then
   c:rect(x,y,width,group.height,Theme.card,4)
   if group.title and y+44>=top and y<bottom then
    c:rect(x+16,y+17,3,15,Theme.accent)
    c:text(x+28,y+12,c:fit(group.title,width-44,17*c.text_scale),Theme.secondary,17*c.text_scale,nil,"bold")
   end
   local row_y=y+(group.title and 36 or 12)
   for _,item in group.items do self:control(c,item,x,row_y,width,top,bottom,controller,keys);row_y+=item.height end
  end
  y+=group.height+16
 end
 c.clip=nil;d:clip();c.alpha=alpha
 if maximum>0 then
  local travel=bottom-top;local thumb=math.max(28,travel*travel/(travel+maximum))
  c:rect(c.x+c.w-14,top,4,travel,Theme.rail,2)
  c:rect(c.x+c.w-14,top+(travel-thumb)*scroll/maximum,4,thumb,Theme.accent,2)
 end
 if controller.mode=="news" then
  c:text(x,c.y+c.h-35,"Public release history",Theme.muted,14)
  if self:hit(c,"news_okay",x+width-120,c.y+c.h-46,120,34,"Okay",true) then controller:okay() end
 else
  c:text(x,c.y+c.h-35,"Tab: focus   Arrows: adjust   Drag right edge: resize",Theme.muted,13)
  if self:hit(c,"page_up",c.x+c.w-108,c.y+c.h-46,32,32,nil,false) then self.scroll[page]=math.max(0,scroll-240) end
  Icons.draw(c,"up",c.x+c.w-100,c.y+c.h-38,16,Theme.secondary)
  if self:hit(c,"page_down",c.x+c.w-68,c.y+c.h-46,32,32,nil,false) then self.scroll[page]=math.min(maximum,scroll+240) end
  Icons.draw(c,"down",c.x+c.w-60,c.y+c.h-38,16,Theme.secondary)
 end
 if self.dropdown then
  local pop=self.dropdown;local click=c.click;if pop.opening then c.click=false end
  local count=math.min(6,#pop.row.choices);local h=count*38;local py=math.clamp(pop.y,top,bottom-h)
  c:rect(pop.x-2,py-2,pop.w+4,h+4,Theme.line,3);c:rect(pop.x,py,pop.w,h,Theme.surface,3)
  if c:over(pop.x,py,pop.w,h) then pop.scroll=math.clamp(pop.scroll-c.wheel,0,#pop.row.choices-count) end
  for i=1,count do
   local choice=i+pop.scroll
   if self:hit(c,"choice"..choice,pop.x,py+(i-1)*38,pop.w,38,pop.row.choices[choice],choice==pop.row.value) then controller:change(pop.row.id,choice);self.dropdown=nil end
  end
  if not pop.opening and c.click and not c:over(pop.x,py,pop.w,h) then self.dropdown=nil end
  pop.opening=false;c.click=click
 end
 local edge=c:over(c.x+c.w-8,c.y+88,16,c.h-88)
 local grip=Motion.value(self.anim,"grip",(edge or self.resizing) and 1 or 0,c.dt,0.08)
 c:rect(c.x+c.w-3,c.y+88,3,c.h-88,tint(Theme.accent,0.25+grip*0.75))
 Icons.draw(c,"resize",c.x+c.w-13,c.y+c.h*0.5-12,20,grip>0.2 and Theme.accent_light or Theme.muted)
 self.hits[#self.hits+1]={id="resize",x=c.x+c.w-8,y=c.y+88,w=16,h=c.h-88,enabled=true}
 if active and edge and c.click and not self.dropdown then self.resizing={x=c.mx,width=c.w};self.drag=nil end
 if controller.error then
  c:rect(x,c.y+c.h-78,width,24,Theme.header)
  c:text(x+8,c.y+c.h-74,c:fit(controller.error,width-16,14),Theme.danger,14)
 end
 if keys.Tab then
  local next_index=1
  for i,hit in self.hits do if hit.id==previous_focus then next_index=i+1 end end
  self.focus=self.hits[next_index] and self.hits[next_index].id or "close"
 end
 return c
end
return M
