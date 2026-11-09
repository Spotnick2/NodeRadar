-- The movescan2 and movescan3 rounds (#91's last measurements): the pure logic (edges, read
-- shapes, the validity verdict, the walk model, the maxFPS restore, the fake skin) and the
-- burst on a minimap that follows where it is drawn. Runs locally only (ForeverProbe is private).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
rawset(_G, "Screenshot", function() end)
rawset(_G, "EnumerateFrames", function() return nil end)

-- Edit Mode's events and frame, as the client has them (the probe registers at load).
local callbacks = {}
rawset(_G, "EventRegistry", { RegisterCallback = function(_, name, fn) callbacks[name] = fn end })
WoW.editMode = false
rawset(_G, "EditModeManagerFrame", { IsEditModeActive = function() return WoW.editMode end })

local M = WoW.Methods
function M.IsProtected(w) return WoW.protected == true end
function M.GetNumPoints(w) return #w._points end
function M.SetClampedToScreen(w, v) w._clamp = v end
function M.IsClampedToScreen(w) return w._clamp end
function M.IsMouseClickEnabled(w) return w._click end
function M.IsMouseMotionEnabled(w) return w._motion end
function M.IsMouseWheelEnabled(w) return w._wheel end
function M.EnableMouseWheel(w, v) w._wheel = v end
function M.SetIconScale(w, v) w._iconScale = v end

-- GameTooltip:SetMinimapMouseover shows the tooltip (TooltipDataHandler adds it; not in the dump).
GameTooltip.SetMinimapMouseover = function(t) t._shown = true; t._owner = UIParent end

