local M={}
function M.ease(t) t=math.clamp(t,0,1);return 1-(1-t)^3 end
function M.value(state,key,target,dt,time)
 local previous=state[key]
 if previous==nil then previous=target end
 local value=previous+(target-previous)*(1-math.exp(-math.clamp(dt,0,0.1)/math.max(time or 0.1,0.001)))
 if math.abs(value-target)<0.0001 then value=target end
 state[key]=value;return value
end
return M
