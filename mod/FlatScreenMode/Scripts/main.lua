-- FlatScreenMode bootstrap: loads flat.lua (the logic) and config.lua.
-- Typing "flatmode reload" in the game console re-reads both without restarting the game.
local DIR = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "ue4ss/Mods/FlatScreenMode/Scripts/"
local VERSION = "1.0"
local M = nil

local function say(msg) print("[FlatScreenMode] " .. msg .. "\n") end

local function loadLogic()
    local f, err = loadfile(DIR .. "flat.lua")
    if not f then say("load error: " .. tostring(err)); return end
    local ok, mod = pcall(f, DIR)
    if ok then M = mod; say("logic loaded (v" .. VERSION .. ")") else say("init error: " .. tostring(mod)) end
end
loadLogic()

-- ClientRestart (every map load / respawn) asks for onClientRestart 1.5 s later. Not with ExecuteWithDelay: its callback
-- runs Lua on UE4SS's async thread while the game thread runs the tick in the same Lua state. That crashed the game
-- inside UE4SS's Lua (v0.3.29: online lobby -> heist travel, the crash came 1.5 s after the new character spawned).
-- Everything here runs on the game thread: the hook only sets a time, the per-frame loop does the call.
local restartAt = nil

LoopInGameThreadAfterFrames(1, function()
    if restartAt and os.clock() >= restartAt then
        restartAt = nil
        if M then pcall(M.onClientRestart) end
    end
    if M then
        local ok, err = pcall(M.tick)
        if not ok then say("tick error: " .. tostring(err)) end
    end
    return false
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    restartAt = os.clock() + 1.5
end)

RegisterConsoleCommandGlobalHandler("flatmode", function(full, params)
    local name = (params and params[1]) or "status"
    ExecuteInGameThread(function()
        if name == "reload" then loadLogic() elseif M then M.command(name, params and params[2]) end
    end)
    return true
end)
