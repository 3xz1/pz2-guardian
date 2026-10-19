-----------------------------------------------------------------------
--  PZ2Guardian.Core
--
--  Boots the mod once per Lua state (same pattern as PZ2Studbook):
--   * installs a require hook so game modules are patched the moment
--     they are first loaded (chains with other mods' hooks);
--   * loads the mod's UI overlay and proves it serves files (probe page);
--   * puts its page into the in-park HUD;
--   * bridges UI events to PZ2Guardian.Guard;
--   * keeps the UI's settings in the game's player save (see "settings").
--
--  Getting onto the page without breaking the other mods: like Studbook,
--  Guardian wraps the view class's Load (not Init). Whichever of the two
--  wraps last runs first; each one lists the other's page as replaceable
--  and imports the other's script, so either order ends with one page
--  that loads every mod's UI, and both ready callbacks on the same view.
--  If anything here fails, the page another mod chose is used unchanged.
-----------------------------------------------------------------------
local global    = _G
local api       = global.api
local pcall     = global.pcall
local tostring  = global.tostring
local type      = global.type
local ipairs    = global.ipairs
local string    = global.string
local table     = global.table
local coroutine = global.coroutine
local tonumber  = global.tonumber
local math      = global.math

local Core = module(...)

Core.sVersion = "1.2.0"
Core.bBooted = false

Core.sOverlayName = "PZ2GuardianUI"
Core.sOverlayPath = "PZ2Guardian/UI/PZ2GuardianUI"
Core.sProbeAddress = "coui://UIGameface/PZ2Guardian/probe.html"
Core.sModHUD = "coui://UIGameface/PZ2GuardianHUD.html"

-- pages we take over: the game's, or another mod's copy of it
Core.tReplaceable = {
	hud = {
		["coui://UIGameface/HUD.html"] = true,
		["coui://UIGameface/PZ2QoLHUD.html"] = true,
		["coui://UIGameface/PZ2AutoHubHUD.html"] = true,
		["coui://UIGameface/PZ2TimeWarpHUD.html"] = true,
		["coui://UIGameface/PZ2BreedAdvisorHUD.html"] = true,
		["coui://UIGameface/PZ2StudbookHUD.html"] = true,
	},
}

Core.sOverlayState = "not loaded" -- "loading" | "mapped" | "failed" | "unloaded"
Core.bProbeOk = false
Core.tViews = {}       -- kind -> view wrapper showing our page
Core.tTookFrom = {}    -- kind -> address we replaced (for Diagnose)
Core.tLoadState = { hud = "not seen" }
-- lower-cased module name -> list of patch functions(tModule)
Core.tPatches = {}
Core.tPatched = {}

local function trace(sMsg)
	pcall(function() api.debug.Trace("[PZ2Guardian] " .. sMsg) end)
end
Core.Trace = trace

-----------------------------------------------------------------------
-- module patching
-----------------------------------------------------------------------

Core.AddModulePatch = function(self, sModuleName, fnPatch)
	local sKey = string.lower(sModuleName)
	local tList = self.tPatches[sKey]
	if not tList then
		tList = {}
		self.tPatches[sKey] = tList
	end
	tList[#tList + 1] = fnPatch
	local tLoaded = global.package and global.package.loaded and global.package.loaded[sKey]
	if type(tLoaded) == "table" then
		self:_ApplyPatches(sKey, tLoaded)
	end
end

Core._ApplyPatches = function(self, sKey, tModule)
	local tList = self.tPatches[sKey]
	if not tList or type(tModule) ~= "table" then
		return
	end
	self.tPatched[sKey] = self.tPatched[sKey] or {}
	for i, fnPatch in ipairs(tList) do
		if not self.tPatched[sKey][i] then
			self.tPatched[sKey][i] = true
			local bOk, sErr = pcall(fnPatch, tModule)
			if not bOk then
				trace("patch for " .. sKey .. " failed: " .. tostring(sErr))
			end
		end
	end
end

Core._InstallRequireHook = function(self)
	local fnRequire = global.require
	local fnTryRequire = global.tryrequire
	local function after(sName, tModule)
		if type(sName) == "string" and type(tModule) == "table" then
			local sKey = string.lower(sName)
			if self.tPatches[sKey] then
				self:_ApplyPatches(sKey, tModule)
			end
		end
		return tModule
	end
	global.require = function(sName, ...)
		return after(sName, fnRequire(sName, ...))
	end
	if fnTryRequire then
		global.tryrequire = function(sName, ...)
			return after(sName, fnTryRequire(sName, ...))
		end
	end
end

-----------------------------------------------------------------------
-- UI overlay (as PZ2BreedAdvisor)
-----------------------------------------------------------------------

-- Lua 5.3: coroutine.running() returns (thread, isMain); never nil.
Core._CanYield = function(self)
	local co, bMain = coroutine.running()
	return co ~= nil and not bMain
end

Core._LoadOverlay = function(self)
	local bOk, sErr = pcall(function()
		api.ui2.LoadOverlay(self.sOverlayName, self.sOverlayPath)
	end)
	if not bOk then
		self.sOverlayState = "failed"
		trace("LoadOverlay failed: " .. tostring(sErr))
		return
	end
	self.sOverlayState = "loading"
	self:_TryMap()
end

Core.WaitUntilReady = function(self)
	if self.bWaited or not self:_CanYield() then
		return
	end
	self.bWaited = true
	local nFrames = 0
	while self.sOverlayState == "loading" and nFrames < 300 do
		if self:_TryMap() then
			break
		end
		nFrames = nFrames + 1
		coroutine.yield()
	end
	nFrames = 0
	while self.sOverlayState == "mapped" and not self.bProbeOk and nFrames < 180 do
		nFrames = nFrames + 1
		coroutine.yield()
	end
	-- never destroy a view from a UI callback (deadlocks the UI engine)
	if self.bProbeOk then
		self:_ShutdownProbe()
	end
	trace("overlay " .. self.sOverlayState .. ", probe " .. tostring(self.bProbeOk))
end

Core._TryMap = function(self)
	if self.sOverlayState ~= "loading" then
		return self.sOverlayState == "mapped"
	end
	local bOk, bLoaded = pcall(api.ui2.IsOverlayLoaded, self.sOverlayName)
	if not bOk or not bLoaded then
		return false
	end
	local bMapped, sErr = pcall(api.ui2.MapResources, self.sOverlayName)
	if not bMapped then
		self.sOverlayState = "failed"
		trace("MapResources failed: " .. tostring(sErr))
		return false
	end
	self.sOverlayState = "mapped"
	self:_StartProbe()
	return true
end

Core._StartProbe = function(self)
	local bOk, sErr = pcall(function()
		local ViewWrapper = global.require("UI2.ViewWrapper")
		local oProbe = ViewWrapper:new()
		oProbe:Init({
			sViewName = "PZ2GuardianProbe",
			sViewAddress = self.sProbeAddress,
			bRenderToScreen = false,
			bRenderToFullScreen = false,
			nViewWidth = 16,
			nViewHeight = 16,
			fnOnReadyCallback = function()
				self.bProbeOk = true
			end,
		})
		self.oProbe = oProbe
	end)
	if not bOk then
		trace("probe failed to start: " .. tostring(sErr))
	end
end

Core._ShutdownProbe = function(self)
	if self.oProbe ~= nil then
		pcall(function() self.oProbe:Shutdown() end)
		self.oProbe = nil
	end
end

-- The game unmaps and unloads its own overlays on exit; ours must go the
-- same way, or the game crashes on exit (0xFDEAD).
Core.UnloadOverlay = function(self)
	if self.sOverlayState ~= "mapped" and self.sOverlayState ~= "loading" then
		return
	end
	pcall(api.ui2.UnmapResources, self.sOverlayName)
	if self:_CanYield() then
		local nFrames = 0
		while nFrames < 300 do
			local bOk, bDone = pcall(api.ui2.AreResourcesUnmapped, self.sOverlayName)
			if not bOk or bDone then
				break
			end
			nFrames = nFrames + 1
			coroutine.yield()
		end
	end
	pcall(api.ui2.UnloadOverlay, self.sOverlayName)
	self.sOverlayState = "unloaded"
end

Core._PatchGameScript = function(self, GameScript)
	local fnPrepare = GameScript.OnPrepareToShutdown
	if type(fnPrepare) ~= "function" then
		return
	end
	GameScript.OnPrepareToShutdown = function(oGame, ...)
		local bOk, sErr = pcall(self.UnloadOverlay, self)
		if not bOk then
			trace("overlay unload failed: " .. tostring(sErr))
		end
		return fnPrepare(oGame, ...)
	end
end

-----------------------------------------------------------------------
-- taking over the HUD page at Load time (as PZ2Studbook)
-----------------------------------------------------------------------

-- tClass: the HUDUI class (a ViewWrapper subclass without a Load of its
-- own, so Load comes from ViewWrapper through the class).
Core._PatchLoad = function(self, tClass, sKind)
	local fnLoad = tClass.Load
	if type(fnLoad) ~= "function" then
		self.tLoadState[sKind] = "no Load to wrap"
		return
	end
	tClass.Load = function(oUI, ...)
		local bOk, sErr = pcall(self._TakeOver, self, oUI, sKind, self.sModHUD)
		if not bOk then
			self.tLoadState[sKind] = "take-over failed: " .. tostring(sErr)
		end
		return fnLoad(oUI, ...)
	end
	local fnShutdown = tClass.Shutdown
	if type(fnShutdown) == "function" then
		tClass.Shutdown = function(oUI, ...)
			if self.tViews[sKind] == oUI then
				self.tViews[sKind] = nil
			end
			return fnShutdown(oUI, ...)
		end
	end
	self.tLoadState[sKind] = "hooked"
end

Core._TakeOver = function(self, oUI, sKind, sModPage)
	local sAddress = type(oUI) == "table" and oUI.sViewAddress or nil
	if not self.tReplaceable[sKind][sAddress] then
		return
	end
	self:_TryMap()
	if self.sOverlayState ~= "mapped" or not self.bProbeOk then
		self.tLoadState[sKind] = "left " .. tostring(sAddress) .. " (overlay " .. self.sOverlayState .. ", probe " .. tostring(self.bProbeOk) .. ")"
		return
	end
	oUI.sViewAddress = sModPage
	self.tTookFrom[sKind] = sAddress
	self.tViews[sKind] = oUI
	self.tLoadState[sKind] = "took over " .. sAddress
	-- Init copies tInitSettings.fnOnReadyCallback into tOnReadyCallbacks
	-- right after Load; add ours to the same list (works whether Load runs
	-- before or after that copy)
	local fnReady = function()
		local bOk, sErr = pcall(self._OnReady, self, oUI, sKind)
		if not bOk then
			self.tLoadState[sKind] = "ready failed: " .. tostring(sErr)
		end
	end
	if type(oUI.tOnReadyCallbacks) == "table" then
		table.insert(oUI.tOnReadyCallbacks, fnReady)
	elseif type(oUI.tInitSettings) == "table" then
		local fnOld = oUI.tInitSettings.fnOnReadyCallback
		oUI.tInitSettings.fnOnReadyCallback = function(...)
			fnReady()
			if fnOld then
				return fnOld(...)
			end
		end
	end
end

-- Sends an event to our page in that view. Dropped without a page.
Core.Send = function(self, sKind, sEvent, ...)
	local oUI = self.tViews[sKind]
	if oUI == nil then
		return false
	end
	local tArgs = table.pack(...)
	return (pcall(function()
		oUI:TriggerEventAtNextAdvance(sEvent, table.unpack(tArgs, 1, tArgs.n))
	end))
end

-- AddEventListener(sEvent, nArgCount, fn, cbArg): nArgCount must equal the
-- number of arguments the page sends, or the event never arrives.
local function listen(oUI, sEvent, nArgCount, fn)
	oUI:AddEventListener(sEvent, nArgCount, function(a, ...)
		if a == Core then
			return fn(...)
		end
		return fn(a, ...)
	end, Core)
end

-- The park world (DarwinWorld): in-park events reach the game only while it
-- is active. Back to the main menu, the HUD keeps ticking while the park
-- is torn down, and world API calls then crash the engine (AutoHub crash
-- dumps 2026-10-18).
Core.bParkLive = true

Core._PatchDarwinWorld = function(self, DarwinWorld)
	local function wrap(sName, bLive)
		local fn = DarwinWorld[sName]
		if type(fn) ~= "function" then
			return
		end
		DarwinWorld[sName] = function(...)
			if not bLive then
				self.bParkLive = false
			end
			local tRes = table.pack(fn(...))
			if bLive then
				self.bParkLive = true
			end
			return table.unpack(tRes, 1, tRes.n)
		end
	end
	wrap("OnActivate", true)
	wrap("OnDeactivate", false)
	wrap("OnQuitRequested", false)
	wrap("OnUnload", false)
	wrap("OnShutdown", false)
end

-- Runs inside the view's ready callback: non-blocking calls only.
Core._OnReady = function(self, oUI, sKind)
	local G = self.oGuard
	if sKind == "hud" then
		-- a new park HUD: the park is live (in case OnActivate was missed)
		self.bParkLive = true
	end
	local function guarded(sName, nArgCount, fn)
		listen(oUI, sName, nArgCount, function(...)
			if sKind == "hud" and not self.bParkLive then
				return
			end
			if not G then
				self:Send(sKind, "PZ2Guardian_Log", sName .. ": guard module not loaded")
				return
			end
			local bOk, sErr = pcall(fn, G, ...)
			if not bOk then
				self:Send(sKind, "PZ2Guardian_Log", "error in " .. sName .. ": " .. tostring(sErr))
			end
		end)
	end
	-- argument counts must match the engine.trigger calls in main.js; reply
	-- events have their own names (a page that sends and listens to one
	-- name gets its own message back)
	guarded("PZ2Guardian_Settings", 1, function(Gd, sBits)
		Gd:LoadSettings(sBits)
		self:Send(sKind, "PZ2Guardian_State", Gd:UIState())
	end)
	guarded("PZ2Guardian_Times", 1, function(Gd, sTimes)
		Gd:SetTimes(sTimes)
		self:Send(sKind, "PZ2Guardian_State", Gd:UIState())
	end)
	guarded("PZ2Guardian_Tick", 1, function(Gd)
		Gd:Tick()
		self:Send(sKind, "PZ2Guardian_State", Gd:UIState())
	end)
	guarded("PZ2Guardian_Diagnose", 1, function(Gd)
		local s = "PZ2Guardian " .. self.sVersion .. " | park live " .. tostring(self.bParkLive) .. " | HUD: " .. tostring(self.tLoadState.hud)
			.. " | overlay " .. self.sOverlayState .. ", probe " .. tostring(self.bProbeOk)
			.. "\nsettings store: " .. self:StoreStatus() .. "\n" .. Gd:Diagnose()
		self:Send(sKind, "PZ2Guardian_DiagnoseResult", s)
	end)
	-- the page's settings (no game world calls: not gated by bParkLive)
	listen(oUI, "PZ2Guardian_StoreSave", 1, function(sText)
		local bOk, sResult = pcall(self.StoreWrite, self, sText)
		self:Send(sKind, "PZ2Guardian_StoreSaved", bOk and sResult or ("error: " .. tostring(sResult)))
	end)
	-- the saved settings go with the hello, so the page has them before it
	-- hands its settings to Lua
	local bRead, sText, sStatus = pcall(self.StoreRead, self)
	if not bRead then
		sText, sStatus = "", "error: " .. tostring(sText)
	end
	self:Send(sKind, "PZ2Guardian_Hello", self.sVersion, sText, sStatus)
end

-----------------------------------------------------------------------
-- settings that outlast the game
-----------------------------------------------------------------------
-- The game's UI keeps localStorage in memory only, so it is empty after
-- every game start. The page's settings are kept in the game's player save
-- instead (Saves\player, the main player's tData, saved whole by the game:
-- GetData / SetData, api.save.RequestSaveMainPlayer), the way Mike's QoL
-- Toolbox keeps its own (proven in game there, Franchise included). Our own
-- "PZ2Guardian" entry only, short ASCII strings, a size cap and pcall
-- around every call; nothing else in that save is touched, and nothing
-- goes into park or online saves.
--   tData.PZ2Guardian = { V = "1", N = "<parts>", P1 = "<= 4000 chars", ... }
Core.sStoreRoot = "PZ2Guardian"
Core.nStoreChunk = 4000
Core.nStoreCap = 60000
Core.sStoreLast = "not used yet"

-- the game's main player (nil until the profile is loaded: key 0)
Core._Player = function(self)
	local bOk, tPlayer = pcall(function()
		local GDB = global.package.loaded["database.gamedatabase"] or global.require("Database.GameDatabase")
		local nKey = GDB.GetPlayerKey(api.player.GetGameOwner())
		if nKey == nil or nKey == 0 then
			return nil
		end
		return GDB.GetPlayer(nKey)
	end)
	if bOk and type(tPlayer) == "table" and type(tPlayer.GetData) == "function" and type(tPlayer.SetData) == "function" then
		return tPlayer
	end
	return nil
end

-- a JSON object as printable ASCII (the page escapes everything else)
local function validStoreText(s)
	return type(s) == "string" and string.sub(s, 1, 1) == "{" and not string.find(s, "[^\32-\126]")
end

-- Returns the kept text ("" when nothing is kept yet) and a status:
-- "ok" | "noplayer" | "unreadable".
Core.StoreRead = function(self)
	local tPlayer = self:_Player()
	if tPlayer == nil then
		self.sStoreLast = "read: no player profile"
		return "", "noplayer"
	end
	local bOk, t = pcall(tPlayer.GetData, tPlayer, self.sStoreRoot)
	if not bOk or t == nil then
		self.sStoreLast = "read: nothing kept yet"
		return "", "ok"
	end
	local n = type(t) == "table" and tonumber(t.N) or nil
	local tParts = {}
	if n ~= nil and n >= 1 and n <= 100 then
		for i = 1, n do
			local s = t["P" .. i]
			if type(s) ~= "string" then
				break
			end
			tParts[i] = s
		end
	end
	local sText = table.concat(tParts)
	if n == nil or #tParts ~= n or not validStoreText(sText) then
		self.sStoreLast = "read: unreadable entry"
		return "", "unreadable"
	end
	self.sStoreLast = "read " .. #sText .. " chars"
	return sText, "ok"
end

-- Replaces the kept text and asks the game to write the player save.
-- Returns "saved" | "kept" (in the player table; the game saves it when a
-- park closes) | "bad" | "toobig" | "noplayer" | "failed".
Core.StoreWrite = function(self, sText)
	local sResult
	if not validStoreText(sText) then
		sResult = "bad"
	elseif #sText > self.nStoreCap then
		sResult = "toobig"
	else
		local tPlayer = self:_Player()
		if tPlayer == nil then
			sResult = "noplayer"
		else
			local nParts = math.max(1, math.ceil(#sText / self.nStoreChunk))
			local tEntry = { V = "1", N = tostring(math.floor(nParts)) }
			for i = 1, nParts do
				tEntry["P" .. i] = string.sub(sText, (i - 1) * self.nStoreChunk + 1, i * self.nStoreChunk)
			end
			if not pcall(tPlayer.SetData, tPlayer, tEntry, self.sStoreRoot) then
				sResult = "failed"
			elseif pcall(function() api.save.RequestSaveMainPlayer() end) then
				sResult = "saved"
			else
				sResult = "kept"
			end
		end
	end
	self.sStoreLast = "write " .. (type(sText) == "string" and #sText or 0) .. " chars: " .. sResult
	if sResult ~= "saved" and sResult ~= "kept" then
		trace("settings store: " .. self.sStoreLast)
	end
	return sResult
end

Core.StoreStatus = function(self)
	return (self:_Player() ~= nil and "player profile ok" or "no player profile") .. ", last " .. self.sStoreLast
end

-----------------------------------------------------------------------
-- boot
-----------------------------------------------------------------------

Core.Boot = function(self)
	if self.bBooted then
		return
	end
	self.bBooted = true
	self:_InstallRequireHook()
	local bOk, sErr = pcall(function()
		self.oGuard = global.require("PZ2Guardian.Guard")
		self.oGuard:Init(self)
	end)
	if not bOk then
		self.oGuard = nil
		trace("guard module failed to init: " .. tostring(sErr))
	end
	self:AddModulePatch("UI.Controllers.HUDUI", function(t) self:_PatchLoad(t, "hud") end)
	self:AddModulePatch("Game.GameScript", function(t) self:_PatchGameScript(t) end)
	self:AddModulePatch("Worlds.DarwinWorld", function(t) self:_PatchDarwinWorld(t) end)
	self:_LoadOverlay()
	trace("booted v" .. self.sVersion)
end
