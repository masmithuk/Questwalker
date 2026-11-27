-- Things that run every frame or second can't flood the game with errors,
-- and hidden ("secret") values in dungeons are left alone.

local fixtures = require("fixtures")

return {
    { "a failing repeated job reports once, then pauses", function(T)
        local ns = T.fresh()
        local reports, calls, now = {}, 0, 0
        _G.GetTime = function() return now end
        _G.geterrorhandler = function() return function(msg) reports[#reports + 1] = msg end end
        local job = ns.Util.Protect("test job", function() calls = calls + 1; error("boom") end)
        for _ = 1, 100 do job() end
        T.eq(calls, 1, "paused after the first error")
        T.eq(#reports, 1)
        T.contains(reports[1], "Questwalker test job")
        now = 31
        job()
        T.eq(calls, 2, "tried again after the pause")
        T.eq(#reports, 1, "but reported once")
        _G.geterrorhandler = nil
    end },

    { "hidden target GUIDs in a dungeon cause no error", function(T)
        local ns, mock = T.fresh()
        fixtures.durotar(mock)
        fixtures.login(ns)
        local SECRET = setmetatable({}, { __tostring = function() error("secret value read") end })
        _G.issecretvalue = function(v) return v == SECRET end
        _G.UnitGUID = function() return SECRET end
        _G.IsInInstance = function() return false, "none" end
        ns.Engine.CheckSilentGiver(1) -- outside: the secret GUID is skipped safely
        T.eq(ns.GameApi.GetNpcID("target"), nil)
        _G.IsInInstance = function() return true, "party" end
        ns.Engine.CheckSilentGiver(1) -- inside: not checked at all
        T.eq(ns.GameApi.InInstance(), true)
        _G.issecretvalue, _G.IsInInstance = nil, nil
    end },

    { "hidden party names don't break the compass", function(T)
        local ns, mock = T.fresh()
        fixtures.durotar(mock)
        mock.player.facing = 0
        mock.party.party1 = { name = "x", class = "HUNTER", position = { mapID = 1411, x = 0.6, y = 0.5 } }
        fixtures.login(ns)
        local SECRET = {}
        _G.issecretvalue = function(v) return v == SECRET end
        _G.UnitName = function() return SECRET end
        local party = ns.Compass.PartyPositions(1411)
        T.eq(#party, 1)
        T.eq(party[1].name, nil, "left out, not read")
        ns.Compass.Draw()
        _G.issecretvalue = nil
    end },
}
