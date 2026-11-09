"""Apply reviewed display wording. Widget IDs, settings fields and numeric controls are untouched."""
from pathlib import Path
import json
import re

path = Path(__file__).resolve().parent.parent / 'Dynamic_Camera/plugin/menu.lua'
source = path.read_text(encoding='utf-8-sig')
q = lambda s: json.dumps(s, ensure_ascii=False)

# id | label | short help (empty label retains the existing label)
rows = '''
main_on||Use Dynamic Camera while playing.
show_help||Show control descriptions.
o_r3||Press R3 to switch between Low and High.
crouch_on|Follow crouching|Move the camera down when crouching.
crouch_amount|Crouch follow strength|Adjust how much the camera follows.
pos_for|Camera position|
pos_height||Adjust how high the camera sits.
pos_pitch||Aim the view up or down.
dist_for|Camera distance|
dist_mode|Distance mode|
dist_fixed||Set the riding distance.
dist_slow|Distance at low speed|Set the distance when riding slowly.
dist_fast|Distance at top speed|Set the distance when riding fast.
col_on||Keep the camera clear of walls.
col_auto||Handle collision automatically. Turn off to use Manual collision settings.
fl_strength||Adjust how quickly the camera follows.
fl_horizontal||Adjust how strongly the camera follows turns.
fl_dynamic|Reduce lag at speed|Increase follow responsiveness at speed.
fl_dspeed|Speed for maximum follow boost|Set the speed for the full follow boost.
fl_boost||Adjust the extra responsiveness at speed.
sh_mode||
sh_side||
sh_stance||
sh_offset||Move the camera sideways.
sh_time||Set how long a shoulder switch takes.
sl_on||Tilt with hills while riding.
sl_strength||Adjust how much the view tilts with hills.
sl_response||Set how quickly tilt and aim changes settle.
ty_on||Turn the camera to show tricks.
ty_angle||Set how far the camera turns.
ty_side||
ty_air||Turn the camera during air tricks.
ty_grind||Turn the camera during grinds.
ty_manual||Turn the camera during manuals.
ty_minair||Set the airtime needed before the camera turns.
ty_in|Camera turn time|Set how long the camera takes to turn.
ty_hold||Hold the angle after a trick.
ty_return||Set how long the camera takes to return behind you.
man_for|Manual camera|
man_on||Use a closer view during manuals.
man_mode|Manual distance mode|
man_min|Minimum manual distance|Set the distance at low speed.
man_max|Maximum manual distance|Set the distance at 8 m/s and above.
man_dist||Set the distance during manuals.
man_height||Adjust the camera height during manuals.
man_pitch||Aim the view during manuals.
man_focus||0 targets the board. 1 targets the upper body.
grd_for|Grind camera|
grd_on||Use a closer view during grinds.
grd_dist||Set the distance during grinds.
grd_height||Adjust the camera height during grinds.
grd_pitch||Aim the view during grinds.
grd_focus||0 targets the board. 1 targets the upper body.
cu_blend||Adjust the time between camera views.
cu_board||Use the board as the close-up target.
cu_exit||Set how long the camera takes to leave a close-up.
ba_keep||Keep the skater visible during jumps.
ba_follow||Adjust how much the camera rises with the skater.
ba_rise||Set how far the camera rises over the skater.
ba_full|Jump height for maximum rise|Set the height needed for full camera rise.
ba_ease|Big-air rise time|Set how quickly the camera rises and settles.
lv_on||Tilt toward the landing on drops.
lv_strength||Adjust how much the view tilts toward the landing.
lv_drop|Drop height for maximum tilt|Set the drop needed for full landing tilt.
lv_vertical||Adjust how much the view follows vertical movement.
sk_on||Enable camera shake effects.
sk_speed||Increase shake with speed.
sk_strength||Adjust the shake while riding.
sk_top|Speed for maximum shake|Set the speed needed for full shake.
sk_down||Add shake while riding downhill.
sk_down_s||Adjust the extra downhill shake.
sk_down_a|Slope angle for maximum shake|Set the slope needed for full downhill shake.
sk_land||Adjust the shake on landing.
sk_minfall|Minimum drop height for shake|Ignore drops below this height.
sk_fullfall|Drop height for maximum shake|Set the drop needed for full landing shake.
sk_weight|Landing speed influence|Adjust how much speed adds to landing shake.
lb_on||Lower the camera briefly on landing.
lb_depth||Adjust how far the camera drops.
lb_time|Bounce recovery time|Set how quickly the camera returns after landing.
fv_override||Allow Dynamic Camera to set the field of view.
fv_base|Base FOV|
fv_smooth||Set how quickly the field of view changes.
sf_on||Widen the view with speed.
sf_deg||Set the extra field of view at full speed.
sf_min||Set when the field of view starts widening.
sf_max|Speed for maximum FOV increase|Set the speed needed for full widening.
af_on||Widen the view during big jumps.
af_deg||Set the extra field of view during big jumps.
af_full|Jump height for maximum FOV increase|Set the jump height needed for full widening.
ob_mode|Off-board camera mode|
ob_style|Camera type|
ob_dist|Camera distance|Set the distance from the skater.
ob_height|Camera height|Set the height above the body centre.
ob_look||Set the height the camera aims at.
ob_offset||Move the view sideways. L3 switches sides.
ob_fov|Field of view|
ob_follow||Adjust how quickly the camera follows.
ob_turn|Look smoothing|Smooth the start and stop of camera turns.
ob_stick|Look speed|Set how quickly the right stick turns the view.
ob_invert|Invert vertical look|Push the right stick up to look down.
ob_recentre|Recentre delay|Set the delay before the camera returns behind you. 0 disables recentring.
ob_match|Align view with walking|Align the view with the walking direction.
ob_level|Body height smoothing|Reduce camera movement from body height changes.
ob_bob|Walking bob strength|Adjust camera bob while walking.
ob_bail|Bail distance multiplier|Move further back during bails. 1 keeps the same distance.
ob_trans|Board-to-foot transition time|Set the transition time between riding and walking views.
mc_radius||Set the distance from walls.
mc_in||Set how quickly the camera moves clear of a wall.
mc_out||Set how quickly the camera returns after a wall.
mc_ground||Set the distance above the ground.
bt_take||Set the transition time when taking the camera.
bt_release|Return to game camera time|Set the return time. 0 returns control immediately.
lg_on||Record camera diagnostics for troubleshooting.
'''
wording = {a: (b,c) for a,b,c in (line.split('|') for line in rows.strip().splitlines())}
tips = {
 'cam_height': ['Use the Low view.', 'Use the High view.'],
 'dist_mode': ['Change distance with speed.', 'Keep a fixed riding distance.'],
 'sh_mode': ['Centre the camera.', 'Choose a side.', 'Use the stance to choose a side.'],
 'sh_side': ['Place the camera on the left.', 'Place the camera on the right.'],
 'sh_stance': ['Use a regular stance.', 'Use a goofy stance.'],
 'ty_side': ['Follow the shoulder side or stance.', 'Turn left.', 'Turn right.'],
 'man_mode': ['Keep a fixed distance.', 'Change distance with speed.'],
 'ob_mode': ['Use Dynamic Camera on foot.', "Use the game's camera on foot."],
 'ob_style': ['Look around the skater.', 'Use an over-the-shoulder view.'],
}

