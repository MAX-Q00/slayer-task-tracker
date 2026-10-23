--[[
  task_names.lua
  Slayer task name from the SLAYER_TARGET id, using the game's own cache
  configs (names from the runescape-api-stubs lists), so no hand-made table:
    1. Enum SLAYER_MASTER_<X>_ENUM: target id -> struct; struct param
       SLAYER_NAME holds the display name.
    2. Enum SMKI_CRITTER_NAMES: target id -> name string (fallback)
  Every step is pcall-guarded; nil means "unknown" (caller shows Task #id).
  Results are cached per id.
]]
local names = {}
local cache = {}

local MASTER_ENUMS = { "SLAYER_MASTER_LANIAKEA_ENUM", "SLAYER_MASTER_MORVRAN_ENUM",
    "SLAYER_MASTER_KURADAL_ENUM", "SLAYER_MASTER_DURADEL_ENUM", "SLAYER_MASTER_SUMONA_ENUM",
    "SLAYER_MASTER_CHAELDAR_ENUM", "SLAYER_MASTER_MAZCHNA_ENUM", "SLAYER_MASTER_VANNAKA_ENUM",
    "SLAYER_MASTER_RAPTOR_ENUM", "SLAYER_MASTER_JACQUELYN_ENUM", "SLAYER_MASTER_TURAEL_ENUM",
    "SLAYER_MASTER_MANDRITH_ENUM" }

local function clean(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("<[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "null" then return nil end
    return s
end

local function enumOut(enumName, key)
    local ok, v = pcall(function() return config.Enum[enumName]:GetOutputValue(key) end)
    if ok then return v end
    return nil
end

local function structName(sid)
    if type(sid) ~= "number" or sid < 0 then return nil end
    local ok, v = pcall(function()
        return config.Struct.FromID(sid):GetParamValue(config.Param.SLAYER_NAME)
    end)
    if ok then return clean(v) end
    return nil
end

function names.get(id)
    if type(id) ~= "number" or id <= 0 then return nil end
    if cache[id] ~= nil then return cache[id] or nil end
    local found = nil
    for _, e in ipairs(MASTER_ENUMS) do
        local out = enumOut(e, id)
        found = structName(out) or clean(out)
        if found ~= nil then break end
    end
    if found == nil then found = clean(enumOut("SMKI_CRITTER_NAMES", id)) end
    cache[id] = found or false
    return found
end

return names
