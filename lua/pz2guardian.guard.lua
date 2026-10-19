-----------------------------------------------------------------------
--  PZ2Guardian.Guard
--
--  Keeps habitat animals where they belong. Every tick (the page asks
--  every few seconds) it:
--   * switches the game's escapes off (animals:SetEnableEscapes(false),
--     the switch behind the sandbox option "Animal Escapes");
--   * sends escaped animals back to their habitat;
--   * unboxes animals left in a transport box inside their own habitat;
--   * sends animals left boxed outside their habitat back home.
--
--  Every call shape is taken from the game's compiled Lua (dis53.py):
--   UnboxAnimal          animalinfopopup button / HabitatUtils.UnboxAll:
--                        IsAnimalUnboxableByPlayer(id), ClaimBoxing(id),
--                        UnboxAnimal(id)
--   return to habitat    selectmode (animals placed from storage):
--                        staff:CanStaffDeliverAnimalToFacility(id, hab),
--                        animals:RequestTransportToAssignedHabitat(id)
--   keeper move          (proven by PZ2Studbook) CanTransportToEntity(
--                        false, hab) -> ok, type;
--                        AttemptRequestToTransportAnimalToTarget(id, hab, type)
--   emergency capture    animalinfopopup: GetEmergencyCaptureCost(),
--                        money:CanModifyCash(-cost), EmergencyCaptureAnimal(id)
--
--  Hands off: an animal with a transport job (a keeper, the vet, the
--  player or another mod is moving it), one being carried, in the Trade
--  Centre, quarantine or the vet surgery, or tranquillised by a vet.
--  A grace time lets the game's own staff go first and leaves a box the
--  player made on purpose alone for a while.
-----------------------------------------------------------------------
local global   = _G
local api      = global.api
local pcall    = global.pcall
local tostring = global.tostring
local type     = global.type
local pairs    = global.pairs
local ipairs   = global.ipairs
local string   = global.string
local table    = global.table
local math     = global.math

local Guard = module(...)

Guard.tSettings = {
	block = true,      -- switch escapes off
	ret = true,        -- send escaped / boxed-away animals home
	unbox = true,      -- unbox animals boxed inside their own habitat
	emergency = false, -- paid emergency capture after nEmergencyAfter (costs money)
}

-- real seconds (unaffected by game speed); the page can change the first
-- five (SetTimes), in this order
Guard.nLooseGrace = 15      -- escaped this long before we send a keeper
Guard.nBoxedAwayGrace = 30  -- boxed outside the habitat, no job
Guard.nUnboxGrace = 10      -- boxed in its own habitat, no job
Guard.nRetry = 45           -- between attempts for one animal
Guard.nEmergencyAfter = 120 -- loose this long -> paid capture (if switched on)
Guard.tTimeKeys = { "nLooseGrace", "nBoxedAwayGrace", "nUnboxGrace", "nRetry", "nEmergencyAfter" }
Guard.tTimeLimits = { nLooseGrace = { 0, 3600 }, nBoxedAwayGrace = { 0, 3600 }, nUnboxGrace = { 0, 3600 },
	nRetry = { 10, 3600 }, nEmergencyAfter = { 10, 3600 } }
Guard.nBlockEvery = 10      -- re-apply the escape switch this often
-- An unboxed animal counts once it has stayed out this long. If the game
-- puts it back in the box sooner (seen in Franchise: the server refuses and
-- the animal snaps back), that is a bounce; after nBounceMax bounces, or
-- nBounceMax unbox tries that change nothing, it is left alone for nHold.
Guard.nStayOut = 60
Guard.nBounceMax = 3
Guard.nHold = 120
Guard.tOut = {}             -- entity ID -> { at = time it got out, n = bounces, name }
Guard.nLastTick = nil

Guard.tSeen = {}            -- entity ID -> { state, since, last, tries, note }
Guard.tLog = {}
-- per animal, this session: unboxed, sent home (a keeper was asked), of
-- those back in the habitat, emergency captures
Guard.tCount = { unboxed = 0, returned = 0, home = 0, captured = 0 }
-- unique per game start (a table address), so the page can tell a new
-- game start (counts from 0) from a park reload (counts kept)
Guard.sBoot = string.gsub(tostring(Guard.tCount), "^table: ", "")
Guard.nLastBlock = nil
Guard.sBlock = "not applied yet"
Guard.nTicks = 0