def arguments(start):
    """Split a Lua call without touching expressions or numeric ranges."""
    depth=0; quote=False; escaped=False; parts=[]; begin=start
    for i in range(start,len(source)):
        c=source[i]
        if quote:
            if escaped: escaped=False
            elif c=='\\': escaped=True
            elif c=='"': quote=False
        elif c=='"': quote=True
        elif c in '({[': depth+=1
        elif c in ')}]':
            if c==')' and depth==0:
                return parts+[source[begin:i]],i
            depth-=1
        elif c==',' and depth==0:
            parts.append(source[begin:i]);begin=i+1
    raise ValueError('unclosed call')

edits=[]
for match in re.finditer(r'\b(toggle|slider|pick|camera_for|ui:toggle|ui:slider|ui:dropdown)\("([^"\n]+)",',source):
    kind,ident=match.groups()
    parts,end=arguments(source.index('(',match.start())+1)
    label,tip=wording.get(ident,('', ''))
    def put(n,value):
        old=parts[n]
        parts[n]=old[:len(old)-len(old.lstrip())]+value+old[len(old.rstrip()):]
    if label: put(1,q(label))
    if kind in ('toggle','slider') and ident in wording:
        put(2,q(tip) if tip else 'nil')
    if kind=='ui:toggle' and ident in wording:
        put(3,'help and '+q(tip)+' or nil')
    if kind=='camera_for':
        put(2,q('Edit the Low view.'));put(3,q('Edit the High view.'))
    if kind=='pick' and ident in tips:
        put(4,'{ '+', '.join(map(q,tips[ident]))+' }')
        if ident=='man_mode': put(2,'{ "Fixed", "Speed-based" }')
    if ident=='preset_pick': put(4,'help and "Select a saved preset." or nil')
    edits.append((source.index('(',match.start())+1,end,','.join(parts)))
