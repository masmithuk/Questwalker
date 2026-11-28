--[[
    Questwalker - Data/Unavailable.lua

    Quests in the database that can't actually be picked up on WoW Forever,
    so the guide never sends anyone to them. Questie hides most of these
    itself (its blacklist is checked too); this list covers the ones it
    misses on Forever. Report others on the GitHub issues page.
]]

local _, ns = ...
ns.Data = ns.Data or {}

ns.Data.UnavailableQuests = {
    [579] = "Stormwind Library", -- no quest giver offers it (Questie hides it only from Cataclysm on)
}
