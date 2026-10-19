"""Runs PZ2Guardian's Lua against a fake game API (lupa, Lua 5.3).

The fakes follow the game's compiled Lua (dis53.py):
  * unbox: IsAnimalUnboxableByPlayer(id), ClaimBoxing(id) -> bool, UnboxAnimal(id)
  * return home: staff:CanStaffDeliverAnimalToFacility(id, hab),
    animals:RequestTransportToAssignedHabitat(id)
  * keeper move: CanTransportToEntity(false, hab) -> ok, type;
    AttemptRequestToTransportAnimalToTarget(id, hab, type) (type required)
  * GetAnimalTransportData(id).bHasTransportJob
  * UI2.ViewWrapper.Init: stores the address, calls self:Load(), then copies
    fnOnReadyCallback into tOnReadyCallbacks.
"""
import json
import os
import sys
from lupa.lua53 import LuaRuntime

LUA_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "lua")
STUDBOOK_LUA = os.path.join(LUA_DIR, "..", "..", "PZ2Studbook", "lua")

FAKE = r"""
loaded_src = {}
game_modules = {}
package.loaded = {}
module = function(name)
  local t = {}
  package.loaded[string.lower(name)] = t
  return t
end
require = function(name)
  local key = string.lower(name)
  if package.loaded[key] then return package.loaded[key] end
  if game_modules[key] then package.loaded[key] = game_modules[key]; return game_modules[key] end
  local src = loaded_src[key]
  assert(src, "no module " .. name)
  local fn = assert(load(src, name))
  local r = fn(name)
  return package.loaded[key] or r
end
tryrequire = function(name) local ok, r = pcall(require, name); if ok then return r end end

ViewWrapper = {}
ViewWrapper.__index = ViewWrapper
function ViewWrapper:new() return setmetatable({}, self) end
function ViewWrapper:subclass() local c = setmetatable({}, { __index = self }); c.__index = c; return c end
function ViewWrapper:Init(t)
  self.tInitSettings = t
  self.sViewAddress = t.sViewAddress
  self.tOnReadyCallbacks = {}
  self.tListeners = {}
  self:Load()
  if t.fnOnReadyCallback then table.insert(self.tOnReadyCallbacks, t.fnOnReadyCallback) end
end
function ViewWrapper:Load() self.sLoaded = self.sViewAddress end
function ViewWrapper:Ready() for _, fn in ipairs(self.tOnReadyCallbacks) do fn() end end
function ViewWrapper:Shutdown() self.bShut = true end
function ViewWrapper:AddEventListener(name, n, fn, arg) self.tListeners[name] = { n = n, fn = fn, arg = arg } end
sent = {}
function ViewWrapper:TriggerEventAtNextAdvance(name, ...) sent[#sent + 1] = { name = name, args = { ... } } end
function ViewWrapper:Fire(name, ...) local l = self.tListeners[name]; assert(l, "no listener " .. name); return l.fn(l.arg, ...) end
game_modules["ui2.viewwrapper"] = ViewWrapper
game_modules["ui.controllers.hudui"] = ViewWrapper:subclass()
game_modules["ui.controllers.frontendui"] = ViewWrapper:subclass()
game_modules["game.gamescript"] = { OnPrepareToShutdown = function() end }
-- the park world: Guardian watches these to know when the park closes
game_modules["worlds.darwinworld"] = {
  OnActivate = function() end, OnDeactivate = function() end, OnQuitRequested = function() end,
  OnUnload = function() end, OnShutdown = function() end,
}

-- time
T = { now = 0, dt = 0.016 }

-- the park ------------------------------------------------------------
calls = {}
local function log(s) calls[#calls + 1] = s end
-- id -> animal record
zoo = {}
habs = { [500] = { valid = true }, [600] = { valid = true } }
escapes_enabled = true
cash_ok = true
staff_can_deliver = true

A = {
  CurrentLocationType_Habitat = 1, CurrentLocationType_Quarantine = 2, CurrentLocationType_TradeCentre = 3,
  CurrentLocationType_VetSurgery = 4, CurrentLocationType_FreeRoaming = 5, CurrentLocationType_BeingCarried = 6,
  AnimalsListType_All = 0, AnimalsListType_Habitat = 1,
}
function A:IsAlive(id) return zoo[id] ~= nil and not zoo[id].dead end
function A:GetCurrentLocationType(id) return zoo[id].loc or 1 end
function A:GetAnimalTransportData(id) return { bHasTransportJob = zoo[id].job or false } end
function A:GetAssignedHabitatEntityID(id) return zoo[id].hab or 0 end
function A:IsAnimalBoxed(id) return zoo[id].boxed or false end
function A:IsEscaped(id) return zoo[id].esc or false end
function A:IsBoxingClaimed(id) return zoo[id].claimed or false end
function A:IsTranquillized(id) return zoo[id].tranq or false end
function A:IsBoxWaitingForNavMeshRebuild(id) return zoo[id].nav or false end
function A:IsAnimalUnboxableByPlayer(id) return zoo[id].unboxable ~= false end
function A:DoesAnimalWantToBeLetOutOfBox(id) return false end
function A:ClaimBoxing(id) log("ClaimBoxing " .. id); return true end
-- server = "refuse": the call works, but the server puts the animal back in
-- its box a moment later (Franchise, "Server error: code 5");
-- server = "ignore": the call works and nothing changes
server = nil
function A:UnboxAnimal(id)
  log("UnboxAnimal " .. id)
  if server == "ignore" then return end
  zoo[id].boxed = false
  if server == "refuse" then zoo[id].reboxAt = T.now + 4 end
end
function serverTick()
  for _, a in pairs(zoo) do
    if a.reboxAt and T.now >= a.reboxAt then a.boxed = true; a.reboxAt = nil end
  end
end
function A:RequestTransportToAssignedHabitat(id) log("Return " .. id) end
function A:CanTransportToEntity(bNotHab, target) return true, 7 end
function A:AttemptRequestToTransportAnimalToTarget(id, target, nType)
  assert(nType ~= nil, "transport type missing")
  log("Move " .. id .. " " .. target .. " " .. nType)
end
function A:GetName(id) return "[STRING_LITERAL:Value=|" .. (zoo[id].name or ("A" .. id)) .. "|]" end
function A:SetEnableEscapes(b) escapes_enabled = b; log("SetEnableEscapes " .. tostring(b)) end
function A:GetEmergencyCaptureCost() return 2500 end
function A:EmergencyCaptureAnimal(id) log("Capture " .. id) end
function A:GetAnimalsInPark(nType)
  assert(nType ~= nil)
  local t = {}
  for id, a in pairs(zoo) do if a.hab and a.hab ~= 0 and a.listed_in_park then t[#t + 1] = id end end
  return t
end
H = {}
function H:GetAnimalsInHabitat(nHab)
  local t = {}
  for id, a in pairs(zoo) do if a.hab == nHab and not a.listed_in_park then t[#t + 1] = id end end
  return t
end
function H:IsHabitatValid(nHab) return habs[nHab].valid end
F = {}
function F:GetAllHabitatsEntityIDs() return { 500, 600 } end
S = {}
function S:CanStaffDeliverAnimalToFacility(id, hab) return staff_can_deliver end
M = {}
function M:CanModifyCash(n) return cash_ok end

api = {
  debug = { Trace = function() end },
  entity = { NullEntityID = -1 },
  time = {
    GetTotalTimeUnscaled = function() return T.now end,
    GetDeltaTime = function() return T.dt end,
    GetDeltaTimeUnscaled = function() return 0.016 end,
  },
  world = { GetWorldAPIs = function() return { animals = A, habitat = H, facilities = F, staff = S, money = M } end },
  ui2 = {
    LoadOverlay = function() end,
    IsOverlayLoaded = function() return true end,
    MapResources = function() end,
    UnmapResources = function() end,
    AreResourcesUnmapped = function() return true end,
    UnloadOverlay = function() end,
  },
}
"""

