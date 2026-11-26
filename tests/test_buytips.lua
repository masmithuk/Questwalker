-- Collect objectives suggest buying the items when they can be bought.

local fixtures = require("fixtures")

local function stepFor(state, id)
    for _, s in ipairs(state.steps) do
        for _, q in ipairs(s.questIDs or {}) do
            if q == id and s.kind == "COMPLETE" then return s end
        end
    end
    return nil
end

local function itemInfo(map)
    _G.GetItemInfo = function(id)
        local e = map[id]
        if not e then return nil end
        -- name, link, quality, iLevel, minLevel, type, subType, stack, equip, texture, sell, class, subclass, bind
        return e.name, nil, 1, 1, 1, nil, nil, 20, "", nil, 1, e.class or 7, 0, e.bind or 0
    end
end

local function boarMeat(db)
    db.Item[5001] = { name = "Chunk of Boar Meat", npcDrops = { 2001 } }
    db.Quest[101].objectives = { nil, nil, { { 5001, 10 } } }
end

return {
    { "tradeable drops: buy on the Auction House, with a price when known", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        boarMeat(db)
        itemInfo({ [5001] = { name = "Chunk of Boar Meat" } })
        _G.Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(_, id) return id == 5001 and 150 or nil end } } }
        fixtures.addToLog(mock, 101, "Boar Meat", false, { "Chunk of Boar Meat: 4/10" })
        local step = stepFor(fixtures.login(ns), 101)
        T.contains(step.lines, "  Or buy 6 Chunk of Boar Meat on the Auction House: about 9s (1s 50c each, Auctionator).")
        _G.Auctionator = nil
    end },

    { "no auction addon: still says it can be bought", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        boarMeat(db)
        itemInfo({ [5001] = { name = "Chunk of Boar Meat" } })
        _G.Auctionator, _G.TSM_API, _G.CoinForgeAPI = nil, nil, nil
        fixtures.addToLog(mock, 101, "Boar Meat", false, { "Chunk of Boar Meat: 0/10" })
        local step = stepFor(fixtures.login(ns), 101)
        T.contains(step.lines, "  Or buy 10 Chunk of Boar Meat on the Auction House.")
    end },

    { "Coin Forge prices come first when it offers them", function(T)
        local ns = T.fresh()
        _G.CoinForgeAPI = { GetPrice = function() return 99 end }
        _G.Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function() return 150 end } } }
        local price, source = ns.Market.Price(5001)
        T.eq(price, 99); T.eq(source, "Coin Forge")
        _G.CoinForgeAPI = nil
    end },

    { "sold by a vendor: buy it there", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        boarMeat(db)
        db.Item[5001].vendors = { 1002 } -- the Foreman, in Durotar
        itemInfo({ [5001] = { name = "Chunk of Boar Meat" } })
        fixtures.addToLog(mock, 101, "Boar Meat", false, { "Chunk of Boar Meat: 4/10" })
        local step = stepFor(fixtures.login(ns), 101)
        T.contains(step.lines, "  Or buy 6 Chunk of Boar Meat from Foreman Thazz'ril, Durotar.")
    end },

    { "quest items and finished objectives get no tip; the setting turns tips off", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        boarMeat(db)
        itemInfo({ [5001] = { name = "Chunk of Boar Meat", class = 12, bind = 4 } })
        fixtures.addToLog(mock, 101, "Boar Meat", false, { "Chunk of Boar Meat: 4/10" })
        local step = stepFor(fixtures.login(ns), 101)
        for _, line in ipairs(step.lines) do T.truthy(not line:find("Or buy"), "quest item: " .. line) end
        T.eq(#ns.Market.Tips({ profile = { faction = "Horde" } }, 101, { "Chunk of Boar Meat: 10/10" }), 0)
        itemInfo({ [5001] = { name = "Chunk of Boar Meat" } })
        QuestwalkerDB.guide.buyTips = false
        T.eq(#ns.Market.Tips({ profile = { faction = "Horde" } }, 101, { "Chunk of Boar Meat: 4/10" }), 0)
    end },
}