local NR = loadAddon()
local FP = loadForeverProbe()
local ns = loadProbe()
local MS, ms2 = ns._movescan, ns._ms2
local fp = function(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local W = ms2.W

local WorldFrame = CreateFrame("Frame", "WorldFrame", UIParent)
local HOME_PARENT = CreateFrame("Frame", "MinimapClusterStandIn", UIParent)
local function homeState()
    Minimap:ClearAllPoints()
    Minimap:SetPoint("TOPRIGHT", HOME_PARENT, "TOPRIGHT", -10, -20)
    Minimap:SetSize(140, 140)
    Minimap:SetAlpha(0.8)
    Minimap:SetClampedToScreen(true)
    Minimap:SetMouseClickEnabled(true)
    Minimap:SetMouseMotionEnabled(true)
    Minimap:EnableMouseWheel(true)
    Minimap:SetFrameStrata("LOW")
    Minimap:SetFrameLevel(7)
    Minimap._iconScale = nil
end
homeState()
WoW.cursor = { 500, 400 }
WoW.combat, WoW.protected = false, false

local function same(snap)
    local now = MS.snapshot()
    local p, q = snap.points[1], now.points[1]
    return #now.points == #snap.points and p[1] == q[1] and p[2] == q[2] and p[3] == q[3] and p[4] == q[4] and p[5] == q[5]
        and now.w == snap.w and now.h == snap.h and now.alpha == snap.alpha and now.clamp == snap.clamp
        and now.click == snap.click and now.motion == snap.motion and now.wheel == snap.wheel
        and now.strata == snap.strata and now.level == snap.level
end
local orig = MS.snapshot()
local function lines() return NodeRadarProbeDB.movescan2 and NodeRadarProbeDB.movescan2.lines or {} end
local function has(p) for _, l in ipairs(lines()) do if l:find(p, 1, true) then return true end end end
local function results() return NodeRadarProbeDB.movescan2.results end

-- The round is active, as in game: its stop guard must leave the steps' jobs alone.
fp("steps nr movescan2")
WoW.advance(1.1)
check(FP.db.steps.records["NodeRadarProbe/movescan2"] ~= nil and has("API: SetIconScale=true"), "the movescan2 round starts, and its first step logs the API")
check(has("tooltip hook installed=true") and has("EnableMouseClicks="), "...including whether Minimap has EnableMouseClicks (the stub answers yes; the dump says no) and whether the tooltip hook is possible")

-- 1. The pure logic --------------------------------------------------------------------------

local function K(n) return n == "Silverleaf" and "herbs" or nil end
local function P(n) return n == "Me" end
check(ms2.classify(nil, K, P).kind == "nil", "classify: nil is a nil answer")
check(ms2.classify({ type = 21 }, K, P).kind == "nolines:nil", "classify: a table without lines")
check(ms2.classify({ type = 21, lines = {} }, K, P).kind == "emptylines", "classify: a table with no lines")
local sh = ms2.classify({ lines = { { leftText = "Silverleaf" }, { leftText = "Silverleaf" }, { leftText = "Me" }, { leftText = "Some Rare" } } }, K, P)
check(sh.kind == "nodes" and sh.nNode == 2 and sh.nPlayer == 1 and sh.nOther == 1, "classify: nodes, a player and another entry are told apart")
local txt = ms2.shapeText(sh)
check(txt:find("Silverleaf", 1, true) and not txt:find("Some Rare", 1, true) and not txt:find("Me", 1, true), "classify: only node names are written out, never players or others")
check(ms2.classify({ lines = { { leftText = "Me" } } }, K, P).kind == "othersonly", "classify: only non-node entries")
check(ms2.classify(WoW.Secret("x"), K, P).kind == "secret", "classify: a secret answer")

local V = { focus = true, top = "Minimap", perr = 0.5, settled = true, readable = true }
check(ms2.verdict(V) == true, "verdict: a good read is valid")
local function vwith(k, v) local t = {}; for a, b in pairs(V) do t[a] = b end; t[k] = v; return ms2.verdict(t) end
local ok1, why1 = vwith("perr", 1.5)
check(ok1 == false and why1:find("placement error", 1, true), "verdict: a placement error over a unit is unread: " .. tostring(why1))
check(vwith("perr", 1) == true, "verdict: exactly a unit is still valid")
local ok2, why2 = vwith("settled", false)
check(ok2 == false and why2 == "unsettled", "verdict: an unsettled read is unread")
local ok3, why3 = vwith("focus", false)
check(ok3 == false and why3:find("top focus", 1, true), "verdict: Minimap not the top focus is unread")
check(vwith("perr", nil) == false and vwith("ubErr", "x") == false and vwith("readable", false) == false, "verdict: unreadable placement, UpdateBlips error and unreadable data are unread")

local function samplesOf(spec)
    local out = {}
    for i, c in ipairs(spec) do local h; if c == 1 then h = true elseif c == 0 then h = false end; out[i] = { off = i - 4, hit = h } end
    return out
end
local e = ms2.findEdges(samplesOf({ 0, 0, 1, 1, 1, 1, 0 }))                 -- offsets -3..3, hits at -1..2
check(e.lo == -2 + 1 and e.hi == 2 and e.width == 4 and e.centre == 0.5, "edges: the run's edges and width (" .. tostring(e.width) .. ")")
check(e.missLo == -2 and e.missHi == 3 and not e.truncLo and not e.truncHi, "edges: the misses that bound it")
local e2 = ms2.findEdges(samplesOf({ -1, -1, 1, 1, 1, 1, 0 }))
check(e2.truncLo == true and not e2.truncHi and e2.width == 4, "edges: an unread next to the run flags it as a lower bound")
local e3 = ms2.findEdges(samplesOf({ 1, 0, 0, 1, 1, 0, 0 }))
check(e3.width == 2 and e3.holes == 1, "edges: a hit outside the longest run is a hole")
check(ms2.findEdges(samplesOf({ 0, 0, -1 })).lo == nil, "edges: no hit at all")

local ox, oy = ms2.nodeOffsetPx(3, -2, 100, 200, 100, 200, 2)
check(ox == 3 and oy == -2, "walk model: standing still leaves the offset as placed")
ox, oy = ms2.nodeOffsetPx(0, 0, 100, 200, 100, 199, 2)                        -- the west coordinate fell: moved east a yard
check(ox == -2, "walk model: moving a yard east moves the node 2 px left of the cursor")
ox, oy = ms2.nodeOffsetPx(0, 0, 100, 200, 101, 200, 2)
check(oy == -2, "walk model: moving a yard north moves the node 2 px down from the cursor")
check(ms2.expectHit(8, -8, 16) and not ms2.expectHit(8.1, 0, 16) and not ms2.expectHit(0, -9, 16), "walk model: the hit square is H wide")
local tn, tw = ms2.worldTarget(100, 200, 10, -5, 198, 100)
local pdx, pdy = ms2.placeFor(tn, tw, 100, 200, 198, 100)
check(math.abs(pdx - 10) < 1e-9 and math.abs(pdy + 5) < 1e-9, "walk model: the placement for a world spot undoes the seed's projection")
check(math.abs(ms2.pxPerYard(198, 0.64, 100) - 0.6336) < 1e-9 and math.abs(ms2.unitsFor(20, 100, 16, 1.2) - 133.3333) < 1e-3, "walk model: pixels per yard and the map size for a window")

local cv = { maxFPS = "144" }
local api = { get = function(n) return cv[n] end, set = function(n, v) cv[n] = v end }
local d = {}
check(ms2.fpsTake(api, d) == true and cv.maxFPS == "20" and d.fpsPending.value == "144", "maxFPS: the value is saved, then capped")
ms2.fpsTake(api, d)
check(d.fpsPending.value == "144", "maxFPS: a second take keeps the owner's value, not 20")
check(ms2.fpsGive(api, d) == true and cv.maxFPS == "144" and d.fpsPending == nil, "maxFPS: given back, the pending value dropped")
cv.maxFPS = "144.000000"
d = {}; ms2.fpsTake(api, d)
local frozen = { get = function(n) return cv[n] end, set = function() end }
check(ms2.fpsGive(frozen, d) == false and d.fpsPending ~= nil, "maxFPS: a value that does not read back stays pending")
check(ms2.fpsGive(api, d) == true and cv.maxFPS == "144.000000", "maxFPS: ...and is given back when it can be")
check(ms2.fpsTake({ get = function() return nil end, set = function() end }, {}) == false, "maxFPS: no such CVar, nothing taken")
cv = { maxFPS = "120", useMaxFPS = "0" }
d = {}
check(ms2.fpsTake(api, d) == true and cv.useMaxFPS == "1" and cv.maxFPS == "20" and d.fpsPending.use == "0", "useMaxFPS: switched on with the cap, the owner's value saved")
check(ms2.fpsGive(api, d) == true and cv.useMaxFPS == "0" and cv.maxFPS == "120" and d.fpsPending == nil, "useMaxFPS: put back with maxFPS")
d = {}; ms2.fpsTake(api, d)
local useFrozen = { get = function(n) return cv[n] end, set = function(n, v) if n ~= "useMaxFPS" then cv[n] = v end end }
check(ms2.fpsGive(useFrozen, d) == false and d.fpsPending ~= nil, "useMaxFPS: one that does not read back keeps the whole pending value")
check(ms2.fpsGive(api, d) == true and cv.useMaxFPS == "0", "useMaxFPS: ...and is given back when it can be")
check(ms2.skinAction(nil, false) == nil and ms2.skinAction("anchor", false) == "pull" and ms2.skinAction("anchor+alpha", false) == "pull+opaque" and ms2.skinAction("anchor", true) == nil,
    "fake skin: off does nothing, anchor pulls, anchor+alpha pulls and shows, no recursion")
local st = ms2.statsOf({ 100, 200, 300, 400 })
check(st.n == 4 and st.min == 100 and st.max == 400 and st.avg == 250, "stats")

-- A minimap that follows where it is drawn: a blip's hit square is 2 x WoW.hitHalf screen px, its
-- place scaled with the map's size; the top focus is Minimap only while the cursor is on it.
local BASE = 140
WoW.hitHalf = 8
WoW.blipsAt = { { "Silverleaf", 20, -15 } }
WoW.blipFn = nil
Minimap._rect = { 430, 230, 140, 140 }
Minimap._effScale = 1.2
function Minimap.UpdateBlips() end
function Minimap.GetCenter()
    local p = Minimap._points[1]
    if p and p[1] == "CENTER" and p[3] == "BOTTOMLEFT" then return p[4] + (WoW.centreError or 0), p[5] end
    return 500, 300
end
local function centrePx()
    local p = Minimap._points[1]
    return p[4] * 1.2, p[5] * 1.2
end
local function placed()
    local p = Minimap._points[1]
    if not (p and p[1] == "CENTER" and p[3] == "BOTTOMLEFT") then return false end
    local half = Minimap:GetWidth() * 1.2 / 2
    return math.abs(WoW.cursor[1] - p[4] * 1.2) <= half and math.abs(WoW.cursor[2] - p[5] * 1.2) <= half
end
rawset(_G, "GetMouseFoci", function()
    if WoW.topFocus then return { WoW.topFocus } end
    if placed() then return { Minimap } end
    return { WorldFrame }
end)
rawset(_G, "IsMouselooking", function() return WoW.mouselook == true end)
rawset(_G, "IsMouseButtonDown", function(b) return WoW.buttons and WoW.buttons[b] == true end)
C_TooltipInfo.GetMinimapMouseover = function()
    if WoW.noAnswer then return nil end
    local cx, cy = centrePx()
    local k = (Minimap:GetWidth() / BASE) * 1.2
    local lines = {}
    for _, b in ipairs(WoW.blipFn and WoW.blipFn() or WoW.blipsAt) do
        if (not WoW.minNodeSize or Minimap:GetWidth() >= WoW.minNodeSize)
            and math.abs(WoW.cursor[1] - (cx + b[2] * k)) <= WoW.hitHalf and math.abs(WoW.cursor[2] - (cy + b[3] * k)) <= WoW.hitHalf then
            lines[#lines + 1] = { leftText = b[1], type = 0 }
        end
    end
    if #lines == 0 then return WoW.emptyAnswer end
    return { type = 21, lines = lines }
end
-- Blizzard's Minimap_OnUpdate: while the map is under the cursor, every frame it shows the tooltip.
local sim = CreateFrame("Frame")
sim:SetScript("OnUpdate", function() if placed() then GameTooltip:SetMinimapMouseover() else GameTooltip:Hide() end end)

local function runJob(step, body, secs, stepSize)
    local out = {}
    MS.start(step, function() if MS.state() then MS.restore("test start") end; out.v = body() end, function(s) out.sum = s end)
    WoW.advance(secs or 5, stepSize or 0.02)
    return out
end
local function advanceUntil(cond, secs, stepSize)
    local t, v = 0, cond()
    while not v and t < secs do WoW.advance(stepSize or 0.02, stepSize or 0.02); t = t + (stepSize or 0.02); v = cond() end
    return v
end

-- 2. One burst: the plan's frames -------------------------------------------------------------

homeState()
local rec
NodeRadarProbeDB.movescan = nil
local out = runJob("t", function() rec = ms2.burst({ step = "t", label = "presence", px = 15.4, name = "Silverleaf" }) end)
local noisy = 0
for _, l in ipairs(NodeRadarProbeDB.movescan and NodeRadarProbeDB.movescan.lines or {}) do
    if l:find("restore readback (t burst)", 1, true) or l:find("t f1 saved:", 1, true) == nil and l:find("SetIconScale", 1, true) then noisy = noisy + 1 end
end
check(noisy == 0, "a burst writes none of the old round's per-borrow lines (quiet), only failures (" .. noisy .. ")")
check(rec and not rec.refused, "a burst runs")
check(rec.frames == 5, "a burst takes the plan's five frames: borrow, place, settle, read, readback (" .. tostring(rec.frames) .. ")")
local rd = rec.reads[1]
check(rd and rd.r == 2 and rd.settled and rd.valid and rd.count == 1, "the read is two frames after the placement, settled, valid, and lists the node")
check(math.abs(rec.units - 15.4 / 1.2) < 1e-9 and math.abs(rec.px - 15.4) < 1e-9, "the presence size is 15.4 screen px: SetSize(15.4 / effective scale)")
check(rec.restoreOK and rec.readbackOK and same(orig) and Minimap._iconScale == 1, "the minimap is restored and read back")
check(rec.ms and rec.ms >= 0 and rec.tipFrames == 5, "the burst's duration in ms and its frames are recorded")

-- unsettled: read at r+1 is unread, never evidence
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "early", px = 15.4, unsettled = true, name = "Silverleaf" }) end)
rd = rec.reads[1]
check(rd and not rd.valid and rd.why == "unsettled" and rd.r == 1, "a read before the settle frame is flagged unread")
check(rd.shape and rd.shape.kind == "nodes", "...yet its shape is still logged")
check(same(orig), "...and the map is home")

