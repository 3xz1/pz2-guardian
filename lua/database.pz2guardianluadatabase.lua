-----------------------------------------------------------------------
--  Database.PZ2GuardianLuaDatabase
--
--  Entry point. Database.Main calls tryrequire("Database.<Pack>LuaDatabase")
--  for every loaded content pack; this module boots PZ2Guardian once.
-----------------------------------------------------------------------
local global  = _G
local api     = global.api
local pcall   = global.pcall
local require = global.require

local PZ2GuardianLuaDatabase = module(...)

local Core = nil
local bOk, sErr = pcall(function()
	Core = require("PZ2Guardian.Core")
	Core:Boot()
end)
if not bOk then
	pcall(function() api.debug.Trace("[PZ2Guardian] boot failed: " .. global.tostring(sErr)) end)
end

-- Runs on the game's startup coroutine, so the UI overlay can be awaited here.
PZ2GuardianLuaDatabase.AddContentToCall = function(_tContentToCall)
	if Core then
		local bOk, sErr = pcall(Core.WaitUntilReady, Core)
		if not bOk then
			pcall(function() api.debug.Trace("[PZ2Guardian] WaitUntilReady failed: " .. global.tostring(sErr)) end)
		end
	end
end