FAILS = 0
OKS = 0


def check(cond, msg):
    global FAILS, OKS
    if cond:
        OKS += 1
    else:
        FAILS += 1
        print("FAIL:", msg)


def read_dir(lua, d):
    for f in sorted(os.listdir(d)):
        if f.endswith(".lua"):
            with open(os.path.join(d, f), encoding="utf-8") as fh:
                lua.globals().loaded_src[f[:-4]] = fh.read()


def fresh():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE)
    read_dir(lua, LUA_DIR)
    return lua


def calls(lua):
    return list(lua.globals().calls.values())


def guard(lua):
    G = lua.eval('require("PZ2Guardian.Guard")')
    lua.execute('package.loaded["pz2guardian.guard"].tSeen = {}')
    return G


def run(lua, secs, step=3):
    """advance real time and tick every `step` seconds"""
    G = lua.eval('package.loaded["pz2guardian.guard"]')
    t = 0
    while t < secs:
        lua.execute(f"T.now = T.now + {step}")
        lua.execute("serverTick()")
        G.Tick(G)
        t += step


def animal(lua, id_, **kw):
    parts = ", ".join(f"{k} = {json.dumps(v) if not isinstance(v, bool) else str(v).lower()}" for k, v in kw.items())
    lua.execute(f"zoo[{id_}] = {{ {parts} }}")