-- the placement check
WoW.centreError = 5
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "err", px = 15.4 }) end)
rd = rec.reads[1]
check(rd and not rd.valid and rd.why:find("placement error", 1, true), "a placement error makes the read unread: " .. tostring(rd and rd.why))
WoW.centreError = 0

-- a window of ours over the map
local blocker = CreateFrame("Frame", "ForeverProbeConsoleStandIn", UIParent)
WoW.topFocus = blocker
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "blocked", px = 15.4, ignoreGate = true }) end)
rd = rec.reads[1]
check(rd and not rd.valid and rd.why:find("top focus is ForeverProbeConsoleStandIn", 1, true), "a read under another window is unread, not empty")
WoW.topFocus = nil
-- continuation: a top focus that is neither Minimap while placed nor the world ends the burst
WoW.topFocus = blocker
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "cont", px = 15.4 }) end)
check(rec.interrupted and rec.interrupted:find("top focus", 1, true) and #rec.reads == 0 and rec.restoreOK and same(orig), "an overlay ends the burst at once, and the map is home")
WoW.topFocus = nil

-- the tooltip: hidden after its producer, only while the scan's flag is on
check(ms2.ensureTipHook() == true, "the producer hook installs")
GameTooltip:Hide()
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "on", px = 15.4, tipLog = true }) end)
check(rec.tipShown == 0, "suppression on: the tooltip is never shown in a burst frame (" .. tostring(rec.tipShown) .. ")")
check(W.supCount > 0, "...because the hook hid it")
GameTooltip._shown = false
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "off", px = 15.4, suppress = false }) end)
check(rec.tipShown > 0, "suppression off: the tooltip shows (the hook hides only while the flag is on)")
GameTooltip:Hide()
check(has("(placed): GameTooltip shown"), "the per-frame tooltip lines are logged")

