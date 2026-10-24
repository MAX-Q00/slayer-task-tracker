--[[
  Slayer Task Tracker
  -------------------
  Shows your current Slayer task, kills remaining, task streak and progress
  toward a Slayer point goal you choose, plus how many tasks until the next
  10th / 50th task bonus.

  Guideline notes for moderators:
    * Display and logging only. No inputs, menu entries or server actions.
    * Only player-known information is used: messages already shown in the
      player's own chat box, values typed in by the player, and (optionally)
      player variables the server already transmits to the client.
    * No permissions (0.11.0 removed the optional chatAccess). Task, kills
      left, points and master come from transmitted player variables; the
      streak is entered by the player in Edit.
]]

local PLUGIN_NAME = "Slayer Task Tracker"

local helpers  = require("ui_helpers")
helpers.VERSION = "0.11.24"
local SLAYER = 18   -- SkillType.SLAYER
local gameVars = require("game_vars")
local masters  = require("masters")
local taskNames = require("task_names")

-------------------------------------------------------------------------------
-- Saved state
-------------------------------------------------------------------------------

local STATE_KEY = "state"

-- Everything the panel shows. Saved after every change so a client crash
-- loses nothing (the database tutorial notes PluginShutdown can be skipped).
local okLoad, loaded = pcall(function() return PersistentDB:GetStructuredData(STATE_KEY) end)
if not okLoad then helpers.log("[Slayer Task Tracker] ERROR loading state: " .. tostring(loaded)) end
local state = (okLoad and loaded) or {}
state.monster     = helpers.cleanText(state.monster, 32)   -- e.g. "abyssal demons"; sanitised on load
if state.namedMonster ~= nil then state.namedMonster = helpers.cleanText(state.namedMonster, 32) end
if state.pendingName ~= nil then state.pendingName = helpers.cleanText(state.pendingName, 32) end
state.assigned    = state.assigned or 0   -- kills given at assignment
state.remaining   = state.remaining or 0  -- kills left
state.streak      = state.streak or 0     -- tasks completed in a row
state.points      = state.points or 0     -- Slayer point balance
state.goal        = state.goal or 0       -- player's target balance (0 = none)
state.pointsLog   = state.pointsLog or {} -- points earned on recent tasks
state.history     = type(state.history) == "table" and state.history or {}   -- 0.11.21: last 10 tasks { m, k }

local function save()
    pcall(function() PersistentDB:SetStructuredData(STATE_KEY, state) end)
end

-------------------------------------------------------------------------------
-- Derived values
-------------------------------------------------------------------------------

--- Average points earned per task over the last 20 completions (or nil).
local function averagePoints()
    local n = #state.pointsLog
    if n == 0 then return nil end
    local sum = 0
    for _, p in ipairs(state.pointsLog) do sum = sum + p end
    return sum / n
end

