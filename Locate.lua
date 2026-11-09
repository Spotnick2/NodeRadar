-- Locate.lua: where the minimap scan's nodes are (#91, step 2), from 70862.
--
-- The scan's presence read says how many of each node name are in range; this finds where.
-- A read lists what lies within a node's hit square of the cursor: 16 screen px, its centre
-- up to 3.5 px off the node (measured, docs/FOREVER-PROBE.md "The scan's last round"). So a
-- map M px wide over a view radius of R yards covers, for sure, a window W yards wide around
-- the map point under the cursor when W/2 yards is at most GUARANTEE_PX/2 px: M = 2R·G/W.
--
-- The search: the map's sixteenths (its quarters all answered in game), each window that lists
-- a name split in four, down to FINE yards; the positive leaves of a burst, grouped by name and
-- adjacency, are its nodes (a group's centre). One read serves every name it lists. Windows are
-- held in world yards and each read paired with where the player was at its placement and at
-- the read: the map follows the player, the frame stays, so what the read covered is the window
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
Locate.REACH = 1.3        -- a positive's reach, in windows: 11.5 px (8 + 3.5) against the 9 px guarantee
Locate.MATCH = 25         -- yards: a located node this near a record of its name is that record
                          -- (a leaf's width and its reach: one node lights adjacent leaves)
Locate.RECHECK = 15       -- seconds between re-checks of a record at its spot
Locate.GONE = 120         -- seconds a gathered node's spot is the same node
Locate.TRIES = 2          -- unread windows are tried this many times
Locate.OVERDUE = 3        -- presence reads with fewer in range before the surplus goes unchecked
Locate.SLACK = 25         -- yards: a located spot's error (a leaf's width and its reach); out of
                          -- range only beyond the radius by this (Codex, PR #102: a node by the rim
                          -- dropped and found again, alerting each time)
Locate.BACKOFF = 20       -- seconds before a search of a name that ended unresolved starts again
Locate.MIN_CHECK = 5      -- yards: the smallest re-check window (two records nearer than ~2x this
                          -- are near-duplicates: ambiguous, rebuilt)
Locate.NEAR = 25          -- yards: a gather takes the nearest record of its name this near

local records = {}        -- { name, kind, north, west, at, instance, misses = 0 }
local windows = {}        -- { north, west, size, names = {[name] = true}, depth, tries, record }
local gone = {}           -- { name, north, west, at }: gathered spots, the same node for GONE s
local counts = {}         -- the last presence read's counts
local quiet = nil         -- [name] = nodes in range at the first read after a reset, silent
local active = {}         -- [name] = true while a search of it has windows
local ended = {}          -- [name] = when its last search ran out (BACKOFF)
local hits = {}           -- this burst's positive leaves: { name, north, west, size }
local rebuilt = {}        -- [name] = when its records were last turned into priors (a rebuild)
local dirty = false
local found = {}          -- new records to announce, at the burst's end (the map home again)
local fresh = false       -- a search started since the last Take (MoveScan's quick run restarts)

local function d2(a, n, w) return (a.north - n) ^ 2 + (a.west - w) ^ 2 end

local function instanceNow()
    local ok, _, _, _, inst = pcall(UnitPosition, "player")
    return ok and API.Num(inst) or nil
end

function Locate.Records() return records end

-- Everything forgotten: a zone, tracking or zoom change, the scan turned on (quiet: the next
-- read's nodes are the baseline, located silently).
function Locate.Reset()
    records, windows, gone, counts, found, active, ended, hits = {}, {}, {}, {}, {}, {}, {}, {}
    rebuilt = {}
    quiet = nil
    dirty, fresh = true, false
end

-- The alert's silent baseline taken again (Alert.Reset: a zoom, Codex, PR #102): the next
-- presence read's unrecorded nodes are located silently. The records stay (world yards).
function Locate.Rebaseline() quiet = nil end

-- Records of a name, its priors aside (a rebuild's: drawn, not counted, being found again).
local function ofName(name)
    local n = 0
    for _, r in ipairs(records) do if r.name == name and not r.prior then n = n + 1 end end
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

-- A rebuild (Codex, PR #102: guessing which of a name's records to sacrifice kept losing live
-- nodes in clusters): its records become priors, still drawn but no longer counted, so a fresh
-- search finds every node of the name again. A node found where a prior was takes it back,
-- silently; one found elsewhere is new. Once the count is met, priors not found again go;
-- unresolved, they stay until a later search. At most once a BACKOFF per name.
local function rebuild(name, now, why)
    if now - (rebuilt[name] or -math.huge) < Locate.BACKOFF then return false end
    rebuilt[name] = now
    for _, r in ipairs(records) do
        if r.name == name then r.prior, r.due, r.checking, r.overdue = true, nil, nil, nil end
    end
    ended[name] = nil
    API.Trace("locate: " .. name .. " rebuilt (" .. why .. ")")
    return true
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
    local before = counts                                  -- the read before: what an ended search ran under
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
                if d2(records[i], pn, pw) > (radius + Locate.SLACK) ^ 2 then drop(records[i], "out of range") end
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
    -- Names gone from range: their search state and quiet allowances go with them (Codex,
    -- PR #102: an allowance left by a vanished node silenced a later one of its name).
    for name in pairs(active) do if not c[name] then active[name], ended[name] = nil, nil end end
    for name in pairs(ended) do if not c[name] then ended[name] = nil end end
    for name, q in pairs(quiet) do quiet[name] = math.min(q, math.max(0, (c[name] or 0) - ofName(name))) end
    -- Expired gathered spots trimmed.
    for i = #gone, 1, -1 do if now - gone[i].at > Locate.GONE then table.remove(gone, i) end end
    local need = {}
    for name, n in pairs(c) do
        local m = ofName(name)
        -- A search that ran out unresolved (two nodes too close to tell apart, one by the rim)
        -- starts again only after BACKOFF, unless the count rose since (Codex, PR #102: it
        -- restarted every presence read; then the backoff also held a successful search's
        -- successor and a node arriving later).
        local on = searching(name)
        if active[name] and not on then
            -- Judged by the count it ran under (the read before), not this one, which may
            -- already hold a new node.
            local ran = before[name] or 0
            active[name] = nil
            if ran > m then
                ended[name] = { at = now, n = ran }
                API.Trace(("locate: %s search ran out with %d of %d found: again in %d s, or at a rise"):format(name, m, ran, Locate.BACKOFF))
            else
                ended[name] = nil
            end
        end
        local e = ended[name]
        -- A rise since the last read is new demand, whatever the old search's count (Codex,
        -- PR #102: 3, 2, 3 waited the old backoff).
        if e and (n > e.n or n <= m or n > (before[name] or 0)) then ended[name], e = nil, nil end
        if n > m and not on and not (e and now - e.at < Locate.BACKOFF) then
            need[name], active[name] = true, true
            API.Trace(("locate: %s search starts (%d in range, %d recorded)"):format(name, n, m))
        elseif n > m and on and n > (before[name] or 0) then
            -- A rise mid-search: the new node can be where this search already read nothing
            -- (in game a vein beside the player, after the windows there were read for a far
            -- one: the search ran out 1 of 2 and backed off). Searched again from the top, its
            -- old windows dropped (kept, they were read first, deepest first, and doubled it).
            for i = #windows, 1, -1 do
                local w = windows[i]
                if not w.record and w.names[name] then
                    local rest = {}
                    for other in pairs(w.names) do if other ~= name then rest[other] = true end end
                    if next(rest) then w.names = rest else table.remove(windows, i) end
                end
            end
            need[name] = true
            API.Trace(("locate: %s search starts again (%d in range, a rise)"):format(name, n))
        elseif n > m and not on then
            API.Trace(("locate: %s waits its backoff (%.0f s left)"):format(name, Locate.BACKOFF - (now - e.at)))
        end
        -- A rebuild done: the count met by nodes found again, the priors left are gone.
        if n <= m then
            for i = #records, 1, -1 do
                if records[i].name == name and records[i].prior then drop(records[i], "not found again") end
            end
        end
        if n < m then
            -- Fewer in range than recorded: each re-checked at its spot. Re-checks that can't
            -- read kept a mined vein as a ghost icon in game, so after OVERDUE such presence
            -- reads the count wins: the surplus goes, least recently confirmed first.
            local mine, overdue = {}, false
            for _, r in ipairs(records) do
                if r.name == name and not r.prior then
                    r.due, r.overdue = true, (r.overdue or 0) + 1
                    mine[#mine + 1] = r
                    if r.overdue >= Locate.OVERDUE then overdue = true end
                end
            end
            if overdue then
                table.sort(mine, function(a, b) return a.at < b.at end)
                for i = 1, m - n do drop(mine[i], "fewer in range than recorded") end
            end
        else
            for _, r in ipairs(records) do if r.name == name then r.overdue = nil end end
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
            fresh = true
        end
    end
end

-- The next window to read, as a placement for MoveScan, or nil: re-checks first, then the
-- deepest search window (a node found sooner), the nearest of those; out of range or no
-- longer needed, dropped.
function Locate.Next(pn, pw, radius, es)
    local now = GetTime()
    if not NR.Scan.Where() then return nil end
    for _, r in ipairs(records) do
        if not r.prior and (r.due or now - r.at >= Locate.RECHECK) and not r.checking and now >= (r.checkAfter or 0) then
            r.checking = true
            -- Sized to half the gap to the nearest other record of its name (MIN_CHECK to FINE),
            -- so the read's reach can't take in that neighbour: a cluster's re-checks stay
            -- conclusive (a fixed 16 yards made two herbs 25 yards apart ambiguous for good).
            local gap = math.huge
            for _, o in ipairs(records) do
                if o ~= r and o.name == r.name and not o.prior then gap = math.min(gap, math.sqrt(d2(o, r.north, r.west))) end
            end
            -- Wide enough to cover the record's own uncertainty (its node can be r.err off it, on
            -- each axis) when nothing of its name is near, so a negative there is conclusive;
            -- in a cluster, no wider than half the gap (Read: a narrower negative proves nothing).
            local err = r.err or Locate.FINE * Locate.REACH
            local size = math.max(Locate.MIN_CHECK, math.min(2 * err, gap / 2))
            windows[#windows + 1] = { north = r.north, west = r.west, size = size, names = { [r.name] = true },
                                      depth = 99, tries = 0, record = r }
        end
    end
    -- Pruned first, then chosen, then removed by identity (Codex, PR #102: removing by an index
    -- taken before the pruning took the wrong window).
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
                if d2(w.record, pn, pw) > (radius + Locate.SLACK) ^ 2 then drop(w.record, "out of range") end
            end
        end
    end
    local best
    for _, w in ipairs(windows) do
        if not best or w.depth > best.depth or (w.depth == best.depth and d2(w, pn, pw) < d2(best, pn, pw)) then
            best = w                                       -- deepest, then nearest the player
        end
    end
    if not best then return nil end
    for i, w in ipairs(windows) do
        if w == best then table.remove(windows, i); break end
    end
    local px = 2 * radius * Locate.GUARANTEE_PX / best.size       -- the map's width, screen px
    local units = px / es
    local k = 2 * radius / units                                   -- yards per map unit
    return { kind = "window", window = best, units = units, radius = radius,
             ox = -(best.west - pw) / k, oy = (best.north - pn) / k }
end

local function goneAt(name, north, west, now)
    for _, g in ipairs(gone) do
        if g.name == name and now - g.at <= Locate.GONE and d2(g, north, west) <= Locate.MATCH ^ 2 then return g end
    end
end

-- A node of `name` located near (north, west): an existing record renewed, a gathered spot's
-- node kept silently, or a new record (and its alert).
local function located(name, north, west, now, size)
    -- The same node: within a leaf's reach on each axis (a fixed MATCH merged two nodes a
    -- couple of leaves apart at a small radius; Codex, PR #102).
    local reach = (size or Locate.FINE) * Locate.REACH
    for _, r in ipairs(records) do
        if r.name == name and not r.prior and math.abs(r.north - north) <= reach and math.abs(r.west - west) <= reach then
            r.at, r.due, r.overdue = now, nil, nil
            return
        end
    end
    -- A rebuild's prior here: the same node, found again (its record, icon and identity kept).
    for _, r in ipairs(records) do
        if r.name == name and r.prior and math.abs(r.north - north) <= reach and math.abs(r.west - west) <= reach then
            r.prior, r.at, r.north, r.west, r.err = nil, now, north, west, reach
            dirty = true
            return
        end
    end
    -- r.err: how far its node can be from this spot, per axis (a leaf's reach, Codex, PR #102).
    local r = { name = name, kind = NR.Learn.Kind(name), north = north, west = west, at = now,
                instance = instanceNow(), misses = 0, err = reach }
    records[#records + 1] = r
    dirty = true
    -- A gathered spot keeps its node silent for all of GONE, whatever it's found again
    -- (Codex, PR #102: consumed at the first rediscovery, a second one alerted).
    if goneAt(name, north, west, now) then
        API.Trace("locate: " .. name .. " at a gathered spot: the same node, silent")
        return
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

-- A burst's positive leaves, one node each group of adjacent ones (a node lights the leaves
-- within its reach, Codex, PR #102: one node made two records): grouped by name, linked when
-- within a leaf and its reach, each group's centre located once.
-- Per axis: one node lights leaves whose centres are up to 2 x 0.64 leaves apart on each (its
-- reach), diagonal neighbours included.
local function linked(a, b)
    local link = (a.size + b.size) / 2 * Locate.REACH
    return a.name == b.name and math.abs(a.north - b.north) <= link and math.abs(a.west - b.west) <= link
end

local function settleHits(now)
    -- Each group compatible with one node: a leaf joins only when linked to every member
    -- (Codex, PR #102: chaining neighbours merged two nodes into one record for good).
    -- In a fixed order (by north, then west), so the grouping doesn't depend on the read order
    -- (Codex, PR #102: W, 2W, 0, 3W made three groups of two nodes' four leaves).
    table.sort(hits, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        if a.north ~= b.north then return a.north < b.north end
        return a.west < b.west
    end)
    local groups = {}
    for _, h in ipairs(hits) do
        local home
        for _, g in ipairs(groups) do
            local all = true
            for _, m in ipairs(g) do if not linked(h, m) then all = false; break end end
            if all then home = g; break end
        end
        if home then home[#home + 1] = h else groups[#groups + 1] = { h } end
    end
    -- Never more new nodes than the presence count leaves unaccounted for: an extra group is an
    -- ambiguous partition, left unresolved (the search carries on), not a published identity.
    -- Each group's centre, and the records some group of this burst points at.
    local pointed = {}
    for _, g in ipairs(groups) do
        local n, w = 0, 0
        for _, m in ipairs(g) do n, w = n + m.north, w + m.west end
        g.n, g.w, g.reach = n / #g, w / #g, g[1].size * Locate.REACH
        for _, r in ipairs(records) do
            if r.name == g[1].name and not r.prior and math.abs(r.north - g.n) <= g.reach
                and math.abs(r.west - g.w) <= g.reach then
                g.match, pointed[r] = r, true
            end
        end
    end
    local room = {}
    for _, g in ipairs(groups) do
        local name = g[1].name
        if room[name] == nil then room[name] = math.max(0, (counts[name] or 0) - ofName(name)) end
        -- Beyond the count: a node somewhere is recorded wrong (a duplicate, a stale one), and no
        -- single record can be safely blamed: the name is rebuilt, and the group placed in it.
        if not g.match and room[name] == 0 and rebuild(name, now, "a group beyond the count") then
            room[name] = math.max(0, (counts[name] or 0) - ofName(name))
        end
        if g.match or room[name] > 0 then
            if not g.match then room[name] = room[name] - 1 end
            located(name, g.n, g.w, now, g[1].size)
        else
            API.Trace("locate: " .. name .. " a group beyond the count, left unresolved")
        end
    end
    hits = {}
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
            -- A positive renews it only if no other record of its name lies within the read's
            -- reach (Codex, PR #102: a neighbour's positive kept a dead one alive).
            local reach = w.size / 2 + w.size * Locate.REACH
            for _, o in ipairs(records) do
                if o ~= r and o.name == r.name and not o.prior and d2(o, north, west) <= reach ^ 2 then
                    -- Two records of a name within one read's reach: which is real can't be told
                    -- from here; a rebuild settles it (or, within BACKOFF of the last, later).
                    r.checkAfter = now + Locate.RECHECK
                    rebuild(r.name, now, "ambiguous re-check")
                    return
                end
            end
            r.at, r.due, r.overdue = now, nil, nil
        elseif w.size / 2 + 0.01 >= (r.err or Locate.FINE * Locate.REACH) then
            drop(r, "not at its spot")
        else
            -- A window narrower than the record's uncertainty (a cluster): its negative can't
            -- tell a gone node from one a few yards off its estimate (Codex, PR #102: live
            -- records dropped). A rebuild settles it; within BACKOFF, checked again later.
            r.checkAfter = now + Locate.RECHECK
            rebuild(r.name, now, "a narrow re-check found nothing")
        end
        return
    end
    local positive = {}
    for name in pairs(w.names) do if c[name] then positive[name] = true end end
    if not next(positive) then return end
    if w.size <= Locate.FINE then
        for name in pairs(positive) do hits[#hits + 1] = { name = name, north = north, west = west, size = w.size } end
    else
        split(north, west, w.size, positive, w.depth + 1)
    end
end

-- A read that didn't count: the window tried again later, TRIES times; an exhausted re-check
-- waits RECHECK before the next (Codex, PR #102: recreated at once, it starved the searches).
function Locate.Unread(p)
    local w = p and p.window
    if not w then return end
    w.tries = w.tries + 1
    API.Trace(("locate: a %.0f yd window%s placed but not read (try %d of %d)"):format(w.size,
        w.record and " (re-check)" or "", w.tries, Locate.TRIES))
    if w.tries < Locate.TRIES then
        windows[#windows + 1] = w
    elseif w.record then
        w.record.checking = nil
        w.record.checkAfter = GetTime() + Locate.RECHECK
    end
end

-- The player gathered a node of that name: the nearest record of its name within NEAR goes
-- (Codex, PR #102: every one within 25 yards went, a live neighbour too), its spot (or the
-- player's, none recorded) remembered as the same node for GONE seconds (a vein mined again).
function Locate.Gathered(name, now)
    local ok, n, w = pcall(UnitPosition, "player")
    n, w = ok and API.Num(n), ok and API.Num(w)
    if not n then return end
    local best, bestD
    for _, r in ipairs(records) do
        local d = d2(r, n, w)
        if r.name == name and d <= Locate.NEAR ^ 2 and (not bestD or d < bestD) then best, bestD = r, d end
    end
    if best then drop(best, "gathered") end
    gone[#gone + 1] = { name = name, north = best and best.north or n, west = best and best.west or w, at = now }
end

-- A burst stopped before its end: its positive leaves go with it (Codex, PR #102: kept, a later
-- Take placed them after contradictory reads).
function Locate.Cancel() hits = {} end

-- Search windows still open (re-checks aside): the scan comes back soon (MoveScan.LOCATE_GAP).
-- Windows waiting: search windows, re-checks (the burst line, #91).
function Locate.Queued()
    local s, r = 0, 0
    for _, w in ipairs(windows) do if w.record then r = r + 1 else s = s + 1 end end
    return s, r
end

function Locate.Busy()
    for _, w in ipairs(windows) do if not w.record then return true end end
    return false
end

-- Whether a search started since the last call (MoveScan restarts its quick run for it).
function Locate.TakeFresh()
    local f = fresh
    fresh = false
    return f
end

-- Whether the records changed since the last call, and the new ones to announce (the
-- consumers are told once a burst, with the map home). The burst's leaves settle first.
function Locate.Take()
    if #hits > 0 then settleHits(GetTime()) end
    local d, f = dirty, found
    dirty, found = false, {}
    return d or #f > 0, f
end

Locate._test = { rebuild = function(name, now, why) return rebuild(name, now, why or "test") end,
                 windows = function() return windows end, gone = function() return gone end,
                 quiet = function() return quiet end, hits = function() return hits end }