# --- escape block -------------------------------------------------------
lua = fresh()
G = guard(lua)
run(lua, 3)
check(lua.globals().escapes_enabled is False, "block on by default: SetEnableEscapes(false)")
lua.execute('escapes_enabled = true')
run(lua, 3)
check(lua.globals().escapes_enabled is True, "not re-applied every tick (only every 10 s)")
run(lua, 12)
check(lua.globals().escapes_enabled is False, "re-applied after 10 s (park settings may switch it back)")
G.LoadSettings(G, "0,1,1,0")
check(lua.globals().escapes_enabled is True, "block switched off: escapes enabled again")
lua.execute('calls = {}')
run(lua, 30)
check(not any("SetEnableEscapes" in c for c in calls(lua)), "block off: never switched off again")

# --- escaped animal goes home, after the grace time ----------------------
lua = fresh()
G = guard(lua)
animal(lua, 1, hab=500, esc=True, loc=5, name="Zara")
run(lua, 9)
check("Return 1" not in calls(lua), "no request inside the 15 s grace (staff go first)")
run(lua, 9)
check(calls(lua).count("Return 1") == 1, "escaped: RequestTransportToAssignedHabitat after the grace")
run(lua, 30)
check(calls(lua).count("Return 1") == 1, "no repeat before nRetry (45 s)")
run(lua, 18)
check(any(c.startswith("Move 1 500 7") for c in calls(lua)), "2nd try: keeper move with the transport type")
check(G.tCount.returned == 1, "two tries, one animal: sent home counted once")
state = json.loads(G.UIState(G))
check(state["rows"] and state["rows"][0]["name"] == "Zara" and state["rows"][0]["state"] == "loose", "UI row for the escapee")
check(state["home"] == 0, "not home yet")
# the keeper boxes it and carries it (other states), then it's home
lua.execute('zoo[1].boxed = true; zoo[1].job = true')
run(lua, 6)
check(json.loads(G.UIState(G))["rows"][0]["state"] == "moving", "boxed by the keeper: being moved")
lua.execute('zoo[1].esc = false; zoo[1].loc = 1; zoo[1].boxed = false; zoo[1].job = false')
run(lua, 3)
state = json.loads(G.UIState(G))
check(state["rows"] == [], "row gone once home")
check(any("back in its habitat" in s for s in G.tLog.values()), "logged back in its habitat")
check(state["home"] == 1 and state["returned"] == 1, f"sent 1, back 1 (through the keeper's states), got {state}")
# escapes again later: a new case, counted again
lua.execute('zoo[1].esc = true; zoo[1].loc = 5')
run(lua, 18)
check(json.loads(G.UIState(G))["returned"] == 2, "a second escape counts again")