--- Tasks until the next streak multiple of `every` (e.g. 10 or 50).
-- Slayer masters award bonus points on every 10th and 50th task.
local function tasksUntilMultiple(every)
    local nextMultiple = (state.streak // every + 1) * every
    return nextMultiple - state.streak
end

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------

local lines = {}

local function slayerLine()
    local okL, lvl = pcall(function() return Player.GetLevelGameplay(SLAYER) end)
    local okX, xp = pcall(function() return Player.GetXPCapped(SLAYER) end)
    if not okL or lvl == nil then return "<col=808080>unavailable</col>" end
    local x = okX and xp or nil
    if type(x) == "number" then
        return formatStr("{}  ({} xp)", lvl, (string.format("%d", x // 1):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")))
    end
    return tostring(lvl)
end

local H = helpers
local emptyText = nil
local sourceText = nil
local panelRoot = nil
local lastTarget = nil
state.source = state.source or "manual"

-- Session-only kill-rate tracking for the ETA line (never saved).
local clockSecs = 0          -- seconds since load (1 Hz tick)
local sessXP = {}            -- 0.11.21: Slayer xp at load / now (session gain)
local rate = { first = nil, firstLeft = nil, lastLeft = nil, t = nil }
local seenNoTask = false     -- saw "no task" this session, so the next task is a fresh assignment
local completionSound = nil
local function playDone()
    if not state.doneSound then return end
    pcall(function() if completionSound ~= nil then completionSound:Stop() end end)
    completionSound = nil
    pcall(function()
        local inst = audio.Play(4065)   -- Sound.csv TASK_COMPLETE_01 (built-in)
        if inst ~= nil then inst:Start() end
        completionSound = inst
    end)
end
local function taskComplete(name, kills)
    table.insert(state.history, 1, { m = helpers.cleanText(tostring(name), 32), k = tonumber(kills) or 0 })
    while #state.history > 10 do table.remove(state.history) end
    pcall(save)
    helpers.showToast("Slayer task complete: " .. tostring(name) .. (kills and kills > 0 and (" (" .. kills .. " kills)") or ""), 8)
    playDone()
end

--- Pull task data from game vars (1 Hz, after load). Returns true if live.
local function pullVars()
    local remaining = gameVars.read("remaining")
    if remaining == nil then return false end
    local target = gameVars.read("target")
    local points = gameVars.read("points")
    if points ~= nil then state.points = points end
    if remaining > 0 then
        -- New assignment: count went up, or the target changed.
        if remaining > state.remaining or (target ~= nil and target ~= state.targetId) then
            state.assigned = remaining
            -- Fresh assignment only if we saw "no task" earlier this session;
            -- otherwise the plugin started mid-task and the total is a guess.
            state.midTask = not seenNoTask
            rate = { first = nil }
            if target ~= state.targetId or state.monster == "" then
                local cacheName = nil
                pcall(function() cacheName = taskNames.get(target) end)
                state.monster = cacheName or (state.namedTarget == target and state.namedMonster) or ("Task #" .. tostring(target))
            end
            state.targetId = target
        end
        if state.targetId ~= nil and string.sub(state.monster, 1, 6) == "Task #" then
            local n = nil
            pcall(function() n = taskNames.get(state.targetId) end)
            if n ~= nil then state.monster = n end
        end
        if remaining < state.remaining then
            if rate.first == nil then rate.first, rate.firstLeft = clockSecs, state.remaining end
            rate.lastLeft, rate.t = remaining, clockSecs
        end
        state.remaining = remaining
        if state.assigned < remaining then state.assigned = remaining end   -- max seen
    else
        if state.remaining > 0 and state.monster ~= "" then taskComplete(state.monster, state.assigned) end
        state.remaining = 0
        state.monster = ""
        seenNoTask = true
        rate = { first = nil }
    end
    state.source = "game vars"
    return true
end

local barBg, barFill = nil, nil
local editParts = {}
local editDivider = nil
local VAL_X = 64   -- one left edge for every value
-- 0.11.23: the label / value border is adjustable (shared helpers.columns).
local valCols, valHandle = nil, nil
local settingsUI = nil
state.show = state.show or {}
for _, k in ipairs({ "master", "streak", "points", "level", "bar", "eta", "history" }) do
    if state.show[k] == nil then state.show[k] = true end
end
if state.suggest == nil then state.suggest = true end
if state.showManual == nil then state.showManual = false end

local function layoutRows(hasTask)
    -- Task row, thin progress bar, then Master/Streak/Points/Level.
    local y = H.rowY(1)
    if valCols then VAL_X = valCols:get("label") end
    if valHandle then
        valHandle:setHidden(not hasTask)
        valHandle:place(H.PAD + VAL_X - 3, y, H.ROW_HEIGHT)
    end
    local function place(cells, show)
        for ci, c in ipairs(cells or {}) do
            helpers.safe(function()
                c.hidden = not show
                if ci == 1 then c:SetSize(VAL_X - 2, H.ROW_HEIGHT) else c:SetSize(-(2 * H.PAD + VAL_X), H.ROW_HEIGHT, 1.0, 0.0) end
                c:SetPos(ci == 1 and H.PAD or (H.PAD + VAL_X), y)
            end)
        end
        if show then y = y + H.ROW_HEIGHT end
    end
    place(lines[1], hasTask)
    place(lines[7], hasTask)   -- 0.11.10: kill count on its own line
    helpers.safe(function() emptyText:SetPos(H.PAD, H.rowY(1)); emptyText.hidden = hasTask end)
    if not hasTask then y = y + H.ROW_HEIGHT end
    local bar = hasTask and state.show.bar
    helpers.setHidden({ barBg }, not bar)
    if not bar then helpers.setHidden({ barFill }, true) end
    if bar then
        helpers.safe(function() barBg:SetPos(H.PAD, y) end)
        helpers.safe(function() barFill:SetPos(H.PAD, y) end)
        y = y + 8
    end
    place(lines[6], hasTask and state.show.eta and lines[6] ~= nil and lines[6].shown)
    place(lines[5], hasTask and state.show.master)
    local KEY = { [2] = "streak", [3] = "points", [4] = "level" }
    for _, i in ipairs({ 2, 3, 4 }) do place(lines[i], lines[i] ~= nil and lines[i].shown and state.show[KEY[i]]) end
    for i = 8, 17 do place(lines[i], lines[i] ~= nil and lines[i].shown and state.show.history) end
    local open = state.showManual == true
    helpers.setHidden(editParts, not open)
    helpers.setHidden({ editDivider }, not open)
    if open then
        helpers.safe(function() editDivider:SetPos(H.PAD, y + 2) end)
        y = y + 6
        local x = H.PAD
        for _, e in ipairs(editParts) do
            helpers.safe(function() e:SetPos(x, y) end)
            pcall(function() x = x + e.width + 4 end)
        end
        y = y + H.ROW_HEIGHT
    end
    if settingsUI ~= nil then
        settingsUI.open = state.editOpen == true
        y = settingsUI:place(y)
    end
    -- 0.11.21: 10px bottom padding; min width fits the task name and count.
    local minW = 0
    pcall(function()
        local a = H.PAD + VAL_X + helpers.textWidthOf(helpers.FONT, tostring(state.monster ~= "" and state.monster or "Mutated jadinkos")) + H.PAD + 8
        local b = H.PAD + VAL_X + helpers.textWidthOf(helpers.FONT, "9999 left of 9999") + H.PAD + 8
        minW = math.min(360, math.floor(math.max(a, b)))
    end)
    if minW > 0 then pcall(helpers.setMinWidth, minW) end
    helpers.fitHeight(y + 10)
end

local function refresh()
    local hasTask = state.monster ~= "" and state.remaining > 0
    local w = 300
    pcall(function() w = panelRoot.width end)

    local values = {}
    if hasTask then
        local total = (state.midTask and "~" or "") .. state.assigned
        -- 0.11.10: name alone (ellipsized, full name on hover); count below.
        values[1] = { H.lbl("Task"), H.val(state.monster) }
        values[7] = { H.lbl("Left"), H.gold(state.remaining) .. H.lbl(" left of ") .. H.val(total) }
        -- ETA: needs 3+ kills seen this session on this task.
        if rate.first ~= nil and rate.lastLeft ~= nil and rate.t > rate.first then
            local kills = rate.firstLeft - rate.lastLeft
            if kills >= 3 then
                local perSec = kills / (rate.t - rate.first)
                local perHour = math.floor(perSec * 3600 + 0.5)
                local left = math.ceil(state.remaining / perSec / 60)
                local xs = ""
                if sessXP.start ~= nil and sessXP.now ~= nil and sessXP.now > sessXP.start then
                    xs = " - " .. helpers.commas(sessXP.now - sessXP.start) .. " xp"
                end
                values[6] = { H.lbl("ETA"), H.val("~" .. left .. " min") .. H.lbl(" - " .. perHour .. " kills/h" .. xs) }
            end
        end
        local who = nil
        pcall(function() who = masters.current() end)
        values[5] = { H.lbl("Master"), who and H.val(who) or H.lbl("unknown") }
    end
    -- Streak is manual (no game variable exists for it); hidden while 0.
    if state.streak > 0 then
        local nb = (state.streak // 10 + 1) * 10
        local big = nil
        for _, m in ipairs({ 50, 100, 250, 1000 }) do local nm = (state.streak // m + 1) * m; if big == nil or nm < big then if nm ~= nb then big = nm end end end
        values[2] = { H.lbl("Streak"), H.val(state.streak) .. H.lbl(", next bonus ") .. H.gold(nb) .. (big and H.lbl(", big ") .. H.val(big) or "") }
    end
    if state.points > 0 or state.goal > 0 then
        local pts = H.val(state.points)
        if state.goal > 0 then pts = pts .. H.lbl(" of " .. state.goal .. " goal") end
        values[3] = { H.lbl("Points"), pts }
    end
    local okL, lvl = pcall(function() return Player.GetLevelGameplay(SLAYER) end)
    if okL and type(lvl) == "number" then
        local lv = H.val(lvl)
        local okX, xp = pcall(function() return Player.GetXPCapped(SLAYER) end)
        if okX and type(xp) == "number" then sessXP.start = sessXP.start or xp; sessXP.now = xp end
        if okX and type(xp) == "number" and w >= 260 then
            local n = string.format("%d", xp // 1):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
            lv = lv .. H.lbl(" (" .. n .. " xp)")
        end
        values[4] = { H.lbl("Level"), lv }
    end
    -- 0.11.21: last tasks (newest first, up to 10)
    for i = 1, 10 do
        local h = state.history[i]
        values[7 + i] = h and { i == 1 and H.lbl("History") or "", H.val(h.m) .. H.lbl("  " .. (h.k > 0 and (h.k .. " kills") or "")) } or nil
    end
    for i = 1, 17 do
        if lines[i] ~= nil then
            helpers.setRow(lines[i], values[i])
            lines[i].shown = values[i] ~= nil
        end
    end
    if emptyText ~= nil then
        helpers.safe(function()
            local best = nil
            pcall(function() best = masters.best() end)
            if not state.suggest then best = nil end
            helpers.setText(emptyText, H.lbl("No task. Speak to a Slayer Master" .. (best and (" (Best: " .. best .. ")") or "")))
        end)
    end
    if hasTask and barFill ~= nil then
        local done = 0
        if state.assigned > 0 then done = (state.assigned - state.remaining) / state.assigned end
        helpers.safe(function()
            local full = barBg.width
            barFill:SetSize(math.max(1, math.floor(full * done + 0.5)), 4)
            barFill.hidden = done <= 0 or not state.show.bar
        end)
    end
    if sourceText ~= nil then
        local src = "Source: " .. state.source
        if masters.lastRaw ~= nil then src = src .. " | master id " .. tostring(masters.lastRaw) end
        helpers.setText(sourceText, H.lbl(src), "content")
    end
    layoutRows(hasTask)
end

local function buildPanel(root)
    panelRoot = root
    lines = {}
    valCols = helpers.columns("task", { label = { w = 64, min = 40, max = 200 } }, function() pcall(refresh) end)
    VAL_X = valCols:get("label")
    local cols = { { x = H.PAD, w = VAL_X - 2 }, { x = H.PAD + VAL_X, w = -(2 * H.PAD + VAL_X), pw = 1.0 } }
    for i = 1, 17 do lines[i] = helpers.tableRow(root, 1, cols) end
    emptyText = helpers.textRow(root, 1, "")
    valHandle = valCols:handle(root, "label", 1, "Drag to resize the label / value columns (Settings > Column widths > Reset).")
    pcall(function()
        barBg = ui.Rectangle.new(root)
        barBg.fill = true -- 0.11.7: Rectangle.fill defaults to false (outline only)
        barBg:SetSize(-2 * H.PAD, 4, 1.0, 0.0)
        barBg.colour = Vector4.new(120/255, 104/255, 58/255, 0.45)   -- 0.11.21: visible bronze track
        barFill = ui.Rectangle.new(root)
        barFill.fill = true
        barFill:SetSize(1, 4)
        barFill.colour = Vector4.new(0.96, 0.75, 0.20, 1.0)   -- gold
    end)

    -- Manual entry (shown via the "Manual task entry" setting).
    pcall(function()
        editDivider = ui.Rectangle.new(root)
        editDivider.fill = true
        editDivider:SetSize(-2 * H.PAD, 1, 1.0, 0.0)
        editDivider.colour = Vector4.new(120/255, 104/255, 58/255, 1.0)
    end)
    local monsterField = helpers.input(root, H.PAD, 0, 110, 18, "Monster")
    local killsField = helpers.input(root, 0, 0, 44, 18, "Kills")
    pcall(function() killsField:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NUMERIC, 5) end)
    local setBtn = helpers.button(root, 0, 0, 58, 18, "Set task", function()
        local kills = helpers.cleanInt(killsField.content, 1, 9999)
        local mon = helpers.cleanText(monsterField.content, 24)
        if mon ~= "" and kills ~= nil then
            state.monster, state.assigned, state.remaining = mon, kills, kills
            state.source = "manual"
            if state.targetId ~= nil then state.namedTarget, state.namedMonster = state.targetId, mon end
            save()
            refresh()
        end
    end)
    local undoBtn = helpers.button(root, 0, 0, 64, 18, "Undo kill", function()
        if state.remaining < state.assigned then
            state.remaining = state.remaining + 1
            save()
            refresh()
        end
    end)
    editParts = { monsterField, killsField, setBtn, undoBtn }
    local items = helpers.commonItems(function() refresh() end)
    local function sbool(get, set, label, a, b)
        table.insert(items, { label = label, options = { a or "Shown", b or "Hidden" },
            get = function() return get() and 1 or 2 end,
            set = function(i) set(i == 1); save(); refresh() end })
    end
    for _, k in ipairs({ { "master", "Master row" }, { "streak", "Streak row" }, { "points", "Points row" },
                         { "level", "Level row" }, { "bar", "Progress bar" }, { "eta", "ETA line" }, { "history", "Task history" } }) do
        sbool(function() return state.show[k[1]] end, function(v) state.show[k[1]] = v end, k[2])
    end
    table.insert(items, 1, { labelFn = function() return "Task streak: " .. state.streak end, options = { "+1" },
        get = function() return 1 end, set = function() state.streak = state.streak + 1; save(); refresh() end })
    table.insert(items, 2, { label = "Correct streak", options = { "-1" },
        get = function() return 1 end, set = function() state.streak = math.max(0, state.streak - 1); save(); refresh() end })
    sbool(function() return state.doneSound == true end, function(v) state.doneSound = v end, "Task-complete sound", "On", "Off")
    sbool(function() return state.showManual end, function(v) state.showManual = v end, "Manual task entry")
    sbool(function() return state.suggest end, function(v) state.suggest = v end, "Best master hint", "On", "Off")
    settingsUI = helpers.newSettings(root, items, 6)
    settingsUI.onChange = function() refresh() end
    helpers.editToggle(root, function() return state.editOpen == true end, function(v)
        state.editOpen = v
        save()
        refresh()
    end)
    -- Source line is a diagnostic only.
    if helpers.DEBUG then
        sourceText = helpers.textRow(root, 0, "")
        table.insert(editParts, sourceText)
    end
    refresh()
end

-------------------------------------------------------------------------------
-- Settings: point goal, streak and balance corrections
-------------------------------------------------------------------------------

local function numberSetting(root, row, label, key)
    helpers.textRow(root, row, label)
    local f = helpers.input(root, 5, 5 + (row + 1) * helpers.ROW_HEIGHT, 100, 24, "0")
    f:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NUMERIC, 7)
    f.content = tostring(state[key])
    f:Subscribe(ui.Hook.ONCONTENTCHANGED, function(c, reason, newContents)
        local n = helpers.cleanInt(newContents, 0, 9999999)
        if n ~= nil then
            state[key] = n
            save()
        end
    end)
end

helpers.subscribe(PLUGIN_NAME, "SettingsLayerReady", "sttSettings", function(e)
    local root = e.component
    numberSetting(root, 0, "Slayer point goal (0 = none):", "goal")
    numberSetting(root, 3, "Current Slayer points:", "points")
    numberSetting(root, 6, "Current task streak:", "streak")
    helpers.button(root, 5, 5 + 9 * helpers.ROW_HEIGHT, 140, 24, "Clear points history", function()
        state.pointsLog = {}
        save()
    end)
end)

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------


-- Game vars: polled once a second, starting 3 s after load (never during load).
local varTicks, varSecs = 0, 0
helpers.subscribe(PLUGIN_NAME, "Logic", "sttVars", function()
    varTicks = varTicks + 1
    if varTicks < 50 then return end
    varTicks = 0
    varSecs = varSecs + 1
    clockSecs = clockSecs + 1
    if varSecs < 3 then return end
    gameVars.ready = true
    local before = state.remaining .. "|" .. state.points .. "|" .. state.monster
    if pullVars() then
        if state.pendingName ~= nil and state.targetId ~= nil then
            state.namedTarget, state.namedMonster = state.targetId, state.pendingName
            state.monster, state.pendingName = state.pendingName, nil
        end
        if before ~= state.remaining .. "|" .. state.points .. "|" .. state.monster then save() end
    end
    refresh()
end)

-- Kill counting without chat: every Slayer XP drop while a task is active
-- counts as one kill (Slayer XP is only awarded for on-task kills).
helpers.subscribe(PLUGIN_NAME, "SkillTransmit", "sttXp", function(e)
    if e.skill ~= SLAYER then return end
    local gained = (e.newXP or 0) - (e.oldXP or 0)
    if gained > 0 and state.monster ~= "" and state.remaining > 0 and not gameVars.live then
        state.remaining = state.remaining - 1
        save()
        if state.remaining == 0 then taskComplete(state.monster, state.assigned) end
    end
    refresh()
end)

-- Toast countdown runs on the 50 Hz logic tick.
helpers.subscribe(PLUGIN_NAME, "Logic", "sttLogic", function() helpers.tickToast() end)


-------------------------------------------------------------------------------
-- Window: shown immediately on enable (official tutorial pattern)
-------------------------------------------------------------------------------

local window = nil

--- Create the window and fill it. Safe to call repeatedly; it only does work
-- until the window exists. Retried once per second from the Logic tick
-- because the game window may not exist yet (e.g. enabled from the lobby).
local function tryCreateWindow()
    if window ~= nil then return end
    window = helpers.createWindow(PLUGIN_NAME, 300, 200, 0.02, 0.45)
    if window ~= nil then
        local ok, err = pcall(buildPanel, window)
        helpers.raiseGrip()
        if not ok then
            helpers.log("[" .. PLUGIN_NAME .. "] ERROR building panel: " .. tostring(err))
        end
    end
end

tryCreateWindow()

local retryTicks = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "windowRetry", function()
    if window == nil then
        retryTicks = retryTicks + 1
        if retryTicks >= 50 then
            retryTicks = 0
            tryCreateWindow()
        end
    end
end)

-- Lobby guard: re-read vars a few seconds after (re)login.
table.insert(helpers.onLogin, function() varSecs = 0; gameVars.ready = false end)

helpers.installRibbon(PLUGIN_NAME)
helpers.log("[" .. PLUGIN_NAME .. "] loaded")

function PluginShutdown()
    save()
    helpers.destroyToast()
    helpers.destroyWindow()
end