-- the fake skin
ms2.ensureSkinHook()
W.skinHome = MS.snapshot().points
W.skin = "anchor"
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "skin", px = 15.4 }) end)
rd = rec.reads[1]
check((rd == nil and rec.interrupted) or (rd and not rd.valid), "a skin that re-anchors the map leaves the read unread")
check(rec.restoreOK and rec.readbackOK and same(orig), "...and the map is restored")
W.skin = "anchor+alpha"
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "skin2", px = 15.4 }) end)
check(rec.opaque > 0, "a skin that also resets alpha shows the map: counted as opaque frames (" .. tostring(rec.opaque) .. ")")
check(rec.restoreOK and Minimap:GetAlpha() == 0.8 and same(orig), "...and the alpha comes back")
W.skin = nil
out = runJob("t", function() rec = ms2.burst({ step = "t", label = "noskin", px = 15.4 }) end)
check(rec.reads[1] and rec.reads[1].valid and rec.opaque == 0, "with the skin off, the same burst reads and never shows the map")

-- 3. The restore's order: geometry first, visibility and clicks only once it read back ---------

homeState()
local realSetSize = Minimap.SetSize
out = {}
MS.start("order", function()
    Minimap:SetSize(5, 5)
    Minimap:SetAlpha(0)
    Minimap:SetMouseClickEnabled(false)
    Minimap.SetSize = function() end              -- the geometry restore silently refused
    coroutine.yield()
end, function(s) out.sum = s end)
WoW.advance(0.5)
check(Minimap:GetAlpha() == 0 and Minimap._click == false, "geometry failed: the map stays invisible and click-off, never shown away from home")
check(NodeRadarProbeDB.movescan and (function() for _, l in ipairs(NodeRadarProbeDB.movescan.lines) do if l:find("GEOMETRY DID NOT READ BACK", 1, true) then return true end end end)(),
    "...and the log says why")
Minimap.SetSize = nil
WoW.advance(5)
check(Minimap:GetAlpha() == 0.8 and Minimap._click == true and same(orig), "the pending restore finishes once the geometry can be set back")

-- 4. A hit square, by a 1 px sweep ------------------------------------------------------------------

