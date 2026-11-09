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
WoW.blips = { { "Silverleaf", 20, -15 } }
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
bursts(20, function() return not NR.Locate.Busy() end)
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
check((NR.Locate._test.quiet() or {}).Silverleaf ~= nil, "(control) a quiet allowance for the first look")
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
WoW.blips = { { "Silverleaf", 2, -2 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
NR.Locate.Gathered("Silverleaf", WoW.now)
NR.Located(select(2, NR.Locate.Take()), WoW.now)
sounds = #WoW.sounds
bursts(12, function() return #NR.Locate.Records() > 0 end)
NR.Locate.Gathered("Silverleaf", WoW.now - 1)                      -- mined again, still there
local g = NR.Locate._test.gone()
for _, e in ipairs(g) do e.at = WoW.now - 30 end                   -- both within GONE
NR.Located(select(2, NR.Locate.Take()), WoW.now)
bursts(12, function() return #NR.Locate.Records() > 0 end)
check(#WoW.sounds == sounds, "a gathered spot found again twice within GONE: silent each time")

done("test_locate2")
