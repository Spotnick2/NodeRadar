-- #91: the minimap scan. From client build 70862, with the scan on, NodeRadar moves
-- Minimap under the resting cursor for a few frames, invisible, reads what lies there and
-- puts it back (docs/PLAN.md, "The minimap scan mode"). The stubs' move model
-- (WoW.moveModel): the mouseover follows the real cursor only, a node's hit square is 16
-- screen px, the frame after a resize reads nothing, a read before UpdateBlips is stale.

local HOME
local function home()
    return { p = { Minimap:GetPoint(1) }, n = Minimap:GetNumPoints(), w = Minimap:GetWidth(), h = Minimap:GetHeight(),
             alpha = Minimap:GetAlpha(), click = Minimap:IsMouseClickEnabled(), wheel = Minimap:IsMouseWheelEnabled(),
             clamp = Minimap:IsClampedToScreen() }
end
local function atHome()
    local h = home()
    return h.n == HOME.n and h.p[1] == HOME.p[1] and h.p[2] == HOME.p[2] and h.p[3] == HOME.p[3] and h.p[4] == HOME.p[4]
        and h.p[5] == HOME.p[5] and h.w == HOME.w and h.h == HOME.h and h.alpha == HOME.alpha and h.click == HOME.click
        and h.wheel == HOME.wheel and h.clamp == HOME.clamp
end

