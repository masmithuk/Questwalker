--[[
    Questwalker - UI/MapPins.lua

    Numbered markers on the world map: where each of the guide's next steps
    is. 1 is the step you're on (gold), then 2, 3, ... in the order the
    guide will take them. Steps at the same spot share one marker ("2, 3").
    Hover a marker to see its step.

    Works on any map you look at: a step in another zone is placed through
    world coordinates when the game can (continent maps show the whole
    route). Off with Settings > "Number the steps on the world map".

    Layout() is pure (steps + map in, markers out) and unit-tested; the
    rest only draws.
]]

local _, ns = ...

local MapPins = {}
ns.MapPins = MapPins

MapPins.MAX_STEPS = 10
local SAME_SPOT = 0.012   -- markers closer than this (map fraction) merge
local MAX_BLOBS = 400     -- circles drawn for hunting areas
local PIN_SIZE = 22
local PIN_LEVEL = 2200    -- above Blizzard's and Questie's map pins
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

local lastSteps = {}
local route = nil         -- { from = world, to = world } from the Navigator
local dots = {}
local routeLayer
local ROUTE_DOT_GAP = 0.012  -- map fraction between route dots
local ROUTE_MAX_DOTS = 120
local pins = {}
local drawn = { mapID = nil, scale = nil, width = nil, dirty = true }
local hooked = false

local function enabled()
    local g = ns.Settings and ns.Settings.account and ns.Settings.account.guide
    return not g or g.mapNumbers ~= false
end

--- Where a step's target falls on `mapID`, as 0-1 fractions, or nil.
function MapPins.Project(t, mapID)
    if not t or not t.mapID or not t.x or not t.y then return nil end
    if t.mapID == mapID then return t.x, t.y end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then
        return nil
    end
    local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, t.mapID, CreateVector2D(t.x, t.y))
    if not ok or not continent or not world then return nil end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, world, mapID)
    if not ok2 or not pos then return nil end
    local x, y = pos:GetXY()
    if not x or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return x, y
end

--- Where a world position falls on `mapID` (0-1), or nil.
function MapPins.ProjectWorld(world, mapID)
    if not (world and mapID and C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, world.continent, CreateVector2D(world.x, world.y), mapID)
    if not ok or not pos then return nil end
    local x, y = pos:GetXY()
    if not x then return nil end
    return x, y
end