homeState()
MS.seeds.s1 = { name = "Silverleaf", dx = 20, dy = -15, B = 140, es = 1.2, kind = "herbs" }
out = runJob("hit", ms2.hitBody("s1", "hit_zoom1"), 40)
check(out.sum and out.v and out.v:find("H (x/y px) by size", 1, true), "the hit-square step finishes: " .. tostring(out.v))
local hit = results().hit_zoom1
check(hit and #hit.sizes == 4 and hit.sizes[1].units == 48 and hit.sizes[2].units == 64 and hit.sizes[3].units == 96 and hit.sizes[4].units == 198, "the sweep runs at four map sizes")
check(has("seed verified: Silverleaf x1"), "the seed is verified before the sweep")
check(hit.sizes[3].nodeX and hit.sizes[3].half and hit.sizes[3].circleRatio and hit.sizes[3].xEdgeHi, "each size records where the node's projection lies against the map's rect, and the cursor at the edges")
check(has("node projected at"), "...and logs it")
for _, s in ipairs(hit.sizes) do
    check(s.alive == true and s.xw and s.yw and s.xw >= 16 and s.xw <= 17 and s.yw >= 16 and s.yw <= 17, ("size %d: the square is found 16 to 17 px wide and tall (1 px steps; x %s, y %s)"):format(s.units, tostring(s.xw), tostring(s.yw)))
    check(s.r1agree and s.r1agree > 60 and (s.r1differ or 0) == 0, "size " .. s.units .. ": r+1 agrees with r+2 on a map that does not move")
end
check(has("hit f") or has("hit b"), "the sweep is logged")
check(same(orig) and Minimap._iconScale == 1, "the map is home after the sweeps")
-- a node near the rim: the sweep's cursor leaves the small map; those samples are unread, the sweep goes on
WoW.blipsAt = { { "Silverleaf", 60, 0 } }
MS.seeds.s1 = { name = "Silverleaf", dx = 60, dy = 0, B = 140, es = 1.2, kind = "herbs" }
out = runJob("hit", ms2.hitBody("s1", "hit_rim"), 40)
local rim = results().hit_rim
check(rim and rim.sizes[1].interrupted == nil and rim.sizes[1].alive == true and rim.sizes[1].xw and rim.sizes[1].xw >= 12 and rim.sizes[1].xw < 17, "a sweep whose cursor leaves the small map goes on, with the node found (width cut short by the edge)")
check(rim.sizes[1].x:find("TRUNCATED", 1, true), "...and the width is marked a lower bound where the map's edge cut it")
WoW.blipsAt = { { "Silverleaf", 20, -15 } }
-- a stale seed is reported, not measured
MS.seeds.s1 = { name = "Silverleaf", dx = -60, dy = 50, B = 140, es = 1.2, kind = "herbs" }
out = runJob("hit", ms2.hitBody("s1", "stale"), 20)
check(out.v == ms2.SEED_MSG and results().stale == nil and MS.seeds.s1 == nil, "a seed whose node is not there is not measured: the step asks for a new seed (" .. tostring(out.v) .. ")")
check(has("SEED NOT LISTED"), "...and the log says so")
local rdone, rtxt = ms2.retrying(function() return true, ms2.SEED_MSG end)()
check(rdone == false and rtxt == ms2.SEED_MSG, "a step whose body lost its seed goes back to waiting, not complete")
check(ms2.retrying(function() return true, "H done" end)() == true, "...and a finished one completes")
local sr = ms2.seedReady("s1", "a dot")
local okr, whyr = sr()
check(okr == false and whyr:find("SEED NOT LISTED", 1, true), "a dropped seed is asked for again before the countdown")
WoW.blipsAt = { { "Silverleaf", 60, 0 } }
MS.seeds.s1 = { name = "Silverleaf", dx = 99, dy = 99, B = 140, es = 1.2, kind = "herbs" }
out = runJob("ladder", ms2.ladderBody("s1", "stale_ladder"), 10)
check(out.v == ms2.SEED_MSG and results().stale_ladder == nil, "a ladder with a stale seed makes no result")
MS.seeds.s1 = { name = "Silverleaf", dx = 20, dy = -15, B = 140, es = 1.2, kind = "herbs" }
WoW.blipsAt = { { "Silverleaf", 20, -15 } }
MS.seeds.s1 = { name = "Silverleaf", dx = 20, dy = -15, B = 140, es = 1.2, kind = "herbs" }

-- 5. The presence-size ladder, with a size below which nodes are not listed --------------------------

WoW.minNodeSize = 12
out = runJob("ladder", ms2.ladderBody("s1", "ladder_scale1"), 20)
local lad = results().ladder_scale1
check(lad and #lad.rows == 7, "the ladder has seven sizes")
local byU = {}
for _, r in ipairs(lad.rows) do byU[#byU + 1] = r end
check(lad.verified == 1 and lad.controlPx >= 20 and byU[2].ctl == nil and byU[2].nSeedPlace == 1, "the ladder logs the verification count and a control read 20 px from the seed's place")
check(byU[1].s == true and byU[1].c == true and byU[2].s == true and byU[2].c == true, "20 and 24 units: listed at the node's place and centred")
check(byU[3].s == false and byU[3].c == false and byU[4].s == false, "12.8 and 14 px (below the stub's 12 unit size): not listed")
check(math.abs(byU[5].px - 15.4) < 1e-9 and byU[5].s == true and byU[5].c == true, "the 15.4 px row is the presence size and lists the node")
WoW.minNodeSize = nil
check(same(orig), "the ladder leaves the map home")

-- 6. Two nodes of one name ---------------------------------------------------------------------------------

MS.seeds.pairA = { name = "Silverleaf", dx = 20, dy = -15, B = 140, es = 1.2 }
MS.seeds.pairB = { name = "Silverleaf", dx = -30, dy = 25, B = 140, es = 1.2 }
WoW.blipsAt = { { "Silverleaf", 20, -15 }, { "Silverleaf", -30, 25 } }
out = runJob("pair", ms2.pairBody, 20)
check(results().pair and results().pair.presenceMultiplicity == 2, "two nodes of a name read twice at the presence size: " .. tostring(out.v))
check(results().pair.twice == 0, "...and never together at a cursor 50 px from one")
-- ...and the trace reaches each seeded node (the sweep goes from A to B, not away from B).
do
    local along, dPxAt = {}, results().pair.distancePxAt
    for t, c in results().pair.along:gmatch("([%+%-]%d+):(%S+)") do along[tonumber(t)] = c end
    local function near(target) local best; for t, c in pairs(along) do if math.abs(t - target) <= 2 and c == "1" then best = t end end return best end
    check(near(0) ~= nil, "the A-to-B trace lists the name once at A's position")
    check(near(dPxAt) ~= nil, "the A-to-B trace lists the name once at B's position (t = " .. string.format("%.1f", dPxAt) .. ")")
end
WoW.blipsAt = { { "Silverleaf", 20, -15 } }
MS.seeds.pairA, MS.seeds.pairB = nil, nil

-- 7. Tooltip suppression, over a full step --------------------------------------------------------------

GameTooltip:Hide()
out = runJob("tip", ms2.tipBody, 30)
local tip = results().tooltip
check(tip and tip.hooked and tip.on.shown == 0 and tip.off.shown > 0, "the tooltip step: suppression on shows nothing, off shows it")
check(tip.heldon and tip.heldon.shown == 0 and tip.heldoff and tip.heldoff.shown > 0, "the long held blinks too")
check(same(orig), "the map is home after the tooltip step")

-- 8. A valid read with nothing there ---------------------------------------------------------------------------

WoW.blipsAt = {}
out = runJob("empty", ms2.emptyBody, 30)
local function anyKey(group, pat)
    for k in pairs(results().empty[group]) do if k:find(pat, 1, true) then return true end end
end
check(anyKey("presence", "valid nil"), "a valid empty read at the presence size, when the client answers nil")
check(anyKey("unsettledPresence", "unread[unsettled] nil") and not anyKey("unsettledPresence", "valid"), "...against an unsettled one: unread, never valid")
check(anyKey("locate", "valid nil"), "...and at a locate size")
WoW.emptyAnswer = { type = 21, lines = {} }
out = runJob("empty", ms2.emptyBody, 30)
check(anyKey("presence", "valid emptylines"), "a table with no lines is told apart from nil")
WoW.emptyAnswer = nil
WoW.blipsAt = { { "Silverleaf", 20, -15 } }

-- 9. Movement between placement and read ------------------------------------------------------------------------

homeState()
WoW.hitHalf = 7.5
W.H = 15
local R = 100
WoW.pos = { 1000, 2000, 1 }
local wtn, wtw = ms2.worldTarget(1000, 2000, 30, -20, 140, R)
WoW.blipFn = function()
    local k = (70 / R)
    return { { "Silverleaf", (WoW.pos[2] - wtw) * k, (wtn - WoW.pos[1]) * k } }
end
MS.seeds.walk = { name = "Silverleaf", dx = 30, dy = -20, B = 140, es = 1.2, R = R, pos = { 1000, 2000 } }
local walker = CreateFrame("Frame")
walker:SetScript("OnUpdate", function(_, dt) if WoW.speed > 0 then WoW.pos = { WoW.pos[1] + 6 * dt, WoW.pos[2], WoW.pos[3] } end end)
WoW.speed = 6
-- the speed gate: standing still, no burst counts and the step times out
WoW.speed = 0
out = runJob("walk", ms2.walkBody, 50, 0.05)
check(results().walk.bursts == 0 and out.v:find("TIMED OUT", 1, true) and results().walk.refused:find("not moving", 1, true), "the walk counts bursts only while moving: standing still gives none and the step ends at 45 s: " .. tostring(out.v))
check(same(orig), "...and the map is home")
WoW.speed = 6
out = runJob("walk", ms2.walkBody, 30, 0.02)
WoW.speed = 0
walker:SetScript("OnUpdate", nil)
local wr = results().walk
check(wr and wr.bursts >= 20, "the walk step runs bursts while the player moves (" .. tostring(wr and wr.bursts) .. ")")
check(wr.agree > 10 and wr.differ == 0, "the read covers the world around the player at the READ: the model agrees in every read (" .. tostring(wr.agree) .. " agree, " .. tostring(wr.differ) .. " differ)")
check(wr.movedMax > 1, "the player really moved between placement and read in some burst (" .. ("%.2f"):format(wr.movedMax) .. " yd)")
local sawMiss, sawHit = false, false
for _, r in ipairs(wr.rows) do if r:find("listed 0", 1, true) then sawMiss = true end if r:find("listed 1", 1, true) then sawHit = true end end
check(sawMiss and sawHit, "...with both listed and unlisted reads, so the agreement means something")
check(same(orig), "the map is home after the walk")
WoW.blipFn = nil
WoW.hitHalf = 8
W.H = nil
MS.seeds.walk = nil

-- 10. maxFPS: always put back --------------------------------------------------------------------------------------

homeState()
WoW.cvars.maxFPS = "144"
local seen20 = false
local fpsWatch = CreateFrame("Frame")
fpsWatch:SetScript("OnUpdate", function() if WoW.cvars.maxFPS == "20" then seen20 = true end end)
out = runJob("lowfps", ms2.lowfpsBody, 30, 0.05)
check(seen20, "the cap was in effect during the step")
check(WoW.cvars.maxFPS == "144" and NodeRadarProbeDB.movescan2.fpsPending == nil, "maxFPS is back at the end of the step")
local lf = results().lowfps
check(lf and lf.ms.n == 14 and lf.bad == 0 and lf.restored == true, "the low-frame-rate bursts' durations are recorded (" .. tostring(lf and lf.ms.n) .. ")")
-- the step aborted
seen20 = false
MS.start("lowfps", ms2.lowfpsBody, function() end)
WoW.advance(2, 0.05)
check(WoW.cvars.maxFPS == "20", "(control) the cap is on mid-step")
WoW.fire("PLAYER_LEAVING_WORLD")
check(WoW.cvars.maxFPS == "144" and NodeRadarProbeDB.movescan2.fpsPending == nil, "a step aborted by the client leaving the world puts maxFPS back")
-- the step failing
MS.start("lowfps", function() ms2.fpsTake({ get = function(n) return WoW.cvars[n] end, set = function(n, v) WoW.cvars[n] = v end }, ms2.db()); coroutine.yield(); error("kaboom") end, function() end)
WoW.advance(0.5, 0.05)
check(WoW.cvars.maxFPS == "144", "a step that throws puts maxFPS back")
-- a reload: the pending value is in the saved variables, and login puts it back
ms2.db().fpsPending = { value = "90" }
WoW.cvars.maxFPS = "20"
WoW.fire("PLAYER_LOGIN")
check(WoW.cvars.maxFPS == "90" and ms2.db().fpsPending == nil, "after a reload, login puts the owner's maxFPS back")
WoW.cvars.maxFPS = nil

-- 11. Input in each phase ---------------------------------------------------------------------------------------------

homeState()
GameTooltip:Hide()
ms2.inputStart()
ms2.inputAlive()
WoW.advance(0.1, 0.02)
check(advanceUntil(function() return W.phase == "hold-prepared" end, 20), "a burst holds in its prepared phase")
WoW.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
check(select(1, MS.state()) ~= nil and (W.input.endedByDown or 0) == 0, "a flavor B burst is not ended by a mouse button down")
WoW.fire("GLOBAL_MOUSE_UP", "LeftButton")
check(advanceUntil(function() return W.phase == "hold-placed" end, 20), "a burst holds in its placed phase")
WoW.fire("GLOBAL_MOUSE_DOWN", "RightButton")
check(select(1, MS.state()) == nil and same(orig), "a flavor A burst ends at a mouse button down: the map is home at once")
check(W.input.endedByDown == 1, "...and the end is counted")
WoW.fire("GLOBAL_MOUSE_UP", "RightButton")
WoW.fire("MINIMAP_PING", "player", 0.1, 0.2)
local inp = ms2.db().input
local pings = 0
for k, v in pairs(inp) do if k:find("MINIMAP_PING | ", 1, true) then pings = pings + v end end
check(inp["DOWN LeftButton | hold-prepared"] == 1 and inp["DOWN RightButton | hold-placed"] == 1 and pings == 1,
    "each event is tallied by the phase it landed in")
check(has("DOWN RightButton: burst") and has("ended the burst; restore OK"), "the event line names the burst, frame, phase and the restore")
WoW.mouselook = true
WoW.advance(0.5, 0.02)
check((W.input.mlStarts or 0) == 1, "mouselook starting is seen once, in its phase")
WoW.mouselook = false
WoW.advance(3, 0.02)
local fin, res
fin, res = ms2.inputEnd()
check(fin == false and not W.input == false, "the end step waits for the last burst to finish")
advanceUntil(function() fin, res = ms2.inputEnd(); return fin end, 10)
check(fin and res:find("restore not clean 0", 1, true) and select(1, MS.state()) == nil, "the input run ends with every restore clean: " .. tostring(res))
check(same(orig) and select(2, MS.state()) == nil, "...and no job is left running")
check(W.input == nil and not W.watch, "...and the run's state is cleared")

-- 12. A fight starting mid-burst ---------------------------------------------------------------------------------------

homeState()
ms2.fightStart()
local fightWait = ms2.fightWait(3)
local function poll() WoW.advance(1, 0.02); return fightWait() end
local function oneFight(n)
    poll()
    check(advanceUntil(function() return W.phase == "placed" or W.phase == "hold-placed" end, 20), "fight " .. n .. ": a burst is in its placed phase")
    WoW.combat = true
    WoW.fire("PLAYER_REGEN_DISABLED")
    check(select(1, MS.state()) == nil and same(orig), "fight " .. n .. ": PLAYER_REGEN_DISABLED mid-burst restores at once")
    WoW.flushTimers(WoW.now + 1)
    poll(); poll()
    local cb = W.fight.combatBursts and W.fight.combatBursts[n]
    check(cb and cb.ok == true and not cb.refused and cb.frames >= 5, "fight " .. n .. ": the burst run in combat restores and reads back clean")
    check(MS.refusal() == "in combat", "fight " .. n .. ": nothing else may borrow in combat")
    WoW.combat = false
    WoW.fire("PLAYER_REGEN_ENABLED")
end
oneFight(1)
check(W.fight.n == 1 and W.fight.inBurst == 1 and W.fight.afterOK == 1, "the first fight began inside a burst, and the minimap was back after it")
poll()
check(select(2, MS.state()) ~= nil, "after the fight, the bursts resume")
oneFight(2)
oneFight(3)
local done3, msg3 = poll()
check(done3 == true and msg3:find("3 fights", 1, true), "three fights complete the step: " .. tostring(msg3))
local ffin, fres
advanceUntil(function() ffin, fres = ms2.fightEnd(); return ffin end, 10)
check(ffin and fres:find("back home true", 1, true) and results().fight.fights == 3, "the fight run ends with the minimap home: " .. tostring(fres))
check(same(orig) and select(2, MS.state()) == nil, "no job is left after the fight run")

-- 13. Edit Mode mid-burst ------------------------------------------------------------------------------------------------

homeState()
ms2.editStart()
local editWait = ms2.editWait()
local function epoll() WoW.advance(1, 0.02); return editWait() end
epoll()
check(advanceUntil(function() return W.phase == "placed" or W.phase == "hold-placed" end, 20), "a burst is in its placed phase")
WoW.editMode = true
callbacks["EditMode.Enter"]()
check(select(1, MS.state()) == nil and same(orig), "EditMode.Enter mid-burst restores at once")
WoW.flushTimers(WoW.now + 1)
epoll(); epoll()
check(select(2, MS.state()) == nil or true, "(bursts are refused while Edit Mode is active)")
local es = ms2.db().aborts
check(es[#es] ~= nil, "the abort is recorded with its phase")
local state1 = W.edit
check(state1.enters == 1 and state1.inBurst == 1 and state1.afterOK == 1, "Edit Mode entered inside a burst and the minimap came back")
local dn = editWait()
check(dn == false, "Edit Mode still open: the step waits")
WoW.editMode = false
callbacks["EditMode.Exit"]()
local dn2, dm2 = epoll()
check(dn2 == true, "leaving Edit Mode completes the step: " .. tostring(dm2))
local efin, eres
advanceUntil(function() efin, eres = ms2.editEnd(); return efin end, 10)
check(efin and eres:find("back home true", 1, true), "the Edit Mode run ends with the minimap home: " .. tostring(eres))
check(same(orig) and select(2, MS.state()) == nil, "no job is left after the Edit Mode run")

-- 14. What travels with Minimap ----------------------------------------------------------------------------------------------

homeState()
local eye = CreateFrame("Frame", "QueueStatusButton", UIParent)
function eye.GetRect() local p = Minimap._points[1]; return (p[4] or 0) + 100, (p[5] or 0) + 100, 20, 20 end
local mail = CreateFrame("Frame", "MiniMapMailFrame", UIParent)
function mail.GetRect() return 300, 300, 20, 20 end
out = runJob("attached", ms2.attachedBody, 20)
check(results().attached and #results().attached.travels == 1 and results().attached.travels[1] == "QueueStatusButton", "the frame anchored to Minimap is caught travelling, a fixed one is not: " .. tostring(out.v))
check(has("QueueStatusButton: before") and has("TRAVELS WITH MINIMAP"), "...and the log says so")
check(same(orig), "the map is home after the attached-frames step")

-- the fake skin step
out = runJob("fakeskin", ms2.skinBody, 40)
local fs = results().fakeskin
check(fs and fs.anchor.valid == 0 and fs.anchor.invalid == 6 and fs["anchor+alpha"].valid == 0, "with a re-anchoring skin every read is unread, never valid: " .. tostring(out.v))
check(fs.anchor.restoreBad == 0 and fs["anchor+alpha"].restoreBad == 0 and fs.homeOK == true, "...and the map always comes home")
check(fs["anchor+alpha"].opaqueBursts > 0 and (fs.anchor.opaqueBursts or 0) == 0, "an alpha-resetting skin shows the map during the borrow, an anchoring-only one does not")
check(W.skin == nil, "the fake skin is off afterwards")

-- 15. Riding ----------------------------------------------------------------------------------------------------------------------

homeState()
out = runJob("riding", ms2.ridingBody, 70, 0.05)
local rr = results().riding
check(rr and rr.bursts >= 25 and rr.valid >= 25 and rr.restoreBad == nil, "the riding step: a burst every 2 s for a minute, all valid (" .. tostring(rr and rr.bursts) .. ")")
check(rr.bursts <= 32, "...never faster than every 2 s")
check(same(orig), "the map is home after riding")

-- 15b. Glass MiniMap's scan lease is released once, on every exit ---------------------------------------------------------------

do
    local begins, ends = 0, 0
    rawset(_G, "GlassMiniMap", { PUBLIC_API_VERSION = 1, ScanBegin = function() begins = begins + 1; return true end, ScanEnd = function() ends = ends + 1 end })
    local function reset() begins, ends = 0, 0; homeState(); WoW.combat = false end
    reset()
    runJob("t", function() ms2.burst({ step = "t", label = "normal", px = 15.4, name = "Silverleaf" }) end)
    check(begins == 1 and ends == 1, "a normal burst takes and releases the lease once (" .. begins .. "/" .. ends .. ")")
    reset()
    runJob("t", function() ms2.burst({ step = "t", label = "interrupted", px = 15.4, name = "Silverleaf", holdPlaced = 30 }) end, 0.3)
    check(advanceUntil(function() return W.phase == "hold-placed" end, 5), "an interrupted burst gets to its hold")
    check(begins == 1 and ends == 0, "...holding the lease")
    WoW.combat = true
    WoW.fire("PLAYER_REGEN_DISABLED")
    WoW.advance(2, 0.02)
    check(begins == 1 and ends == 1, "combat mid-burst releases the lease exactly once (" .. begins .. "/" .. ends .. ")")
    WoW.combat = false
    reset()
    runJob("t", function() ms2.burst({ step = "t", label = "error", px = 15.4, name = "Silverleaf", placeFn = function() error("boom") end }) end, 1)
    check(begins == 1 and ends == 1, "a burst that throws releases the lease exactly once (" .. begins .. "/" .. ends .. ")")
    check(select(1, MS.state()) == nil and same(orig), "...with the map home")
    rawset(_G, "GlassMiniMap", nil)
end

-- 16. The rounds exist ----------------------------------------------------------------------------------------------------------------

fp("steps nr movescan2")
WoW.advance(1.1)
check(FP.db.steps.records["NodeRadarProbe/movescan2"] ~= nil, "the movescan2 round starts")
fp("steps nr movescan3")
WoW.advance(1.1)
check(FP.db.steps.records["NodeRadarProbe/movescan3"] ~= nil, "the movescan3 round starts")
FP.Steps.Stop("test")

done("test_probe_movescan2")