for start,end,value in reversed(edits): source=source[:start]+value+source[end:]

cards={'CROUCH BODY FOLLOW':'CROUCH','TRICK CAMERA TURN':'TRICK CAMERA','CLOSE-UP SETTINGS':'CLOSE-UPS',
       'OFF THE BOARD':'OFF-BOARD CAMERA','FEEL':'CAMERA MOVEMENT','BODY':'BODY FOLLOWING',
       'BOARD TRANSITION':'BOARD TRANSITIONS','MANUAL COLLISION SETTINGS':'MANUAL COLLISION'}
source=re.sub(r'ui:card\("([^"\n]+)"(?:, "[^"\n]*")?\)',lambda m:'ui:card('+q(cards.get(m[1],m[1]))+')',source)

# Remove static filler notes; keep short instructions where they answer a specific control question.
static={
 'Applies the selected preset without changing whether the camera is enabled.':None,
 'Opens a window to save the camera under a name, rename or delete presets, and import a preset file.':None,
 'Shows the preset folder in Explorer. Copy a .json file out to share it, or in to add one: it appears in the list by itself.':'Copy preset files here to import or share them.',
 'Settings for the camera: follow, tricks, jumps, landings and effects, and the view off the board.':None,
 'Camera style: this plugin has the Full style only (it controls the whole view). Native+ is not included.':None,
 'L3 switches shoulder side. Controller clicks work automatically; no manual binding needed.':None,
 '100% keeps the current dip; 0% removes crouch body follow. Changes blend smoothly. The amount is remembered while off.':'Adjust how much the camera follows.',
 "Bind 'Switch shoulder side' on ReSkate's Binds page (L3 in Skate 3) to switch shoulder sides.":'L3 switches shoulder side.',
 'The camera turns to show the trick, holds that angle while you keep tricking, and returns behind you after landing.':None,
 'How quickly the landing tilt changes is Tilt transition time, in FOLLOW & MOVEMENT.':None,
 "Higher: a wider view that shows more around you. Lower: a narrower, more zoomed-in view. 0 keeps the game's FOV.":"0 uses the game's FOV.",
 "Higher: a wider view. Lower: a narrower, more zoomed-in view. 0 keeps the game's FOV.":"0 uses the game's FOV.",
 'Turn on Override game FOV above to use this.':'Enable Override game FOV to use this.',
 'Look around with the right stick. R3 swings the camera behind you; double-click R3 (or the bind "switch off-board view", Ctrl+Shift+V) to switch Orbit / Shoulder. Each style keeps its own sliders. The mouse is not used.':'R3 recentres. Double R3 switches Orbit / Shoulder.',
 'Used when Automatic collision handling is off (CAMERA tab).':'Turn off Automatic collision handling to use these settings.',
 "The plugin cannot see the game's camera while it holds the view, so it eases to where it expects it to be, learned from the last time you were on foot.":None,
}
literal=r'"(?:\\.|[^"\\])*"'
def rewrite_note(m):
    text=json.loads(m[2])
    if text not in static: return m[0]
    replacement=static[text]
    return '' if replacement is None else m[1]+'note('+q(replacement)+')'
source=re.sub(r'(?m)^([ \t]*(?:ui:)?)note\(('+literal+r')\)',rewrite_note,source)
source=source.replace('"Manage presets... (save, rename, import)"','"Manage presets…"')
source=re.sub(r'\n[ \t]+\n', '\n\n', source)
path.write_text(source,encoding='utf-8',newline='\n')
