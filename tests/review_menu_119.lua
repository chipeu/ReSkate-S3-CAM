-- Render the actual menu widget inventory into a review artifact without launching the game.
local Mock,Store,Menu,Presets=require("mock_reskate"),require("store"),require("menu"),require("presets")
local m=Mock.install()
local st=Store.new();st:load()
Menu.install({store=st,glue={status=function() return "Enabled" end,base_fov=65}})
print("# Dynamic Camera 1.1.9 menu layout\n")
print("Generated from the actual menu widget output. The common controls appear on every tab; conditional speed-based distance controls are listed separately. Low and High retain their existing selectors.\n")
for tab,title in Menu.TABS do
	Menu.state.position_for=nil
	Presets.refresh()
	m.build_page({tabs=tab})
	local ids={}
	print("\n## "..title.."\n")
	for _,w in m.widgets do
		if w.id then ids[w.id]=true end
		if w.kind=="card" then print("\n### "..w.text.."\n")
		elseif w.id and w.id~="tabs" then
			local choices=w.choices and (" ("..table.concat(w.choices," / ")..")") or ""
			print("- "..w.text..choices..(w.help and " — "..w.help or ""))
		elseif w.kind=="info" then print("- "..w.text)
		elseif w.kind=="note" then print("  "..w.text) end
	end
	if tab==2 or tab==4 then
		m.build_page(tab==2 and {tabs=tab,dist_mode=1} or {tabs=tab,man_mode=2})
		print("\n### SPEED-BASED DISTANCE CONTROLS\n")
		for i,w in m.widgets do
			if w.id and not ids[w.id] then
				print("- "..w.text)
				local next=m.widgets[i+1]
				if next and next.kind=="note" then print("  "..next.text) end
			end
		end
	end
end
