--[[
    Questwalker - UI/TargetButton.lua

    "Target" button: each press targets a quest creature near you, starting
    with the nearest. Pressing again moves to the next one of that kind
    (the game rotates through creatures with the same name, as /target
    does). Right-click (or its own key binding) switches to the next kind
    of creature, nearest kind first.

    Why not one rotation through every kind? The game's targeting commands
    that rotate through units don't take a name, and those that take a name
    only rotate through units with that name. Repeating the same name is
    what lets the game step through the creatures around you.

    Why it's built this way
      * Addons may not call TargetUnit; targeting has to come from a
        hardware click on a secure button. So this is a
        SecureActionButton running the macro "/targetexact <name>".
      * Addon code can't change a secure button during combat, but a
        secure snippet running inside the button can. So, out of combat,
        Questwalker stores the sorted creature list on the button as
        attributes (fp-name1..N, fp-count), and a secure pre-click snippet
        steps to the next name and rewrites the macro on every press -
        which keeps working mid-fight.
      * The button listens to both mouse-down and mouse-up (so key bindings
        work whatever your "cast on key down" setting is); the snippet lets
        exactly one of them through so each press moves one step.
      * Shift is reserved for moving: Shift + left-drag moves the button and
        a Shift-click doesn't target anything.

    The buttons are small icons in a row, one per group of creatures: kinds
    that share their last word ("Forest Spider", "Venom Web Spider":
    Spiders) or a first word that isn't just describing them ("Defias
    Trapper", "Defias Smuggler": Defias). Each shows the group's icon, a
    short label underneath and, for a group of several kinds, how many.
    Right-click goes to the next kind in that group. Hover for the kinds,
    their progress and which one a click targets. The first button
    (QuestwalkerTargetButton) is the nearest group; the others
    (QuestwalkerTargetButton2..6) line up to its right and have their own
    key bindings. They're their own small frames rather than part of the
    guide window: protected buttons inside the guide window would stop that
    window from resizing during combat.

    The creature list (pure; tested):
      * only the guide's current step, and only when it's a "complete
        objectives" step (pick-ups, hand-ins and trainers hide the button)
      * that step's quests that aren't ready to hand in yet
      * their creature objectives and creatures that drop their quest items
        (objects can't be targeted)
      * skipping creatures whose kill objective is already finished
      * one entry per creature, sorted by its nearest spawn
]]

local _, ns = ...

local TargetButton = {}
ns.TargetButton = TargetButton

local L = ns.L

local FRAME_NAME = "QuestwalkerTargetButton" -- referenced by Bindings.xml
local MAX_TARGETS = 8
local MAX_EXTRA = 5 -- extra group buttons (2nd to 6th group)

local extras = {} -- per-creature buttons, created on first need

local button, header
local pendingList     -- chosen in combat, applied after
local appliedKey      -- signature of the list on the button
local lastNames       -- every creature on the buttons, nearest first

-- Runs in the secure (restricted) environment before every click.
-- `self` is the button; returning false cancels the click.
local PRE_CLICK = [[
    if IsShiftKeyDown() then return false end
    if (down and true or false) ~= (self:GetAttribute("fp-usedown") and true or false) then
        return false
    end
    local count = self:GetAttribute("fp-count") or 0
    if count == 0 then return false end
    local index = self:GetAttribute("fp-index") or 0
    if index == 0 then
        index = 1 -- first press: the nearest kind
    elseif button == "RightButton" then
        index = index % count + 1 -- the next kind of creature
    end
    -- Left presses repeat the name, so the game steps through each creature of that kind.
    self:SetAttribute("fp-index", index)
    self:SetAttribute("macrotext", "/targetexact " .. self:GetAttribute("fp-name" .. index))
]]
TargetButton.PRE_CLICK = PRE_CLICK

---------------------------------------------------------------------------
-- Choosing the creatures (pure)
---------------------------------------------------------------------------

--- Is the objective naming this creature already done?
local function killDone(name, objectives)
    local finished, open = false, false
    for _, o in ipairs(objectives) do
        if o.text:find(name, 1, true) then
            if o.finished then finished = true else open = true end
        end
    end
    return finished and not open
end

--- Add each targetable creature for one quest to `found` (name -> distance).
local function collectForQuest(questID, origin, found)
    local objectives = ns.GameApi.GetObjectives(questID)
    for _, t in ipairs(ns.QuestieData.GetObjectiveTargets(questID)) do
        if t.kind == "npc" and t.name ~= "" and not killDone(t.name, objectives) then
            for _, p in ipairs(t.points) do
                if p.world == nil then
                    p.world = ns.GameApi.GetWorldPosition(p.mapID, p.x, p.y) or false
                end
            end
            local _, dist = ns.Planner.Nearest(origin, t.points)
            dist = dist or math.huge
            if not found[t.name] or dist < found[t.name] then
                found[t.name] = dist
            end
        end
    end
end

---------------------------------------------------------------------------
-- Grouping (pure)
---------------------------------------------------------------------------

-- Words that describe a creature rather than say what it is, so they
-- don't make two creatures the same kind ("Young Wolf", "Young Boar").
local DESCRIBING = {
    young = true, elder = true, old = true, greater = true, lesser = true, large = true, small = true,
    giant = true, dark = true, black = true, grey = true, gray = true, white = true, red = true,
    green = true, blue = true, mottled = true, rabid = true, wild = true, feral = true, savage = true,
    frenzied = true, corrupted = true, diseased = true, plagued = true, starving = true, mangy = true,
    forest = true, mountain = true, venom = true, cave = true, rock = true, timber = true,
}

-- Icons for kinds of creature (a word in the group's name). The first
-- match wins; anything else gets a crosshair.
local ICONS = {
    { "spider", "Interface\\Icons\\Spell_Nature_Web" },
    { "wolf", "Interface\\Icons\\Ability_Hunter_Pet_Wolf" },
    { "worg", "Interface\\Icons\\Ability_Hunter_Pet_Wolf" },
    { "boar", "Interface\\Icons\\Ability_Hunter_Pet_Boar" },
    { "bear", "Interface\\Icons\\Ability_Hunter_Pet_Bear" },
    { "cat", "Interface\\Icons\\Ability_Hunter_Pet_Cat" },
    { "lion", "Interface\\Icons\\Ability_Hunter_Pet_Cat" },
    { "panther", "Interface\\Icons\\Ability_Hunter_Pet_Cat" },
    { "tiger", "Interface\\Icons\\Ability_Hunter_Pet_Cat" },
    { "prowler", "Interface\\Icons\\Ability_Hunter_Pet_Cat" },
    { "raptor", "Interface\\Icons\\Ability_Hunter_Pet_Raptor" },
    { "crocolisk", "Interface\\Icons\\Ability_Hunter_Pet_Crocolisk" },
    { "gorilla", "Interface\\Icons\\Ability_Hunter_Pet_Gorilla" },
    { "scorpid", "Interface\\Icons\\Ability_Hunter_Pet_Scorpid" },
    { "bat", "Interface\\Icons\\Ability_Hunter_Pet_Bat" },
    { "owl", "Interface\\Icons\\Ability_Hunter_Pet_Owl" },
    { "crab", "Interface\\Icons\\Ability_Hunter_Pet_Crab" },
    { "turtle", "Interface\\Icons\\Ability_Hunter_Pet_Turtle" },
    { "hyena", "Interface\\Icons\\Ability_Hunter_Pet_Hyena" },
    { "vulture", "Interface\\Icons\\Ability_Hunter_Pet_Vulture" },
    { "tallstrider", "Interface\\Icons\\Ability_Hunter_Pet_TallStrider" },
    { "strider", "Interface\\Icons\\Ability_Hunter_Pet_TallStrider" },
    { "wind serpent", "Interface\\Icons\\Ability_Hunter_Pet_WindSerpent" },
    { "serpent", "Interface\\Icons\\Ability_Hunter_Pet_WindSerpent" },
    { "harpy", "Interface\\Icons\\Ability_Hunter_Pet_Vulture" },
    { "murloc", "Interface\\Icons\\INV_Misc_Head_Murloc_01" },
    { "kobold", "Interface\\Icons\\INV_Misc_Head_Kobold_01" },
    { "gnoll", "Interface\\Icons\\INV_Misc_Head_Gnoll_01" },
    { "troll", "Interface\\Icons\\INV_Misc_Head_Troll_01" },
    { "orc", "Interface\\Icons\\INV_Misc_Head_Orc_01" },
    { "skeleton", "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01" },
    { "zombie", "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01" },
    { "ghoul", "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01" },
    { "elemental", "Interface\\Icons\\Spell_Nature_EarthElemental_Totem" },
    { "ooze", "Interface\\Icons\\INV_Misc_Slime_01" },
    { "slime", "Interface\\Icons\\INV_Misc_Slime_01" },
    { "basilisk", "Interface\\Icons\\Ability_Hunter_Pet_Crocolisk" },
    { "thresher", "Interface\\Icons\\INV_Misc_Fish_02" },
    { "shark", "Interface\\Icons\\INV_Misc_Fish_02" },
    { "dragon", "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
    { "whelp", "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
    { "drake", "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
}
local DEFAULT_ICON = "Interface\\Icons\\Ability_Hunter_SniperShot"

local function words(name)
    local out = {}
    for w in name:gmatch("[%a']+") do out[#out + 1] = w:lower() end
    return out
end

--- The icon for a kind of creature.
function TargetButton.IconFor(label)
    local lower = (label or ""):lower()
    for _, entry in ipairs(ICONS) do
        if lower:find(entry[1], 1, true) then return entry[2] end
    end
    return DEFAULT_ICON
end

local function plural(word)
    if word:sub(-1) == "y" and not word:sub(-2, -2):match("[aeiou]") then return word:sub(1, -2) .. "ies" end
    if word:sub(-1) == "s" or word:sub(-1) == "x" or word:sub(-2) == "ch" then return word .. "es" end
    if word:sub(-2) == "lf" then return word:sub(1, -3) .. "lves" end
    return word .. "s"
end

local function titleCase(word)
    return word:sub(1, 1):upper() .. word:sub(2)
end

--- Put creatures of the same kind together: those sharing their last word
--- ("Forest Spider", "Venom Web Spider": Spiders), else their first word
--- when it isn't just describing them ("Defias Trapper", "Defias
--- Smuggler": Defias). Groups keep the order of their nearest member.
-- @param names creature names, nearest first
-- @return list of { label, icon, names }
function TargetButton.Group(names)
    local lastOf, firstOf, lastCount, firstCount = {}, {}, {}, {}
    for _, name in ipairs(names) do
        local w = words(name)
        local last, first = w[#w] or name:lower(), w[1] or name:lower()
        lastOf[name], firstOf[name] = last, first
        lastCount[last] = (lastCount[last] or 0) + 1
        if #w > 1 and not DESCRIBING[first] then firstCount[first] = (firstCount[first] or 0) + 1 end
    end
    local groups, byKey = {}, {}
    for _, name in ipairs(names) do
        local key, label
        if lastCount[lastOf[name]] > 1 then
            key = "last:" .. lastOf[name]
            label = titleCase(plural(lastOf[name]))
        elseif (firstCount[firstOf[name]] or 0) > 1 then
            key = "first:" .. firstOf[name]
            label = titleCase(firstOf[name])
        else
            key, label = "name:" .. name, name
        end
        local g = byKey[key]
        if not g then
            g = { label = label, names = {} }
            byKey[key] = g
            groups[#groups + 1] = g
        end
        g.names[#g.names + 1] = name
    end
    for _, g in ipairs(groups) do
        g.icon = TargetButton.IconFor(table.concat(g.names, " "))
    end
    return groups
end

--- Creature names to cycle through for the current step, nearest first.
--- Only a step that sends you to do objectives has targets; turn-ins,
--- pick-ups and trainer visits leave the button hidden.
-- @param step   the guide's current step (may be nil)
-- @param log    quest log from GameApi.GetQuestLog()
-- @param origin player's world position (may be nil)
function TargetButton.BuildList(step, log, origin)
    if step and step.kind == "GRIND" then
        return step.grindNames or {} -- the mobs to grind on, nearest first
    end
    local found = {}
    if step and step.kind == "COMPLETE" then
        for _, questID in ipairs(step.questIDs or {}) do
            local quest = log[questID]
            if quest and not quest.complete then collectForQuest(questID, origin, found) end
        end
    end
    local list = {}
    for name, dist in pairs(found) do list[#list + 1] = { name = name, dist = dist } end
    table.sort(list, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end)
    local names = {}
    for i = 1, math.min(#list, MAX_TARGETS) do names[i] = list[i].name end
    return names
end

---------------------------------------------------------------------------
-- The secure button
---------------------------------------------------------------------------

local function savePosition(f)
    local point, _, relativePoint, x, y = f:GetPoint(1)
    local saved = ns.Settings.account.target
    saved.point, saved.relativePoint, saved.x, saved.y = point, relativePoint, x, y
end

local function restorePosition(f)
    local saved = ns.Settings.account.target
    f:ClearAllPoints()
    f:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
end

local ICON_SIZE = 34
local ICON_GAP = 4

--- The creature this button's next left press targets.
local function currentName(b)
    local count = b:GetAttribute("fp-count") or 0
    if count == 0 then return nil end
    local index = b:GetAttribute("fp-index") or 0
    if index == 0 then index = 1 end
    return b:GetAttribute("fp-name" .. index), index, count
end

--- Hover: the group, which creature a press targets, and how to use it.
local function showTooltip(b)
    if not GameTooltip or not b.group then return end
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText(b.group.label)
    local current = currentName(b)
    for _, name in ipairs(b.group.names) do
        local progress
        for _, text in ipairs(b.progress or {}) do
            if text:find(name, 1, true) then progress = text:match("(%d+%s*/%s*%d+)") end
        end
        local line = (name == current and "> " or "  ") .. name .. (progress and ("  " .. progress) or "")
        if name == current then
            GameTooltip:AddLine(line, 1, 0.82, 0)
        else
            GameTooltip:AddLine(line, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(#b.group.names > 1 and L.TARGET_HINT_GROUP or L.TARGET_HINT, 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end

local function onPostClick(b)
    if GameTooltip and GameTooltip:IsOwned(b) then showTooltip(b) end
end

--- One square icon button for a group of creatures. Button 1 is the
--- one with the saved position and key bindings; the rest line up to its
--- right and have their own bindings.
local function createIcon(i)
    local name = i == 1 and FRAME_NAME or (FRAME_NAME .. i)
    local b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate")
    b:SetSize(ICON_SIZE, ICON_SIZE)
    b:SetAttribute("type", "macro")
    b:SetAttribute("macrotext", "")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:EnableMouse(true)
    b:RegisterForDrag("LeftButton")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetPoint("TOPLEFT", -2, 2)
    b.border:SetPoint("BOTTOMRIGHT", 2, -2)
    b.border:SetColorTexture(0, 0, 0, 0.8)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("TOP", b, "BOTTOM", 0, -1)
    b.label:SetWidth(ICON_SIZE + ICON_GAP + 8)
    b.label:SetWordWrap(false)

    if i == 1 then
        b:SetMovable(true)
        b:SetClampedToScreen(true)
        restorePosition(b)
    else
        local prev = i == 2 and button or extras[i - 2]
        b:SetPoint("LEFT", prev, "RIGHT", ICON_GAP, 0)
    end
    -- Shift + left-drag on any of them moves the whole row.
    b:SetScript("OnDragStart", function()
        if IsShiftKeyDown() and not ns.GameApi.InCombat() then button:StartMoving() end
    end)
    b:SetScript("OnDragStop", function()
        button:StopMovingOrSizing()
        savePosition(button)
    end)
    b:SetScript("OnEnter", showTooltip)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:HookScript("PostClick", onPostClick)

    if not header then header = CreateFrame("Frame", nil, UIParent, "SecureHandlerBaseTemplate") end
    SecureHandlerWrapScript(b, "OnClick", header, PRE_CLICK)
    b:Hide()
    return b
end

--- Store one group's creatures on a button.
local function fill(b, group, useDown, progress)
    local oldCount = b:GetAttribute("fp-count") or 0
    local names = group and group.names or {}
    for k = 1, math.max(oldCount, #names) do b:SetAttribute("fp-name" .. k, names[k]) end
    b:SetAttribute("fp-count", #names)
    b:SetAttribute("fp-index", 0) -- next press: the nearest again
    b:SetAttribute("fp-usedown", useDown)
    b:SetAttribute("macrotext", names[1] and ("/targetexact " .. names[1]) or "")
    b.group, b.progress = group, progress
    if group then
        b.icon:SetTexture(group.icon)
        b.count:SetText(#names > 1 and tostring(#names) or "")
        b.label:SetText(group.label)
        b:Show()
    else
        b:Hide()
    end
end

--- The current step's objective texts ("Vile Familiar slain: 2/8").
local function progressOf(state)
    local out = {}
    local step = state and state.steps and state.steps[1]
    for _, questID in ipairs(step and step.questIDs or {}) do
        for _, o in ipairs(ns.GameApi.GetObjectives(questID)) do out[#out + 1] = o.text end
    end
    return out
end

--- Store a creature list on the buttons (out of combat only).
local function apply(names, progress)
    if ns.GameApi.InCombat() then
        pendingList = { names = names, progress = progress }
        return
    end
    pendingList = nil
    if not button then button = createIcon(1) end
    if not ns.Settings.account.targetButton then names = {} end

    local key = table.concat(names, "\n")
    if key == appliedKey then
        button.progress = progress
        for _, b in ipairs(extras) do b.progress = progress end
        return
    end
    appliedKey = key
    lastNames = names

    local groups = TargetButton.Group(names)
    local useDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") or false
    fill(button, groups[1], useDown, progress)
    for i = 1, MAX_EXTRA do
        local group = groups[i + 1]
        if group and not extras[i] then extras[i] = createIcon(i + 1) end
        if extras[i] then fill(extras[i], group, useDown, progress) end
    end
end

--- Rebuild the creature list from the guide's current step.
-- @param state Engine.state (uses .steps[1] and .log)
-- @param origin player's world position
function TargetButton.Update(state, origin)
    apply(TargetButton.BuildList(state.steps and state.steps[1], state.log or {}, origin), progressOf(state))
end

--- Why the button is or isn't showing, for /qw debug.
function TargetButton.Describe(state)
    local step = state.steps and state.steps[1]
    local names = TargetButton.BuildList(step, state.log or {}, state.origin)
    local why
    if not ns.Settings.account.targetButton then
        why = "turned off in Settings"
    elseif pendingList then
        why = "waiting for combat to end"
    elseif not step then
        why = "hidden: no current step"
    elseif step.kind ~= "COMPLETE" then
        why = ("hidden: the current step is %s (%s), not a Complete step"):format(step.kind, step.title or "?")
    elseif #names == 0 then
        why = "hidden: the current step's quests have no creatures left to kill in QuestieDB"
    else
        why = "showing"
    end
    return ("target button %s; creatures: %s"):format(why, #names > 0 and table.concat(names, ", ") or "none")
end

--- Apply a list chosen during combat.
function TargetButton.OnCombatEnded()
    if pendingList then apply(pendingList.names, pendingList.progress) end
end

function TargetButton.SetEnabled(enabled)
    ns.Settings.account.targetButton = enabled and true or false
    appliedKey = nil -- force the next apply to redraw
    TargetButton.Update(ns.Engine.state, ns.Engine.state.origin)
end

function TargetButton.ResetPosition()
    if button and not ns.GameApi.InCombat() then restorePosition(button) end
end

--- For tests: every creature on the buttons, nearest first.
function TargetButton.GetNames()
    local names = {}
    for i, name in ipairs(lastNames or {}) do names[i] = name end
    return names
end

--- For tests: the groups on show, as "Label: name, name".
function TargetButton.GetGroups()
    local out = {}
    for _, b in ipairs({ button, unpack(extras) }) do
        if b and b:IsShown() and b.group then
            out[#out + 1] = b.group.label .. ": " .. table.concat(b.group.names, ", ")
        end
    end
    return out
end

function TargetButton.GetMacro()
    return button and button:GetAttribute("macrotext")
end

--- For tests: the extra group buttons that are showing.
function TargetButton.GetExtraButtons()
    local out = {}
    for _, b in ipairs(extras) do
        if b:IsShown() then out[#out + 1] = b end
    end
    return out
end