# --- counters: unboxed and captured are separate --------------------------
lua = fresh()
G = guard(lua)
G.LoadSettings(G, "1,1,1,1")
animal(lua, 30, hab=500, boxed=True, loc=1)
animal(lua, 31, hab=500, esc=True)
run(lua, 180)
state = json.loads(G.UIState(G))
check(state["unboxed"] == 1, f"unboxed 1, got {state['unboxed']}")
check(state["captured"] == 1, f"captured 1, got {state['captured']}")
check(state["returned"] == 1, f"escapee counted once as sent home (keeper, then capture), got {state['returned']}")
check(isinstance(state["boot"], str) and state["boot"] != "", "boot id for the page's all-time totals")

# --- wait times from the page --------------------------------------------
lua = fresh()
G = guard(lua)
G.SetTimes(G, "60,5,10,20,30")
check((G.nLooseGrace, G.nBoxedAwayGrace, G.nUnboxGrace, G.nRetry, G.nEmergencyAfter) == (60, 5, 10, 20, 30), "SetTimes in order")
check(json.loads(G.UIState(G))["times"] == [60, 5, 10, 20, 30], "times sent back to the page")
animal(lua, 32, hab=500, esc=True)
run(lua, 54)
check("Return 32" not in calls(lua), "escaped: waits the set 60 s")
run(lua, 9)
check("Return 32" in calls(lua), "escaped: sent after 60 s")
animal(lua, 33, hab=500, boxed=True, loc=1)
run(lua, 9)
check("UnboxAnimal 33" not in calls(lua), "not unboxed before the set 10 s")
run(lua, 6)
check("UnboxAnimal 33" in calls(lua), "unbox after the set 10 s")
G.SetTimes(G, "-5,99999,abc,1,0")
check((G.nLooseGrace, G.nBoxedAwayGrace, G.nUnboxGrace, G.nRetry, G.nEmergencyAfter) == (0, 3600, 10, 10, 10),
      "clamped (0..3600, retry/emergency at least 10), junk ignored")

# --- hands off -----------------------------------------------------------
lua = fresh()
G = guard(lua)
animal(lua, 2, hab=500, esc=True, job=True)            # someone is moving it
animal(lua, 3, hab=500, boxed=True, job=True)          # Studbook / player move
animal(lua, 4, hab=500, loc=3)                         # in the Trade Centre (AutoHub)
animal(lua, 5, hab=500, esc=True, tranq=True)          # the vet is capturing it
animal(lua, 6, hab=500, boxed=True, claimed=True)      # keeper has the box
animal(lua, 7, hab=500, loc=6, esc=True)               # being carried
animal(lua, 8, hab=0, esc=True)                        # no habitat at all
animal(lua, 9, hab=500, boxed=True, loc=2)             # in quarantine
run(lua, 200)
bad = [c for c in calls(lua) if not c.startswith("SetEnableEscapes")]
check(bad == [], f"hands off busy/away animals, got {bad}")

# --- boxed in its habitat: unboxed --------------------------------------
lua = fresh()
G = guard(lua)
animal(lua, 10, hab=500, boxed=True, loc=1)
run(lua, 6)
check("UnboxAnimal 10" not in calls(lua), "not inside the 10 s grace (a box made on purpose)")
run(lua, 9)
c = calls(lua)
check("ClaimBoxing 10" in c and "UnboxAnimal 10" in c and c.index("ClaimBoxing 10") < c.index("UnboxAnimal 10"),
      "ClaimBoxing then UnboxAnimal (the game's button)")
