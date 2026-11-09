-- Locate.lua: where the minimap scan's nodes are (#91, step 2), from 70862.
--
-- The scan's presence read says how many of each node name are in range; this finds where.
-- A read lists what lies within a node's hit square of the cursor: 16 screen px, its centre
-- up to 3.5 px off the node (measured, docs/FOREVER-PROBE.md "The scan's last round"). So a
-- map M px wide over a view radius of R yards covers, for sure, a window W yards wide around
-- the map point under the cursor when W/2 yards is at most GUARANTEE_PX/2 px: M = 2R·G/W.
--
-- The search: the map's four quarters (W = R), each one that lists a name split in four
-- (W/2), down to FINE yards; a positive at that size is the node (the centroid of the
-- positive leaves within MATCH). One read serves every name it lists. Windows are held in
-- world yards and each read paired with where the player was at its placement and at the
-- read: the map follows the player, the frame stays, so what the read covered is the window
-- moved by the player's own move. A positive that came from a neighbour (the reach is wider
-- than the guarantee) only costs reads: the window that really holds the node is positive too.
--
-- Records live on evidence, not time: a valid read at a record's spot without its name, a
-- presence count of 0, or the record leaving the minimap's range drops it; one is re-checked
-- at its spot every RECHECK seconds, and all of a name when the count falls below them.
--
-- A node located where none was known alerts, unless a count's rise already did (then only
-- its sonar), it was there at the scan's first look after a reset (quiet), or it is a node the
-- player gathered from (`gone`: the same node, kept silently).

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Locate = {}
NR.Locate = Locate

Locate.GUARANTEE_PX = 9   -- the hit square 16 px less twice its 3.5 px offset
Locate.FINE = 16          -- yards: a window this small is a node's place (in game the leaves went
                          -- to 7 yards: a level of reads for little; a vein took ~10 s to locate)
Locate.MATCH = 20         -- yards: a located node this near a record of its name is that record
Locate.RECHECK = 15       -- seconds between re-checks of a record at its spot
Locate.GONE = 120         -- seconds a gathered node's spot is the same node
Locate.TRIES = 2          -- unread windows are tried this many times
Locate.OVERDUE = 3        -- presence reads with fewer in range before the surplus goes unchecked

local records = {}        -- { name, kind, north, west, at, instance, misses = 0 }
local windows = {}        -- { north, west, size, names = {[name] = true}, depth, tries, record }
local gone = {}           -- { name, north, west, at }
local counts = {}         -- the last presence read's counts
local quiet = nil         -- [name] = nodes in range at the first read after a reset, silent
local dirty = false
local found = {}          -- new records to announce, at the burst's end (the map home again)

local function d2(a, n, w) return (a.north - n) ^ 2 + (a.west - w) ^ 2 end

local function instanceNow()
    local ok, _, _, _, inst = pcall(UnitPosition, "player")
    return ok and API.Num(inst) or nil
end

function Locate.Records() return records end

