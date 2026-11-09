-- #91, step 2: the corrections from Codex's broad review of PR #102 (gpt-6-astra, 2026-11-09),
-- each with its failure scenario. The stubs' move model as in test_locate.lua.

local function fresh(db)
    local passed, failed = 0, 0
    if Kit then passed, failed = Kit.counts() end
    dofile("tests/wow_stubs.lua")
    dofile("tests/harness.lua")
    for _ = 1, passed do check(true) end
    for _ = 1, failed do check(false, "(an earlier case's failure, carried over)") end
    NodeRadar, NodeRadarDB, NodeRadarCharDB = nil, nil, nil
    WoW.build = "70862"
    WoW.moveModel = true
    WoW.tracking[1].active = true
    WoW.speed = 0
    WoW.cursor = { 300, 300 }
    WoW.pos = { 1000, 2000, 0, 0 }
    WoW.blips = {}
    local NR = loadAddon({ db = db or { moveScan = true, moveScanAsked = true } })
    NR.db.learn = false
    return NR
end

local function frames(n)
    for _ = 1, n or 1 do
        WoW.now = WoW.now + 0.02
        WoW.tick(0.02)
    end
end

local function bursts(limit, done)
    for _ = 1, limit do
        if done and done() then return true end
        local started = false
        for _ = 1, 800 do
            frames(1)
            if NodeRadar.MoveScan._test.burst() then started = true; break end
        end
        if not started then return false end
        for _ = 1, 60 do
            if not NodeRadar.MoveScan._test.burst() then break end
            frames(1)
        end
    end
    return done and done() or false
end

local YARDS = 150 / 99
local function has(list, x) for _, v in ipairs(list) do if v == x then return true end end return false end
local PRESENCE = NodeRadar and NodeRadar.MoveScan.PRESENCE_PX or 15.4

-- Reads answer `answer(width)` instead of the model while `on`: nil leaves the model's.
local function override(answer)
    local real = C_TooltipInfo.GetMinimapMouseover
    C_TooltipInfo.GetMinimapMouseover = function()
        local a = answer(Minimap:GetWidth())
        if a == "model" then return real() end
        return a
    end
    return function() C_TooltipInfo.GetMinimapMouseover = real end
end
local function isPresence(width) return width < 14 end      -- 15.4 px / 1.2: 12.8 units

--------------------------------------------------------------------------------
-- 1. A failed presence read ends the burst: no window decides anything after it.
--------------------------------------------------------------------------------

local NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
local rec = NR.Locate.Records()[1]
rec.due = true
local windows0 = NR.MoveScan.stats.windows
local undo = override(function(w) if isPresence(w) then return { type = 21, lines = {} } end return { type = 21, lines = {} } end)
bursts(1)
undo()
check(NR.MoveScan.stats.windows == windows0, "a failed presence read: no locate window follows in its burst")
check(has(NR.Locate.Records(), rec), "...so an empty window can't drop a live record")

--------------------------------------------------------------------------------
-- 2. A window answering nil is unread, not "no node"; an empty one is read again once.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
rec = NR.Locate.Records()[1]
rec.due = true
undo = override(function(w) if isPresence(w) then return "model" end return nil end)
bursts(1)
undo()
check(has(NR.Locate.Records(), rec), "a re-check answering nil keeps the record (unread)")
-- One empty frame, then the node: renewed, not dropped.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
rec = NR.Locate.Records()[1]
rec.due, rec.at = true, WoW.now - 100
local empties = 1
undo = override(function(w)
    if not isPresence(w) and empties > 0 then empties = empties - 1; return { type = 21, lines = {} } end
    return "model"
end)
bursts(1)
undo()
check(has(NR.Locate.Records(), rec) and rec.at > WoW.now - 10, "one empty frame, then the node: re-read, renewed")