check(G.tCount.unboxed == 0, "not counted yet: it must stay out of the box for 60 s")
run(lua, 63)
check(G.tCount.unboxed == 1, "counted once it stayed out for 60 s")
check(any("out of the box" in s for s in G.tLog.values()), "logged out of the box")

# --- Franchise: the server puts it back in the box -------------------------
lua = fresh()
G = guard(lua)
lua.execute('server = "refuse"')
animal(lua, 12, hab=500, boxed=True, loc=1, name="Praneel")
run(lua, 100)
n = calls(lua).count("UnboxAnimal 12")
check(n == 3, f"bounced back 3 times -> stops after 3 unboxes, got {n}")
check(G.tCount.unboxed == 0, "bounces are not counted as unboxed")
rows = json.loads(G.UIState(G))["rows"]
check(len(rows) == 1 and rows[0]["name"] == "Praneel" and "left alone" in rows[0]["note"], f"row explains the hold, got {rows}")
check(any("back in the box after 3" in s for s in G.tLog.values()), "logged the bounces")
run(lua, 125)
check(calls(lua).count("UnboxAnimal 12") == 4, "tries again after the 2 min hold")
d = G.Diagnose(G)
check("tracking Praneel [12]" in d and "bounces" in d, "diagnose shows what Guardian tracks")

# --- on hold, then the player moves it: the hold must not follow it ----------
lua = fresh()
G = guard(lua)
lua.execute('server = "refuse"')
animal(lua, 14, hab=500, boxed=True, loc=1)
run(lua, 100)
check(calls(lua).count("UnboxAnimal 14") == 3, "refused 3 times -> on hold")
# the player moves it: a keeper job, then it arrives boxed in habitat 600
lua.execute('server = nil; zoo[14].job = true')
run(lua, 30)
lua.execute('zoo[14].job = false; zoo[14].hab = 600; zoo[14].boxed = true')
run(lua, 9)
check(calls(lua).count("UnboxAnimal 14") == 3, "new box: normal 10 s wait first")
run(lua, 6)
check(calls(lua).count("UnboxAnimal 14") == 4, "moved by the player: unboxed after the normal wait, no hold")
# you unbox it yourself while on hold: also a fresh start next time
lua = fresh()
G = guard(lua)
lua.execute('server = "refuse"')
animal(lua, 15, hab=500, boxed=True, loc=1)
run(lua, 100)
lua.execute('server = nil; zoo[15].boxed = false')
run(lua, 90)
lua.execute('zoo[15].boxed = true')
run(lua, 15)
check(calls(lua).count("UnboxAnimal 15") == 4, "unboxed by hand, boxed again later: handled normally")

# --- the unbox call changes nothing -----------------------------------------
lua = fresh()
G = guard(lua)
lua.execute('server = "ignore"')
animal(lua, 13, hab=500, boxed=True, loc=1)
run(lua, 150)
n = calls(lua).count("UnboxAnimal 13")
check(n == 3, f"still boxed after 3 tries -> stops, got {n}")
rows = json.loads(G.UIState(G))["rows"]
check(rows and "still in the box" in rows[0]["note"], f"row says so, got {rows}")
check(G.tCount.unboxed == 0, "nothing counted")

# broken habitat / unboxable false / nav rebuild: leave it
for kw, why in ((dict(), "habitat broken"), (dict(unboxable=False), "not unboxable"), (dict(nav=True), "nav rebuild")):
    lua = fresh()
    G = guard(lua)
    if why == "habitat broken":
        lua.execute("habs[500].valid = false")
    animal(lua, 11, hab=500, boxed=True, loc=1, **kw)
    run(lua, 120)
    check("UnboxAnimal 11" not in calls(lua), f"left boxed: {why}")

