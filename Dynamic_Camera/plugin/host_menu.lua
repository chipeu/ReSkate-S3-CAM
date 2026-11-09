-- API 1 menu ownership: menu.state (2.1.4-3+) also covers ReSkate/replays.
-- Plugin-owned custom screens are intentionally separate: their camera preview stays live.
local M={}
function M.covered(state)
 return type(state)~="table" or state.known~=true or state.pause==true
  or state.reskate==true or state.replay_editor==true
end
function M.blocked()
 local menu=reskate.menu
 if menu and type(menu.state)=="function" then
  local ok,state=pcall(menu.state)
  -- Unknown is not a closed menu. Do not acquire over loading/replay UI.
  return not ok or M.covered(state)
 end
 -- Older API 1 hosts only expose the game's pause menu. Retain that path.
 if menu and type(menu.game)=="function" then
  local ok,state=pcall(menu.game)
  return not ok or (type(state)=="table" and (state.known==false or state.open==true))
 end
 return false
end
return M