-- Everything forgotten: a zone, tracking or zoom change, the scan turned on (quiet: the next
-- read's nodes are the baseline, located silently).
function Locate.Reset()
    records, windows, gone, counts, found = {}, {}, {}, {}, {}
    quiet = nil
    dirty = true
end

local function ofName(name)
    local n = 0
    for _, r in ipairs(records) do if r.name == name then n = n + 1 end end
    return n
end

local function drop(r, why)
    for i, x in ipairs(records) do
        if x == r then
            table.remove(records, i)
            dirty = true
            API.Trace(("locate: %s dropped (%s)"):format(r.name, why))
            return
        end
    end
end

-- The four windows of a square (the map's, or a positive window's).
local function split(north, west, size, names, depth)
    local q = size / 4
    for _, d in ipairs({ { q, q }, { q, -q }, { -q, q }, { -q, -q } }) do
        windows[#windows + 1] = { north = north + d[1], west = west + d[2], size = size / 2, names = names,
                                  depth = depth, tries = 0 }
    end
end

local function searching(name)
    for _, w in ipairs(windows) do if not w.record and w.names[name] then return true end end
    return false
end

-- A presence read (MoveScan): what needs finding or re-checking.
function Locate.Presence(c, now)
    local pn, pw
    do
        local ok, n, w = pcall(UnitPosition, "player")
        pn, pw = ok and API.Num(n), ok and API.Num(w)
    end
    if not pn then return end
    counts = c
    -- World positions need a map that doesn't turn (Scan.Where: nil when it rotates, in an
    -- instance, or unreadable; Codex, PR #102): no locating then, what was located forgotten.
    -- The presence alert doesn't need it.
    if not NR.Scan.Where() then
        if #records > 0 or #windows > 0 then
            records, windows = {}, {}
            dirty = true
            API.Trace("locate: the map rotates or is unreadable here: nothing located")
        end
        return
    end
    -- Out of the minimap's range: gone from it, whatever the count says (Codex, PR #102: a
    -- node ridden away from while another of its name came in kept the count at 1).
    do
        local okR, radius = pcall(C_Minimap.GetViewRadius)
        radius = okR and API.Num(radius)
        if radius then
            for i = #records, 1, -1 do
                if d2(records[i], pn, pw) > radius ^ 2 then drop(records[i], "out of range") end
            end
        end
    end
    if not quiet then
        quiet = {}
        for name, n in pairs(c) do quiet[name] = n - ofName(name) end
    end
    -- A name no longer in range: its records go (a valid read lists every node in range).
    for i = #records, 1, -1 do
        local r = records[i]
        if not c[r.name] then drop(r, "not in range") end
    end
    local need = {}
    for name, n in pairs(c) do
        local m = ofName(name)
        if n > m and not searching(name) then need[name] = true end
        if n < m then
            -- Fewer in range than recorded: each re-checked at its spot. Re-checks that can't
            -- read kept a mined vein as a ghost icon in game, so after OVERDUE such presence
            -- reads the count wins: the surplus goes, least recently confirmed first.
            local mine, overdue = {}, false
            for _, r in ipairs(records) do
                if r.name == name then
                    r.due, r.overdue = true, (r.overdue or 0) + 1
                    mine[#mine + 1] = r
                    if r.overdue >= Locate.OVERDUE then overdue = true end
                end
            end
            if overdue then
                table.sort(mine, function(a, b) return a.at < b.at end)
                for i = 1, m - n do drop(mine[i], "fewer in range than recorded") end
            end
        end
    end
    if next(need) then
        local okR, radius = pcall(C_Minimap.GetViewRadius)
        radius = okR and API.Num(radius)
        -- Straight to the map's sixteenths: its quarters all answered in game (at that size a
        -- node's hit square covers most of the tiny map), four reads for nothing a search.
        if radius then
            local before = #windows
            split(pn, pw, 2 * radius, need, 1)
            local quarters = {}
            for i = before + 1, #windows do quarters[#quarters + 1] = table.remove(windows) end
            for _, q in ipairs(quarters) do split(q.north, q.west, q.size, need, 2) end
        end
    end
end

-- The next window to read, as a placement for MoveScan, or nil: re-checks first, then the
-- deepest search window (a node found sooner); out of range or no longer needed, dropped.
function Locate.Next(pn, pw, radius, es)
    local now = GetTime()
    if not NR.Scan.Where() then return nil end
    for _, r in ipairs(records) do
        if (r.due or now - r.at >= Locate.RECHECK) and not r.checking then
            r.checking = true
            windows[#windows + 1] = { north = r.north, west = r.west, size = Locate.FINE, names = { [r.name] = true },
                                      depth = 99, tries = 0, record = r }
        end
    end
    local best, bestI
    for i = #windows, 1, -1 do
        local w = windows[i]
        local wanted = false
        for name in pairs(w.names) do
            if w.record or (counts[name] or 0) > ofName(name) then wanted = true end
        end
        if not wanted or math.sqrt(d2(w, pn, pw)) > radius + w.size / 2 then
            table.remove(windows, i)
            if w.record then
                w.record.checking = nil
                if d2(w.record, pn, pw) > radius ^ 2 then drop(w.record, "out of range") end
            end
        elseif not best or w.depth > best.depth
            or (w.depth == best.depth and d2(w, pn, pw) < d2(best, pn, pw)) then
            best, bestI = w, i                             -- deepest, then nearest the player
        end
    end
    if not best then return nil end
    table.remove(windows, bestI)
    local px = 2 * radius * Locate.GUARANTEE_PX / best.size       -- the map's width, screen px
    local units = px / es
    local k = 2 * radius / units                                   -- yards per map unit
    return { kind = "window", window = best, units = units, radius = radius,
             ox = -(best.west - pw) / k, oy = (best.north - pn) / k }
end

-- A node of `name` located near (north, west): an existing record renewed, a gathered spot's
-- node kept silently, or a new record (and its alert).
local function located(name, north, west, now)
    for _, r in ipairs(records) do
        if r.name == name and d2(r, north, west) <= Locate.MATCH ^ 2 then
            r.at, r.due, r.overdue = now, nil, nil
            return
        end
    end
    local r = { name = name, kind = NR.Learn.Kind(name), north = north, west = west, at = now,
                instance = instanceNow(), misses = 0 }
    records[#records + 1] = r
    dirty = true
    for i, g in ipairs(gone) do
        if g.name == name and now - g.at <= Locate.GONE and d2(g, north, west) <= Locate.MATCH ^ 2 then
            table.remove(gone, i)
            API.Trace("locate: " .. name .. " at a gathered spot: the same node, silent")
            return
        end
    end
    -- There at the scan's first look after a reset: no sound of its own (a rise that
    -- announced it still gets its sonar, Alert.Located).
    if quiet and (quiet[name] or 0) > 0 then
        quiet[name] = quiet[name] - 1
        r.quiet = true
    end
    API.Trace("locate: " .. name .. " found at a new spot" .. (r.quiet and " (there at the first look)" or ""))
    found[#found + 1] = r
end

-- A window's read (MoveScan): `c` the counts it listed; (pn, pw) the player at the read.
function Locate.Read(p, c, pn, pw, now)
    local w = p.window
    if not w then return end
    -- What the read covered: the window moved by the player's own move since the placement.
    local north, west = w.north, w.west
    if pn and p.pn then north, west = north + (pn - p.pn), west + (pw - p.pw) end
    if w.record then
        local r = w.record
        r.checking = nil
        if c[r.name] then
            r.at, r.due, r.overdue = now, nil, nil
        else
            drop(r, "not at its spot")
        end
        return
    end
    local positive = {}
    for name in pairs(w.names) do if c[name] then positive[name] = true end end
    if not next(positive) then return end
    if w.size <= Locate.FINE then
        for name in pairs(positive) do located(name, north, west, now) end
    else
        split(north, west, w.size, positive, w.depth + 1)
    end
end

-- A read that didn't count: the window tried again later, TRIES times.
function Locate.Unread(p)
    local w = p and p.window
    if not w then return end
    w.tries = w.tries + 1
    if w.tries < Locate.TRIES then
        windows[#windows + 1] = w
    elseif w.record then
        w.record.checking = nil
    end
end

-- The player gathered a node of that name: its records within NEAR yards go, their spots
-- remembered as the same node for GONE seconds (a vein mined again).
Locate.NEAR = 25           -- a located spot can be ~10 yards off (the 7 to 15 yard leaves, their reach)
function Locate.Gathered(name, now)
    local ok, n, w = pcall(UnitPosition, "player")
    n, w = ok and API.Num(n), ok and API.Num(w)
    if not n then return end
    for i = #records, 1, -1 do
        local r = records[i]
        if r.name == name and d2(r, n, w) <= Locate.NEAR ^ 2 then
            table.remove(records, i)
            dirty = true
        end
    end
    gone[#gone + 1] = { name = name, north = n, west = w, at = now }
end

-- Whether the records changed since the last call, and the new ones to announce (the
-- consumers are told once a burst, with the map home).
-- Search windows still open (re-checks aside): the scan comes back soon (MoveScan.LOCATE_GAP).
function Locate.Busy()
    for _, w in ipairs(windows) do if not w.record then return true end end
    return false
end

function Locate.Take()
    local d, f = dirty, found
    dirty, found = false, {}
    return d or #f > 0, f
end

Locate._test = { windows = function() return windows end, gone = function() return gone end,
                 quiet = function() return quiet end }
