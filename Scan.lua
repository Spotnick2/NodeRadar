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

-- The map's own units between samples. A node's blip is a square 25 units wide
-- (docs/FOREVER-PROBE.md, "Item icons, first round"; a quest object's is 15, at
-- every zoom: "Memory"), so 14 never misses one, with room for a smaller one.
-- Each read is a new table (2.5 KB), even empty: 196 reads a sweep, not 625 at
-- 8 (#11).
Scan.STEP = 14

-- One node's hit area (#28): a square this wide around its dot, eight of eight
-- on Glass MiniMap's 198-unit map. Scan.Centre measures within NODE_SLACK of it.
Scan.NODE = 25
Scan.NODE_SLACK = 2
-- From a blip's centroid (at most 5.5 off its node's centre: one or two samples
-- of the grid per axis), a point this far out is past the node's edge.
Scan.FAR = 24
Scan.HALVINGS = 6      -- 24 / 64: an edge to 0.4 units

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
-- read again at half the step, as fine as the old grid of 8, and grouped anew,
-- however wide: a chain of nodes is as wide as an area (Codex again). Only a
-- name the caller counts is (`count(name)`, the alert's nodes): a quest's
-- area, or a name not known yet, stays as it is and costs nothing more. One
-- cell is one node. Returns the cell lists, one per blip.
local function refine(cl, g, step, count)
    if #cl.cells < 2 or not (count and count(cl.name)) then return { cl.cells } end
    local c1, c2, r1, r2 = math.huge, -math.huge, math.huge, -math.huge
    for _, c in ipairs(cl.cells) do
        c1, c2 = math.min(c1, c.col), math.max(c2, c.col)
        r1, r2 = math.min(r1, c.row), math.max(r2, c.row)
    end
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

-- Where the sweep was taken, for a blip's map coordinates (#27): the player's
-- zone map, position on it and size in yards, and the minimap's view radius;
-- nil when any of it is missing or secret, in an instance, or when the
-- minimap rotates (Forever has no such option; unmeasured, so no numbers).
local function call(f, ...)
    if type(f) ~= "function" then return false end
    return pcall(f, ...)
end

function Scan.Where()
    local okI, instanced = call(IsInInstance)
    if not okI or API.IsSecret(instanced) or type(instanced) ~= "boolean" or instanced then return nil end
    local okR, rotate = call(C_CVar and C_CVar.GetCVar, "rotateMinimap")
    if not okR or API.IsSecret(rotate) or (rotate ~= "0" and rotate ~= "1") then return nil end
    if rotate == "1" then
        local okG, ignored = call(C_Minimap.IsRotateMinimapIgnored)
        if not okG or API.IsSecret(ignored) or ignored ~= true then return nil end
    end
    local okM, map = call(C_Map.GetBestMapForUnit, "player")
    map = okM and API.Num(map)
    if not map then return nil end
    local okP, pos = call(C_Map.GetPlayerMapPosition, map, "player")
    if not okP or pos == nil or API.IsSecret(pos) or type(pos) ~= "table" then return nil end
    local okXY, px, py = call(pos.GetXY, pos)
    px, py = okXY and API.Num(px), okXY and API.Num(py)
    local okS, w, h = call(C_Map.GetMapWorldSize, map)
    w, h = okS and API.Num(w), okS and API.Num(h)
    local okV, radius = call(C_Minimap.GetViewRadius)
    radius = okV and API.Num(radius)
    if not (px and py and w and h and radius) or w <= 0 or h <= 0 or radius <= 0 then return nil end
    return { map = map, x = px, y = py, w = w, h = h, radius = radius }
end

-- A blip's zone-map coordinates: uiMapID, x, y (0-1), or nil. HereBeDragons-
-- Pins' minimap drawing inverted, measured within reach of two gathered
-- nodes (docs/FOREVER-PROBE.md): the offset in the map's own units x radius /
-- half-width = yards, up north, the map's y growing southward.
function Scan.MapPosition(result, blip)
    local where, g = result and result.where, result and result.geometry
    if not (where and g and blip) then return nil end
    local k = where.radius / (g.w / 2)
    local x, y = where.x + blip.x * k / where.w, where.y - blip.y * k / where.h
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return where.map, x, y
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
-- ms }, or nil and why. The soft cursor is turned off on every path. With
-- `count`, the names it says yes to are told apart side by side (refine);
-- without, every cluster is one blip, the same grouping on every sweep.
function Scan.Sweep(count)
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
                for _, members in ipairs(refine(cl, g, step, count)) do
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
    return { byName = byName, blips = list, geometry = g, where = Scan.Where(), ms = debugprofilestop() - t0 }
end

-- Whether a point (map units from its centre) reads that name.
local function reads(g, x, y, name)
    Minimap:UpdateMouseoverAtPoint((g.l + g.w / 2 + x) * g.es, (g.b + g.h / 2 + y) * g.es)
    local found = names()
    if found then
        for _, n in ipairs(found) do if n == name then return true end end
    end
    return false
end

-- How far from the blip, along (dx, dy), its name stops; nil when the far
-- point reads it too (another of its name there).
local function edge(g, b, dx, dy)
    if reads(g, b.x + dx * Scan.FAR, b.y + dy * Scan.FAR, b.name) then return nil end
    local lo, hi = 0, Scan.FAR
    for _ = 1, Scan.HALVINGS do
        local mid = (lo + hi) / 2
        if reads(g, b.x + dx * mid, b.y + dy * mid, b.name) then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
end

-- A blip's node centre, or nil and why. Both widths must be one node's square:
-- two of a name merged into one cluster measure as their union, wider (Codex,
-- #28: a pair at (-7, -7) and (7, 7) read 39 x 39 between them).
local function centre(g, b)
    if not reads(g, b.x, b.y, b.name) then return nil, "its centroid reads nothing" end
    local r = edge(g, b, 1, 0)
    local l = r and edge(g, b, -1, 0)
    local u = l and edge(g, b, 0, 1)
    local d = u and edge(g, b, 0, -1)
    if not d then return nil, "crowded" end
    if math.abs(r + l - Scan.NODE) > Scan.NODE_SLACK or math.abs(u + d - Scan.NODE) > Scan.NODE_SLACK then
        return nil, "not one node"
    end
    return b.x + (r - l) / 2, b.y + (u - d) / 2
end

-- Measures each blip's centre from this frame's sweep (#28): sets b.cx, b.cy
-- or b.why. About 29 reads a blip. True, or nil and why; the soft cursor is
-- turned off on every path, as after a sweep.
function Scan.Centre(blips)
    local g, why = Scan.Geometry()
    if not g then return nil, why end
    local okOn, errOn = pcall(Minimap.SetUsingSoftCursor, Minimap, true)
    local ok, err = okOn, errOn
    if okOn then
        ok, err = pcall(function()
            for _, b in ipairs(blips) do
                local x, y = centre(g, b)
                if x then b.cx, b.cy = x, y else b.why = y end
            end
        end)
    end
    putBack(g)
    pcall(Minimap.SetUsingSoftCursor, Minimap, false)
    if not ok then
        API.Fail("centre", err)
        return nil, "measuring failed: " .. tostring(err)
    end
    return true
end

-- How many blips of a name a sweep saw.
function Scan.Count(result, name)
    local b = result and result.byName[name]
    return b and #b or 0
end
