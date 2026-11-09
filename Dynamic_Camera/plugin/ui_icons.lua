-- Original small line icons, one stroke/size system, no font/icon dependency.
local M={}
local paths={
 presets={{2,3,14,3,14,7,2,7,2,3},{2,10,14,10,14,14,2,14,2,10}},
 camera={{1,5,15,5,15,14,1,14,1,5},{4,5,5,2,11,2,12,5}},
 follow={{2,13,2,8,12,8,12,2},{8,5,12,1,16,5}},
 tricks={{8,1,15,8,8,15,1,8,8,1},{1,2,4,2},{12,14,15,14}},
 air={{1,14,5,14,10,4,15,4},{7,5,10,2,13,5}},
 effects={{1,3,15,3},{1,8,15,8},{1,13,15,13}},
 offboard={{8,5,8,10,4,15},{8,10,13,15},{3,7,8,6,13,9}},
 advanced={{3,1,3,15},{8,1,8,15},{13,1,13,15}},
 news={{3,1,11,1,14,4,14,15,3,15,3,1},{6,6,11,6},{6,9,11,9},{6,12,10,12}},
 close={{3,3,13,13},{13,3,3,13}},
 down={{3,6,8,11,13,6}},up={{3,10,8,5,13,10}},
 resize={{5,3,5,13},{9,1,9,15},{13,3,13,13}},
}
function M.draw(c,name,x,y,size,colour)
 local k=size/16
 for _,path in paths[name] or {} do
  for i=1,#path-2,2 do c:line(x+path[i]*k,y+path[i+1]*k,x+path[i+2]*k,y+path[i+3]*k,colour,1.5) end
 end
 if name=="camera" then c:circle(x+8*k,y+9.5*k,3*k,colour,false)
 elseif name=="offboard" then c:circle(x+8*k,y+2*k,2*k,colour,false)
 elseif name=="effects" then
  for _,p in {{5,3},{11,8},{7,13}} do c:circle(x+p[1]*k,y+p[2]*k,2*k,colour,true) end
 elseif name=="advanced" then
  for _,p in {{3,5},{8,11},{13,6}} do c:circle(x+p[1]*k,y+p[2]*k,2*k,colour,true) end
 end
end
return M
