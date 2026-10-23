--[[
  masters.lua
  Best standard (non-Wilderness) RS3 Slayer Master the player qualifies for.
  Requirements from runescape.wiki/w/Slayer_master (checked 2026-10-22).
  Ordered best (most points) first. quest = config.Quest name; when a quest
  can't be read it is assumed done (never blocks).
  Left out: Mandrith (Wilderness), The Raptor (points vary by level and need
  Unwelcome Guests), Turael/Spria (no points; Jacquelyn covers level 0).
]]
local masters = {}

masters.LIST = {
    { name = "Laniakea", combat = 120, slayer = 90 },   -- + Anachronia intro (not checkable)
    { name = "Morvran",  combat = 120, slayer = 85, quest = "PLAGUES_END" },
    { name = "Kuradal",  combat = 110, slayer = 75 },   -- + Barbarian Firemaking (not checkable)
    { name = "Duradel",  combat = 100, slayer = 50, quest = "SHILO_VILLAGE" },
    { name = "Sumona",   combat = 90,  slayer = 35, quest = "SMOKING_KILLS" },
    { name = "Chaeldar", combat = 75,  slayer = 1,  quest = "LOST_CITY" },
    { name = "Mazchna",  combat = 50,  slayer = 1 },
    { name = "Vannaka",  combat = 30,  slayer = 1 },
    { name = "Jacquelyn", combat = 1,  slayer = 1 },
}

local function questDone(q)
    if q == nil then return true end
    local ok, v = pcall(function() return config.Quest[q].hasFinishedQuest end)
    if ok and type(v) == "boolean" then return v end
    return true   -- unknown: don't block
end

--- Returns the best master's name, or nil if levels can't be read.
function masters.best()
    local okC, cb = pcall(function() return Player.GetCombatLevel() end)
    local okS, sl = pcall(function() return Player.GetLevelGameplay(18) end)
    if not (okC and type(cb) == "number" and okS and type(sl) == "number") or cb <= 0 then return nil end
    for _, m in ipairs(masters.LIST) do
        if cb >= m.combat and sl >= m.slayer and questDone(m.quest) then return m.name end
    end
    return "Jacquelyn"
end

--[[
  Who assigned the current task: var.VarPlayer.SLAYER_MASTER (a varbit of
  varp 2092, per the runescape-api-stubs VarPlayer list). The wiki has no
  value table for it, so the mapping below is inferred from the game's own
  NPC config names in the stubs (SLAYER_MASTER_1_TUREAL, _2_MAZCHNA, _3, _4,
  _5_DURADEL, _6_KURADAL, _7_IORWERTH, _8_DINO_ISLAND) and the OSRS varbit
  of the same name (1 Turael, 2 Mazchna, 3 Vannaka, 4 Chaeldar, 5 Duradel).
  At runtime we first try the game's SLAYER_MASTER_ENUM for a name.
]]
masters.LOCATION = {
    ["Turael"] = "Burthorpe", ["Spria"] = "Burthorpe", ["Jacquelyn"] = "Lumbridge",
    ["Vannaka"] = "Edgeville", ["The Raptor"] = "Fort Forinthry",
    ["Mazchna"] = "Canifis", ["Achtryn"] = "Canifis", ["Chaeldar"] = "Zanaris",
    ["Sumona"] = "Pollnivneach", ["Duradel"] = "Shilo Village", ["Lapalok"] = "Shilo Village",
    ["Kuradal"] = "Ancient Cavern", ["Morvran"] = "Prifddinas", ["Laniakea"] = "Anachronia",
    ["Mandrith"] = "Wilderness",
}
masters.BY_ID = {
    [1] = "Turael", [2] = "Mazchna", [3] = "Vannaka", [4] = "Chaeldar",
    [5] = "Duradel", [6] = "Kuradal", [7] = "Morvran", [8] = "Laniakea",
}

masters.lastRaw = nil

local function nameFromEnum(v)
    local ok, out = pcall(function()
        return config.Enum.SLAYER_MASTER_ENUM:GetOutputValue(v)
    end)
    if not ok or out == nil then return nil end
    if type(out) == "string" and out ~= "" then return out end
    if type(out) == "number" and out > 0 then
        local okN, n = pcall(function() return config.NPC.FromID(out).name end)
        if okN and type(n) == "string" and n ~= "" then return n end
    end
    return nil
end

--- "Laniakea (Anachronia)", or nil if unknown/unreadable.
function masters.current()
    local ok, v = pcall(function() return var.VarPlayer.SLAYER_MASTER.value end)
    if not ok or type(v) ~= "number" or v <= 0 then return nil end
    masters.lastRaw = v
    local name = nameFromEnum(v)
    if name ~= nil then
        -- Enum names may include a title; match a known master inside it.
        for known, _ in pairs(masters.LOCATION) do
            if string.find(name, known, 1, true) then name = known break end
        end
    else
        name = masters.BY_ID[v]
    end
    if name == nil then return nil end
    local loc = masters.LOCATION[name]
    return loc and (name .. " (" .. loc .. ")") or name
end

return masters
