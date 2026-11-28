-- Wandering off doesn't take the guide with you: a level 2 human in
-- Stormwind is sent back to Northshire. (Here: a level 2 orc in the
-- Barrens is sent back to Durotar.)

local fixtures = require("fixtures")

return {
    { "new quests come from the guide's zones, not where you stand", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock, { level = 2, mode = "efficient" })
        QuestwalkerCharDB.guide.trainedLevel = 60
        -- A low quest right here in the Barrens...
        db.Quest[109] = { name = "Barrens Errand", startedBy = { { 1003 } }, finishedBy = { { 1003 } },
            requiredLevel = 1, questLevel = 2 }
        mock.player.position = { mapID = 1413, x = 0.5, y = 0.5 } -- standing in the Barrens
        local state = fixtures.login(ns)
        for _, s in ipairs(state.steps) do
            for _, id in ipairs(s.questIDs or {}) do T.truthy(id ~= 109, "not the Barrens quest") end
        end
        local first = fixtures.heading(state)
        T.truthy(first and first.target and first.target.mapID == 1411,
            "heading back to Durotar: " .. tostring(first and first.title))
    end },

    { "quests that can't be picked up are never suggested", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[579] = { name = "Stormwind Library", startedBy = { { 1001 } }, finishedBy = { { 1001 } },
            requiredLevel = 1, questLevel = 3 }
        local state = fixtures.login(ns)
        local ctx = ns.Engine.BuildContext()
        T.eq(ns.QuestieData.IsDoable(579, ctx), false)
        for _, s in ipairs(state.steps) do
            for _, id in ipairs(s.questIDs or {}) do T.truthy(id ~= 579) end
        end
    end },

    { "Questie's hidden quests count too", function(T)
        local ns, mock = T.fresh()
        fixtures.durotar(mock)
        fixtures.login(ns)
        _G.QuestieLoader = { ImportModule = function(_, name)
            if name == "QuestieCorrections" then return { hiddenQuests = { [102] = true } } end
            return nil
        end }
        T.eq(ns.QuestieData.IsUnavailable(102), true)
        T.eq(ns.QuestieData.IsUnavailable(101), false)
        _G.QuestieLoader = nil
    end },
}