# unbox switched off
lua = fresh()
G = guard(lua)
G.LoadSettings(G, "1,1,0,0")
animal(lua, 12, hab=500, boxed=True, loc=1)
run(lua, 120)
check("UnboxAnimal 12" not in calls(lua), "unbox off: left alone")

# --- boxed outside its habitat: sent home, never unboxed there ---------
lua = fresh()
G = guard(lua)
animal(lua, 13, hab=600, boxed=True, loc=5, listed_in_park=True)
run(lua, 36)
c = calls(lua)
check("Return 13" in c, "boxed away: sent home (found via GetAnimalsInPark)")
check("UnboxAnimal 13" not in c, "never unboxed outside its habitat")

# boxed + escaped flag at a habitat location: still counts as away
lua = fresh()
G = guard(lua)
animal(lua, 14, hab=600, boxed=True, esc=True, loc=1)
run(lua, 36)
check("UnboxAnimal 14" not in calls(lua) and "Return 14" in calls(lua), "boxed + escaped: home, not unboxed")

# no keeper can reach the habitat: falls back to the keeper move
lua = fresh()
G = guard(lua)
lua.execute("staff_can_deliver = false")
animal(lua, 15, hab=500, esc=True)
run(lua, 18)
c = calls(lua)
check("Return 15" not in c and any(x.startswith("Move 15 500") for x in c), "unreachable: no return request, keeper move tried")

# --- paused: nothing happens --------------------------------------------
lua = fresh()
G = guard(lua)
lua.execute("T.dt = 0")
animal(lua, 16, hab=500, esc=True)
animal(lua, 17, hab=500, boxed=True)
run(lua, 200)
bad = [c for c in calls(lua) if not c.startswith("SetEnableEscapes")]
check(bad == [], f"paused: no actions, got {bad}")
lua.execute("T.dt = 0.016")
run(lua, 3)
check("Return 16" in calls(lua) and "UnboxAnimal 17" in calls(lua), "acts right after unpausing (grace already over)")

# --- emergency capture --------------------------------------------------
lua = fresh()
G = guard(lua)
animal(lua, 18, hab=500, esc=True)
run(lua, 300)
check("Capture 18" not in calls(lua), "emergency capture off by default")
lua = fresh()
G = guard(lua)
G.LoadSettings(G, "1,1,1,1")
animal(lua, 19, hab=500, esc=True)
run(lua, 117)
check("Capture 19" not in calls(lua), "no capture before 2 minutes")
run(lua, 60)
check("Capture 19" in calls(lua), "paid capture after 2 minutes")
lua = fresh()
G = guard(lua)
G.LoadSettings(G, "1,1,1,1")
lua.execute("cash_ok = false")
animal(lua, 20, hab=500, esc=True)
run(lua, 300)
check("Capture 20" not in calls(lua) and "Return 20" in calls(lua), "can't afford: no capture, keeper still sent")

# --- a missing API never raises -----------------------------------------
lua = fresh()
G = guard(lua)
lua.execute("A.UnboxAnimal = nil; A.RequestTransportToAssignedHabitat = nil; A.IsEscaped = nil")
animal(lua, 21, hab=500, boxed=True)
ok = True
try:
    run(lua, 120)
    G.Diagnose(G)
    json.loads(G.UIState(G))
except Exception as e:  # noqa: BLE001
    ok = False
    print(e)
check(ok, "missing APIs: no Lua error")
rows = json.loads(G.UIState(G))["rows"]
check(rows and "unbox failed" in rows[0]["note"], f"missing UnboxAnimal reported in the row, got {rows}")

# --- Diagnose ------------------------------------------------------------
lua = fresh()
G = guard(lua)
animal(lua, 22, hab=500, esc=True, name="Bob")
d = G.Diagnose(G)
check("Bob [22] loose" in d and "RequestTransportToAssignedHabitat: yes" in d, "diagnose lists the API and the escapee")


