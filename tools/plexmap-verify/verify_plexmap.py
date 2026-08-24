import re, sys, json
EV="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Headers/Events.h"
PLEX="/Applications/Plex HTPC.app/Contents/Resources/inputmaps/keyboard.json"
SWIFT="/Users/Owner/mini-youtube/macos/Sources/MiniTube/PlexKeyMap.swift"

# ---- 1. authoritative key codes from Events.h -------------------------------
code_of={}
for m in re.finditer(r'kVK_(\w+)\s*=\s*(0x[0-9A-Fa-f]+)', open(EV).read()):
    code_of[m.group(1)]=int(m.group(2),16)
def kc(n): return code_of[n]

PLEX_KEY_TO_VK = {
 "Left":kc("LeftArrow"), "Right":kc("RightArrow"), "Up":kc("UpArrow"), "Down":kc("DownArrow"),
 "Return":kc("Return"), "Enter":kc("ANSI_KeypadEnter"), "Esc":kc("Escape"), "Backspace":kc("Delete"),
 "Space":kc("Space"), "PgUp":kc("PageUp"), "PgDown":kc("PageDown"), "Home":kc("Home"), "End":kc("End"),
 "=":kc("ANSI_Equal"), "-":kc("ANSI_Minus"), "[":kc("ANSI_LeftBracket"), "]":kc("ANSI_RightBracket"),
 "BSLASH":kc("ANSI_Backslash"),
}
for L in "ABEFHILMPRSWXZ": PLEX_KEY_TO_VK[L]=kc("ANSI_"+L)

# ---- 2. Plex's shipped map --------------------------------------------------
raw=open(PLEX).read()
raw=re.sub(r'^\s*//.*$','',raw,flags=re.M)
raw=raw.replace('"\\\\\\\\"','"BSLASH"')   # json "\\\\" = the literal backslash key
plex=json.loads(raw)["mapping"]
short_of, long_of = {}, {}
for spec,act in plex.items():
    for key in spec.split("|"):
        key=key.replace("\\","")
        if isinstance(act,dict): short_of[key]=act.get("short"); long_of[key]=act.get("long")
        else: short_of[key]=act
def plex_action(key):
    a=short_of.get(key)
    if isinstance(a,list): a=a[-1]
    return a

# ---- 3. my table, parsed out of the real Swift source -----------------------
src=open(SWIFT).read()
body=src[src.index("static func command(for code: UInt16)"):src.index("/// Commands that only mean")]
mine={}
for m in re.finditer(r'case ([\d,\s]+):\s*return \.(\w+)(\(([^)]*)\))?', body):
    cmd=m.group(2); arg=m.group(4)
    for c in m.group(1).split(","):
        mine[int(c.strip())]=(cmd,arg)

# ---- 4. expected enum action per Plex action --------------------------------
EXPECT={
 "left":("navigate",".left"),"right":("navigate",".right"),"up":("navigate",".up"),"down":("navigate",".down"),
 "enter":("activate",None),"back":("back",None),"home":("home",None),"menu":("menu",None),"info":("info",None),
 "play_pause":("playPause",None),"stop":("stop",None),
 "seek_forward":("seek","10"),"seek_backward":("seek","-10"),
 "page_up":("seek","10"),"page_down":("seek","-10"),
 "step_forward":("step","600"),"step_backward":("step","-600"),
 "increase_volume":("volume","0.05"),"decrease_volume":("volume","-0.05"),
 "toggle_subtitles":("toggleSubtitles",None),"cycle_subtitles":("toggleSubtitles",None),
 "toggle_watched":("toggleWatched",None),
 "toggle_fullscreen":("toggleFullscreen",None),
 "previous_pivot_tab":("cycleTab","-1"),"next_pivot_tab":("cycleTab","1"),
}
vk_to_plexkey={}
for k,v in PLEX_KEY_TO_VK.items(): vk_to_plexkey.setdefault(v,[]).append(k)

fails=[]; checked=0
for vk,(cmd,arg) in sorted(mine.items()):
    if vk in (69,78): continue     # keypad +/- : no Plex spelling, share =/- intent
    names=vk_to_plexkey.get(vk)
    if not names: fails.append(f"code {vk} -> .{cmd}: NOT a key I mapped to a name"); continue
    acts={plex_action(n) for n in names if plex_action(n)}
    if not acts: fails.append(f"{'/'.join(names)} (code {vk}) -> .{cmd}: Plex binds NOTHING here"); continue
    ok=False
    for a in acts:
        e=EXPECT.get(a)
        if e and e[0]==cmd and (e[1] is None or (arg or "").strip()==e[1]): ok=True
    checked+=1
    if not ok:
        fails.append(f"{'/'.join(names)} (code {vk}): Plex says {acts}, I do .{cmd}({arg or ''})")

for key,act in long_of.items():
    if key in ("Return","Enter") and act!="menu": fails.append(f"long {key}: Plex={act}, expected menu")
    if key in ("Esc","Backspace","Back") and act!="home": fails.append(f"long {key}: Plex={act}, expected home")

print(f"verified {checked} key bindings against Plex's shipped keyboard.json + Events.h")
print(f"long-press pairs checked: {len(long_of)}")
if fails:
    print("\nMISMATCHES:"); [print("  -",f) for f in fails]; sys.exit(1)
print("\nALL MATCH — the app's table is faithful to the shipped Plex HTPC map")
