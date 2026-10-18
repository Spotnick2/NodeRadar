-- Scan.lua: one sweep of the minimap's blips (docs/PLAN.md, "The sweep").
--
-- Measured on 70450 (docs/FOREVER-PROBE.md): Minimap:UpdateMouseoverAtPoint
-- takes a point in GetCursorPosition's space, and counts with the cursor
-- anywhere while Minimap:SetUsingSoftCursor(true); C_TooltipInfo.
-- GetMinimapMouseover() then reads the names there. A sweep is about 4 ms.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Scan = {}
NR.Scan = Scan

-- The map's own units between samples. A node's blip is a square at least 17
-- units wide (herbs read 3 x 3 at a step of 8; a quest object measured 15 x 15,
-- at every zoom: docs/FOREVER-PROBE.md, "Memory"), so 14 never misses one, with
-- room for a smaller icon. Each read is a new table (2.5 KB), even empty: 225
-- reads a sweep, not 625 at 8 (#11).
Scan.STEP = 14

-- The map's rect in its own units and its effective scale; nil and why when
-- any part is missing or secret.
function Scan.Geometry()
    local es = API.Num(Minimap:GetEffectiveScale())
    local l, b, w, h = Minimap:GetRect()
    l, b, w, h = API.Num(l), API.Num(b), API.Num(w), API.Num(h)
    if not (es and l and b and w and h) or w <= 0 or h <= 0 then return nil, "the map's geometry is unreadable" end
    return { es = es, l = l, b = b, w = w, h = h }
end

-- A line's text as a name: the client's escape codes out. A node above or below
-- the player reads "|TInterface\Minimap\Minimap-PositionArrows:…|tPeacebloom",
-- quest lines carry colours (release check, 70450): the same node must read the
-- same name at every height, and as gathering names it.
function Scan.Plain(s)
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", ""):gsub("|n", " ")
    return (s:match("^%s*(.-)%s*$"))
end

-- The names under the mouseover, or throws: a secret answer fails the sweep.
local function names()
    local data = C_TooltipInfo.GetMinimapMouseover()
    if data == nil then return nil end
    if API.IsSecret(data) or type(data) ~= "table" then error("the mouseover reads secret", 0) end
    local lines = data.lines
    if API.IsSecret(lines) then error("the mouseover reads secret", 0) end
    if type(lines) ~= "table" then return nil end
    local list
    for _, line in ipairs(lines) do
        local t = type(line) == "table" and line.leftText or nil
        if API.IsSecret(t) then error("a mouseover line reads secret", 0) end
        if type(t) == "string" then
            for row in t:gmatch("[^\n]+") do
                local name = Scan.Plain(row)
                if name ~= "" then
                    list = list or {}
                    list[#list + 1] = name
                end
            end
        end
    end
    return list
end

-- Cells that touch (8 neighbours) are one blip, at the centre of its cells, in
-- the map's units from its centre, as drawn.
local function group(cells, g)
    local byName, list = {}, {}
    for name, set in pairs(cells) do
        local seen, blips = {}, {}
        for key, cell in pairs(set) do
            if not seen[key] then
                local sx, sy, n, stack = 0, 0, 0, { cell }
                seen[key] = true
                while #stack > 0 do
                    local c = table.remove(stack)
                    sx, sy, n = sx + c[1], sy + c[2], n + 1
                    for dc = -1, 1 do
                        for dr = -1, 1 do
                            local k = (c.col + dc) .. ":" .. (c.row + dr)
                            local nb = set[k]
                            if nb and not seen[k] then
                                seen[k] = true
                                stack[#stack + 1] = nb
                            end
                        end
                    end
                end
                local blip = { name = name, x = sx / n - g.w / 2, y = sy / n - g.h / 2, cells = n }
                blips[#blips + 1] = blip
                list[#list + 1] = blip
            end
        end
        byName[name] = blips
    end
    return byName, list
end

-- Puts the mouseover back where the player's cursor is, or off the map.
local function putBack(g)
    local px, py = GetCursorPosition()
    px, py = API.Num(px), API.Num(py)
    local ok, over = pcall(Minimap.IsMouseOver, Minimap)
    if not (px and py and ok and API.Yes(over)) then
        px, py = (g.l - 3 * g.w) * g.es, (g.b - 3 * g.h) * g.es
    end
    pcall(Minimap.UpdateMouseoverAtPoint, Minimap, px, py)
end

-- One sweep: { byName = { [name] = { blip, ... } }, blips = { ... }, geometry,
-- ms }, or nil and why. The soft cursor is turned off on every path.
function Scan.Sweep()
    local g, why = Scan.Geometry()
    if not g then return nil, why end
    local step = Scan.STEP
    local cells = {}
    local t0 = debugprofilestop()
    local okOn, errOn = pcall(Minimap.SetUsingSoftCursor, Minimap, true)
    local ok, err = okOn, errOn
    if okOn then
        ok, err = pcall(function()
            local row = 0
            for oy = step / 2, g.h, step do
                local col = 0
                for ox = step / 2, g.w, step do
                    Minimap:UpdateMouseoverAtPoint((g.l + ox) * g.es, (g.b + oy) * g.es)
                    local found = names()
                    if found then
                        for _, name in ipairs(found) do
                            cells[name] = cells[name] or {}
                            cells[name][col .. ":" .. row] = { ox, oy, col = col, row = row }
                        end
                    end
                    col = col + 1
                end
                row = row + 1
            end
        end)
    end
    -- Unconditionally, whatever happened above.
    putBack(g)
    pcall(Minimap.SetUsingSoftCursor, Minimap, false)
    if not ok then
        API.Fail("sweep", err)
        return nil, "the sweep failed: " .. tostring(err)
    end
    local byName, list = group(cells, g)
    return { byName = byName, blips = list, geometry = g, ms = debugprofilestop() - t0 }
end

-- How many blips of a name a sweep saw.
function Scan.Count(result, name)
    local b = result and result.byName[name]
    return b and #b or 0
end
