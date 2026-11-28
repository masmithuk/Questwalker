-- Target button: cycling nearest to furthest, one step per press, Shift,
-- and only the current step's creatures.

local fixtures = require("fixtures")

-- The current step is "Vile Familiars", which needs three creatures that are
-- 20, ~141 and ~636 yards away. Another quest in the log ("Boars") has its
-- own creature in another area, which the button should leave alone.
local function setup(T)
    local ns, mock = T.fresh()
    local db = fixtures.durotar(mock)
    db.Npc[2002] = { name = "Distant Boar", spawns = { [14] = { { 95, 95 } } } }
    db.Npc[2003] = { name = "Near Scorpid", spawns = { [14] = { { 52, 50 } } } }
    db.Npc[2004] = { name = "Other Quest Raptor", spawns = { [14] = { { 95, 5 } } } } -- another area
    db.Quest[101].objectives = { { { 2001 }, { 2002 }, { 2003 } } }
    db.Quest[112] = { name = "Boars", startedBy = { { 1002 } }, objectives = { { { 2004 } } } }
    fixtures.addToLog(mock, 101, "Vile Familiars", false,
        { "Vile Familiar slain: 2/8", "Distant Boar slain: 0/5", "Near Scorpid slain: 1/6" })
    fixtures.addToLog(mock, 112, "Boars", false, { "Other Quest Raptor slain: 0/5" })
    QuestwalkerCharDB = QuestwalkerCharDB or {}
    fixtures.login(ns)
    QuestwalkerCharDB.guide.trainedLevel = 60
    T.truthy(ns.Engine.FocusQuest(101), "focus the Vile Familiars step")
    return ns, mock, QuestwalkerTargetButton
end

local function target(name) return "/targetexact " .. name end