local function W()
	local bOk, t = pcall(function() return api.world.GetWorldAPIs() end)
	return bOk and t or nil
end

-- method call t:Name(...) -> true, first result | false, error text
local function call(t, sName, ...)
	if t == nil then
		return false, "API missing"
	end
	local bOk, fn = pcall(function() return t[sName] end)
	if not bOk or type(fn) ~= "function" then
		return false, sName .. " missing"
	end
	local tRes = table.pack(pcall(fn, t, ...))
	if not tRes[1] then
		return false, tostring(tRes[2])
	end
	return true, tRes[2], tRes[3]
end
Guard.call = call

-- a read: its first result, or nil when the call failed (never the error
-- text, which would count as true)
local function ask(t, sName, ...)
	local bOk, v = call(t, sName, ...)
	if bOk then
		return v
	end
	return nil
end

local function now()
	local bOk, n = pcall(function() return api.time.GetTotalTimeUnscaled() end)
	return (bOk and type(n) == "number") and n or 0
end

-- no IsPaused API: paused = scaled delta 0 while real time runs
Guard.IsPaused = function(self)
	local bOk, b = pcall(function()
		return api.time.GetDeltaTime() == 0 and api.time.GetDeltaTimeUnscaled() > 0
	end)
	return bOk and b or false
end