--- Dots along the Navigator's route on `mapID`: a list of {x, y}.
function MapPins.RouteDots(mapID)
    local out = {}
    if not route then return out end
    local x1, y1 = MapPins.ProjectWorld(route.from, mapID)
    local x2, y2 = MapPins.ProjectWorld(route.to, mapID)
    if not (x1 and x2) then return out end
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    local n = math.min(ROUTE_MAX_DOTS, math.floor(len / ROUTE_DOT_GAP))
    for i = 1, n do
        local t = i / (n + 1)
        local x, y = x1 + dx * t, y1 + dy * t
        if x >= 0 and x <= 1 and y >= 0 and y <= 1 then out[#out + 1] = { x = x, y = y } end
    end
    return out
end

--- The Navigator's current leg, drawn as a dotted line (nil to clear).
function MapPins.SetRoute(player, point)
    if not (player and point and player.world and point.world) then
        if route then route = nil; drawn.dirty = true end
        return
    end
    local old = route
    if old and old.to == point.world and math.abs(old.from.x - player.world.x) < 5
        and math.abs(old.from.y - player.world.y) < 5 then
        return
    end
    route = { from = player.world, to = point.world }
    drawn.dirty = true
end

MapPins.AREA_YARDS = 45        -- radius of the shading around each spawn
MapPins.AREA_CLUSTER = 0.06    -- spawns closer than this (map fraction) are one area

--- Yards across a map (left edge to right edge), or nil.
local function mapWidthYards(mapID)
    local GA = ns.GameApi
    local a, b = GA.GetWorldPosition(mapID, 0, 0.5), GA.GetWorldPosition(mapID, 1, 0.5)
    if not (a and b) or a.continent ~= b.continent then return nil end
    return ns.Util.Distance(a, b)
end

--- Split points into areas: each point joins any area it's near.
local function clusters(points, gap)
    local groups = {}
    for _, p in ipairs(points) do
        local home
        for _, g in ipairs(groups) do
            for _, q in ipairs(g) do
                if math.abs(p.x - q.x) < gap and math.abs(p.y - q.y) < gap then home = g; break end
            end
            if home then break end
        end
        if home then home[#home + 1] = p else groups[#groups + 1] = { p } end
    end
    return groups
end

local function addMarker(markers, x, y, i, step, extra)
    for _, m in ipairs(markers) do
        if not m.area and not (extra and extra.area)
            and math.abs(m.x - x) < SAME_SPOT and math.abs(m.y - y) < SAME_SPOT then
            if m.numbers[#m.numbers] ~= i then
                m.numbers[#m.numbers + 1] = i
                m.steps[#m.steps + 1] = step
            end
            return
        end
    end
    local m = { x = x, y = y, numbers = { i }, steps = { step }, current = i == 1 }
    for k, v in pairs(extra or {}) do m[k] = v end
    markers[#markers + 1] = m
end

--- What to draw on `mapID` for the planned steps: numbered markers for
--- places to go (quest givers, hand-ins, things to loot once), and shaded
--- areas where creatures are to be killed, each with its number in the
--- middle.
-- @return markers { x, y, numbers, steps, current, area? }, and
--         areas { x, y, number, current, radius (map fraction of width) }
function MapPins.Layout(steps, mapID)
    local markers, areas = {}, {}
    if not mapID then return markers, areas end
    local width = mapWidthYards(mapID)
    local radius = width and width > 0 and MapPins.AREA_YARDS / width or 0.02
    for i, step in ipairs(steps or {}) do
        if i > MapPins.MAX_STEPS then break end
        if step.areas then
            local points = {}
            for _, p in ipairs(step.areas) do
                local x, y = MapPins.Project(p, mapID)
                if x then points[#points + 1] = { x = x, y = y } end
            end
            for _, p in ipairs(points) do
                areas[#areas + 1] = { x = p.x, y = p.y, number = i, current = i == 1, radius = radius }
            end
            for _, g in ipairs(clusters(points, MapPins.AREA_CLUSTER)) do
                local sx, sy = 0, 0
                for _, p in ipairs(g) do sx, sy = sx + p.x, sy + p.y end
                addMarker(markers, sx / #g, sy / #g, i, step, { area = true })
            end
            -- Things to loot once still get their own markers.
            for _, t in ipairs(step.targets or {}) do
                if t.once then
                    local x, y = MapPins.Project(t, mapID)
                    if x then addMarker(markers, x, y, i, step) end
                end
            end
        else
            for _, t in ipairs(step.targets or { step.target }) do
                local x, y = MapPins.Project(t, mapID)
                if x then addMarker(markers, x, y, i, step) end
            end
        end
    end
    return markers, areas
end

--- "1", "2, 3" or "4-7" for a marker.
function MapPins.Label(numbers)
    local n = #numbers
    if n == 1 then return tostring(numbers[1]) end
    if n > 2 and numbers[n] - numbers[1] == n - 1 then return numbers[1] .. "-" .. numbers[n] end
    if n > 3 then return numbers[1] .. ", " .. numbers[2] .. "+" end
    local parts = {}
    for i, v in ipairs(numbers) do parts[i] = tostring(v) end
    return table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function canvas()
    local map = _G.WorldMapFrame
    local scroll = map and map.ScrollContainer
    return map, scroll, scroll and scroll.Child
end

local function showTooltip(pin)
    local m = pin.marker
    if not m or not GameTooltip then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    for k, step in ipairs(m.steps) do
        if k > 1 then GameTooltip:AddLine(" ") end
        GameTooltip:AddLine(m.numbers[k] .. ". " .. (step.title or ""), 1, 0.82, 0)
        for _, line in ipairs(step.lines or {}) do GameTooltip:AddLine(line, 1, 1, 1, true) end
    end
    GameTooltip:Show()
end

local function newPin(parent)
    local pin = CreateFrame("Button", nil, parent)
    pin:SetSize(PIN_SIZE, PIN_SIZE)
    pin.bg = pin:CreateTexture(nil, "BACKGROUND")
    pin.bg:SetAllPoints()
    pin.bg:SetTexture(CIRCLE)
    pin.ring = pin:CreateTexture(nil, "BORDER")
    pin.ring:SetPoint("TOPLEFT", -2, 2)
    pin.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    pin.ring:SetTexture(CIRCLE)
    pin.ring:SetVertexColor(0, 0, 0, 0.9)
    pin.text = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pin.text:SetPoint("CENTER", 0, 0)
    pin:SetScript("OnEnter", showTooltip)
    pin:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return pin
end

local blobs = {}
local areaLayer

local function hideAll(from)
    for i = from or 1, #pins do pins[i]:Hide() end
    if not from then
        for _, dot in ipairs(dots) do dot:Hide() end
        for _, blob in ipairs(blobs) do blob:Hide() end
    end
end

--- Shade the hunting areas: a soft circle round each spawn, so spawns
--- close together read as one area. The current step's area is red,
--- later ones blue.
function MapPins.DrawAreas(child, areas, width)
    if not areaLayer then
        areaLayer = CreateFrame("Frame", nil, child)
        areaLayer:SetAllPoints(child)
        areaLayer:SetFrameLevel(PIN_LEVEL - 20)
    end
    local count = 0
    for i, a in ipairs(areas or {}) do
        if i > MAX_BLOBS then break end
        count = i
        local blob = blobs[i]
        if not blob then
            blob = areaLayer:CreateTexture(nil, "ARTWORK")
            blob:SetTexture(CIRCLE)
            blobs[i] = blob
        end
        if a.current then
            blob:SetVertexColor(0.9, 0.2, 0.1, 0.22)
        else
            blob:SetVertexColor(0.2, 0.45, 0.9, 0.16)
        end
        local size = 2 * a.radius * width
        blob:SetSize(size, size)
        blob:ClearAllPoints()
        blob:SetPoint("CENTER", child, "TOPLEFT", a.x * width, -a.y * child:GetHeight())
        blob:Show()
    end
    for i = count + 1, #blobs do blobs[i]:Hide() end
    MapPins.areaCount = count
end

--- Redraw the markers for the map being shown.
function MapPins.Draw()
    local map, scroll, child = canvas()
    if not (child and map:IsShown()) or not enabled() then
        hideAll()
        return
    end
    local mapID = map.GetMapID and map:GetMapID()
    local scale = scroll.GetCanvasScale and scroll:GetCanvasScale() or 1
    local width, height = child:GetWidth(), child:GetHeight()
    drawn.mapID, drawn.scale, drawn.width, drawn.dirty = mapID, scale, width, false
    if not width or width <= 0 then return end

    local markers, areas = MapPins.Layout(lastSteps, mapID)
    MapPins.DrawAreas(child, areas, width)
    for i, m in ipairs(markers) do
        local pin = pins[i] or newPin(child)
        pins[i] = pin
        pin.marker = m
        -- Same size on screen at any zoom.
        local s = 1 / (scale > 0 and scale or 1)
        pin:SetScale(s)
        pin:SetFrameLevel(PIN_LEVEL)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", child, "TOPLEFT", m.x * width / s, -m.y * height / s)
        pin.text:SetText(MapPins.Label(m.numbers))
        local label = pin.text:GetText() or ""
        pin:SetWidth(PIN_SIZE + math.max(0, #label - 2) * 5)
        pin.ring:SetVertexColor(m.area and 0.85 or 0, m.area and 0.2 or 0, m.area and 0.1 or 0, 0.95)
        if m.current then
            pin.bg:SetVertexColor(1, 0.75, 0.1, 1)
            pin.text:SetTextColor(0, 0, 0)
        else
            pin.bg:SetVertexColor(0.12, 0.35, 0.65, 0.95)
            pin.text:SetTextColor(1, 1, 1)
        end
        pin:Show()
    end
    hideAll(#markers + 1)

    -- The Navigator's route, under the markers.
    local list = MapPins.RouteDots(mapID)
    for i, d in ipairs(list) do
        local dot = dots[i]
        if not dot then
            -- On their own frame above the map tiles (textures on the
            -- canvas itself would sit underneath them).
            if not routeLayer then
                routeLayer = CreateFrame("Frame", nil, child)
                routeLayer:SetAllPoints(child)
                routeLayer:SetFrameLevel(PIN_LEVEL - 10)
            end
            dot = routeLayer:CreateTexture(nil, "OVERLAY")
            dot:SetTexture(CIRCLE)
            dot:SetVertexColor(1, 0.82, 0.1, 0.9)
            dots[i] = dot
        end
        local size = 6 / (scale > 0 and scale or 1)
        dot:SetSize(size, size)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", child, "TOPLEFT", d.x * width, -d.y * height)
        dot:Show()
    end
    for i = #list + 1, #dots do dots[i]:Hide() end
end

--- Watch the world map: redraw when it opens, changes map or zooms.
local function hook()
    local map, scroll = canvas()
    if hooked or not map then return end
    hooked = true
    if map.HookScript then map:HookScript("OnShow", function() drawn.dirty = true end) end
    if hooksecurefunc and map.OnMapChanged then
        hooksecurefunc(map, "OnMapChanged", function() drawn.dirty = true end)
    end
    -- Zooming and map changes are cheap to spot, so check while it's open.
    local watcher = CreateFrame("Frame", nil, map)
    local elapsed = 0
    watcher:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + (dt or 0)
        if elapsed < 0.1 then return end
        elapsed = 0
        local mapID = map.GetMapID and map:GetMapID()
        local scale = scroll and scroll.GetCanvasScale and scroll:GetCanvasScale() or 1
        local width = scroll and scroll.Child and scroll.Child:GetWidth()
        if drawn.dirty or mapID ~= drawn.mapID or scale ~= drawn.scale or width ~= drawn.width then
            MapPins.Draw()
        end
    end)
end

--- New plan from the Engine. (The map is hooked on first use, so a world
--- map that loads on demand is picked up too.)
function MapPins.Update(steps)
    lastSteps = steps or {}
    hook()
    drawn.dirty = true
    local map = _G.WorldMapFrame
    if map and map:IsShown() then MapPins.Draw() end
end

--- Labels of the markers on show, in order (for tests and /qw debug).
function MapPins.Shown()
    local out = {}
    for _, pin in ipairs(pins) do
        if pin:IsShown() then out[#out + 1] = pin.text:GetText() end
    end
    return out
end

--- Turn the numbers on or off (Settings).
function MapPins.SetEnabled(on)
    ns.Settings.account.guide.mapNumbers = on and true or false
    drawn.dirty = true
    MapPins.Draw()
end
