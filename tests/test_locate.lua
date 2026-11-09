-- #91, step 2: where the scan's nodes are (Locate.lua). From 70862 a burst follows its
-- presence read with locate windows: the map's quarters, each positive one split in four,
-- down to Locate.FINE yards. The stubs' move model (WoW.moveModel): a node's hit square is
-- 16 screen px around where the moved map draws it, its offset in a 198-unit map's units,
-- the view radius 150 yards, so one base unit is 150 / 99 yards.

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
    WoW.pos = { 1000, 2000, 0, 0 }                 -- north, west, (height), instance
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

-- Bursts until `done()` or `limit` of them, each to its end.
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
-- A blip's world spot (north, west), from its base offset (east dx, north dy).
local function spot(dx, dy) return WoW.pos[1] + dy * YARDS, WoW.pos[2] - dx * YARDS end

local function recordNear(name, n, w, within)
    for _, r in ipairs(NodeRadar.Locate.Records()) do
        if r.name == name and math.sqrt((r.north - n) ^ 2 + (r.west - w) ^ 2) <= within then return r end
    end
end

--------------------------------------------------------------------------------
-- 1. A node in range is located within a few bursts, to about Locate.FINE yards.
--------------------------------------------------------------------------------

local NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
local n1, w1 = spot(20, -15)
check(bursts(12, function() return recordNear("Silverleaf", n1, w1, 12) ~= nil end),
    "a node in range is located (within 12 yards) in a few bursts")
check(NR.MoveScan.stats.windows > 0, "...by locate windows after the presence read")
check(WoW.now < 8, "...within a couple of seconds of the first look (bursts 0.3 s apart while locating)")
check(#NR.Locate.Records() == 1, "...one record for one node")
local homeW = Minimap:GetWidth()
check(homeW == 198 and Minimap:GetAlpha() == 1, "the map is home between bursts")

-- Many new nodes: at most LOCATE_RUN quick bursts in a row, then the usual cadence (the owner:
-- three new nodes blinked a long while).
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 30 }, { "Silverleaf", 50, 50 },
              { "Silverleaf", -60, -40 }, { "Silverleaf", 70, -10 } }
