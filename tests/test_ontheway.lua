-- Quest givers and hand-ins you pass are done on the way.

local fixtures = require("fixtures")

local function w(x, y) return { continent = 1, x = x, y = y } end
local function step(key, kind, x, y, extra)
    local s = { key = key, kind = kind, title = key, target = { world = w(x, y) } }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

return {
    { "a quest giver beside the path is visited first", function(T)
        local ns = T.fresh()
        local dest = step("dest", "COMPLETE", 1000, 0)
        local giver = step("giver", "ACCEPT", 400, 30)       -- 30 yd off the line
        local far = step("far", "ACCEPT", 400, 300)          -- well off it
        local out = ns.Planner.AddOnTheWay(w(0, 0), { dest, far }, { dest, giver, far }, 80, 10)
        T.eq(out[1].key, "giver"); T.eq(out[1].onTheWayTo, "dest")
        T.eq(out[1].onTheWayTitle, "dest")
        T.eq(out[2].key, "dest")
        T.eq(out[3].key, "far", "the rest keep their order")
    end },

    { "nearest first, and nothing past the destination", function(T)
        local ns = T.fresh()
        local dest = step("dest", "COMPLETE", 1000, 0)
        local a = step("a", "TURNIN", 700, 10)
        local b = step("b", "ACCEPT", 200, 0)
        local beyond = step("beyond", "ACCEPT", 1050, 0)
        local out = ns.Planner.AddOnTheWay(w(0, 0), { dest }, { dest, a, b, beyond }, 80, 10)
        T.eq(out[1].key, "b"); T.eq(out[2].key, "a"); T.eq(out[3].key, "dest")
        T.eq(#out, 3)
    end },

    { "side quests the guide marks down aren't stopped for", function(T)
        local ns = T.fresh()
        local dest = step("dest", "COMPLETE", 1000, 0)
        local side = step("side", "ACCEPT", 400, 0, { bonus = -350 })
        local out = ns.Planner.AddOnTheWay(w(0, 0), { dest }, { dest, side }, 80, 10)
        T.eq(out[1].key, "dest")
    end },

    { "0 turns it off", function(T)
        local ns = T.fresh()
        local dest = step("dest", "COMPLETE", 1000, 0)
        local out = ns.Planner.AddOnTheWay(w(0, 0), { dest }, { dest, step("g", "ACCEPT", 400, 0) }, 0, 10)
        T.eq(out[1].key, "dest")
    end },

    { "a quest from much later in the list is picked up when you pass", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Npc[1004] = { name = "Gornek", spawns = { [14] = { { 47, 50.3 } } } } -- between you and Zureetha
        db.Quest[107] = { name = "Later On", startedBy = { { 1004 } }, finishedBy = { { 1004 } },
            requiredLevel = 1, questLevel = 6 }
        local quests = { { id = 101 } }
        for i = 1, 12 do quests[#quests + 1] = { step = "note", text = "Filler " .. i } end
        quests[#quests + 1] = { id = 107 }
        QuestwalkerDB.guides["custom-later"] = {
            format = "Questwalker guide", version = 2, name = "Later", basedOn = "efficient",
            rules = { maxAccept = 1 }, quests = quests,
            bands = { { levels = { 1, 60 }, zones = { "Durotar" } } },
        }
        ns.Library.Init()
        QuestwalkerCharDB.routeId = "custom-later"
        QuestwalkerCharDB.guide.trainedLevel = 60
        local state = fixtures.login(ns)
        T.eq(fixtures.heading(state).title, "Talk to Zureetha Fargaze")
        local first = state.steps[1]
        T.eq(first.title, "Talk to Gornek", "picked up on the way")
        T.contains(ns.GuideFrame.CurrentText(first), "On your way to: Talk to Zureetha Fargaze")
    end },
}
