-- Kill objectives are shaded areas on the world map; pick-ups, hand-ins
-- and things to loot once keep numbered markers.

local fixtures = require("fixtures")

local function pt(x, y) return { mapID = 1411, x = x, y = y } end

return {
    { "creature spawns become areas, each numbered once", function(T)
        local ns = T.fresh()
        local accept = { title = "Talk to A", target = pt(0.2, 0.2) }
        local hunt = { title = "Kill boars", target = pt(0.5, 0.5),
            areas = { pt(0.50, 0.50), pt(0.52, 0.51), pt(0.51, 0.53),   -- one patch
                      pt(0.80, 0.80), pt(0.81, 0.82) } }                 -- another
        local markers, areas = ns.MapPins.Layout({ accept, hunt }, 1411)
        T.eq(#areas, 5, "a circle per spawn")
        T.eq(areas[1].number, 2)
        local pins, areaPins = 0, 0
        for _, m in ipairs(markers) do
            if m.area then areaPins = areaPins + 1 else pins = pins + 1 end
        end
        T.eq(pins, 1, "only the pick-up is a pin")
        T.eq(areaPins, 2, "one number per patch")
        T.truthy(areas[1].radius > 0)
    end },

    { "things to loot once keep their markers inside an area step", function(T)
        local ns = T.fresh()
        local rifle = pt(0.3, 0.7); rifle.once = true
        local step = { title = "Rifles and wolves", target = pt(0.5, 0.5),
            targets = { pt(0.5, 0.5), rifle }, areas = { pt(0.5, 0.5) } }
        local markers = ns.MapPins.Layout({ step }, 1411)
        local found
        for _, m in ipairs(markers) do
            if not m.area and math.abs(m.x - 0.3) < 1e-9 then found = m end
        end
        T.truthy(found, "the rifle's marker")
    end },

    { "a kill quest in game has an area from its creatures' spawns", function(T)
        local ns, mock = T.fresh()
        local db = fixtures.durotar(mock)
        db.Npc[2001].spawns = { [14] = { { 55, 55 }, { 56, 57 }, { 54, 58 } } }
        fixtures.addToLog(mock, 101, "Boar Hunt", false, { { text = "Boar slain: 0/8", finished = false } })
        local state = fixtures.login(ns)
        local step
        for _, s in ipairs(state.steps) do
            for _, id in ipairs(s.questIDs or {}) do if id == 101 and s.kind == "COMPLETE" then step = s end end
        end
        T.truthy(step and step.areas, "areas on the step")
        T.eq(#step.areas, 3)
    end },
}
