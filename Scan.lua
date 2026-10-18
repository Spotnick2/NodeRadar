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

-- Cells that touch (8 neighbours) are one cluster: { name, cells = { cell, ... } }.
local function clusters(cells)
    local out = {}
    for name, set in pairs(cells) do
        local seen = {}
        for key, cell in pairs(set) do
            if not seen[key] then
                local members, stack = {}, { cell }
                seen[key] = true
                while #stack > 0 do
                    local c = table.remove(stack)
                    members[#members + 1] = c
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
                out[#out + 1] = { name = name, cells = members }
            end
        end
    end
    return out
end

-- Grid cells of a name, sampled every `step` over a rect of the map (its own
-- units from the bottom left); only `want` is kept when given.
local function sample(g, step, x0, y0, x1, y1, cells, want)
    local row = 0
    for oy = y0 + step / 2, y1, step do
        local col = 0
        for ox = x0 + step / 2, x1, step do
            Minimap:UpdateMouseoverAtPoint((g.l + ox) * g.es, (g.b + oy) * g.es)
            local found = names()
            if found then
                for _, name in ipairs(found) do
                    if want == nil or name == want then
                        cells[name] = cells[name] or {}
                        cells[name][col .. ":" .. row] = { ox, oy, col = col, row = row }
                    end
                end
            end
            col = col + 1
        end
        row = row + 1
    end
end

-- A cluster of several cells may be two nodes of a name side by side: the
-- grid bridges any gap narrower than its step (Codex, PR #12). Its patch is
-- read again at half the step, as fine as the old grid of 8, and grouped anew.
-- One cell is one node; a cluster wider than REFINE_SPAN cells is an area (a
-- quest's), left as it is. Returns the cell lists, one per blip.
Scan.REFINE_SPAN = 4
local function refine(cl, g, step)
    if #cl.cells < 2 then return { cl.cells } end
    local c1, c2, r1, r2 = math.huge, -math.huge, math.huge, -math.huge
    for _, c in ipairs(cl.cells) do
        c1, c2 = math.min(c1, c.col), math.max(c2, c.col)
        r1, r2 = math.min(r1, c.row), math.max(r2, c.row)
    end
    if c2 - c1 >= Scan.REFINE_SPAN or r2 - r1 >= Scan.REFINE_SPAN then return { cl.cells } end
    local fine = {}
    sample(g, step / 2, c1 * step, r1 * step, math.min(g.w, (c2 + 1) * step), math.min(g.h, (r2 + 1) * step),
        fine, cl.name)
    local parts = clusters(fine)
    if #parts == 0 then return { cl.cells } end
    local out = {}
    for _, part in ipairs(parts) do out[#out + 1] = part.cells end
    return out
end

-- A blip at the centre of its cells, in the map's units from its centre, as drawn.
local function blip(name, members, g)
    local sx, sy = 0, 0
    for _, c in ipairs(members) do sx, sy = sx + c[1], sy + c[2] end
    return { name = name, x = sx / #members - g.w / 2, y = sy / #members - g.h / 2, cells = #members }
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
    local parts = {}                                   -- { name, cells } per blip
    local t0 = debugprofilestop()
    local okOn, errOn = pcall(Minimap.SetUsingSoftCursor, Minimap, true)
    local ok, err = okOn, errOn
    if okOn then
        ok, err = pcall(function()
            local cells = {}
            sample(g, step, 0, 0, g.w, g.h, cells)
            for _, cl in ipairs(clusters(cells)) do
                for _, members in ipairs(refine(cl, g, step)) do
                    parts[#parts + 1] = { name = cl.name, cells = members }
                end
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
    local byName, list = {}, {}
    for _, part in ipairs(parts) do
        local b = blip(part.name, part.cells, g)
        byName[part.name] = byName[part.name] or {}
        table.insert(byName[part.name], b)
        list[#list + 1] = b
    end
    return { byName = byName, blips = list, geometry = g, ms = debugprofilestop() - t0 }
end

-- How many blips of a name a sweep saw.
function Scan.Count(result, name)
    local b = result and result.byName[name]
    return b and #b or 0
end