local function idList(v)
	local t = {}
	if type(v) ~= "table" then
		return t
	end
	for k, x in pairs(v) do
		local n = nil
		if type(x) == "number" then
			n = x
		elseif x == true and type(k) == "number" then
			n = k
		end
		if n and n ~= 0 then
			t[#t + 1] = n
		end
	end
	return t
end

local function plain(s)
	s = tostring(s or "")
	return (string.gsub(s, "%[STRING_LITERAL:Value=|(.-)|%]", "%1"))
end

Guard.Log = function(self, sText)
	local tLog = self.tLog
	tLog[#tLog + 1] = sText
	while #tLog > 80 do
		table.remove(tLog, 1)
	end
end

Guard.Init = function(self, Core)
	self.Core = Core
end

Guard.SetSetting = function(self, sKey, bOn)
	if self.tSettings[sKey] == nil then
		return
	end
	local bWas = self.tSettings[sKey]
	self.tSettings[sKey] = bOn and true or false
	if sKey == "block" and bWas ~= self.tSettings.block then
		self.nLastBlock = nil
		if not bOn then
			-- give escapes back (the game's default; the sandbox option can
			-- still switch them off)
			local t = W()
			local bOk, sErr = call(t and t.animals, "SetEnableEscapes", true)
			self.sBlock = bOk and "off: escapes allowed again" or ("off; could not re-enable: " .. tostring(sErr))
			self:Log(self.sBlock)
		end
	end
end

-- "loose,boxedAway,unbox,retry,emergency" in seconds (from the page)
Guard.SetTimes = function(self, sText)
	local i = 0
	for sNum in string.gmatch(tostring(sText or ""), "[^,]+") do
		i = i + 1
		local sKey = self.tTimeKeys[i]
		local n = global.tonumber(sNum)
		if sKey and n and n == n then
			local tLim = self.tTimeLimits[sKey]
			self[sKey] = math.floor(math.min(tLim[2], math.max(tLim[1], n)))
		end
	end
end

-- "block,ret,unbox,emergency" as 1/0 (from the page's localStorage)
Guard.LoadSettings = function(self, sText)
	local tKeys = { "block", "ret", "unbox", "emergency" }
	local i = 0
	for sBit in string.gmatch(tostring(sText or ""), "[^,]+") do
		i = i + 1
		if tKeys[i] then
			self:SetSetting(tKeys[i], sBit == "1")
		end
	end
end

-----------------------------------------------------------------------
-- the animals to look at: every habitat's list, plus the park's habitat
-- animal list (escaped animals may only show up there)
-----------------------------------------------------------------------
Guard._Animals = function(self, t)
	local tSet, tOut = {}, {}
	local function add(v)
		for _, n in ipairs(idList(v)) do
			if not tSet[n] then
				tSet[n] = true
				tOut[#tOut + 1] = n
			end
		end
	end
	local bOk, tHabs = call(t.facilities, "GetAllHabitatsEntityIDs")
	if bOk then
		for _, nHab in ipairs(idList(tHabs)) do
			local bOk2, v = call(t.habitat, "GetAnimalsInHabitat", nHab)
			if bOk2 then
				add(v)
			end
		end
	end
	local nType = t.animals and t.animals.AnimalsListType_Habitat
	if nType ~= nil then
		local bOk3, v = call(t.animals, "GetAnimalsInPark", nType)
		if bOk3 then
			add(v)
		end
	end
	table.sort(tOut)
	return tOut
end

local function valid(n)
	return type(n) == "number" and n ~= 0 and n ~= api.entity.NullEntityID
end

-- -> state, habitat, details
--   "ok" | "skip" | "moving" | "vet" | "loose" | "boxedHome" | "boxedAway"
Guard.Classify = function(self, t, nID)
	local A = t.animals
	local bOk, bAlive = call(A, "IsAlive", nID)
	if bOk and bAlive == false then
		return "skip", nil, "dead"
	end
	local nLoc = ask(A, "GetCurrentLocationType", nID)
	if nLoc ~= nil and (nLoc == A.CurrentLocationType_TradeCentre or nLoc == A.CurrentLocationType_Quarantine
		or nLoc == A.CurrentLocationType_VetSurgery or nLoc == A.CurrentLocationType_BeingCarried) then
		return "skip", nil, "away (location " .. tostring(nLoc) .. ")"
	end
	local tTr = ask(A, "GetAnimalTransportData", nID)
	if type(tTr) == "table" and tTr.bHasTransportJob then
		return "moving", nil, "has a transport job"
	end
	local nHab = ask(A, "GetAssignedHabitatEntityID", nID)
	if not valid(nHab) then
		return "skip", nil, "no habitat"
	end
	local bBoxed = ask(A, "IsAnimalBoxed", nID)
	local bEsc = ask(A, "IsEscaped", nID)
	if bBoxed then
		local bClaimed = ask(A, "IsBoxingClaimed", nID)
		if bClaimed then
			return "moving", nHab, "box claimed by staff"
		end
		if not bEsc and (nLoc == nil or nLoc == A.CurrentLocationType_Habitat) then
			return "boxedHome", nHab, ""
		end
		return "boxedAway", nHab, ""
	end
	if bEsc then
		local bTranq = ask(A, "IsTranquillized", nID)
		if bTranq then
			return "vet", nHab, "tranquillised, the vet is on it"
		end
		return "loose", nHab, ""
	end
	return "ok", nHab, ""
end

-----------------------------------------------------------------------
-- actions
-----------------------------------------------------------------------
Guard._Name = function(self, t, nID)
	local bOk, s = call(t.animals, "GetName", nID)
	s = bOk and plain(s) or ""
	if s == "" or string.find(s, "ERROR", 1, true) then
		return "animal " .. tostring(nID)
	end
	return s
end

-- 1st try: the game's own "return to habitat"; later tries alternate with
-- the keeper move (CanTransportToEntity + transport type)
Guard._SendHome = function(self, t, nID, nHab, rec)
	local A = t.animals
	rec.tries = (rec.tries or 0) + 1
	if rec.tries % 2 == 1 then
		local bOk, bCan = call(t.staff, "CanStaffDeliverAnimalToFacility", nID, nHab)
		if bOk and bCan == false then
			rec.note = "no keeper can reach the habitat (path or gate?)"
		else
			local bOk2, sErr = call(A, "RequestTransportToAssignedHabitat", nID)
			if bOk2 then
				rec.note = "keeper asked to bring it home"
				return true
			end
			rec.note = "return request failed: " .. tostring(sErr)
		end
	end
	local bOk, bCan, nType = call(A, "CanTransportToEntity", false, nHab)
	if not bOk then
		rec.note = (rec.note or "") .. "; move check failed: " .. tostring(bCan)
		return false
	end
	if not bCan then
		rec.note = (rec.note or "") .. "; the game says it can't be moved there now"
		return false
	end
	local bOk2, sErr = call(A, "AttemptRequestToTransportAnimalToTarget", nID, nHab, nType)
	if bOk2 then
		rec.note = "keeper move to its habitat requested"
		return true
	end
	rec.note = "move request failed: " .. tostring(sErr)
	return false
end

Guard._Unbox = function(self, t, nID, nHab, rec)
	local A = t.animals
	local bWaitNav = ask(A, "IsBoxWaitingForNavMeshRebuild", nID)
	if bWaitNav then
		rec.note = "box waits for the game to rebuild paths"
		return false
	end
	local bOkV, bValid = call(t.habitat, "IsHabitatValid", nHab)
	if bOkV and bValid == false then
		rec.note = "habitat is broken (barrier or gate), left in the box"
		return false
	end
	local bOk, bCan = call(A, "IsAnimalUnboxableByPlayer", nID)
	if bOk and not bCan then
		rec.note = "the game doesn't allow unboxing it now"
		return false
	end
	local bOk2, bClaimed = call(A, "ClaimBoxing", nID)
	if not bOk2 or not bClaimed then
		rec.note = "box is busy (claim refused)"
		return false
	end
	local bOk3, sErr = call(A, "UnboxAnimal", nID)
	if not bOk3 then
		rec.note = "unbox failed: " .. tostring(sErr)
		return false
	end
	rec.note = "unboxed"
	return true
end

Guard._Capture = function(self, t, nID, rec)
	local A = t.animals
	local bOk, nCost = call(A, "GetEmergencyCaptureCost")
	if not bOk or type(nCost) ~= "number" then
		rec.note = "emergency capture cost unknown"
		return false
	end
	local bOk2, bCan = call(t.money, "CanModifyCash", -nCost)
	if bOk2 and bCan == false then
		rec.note = "can't afford emergency capture (" .. tostring(nCost) .. ")"
		return false
	end
	local bOk3, sErr = call(A, "EmergencyCaptureAnimal", nID)
	if not bOk3 then
		rec.note = "emergency capture failed: " .. tostring(sErr)
		return false
	end
	rec.note = "emergency capture (" .. tostring(nCost) .. ")"
	return true
end

Guard._Block = function(self, t, nNow)
	if not self.tSettings.block then
		return
	end
	if self.nLastBlock ~= nil and nNow - self.nLastBlock < self.nBlockEvery and nNow >= self.nLastBlock then
		return
	end
	self.nLastBlock = nNow
	local bOk, sErr = call(t.animals, "SetEnableEscapes", false)
	local s = bOk and "on: escapes switched off" or ("FAILED: " .. tostring(sErr))
	if s ~= self.sBlock then
		self:Log("escape block " .. s)
	end
	self.sBlock = s
end

local tGrace = {
	loose = "nLooseGrace",
	boxedAway = "nBoxedAwayGrace",
	boxedHome = "nUnboxGrace",
}

Guard.Tick = function(self)
	local t = W()
	if not t or not t.animals then
		return
	end
	self.nTicks = self.nTicks + 1
	local nNow = now()
	self:_Block(t, nNow)
	local bPaused = self:IsPaused()
	self.bPaused = bPaused
	local tNew = {}
	for _, nID in ipairs(self:_Animals(t)) do
		local sState, nHab, sWhy = self:Classify(t, nID)
		if sState ~= "ok" and sState ~= "skip" then
			local rec = self.tSeen[nID]
			if not rec or rec.state ~= sState then
				-- a new state (escaped -> boxed by the keeper -> carried):
				-- keep what was done for this animal, so it counts once
				local old = rec
				rec = { state = sState, since = nNow, tries = 0, note = sWhy }
				rec.name = old and old.name or self:_Name(t, nID)
				rec.acted = old and old.acted
				rec.sent = old and old.sent
				rec.unboxed = old and old.unboxed
				local o = self.tOut[nID]
				if sState == "boxedHome" and o and o.at and nNow - o.at < self.nStayOut then
					-- out of the box a moment ago and back in already
					o.n = o.n + 1
					o.at = nil
					rec.bounces = o.n
					self:Log(rec.name .. ": back in the box after " .. o.n .. " unbox(es)")
					if o.n >= self.nBounceMax then
						rec.holdUntil = nNow + self.nHold
						rec.holdWhy = "the game keeps putting it back in the box (in Franchise the server may refuse)"
					end
				end
			end
			if rec.holdUntil and nNow < rec.holdUntil then
				rec.note = tostring(rec.holdWhy) .. "; left alone for "
					.. math.max(1, math.floor((rec.holdUntil - nNow) / 60 + 0.5)) .. " min"
			end
			rec.hab = nHab
			tNew[nID] = rec
			local sGrace = tGrace[sState]
			local bDue = sGrace ~= nil and nNow - rec.since >= self[sGrace]
				and (rec.last == nil or nNow - rec.last >= self.nRetry)
				and not (rec.holdUntil and nNow < rec.holdUntil)
			if bDue and not bPaused then
				self:_Act(t, nID, nHab, rec, nNow)
			elseif sGrace == nil then
				rec.note = sWhy
			end
		end
	end
	-- an animal that is fine again: say so once
	for nID, rec in pairs(self.tSeen) do
		if not tNew[nID] and rec.acted then
			if rec.unboxed then
				-- counted once it stays out (see nStayOut)
				local o = self.tOut[nID] or { n = 0 }
				o.at, o.name, o.counted = nNow, rec.name, false
				self.tOut[nID] = o
				self:Log(rec.name .. ": out of the box")
			elseif rec.sent then
				self.tCount.home = self.tCount.home + 1
				self:Log(rec.name .. ": back in its habitat")
			else
				self:Log(rec.name .. ": back to normal")
			end
		end
	end
	self.tSeen = tNew
	-- out of the box long enough: now it counts; old entries go
	for nID, o in pairs(self.tOut) do
		if o.at and not o.counted and nNow - o.at >= self.nStayOut then
			o.counted = true
			self.tCount.unboxed = self.tCount.unboxed + 1
		end
		if o.at == nil and not tNew[nID] then
			self.tOut[nID] = nil
		elseif o.counted and nNow - o.at >= self.nHold then
			self.tOut[nID] = nil
		end
	end
	self.nLastTick = nNow
end

Guard._Act = function(self, t, nID, nHab, rec, nNow)
	local sState = rec.state
	local bDone = false
	if sState == "boxedHome" then
		if not self.tSettings.unbox then
			return
		end
		rec.tries = (rec.tries or 0) + 1
		bDone = self:_Unbox(t, nID, nHab, rec)
		if bDone then
			rec.unboxed = true
			-- asked but still boxed at the next tries: the game ignores it
			if rec.tries >= self.nBounceMax then
				rec.holdUntil = nNow + self.nHold
				rec.holdWhy = "unboxed " .. rec.tries .. " times, still in the box"
				rec.note = rec.holdWhy .. "; left alone for " .. math.floor(self.nHold / 60) .. " min"
			end
		end
	else
		if not self.tSettings.ret then
			return
		end
		if sState == "loose" and self.tSettings.emergency and nNow - rec.since >= self.nEmergencyAfter then
			bDone = self:_Capture(t, nID, rec)
			if bDone then
				self.tCount.captured = self.tCount.captured + 1
				if not rec.sent then
					rec.sent = true
					self.tCount.returned = self.tCount.returned + 1
				end
			end
		end
		if not bDone then
			bDone = self:_SendHome(t, nID, nHab, rec)
			if bDone and not rec.sent then
				rec.sent = true
				self.tCount.returned = self.tCount.returned + 1
			end
		end
	end
	rec.last = nNow
	rec.acted = true
	local sWhat = sState == "loose" and "escaped" or (sState == "boxedHome" and "boxed in its habitat" or "boxed outside its habitat")
	self:Log(rec.name .. " (" .. sWhat .. "): " .. tostring(rec.note))
end

-----------------------------------------------------------------------
-- UI state (JSON text for the page)
-----------------------------------------------------------------------
local function jstr(s)
	s = tostring(s)
	s = string.gsub(s, '[%c"\\]', function(c)
		if c == '"' then return '\\"' end
		if c == "\\" then return "\\\\" end
		if c == "\n" then return "\\n" end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. s .. '"'
end

Guard.UIState = function(self)
	local nNow = now()
	local tRows = {}
	for nID, rec in pairs(self.tSeen) do
		tRows[#tRows + 1] = string.format('{"id":%s,"name":%s,"state":%s,"secs":%d,"tries":%d,"note":%s}',
			jstr(nID), jstr(rec.name), jstr(rec.state), math.floor(math.max(0, nNow - rec.since)),
			rec.tries or 0, jstr(rec.note or ""))
	end
	table.sort(tRows)
	local tLog = {}
	for _, s in ipairs(self.tLog) do
		tLog[#tLog + 1] = jstr(s)
	end
	local S = self.tSettings
	return string.format('{"boot":%s,"block":%s,"ret":%s,"unbox":%s,"emergency":%s,"blockState":%s,"paused":%s,'
		.. '"ticks":%d,"returned":%d,"home":%d,"unboxed":%d,"captured":%d,"times":[%d,%d,%d,%d,%d],'
		.. '"rows":[%s],"log":[%s]}',
		jstr(self.sBoot), tostring(S.block), tostring(S.ret), tostring(S.unbox), tostring(S.emergency), jstr(self.sBlock),
		tostring(self.bPaused == true), self.nTicks, self.tCount.returned, self.tCount.home, self.tCount.unboxed,
		self.tCount.captured, self.nLooseGrace, self.nBoxedAwayGrace, self.nUnboxGrace, self.nRetry,
		self.nEmergencyAfter, table.concat(tRows, ","), table.concat(tLog, ","))
end

-- raw facts per animal that is not "ok" (or the first few), for screenshots
Guard.Diagnose = function(self)
	local t = W()
	local tOut = {}
	if not t or not t.animals then
		return "no world APIs (not in a park?)"
	end
	local A = t.animals
	for _, s in ipairs({ "SetEnableEscapes", "IsEscaped", "IsAnimalBoxed", "GetAnimalTransportData",
		"IsAnimalUnboxableByPlayer", "ClaimBoxing", "UnboxAnimal", "RequestTransportToAssignedHabitat",
		"CanTransportToEntity", "AttemptRequestToTransportAnimalToTarget", "EmergencyCaptureAnimal" }) do
		local bOk, fn = pcall(function() return A[s] end)
		tOut[#tOut + 1] = s .. ": " .. ((bOk and type(fn) == "function") and "yes" or "MISSING")
	end
	local bOkS, fnS = pcall(function() return t.staff.CanStaffDeliverAnimalToFacility end)
	tOut[#tOut + 1] = "staff.CanStaffDeliverAnimalToFacility: " .. ((bOkS and type(fnS) == "function") and "yes" or "MISSING")
	tOut[#tOut + 1] = "escape block: " .. tostring(self.sBlock) .. "; paused " .. tostring(self:IsPaused())
	local nNow = now()
	tOut[#tOut + 1] = "ticks " .. self.nTicks .. ", last tick "
		.. (self.nLastTick and (math.floor(nNow - self.nLastTick) .. " s ago") or "never")
	for nID, rec in pairs(self.tSeen) do
		tOut[#tOut + 1] = string.format("tracking %s [%s]: %s for %d s, tries %d, bounces %d%s, note: %s", tostring(rec.name),
			tostring(nID), tostring(rec.state), math.floor(math.max(0, nNow - rec.since)), rec.tries or 0, rec.bounces or 0,
			rec.holdUntil and nNow < rec.holdUntil and ", ON HOLD" or "", tostring(rec.note))
	end
	for nID, o in pairs(self.tOut) do
		tOut[#tOut + 1] = string.format("out of box: %s [%s] %s, bounces %d", tostring(o.name), tostring(nID),
			o.at and (math.floor(nNow - o.at) .. " s ago" .. (o.counted and ", counted" or "")) or "back in the box", o.n or 0)
	end
	local tIDs = self:_Animals(t)
	tOut[#tOut + 1] = "animals checked: " .. #tIDs
	local nShown = 0
	for _, nID in ipairs(tIDs) do
		local sState, nHab, sWhy = self:Classify(t, nID)
		if sState ~= "ok" or nShown < 3 then
			nShown = nShown + 1
			if nShown > 25 then
				tOut[#tOut + 1] = "(more not shown)"
				break
			end
			local nLoc = ask(A, "GetCurrentLocationType", nID)
			local bBoxed = ask(A, "IsAnimalBoxed", nID)
			local bEsc = ask(A, "IsEscaped", nID)
			local tTr = ask(A, "GetAnimalTransportData", nID)
			local bUnbox = ask(A, "IsAnimalUnboxableByPlayer", nID)
			local bWants = ask(A, "DoesAnimalWantToBeLetOutOfBox", nID)
			tOut[#tOut + 1] = string.format("%s [%s] %s%s | loc %s boxed %s escaped %s job %s unboxable %s wantsOut %s hab %s",
				self:_Name(t, nID), tostring(nID), sState, sWhy ~= "" and (" (" .. sWhy .. ")") or "", tostring(nLoc),
				tostring(bBoxed), tostring(bEsc), tostring(type(tTr) == "table" and tTr.bHasTransportJob),
				tostring(bUnbox), tostring(bWants), tostring(nHab))
		end
	end
	return table.concat(tOut, "\n")
end
