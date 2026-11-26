--[[
    Questwalker - Integrations/Market.lua

    Buying quest items instead of farming them. For each item a collect
    objective still needs, works out the quickest way to get it:

      vendor   an NPC sells it (QuestieDB): "Buy 6 Linen Cloth from
               Brother Danil, Northshire Abbey"
      auction  it can be traded, so it may be on the Auction House, with
               a price when an auction addon knows one: Coin Forge (if it
               offers prices), Auctionator or TradeSkillMaster

    Quest items (bound, or the Quest item class) can't be bought, so they
    get no tip. Turned off with Settings > "Suggest buying quest items".
]]

local _, ns = ...

local Market = {}
ns.Market = Market

local QUEST_CLASS = 12   -- item class for quest items
local BIND_NONE = 0

local function enabled()
    local g = ns.Settings and ns.Settings.account and ns.Settings.account.guide
    return not g or g.buyTips ~= false
end

--- Can this item be traded (so it could be on the Auction House)? nil
--- when the game hasn't loaded the item's details yet.
function Market.IsTradeable(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local info = { getInfo(itemID) }
    if not info[1] then
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
        return nil
    end
    local classID, bindType = info[12], info[14]
    if classID == QUEST_CLASS then return false end
    return bindType == nil or bindType == BIND_NONE
end

--- The going rate on the Auction House, in copper, and who said so; nil
--- when no auction addon knows.
function Market.Price(itemID)
    local cf = _G.CoinForgeAPI
    if cf and type(cf.GetPrice) == "function" then
        local ok, price = pcall(cf.GetPrice, itemID)
        if ok and type(price) == "number" and price > 0 then return price, "Coin Forge" end
    end
    local auctionator = _G.Auctionator
    local api = auctionator and auctionator.API and auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local ok, price = pcall(api.GetAuctionPriceByItemID, "Questwalker", itemID)
        if ok and type(price) == "number" and price > 0 then return price, "Auctionator" end
    end
    local tsm = _G.TSM_API
    if tsm and tsm.GetCustomPriceValue then
        local ok, price = pcall(tsm.GetCustomPriceValue, "dbminbuyout", "i:" .. itemID)
        if ok and type(price) == "number" and price > 0 then return price, "TSM" end
    end
    return nil
end

--- 12345 copper -> "1g 23s 45c" (short: drops zero parts).
function Market.Money(copper)
    copper = math.floor(copper + 0.5)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

--- How many of an item you still need, from the quest's objective text
--- ("Linen Cloth: 4/10"), or the objective's count.
local function stillNeeded(item, objectives)
    for _, text in ipairs(objectives) do
        if text:find(item.name, 1, true) then
            local have, need = text:match("(%d+)%s*/%s*(%d+)")
            if have then return tonumber(need) - tonumber(have) end
        end
    end
    return nil
end

--- Tips for buying what a quest still needs.
-- @param ctx the planning context (origin, profile)
-- @param questID a quest in your log
-- @param open its unfinished objective texts
-- @return lines
function Market.Tips(ctx, questID, open)
    local lines = {}
    if not enabled() or not ns.QuestieData.IsReady() then return lines end
    for _, item in ipairs(ns.QuestieData.ObjectiveItems(questID)) do
        local need = stillNeeded(item, open)
        if need and need > 0 then
            local vendor, point
            local vendors = ns.QuestieData.GetVendors(item.id, ctx.profile.faction)
            if #vendors > 0 then
                local best, bestD
                for _, v in ipairs(vendors) do
                    for _, p in ipairs(v.points) do
                        local w = p.world ~= nil and p.world or ns.GameApi.GetWorldPosition(p.mapID, p.x, p.y)
                        local d = w and ctx.origin and w.continent == ctx.origin.continent
                            and ns.Util.Distance(ctx.origin, w) or math.huge
                        if not best or d < bestD then best, bestD, point = v, d, p end
                    end
                end
                vendor = best
            end
            if vendor then
                local zone = point and ns.GameApi.GetMapName(point.mapID)
                lines[#lines + 1] = ns.L.BUY_VENDOR_FMT:format(need, item.name, vendor.name,
                    zone and (", " .. zone) or "")
            elseif Market.IsTradeable(item.id) then
                local price, source = Market.Price(item.id)
                if price then
                    lines[#lines + 1] = ns.L.BUY_AH_PRICE_FMT:format(need, item.name,
                        Market.Money(price * need), Market.Money(price), source)
                else
                    lines[#lines + 1] = ns.L.BUY_AH_FMT:format(need, item.name)
                end
            end
        end
    end
    return lines
end
