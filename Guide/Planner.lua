--[[
    Questwalker - Guide/Planner.lua

    Pure route planning: takes candidate steps that already know where they
    are, merges steps at the same NPC, groups quest objectives in the same
    area into one step, and orders them into a walking route.

    No game API calls in here - everything arrives as plain tables, so the
    whole file is covered by tests/test_planner.lua.

    Step shape
      key       stable identity, e.g. "accept:npc:1234" or "train:12"
      kind      "TURNIN" | "ACCEPT" | "COMPLETE" | "TRAIN" | "BUY" | "NOTE" | "HEARTH"
      title     short headline ("Talk to Grull Hawkwind")
      lines     list of detail lines (quest names, objectives)
      questIDs  quests this step covers (for skipping and completion)
      actor     optional "npc:<id>" / "object:<id>" used for merging
      target    optional { mapID, x, y, world = { continent, x, y } }
      manual    true when the player must click Done
      bonus     yards this step is treated as closer than it is (set by
                the mode's rules: hand-ins, story follow-ups, dungeon quests)
]]

local _, ns = ...

local Planner = {}
ns.Planner = Planner

-- Order used to break ties between steps at the same spot:
-- hand quests in before picking up the follow-ups.
local KIND_ORDER = { TURNIN = 1, ACCEPT = 2, TRAIN = 3, HEARTH = 4, BUY = 5, DUNGEON = 6, COMPLETE = 7, NOTE = 8 }

-- Cost of a step on another continent, or with no comparable position.
local FAR_AWAY = 1e6
local UNKNOWN_POSITION = 5e5

--- Merge ACCEPT, TURNIN and DUNGEON steps that share an actor (the same NPC) into a
--- single step listing every quest.
function Planner.Merge(steps)
    local merged, byKey = {}, {}
    for _, step in ipairs(steps) do
        local mergeKey = step.actor and (step.kind .. ":" .. step.actor) or nil
        local existing = mergeKey and byKey[mergeKey]
        if existing then
            for _, line in ipairs(step.lines or {}) do
                existing.lines[#existing.lines + 1] = line
            end
            for _, id in ipairs(step.questIDs or {}) do
                existing.questIDs[#existing.questIDs + 1] = id
            end
            -- A merged step is as attractive as its best part.
            existing.bonus = math.max(existing.bonus or 0, step.bonus or 0)
            existing.target = existing.target or step.target
            -- Only "pass by" when every part is.
            if not step.passBy then existing.passBy = nil end
        else
            local copy = {}
            for k, v in pairs(step) do copy[k] = v end
            copy.lines = { unpack(step.lines or {}) }
            copy.questIDs = { unpack(step.questIDs or {}) }
            if mergeKey then
                copy.key = mergeKey:lower()
                byKey[mergeKey] = copy
            end
            merged[#merged + 1] = copy
        end
    end
    return merged
end

-- Objectives this close together (yards) are done as one step.
Planner.GROUP_RADIUS = 150
-- A quest whose creatures spread over more than this (yards, corner to
-- corner) can be done anywhere along the way: it's folded into a nearby
-- quest that's tied to one place.
Planner.AMBIENT_SPREAD = 450
local AREA_SAMPLE = 80 -- spawn points checked when comparing areas

--- How far a step's hunting area spreads (yards, corner to corner of its
--- spawns), or 0 when it has no area.
function Planner.Spread(step)
    if step.spread then return step.spread end
    local minX, minY, maxX, maxY, continent
    for _, p in ipairs(step.areas or {}) do
        local w = p.world
        if w and (not continent or w.continent == continent) then
            continent = w.continent
            minX, maxX = math.min(minX or w.x, w.x), math.max(maxX or w.x, w.x)
            minY, maxY = math.min(minY or w.y, w.y), math.max(maxY or w.y, w.y)
        end
    end
    local spread = 0
    if minX then spread = math.sqrt((maxX - minX) ^ 2 + (maxY - minY) ^ 2) end
    step.spread = spread
    return spread
end

--- Are any of a step's spawns within `radius` of a world position?
function Planner.AreaNear(step, world, radius)
    if not world then return false end
    local list = step.areas or {}
    local every = math.max(1, math.floor(#list / AREA_SAMPLE))
    for i = 1, #list, every do
        local w = list[i].world
        if w and w.continent == world.continent and ns.Util.Distance(w, world) <= radius then return true end
    end
    return false
end

local function near(a, b, radius)
    return a and b and a.continent == b.continent and ns.Util.Distance(a, b) <= radius
end

--- "A", "A & B", "A, B & C"
function Planner.JoinNames(names)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " & " .. names[#names]
end

--- Group COMPLETE steps whose objectives are in the same area (each
--- within `radius` of another in the group) into one step, so quests
--- like "Cutting Teeth" and "Wayward Weapons" are done together. The
--- group points at the member nearest to `origin`.
-- @return new list of steps (other steps untouched)
function Planner.GroupObjectives(steps, radius, origin)
    radius = radius or Planner.GROUP_RADIUS
    local out, solo = {}, {}
    for _, step in ipairs(steps) do
        if step.kind == "COMPLETE" and step.target and step.target.world then
            solo[#solo + 1] = step
        else
            out[#out + 1] = step
        end
    end
    -- Deterministic order (the quest log arrives in no particular order).
    table.sort(solo, function(a, b) return (a.questIDs[1] or 0) < (b.questIDs[1] or 0) end)

    -- Quests whose creatures are everywhere (Protect the Frontier) are
    -- done alongside a nearby quest that's tied to one place (A Bundle of
    -- Trouble) rather than as a trip of their own.
    local specific, ambient = {}, {}
    for _, step in ipairs(solo) do
        if Planner.Spread(step) > Planner.AMBIENT_SPREAD then
            ambient[#ambient + 1] = step
        else
            specific[#specific + 1] = step
        end
    end

    local groups = {}
    for _, step in ipairs(specific) do
        local home
        for _, g in ipairs(groups) do
            for _, member in ipairs(g) do
                if near(member.target.world, step.target.world, radius) then home = g; break end
            end
            if home then break end
        end
        if home then home[#home + 1] = step else groups[#groups + 1] = { step } end
    end

    for _, step in ipairs(ambient) do
        -- Join the nearest place-tied group its creatures are found around.
        local home, homeDist
        for _, g in ipairs(groups) do
            local anchor = g[1].target.world
            if g.anchorOnly ~= false and Planner.AreaNear(step, anchor, radius) then
                local d = origin and anchor.continent == origin.continent and ns.Util.Distance(origin, anchor) or 0
                if not home or d < homeDist then home, homeDist = g, d end
            end
        end
        if home then
            home[#home + 1] = step
            home.alongside = true
        else
            groups[#groups + 1] = { step, anchorOnly = false }
        end
    end

    for _, g in ipairs(groups) do
        if #g == 1 then
            out[#out + 1] = g[1]
        else
            local ids, names, lines, keys = {}, {}, {}, {}
            local areas, targets, asYouGo = {}, {}, {}
            local best, bestDist, bonus = g[1], math.huge, 0
            local anchored = g.alongside -- head for the place-tied quests, not the widespread one
            -- Names and lines in quest order, however the group was formed.
            table.sort(g, function(x, y) return (x.questIDs[1] or 0) < (y.questIDs[1] or 0) end)
            for _, m in ipairs(g) do
                for _, id in ipairs(m.questIDs) do ids[#ids + 1] = id end
                for _, a in ipairs(m.areas or {}) do areas[#areas + 1] = a end
                for _, t in ipairs(m.targets or { m.target }) do targets[#targets + 1] = t end
                names[#names + 1] = m.questTitle or m.title
                for _, l in ipairs(m.lines or {}) do lines[#lines + 1] = l end
                keys[#keys + 1] = m.key
                bonus = math.max(bonus, m.bonus or 0)
                local d = origin and m.target.world.continent == origin.continent
                    and ns.Util.Distance(origin, m.target.world) or math.huge
                local eligible = not anchored or Planner.Spread(m) <= Planner.AMBIENT_SPREAD
                if not eligible then asYouGo[#asYouGo + 1] = m.questTitle or m.title end
                if eligible and d < bestDist then best, bestDist = m, d end
            end
            out[#out + 1] = {
                key = table.concat(keys, "+"),
                kind = "COMPLETE",
                title = "Complete: " .. Planner.JoinNames(names),
                lines = lines,
                questIDs = ids,
                target = best.target,
                targets = targets,
                areas = #areas > 0 and areas or nil,
                asYouGo = #asYouGo > 0 and Planner.JoinNames(asYouGo) or nil,
                bonus = bonus > 0 and bonus or nil,
                grouped = #g,
            }
        end
    end
    return out
end

--- Yards between two world positions, with penalties for the unknown.
function Planner.Cost(from, step)
    local to = step.target and step.target.world
    local cost
    if not from or not to then
        cost = UNKNOWN_POSITION
    elseif from.continent ~= to.continent then
        cost = FAR_AWAY
    else
        cost = ns.Util.Distance(from, to)
    end
    return cost - (step.bonus or 0)
end

local function better(a, costA, b, costB)
    if costA ~= costB then return costA < costB end
    local oa, ob = KIND_ORDER[a.kind] or 99, KIND_ORDER[b.kind] or 99
    if oa ~= ob then return oa < ob end
    return a.key < b.key
end

--- Order steps by repeatedly walking to the nearest remaining one.
-- @param origin   player's world position { continent, x, y } or nil
-- @param steps    candidate steps (merged)
-- @param pinnedKey key of the current step; kept first while it exists
--                 so the route doesn't jump around as you walk
-- @param limit    maximum number of steps to return
function Planner.Order(origin, steps, pinnedKey, limit)
    local remaining = {}
    for i = 1, #steps do remaining[i] = steps[i] end

    local ordered = {}
    local position = origin

    local function take(index)
        local step = table.remove(remaining, index)
        ordered[#ordered + 1] = step
        if step.target and step.target.world then
            position = step.target.world
        end
    end

    if pinnedKey then
        for i, step in ipairs(remaining) do
            if step.key == pinnedKey then take(i); break end
        end
    end

    while #remaining > 0 and #ordered < (limit or math.huge) do
        local bestIndex, bestCost = 1, Planner.Cost(position, remaining[1])
        for i = 2, #remaining do
            local cost = Planner.Cost(position, remaining[i])
            if better(remaining[i], cost, remaining[bestIndex], bestCost) then
                bestIndex, bestCost = i, cost
            end
        end
        take(bestIndex)
    end
    return ordered
end

-- Quick stops worth making on the way: they take seconds once you're there.
local QUICK_KINDS = { ACCEPT = true, TURNIN = true }
Planner.ON_THE_WAY_MAX = 4
-- A quest giver this close (yards) with a quest sharing enemies with the
-- step you're heading for is visited first, detour or not.
Planner.SHARED_RANGE = 600

--- Pick up and hand in quests on the way to the current step. Any quick
--- stop (an ACCEPT or TURNIN from the candidates) that adds at most
--- `maxDetour` yards to the walk there, and is nearer than the step, goes
--- first, nearest first. They're marked onTheWayTo = the step's key, so
--- the step stays the one being walked to.
-- @param ordered the route from Planner.Order (its first step is where you're heading)
-- @param pool    every candidate step (merged), so pickups planned for much later count
function Planner.AddOnTheWay(origin, ordered, pool, maxDetour, limit)
    local dest = ordered[1]
    local to = dest and dest.target and dest.target.world
    if not (origin and to and maxDetour and maxDetour > 0) or origin.continent ~= to.continent then
        return ordered
    end
    if QUICK_KINDS[dest.kind] and dest.onTheWayTo then return ordered end
    local direct = ns.Util.Distance(origin, to)
    -- Quests sharing enemies with the one you're heading out to do.
    local heading = {}
    for _, id in ipairs(dest.questIDs or {}) do heading[id] = true end
    local picks = {}
    for _, step in ipairs(pool) do
        local at = step.target and step.target.world
        local together = false
        for _, id in ipairs(step.sharedWith or {}) do
            if heading[id] then together = true; break end
        end
        if together and at and at.continent == origin.continent and step.key ~= dest.key
            and ns.Util.Distance(origin, at) <= Planner.SHARED_RANGE then
            picks[#picks + 1] = { step = step, d = ns.Util.Distance(origin, at) }
            at = nil -- taken; skip the detour test below
        end
        -- Steps the guide marks down (Story's side quests) aren't worth a stop.
        if step ~= dest and QUICK_KINDS[step.kind] and at and at.continent == origin.continent
            and step.key ~= dest.key and (step.bonus or 0) >= 0 then
            local first = ns.Util.Distance(origin, at)
            local detour = first + ns.Util.Distance(at, to) - direct
            if first < direct and detour <= maxDetour then
                picks[#picks + 1] = { step = step, d = first }
            end
        end
    end
    if #picks == 0 then return ordered end
    table.sort(picks, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.step.key < b.step.key
    end)
    local out, used = {}, {}
    for i = 1, math.min(#picks, Planner.ON_THE_WAY_MAX) do
        local step = picks[i].step
        step.onTheWayTo = dest.key
        step.onTheWayTitle = dest.title
        step.onTheWayLines = dest.lines
        out[#out + 1] = step
        used[step] = true
    end
    for _, step in ipairs(ordered) do
        if not used[step] and #out < (limit or math.huge) then out[#out + 1] = step end
    end
    return out
end

--- Choose the point closest to `origin` from a list of map points that
--- have already been given world positions.
function Planner.Nearest(origin, points)
    local best, bestDist
    for _, p in ipairs(points) do
        local d
        if origin and p.world and p.world.continent == origin.continent then
            d = ns.Util.Distance(origin, p.world)
        else
            d = UNKNOWN_POSITION
        end
        if not bestDist or d < bestDist then
            best, bestDist = p, d
        end
    end
    return best, bestDist
end

--- Full planning pass: merge, then order.
function Planner.Build(origin, steps, pinnedKey, limit)
    return Planner.Order(origin, Planner.GroupObjectives(Planner.Merge(steps), nil, origin), pinnedKey, limit)
end
