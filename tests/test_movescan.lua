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
    local passed, failed = 0, 0
    if Kit then passed, failed = Kit.counts() end
    dofile("tests/wow_stubs.lua")
    dofile("tests/harness.lua")
    for _ = 1, passed do check(true) end
    for _ = 1, failed do check(false, "(an earlier case's failure, carried over)") end
    NodeRadar, NodeRadarDB, NodeRadarCharDB = nil, nil, nil
    WoW.build = build or "70862"
    WoW.moveModel = true
    WoW.tracking[1].active = true
    WoW.speed = 0
    WoW.cursor = { 300, 300 }                      -- over the world, away from the minimap
    WoW.blips = {}
    local NR = loadAddon({ db = db or { moveScan = true, moveScanAsked = true } })
    NR.db.learn = false
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

--------------------------------------------------------------------------------
-- 3. Unread is never absence: no observation at all.
--------------------------------------------------------------------------------

local n = #observed
WoW.mouseoverThrows = true
WoW.now = WoW.now + 10
check(untilBorrowed(400), "a burst with a failing read")
runBurst()
WoW.mouseoverThrows = false
check(#observed == n and NR.MoveScan.stats.unread == 1, "an unread burst observes nothing (not an empty count)")
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
-- A UI suite's full-screen layer below the minimap doesn't block it.
NR = fresh()
local layer = CreateFrame("Frame", nil, UIParent)
layer:SetFrameStrata("BACKGROUND")
WoW.focus = layer
check(untilBorrowed(), "a frame drawn below the minimap under the cursor: the burst still starts")
runBurst()
WoW.focus = nil
-- A click just released: 0.3 s before a burst (a quick second click mustn't meet the map).
NR = fresh()
frames(5)
WoW.buttonDown = true
frames(5)
WoW.buttonDown = false
frames(12)
check(NR.MoveScan.stats.bursts == 0, "0.24 s after a mouse button came up: no burst yet")
check(untilBorrowed(10), "...from 0.3 s, one comes")
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
frames(20)
check(NR.MoveScan.stats.bursts == 0 and g.ends == g.begins and g.begins >= 1, "a throwing ScanBegin: no borrow, ScanEnd paid")
NR = fresh()
rawset(_G, "GlassMiniMap", {})
WoW.loadedAddons = { GlassMiniMap = true }
frames(60)
check(NR.MoveScan.stats.bursts == 0 and chatHas("needs a newer Glass MiniMap"),
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

done("test_movescan")