local starts, inBurst, t0 = {}, false, nil
for _ = 1, 600 do
    frames(1)
    local b = NR.MoveScan._test.burst() ~= nil
    if b and not inBurst then starts[#starts + 1] = WoW.now end
    inBurst = b
end
local quick, maxRun = 0, 0
for i = 2, #starts do
    if starts[i] - starts[i - 1] < 1 then quick = quick + 1 else quick = 0 end
    if quick > maxRun then maxRun = quick end
end
check(maxRun >= 3 and maxRun <= 8,
    "quick locate bursts come in runs of at most LOCATE_RUN (" .. maxRun .. ")")

--------------------------------------------------------------------------------
-- 2. The consumers: the icons draw it, the compass points at it.
--------------------------------------------------------------------------------

NR = fresh({ moveScan = true, moveScanAsked = true, icons = true, compass = true })
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
frames(2)
check(#NR.Icons.Records() == 1 and NR.Icons.Records()[1].frame ~= nil, "the icons draw the located node")
check(NR.Compass.Chosen() ~= nil and NR.Compass.Chosen().name == "Silverleaf", "the compass chooses it")
WoW.now = WoW.now + 30
NR.Compass.Refresh()
bursts(1)                                          -- the burst that's due by now, to its end
frames(2)
check(NR.Compass.Chosen() ~= nil, "...still 30 s later without a burst (records live on evidence, not the sweep's interval)")
check(NR.Icons.Records()[1].frame:IsShown(), "...and the icon still drawn")

--------------------------------------------------------------------------------
-- 3. One node replaced by another between two reads (the count stays 1): the new one is
-- located at a new spot and alerts (the owner's run: no sound by counts alone).
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
local sounds = #WoW.sounds
WoW.blips = { { "Silverleaf", -40, 30 } }
local n2, w2 = spot(-40, 30)
check(bursts(20, function() return recordNear("Silverleaf", n2, w2, 12) ~= nil end), "the replacement is located")
check(recordNear("Silverleaf", n1, w1, 12) == nil, "...the old one's record dropped (a re-check at its spot)")
check(#WoW.sounds == sounds + 1, "...and it alerts: a node at a new spot")
SlashCmdList.NODERADAR("scan log")
check(chatHas("FIRED Silverleaf %(located at a new spot%)"), "...said in the log")

--------------------------------------------------------------------------------
-- 4. The first look after a reset: what's there is located silently; a count's rise is
-- announced once (the sound), its location only ripples.
--------------------------------------------------------------------------------

NR = fresh()
SlashCmdList.NODERADAR("scan")
SlashCmdList.NODERADAR("scan")                    -- off and on: a reset, the next read a baseline
WoW.blips = { { "Silverleaf", 20, -15 } }
sounds = #WoW.sounds
bursts(12, function() return #NR.Locate.Records() > 0 end)
check(#WoW.sounds == sounds, "there at the first look after turning the scan on: located silently")
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 30 } }
sounds = #WoW.sounds
bursts(20, function() return #NR.Locate.Records() >= 2 end)
check(#NR.Locate.Records() == 2, "a second node located")
check(#WoW.sounds == sounds + 1, "...one sound for it (the count's rise), not a second at its location")

--------------------------------------------------------------------------------
-- 5. A node mined, still there (a vein gives several): found again at its spot, silently.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 2, -2 } }            -- by the player
bursts(12, function() return #NR.Locate.Records() > 0 end)
NR.Locate.Gathered("Silverleaf", WoW.now)
NR.Located(select(2, NR.Locate.Take()), WoW.now)
check(#NR.Locate.Records() == 0, "a gather drops the record by the player")
sounds = #WoW.sounds
bursts(12, function() return #NR.Locate.Records() > 0 end)
check(#NR.Locate.Records() == 1 and #WoW.sounds == sounds, "still there: found again at its spot, no sound")

-- A vein mined by someone else: its re-check at its spot answers with no lines (nothing
-- there), and the record goes at once (in game such answers were kept as ghosts).
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 30 } }
bursts(30, function() return #NR.Locate.Records() >= 2 end)
local minedBy = recordNear("Silverleaf", n1, w1, 16)
WoW.blips = { { "Silverleaf", -40, 30 } }
NR.Locate.OVERDUE = 99                               -- the re-check alone must settle it
bursts(6, function()
    for _, r in ipairs(NR.Locate.Records()) do if r == minedBy then return false end end
    return true
end)
local still = false
for _, r in ipairs(NR.Locate.Records()) do if r == minedBy then still = true end end
check(minedBy ~= nil and not still, "a re-check answering with no lines drops the record (no ghost)")
NR.Locate.OVERDUE = 3

-- Fewer in range than recorded (a mined vein whose record sat off its spot): the least
-- recently confirmed one goes at once, the count winning over re-checks that can't read.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 30 } }
bursts(30, function() return #NR.Locate.Records() >= 2 end)
local recs = NR.Locate.Records()
recs[1].at, recs[2].at = WoW.now - 100, WoW.now      -- the first confirmed long ago
local stale = recs[1]
local realFoci = GetMouseFoci
rawset(_G, "GetMouseFoci", function()                      -- every window read invalid (not the top focus)
    if Minimap:GetWidth() > 20 then return { WorldFrame } end
    return realFoci()
end)
WoW.blips = { { "Silverleaf", -40, 30 } }
bursts(4)
rawset(_G, "GetMouseFoci", realFoci)
local kept = false
for _, r in ipairs(NR.Locate.Records()) do if r == stale then kept = true end end
check(#NR.Locate.Records() == 1 and not kept,
    "the count falls to 1, the re-checks can't read: after 3 reads the least recently confirmed goes")

--------------------------------------------------------------------------------
-- 6. A name gone from range: its records go at the next presence read.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
WoW.blips = {}
bursts(2)
check(#NR.Locate.Records() == 0, "no Silverleaf in range: its record goes")

--------------------------------------------------------------------------------
-- 8. Codex's review of PR #102.
--------------------------------------------------------------------------------

-- A record Locate drops takes its icon with it (no ghost frame).
NR = fresh({ moveScan = true, moveScanAsked = true, icons = true })
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 30 } }
bursts(30, function() return #NR.Locate.Records() >= 2 end)
frames(2)
local gone1 = recordNear("Silverleaf", n1, w1, 12)
local ghost = gone1 and gone1.frame
check(ghost and ghost:IsShown(), "(control) both icons drawn")
WoW.blips = { { "Silverleaf", -40, 30 } }            -- the first one gone, the second stays
bursts(8, function() return #NR.Locate.Records() == 1 end)
frames(2)
check(#NR.Locate.Records() == 1 and not ghost:IsShown(), "the dropped record's icon is hidden, not left behind")

-- Ridden out of range while another of its name came in (the count stays 1): the old record
-- goes, the new one is searched for, located and alerts.
NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
local old = NR.Locate.Records()[1]
WoW.pos = { WoW.pos[1] + 300, WoW.pos[2], 0, 0 }   -- 300 yards north: the old one out of range
WoW.blips = { { "Silverleaf", -40, 30 } }
local n3, w3 = spot(-40, 30)
sounds = #WoW.sounds
check(bursts(20, function() return recordNear("Silverleaf", n3, w3, 12) ~= nil end), "the one in range now is located")
local stillOld = false
for _, r in ipairs(NR.Locate.Records()) do if r == old then stillOld = true end end
check(not stillOld, "...the one out of range dropped")
check(#WoW.sounds == sounds + 1, "...and the new one alerts")

-- The consumers run after every burst that read, the set unchanged: sharing's heartbeat, the
-- compass's choice as the player moves.
NR = fresh({ moveScan = true, moveScanAsked = true, compass = true })
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 30 } }
bursts(30, function() return #NR.Locate.Records() >= 2 end)
local nA, wA = spot(20, -15)
local nB, wB = spot(-40, 30)
check(NR.Compass.Chosen() and recordNear("Silverleaf", nA, wA, 12) == NR.Compass.Chosen(), "(control) the nearer, A, chosen")
local sends, realSend = 0, NR.Share.Send
NR.Share.Send = function(...) sends = sends + 1; return realSend(...) end
WoW.pos = { nB, wB, 0, 0 }                          -- the player walks to B
local function offset(n, w) return -(w - WoW.pos[2]) / YARDS, (n - WoW.pos[1]) / YARDS end
local ax, ay = offset(nA, wA)
WoW.blips = { { "Silverleaf", ax, ay }, { "Silverleaf", 0, 0 } }
bursts(2)
NR.Share.Send = realSend
check(sends >= 2, "Share.Send after each burst, the record set unchanged")
check(NR.Compass.Chosen() and recordNear("Silverleaf", nB, wB, 12) == NR.Compass.Chosen(), "...and the compass now chooses B")

-- A node by the rim, the player standing still: its record keeps its identity across several
-- presence reads and re-checks, and nothing alerts again (Codex, PR #102: its approximate
-- spot just outside the radius dropped it and found it again).
NR = fresh()
WoW.blips = { { "Silverleaf", 94, 22 } }            -- 96.5 base units: 146 yards of the 150
bursts(20, function() return #NR.Locate.Records() > 0 end)
local rim = NR.Locate.Records()[1]
-- Its approximate spot just outside the radius (a leaf's centre past the rim): 156 yards.
if rim then rim.north, rim.west = WoW.pos[1] + 6, WoW.pos[2] - 156 end
sounds = #WoW.sounds
for _ = 1, 4 do
    WoW.now = WoW.now + NR.Locate.RECHECK
    bursts(2)
end
check(rim ~= nil and NR.Locate.Records()[1] == rim and #NR.Locate.Records() == 1, "a node by the rim keeps its record")
check(#WoW.sounds == sounds, "...and doesn't alert again")

-- A rotating minimap: nothing is located (screen up isn't north), the presence alert stays.
NR = fresh()
WoW.cvars.rotateMinimap = "1"
WoW.blips = { { "Silverleaf", 20, -15 } }
sounds = #WoW.sounds
bursts(8)
check(#NR.Locate.Records() == 0 and NR.MoveScan.stats.windows == 0, "a rotating minimap: no locate window, no record")
check(#WoW.sounds == sounds + 1, "...the presence alert still sounds")
WoW.cvars.rotateMinimap = "0"

-- A node the player doesn't want (skipped, beyond the skill): its rise is silent and its
-- location doesn't ripple.
NR = fresh()
NR.Alert.Wanted = function() return false end
local sonars, realSonar = 0, NR.Alert.Sonar
NR.Alert.Sonar = function(...) sonars = sonars + 1; return realSonar(...) end
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(12, function() return #NR.Locate.Records() > 0 end)
check(#NR.Locate.Records() == 1 and sonars == 0, "an unwanted node is located without a sonar")

--------------------------------------------------------------------------------
-- 9. The quest areas (the owner's screenshots: their outline across the screen at a locate
-- window's size): their tracking off during each borrow, back on after, back at login if a
-- scan was cut short; our own toggle doesn't stop the burst.
--------------------------------------------------------------------------------

NR = fresh()
local quest = { name = "Quest areas", filterID = 65536, active = true }
table.insert(WoW.tracking, quest)
WoW.blips = { { "Silverleaf", 20, -15 } }
local offDuring, stopped = false, false
for _ = 1, 400 do
    frames(1)
    local b = NR.MoveScan._test.burst()
    if b then
        if not quest.active then offDuring = true end
        if b.reason and b.reason ~= "done" then stopped = true end
    end
    if NR.MoveScan.stats.windows > 0 and not b then break end
end
check(offDuring, "the quest areas' tracking is off during a burst")
check(quest.active == true and NR.db.questOff == nil, "...and back on after it, nothing owed")
check(not stopped, "...our own toggle doesn't stop the burst")
check(NR.MoveScan.stats.windows > 0, "...which went on to its locate windows")
-- A scan cut short (the game closed mid-burst): back on at the next login.
NR = fresh({ moveScan = true, moveScanAsked = true, questOff = true })
quest = { name = "Quest areas", filterID = 65536, active = false }
table.insert(WoW.tracking, quest)
WoW.fire("PLAYER_LOGIN")
check(quest.active == true and NR.db.questOff == nil, "a cut-short scan's quest areas are back on at login")
-- Off before (by the player, or never on): left alone.
NR = fresh()
quest = { name = "Quest areas", filterID = 65536, active = false }
table.insert(WoW.tracking, quest)
WoW.blips = { { "Silverleaf", 20, -15 } }
bursts(3)
check(quest.active == false and NR.db.questOff == nil, "quest areas already off: left off, nothing owed")

--------------------------------------------------------------------------------
-- 7. The trace saved at logout (or a reload) while the scan is on, the session before kept.
--------------------------------------------------------------------------------

WoW.fire("PLAYER_LOGOUT")
local log = NR.db.scanLog
check(log and #log.lines > 0 and log.build == 70862 and log.stats.bursts > 0, "the scan's trace is saved at logout")
WoW.fire("PLAYER_LOGOUT")
check(NR.db.scanLogPrevious == log, "...the previous session's kept")

done("test_locate")
