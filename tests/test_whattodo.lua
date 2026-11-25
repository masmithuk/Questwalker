-- Every quest in a step says what to do, and "On your way to" shows what
-- you'll be doing there.

local fixtures = require("fixtures")

local function stepFor(state, id)
    for _, s in ipairs(state.steps) do
        for _, q in ipairs(s.questIDs or {}) do
            if q == id and s.kind == "COMPLETE" then return s end
        end
    end
    return nil
end

return {
    { "a quest without counters says what it asks", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[106].objectivesText = { "Find the Valor family's farmhouse and search it for clues." }
        fixtures.addToLog(mock, 106, "The Valor Family", false)
        local step = stepFor(fixtures.login(ns), 106)
        T.truthy(step, "objective step")
        T.contains(step.lines, "  Find the Valor family's farmhouse and search it for clues.")
    end },

    { "no text either: points to the quest log", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[106].objectivesText = nil
        fixtures.addToLog(mock, 106, "The Valor Family", false)
        local step = stepFor(fixtures.login(ns), 106)
        T.contains(step.lines, "  " .. ns.L.STEP_SEE_QUEST_LOG)
    end },

    { "quests with counters show the counters only", function(T)
        local ns, mock = T.fresh()
        fixtures.durotar(mock)
        fixtures.addToLog(mock, 101, "Vile Familiars", false, { "Vile Familiar slain: 2/8" })
        local step = stepFor(fixtures.login(ns), 101)
        T.eq(#step.lines, 2)
    end },

    { "on the way: what you'll do at the destination", function(T)
        local ns = T.fresh()
        local function w(x) return { continent = 1, x = x, y = 0 } end
        local dest = { key = "d", kind = "COMPLETE", title = "Complete: Totem & The Valor Family",
            lines = { "The Valor Family", "  Search the farmhouse." }, target = { world = w(1000) } }
        local giver = { key = "g", kind = "ACCEPT", title = "Talk to Gerard", lines = {}, target = { world = w(300) } }
        local out = ns.Planner.AddOnTheWay(w(0), { dest }, { dest, giver }, 80, 10)
        local text = ns.GuideFrame.CurrentText(out[1])
        T.contains(text, "On your way to: Complete: Totem & The Valor Family")
        T.contains(text, "Search the farmhouse.")
    end },
}
