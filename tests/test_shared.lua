-- Quests that share enemies are picked up together, before the killing.
-- Like The People's Militia (kill Defias) and Red Leather Bandanas
-- (bandanas drop from Defias).

local fixtures = require("fixtures")

local function bandanas(db)
    -- Quest 106 wants bandanas, which drop from 2001 (101's creature).
    db.Item[5002] = { name = "Red Leather Bandana", npcDrops = { 2001 } }
    db.Quest[106].objectives = { nil, nil, { { 5002, 15 } } }
    db.Quest[106].requiredClasses = nil
end

local function acceptOf(state, id)
    for i, s in ipairs(state.steps) do
        if s.kind == "ACCEPT" then
            for _, q in ipairs(s.questIDs or {}) do if q == id then return s, i end end
        end
    end
    return nil
end

return {
    { "spots quests that share enemies, through item drops too", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        bandanas(db)
        fixtures.login(ns)
        local ctx = ns.Engine.BuildContext()
        T.eq(table.concat(ns.Sources.SharedEnemies(ctx, 106, { 101, 102 }), ","), "101")
        T.eq(#ns.Sources.SharedEnemies(ctx, 102, { 101 }), 0)
    end },

    { "on the kill quest already: the bandanas come first", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        bandanas(db)
        fixtures.addToLog(mock, 101, "The People's Militia", false, { "Defias slain: 0/15" })
        QuestwalkerCharDB.guide.trainedLevel = 60
        local state = fixtures.login(ns)
        local step, index = acceptOf(state, 106)
        T.truthy(step, "the bandana quest is planned")
        local killAt
        for i, s in ipairs(state.steps) do if s.key == "complete:101" then killAt = i end end
        T.truthy(killAt and index < killAt, "before the killing")
        T.contains(step.lines, "  Same enemies as The People's Militia: take it first and do them together.")
    end },

    { "even from far down the guide's list", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        bandanas(db)
        local quests = { { id = 102 } }
        for i = 1, 12 do quests[#quests + 1] = { step = "note", text = "Filler " .. i } end
        quests[#quests + 1] = { id = 106 }
        QuestwalkerDB.guides["custom-shared"] = {
            format = "Questwalker guide", version = 2, name = "Shared", basedOn = "efficient",
            rules = { maxAccept = 1 }, quests = quests,
            bands = { { levels = { 1, 60 }, zones = { "Durotar" } } },
        }
        ns.Library.Init()
        QuestwalkerCharDB.routeId = "custom-shared"
        QuestwalkerCharDB.guide.trainedLevel = 60
        fixtures.addToLog(mock, 101, "The People's Militia", false, { "Defias slain: 0/15" })
        local state = fixtures.login(ns)
        local step = acceptOf(state, 106)
        T.truthy(step and not step.passBy, "planned, not just if passing")
    end },

    { "already heading out to kill: a quest giver nearby with the same enemies comes first", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        bandanas(db)
        fixtures.addToLog(mock, 101, "The People's Militia", false, { "Defias slain: 0/15" })
        QuestwalkerCharDB.guide.trainedLevel = 60
        fixtures.login(ns)
        ns.Engine.state.currentKey = "complete:101" -- the kill step is the one you're on
        ns.Engine.Replan()
        local state = ns.Engine.state
        local step, index = acceptOf(state, 106)
        local killAt
        for i, s in ipairs(state.steps) do if s.key == "complete:101" then killAt = i end end
        T.truthy(step and killAt and index < killAt, "the pick-up goes before the kills")
        T.eq(step.onTheWayTo, "complete:101")
    end },
}