return {
    { "creatures are listed nearest first", function(T)
        local ns = setup(T)
        local names = ns.TargetButton.GetNames()
        T.eq(table.concat(names, ","), "Near Scorpid,Vile Familiar,Distant Boar")
    end },

    { "pressing again repeats the nearest kind, so the game steps through each one", function(T)
        local _, mock, button = setup(T)
        for _ = 1, 3 do
            T.eq(mock.click(button)[1], target("Near Scorpid"), "same name each press")
        end
    end },

    { "different kinds get an icon each, nearest first", function(T)
        local ns = setup(T)
        T.eq(table.concat(ns.TargetButton.GetGroups(), " | "),
            "Near Scorpid: Near Scorpid | Vile Familiar: Vile Familiar | Distant Boar: Distant Boar")
    end },

    { "one press = one step, whichever key-down setting you use", function(T)
        local _, mock, button = setup(T)
        T.eq(#mock.click(button), 1, "mouse down + up targets once (key-up mode)")
        -- A fresh character with "cast on key down" switched on.
        local ns2, mock2, button2 = setup(T)
        mock2.useKeyDown = true
        ns2.TargetButton.SetEnabled(true)
        local ran = mock2.click(button2)
        T.eq(#ran, 1, "key-down mode also targets once")
        T.eq(ran[1], target("Near Scorpid"))
    end },

    { "a short label and an icon under each button", function(T)
        local _, _, button = setup(T)
        T.eq(button.label:GetText(), "Near Scorpid")
        T.eq(button.icon:GetTexture(), "Interface\\Icons\\Ability_Hunter_Pet_Scorpid")
        T.eq(button.count:GetText(), "", "one kind: no count")
    end },

    { "Shift-click doesn't target (Shift is for dragging)", function(T)
        local _, mock, button = setup(T)
        mock.keys.shift = true
        T.eq(#mock.click(button), 0)
        mock.keys.shift = false
        T.eq(mock.click(button)[1], target("Near Scorpid"), "cycle didn't move")
    end },

    { "Shift + left-drag moves the button, but not in combat", function(T)
        local _, mock, button = setup(T)
        local moved = 0
        button.StartMoving = function() moved = moved + 1 end
        button:GetScript("OnDragStart")(button)
        T.eq(moved, 0, "plain drag does nothing")
        mock.keys.shift = true
        button:GetScript("OnDragStart")(button)
        T.eq(moved, 1, "Shift-drag moves")
        mock.inCombat = true
        button:GetScript("OnDragStart")(button)
        T.eq(moved, 1, "secure frames can't move in combat")
        mock.inCombat = false
        button:GetScript("OnDragStop")(button)
        T.eq(QuestwalkerDB.target.x, 10, "position saved")
    end },

    { "cycling keeps working in combat", function(T)
        local _, mock, button = setup(T)
        mock.inCombat = true
        T.eq(mock.click(button)[1], target("Near Scorpid"))
        T.eq(mock.click(button)[1], target("Near Scorpid"))
    end },

    { "a new list starts again from the nearest", function(T)
        local ns, mock, button = setup(T)
        mock.click(button)
        mock.click(button)
        -- All the scorpids are dead now.
        mock.questLog[1].objectives[3] = { text = "Near Scorpid slain: 6/6", finished = true }
        ns:FireEvent("QUEST_LOG_UPDATE")
        T.eq(table.concat(ns.TargetButton.GetNames(), ","), "Vile Familiar,Distant Boar")
        T.eq(mock.click(button)[1], target("Vile Familiar"))
    end },

    { "other quests' creatures aren't listed", function(T)
        local ns = setup(T)
        for _, name in ipairs(ns.TargetButton.GetNames()) do
            T.truthy(name ~= "Other Quest Raptor", "only the current step's creatures")
        end
    end },

    { "hidden when the current step isn't about objectives", function(T)
        local ns, _, button = setup(T)
        T.truthy(button:IsShown())
        -- Focus a quest that still has to be picked up.
        T.truthy(ns.Engine.FocusQuest(102))
        T.eq(ns.Engine.state.steps[1].kind, "ACCEPT")
        T.eq(#ns.TargetButton.GetNames(), 0)
        T.truthy(not button:IsShown())
    end },

    { "several kinds: one extra icon each, in a row", function(T)
        local ns, mock = setup(T)
        local extras = ns.TargetButton.GetExtraButtons()
        T.eq(#extras, 2, "three kinds: main button plus two")
        T.eq(extras[1]:GetAttribute("macrotext"), "/targetexact Vile Familiar")
        T.eq(mock.click(extras[2])[1], target("Distant Boar"))
    end },

    { "creatures of one kind share an icon; right-click goes through the kinds", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Npc[2002] = { name = "Forest Spider", spawns = { [14] = { { 52, 50 } } } }
        db.Npc[2003] = { name = "Venom Web Spider", spawns = { [14] = { { 53, 50 } } } }
        db.Npc[2005] = { name = "Defias Trapper", spawns = { [14] = { { 60, 50 } } } }
        db.Npc[2006] = { name = "Defias Smuggler", spawns = { [14] = { { 61, 50 } } } }
        db.Quest[101].objectives = { { { 2002 }, { 2003 }, { 2005 }, { 2006 } } }
        fixtures.addToLog(mock, 101, "Webs and Bandits", false, {
            "Forest Spider slain: 0/5", "Venom Web Spider slain: 0/5",
            "Defias Trapper slain: 0/5", "Defias Smuggler slain: 0/5" })
        fixtures.login(ns)
        QuestwalkerCharDB.guide.trainedLevel = 60
        ns.Engine.FocusQuest(101)
        T.eq(table.concat(ns.TargetButton.GetGroups(), " | "),
            "Spiders: Forest Spider, Venom Web Spider | Defias: Defias Trapper, Defias Smuggler")
        local button = QuestwalkerTargetButton
        T.eq(button.icon:GetTexture(), "Interface\\Icons\\Spell_Nature_Web")
        T.eq(button.count:GetText(), "2")
        T.eq(mock.click(button)[1], target("Forest Spider"))
        T.eq(mock.click(button)[1], target("Forest Spider"), "again: the next Forest Spider")
        T.eq(mock.click(button, "RightButton")[1], target("Venom Web Spider"))
        T.eq(mock.click(button, "RightButton")[1], target("Forest Spider"), "wraps round")
    end },

    { "extra buttons go when the creatures do, and wait out combat", function(T)
        local ns, mock = setup(T)
        mock.inCombat = true
        mock.questLog[1].objectives[2] = { text = "Distant Boar slain: 5/5", finished = true }
        mock.questLog[1].objectives[3] = { text = "Near Scorpid slain: 6/6", finished = true }
        ns:FireEvent("QUEST_LOG_UPDATE")
        T.eq(#ns.TargetButton.GetExtraButtons(), 2, "unchanged in combat")
        mock.inCombat = false
        ns:FireEvent("PLAYER_REGEN_ENABLED")
        T.eq(#ns.TargetButton.GetExtraButtons(), 0, "one creature left: no extras")
    end },

    { "/qw debug says why the target button is hidden or shown", function(T)
        local ns, mock = setup(T)
        SlashCmdList.QUESTWALKER("debug")
        T.contains(table.concat(mock.printed, "\n"), "target button showing; creatures: Near Scorpid")
        ns.Engine.FocusQuest(102)
        mock.printed = {}
        SlashCmdList.QUESTWALKER("debug")
        T.contains(table.concat(mock.printed, "\n"), "hidden: the current step is ACCEPT")
    end },

    { "grouping: describing words don't make a kind", function(T)
        local ns = T.fresh()
        local groups = ns.TargetButton.Group({ "Young Wolf", "Young Boar", "Mottled Boar", "Gray Wolf" })
        local labels = {}
        for _, g in ipairs(groups) do labels[#labels + 1] = g.label .. "=" .. #g.names end
        T.eq(table.concat(labels, ","), "Wolves=2,Boars=2")
        T.eq(groups[1].icon, "Interface\\Icons\\Ability_Hunter_Pet_Wolf")
        T.eq(ns.TargetButton.IconFor("Kurzen Commando"), "Interface\\Icons\\Ability_Hunter_SniperShot")
    end },
}