--------------------------------------------------------------------------------
-- 3. Locate.Next removes the window it returns, not another (pruning shifted the index).
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(2)                                           -- a presence read: counts known
local ws = NR.Locate._test.windows()
for i = #ws, 1, -1 do table.remove(ws, i) end
local unwanted = { north = WoW.pos[1], west = WoW.pos[2], size = 30, names = { Nowhere = true }, depth = 5, tries = 0 }
local best = { north = WoW.pos[1] + 5, west = WoW.pos[2], size = 30, names = { Silverleaf = true }, depth = 5, tries = 0 }
local other = { north = WoW.pos[1] + 50, west = WoW.pos[2], size = 60, names = { Silverleaf = true }, depth = 4, tries = 0 }
ws[1], ws[2], ws[3] = unwanted, best, other
local p = NR.Locate.Next(WoW.pos[1], WoW.pos[2], 150, 1.2)
check(p and p.window == best, "(control) the deepest wanted window chosen")
check(not has(ws, best) and has(ws, other), "...it's the one removed; the other stays queued")

--------------------------------------------------------------------------------
-- 4. One node lighting two diagonal leaves (21 yards apart at R 233): one record.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(2)
local leaf = 15
local p1 = { window = { north = 1100, west = 2100, size = leaf, names = { Silverleaf = true }, depth = 6, tries = 0 } }
local p2 = { window = { north = 1100 + leaf, west = 2100 + leaf, size = leaf, names = { Silverleaf = true }, depth = 6, tries = 0 } }
local before = #NR.Locate.Records()
NR.Locate.Read(p1, { Silverleaf = 1 }, nil, nil, WoW.now)
NR.Locate.Read(p2, { Silverleaf = 1 }, nil, nil, WoW.now)
NR.Locate.Take()
check(#NR.Locate.Records() == before + 1, "two diagonal positive leaves of one burst: one record")

--------------------------------------------------------------------------------
-- 5. A re-check whose reach holds another record of its name doesn't renew it.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
local live = NR.Locate.Records()[1]
local dead = { name = "Silverleaf", north = live.north + 12, west = live.west, at = WoW.now - 100, misses = 0 }
table.insert(NR.Locate.Records(), dead)
NR.Locate.Read({ window = { north = dead.north, west = dead.west, size = 16, names = { Silverleaf = true }, record = dead } },
    { Silverleaf = 1 }, nil, nil, WoW.now)
check(dead.at < WoW.now - 50 and dead.checkAfter ~= nil, "a re-check lit by a neighbour of its name: not renewed, retried later")

--------------------------------------------------------------------------------
-- 6. An exhausted unread re-check waits RECHECK before the next (it starved searches).
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
rec = NR.Locate.Records()[1]
local check1 = { window = { north = rec.north, west = rec.west, size = 16, names = { Silverleaf = true }, record = rec, tries = 1 } }
rec.checking = true
NR.Locate.Unread(check1)                            -- its second unread
NR.Locate.Next(WoW.pos[1], WoW.pos[2], 150, 1.2)
local requeued = false
for _, w in ipairs(NR.Locate._test.windows()) do if w.record == rec then requeued = true end end
check(not requeued and rec.checkAfter and rec.checkAfter > WoW.now, "an exhausted re-check isn't queued again at once")

--------------------------------------------------------------------------------
-- 7. A search that ended unresolved (the presence count above what can be located) starts
-- again only after BACKOFF, not at every presence read.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
undo = override(function(w)
    if isPresence(w) then
        local d = C_TooltipInfo and nil
        local lines = { { leftText = "Elegia", type = 0 }, { leftText = "Silverleaf", type = 0 }, { leftText = "Silverleaf", type = 0 } }
        return { type = 21, lines = lines }                 -- two in range; one of them never found
    end
    return "model"
end)
bursts(12, function() return #NR.Locate.Records() > 0 end)
bursts(20, function() return not NR.Locate.Busy() end)   -- the first search runs out, unresolved
local w1 = NR.MoveScan.stats.windows
bursts(2)                                            -- two more presence reads, within BACKOFF
local w2 = NR.MoveScan.stats.windows
undo()
check(not NR.Locate.Busy() and w2 - w1 <= 2,
    "an unresolved search doesn't restart at every presence read (" .. (w2 - w1) .. " windows)")

--------------------------------------------------------------------------------
-- 8. Alert tokens: a rise whose node vanished before it was located doesn't silence a later
-- replacement; a token never outlives OWED_TTL.
--------------------------------------------------------------------------------

NR = fresh()
local A = NR.Alert
A.Reset("test")                                                 -- a silent baseline, no token
A.Counts({ Silverleaf = 1 }, 100, nil, nil, math.huge)
A.Counts({ Silverleaf = 2 }, 101, nil, nil, math.huge, 0)       -- a rise: one token
A.Counts({ Silverleaf = 1 }, 102, nil, nil, math.huge, 0)       -- the risen one gone, unlocated
local sounds = #WoW.sounds
WoW.now = 110
A.Located({ name = "Silverleaf", kind = "herbs", north = WoW.pos[1] + 30, west = WoW.pos[2] }, 110)
check(#WoW.sounds == sounds + 1, "a fall retired the token: a later replacement located alerts")
NR = fresh()
A = NR.Alert
A.Reset("test")
A.Counts({ Silverleaf = 1 }, 100, nil, nil, math.huge)
A.Counts({ Silverleaf = 2 }, 101, nil, nil, math.huge, 0)
sounds = #WoW.sounds
A.Located({ name = "Silverleaf", kind = "herbs", north = WoW.pos[1] + 30, west = WoW.pos[2] }, 101 + A.OWED_TTL + 1)
check(#WoW.sounds == sounds + 1, "a token older than OWED_TTL is spent: located, it alerts")

-- The owed branch delivers the solo ping (the sound had no place for it).
NR = fresh({ moveScan = true, moveScanAsked = true, ping = true })
A = NR.Alert
A.Counts({ Silverleaf = 1 }, 100, nil, nil, math.huge)
A.Counts({ Silverleaf = 2 }, 101, nil, nil, math.huge, 0)
local pings = #WoW.pings
A.Located({ name = "Silverleaf", kind = "herbs", north = WoW.pos[1] + 30, west = WoW.pos[2] }, 102)
check(#WoW.pings == pings + 1, "the owed sonar's located node gets the solo ping too")

--------------------------------------------------------------------------------
-- 9. Quest areas that don't read off: no locate window (their outlines would show).
--------------------------------------------------------------------------------

NR = fresh()
local quest = { name = "Quest areas", filterID = 65536, active = true }
table.insert(WoW.tracking, quest)
WoW.refuseTrackingOff = true
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(6)
WoW.refuseTrackingOff = false
check(NR.MoveScan.stats.valid > 0 and NR.MoveScan.stats.windows == 0, "quest areas refusing to turn off: presence only, no window")

--------------------------------------------------------------------------------
-- 10. The scan turned off and on resets Locate with the alert: one baseline.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
SlashCmdList.NODERADAR("scan")
SlashCmdList.NODERADAR("scan")
check(#NR.Locate.Records() == 0 and NR.Locate._test.quiet() == nil, "off and on: Locate's records and baseline reset too")

-- A zoom (Minimap:SetZoom) resets the alert: a node it shows is counted and located silently.
NR = fresh()
NR.db.cooldown = 0
bursts(3)                                                -- a first look with nothing in range
check(NR.Locate._test.quiet() ~= nil, "zoom: the first look taken")
local sounds10 = #WoW.sounds
Minimap:SetZoom(2)                                       -- the player zooms out
WoW.blips = { { "Silverleaf", 20, -15 } }                -- and a node shows
bursts(20, function() return #NR.Locate.Records() > 0 end)
check(#NR.Locate.Records() == 1, "zoom: the node shown is located")
check(#WoW.sounds == sounds10, "...silently, as its count was (one baseline)")

--------------------------------------------------------------------------------
-- 11. A gather takes the nearest record of its name only; its spot stays silent all of GONE.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
local recs = NR.Locate.Records()
local near1 = { name = "Silverleaf", north = WoW.pos[1] + 3, west = WoW.pos[2], at = WoW.now, misses = 0 }
local near2 = { name = "Silverleaf", north = WoW.pos[1] + 20, west = WoW.pos[2], at = WoW.now, misses = 0 }
table.insert(recs, near1)
table.insert(recs, near2)
NR.Locate.Gathered("Silverleaf", WoW.now)
check(not has(NR.Locate.Records(), near1) and has(NR.Locate.Records(), near2), "a gather takes the nearest record, not its neighbour")

--------------------------------------------------------------------------------
-- 12. Sharing: a change the throttle turned away is sent at the next allowed moment.
--------------------------------------------------------------------------------

NR = fresh({ moveScan = true, moveScanAsked = true, shareNodes = true })
WoW.itemCached[765] = true
WoW.units.player = { name = "Drakuza", realm = "Memphisto", full = "Drakuza Memphisto" }
WoW.units.party1 = { name = "Kalizo", realm = "Mistwalker", full = "Kalizo Mistwalker" }
WoW.group = true
WoW.fire("GROUP_ROSTER_UPDATE")
WoW.blips = { { "Silverleaf", 3, -3 } }                 -- by the player: the gather takes it
bursts(12, function() return #NR.Locate.Records() > 0 end)
bursts(1)
local sent0 = #WoW.sent
NR.Locate.Gathered("Silverleaf", WoW.now)
NR.Located(select(2, NR.Locate.Take()), WoW.now)    -- the withdrawal, within the throttle of the last send
NR.Share.Gathered("Silverleaf", WoW.now)
local sent1 = #WoW.sent
WoW.now = WoW.now + 2
WoW.flushTimers(WoW.now)
check(#WoW.sent > sent1, "a throttled withdrawal goes out when the throttle allows (" .. sent0 .. ", " .. sent1 .. ", " .. #WoW.sent .. ")")

--------------------------------------------------------------------------------
-- Round 2 (Codex's review of the corrections).
--------------------------------------------------------------------------------

-- Grouping: two nodes lighting leaves in a row (0, W | 2W, 3W) stay two records; one node's two
-- diagonal leaves make one record at their centre.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -60, 40 } }   -- presence: two in range
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local W = 15
local function leafHit(n, w)
    NR.Locate.Read({ window = { north = n, west = w, size = W, names = { Silverleaf = true }, depth = 6, tries = 0 } },
        { Silverleaf = 1 }, nil, nil, WoW.now)
end
leafHit(1500, 2500); leafHit(1500 + W, 2500); leafHit(1500 + 2 * W, 2500); leafHit(1500 + 3 * W, 2500)
NR.Locate.Take()
check(#NR.Locate.Records() == 2, "four leaves in a row from two nodes: two records, not one chained (" .. #NR.Locate.Records() .. ")")
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
leafHit(1500 + W, 2500); leafHit(1500 + 2 * W, 2500); leafHit(1500, 2500); leafHit(1500 + 3 * W, 2500)
NR.Locate.Take()
check(#NR.Locate.Records() == 2, "...read in another order (W, 2W, 0, 3W): still two, never more than the count (" .. #NR.Locate.Records() .. ")")
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
leafHit(1700, 2700); leafHit(1700 + W, 2700 + W)
NR.Locate.Take()
local one = NR.Locate.Records()[1]
check(#NR.Locate.Records() == 1 and math.abs(one.north - (1700 + W / 2)) < 0.01, "one node's diagonal leaves: one record at their centre")

-- An exhausted re-check of a due, old record isn't queued again for RECHECK, and Next doesn't
-- hand it out.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
rec = NR.Locate.Records()[1]
rec.due, rec.at = true, WoW.now - 100
NR.Locate.Unread({ window = { north = rec.north, west = rec.west, size = 16, names = { Silverleaf = true }, record = rec, tries = 1 } })
local handed = false
for _ = 1, 2 do
    local q = NR.Locate.Next(WoW.pos[1], WoW.pos[2], 150, 1.2)
    if q and q.window.record == rec then handed = true end
end
check(not handed, "an exhausted re-check of a due record isn't handed out again before RECHECK")

-- BACKOFF: a successful search doesn't hold the next; a node arriving later is searched at once.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
check(bursts(20, function() return not NR.Locate.Busy() end) and #NR.Locate.Records() == 1, "(control) the first search done, resolved")
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 30 } }
bursts(2)
check(NR.Locate.Busy() or #NR.Locate.Records() == 2, "after a successful search, a second node's search starts at once")

-- A cancelled burst's pending leaves don't become records later.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
for _ = 1, 800 do frames(1); if NR.MoveScan._test.burst() then break end end
leafHit(1900, 2900)
WoW.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
NR.Locate.Take()
check(#NR.Locate.Records() == 0, "a burst stopped mid-way: its pending leaf is discarded")

-- A quiet allowance doesn't outlive its name leaving range.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(2)
check(((NR.Locate._test.quiet() or {}).Silverleaf or 0) > 0, "(control) an unspent quiet allowance for the first look")
WoW.blips = {}
bursts(2)
check(((NR.Locate._test.quiet() or {}).Silverleaf or 0) == 0, "the name gone from range: its allowance gone too")

-- Tokens keep their own age: a later rise doesn't renew an older token.
NR = fresh()
A = NR.Alert
A.Reset("test")
A.Counts({ Silverleaf = 1 }, 100, nil, nil, math.huge)
A.Counts({ Silverleaf = 2 }, 101, nil, nil, math.huge, 0)         -- token at 101
A.Counts({ Silverleaf = 3 }, 151, nil, nil, math.huge, 0)         -- token at 151
A.Located({ name = "Silverleaf", kind = "herbs", north = WoW.pos[1] + 30, west = WoW.pos[2] }, 170)
sounds = #WoW.sounds
A.Located({ name = "Silverleaf", kind = "herbs", north = WoW.pos[1] - 30, west = WoW.pos[2] }, 180)
check(#WoW.sounds == sounds + 1, "the 101 token expired at 161, the later rise didn't renew it: located at 180, it alerts")

-- A gathered spot stays silent all of GONE, rediscovered twice.
NR = fresh()
NR.db.cooldown = 0                                                  -- no cooldown hiding a sound
WoW.blips = { { "Silverleaf", 2, -2 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
NR.Locate.Gathered("Silverleaf", WoW.now)                          -- one gather
NR.Located(select(2, NR.Locate.Take()), WoW.now)
sounds = #WoW.sounds
local found1 = bursts(12, function() return #NR.Locate.Records() > 0 end)
local r1 = NR.Locate.Records()[1]
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end   -- lost again, not gathered
NR.Located(select(2, NR.Locate.Take()), WoW.now)
local found2 = bursts(12, function() return #NR.Locate.Records() > 0 end)
check(found1 and found2 and r1 and not r1.quiet and #WoW.sounds == sounds,
    "a gathered spot found again twice within GONE after one gather: silent each time")

--------------------------------------------------------------------------------
-- Round 3.
--------------------------------------------------------------------------------

-- A Stop during the settle frame discards the burst's pending leaves too.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local inSettle = false
for _ = 1, 800 do
    frames(1)
    local b = NR.MoveScan._test.burst()
    if b and b.phase == "settle" then inSettle = true; break end
end
leafHit(1900, 2900)
WoW.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
NR.Locate.Take()
check(inSettle and #NR.Locate.Records() == 0, "a Stop in the settle frame: its pending leaf discarded")

-- 3, 2, 3 within BACKOFF (one located): the rise is new demand, searched at once.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
local phantom = 2
undo = override(function(w)
    if isPresence(w) then
        local lines = { { leftText = "Elegia", type = 0 }, { leftText = "Silverleaf", type = 0 } }
        for _ = 1, phantom do lines[#lines + 1] = { leftText = "Silverleaf", type = 0 } end
        return { type = 21, lines = lines }
    end
    return "model"
end)
bursts(12, function() return #NR.Locate.Records() > 0 end)
local exhausted = bursts(20, function() return not NR.Locate.Busy() end)   -- ran out at 3, one located
local t0 = WoW.now
bursts(1)                                                            -- the end noticed: BACKOFF
check(exhausted and #NR.Locate.Records() == 1 and not NR.Locate.Busy(), "(control) unresolved at 3, one located, in BACKOFF")
phantom = 1
bursts(1)                                                            -- 2
check(not NR.Locate.Busy(), "(control) the fall to 2 starts nothing")
phantom = 2
bursts(1)                                                            -- 3 again: a rise
undo()
check(WoW.now - t0 < NR.Locate.BACKOFF and NR.Locate.Busy(), "3, 2, 3 within BACKOFF: the rise searched at once")

-- Retirement takes live tokens, not expired ones: a fall at 165 with tokens from 101 (expired)
-- and 151 empties the debt; a replacement located at 170 alerts. Likewise a gather.
for _, how in ipairs({ "fall", "gather" }) do
    NR = fresh()
    A = NR.Alert
    A.Reset("test")
    A.Counts({ Silverleaf = 1 }, 100, nil, nil, math.huge)
    A.Counts({ Silverleaf = 2 }, 101, nil, nil, math.huge, 0)
    A.Counts({ Silverleaf = 3 }, 151, nil, nil, math.huge, 0)
    if how == "fall" then A.Counts({ Silverleaf = 2 }, 165, nil, nil, math.huge, 0) else A.Gathered("Silverleaf", 165) end
    sounds = #WoW.sounds
    A.Located({ name = "Silverleaf", kind = "herbs", north = WoW.pos[1] + 30, west = WoW.pos[2] }, 170)
    check(#WoW.sounds == sounds + 1, "a " .. how .. " after the oldest token expired retires the live one: located, it alerts")
end

--------------------------------------------------------------------------------
-- Rounds 4-6: identity errors in a cluster of one name settle by a rebuild, through real
-- bursts: the name's records become priors (still drawn, not counted), a fresh search finds
-- every node again, a node found where a prior was keeps that record, the priors not found
-- again go once the count is met. No live node is lost, none starved.
--------------------------------------------------------------------------------

local function spot(dx, dy) return WoW.pos[1] + dy * YARDS, WoW.pos[2] - dx * YARDS end
local function rec(n, w, ago) return { name = "Silverleaf", north = n, west = w, at = WoW.now - (ago or 5), misses = 0 } end
local function near(n, w, within)
    local list = {}
    for _, r in ipairs(NR.Locate.Records()) do
        if not r.prior and math.abs(r.north - n) <= within and math.abs(r.west - w) <= within then list[#list + 1] = r end
    end
    return list
end
local function settled()
    for _, r in ipairs(NR.Locate.Records()) do if r.prior then return false end end
    return not NR.Locate.Busy()
end

-- Round 4: stale A beside live B; C distant and not yet read; presence two, records two.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -60, 40 } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local bn, bw = spot(20, -15)
local cn, cw = spot(-60, 40)
local A4 = rec(bn + 14, bw, 9)                                     -- stale, 14 yards from B
local B4 = rec(bn, bw, 5)
A4.due = true
table.insert(NR.Locate.Records(), A4)
table.insert(NR.Locate.Records(), B4)
bursts(40, function() return #near(cn, cw, 16) == 1 and settled() end)
check(#near(cn, cw, 16) == 1, "round 4: distant C gets its record")
check(not has(NR.Locate.Records(), A4), "...stale A gone")
check(has(NR.Locate.Records(), B4) and #NR.Locate.Records() == 2, "...live B kept, its own record (found again where it was)")

-- Rounds 5 and 6: live A and X 25 yards apart (A isolated from B), B recorded twice (B and a
-- duplicate B' 18.75 yards off), C new; presence four.
NR = fresh()
WoW.blips = { { "Silverleaf", 60, -50 }, { "Silverleaf", 60, -33.5 }, { "Silverleaf", 0, 0 }, { "Silverleaf", -50, 55 } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local an, aw = spot(60, -50)
local xn, xw = spot(60, -33.5)
local b5n, b5w = spot(0, 0)
local c5n, c5w = spot(-50, 55)
local A5, X5 = rec(an, aw, 10), rec(xn, xw, 8)
local B5, B5d = rec(b5n, b5w, 5), rec(b5n + 18.75, b5w, 6)
B5.due = true
for _, r in ipairs({ A5, X5, B5, B5d }) do table.insert(NR.Locate.Records(), r) end
bursts(80, function() return #near(c5n, c5w, 16) == 1 and settled() end)
check(#near(c5n, c5w, 16) == 1, "rounds 5-6: new C gets its record")
check(#near(an, aw, 10) == 1 and #near(xn, xw, 10) == 1, "...live A and X both kept (" .. #near(an, aw, 10) .. ", " .. #near(xn, xw, 10) .. ")")
check(#near(b5n + 9, b5w, 20) == 1, "...B once, its duplicate gone")
check(#NR.Locate.Records() == 4 and settled(), "...four records for four nodes, no prior left")
local rebuilds = 0
for _, l in ipairs(NR.trace) do if l:find("rebuilt", 1, true) then rebuilds = rebuilds + 1 end end
check(rebuilds <= 1, "...without rebuilding over and over (" .. rebuilds .. ")")

-- A near-duplicate (4 yards from the real record): its re-check is ambiguous even at the
-- smallest window: a rebuild; the real node keeps its record, the duplicate goes.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local dn, dw = spot(20, -15)
local R1, D1 = rec(dn, dw, 5), rec(dn + 4, dw, 6)
D1.due = true
table.insert(NR.Locate.Records(), R1)
table.insert(NR.Locate.Records(), D1)
local sounds6 = #WoW.sounds
bursts(40, function() return #NR.Locate.Records() == 1 and settled() end)
check(has(NR.Locate.Records(), R1) and not has(NR.Locate.Records(), D1) and #NR.Locate.Records() == 1,
    "a near-duplicate: rebuilt, the real record kept (found again where it was), the duplicate gone")
check(#WoW.sounds == sounds6, "...silently")

-- A group beyond the count (one record wrong, far from any node): rebuilt, every node placed,
-- the wrong record gone, the right one kept.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -60, 40 }, { "Silverleaf", 50, 50 } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local a7n, a7w = spot(20, -15)
local A7, W7 = rec(a7n, a7w, 5), rec(WoW.pos[1] - 120, WoW.pos[2] + 10, 3)
table.insert(NR.Locate.Records(), A7)
table.insert(NR.Locate.Records(), W7)
local b7n, b7w = spot(-60, 40)
local c7n, c7w = spot(50, 50)
bursts(80, function() return #near(b7n, b7w, 16) == 1 and #near(c7n, c7w, 16) == 1 and settled() end)
check(#near(b7n, b7w, 16) == 1 and #near(c7n, c7w, 16) == 1 and has(NR.Locate.Records(), A7)
    and not has(NR.Locate.Records(), W7) and #NR.Locate.Records() == 3,
    "a wrong record and a group beyond the count: all three nodes placed, A kept, the wrong one gone")

-- A near-duplicate filling the count while another node waits unrecorded (count 2: A and C;
-- records A and A'): only a rebuild can tell, its re-checks being ambiguous at any size.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -60, 40 } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local a8n, a8w = spot(20, -15)
local c8n, c8w = spot(-60, 40)
local A8, A8d = rec(a8n, a8w, 5), rec(a8n + 4, a8w, 6)
A8d.due = true
table.insert(NR.Locate.Records(), A8)
table.insert(NR.Locate.Records(), A8d)
bursts(60, function() return #near(c8n, c8w, 16) == 1 and settled() end)
check(#near(c8n, c8w, 16) == 1 and has(NR.Locate.Records(), A8) and not has(NR.Locate.Records(), A8d),
    "a near-duplicate filling the count: rebuilt, the waiting node found, the duplicate gone")

-- Round 7: records whose estimates are 7 yards off their live nodes (within a leaf's reach),
-- 14 yards apart: their narrower cluster re-checks miss the nodes, which proves nothing: the
-- records keep their identity and nothing sounds, through several re-check cycles.
NR = fresh()
NR.db.cooldown = 0
WoW.blips = { { "Silverleaf", 30, -7 / YARDS }, { "Silverleaf", 30, 21 / YARDS } }
bursts(2)
for i = #NR.Locate.Records(), 1, -1 do table.remove(NR.Locate.Records(), i) end
local pn9, pw9 = spot(30, 0)
local E1, E2 = rec(pn9, pw9, 5), rec(pn9 + 14, pw9, 5)
E1.err, E2.err = 9.375 * NR.Locate.REACH, 9.375 * NR.Locate.REACH
table.insert(NR.Locate.Records(), E1)
table.insert(NR.Locate.Records(), E2)
local sounds9 = #WoW.sounds
local cyclesOK = true
for cycle = 1, 4 do
    for _, r in ipairs(NR.Locate.Records()) do r.due = true end
    WoW.now = WoW.now + NR.Locate.RECHECK
    local w0 = NR.MoveScan.stats.windows
    -- An actual re-check this cycle (a window read), then settled.
    local ran = bursts(20, function() return NR.MoveScan.stats.windows > w0 and settled() end)
    if not (ran and has(NR.Locate.Records(), E1) and has(NR.Locate.Records(), E2)) then cyclesOK = false end
end
check(cyclesOK, "four re-check cycles each ran, the original records E1 and E2 kept through each")
local n1 = #near(pn9 - 7, pw9, 13)
local n2 = #near(pn9 + 21, pw9, 13)
check(#NR.Locate.Records() == 2 and n1 == 1 and n2 == 1, "two live nodes with approximate records: both kept (" .. n1 .. ", " .. n2 .. ")")
check(#WoW.sounds == sounds9, "...and nothing sounds")

-- A rebuild never fires twice within BACKOFF of a name.
NR = fresh()
check(NR.Locate._test.rebuild("Silverleaf", 100) and not NR.Locate._test.rebuild("Silverleaf", 110)
    and NR.Locate._test.rebuild("Silverleaf", 100 + NR.Locate.BACKOFF), "one rebuild a BACKOFF per name")

-- The search's states in the trace (#91: one-window bursts in game, the cause unlogged).
local function traced(pat)
    for _, l in ipairs(NodeRadar.trace) do if l:find(pat) then return true end end
    return false
end
NR = fresh()
local undo2 = override(function(w) if isPresence(w) then return "model" end return { type = 21, lines = {} } end)
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(30, function() return traced("search ran out") end)
bursts(2)
undo2()
check(traced("locate: Silverleaf search starts %(1 in range, 0 recorded%)"), "trace: a search starts")
check(traced("locate: Silverleaf search ran out with 0 of 1 found: again in 20 s"), "trace: a search runs out")
check(traced("locate: Silverleaf waits its backoff %(%d+ s left%)"), "trace: its backoff")
NR.Locate.Unread({ window = { size = 15, tries = 0 } })
check(traced("locate: a 15 yd window placed but not read %(try 1 of 2%)"), "trace: a window placed but not read")
check(traced("; queued %d+ search, %d+ re%-check"), "trace: the burst line's queue")

done("test_locate2")