# --- HUD page sharing with Studbook (both wrap orders) ------------------
def boot_both(order):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE)
    read_dir(lua, LUA_DIR)
    if os.path.isdir(STUDBOOK_LUA):
        read_dir(lua, STUDBOOK_LUA)
    for name in order:
        lua.execute(f'require("Database.{name}LuaDatabase")')
        lua.execute(f'package.loaded["pz2{name[3:].lower()}.core"].bProbeOk = true')
    hud = lua.eval('require("UI.Controllers.HUDUI")')
    view = lua.eval('require("UI.Controllers.HUDUI"):new()')
    lua.execute('function _init(v) v:Init({ sViewAddress = "coui://UIGameface/PZ2AutoHubHUD.html", fnOnReadyCallback = function() end }) end')
    lua.globals()._init(view)
    view.Ready(view)
    names = [e.name for e in lua.globals().sent.values()]
    return view.sLoaded, names


if os.path.isdir(STUDBOOK_LUA):
    for order in (["PZ2Guardian", "PZ2Studbook"], ["PZ2Studbook", "PZ2Guardian"]):
        page, names = boot_both(order)
        check(page in ("coui://UIGameface/PZ2GuardianHUD.html", "coui://UIGameface/PZ2StudbookHUD.html"),
              f"{order}: one of the two pages wins, got {page}")
        check("PZ2Guardian_Hello" in names, f"{order}: Guardian's ready callback ran")
        check("PZ2Studbook_Hello" in names, f"{order}: Studbook's ready callback ran")
else:
    print("(PZ2Studbook source not found next to this mod: page-sharing test skipped)")

# Guardian alone on the game's own page
lua = fresh()
lua.execute('require("Database.PZ2GuardianLuaDatabase")')
lua.execute('package.loaded["pz2guardian.core"].bProbeOk = true')
view = lua.eval('require("UI.Controllers.HUDUI"):new()')
lua.execute('function _init(v) v:Init({ sViewAddress = "coui://UIGameface/HUD.html" }) end')
lua.globals()._init(view)
view.Ready(view)
check(view.sLoaded == "coui://UIGameface/PZ2GuardianHUD.html", "takes over the game's HUD")
lua.execute('sent = {}')
view.Fire(view, "PZ2Guardian_Settings", "1,1,1,0")
view.Fire(view, "PZ2Guardian_Tick", 1)
names = [e.name for e in lua.globals().sent.values()]
check(names.count("PZ2Guardian_State") == 2, "Settings and Tick answer with the state")
for name, l in view.tListeners.items():
    check(l.n == 1, f"{name} registered with 1 argument (main.js sends 1)")

# --- park closing (1.1.2): no game calls while the park world is torn down
# (back to the main menu, the HUD keeps ticking; world API calls then crash
# the engine, as AutoHub's crash dumps showed)
lua = fresh()
lua.execute('require("Database.PZ2GuardianLuaDatabase")')
lua.execute('package.loaded["pz2guardian.core"].bProbeOk = true')
DW = lua.eval('require("Worlds.DarwinWorld")')
view = lua.eval('require("UI.Controllers.HUDUI"):new()')
lua.execute('function _init(v) v:Init({ sViewAddress = "coui://UIGameface/HUD.html" }) end')
lua.globals()._init(view)
view.Ready(view)
animal(lua, 40, hab=500, esc=True)
lua.execute('T.now = 100')
view.Fire(view, "PZ2Guardian_Tick", 1)
check(len(calls(lua)) > 0, "park live: the tick works")
for ev in ("OnDeactivate", "OnQuitRequested", "OnUnload", "OnShutdown"):
    lua.execute("calls = {}; sent = {}")
    lua.execute(f'require("Worlds.DarwinWorld").OnActivate()')
    lua.execute(f'require("Worlds.DarwinWorld").{ev}()')
    lua.execute('T.now = T.now + 100')
    view.Fire(view, "PZ2Guardian_Tick", 1)
    view.Fire(view, "PZ2Guardian_Diagnose", 1)
    view.Fire(view, "PZ2Guardian_Settings", "1,1,1,0")
    check(calls(lua) == [] and len(lua.globals().sent) == 0, f"after {ev}: no game calls, no answers")
