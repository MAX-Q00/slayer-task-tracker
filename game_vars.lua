--[[
  game_vars.lua
  Reads Slayer values the server already transmits to the client, using
  VarPlayer names from the FriendlyDevelopment/runescape-api-stubs lists
  (csvs/VarPlayer.csv):
    SLAYER_COUNT        (varp 183)  kills left on the current task
    SLAYER_TARGET       (varp 185)  task category id (no name enum found)
    SMKI_SLAYER_POINTS  (bit of 2092) Slayer point balance
    SLAYER_MASTER       (bit of 2092) assigning master id
  No task-streak variable exists in the list, so streak stays chat/manual.
  Every read is pcall-guarded and only starts a few seconds after load.
]]

local gameVars = {}

gameVars.NAMES = {
    remaining = "SLAYER_COUNT",
    target    = "SLAYER_TARGET",
    points    = "SMKI_SLAYER_POINTS",
    master    = "SLAYER_MASTER",
}

gameVars.ready = false   -- set by main.lua after the load delay
gameVars.live = false    -- true once any read returned a number

--- Read one variable. Returns a number or nil.
function gameVars.read(field)
    if not gameVars.ready then return nil end
    local name = gameVars.NAMES[field]
    if name == nil then return nil end
    local ok, value = pcall(function()
        local v = var.VarPlayer[name]
        return v and v.value
    end)
    if ok and type(value) == "number" then
        gameVars.live = true
        return value
    end
    return nil
end

function gameVars.anyConfigured() return gameVars.live end

return gameVars
