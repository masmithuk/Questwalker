-- What a quest needs before it's offered, and quest givers with nothing
-- to say.

local fixtures = require("fixtures")

return {
    { "lists unmet requirements in plain words", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[106].preQuestSingle = { 101 }
        db.Quest[106].requiredSkill = { 185, 50 }
        db.Quest[106].requiredMinRep = { 72, 3000 }
        db.Quest[106].zoneOrSort = -22
        fixtures.login(ns)
        _G.GetFactionInfoByID = function() return "Stormwind", nil, 4, 0, 3000, 1200 end
        local needs = ns.QuestieData.Requirements(106, { isCompleted = function() return false end, log = {} })
        T.contains(needs, "Needs: finish Vile Familiars first")
        T.contains(needs, "Needs: Cooking 50")
        T.contains(needs, "Needs: Friendly with Stormwind")
        T.contains(needs, "Only during a holiday event")
    end },

    { "met requirements aren't listed", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[106].preQuestSingle = { 101 }
        db.Quest[106].requiredSkill = { 185, 50 }
        fixtures.login(ns)
        _G.GetNumSkillLines = function() return 1 end
        _G.GetSkillLineInfo = function() return "Cooking", false, nil, 75 end
        local needs = ns.QuestieData.Requirements(106, { isCompleted = function(id) return id == 101 end, log = {} })
        T.eq(#needs, 0)
    end },

    { "not offered: the message says what it needs", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[101].requiredSkill = { 185, 50 }
        local state = fixtures.login(ns)
        -- Questie judged it doable, so it's a step; the giver says otherwise.
        state.steps = { { kind = "ACCEPT", actor = "npc:1001", questIDs = { 101 }, title = "Talk to Zureetha Fargaze" } }
        ns.Engine.NoteOffered(1001, {})
        T.contains(mock.printed[#mock.printed], "Needs: Cooking 50")
    end },

    { "a quest giver with nothing to say: the guide moves on", function(T)
        local ns, mock = T.fresh()
        fixtures.durotar(mock)
        local state = fixtures.login(ns)
        local step = state.steps[1]
        T.eq(step.kind, "ACCEPT")
        local npc = tonumber(step.actor:match("npc:(%d+)"))
        mock.player.position = { mapID = step.target.mapID, x = step.target.x, y = step.target.y }
        _G.UnitGUID = function(unit) return unit == "target" and ("Creature-0-1-1-1-" .. npc .. "-0") or "Player-1" end
        for _ = 1, 7 do ns.Engine.CheckSilentGiver(1) end
        T.eq(next(QuestwalkerCharDB.guide.notOffered), nil, "not yet")
        ns.Engine.CheckSilentGiver(1)
        T.truthy(QuestwalkerCharDB.guide.notOffered[step.questIDs[1]], "noted as not offered")
    end },

    { "a window opening means they're talking", function(T)
        local ns, mock = T.fresh()
        fixtures.durotar(mock)
        local state = fixtures.login(ns)
        local step = state.steps[1]
        local npc = tonumber(step.actor:match("npc:(%d+)"))
        mock.player.position = { mapID = step.target.mapID, x = step.target.x, y = step.target.y }
        _G.UnitGUID = function(unit) return unit == "target" and ("Creature-0-1-1-1-" .. npc .. "-0") or "Player-1" end
        for _ = 1, 6 do ns.Engine.CheckSilentGiver(1) end
        ns:FireEvent("QUEST_DETAIL")
        for _ = 1, 6 do ns.Engine.CheckSilentGiver(1) end
        T.eq(next(QuestwalkerCharDB.guide.notOffered), nil)
    end },

    { "planning: a quest needing an earlier one sends you to the earlier one", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[106].preQuestSingle = { 101 }
        fixtures.login(ns)
        local ctx = ns.Engine.BuildContext()
        local out = ns.Sources.ResolveNeeds(ctx, { 106 })
        T.eq(table.concat(out, ","), "101")
        T.eq(ctx.needsFirst[106].via[1], 101)
        T.contains(ctx.needsFirst[106].lines, "Needs: finish Vile Familiars first")
    end },

    { "planning: follows a chain back to what you can take now", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[102].preQuestSingle = { 101 }
        db.Quest[106].preQuestSingle = { 102 }
        fixtures.login(ns)
        local ctx = ns.Engine.BuildContext()
        T.eq(table.concat(ns.Sources.ResolveNeeds(ctx, { 106 }), ","), "101")
    end },

    { "planning: already on the earlier quest, nothing extra", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[106].preQuestSingle = { 101 }
        fixtures.addToLog(mock, 101, "Vile Familiars", false)
        fixtures.login(ns)
        local ctx = ns.Engine.BuildContext()
        T.eq(#ns.Sources.ResolveNeeds(ctx, { 106 }), 0)
    end },

    { "planning: a profession or holiday quest waits", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[106].requiredSkill = { 185, 50 }
        db.Quest[102].zoneOrSort = -22
        fixtures.login(ns)
        local ctx = ns.Engine.BuildContext()
        T.eq(table.concat(ns.Sources.ResolveNeeds(ctx, { 106, 102, 101 }), ","), "101")
        T.eq(#ctx.needsFirst[106].via, 0)
    end },

    { "in game: no trip to a holiday quest's giver, and the Steps list says why", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Quest[102].zoneOrSort = -22 -- the Foreman's quest
        QuestwalkerCharDB.guide.trainedLevel = 60
        local state = fixtures.login(ns)
        for _, s in ipairs(state.steps) do
            for _, id in ipairs(s.questIDs or {}) do T.truthy(id ~= 102, "102 isn't a step") end
        end
        local ctx = ns.Engine.BuildContext()
        T.truthy(ctx.needsFirst[102], "noted")
        T.contains(ctx.needsFirst[102].lines, "Only during a holiday event")
        T.contains(ns.StepsTab.StatusLabel({ status = "needs", needs = ctx.needsFirst[102].lines }),
            "Only during a holiday event")
    end },
}