lua.execute('require("Worlds.DarwinWorld").OnActivate()')
lua.execute("calls = {}; T.now = T.now + 100")
view.Fire(view, "PZ2Guardian_Tick", 1)
check("Return 40" in calls(lua) or len(calls(lua)) > 0, "OnActivate (park open again): ticks resume")

# --- settings kept in the player save (1.2.0) ------------------------------
# The game's UI keeps localStorage in memory only; the page's settings go
# to the main player's tData (GetData / SetData, RequestSaveMainPlayer).
STORE_FAKE = r"""
playerKey = 7
playerData = {}
saveRequests = 0
Player = {}
function Player:GetData(k) return playerData[k] end
function Player:SetData(v, k) playerData[k] = v end
game_modules["database.gamedatabase"] = {
  GetPlayerKey = function(owner) assert(owner == "owner"); return playerKey end,
  GetPlayer = function(key) return Player end,
}
api.player = { GetGameOwner = function() return "owner" end }
api.save = { RequestSaveMainPlayer = function() saveRequests = saveRequests + 1 end }
"""


def hud_with_store(lua):
    lua.execute('sent = {}')
    view = lua.eval('require("UI.Controllers.HUDUI"):new()')
    lua.execute('function _init(v) v:Init({ sViewAddress = "coui://UIGameface/HUD.html" }) end')
    lua.globals()._init(view)
    view.Ready(view)
    return view


def sent_events(lua, name):
    return [[e.args[i] for i in range(1, len(e.args) + 1)] for e in lua.globals().sent.values() if e.name == name]


lua = fresh()
lua.execute('require("Database.PZ2GuardianLuaDatabase")')
lua.execute('package.loaded["pz2guardian.core"].bProbeOk = true')
view = hud_with_store(lua)
check(sent_events(lua, "PZ2Guardian_Hello") == [["1.2.0", "", "noplayer"]], "store: no player API yet -> hello says noplayer")
lua.execute(STORE_FAKE)
view = hud_with_store(lua)
check(sent_events(lua, "PZ2Guardian_Hello") == [["1.2.0", "", "ok"]], "store: nothing kept yet -> empty, ok")
text = '{"PZ2Guardian.settings":"{\\"block\\":true,\\"ret\\":false}","PZ2Guardian.times":"{\\"unbox\\":20}"}'
lua.execute('sent = {}')
view.Fire(view, "PZ2Guardian_StoreSave", text)
check(sent_events(lua, "PZ2Guardian_StoreSaved") == [["saved"]], "store: write answers saved")
check(lua.eval("saveRequests") == 1, "store: asks the game to save the player")
check(list(lua.eval("playerData").keys()) == ["PZ2Guardian"], "store: only our own entry")
view = hud_with_store(lua)
check(sent_events(lua, "PZ2Guardian_Hello") == [["1.2.0", text, "ok"]], "store: next HUD gets the saved text")
lua.execute('sent = {}')
view.Fire(view, "PZ2Guardian_StoreSave", '{"PZ2Guardian.x":"ä"}')
check(sent_events(lua, "PZ2Guardian_StoreSaved") == [["bad"]], "store: refuses non-ASCII")
# the store works while the park is closing (no world calls), unlike the guard events
lua.execute('require("Worlds.DarwinWorld").OnDeactivate(); sent = {}')
view.Fire(view, "PZ2Guardian_StoreSave", text)
check(sent_events(lua, "PZ2Guardian_StoreSaved") == [["saved"]], "store: still saves while the park closes")

print(f"{OKS} ok, {FAILS} failed")
sys.exit(1 if FAILS else 0)