-- A fresh client: the stubs and the addon loaded again (see test_blind.lua for the counts).
local function fresh(db, build)
    dofile("tests/wow_stubs.lua")
    dofile("tests/harness.lua")
    NodeRadar, NodeRadarDB, NodeRadarCharDB = nil, nil, nil
    WoW.build = build or "70862"
    WoW.moveModel = true
    WoW.tracking[1].active = true
    WoW.speed = 0
    WoW.cursor = { 300, 300 }                      -- over the world, away from the minimap
    WoW.blips = {}
    local NR = loadAddon({ db = db or { moveScan = true, moveScanAsked = true } })
    NR.db.learn = false
    NR.MoveScan.PLACEMENTS = 1                     -- step 1's checks: the presence read alone (test_locate: the rest)
    NR.MoveScan.SEARCH_PLACEMENTS = 1              -- a search burst's too (#137; section 13: the longer bursts)
    NR.Alert.HOLD = 0                              -- the sound at the presence read (#137; test_alert: the hold)
    HOME = home()
    return NR
end

-- `n` frames, 20 ms apart (a frame is one WoW.tick).
local function frames(n)
    for _ = 1, n or 1 do
        WoW.now = WoW.now + 0.02
        WoW.tick(0.02)
    end
end

-- Frames until a burst starts (at most `limit`), then the burst's frames.
local function untilBorrowed(limit)
    for _ = 1, limit or 200 do
        frames(1)
        if NodeRadar.MoveScan._test.burst() then return true end
    end
    return false
end
local function runBurst()
    for _ = 1, 10 do
        if not NodeRadar.MoveScan._test.burst() then return end
        frames(1)
    end
end

local observed
local function watch(NR)
    observed = {}
    local real = NR.Observe
    NR.Observe = function(kind, obs, now) observed[#observed + 1] = obs; return real(kind, obs, now) end
end

--------------------------------------------------------------------------------
-- 1. Off by default; before 70862 never; the setting on: a burst after the cursor rests.
--------------------------------------------------------------------------------

local NR = fresh({ moveScanAsked = true })
check(HOME.n == 1 and HOME.w == 198, "(control) the stub's minimap at home")
frames(100)
check(NR.MoveScan.stats.bursts == 0 and atHome(), "off by default: the minimap never moves")

NR = fresh({ moveScan = true, moveScanAsked = true }, "70450")
frames(100)
check(NR.MoveScan.stats.bursts == 0, "before 70862 the scan never runs (the radar reads the minimap itself)")

NR = fresh()
watch(NR)
WoW.blips = { { "Silverleaf", 20, -15 } }
check(untilBorrowed(), "on, on 70862: a burst starts once the cursor rests")
check(Minimap:GetAlpha() == 0 and Minimap:IsMouseClickEnabled() == false and Minimap:IsMouseWheelEnabled() == false,
    "the borrowed map is invisible, clicks and wheel off")
check(Minimap._iconScale == 0.01, "...its dots shrunk (they flash under the cursor otherwise, measured)")
local x, y = Minimap:GetPoint(1)
check(x == "CENTER" and select(2, Minimap:GetPoint(1)) == UIParent, "...and moved off its home")
runBurst()
check(atHome(), "after the burst everything is home: anchors, size, alpha, clicks, wheel, clamp")
check(Minimap._iconScale == 1, "...the icon scale back to 1 (no other addon set one)")
check(NR.MoveScan.stats.valid == 1 and #observed == 1, "one valid read, one observation")
check(observed[1] and observed[1].counts.Silverleaf == 1, "presence: Silverleaf once (the node in range)")
check(observed[1] and observed[1].counts.Elegia == nil, "the player's own line isn't a node")

--------------------------------------------------------------------------------
-- 2. Presence drives the alert: the first read is a silent baseline, a rise alerts.
--------------------------------------------------------------------------------

local sounds = #WoW.sounds
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -30, 25 } }
WoW.now = WoW.now + 10
check(untilBorrowed(400), "the next burst comes")
runBurst()
check(#WoW.sounds == sounds + 1, "a second Silverleaf in range: the sound")
check(observed[#observed].counts.Silverleaf == 2, "...presence counts each node (multiplicity kept)")

-- A long gap between reads (the mouse busy for a minute) keeps the counts: a node that
-- arrived meanwhile still alerts (the owner's run: every read was a silent baseline).
sounds = #WoW.sounds
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -30, 25 }, { "Silverleaf", 40, 40 } }
WoW.now = WoW.now + 60
check(untilBorrowed(400), "a burst a minute later")
runBurst()
check(#WoW.sounds == sounds + 1, "...a third Silverleaf in range: the sound, the gap notwithstanding")
SlashCmdList.NODERADAR("status")
check(chatHas("last read: Silverleaf x3"), "/nr status shows the last read's counts")
SlashCmdList.NODERADAR("scan log")
check(chatHas("scan: read Silverleaf x3") and chatHas("alert: FIRED Silverleaf"), "/nr scan log: the reads and what the alert decided")

-- Riding from one node to the next: a read with none, then the next one in range within a
-- few seconds. The sweep's 20 s blink rule took that for one node at the edge; on the scan
-- it's two scan intervals (the owner's run: no sound at a new vein).
WoW.blips = {}
WoW.now = WoW.now + 10
untilBorrowed(400)
runBurst()
check(observed[#observed].counts.Silverleaf == nil, "(control) none in range")
sounds = #WoW.sounds
WoW.blips = { { "Silverleaf", 20, -15 } }
WoW.now = WoW.now + 13
untilBorrowed(400)
runBurst()
check(#WoW.sounds == sounds + 1, "a node in range 13 s after the last one left: the sound")

-- An empty read (no lines) is read again next frame before it counts as unread.
local empties = 1
local realRead2 = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function()
    if empties > 0 then empties = empties - 1; return { type = 21, lines = {} } end
    return realRead2()
end
local valid0 = NR.MoveScan.stats.valid
WoW.now = WoW.now + 10
untilBorrowed(400)
runBurst()
C_TooltipInfo.GetMinimapMouseover = realRead2
check(NR.MoveScan.stats.valid == valid0 + 1 and atHome(), "an empty read, then a good one the next frame: valid")
empties = 5
C_TooltipInfo.GetMinimapMouseover = function()
    if empties > 0 then empties = empties - 1; return { type = 21, lines = {} } end
    return realRead2()
end
WoW.now = WoW.now + 10
untilBorrowed(400)
runBurst()
C_TooltipInfo.GetMinimapMouseover = realRead2
SlashCmdList.NODERADAR("scan log")
check(chatHas("unread %(no lines%): type 21, frame %+4, 2 rereads, size"), "an empty read's details in /nr scan log")
-- One line a burst (Codex, PR #102): its time, frames, frame rate, end, presence and windows.
check(chatHas("scan: burst %d+ ms, %d+ frames %(slowest %d+ ms%), [%d?]+ fps; the presence read failed; presence not read; 0 windows; next in"),
    "a failed burst's summary line")
check(chatHas("scan: burst %d+ ms, %d+ frames %(slowest %d+ ms%), [%d?]+ fps; done; presence read; 0 windows, then the placement limit; next in"),
    "a good burst's summary line, with why no window followed")

-- The first look after entering the world (in game it ran over budget on a loading frame at
-- every reload, then waited 6 s): one that doesn't read is tried again after FIRST_RETRY, at
-- most FIRST_TRIES times; a good one ends it, and the cadence is the usual one again.
do
    local NR2 = fresh()
    WoW.fire("PLAYER_ENTERING_WORLD")
    local fails = 99
    local real = C_TooltipInfo.GetMinimapMouseover
    -- An unread first look (nothing returned: the reload's loading frame). Empty reads in a row
    -- wait for the mouse instead (#125, below).
    C_TooltipInfo.GetMinimapMouseover = function()
        if fails > 0 then return nil end
        return real()
    end
    local function nextStart()
        runBurst()
        local t = WoW.now
        untilBorrowed(1000)
        return WoW.now - t
    end
    untilBorrowed(400)
    local gaps = {}
    for i = 1, 5 do gaps[i] = nextStart() end
    check(gaps[1] < 1.5 and gaps[2] < 1.5 and gaps[3] < 1.5, ("a failed first look: tried again within about a second (%.1f, %.1f, %.1f s)"):format(gaps[1], gaps[2], gaps[3]))
    check(gaps[4] > 5, ("...at most FIRST_TRIES times, then the usual cadence (%.1f s)"):format(gaps[4]))
    WoW.fire("ZONE_CHANGED_NEW_AREA")                  -- a new area owes a first look too
    fails = 0
    local g = nextStart()
    check(g < 1.5, ("a new area: its first look at once (%.1f s)"):format(g))
    check(nextStart() > 5, "...and once it read, the usual cadence")
    C_TooltipInfo.GetMinimapMouseover = real
end
NR = fresh()

-- MINIMAP_UPDATE_TRACKING with nothing changed (sent while mining on 70862) keeps the counts:
-- the next new node still alerts. A real change starts afresh.
WoW.fire("MINIMAP_UPDATE_TRACKING")
sounds = #WoW.sounds
WoW.blips = { { "Silverleaf", 20, -15 }, { "Silverleaf", -40, 10 } }
WoW.now = WoW.now + 10
untilBorrowed(400)
runBurst()
check(#WoW.sounds == sounds + 1, "a tracking update with nothing changed: the next new node still alerts")
WoW.tracking[1].active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.tracking[1].active = true
WoW.fire("MINIMAP_UPDATE_TRACKING")
SlashCmdList.NODERADAR("scan log")
check(chatHas("alert: reset %(tracking changed%)"), "a real tracking change resets the alert")

-- Mining a node, then reaching the next of its name with no read between (1, then 1): the
-- gathered one is counted out at once, so the next alerts (the owner's run).
WoW.blips = { { "Silverleaf", 20, -15 } }
WoW.pos = { 100, 200, 0 }
WoW.now = WoW.now + 30
untilBorrowed(400)
runBurst()
NR.Alert.Gathered("Silverleaf", WoW.now)
-- A vein mined more than once: still there, the player still at it: the same node, silent.
sounds = #WoW.sounds
WoW.now = WoW.now + 30
untilBorrowed(400)
runBurst()
check(#WoW.sounds == sounds, "gathered, still there, the player still at it: no sound (the same node)")
NR.Alert.Gathered("Silverleaf", WoW.now)
WoW.pos = { 160, 200, 0 }                                  -- 60 yards on
sounds = #WoW.sounds
WoW.blips = { { "Silverleaf", -50, 30 } }
WoW.now = WoW.now + 30
untilBorrowed(400)
runBurst()
check(#WoW.sounds == sounds + 1, "a node gathered, the next one of its name read 1 then 1: the sound")

--------------------------------------------------------------------------------
-- 3. Unread is never absence: no observation at all.
--------------------------------------------------------------------------------

local n, unread0 = #observed, NR.MoveScan.stats.unread
WoW.mouseoverThrows = true
WoW.now = WoW.now + 10
check(untilBorrowed(400), "a burst with a failing read")
runBurst()
WoW.mouseoverThrows = false
check(#observed == n and NR.MoveScan.stats.unread == unread0 + 1, "an unread burst observes nothing (not an empty count)")
check(atHome(), "...and still goes home")

--------------------------------------------------------------------------------
-- 4. The read waits for the settle frame after the resize (measured: it reads nothing).
--------------------------------------------------------------------------------

local seen = {}
local realRead = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function()
    seen[#seen + 1] = WoW.frameCount - (Minimap._unsettledUntil or 0)
    return realRead()
end
WoW.now = WoW.now + 10
untilBorrowed(400)
runBurst()
C_TooltipInfo.GetMinimapMouseover = realRead
check(#seen == 1 and seen[1] >= 1, "one read, after the unsettled frame")

--------------------------------------------------------------------------------
-- 5. Admission: each gate refuses.
--------------------------------------------------------------------------------

local function refusedBy(set, unset, why)
    NR = fresh()
    set()
    frames(60)
    local refused = NR.MoveScan.stats.bursts == 0 and atHome()
    local reason = NR.MoveScan.lastRefusal
    unset()
    check(refused, why .. ": no burst")
    return reason
end
refusedBy(function() WoW.combat = true end, function() WoW.combat = false end, "in combat")
refusedBy(function() WoW.mouselook = true end, function() WoW.mouselook = false end, "mouselook")
refusedBy(function() WoW.buttonDown = true end, function() WoW.buttonDown = false end, "a mouse button down")
refusedBy(function() WoW.editMode = true end, function() WoW.editMode = false end, "Edit Mode")
refusedBy(function() WoW.onTaxi = true end, function() WoW.onTaxi = false end, "on a taxi")
refusedBy(function() WoW.instanced = true end, function() WoW.instanced = false end, "in an instance")
refusedBy(function() WoW.tracking[1].active = false end, function() end, "no gathering tracking")
refusedBy(function() Minimap._protected = true end, function() Minimap._protected = false end, "a protected minimap")
refusedBy(function() GameTooltip._shown = true end, function() GameTooltip._shown = false end, "a tooltip shown")
refusedBy(function() WoW.cursor = { (800 + 99) * 1.2, (500 + 99) * 1.2 } end, function() end, "the cursor over the minimap")
local covered = CreateFrame("Frame", nil, UIParent)
covered:SetFrameStrata("DIALOG")
refusedBy(function() WoW.focus = covered end, function() WoW.focus = nil end, "a window under the cursor")
-- #113: the cursor busy, each with its own reason; and a button around the ring.
local function busyBy(set, unset, reason)
    local got = refusedBy(set, unset, reason)
    check(got == reason, reason .. ": the reason says so (got " .. tostring(got) .. ")")
end
busyBy(function() WoW.targeting = true end, function() WoW.targeting = false end, "aiming a spell")
busyBy(function() WoW.cursorInfo = "item" end, function() WoW.cursorInfo = nil end, "something on the cursor")
busyBy(function() WoW.casting = "Herb Gathering" end, function() WoW.casting = nil end, "casting")
busyBy(function() WoW.lootItems = 2 end, function() WoW.lootItems = 0 end, "a loot window is open")
busyBy(function() WoW.units.mouseover = { name = "Kobold" } end, function() WoW.units.mouseover = nil end, "a unit under the mouse")
-- 10 screen px left of the map (its rect from 800 at effective scale 1.2): near; 30 px: not.
busyBy(function() WoW.cursor = { 800 * 1.2 - 10, (500 + 99) * 1.2 } end, function() end, "the cursor is near the minimap")
NR = fresh()
WoW.cursor = { 800 * 1.2 - 30, (500 + 99) * 1.2 }
check(untilBorrowed(), "30 screen px from the minimap's edge: a burst starts (only the margin refuses)")
runBurst()
-- A busy check that throws or is missing is not busy (an older client).
NR = fresh()
local realTargeting = SpellIsTargeting
SpellIsTargeting = function() error("no such thing") end
GetCursorInfo = nil
check(untilBorrowed(), "SpellIsTargeting throwing and GetCursorInfo missing: not busy, a burst starts")
runBurst()
SpellIsTargeting, GetCursorInfo = realTargeting, function() return WoW.cursorInfo end
-- A UI suite's full-screen layer below the minimap doesn't block it.
NR = fresh()
local layer = CreateFrame("Frame", nil, UIParent)
layer:SetFrameStrata("BACKGROUND")
WoW.focus = layer
check(untilBorrowed(), "a frame drawn below the minimap under the cursor: the burst still starts")
runBurst()
WoW.focus = nil
-- The cursor over the 3D world: on the stock UI no focus at all (GetMouseFoci() empty, measured on
-- 70888); with WorldFrame's mouse on, WorldFrame. Both are over the world. (The default stub is the
-- empty list, so every other test here runs on it too.)
NR = fresh()
check(#GetMouseFoci() == 0, "the stub: over the world, no focus")
check(untilBorrowed(), "no focus at all (the stock UI over the world): a burst starts")
runBurst()
NR = fresh()
WoW.worldFocus = true
check(GetMouseFoci()[1] == WorldFrame, "the stub: WorldFrame the focus")
check(untilBorrowed(), "WorldFrame the focus: a burst starts")
runBurst()
WoW.worldFocus = nil
-- GetMouseFoci failing is not "over the world".
local realFoci
local gotFoci = refusedBy(function() realFoci = GetMouseFoci; GetMouseFoci = function() error("no such thing") end end,
    function() GetMouseFoci = realFoci end, "GetMouseFoci throwing")
check(gotFoci == "the cursor is not over the world", "GetMouseFoci throwing: the reason says so (got " .. tostring(gotFoci) .. ")")
-- A click just released: 0.3 s before a burst (a quick second click mustn't meet the map).
NR = fresh()
frames(5)
WoW.buttonDown = true
frames(5)
WoW.buttonDown = false
frames(1)
WoW.cursor = { 304, 300 }                       -- a real nudge (REARM_PX): the hover answers again
frames(11)
check(NR.MoveScan.stats.bursts == 0, "0.24 s after a mouse button came up: no burst yet")
check(untilBorrowed(10), "...from 0.3 s, one comes")
runBurst()
-- The button released and the mouse moved before the next frame, then still: that move counts
-- (Codex, PR #126: the anchor is the last held sample, not the first released one).
NR = fresh()
frames(5)
WoW.buttonDown = true
frames(5)
WoW.buttonDown = false
WoW.cursor = { 304, 300 }                       -- released and moved within the same frame
frames(12)
check(NR.MoveScan.stats.bursts == 0, "released and moved: 0.24 s on, no burst yet")
check(untilBorrowed(30), "...a move made before the first released frame counts: a burst")
runBurst()
-- After a click or mouselook the minimap's hover answers nothing until the mouse moves (in
-- game: empty reads): no burst until it has.
NR = fresh()
frames(5)
WoW.mouselook = true
frames(10)
WoW.mouselook = false
frames(100)
check(NR.MoveScan.stats.bursts == 0, "after mouselook, the mouse not moved: no burst (it would read nothing)")
WoW.cursor = { 301.1, 300 }                     -- #125: jitter (in game 0.4 and 1.1 px passed for moves)
frames(100)
check(NR.MoveScan.stats.bursts == 0, "...1.1 px of jitter is no move: still no burst")
WoW.cursor = { 304, 300 }
check(untilBorrowed(30), "...the mouse nudged and resting: one comes")
runBurst()
-- The cursor's jump as mouselook ends (it reappears where it was) is no move (in game it
-- passed for one, and every read after it came back empty).
NR = fresh()
frames(5)
WoW.mouselook = true
WoW.cursor = { 960, 540 }                       -- where it reads during mouselook
frames(10)
WoW.mouselook = false
WoW.cursor = { 300, 300 }                       -- back where it was
frames(100)
check(NR.MoveScan.stats.bursts == 0, "the cursor's jump as mouselook ends is not a move: no burst")
WoW.cursor = { 304, 300 }
check(untilBorrowed(30), "...a real nudge after it: one comes")
runBurst()
-- The cursor must rest: moving every frame, nothing.
NR = fresh()
for i = 1, 60 do WoW.cursor = { 300 + i * 5, 300 }; frames(1) end
check(NR.MoveScan.stats.bursts == 0, "a moving cursor: no burst")
check(untilBorrowed(30), "...once it rests 0.2 s, one comes")
SlashCmdList.NODERADAR("scan log")
check(chatHas("scan: waited 1 s: the cursor is moving %(%d+ frames%)"), "/nr scan log says what kept it waiting")
runBurst()

--------------------------------------------------------------------------------
-- 6. Mid-burst: a mouse button, combat, the cursor moving: home at once, nothing observed.
--------------------------------------------------------------------------------

local function interruptedBy(act, why)
    NR = fresh()
    watch(NR)
    WoW.blips = { { "Silverleaf", 20, -15 } }
    untilBorrowed()
    frames(1)                                       -- placed
    act()
    if NR.MoveScan._test.burst() then frames(1) end
    runBurst()
    check(atHome() and #observed == 0, why .. " mid-burst: home, nothing observed")
end
interruptedBy(function() WoW.fire("GLOBAL_MOUSE_DOWN", "LeftButton") end, "GLOBAL_MOUSE_DOWN")
interruptedBy(function() WoW.combat = true; WoW.fire("PLAYER_REGEN_DISABLED") end, "combat")
WoW.combat = false
interruptedBy(function() WoW.cursor = { 320, 300 } end, "the cursor moving")
interruptedBy(function() WoW.fireRegistry("EditMode.Enter") end, "Edit Mode")
interruptedBy(function() NR.Set("moveScan", false) end, "the setting turned off")
interruptedBy(function() WoW.targeting = true end, "a spell aimed")
WoW.targeting = false
interruptedBy(function() WoW.cursorInfo = "item" end, "an item picked up")
WoW.cursorInfo = nil

--------------------------------------------------------------------------------
-- 6b. #114: a look at once after a fight, a taxi's end and a dismount, never forced.
--------------------------------------------------------------------------------

-- A burst just ran; the next one isn't due for 6 s (standing still). `event` asks for one now.
local function soonAfter(setup, event, ...)
    NR = fresh()
    check(untilBorrowed(), "(control) a first burst")
    runBurst()
    frames(60)                                      -- 1.2 s on: the 6 s cadence not due
    local before = NR.MoveScan.stats.bursts
    setup()
    WoW.fire(event, ...)
    local came = untilBorrowed(20)                  -- within 0.4 s
    runBurst()
    return came, NR.MoveScan.stats.bursts > before
end
local came = soonAfter(function() end, "PLAYER_REGEN_ENABLED")
check(came, "PLAYER_REGEN_ENABLED: a look at once, not at the 6 s turn")
came = soonAfter(function() end, "PLAYER_CONTROL_GAINED")
check(came, "PLAYER_CONTROL_GAINED (a taxi's end): a look at once")
came = soonAfter(function() WoW.mounted = false end, "PLAYER_MOUNT_DISPLAY_CHANGED")
check(came, "dismounted: a look at once")
came = soonAfter(function() WoW.mounted = true end, "PLAYER_MOUNT_DISPLAY_CHANGED")
WoW.mounted = false
check(not came, "mounting: no extra look (the cadence)")
came = soonAfter(function() frames(1); WoW.combat = false end, "PLAYER_REGEN_ENABLED")
check(came, "(control) the fight's end with combat off")
-- Never forced: refused while the cursor is busy.
came = soonAfter(function() WoW.targeting = true end, "PLAYER_REGEN_ENABLED")
WoW.targeting = false
check(not came, "after a fight but aiming a spell: refused, no look")
-- Off: nothing asked.
NR = fresh({ moveScanAsked = true })
WoW.fire("PLAYER_REGEN_ENABLED")
frames(30)
check(NR.MoveScan.stats.bursts == 0, "the scan off: a fight's end starts nothing")

--------------------------------------------------------------------------------
-- 7. A geometry restore that fails: the map stays invisible and click-off, retried until
-- it works, never shown away from home.
--------------------------------------------------------------------------------

NR = fresh()
untilBorrowed()
frames(1)
Minimap._protected, WoW.combat = true, true           -- the kit refuses SetPoint now
WoW.fire("PLAYER_REGEN_DISABLED")
runBurst()
check(NR.MoveScan.Pending() == "geometry", "a refused geometry restore stays pending")
check(Minimap:GetAlpha() == 0 and Minimap:IsMouseClickEnabled() == false,
    "...the map stays invisible and click-off away from home")
check(chatHas("turned itself off"), "...the scan turns itself off and says so")
frames(200)
check(NR.MoveScan.Pending() == "geometry", "...still pending while refused")
Minimap._protected, WoW.combat = false, false
WoW.fire("PLAYER_REGEN_ENABLED")
check(NR.MoveScan.Pending() == nil and atHome(), "PLAYER_REGEN_ENABLED: retried, everything home")

-- The icon scale's setter failing on the way back: pending, said, retried; never "done"
-- with the dots at 0.01 (Codex, PR #101).
NR = fresh()
local realScale = Minimap.SetIconScale
untilBorrowed()
Minimap.SetIconScale = function(self, v) if v ~= 0.01 then error("refused") end return realScale(self, v) end
runBurst()
check(NR.MoveScan.Pending() == "icon scale" and Minimap._iconScale == 0.01, "a throwing icon-scale restore stays pending")
check(chatHas("dots couldn't be put back"), "...said")
check(Minimap:GetAlpha() == 1 and Minimap:IsMouseClickEnabled() == true, "...while the geometry, visibility and input are home")
Minimap.SetIconScale = realScale
WoW.now = WoW.now + 3
frames(1)
check(NR.MoveScan.Pending() == nil and Minimap._iconScale == 1, "...retried: the dots back to 1")

-- A resize refused (a skin keeps the minimap's size): the read covers only a normal map's
-- centre, so it's unread, never counts (Codex, PR #101).
NR = fresh()
watch(NR)
WoW.blips = { { "Silverleaf", 20, -15 } }
local realSize = Minimap.SetSize
Minimap.SetSize = function(self, w, h) if w < 100 then return end return realSize(self, w, h) end
untilBorrowed()
runBurst()
Minimap.SetSize = realSize
check(#observed == 0 and NR.MoveScan.lastUnread == "not the read's size", "a refused resize: unread, no counts")
check(atHome(), "...and home")

-- Something moving the map between the restore and the settle frame: the readback there
-- catches it and puts it back (Codex, PR #101).
NR = fresh()
untilBorrowed()
for _ = 1, 10 do
    frames(1)
    local b = NR.MoveScan._test.burst()
    if b and b.phase == "settle" then break end
end
check(atHome(), "(control) restored at frame 4")
Minimap:SetSize(120, 120)
frames(1)
check(NR.MoveScan._test.burst() == nil and atHome(), "a change before the settle frame is read back and undone")
check(NR.MoveScan._test.saved() == nil, "...and the snapshot is released only then")
-- The same, with the correction refused: the map goes invisible and click-off again while it
-- waits, never shown and clickable away from home (Codex, PR #101).
NR = fresh()
untilBorrowed()
for _ = 1, 10 do
    frames(1)
    local b = NR.MoveScan._test.burst()
    if b and b.phase == "settle" then break end
end
check(Minimap:GetAlpha() == 1 and Minimap:IsMouseClickEnabled(), "(control) visible and clickable at frame 4")
Minimap:SetSize(120, 120)
local realSize2 = Minimap.SetSize
Minimap.SetSize = function() end
frames(1)
check(NR.MoveScan.Pending() == "geometry", "a refused correction at the settle frame: pending")
check(Minimap:GetAlpha() == 0 and Minimap:IsMouseClickEnabled() == false and Minimap:IsMouseWheelEnabled() == false,
    "...the map invisible, clicks and wheel off while it waits")
Minimap.SetSize = realSize2
WoW.now = WoW.now + 3
frames(1)
check(NR.MoveScan.Pending() == nil and atHome(), "...retried: everything home")

--------------------------------------------------------------------------------
-- 8. Blizzard's tooltip: hidden after its producer during a burst and its settle frame only.
--------------------------------------------------------------------------------

NR = fresh()
WoW.blips = { { "Silverleaf", 20, -15 } }
untilBorrowed()
frames(2)
GameTooltip:SetMinimapMouseover()
check(not GameTooltip:IsShown(), "during a burst the minimap tooltip is hidden right after it's built")
runBurst()
check(not NR.MoveScan.Suppressing(), "...and the suppression ends with the burst")
WoW.hover(20, -15)
WoW.moveModel = false
GameTooltip:SetMinimapMouseover()
check(GameTooltip:IsShown(), "a real hover afterwards shows it as usual")
WoW.moveModel = true
WoW.leaveMap()
GameTooltip:Hide()

--------------------------------------------------------------------------------
-- 9. Blizzard's coordinates and LFG eye: hidden for the borrow, back after.
--------------------------------------------------------------------------------

NR = fresh()
local coordsF, eye = MinimapCluster.MinimapContainer.PlayerCoords, QueueStatusButton
coordsF:SetAlpha(0.9)
untilBorrowed()
check(coordsF:GetAlpha() == 0 and eye:GetAlpha() == 0 and eye:IsMouseEnabled() == false,
    "the coordinates and the LFG eye are invisible during the borrow, the eye's mouse off")
runBurst()
check(coordsF:GetAlpha() == 0.9 and eye:GetAlpha() == 1 and eye:IsMouseEnabled() == true, "...and back after")
-- The eye showing mid-burst (it wasn't at the borrow): the burst ends.
NR = fresh()
watch(NR)
eye = QueueStatusButton
untilBorrowed()
eye:Show()
frames(1)
runBurst()
eye:Hide()
check(#observed == 0 and atHome(), "the LFG eye shown mid-burst ends it")

--------------------------------------------------------------------------------
-- 10. Followers: another addon's frame anchored to the map waits the scan, named once.
--------------------------------------------------------------------------------

NR = fresh()
local ring = CreateFrame("Frame", "SomeSkinRing", UIParent)
ring:SetPoint("CENTER", Minimap, "CENTER")
frames(60)
check(NR.MoveScan.stats.bursts == 0, "a shown frame anchored to the minimap: no burst")
check(chatHas("SomeSkinRing"), "...and chat names it")
ring:Hide()
NR.MoveScan.Apply()                                  -- the search again now
check(untilBorrowed(), "hidden, the scan goes on")
runBurst()
ring:ClearAllPoints()

--------------------------------------------------------------------------------
-- 11. Glass MiniMap: v1 is asked, in pairs; refused three times turns the scan off; an older
-- one means no scan at all.
--------------------------------------------------------------------------------

local function glass(begin)
    local g = { PUBLIC_API_VERSION = 1, begins = 0, ends = 0 }
    g.ScanBegin = function(owner) g.begins = g.begins + 1; g.owner = owner; return begin() end
    g.ScanEnd = function() g.ends = g.ends + 1 end
    rawset(_G, "GlassMiniMap", g)
    WoW.loadedAddons = { GlassMiniMap = true }
    return g
end
NR = fresh()
local g = glass(function() return true end)
untilBorrowed()
runBurst()
check(g.begins == 1 and g.ends == 1 and g.owner == "NodeRadar", "Glass MiniMap v1: one ScanBegin, one ScanEnd")
NR = fresh()
g = glass(function() return true end)
untilBorrowed()
frames(1)
WoW.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
check(g.begins == 1 and g.ends == 1, "...an interrupted burst still ends its scan")
NR = fresh()
g = glass(function() return false end)
frames(1500)
check(NR.MoveScan.stats.bursts == 0 and g.begins == 3 and g.ends == 3, "refused: no borrow, ScanEnd still owed and paid")
check(chatHas("Glass MiniMap refused it 3 times"), "...three refusals turn the scan off, said")
NR = fresh()
g = glass(function() error("boom") end)
frames(40)                                      -- the home holds still 0.5 s first (#116)
check(NR.MoveScan.stats.bursts == 0 and g.ends == g.begins and g.begins >= 1, "a throwing ScanBegin: no borrow, ScanEnd paid")
NR = fresh()
rawset(_G, "GlassMiniMap", {})
WoW.loadedAddons = { GlassMiniMap = true }
frames(60)
check(NR.MoveScan.stats.bursts == 0 and chatHas("needs Glass MiniMap 1.1.0 or later"),
    "Glass MiniMap without version 1: no scan, said once")
rawset(_G, "GlassMiniMap", nil)
WoW.loadedAddons = nil

--------------------------------------------------------------------------------
-- 12. The icon scale another addon set comes back; the cadence.
--------------------------------------------------------------------------------

NR = fresh()
Minimap:SetIconScale(0.8)
untilBorrowed()
runBurst()
check(Minimap._iconScale == 0.8, "an icon scale another addon set is restored")
local t0 = WoW.now
check(untilBorrowed(1000), "(control) the next burst")
check(WoW.now - t0 >= 6 - 0.05, "standing still: a burst every 6 s (2 s x 3)")
runBurst()
WoW.speed = 7
t0 = WoW.now
untilBorrowed(1000)
check(WoW.now - t0 <= 2.1, "moving: every 2 s")
runBurst()
WoW.speed = 0

--------------------------------------------------------------------------------
-- 13. The login prompt, /nr scan, Options.
--------------------------------------------------------------------------------

NR = fresh({})
check(NR.MoveScan._test.askAt() ~= nil, "on 70862, never asked: the prompt is due")
frames(100)
check(NR.MoveScan._test.prompt() == nil, "not before 10 s")
WoW.combat = true
WoW.now = WoW.now + 20
frames(5)
check(NR.MoveScan._test.prompt() == nil, "never in combat")
WoW.combat = false
frames(1)
local p = NR.MoveScan._test.prompt()
check(p and p:IsShown(), "the first quiet moment after 10 s: asked")
p.yes:GetScript("OnClick")(p.yes)
check(NR.db.moveScan == true and NR.db.moveScanAsked == true and not p:IsShown(), "\"Try\": the scan on, asked once")
NR = fresh({ moveScanAsked = true })
check(NR.MoveScan._test.askAt() == nil, "asked before: never again")
NR = fresh({}, "70450")
check(NR.MoveScan._test.askAt() == nil, "before 70862: never asked")

NR = fresh({ moveScanAsked = true })
SlashCmdList.NODERADAR("scan")
check(NR.db.moveScan == true, "/nr scan turns it on")
SlashCmdList.NODERADAR("scan 3")
check(NR.db.scanEvery == 3, "/nr scan 3: every 3 s while moving")
SlashCmdList.NODERADAR("scan")
check(NR.db.moveScan == false, "/nr scan again: off")

--------------------------------------------------------------------------------
-- 14. #116: the home must hold still before a borrow; something that keeps moving the map stops
-- the scan for a while; MS.Trouble says why, lasting reasons only; Options shows it.
--------------------------------------------------------------------------------

-- Another addon's borrow, done to the map from outside: away for a few frames, then home.
local function foreignBorrow()
    local p = { Minimap:GetPoint(1) }
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", -2000, -2000)
    Minimap:SetAlpha(0)
    frames(3)
    Minimap:ClearAllPoints()
    Minimap:SetPoint(p[1], p[2], p[3], p[4], p[5])
    Minimap:SetAlpha(1)
end

NR = fresh()
frames(5)
foreignBorrow()
local okNow = NR.MoveScan.Refusal(GetTime())
check(okNow == "the minimap just moved", "the map just came home from someone else's move: no borrow (" .. tostring(okNow) .. ")")
check(untilBorrowed(), "...once it has held still 0.5 s, a burst")
runBurst()
check(atHome(), "(control) home after it")
-- A skin re-asserting the same anchors changes nothing.
NR = fresh()
frames(30)
for _ = 1, 30 do
    local p = { Minimap:GetPoint(1) }
    Minimap:ClearAllPoints()
    Minimap:SetPoint(p[1], p[2], p[3], p[4], p[5])
    frames(1)
end
check(NR.MoveScan.Trouble(GetTime()) == nil and NR.MoveScan.stats.bursts >= 1,
    "the same anchors set again and again: no trouble, the scan runs")
-- Another scanner loaded with its scan on (a setting it can't read counts as on): ours stands
-- down, and neither the chat line nor the Options line names it (the owner, 2026-11-12).
NR = fresh()
local nRivals = #NR.MoveScan.RIVALS
check(nRivals >= 1, "MS.RIVALS lists the other scanners")
for i = 1, nRivals do
    NR = fresh()
    local r = NR.MoveScan.RIVALS[i].name          -- its folder name: never in a label or a message
    WoW.loadedAddons = { [r] = true }
    local printed, realPrint = {}, print
    print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
    frames(60)
    print = realPrint
    check(NR.MoveScan.stats.bursts == 0 and NR.MoveScan.lastRefusal == "another minimap scanner is on",
        "rival " .. i .. " loaded, its setting unread (counts as on): no burst, refused as another scanner (got "
        .. tostring(NR.MoveScan.lastRefusal) .. ")")
    local key, line, hint = NR.MoveScan.Trouble(GetTime())
    local text = table.concat(printed, " | ") .. " | " .. tostring(line) .. " | " .. tostring(hint)
    check(key == "rival" and #printed >= 1, "rival " .. i .. ": the chat line and the Options line say so")
    check(not text:lower():find(r:lower(), 1, true), "rival " .. i .. ": never named to the player")
    WoW.loadedAddons = nil
end
-- One loaded with its scan off: ours runs.
NR = fresh()
table.insert(NR.MoveScan.RIVALS, { name = "OtherScanner", on = function() return false end })
WoW.loadedAddons = { OtherScanner = true }
check(untilBorrowed(), "another scanner loaded with its scan off: ours runs")
runBurst()
WoW.loadedAddons = nil
-- One whose setting throws: counts as on (stand down when in doubt).
NR = fresh()
table.insert(NR.MoveScan.RIVALS, { name = "OtherScanner", on = function() error("unreadable") end })
WoW.loadedAddons = { OtherScanner = true }
frames(60)
check(NR.MoveScan.stats.bursts == 0 and NR.MoveScan.lastRefusal == "another minimap scanner is on",
    "another scanner whose setting throws: ours stands down")
WoW.loadedAddons = nil
-- Something that keeps moving it: three moves in ten seconds stop the scan for 30 s.
NR = fresh()
check(untilBorrowed(), "(control) the first look")
runBurst()
local b0 = NR.MoveScan.stats.bursts
for _ = 1, 3 do foreignBorrow(); frames(10) end
check(NR.MoveScan.Trouble(GetTime()) == "mover", "three foreign moves in 10 s: Trouble says something keeps moving it")
frames(400)                                     -- past the 6 s cadence: a look is due
check(NR.MoveScan.stats.bursts == b0 and NR.MoveScan.lastRefusal == "something keeps moving the minimap",
    "...no burst meanwhile")
check(chatHas("something else keeps moving the minimap"), "...said once")
WoW.now = WoW.now + 31
check(untilBorrowed(), "...30 s without a move: the scan again")
runBurst()
-- Tripped, a lone move later restarts the quiet (Codex): one move 20 s on holds the scan 30 s more.
NR = fresh()
check(untilBorrowed(), "(control) the first look")
runBurst()
for _ = 1, 3 do foreignBorrow(); frames(10) end
check(NR.MoveScan.Trouble(GetTime()) == "mover", "(control) tripped")
WoW.now = WoW.now + 20
foreignBorrow()
frames(5)
WoW.now = WoW.now + 15                                  -- 35 s after the trip, 15 s after the last move
frames(2)
check(NR.MoveScan.Trouble(GetTime()) == "mover", "a move 20 s after the trip: still held, 15 s on")
WoW.now = WoW.now + 16
frames(2)
check(NR.MoveScan.Trouble(GetTime()) == nil, "...30 s after that last move: free")
-- A getter failing for a frame, again and again, is no move (Codex: nothing committed unread).
NR = fresh()
check(untilBorrowed(), "(control) the first look")
runBurst()
local realW = Minimap.GetWidth
for _ = 1, 4 do
    Minimap.GetWidth = function() return nil end
    frames(2)
    Minimap.GetWidth = realW
    frames(5)
end
check(NR.MoveScan.Trouble(GetTime()) == nil, "the width unreadable for a frame four times: no 'keeps moving'")
check(NR.MoveScan.Refusal(GetTime()) ~= "something keeps moving the minimap", "...and no such refusal")
-- The first readable sample after unreadable ones is the baseline, not a move.
NR = fresh()
realW = Minimap.GetWidth
Minimap.GetWidth = function() return nil end
frames(3)
Minimap.GetWidth = realW
frames(3)                                               -- the first readable sample: the baseline
foreignBorrow(); frames(10)                             -- two changes: below MOVES unless the baseline counted
check(NR.MoveScan.Trouble(GetTime()) == nil, "after unreadable first samples, the first readable one is the baseline, not a move")
foreignBorrow(); frames(10)
check(NR.MoveScan.Trouble(GetTime()) == "mover", "(control) real moves still count")

-- Our own bursts never count as moves.
NR = fresh()
for _ = 1, 5 do
    check(untilBorrowed(400), "(control) a burst of our own")
    runBurst()
end
check(NR.MoveScan.Trouble(GetTime()) == nil, "five of our own bursts: no 'something keeps moving it'")

-- Trouble: the lasting reasons, keyed; the moment-to-moment ones never.
local function troubleBy(set, unset, key)
    NR = fresh()
    set()
    frames(2)
    local got = NR.MoveScan.Trouble(GetTime())
    unset()
    check(got == key, "Trouble: " .. key .. " (got " .. tostring(got) .. ")")
end
troubleBy(function() WoW.tracking[1].active = false end, function() end, "no tracking")
troubleBy(function() Minimap._protected = true end, function() Minimap._protected = false end, "protected")
troubleBy(function() WoW.instanced = true end, function() WoW.instanced = false end, "instance")
troubleBy(function() Minimap:Hide() end, function() Minimap:Show() end, "hidden")
NR = fresh()
WoW.combat, GameTooltip._shown, WoW.targeting = true, true, true
check(NR.MoveScan.Trouble(GetTime()) == nil, "combat, a tooltip, a spell aimed: no trouble (they pass)")
WoW.combat, GameTooltip._shown, WoW.targeting = false, false, false
NR = fresh({ moveScanAsked = true })
WoW.tracking[1].active = false
check(NR.MoveScan.Trouble(GetTime()) == nil, "the scan off: no trouble line")
NR = fresh(nil, "70450")
WoW.tracking[1].active = false
check(NR.MoveScan.Trouble(GetTime()) == nil, "before 70862 (the radar reads itself): no trouble line")

-- Options: the red line under the scan's checkbox, read on show and each second while shown.
NR = fresh()
WoW.tracking[1].active = false
NR.Options.Register()
NR.Options._test.panel:Hide()
NR.Options._test.panel:Show()
check(NR.Options._test.trouble == "no tracking", "Options shows the trouble on show")
WoW.tracking[1].active = true
WoW.fire("MINIMAP_UPDATE_TRACKING")                -- as the client does on a tracking change
for _ = 1, 60 do WoW.tick(0.02) end
check(NR.Options._test.trouble == nil, "...and clears it within a second of the fix, the page open")

-- A loot window, empty ones too: LOOT_OPENED to LOOT_CLOSED.
NR = fresh()
WoW.fire("LOOT_OPENED")
frames(60)
check(NR.MoveScan.stats.bursts == 0 and NR.MoveScan.lastRefusal == "a loot window is open",
    "LOOT_OPENED with no items: still refused")
WoW.fire("LOOT_CLOSED")
check(untilBorrowed(), "LOOT_CLOSED: a burst")
runBurst()

--------------------------------------------------------------------------------
-- 15. Codex on PR #124.
--------------------------------------------------------------------------------

-- Another scanner borrows the map between our restore and the settle frame: the geometry, the
-- visibility and the input are all its own now; the settle frame writes none of ours over them.
NR = fresh()
check(untilBorrowed(), "(control) a burst")
for _ = 1, 20 do
    local b = NR.MoveScan._test.burst()
    if not b or b.phase == "settle" then break end
    frames(1)
end
local sb = NR.MoveScan._test.burst()
check(sb and sb.phase == "settle" and atHome(), "(control) restored and verified home, the settle frame next")
local rival = NR.MoveScan.RIVALS[1].name
WoW.loadedAddons = { [rival] = true }                -- its setting unread: on
Minimap:ClearAllPoints()
Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", -2000, -2000)
Minimap:SetAlpha(0)
Minimap:SetMouseClickEnabled(false)
Minimap:EnableMouseWheel(false)
frames(1)                                            -- the settle frame
check(NR.MoveScan._test.burst() == nil, "the settle frame ran")
local ax = select(4, Minimap:GetPoint(1))
check(ax == -2000, "its borrow's geometry left to it")
check(Minimap:GetAlpha() == 0, "its alpha 0 kept: our saved alpha not written over its borrow (got " .. tostring(Minimap:GetAlpha()) .. ")")
check(Minimap:IsMouseClickEnabled() == false and Minimap:IsMouseWheelEnabled() == false, "its input kept off")
check(NR.MoveScan._test.saved() == nil and NR.MoveScan.Trouble(GetTime()) ~= "halted", "nothing left owed, the scan not halted")
WoW.loadedAddons = nil

-- An owner's call made from another hook during our own setter call drops that claim: a frame on
-- the map whose hook on SetMouseClickEnabled(false) also turns its motion off keeps it off after
-- the burst; its clicks come back.
NR = fresh()
local pin = CreateFrame("Frame", nil, Minimap)
pin:Show()
pin:EnableMouse(true)
hooksecurefunc(pin, "SetMouseClickEnabled", function(self, v) if v == false then self:EnableMouseMotion(false) end end)
check(untilBorrowed(), "(control) a burst")
check(pin:IsMouseMotionEnabled() == false and pin:IsMouseClickEnabled() == false, "(control) quieted during the borrow")
runBurst()
frames(2)
check(atHome(), "(control) home after it")
check(pin:IsMouseClickEnabled() == true, "its clicks back")
check(pin:IsMouseMotionEnabled() == false, "its motion left off: the owner turned it off during our call")
-- The reverse order: a hook on SetMouseMotionEnabled(false) that turns its clicks off keeps them
-- off; its motion comes back. And one that calls EnableMouse(false) keeps both off.
NR = fresh()
local pin3 = CreateFrame("Frame", nil, Minimap)
pin3:Show()
pin3:EnableMouse(true)
hooksecurefunc(pin3, "SetMouseMotionEnabled", function(self, v) if v == false then self:SetMouseClickEnabled(false) end end)
check(untilBorrowed(), "(control) a burst")
runBurst()
frames(2)
check(pin3:IsMouseMotionEnabled() == true, "reverse order: its motion back")
check(pin3:IsMouseClickEnabled() == false, "reverse order: its clicks left off (the owner's, during our motion call)")
NR = fresh()
local pin4 = CreateFrame("Frame", nil, Minimap)
pin4:Show()
pin4:EnableMouse(true)
hooksecurefunc(pin4, "SetMouseMotionEnabled", function(self, v) if v == false then self:EnableMouse(false) end end)
check(untilBorrowed(), "(control) a burst")
runBurst()
frames(2)
check(pin4:IsMouseMotionEnabled() == false and pin4:IsMouseClickEnabled() == false,
    "EnableMouse(false) from the owner during our motion call: both left off, no claim recreated")
-- #125: every presence read's trace line carries its context (the player's state, the map's zoom
-- and radius, the icon scale, the tooltip, the last loot), valid or empty.
local function lastTrace(pat)
    for i = #NR.trace, 1, -1 do if NR.trace[i]:find(pat, 1, true) then return NR.trace[i] end end
end
NR = fresh()
WoW.fire("LOOT_CLOSED")
check(untilBorrowed(), "(control) a burst")
runBurst()
local rl = lastTrace("scan: read ")
check(rl and rl:find("indoors ", 1, true) and rl:find("radius ", 1, true) and rl:find("dots 0.01", 1, true)
    and rl:find("loot closed", 1, true), "a valid read's trace has its context (" .. tostring(rl) .. ")")
NR = fresh()
local realRead2 = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function() return { type = 21, lines = {} } end
check(untilBorrowed(), "(control) a burst")
runBurst()
C_TooltipInfo.GetMinimapMouseover = realRead2
local ul = lastTrace("scan: unread (no lines)")
check(ul and ul:find("; indoors ", 1, true) and ul:find("tooltip ", 1, true), "an empty read's trace has its context (" .. tostring(ul) .. ")")
-- #125: empty presence reads in a row (the map's hover stale after mouselook or a click, in game
-- until the mouse really moved): one alone is read again at the next look; two in a row and no
-- look until the mouse moves; a move, and the looks resume.
NR = fresh()
local emptyLeft = 99
local realRead3 = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function()
    if emptyLeft > 0 then return { type = 21, lines = {} } end
    return realRead3()
end
check(untilBorrowed(), "(control) a burst")
runBurst()
local b1 = NR.MoveScan.stats.bursts
check(NR.MoveScan.stats.unread == 1, "(control) the first read empty")
frames(400)
local b2 = NR.MoveScan.stats.bursts
check(b2 == b1 + 1, "one empty read: the next look still comes (" .. (b2 - b1) .. " more)")
frames(1000)
check(NR.MoveScan.stats.bursts == b2 and NR.MoveScan.lastRefusal == "the mouse hasn't moved since a click or mouselook",
    "two in a row: no more looks until the mouse moves (got " .. tostring(NR.MoveScan.lastRefusal) .. ")")
check(lastTrace("empty reads in a row") ~= nil, "...and the trace says so")
emptyLeft = 0
WoW.cursor = { WoW.cursor[1] + 40, WoW.cursor[2] }
check(untilBorrowed(), "the mouse moved: a look again")
runBurst()
check(NR.MoveScan.stats.valid >= 1, "...and it reads")
C_TooltipInfo.GetMinimapMouseover = realRead3
-- The memory churn (the owner, 2026-11-12: 50-80 MB; measured 12 KB a call in Learn.AnyOn, about
-- every frame): the tracking list is read on MINIMAP_UPDATE_TRACKING and at least every
-- ANYON_TTL s, not every frame; a change without the event still seen within ANYON_TTL.
NR = fresh()
local realInfo, infoCalls = C_Minimap.GetTrackingInfo, 0
C_Minimap.GetTrackingInfo = function(...) infoCalls = infoCalls + 1; return realInfo(...) end
frames(150)                                          -- 3 s, the scan on, looks included
check(infoCalls <= 2 * #WoW.tracking * 3, "3 s of frames: the tracking list read a few times, not every frame ("
    .. infoCalls .. " reads)")
WoW.tracking[1].active = false                       -- no event: only the TTL catches it
frames(math.ceil((NR.Learn.ANYON_TTL + 0.5) / 0.02))
check(NR.MoveScan.lastRefusal == "no gathering tracking on", "a change without its event: seen within ANYON_TTL (got "
    .. tostring(NR.MoveScan.lastRefusal) .. ")")
WoW.tracking[1].active = true
WoW.fire("MINIMAP_UPDATE_TRACKING")
check(NR.Learn.AnyOn() == true, "the event: read again at once")
C_Minimap.GetTrackingInfo = realInfo
-- The walks build no list for a frame without children (the owner's minimap: 1,388 frames, most
-- of them childless pins): GetChildren asked only of frames that have some.
NR = fresh()
for _ = 1, 30 do local leaf = CreateFrame("Frame", nil, Minimap); leaf:Show(); leaf:EnableMouse(true) end
local gcCalls = 0
local realKids = WoW.Methods.GetChildren
WoW.Methods.GetChildren = function(w) gcCalls = gcCalls + 1; return realKids(w) end
check(untilBorrowed(), "(control) a burst")
runBurst()
local found = NR.MoveScan.FindFollower()
WoW.Methods.GetChildren = realKids
check(gcCalls < 30, "30 childless frames on the map: GetChildren never asked of them, only of frames with children (" .. gcCalls .. " calls)")
-- #134: a frame on the map that takes the mouse wheel (a skin's scroll-to-zoom): off for the look,
-- back after; the owner turning it off during the look keeps it off.
NR = fresh()
local wheelPin = CreateFrame("Frame", nil, Minimap)
wheelPin:Show()
wheelPin:EnableMouse(false)
wheelPin:EnableMouseWheel(true)
check(untilBorrowed(), "(control) a burst")
check(wheelPin:IsMouseWheelEnabled() == false, "a frame on the map: its wheel off during the look")
runBurst()
frames(2)
check(wheelPin:IsMouseWheelEnabled() == true, "...and back after it")
NR = fresh()
local wheelPin2 = CreateFrame("Frame", nil, Minimap)
wheelPin2:Show()
wheelPin2:EnableMouse(false)
wheelPin2:EnableMouseWheel(true)
check(untilBorrowed(), "(control) a burst")
wheelPin2:EnableMouseWheel(false)                    -- the owner's own call, mid-look
runBurst()
frames(2)
check(wheelPin2:IsMouseWheelEnabled() == false, "the owner turned its wheel off during the look: kept off")

-- #133: a look right after a gather (the loot window closing), not at the next 6 s turn.
NR = fresh()
check(untilBorrowed(), "(control) a burst")
runBurst()
frames(30)
local gb = NR.MoveScan.stats.bursts
WoW.fire("LOOT_OPENED")
frames(10)
WoW.fire("LOOT_CLOSED")
local gt = WoW.now
untilBorrowed(100)
check(NR.MoveScan.stats.bursts == gb + 1 and WoW.now - gt < 1.5, ("the loot window closed: a look within a second or so (%.1f s)"):format(WoW.now - gt))
runBurst()
-- And still through the refusals: closed with the cursor busy, it waits.
NR = fresh()
check(untilBorrowed(), "(control) a burst")
runBurst()
frames(30)
local gb2 = NR.MoveScan.stats.bursts
WoW.fire("LOOT_OPENED")
frames(10)
WoW.combat = true
WoW.fire("LOOT_CLOSED")
frames(50)
check(NR.MoveScan.stats.bursts == gb2, "the loot window closed in combat: no look")
WoW.combat = false
-- And with no such hook, both come back.
NR = fresh()
local pin2 = CreateFrame("Frame", nil, Minimap)
pin2:Show()
pin2:EnableMouse(true)
check(untilBorrowed(), "(control) a burst")
check(pin2:IsMouseMotionEnabled() == false and pin2:IsMouseClickEnabled() == false, "(control) quieted")
runBurst()
frames(2)
check(pin2:IsMouseMotionEnabled() == true and pin2:IsMouseClickEnabled() == true, "a plain frame: both back")

--------------------------------------------------------------------------------
-- 14. #139: from 70938 the minimap tooltip's names are secret (measured on a real hover too).
-- SECRET_READS secret presence reads in a row stop the scan for that build, said once, in
-- Options in red; a valid read in between starts the count again; a new build tries again.
--------------------------------------------------------------------------------

local function secretLooks(n)
    for _ = 1, n do
        WoW.now = WoW.now + 10
        if not untilBorrowed(400) then return false end
        runBurst()
    end
    return true
end

NR = fresh(nil, "70938")
WoW.blips = { { "Silverleaf", 0, 0 } }             -- under the resting cursor's centre: a line every read
WoW.secretNames = true
check(secretLooks(NR.MoveScan.SECRET_READS - 1), "70938: secret looks run")
check(NR.MoveScan.On() and NR.db.secretNames == nil and NR.MoveScan.Trouble(GetTime()) == nil,
    "one short of SECRET_READS secret reads: still on")
WoW.secretNames = false
check(secretLooks(1) and NR.MoveScan.stats.valid == 1, "(control) a valid read in between")
WoW.secretNames = true
check(secretLooks(NR.MoveScan.SECRET_READS - 1) and NR.db.secretNames == nil,
    "a valid read starts the count again")
local chatBefore = #WoW.chat
check(secretLooks(1), "one more secret read")
check(NR.db.secretNames == 70938 and not NR.MoveScan.On(), "SECRET_READS in a row: off for build 70938")
check(atHome(), "...the map at home")
check(chatHas("hides the minimap's names from addons"), "...said in chat")
check(#WoW.chat == chatBefore + 1, "...once")
check(NR.MoveScan.Trouble(GetTime()) == "secret", "Options says why (Trouble: secret)")
check(NR.db.moveScan == true, "the player's setting is kept (the next build tries again)")
local bursts = NR.MoveScan.stats.bursts
WoW.now = WoW.now + 60
frames(300)
check(NR.MoveScan.stats.bursts == bursts and atHome(), "no look on this build any more: the map never borrowed")
SlashCmdList.NODERADAR("scan")
SlashCmdList.NODERADAR("scan")
check(chatHas("it can't run until the next build"), "/nr scan back on says it can't run on this build")
check(NR.MoveScan.Trouble(GetTime()) == "secret", "...and Trouble still says why")

-- Across a reload on the same build: still off; a new build: on again.
local db = NR.db
NR = fresh(db, "70938")
frames(300)
check(NR.MoveScan.stats.bursts == 0 and NR.MoveScan.Trouble(GetTime()) == "secret", "a reload on 70938: still off")
NR = fresh(db, "70950")
check(NR.MoveScan.On() and NR.MoveScan.Trouble(GetTime()) == nil, "a new build: the scan tries again")
WoW.secretNames = false

-- Never asked on a build whose names are secret.
NR = fresh({ secretNames = 70938 }, "70938")
check(NR.MoveScan._test.askAt() == nil, "never asked on a build whose names are secret")
NR = fresh({ secretNames = 70938 }, "70950")
check(NR.MoveScan._test.askAt() ~= nil, "(control) asked on the next build")


done("test_movescan")
