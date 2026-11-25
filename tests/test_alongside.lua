-- Quests whose creatures are everywhere are done alongside a quest that's
-- tied to one place, instead of being a trip of their own.

local function w(x, y) return { continent = 1, x = x, y = y } end

local function spawns(list)
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = { world = w(p[1], p[2]) } end
    return out
end

-- Protect the Frontier: prowlers and bears all over the zone.
local function frontier(nearest)
    return { key = "complete:52", kind = "COMPLETE", title = "Complete: Protect the Frontier",
        questTitle = "Protect the Frontier", questIDs = { 52 }, lines = { "Prowler slain: 0/8" },
        target = { world = nearest },
        areas = spawns({ { 0, 0 }, { 900, 100 }, { 500, 800 }, { 1020, 990 }, { 100, 700 } }) }
end

-- A Bundle of Trouble: bundles in one camp.
local function bundle(x, y)
    return { key = "complete:5545", kind = "COMPLETE", title = "Complete: A Bundle of Trouble",
        questTitle = "A Bundle of Trouble", questIDs = { 5545 }, lines = { "Bundle of Wood: 0/8" },
        target = { world = w(x, y) } }
end

return {
    { "a widespread quest is done alongside the place-tied one", function(T)
        local ns = T.fresh()
        local out = ns.Planner.GroupObjectives({ frontier(w(10, 10)), bundle(1000, 1000) }, nil, w(0, 0))
        T.eq(#out, 1, "one step")
        T.eq(out[1].title, "Complete: Protect the Frontier & A Bundle of Trouble")
        T.eq(out[1].target.world.x, 1000, "heads for the bundles, not the nearest prowler")
        T.contains(out[1].lines, "Prowler slain: 0/8")
        T.eq(out[1].asYouGo, "Protect the Frontier")
        T.contains(ns.GuideFrame.CurrentText(out[1]), "kill them as you go")
    end },

    { "no overlap: they stay apart", function(T)
        local ns = T.fresh()
        local out = ns.Planner.GroupObjectives({ frontier(w(10, 10)), bundle(3000, 3000) }, nil, w(0, 0))
        T.eq(#out, 2)
    end },

    { "spread is measured corner to corner", function(T)
        local ns = T.fresh()
        T.eq(ns.Planner.Spread({ areas = spawns({ { 0, 0 }, { 300, 400 } }) }), 500)
        T.eq(ns.Planner.Spread({}), 0)
        T.truthy(ns.Planner.Spread(frontier(w(0, 0))) > ns.Planner.AMBIENT_SPREAD)
    end },

    { "two place-tied quests far apart aren't joined through a widespread one", function(T)
        local ns = T.fresh()
        local a, b = bundle(1000, 1000), bundle(0, 700)
        b.key, b.questIDs, b.questTitle = "complete:9", { 9 }, "Other Camp"
        local out = ns.Planner.GroupObjectives({ frontier(w(10, 10)), a, b }, nil, w(0, 0))
        T.eq(#out, 2, "the frontier joins one camp, the camps stay separate")
    end },
}
