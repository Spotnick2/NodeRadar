-- The movescan round (/fp steps nr movescan, #91): the probe borrows Minimap and
-- must always put it back. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
rawset(_G, "Screenshot", function() end)
rawset(_G, "EnumerateFrames", function() return nil end)

-- The stub has no getters for these Minimap properties: a minimal, test-only version.
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

local NR = loadAddon()
local FP = loadForeverProbe()
local ns = loadProbe()
local MS = ns._movescan
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end

-- A minimap as Blizzard leaves it, and a cursor resting in the middle of the screen.
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
local function lines() return NodeRadarProbeDB.movescan and NodeRadarProbeDB.movescan.lines or {} end
local function has(p) for _, l in ipairs(lines()) do if l:find(p, 1, true) then return true end end end
local function count(p) local c = 0 for _, l in ipairs(lines()) do if l:find(p, 1, true) then c = c + 1 end end return c end
local function wipeLines() NodeRadarProbeDB.movescan = nil end
local function same(snap)
    local now = MS.snapshot()
    local p, q = snap.points[1], now.points[1]
    return #now.points == #snap.points and p[1] == q[1] and p[2] == q[2] and p[3] == q[3] and p[4] == q[4] and p[5] == q[5]
        and now.w == snap.w and now.h == snap.h and now.alpha == snap.alpha and now.clamp == snap.clamp
        and now.click == snap.click and now.motion == snap.motion and now.wheel == snap.wheel
        and now.strata == snap.strata and now.level == snap.level
end

-- The round exists.
fp("steps nr movescan")
WoW.advance(1.1)
check(FP.db.steps.records["NodeRadarProbe/movescan"] ~= nil, "the movescan round starts")

-- 1. The helper restores every property and verifies.
local orig = MS.snapshot()
check(orig.alpha == 0.8 and orig.clamp == true and orig.level == 7, "the stub minimap reads back as set")
local ok = MS.begin("t1")
check(ok == true, "begin borrows an unprotected minimap")
Minimap:ClearAllPoints()
Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", -10000, -10000)
Minimap:SetSize(21, 21)
Minimap:SetAlpha(0)
Minimap:SetClampedToScreen(true)
Minimap:SetMouseClickEnabled(false)
Minimap:SetMouseMotionEnabled(false)
Minimap:EnableMouseWheel(false)
Minimap:SetFrameStrata("HIGH")
Minimap:SetFrameLevel(30)
check(MS.restore("t1") == true, "restore reports a clean readback")
check(same(orig), "every saved property is back")
check(has("restore readback (t1): points OK"), "the readback line is explicit")
check(has("size OK") and has("alpha OK") and has("clamp OK") and has("mouse OK") and has("strata OK"), "...for every property")
local n = #lines()
check(MS.restore("again") == true and #lines() == n, "restore is idempotent")

-- 2. An error thrown mid-step restores.
homeState(); wipeLines()
local doneSummary
MS.start("boom", function()
    Minimap:SetSize(21, 21)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", -10000, -10000)
    coroutine.yield()
    error("kaboom")
end, function(s) doneSummary = s end)
WoW.advance(0.5)
check(doneSummary and doneSummary:find("failed", 1, true), "the step reports its failure")
check(has("STEP FAILED") and has("kaboom"), "the error is logged")
check(same(orig), "the minimap is back after the error")
check(has("restore readback (end of boom): points OK"), "the readback is logged after the error")
local S, job = MS.state()
check(S == nil and job == nil, "nothing is left borrowed")

-- 3. It refuses when protected or in combat, and then changes nothing.
homeState(); wipeLines()
WoW.protected = true
check(MS.begin("t3") == false, "a protected minimap is refused")
check(has("REFUSED: Minimap is protected"), "...and logged")
check(same(orig), "...and untouched")
WoW.protected = false
WoW.combat = true
check(MS.begin("t3") == false, "combat is refused")
check(has("REFUSED: in combat"), "...and logged")
check(select(1, MS.state()) == nil, "...and nothing saved")
WoW.combat = false
local refused
MS.start("t3s", function() Minimap:SetSize(5, 5) end, function(s) refused = s end)
WoW.protected = false
check(refused == nil, "a normal start is accepted")
WoW.advance(0.3)
check(same(orig), "...and its end restores")
WoW.combat = true
MS.start("t3c", function() Minimap:SetSize(5, 5) end, function(s) refused = s end)
check(refused and refused:find("refused", 1, true), "a step refuses to start in combat")
WoW.combat = false

-- 4. PLAYER_REGEN_DISABLED mid-step restores at once.
homeState(); wipeLines()
MS.start("regen", function()
    Minimap:SetSize(5, 5)
    for _ = 1, 100 do coroutine.yield() end
end, function() end)
WoW.advance(0.3)
check(MS.snapshot().w == 5, "the step is borrowing the minimap")
WoW.combat = true
WoW.fire("PLAYER_REGEN_DISABLED")
check(same(orig), "PLAYER_REGEN_DISABLED restores at once")
check(has("ABORT: PLAYER_REGEN_DISABLED"), "...and says why")
S, job = MS.state()
check(S == nil and job == nil, "...and the step is stopped")
WoW.combat = false
MS.start("leave", function() Minimap:SetSize(5, 5); for _ = 1, 100 do coroutine.yield() end end, function() end)
WoW.advance(0.3)
WoW.fire("PLAYER_LEAVING_WORLD")
check(same(orig), "PLAYER_LEAVING_WORLD restores too")

-- 5. A read is discarded when the cursor moved more than 2 px since placement.
homeState(); wipeLines()
WoW.cursor = { 500, 400 }
MS.begin("t5")
MS.place(0, 0)
WoW.cursor = { 504, 400 }
check(MS.read("t5", "moved") == nil, "a cursor 4 px away discards the read")
check(has("DISCARDED, the cursor moved 4.0 px"), "...and logs it")
WoW.cursor = { 500, 400 }
MS.place(0, 0)
WoW.cursor = { 501, 401 }
check(type(MS.read("t5", "still")) == "table", "a cursor 1.4 px away keeps the read")
MS.restore("t5")

-- A mouseover that follows where the map is drawn: a blip's hit area is 16 screen
-- px, its place scaled with the map's size (the claim #91 measures).
local BASE = 140
WoW.blipsAt = { { "Silverleaf", 20, -15 } }
Minimap._rect = { 430, 230, 140, 140 }                      -- centre 500,300; effective scale 1.2
Minimap._effScale = 1.2
local function centrePx()
    local p = Minimap._points[1]
    return p[4] * 1.2, p[5] * 1.2
end
function Minimap.GetCenter()
    local p = Minimap._points[1]
    if p and p[1] == "CENTER" and p[3] == "BOTTOMLEFT" then return p[4] + (WoW.centreError or 0), p[5] end
    return 500, 300
end
WoW.seen = {}
C_TooltipInfo.GetMinimapMouseover = function()
    local k0 = WoW.kid0
    WoW.seen["strata:" .. tostring(Minimap:GetFrameStrata())] = true
    WoW.seen["click:" .. tostring(Minimap._click)] = true
    WoW.seen["motion:" .. tostring(Minimap._motion)] = true
    WoW.seen["wheel:" .. tostring(Minimap._wheel)] = true
    WoW.seen["alpha:" .. tostring(Minimap:GetAlpha())] = true
    WoW.seen["icon:" .. tostring(Minimap._iconScale)] = true
    if k0 then WoW.seen["kidclick:" .. tostring(k0._click)] = true; WoW.seen["kidmotion:" .. tostring(k0._motion)] = true end
    if WoW.hoverNames then
        local l = {}
        for _, nm in ipairs(WoW.hoverNames) do l[#l + 1] = { leftText = nm, type = 0 } end
        return { type = 21, lines = l }
    end
    local cx, cy = centrePx()
    local k = (Minimap:GetWidth() / BASE) * 1.2
    local lines = {}
    for _, b in ipairs(WoW.blipsAt) do
        if (not WoW.minNodeSize or Minimap:GetWidth() >= WoW.minNodeSize) and math.abs(WoW.cursor[1] - (cx + b[2] * k)) <= 8 and math.abs(WoW.cursor[2] - (cy + b[3] * k)) <= 8 then
            lines[#lines + 1] = { leftText = b[1], type = 0 }
        end
    end
    if #lines == 0 then return nil end
    return { type = 21, lines = lines }
end

-- The move-and-shrink round restores both times and leaves the map home.
homeState(); wipeLines()
MinimapCluster = nil
local touched = {}
rawset(_G, "MinimapCluster", setmetatable({}, { __index = function(_, k)
    return function() touched[#touched + 1] = k; return false end
end }))
WoW.methodsCalled = {}
local sum
MS.start("restore", MS.homeBody, function(s) sum = s end)
WoW.advance(2)
check(sum == "off screen OK, 21 px OK", "the move-and-shrink round restores both times: " .. tostring(sum))
check(same(orig), "the minimap is home after the restore round")
check(count("restore readback (off screen): points OK") == 1 and count("restore readback (off screen and 21 px): points OK") == 1, "both readbacks are OK")
check(has("Minimap:UpdateBlips ok"), "UpdateBlips is tried")

-- The hover seed: a name that is not a node does not seed; a node does, after two polls.
homeState(); wipeLines()
WoW.cursorOnMap = true
WoW.cursor = { 624, 342 }                                   -- (20,-15) from the centre, in map units
WoW.hoverNames = { "Some Player" }
local seed = MS.seedWait("single", "a dot")
local r1, why1 = seed()
seed()
seed()
check(r1 == false and why1 and why1:find("not in the node library", 1, true), "a non-node name does not seed: " .. tostring(why1))
check(MS.seeds.single == nil, "...and nothing is seeded")
-- Learn.Kind is not trusted: it says herbs for everything here, and the library holds a
-- party member's name too.
local realKind = NodeRadar.Learn.Kind
NodeRadar.Learn.Kind = function() return "herbs" end
rawset(_G, "UnitName", function(u) if u == "player" then return "Me" end if u == "party1" then return "Karuzo Macphisto" end end)
NodeRadar.LIBRARY.enUS["Karuzo Macphisto"] = "herbs"
WoW.hoverNames = { "Karuzo Macphisto" }
local rp, whyp = seed()
seed(); seed()
check(rp == false and whyp:find("a player, not a node", 1, true), "a party member's name is rejected: " .. tostring(whyp))
check(MS.seeds.single == nil, "...even when Learn.Kind and the library say herbs")
WoW.hoverNames = { "The Missing Shipment" }
seed(); seed(); seed()
check(MS.seeds.single == nil, "a name Learn.Kind calls herbs but the library lacks does not seed")
NodeRadar.LIBRARY.enUS["Karuzo Macphisto"] = nil
NodeRadar.Learn.Kind = realKind
WoW.hoverNames = { "Silverleaf" }
check(seed() == false and MS.seeds.single == nil, "the first poll on a node only waits")
check(seed() == true, "the second poll seeds it")
local sd = MS.seeds.single
check(sd and sd.name == "Silverleaf" and sd.kind == "herbs" and math.abs(sd.dx - 20) < 0.01 and math.abs(sd.dy + 15) < 0.01 and sd.B == 140,
    "the seed has the node's name, kind and offset from the map's centre")
WoW.hoverNames = nil
WoW.cursorOnMap = false
WoW.cursor = { 500, 400 }

-- pair B on the same dot as A keeps waiting.
MS.seeds.pairA = { name = "Silverleaf", dx = 21, dy = -14, B = 140, kind = "herbs" }
WoW.cursorOnMap = true
WoW.cursor = { 625.2, 343.2 }
WoW.hoverNames = { "Silverleaf" }
local sameDot = MS.seedWait("pairB", "the other dot")
sameDot()
local rb, whyb = sameDot()
check(rb == false and whyb:find("same dot", 1, true) and MS.seeds.pairB == nil, "pair B on A's dot does not seed: " .. tostring(whyb))
MS.seeds.pairA = nil
WoW.hoverNames = nil
WoW.cursorOnMap = false
WoW.cursor = { 500, 400 }

-- single: reads at the seed's offset, the sizes, the icon scale, the hit square.
homeState(); wipeLines()
sum = nil
MS.start("single", MS.singleBody, function(s) sum = s end)
WoW.advance(120)
check(sum ~= nil and sum:find("24 px plain:c[1,1,1]s[1,1,1] alpha 0 only:c[1,1,1]s[1,1,1] hidden", 1, true), "the single-node round finishes with the three 24 px variants: " .. tostring(sum))
-- Settle: every placement is read at r+1, r+2, r+3 and r+4, each logged on its own.
check(has("ladder 198 px seed offset r+1: Silverleaf") and has("ladder 198 px seed offset r+2: Silverleaf") and has("ladder 198 px seed offset r+3: Silverleaf") and has("ladder 198 px seed offset r+4: Silverleaf"), "each placement is read at r+1..r+4")
check(count("ladder 198 px seed offset r+") == 4, "...and at no other frame")
check(not has("PLACEMENT ERROR"), "a correct placement is never flagged")
check(has("cursor at 20.0,-15.0 map units vs intended 20.0,-15.0; error 0.0"), "every read logs where the cursor lies against what was intended")
check(has("ladder summary: 198:c[0,0,0]s[1,1,1] 64:c[0,0,0]s[1,1,1] 48:c[0,0,0]s[1,1,1] 32:c[1,1,1]s[1,1,1] 28:c[1,1,1]s[1,1,1] 24:c[1,1,1]s[1,1,1] 22:c[1,1,1]s[1,1,1] 20:c[1,1,1]s[1,1,1]"), "the ladder is 198, 64, 48, 32, 28, 24, 22, 20, centred and at the seed's offset")
check(has("centred: read at [32 28 24 22 20] px, missed at [198 64 48] px"), "the ladder says where the node drops out")
check(has("24 px plain centred r+1") and has("24 px alpha 0 only centred r+1") and has("24 px hidden (alpha 0 + icon scale 0.01) centred r+1"), "each 24 px variant is named in the log")
check(has("SetIconScale(0.01) ok") and has("SetIconScale(1) ok"), "the icon scale is set and set back")
check(not has("c (icon scale"), "(c) is gone")
check(has("nodes: Silverleaf x1"), "reads mark the node names")
check(same(orig), "the minimap is home after the single round")
check(Minimap._iconScale == 1, "the icon scale is set back to 1")
check(has("icon scale set back to 1; the original is unknown"), "...and the log says the original is unknown")

-- The placement check flags an error over 1 map unit.
homeState(); wipeLines()
WoW.centreError = 5
MS.start("v", function() MS.at("v", "err5", 20, -15, 140, { 1 }, "Silverleaf") end, function() end)
WoW.advance(1)
check(has("error 5.0 PLACEMENT ERROR"), "a 5-unit placement error is flagged")
wipeLines()
WoW.centreError = 0.5
MS.start("v", function() MS.at("v", "err05", 20, -15, 140, { 1 }, "Silverleaf") end, function() end)
WoW.advance(1)
check(has("error 0.5") and not has("PLACEMENT ERROR"), "half a unit is not")
WoW.centreError = 0

-- The dry run: one placement, the four reads, everything logged.
homeState(); wipeLines()
fp("nr movetest 21 5 -3")
WoW.advance(2)
check(has("movetest f") and has("21 px at (5,-3) r+1:") and has("21 px at (5,-3) r+4:"), "movetest places once and logs r+1..r+4")
check(has("cursor at 5.0,-3.0 map units vs intended 5.0,-3.0"), "...with the placement check")
check(same(orig), "...and the map is home")

-- The size ladder dry run: the point scaled by size/198, the summary, and where nodes are lost.
homeState(); wipeLines()
BASE = 198
WoW.minNodeSize = 64
fp("nr movetest ladder 20 -15")
WoW.advance(12)
check(has("ladder (20,-15): 198:[1,1,1] 176:[1,1,1] 160:[1,1,1] 144:[1,1,1] 128:[1,1,1] 112:[1,1,1] 96:[1,1,1] 80:[1,1,1] 64:[1,1,1] 48:[0,0,0] 32:[0,0,0] 24:[0,0,0]"), "the ladder summary counts r+2..r+4 per size")
check(has("ladder: nodes read down to 64 px; lost at 48 32 24"), "the final line says where the nodes are lost")
check(has("ladder 96 px at (9.7,-7.3) r+1:"), "each size places the point scaled by size/198")
check(has("ladder 128 px +8 px r+2:") and has("ladder 128 px -8 px r+2:"), "each size is read at +8 and -8 px")
check(same(orig), "the ladder leaves the map home")
BASE = 140
WoW.minNodeSize = nil
-- The variants: each applies its changes, and the readback puts back all of them.
local kid0 = CreateFrame("Frame", "TestKid0", Minimap)
kid0:SetMouseClickEnabled(true); kid0:SetMouseMotionEnabled(true)
WoW.kid0 = kid0
rawset(_G, "GetMouseFoci", function() return { Minimap } end)
local function homeKid() kid0:SetMouseClickEnabled(true); kid0:SetMouseMotionEnabled(true) end
local function variant(v, expect)
    homeState(); homeKid(); wipeLines(); WoW.seen = {}
    fp("nr movetest 21 0 0 " .. v)
    WoW.advance(3)
    for _, key in ipairs(expect) do check(WoW.seen[key], v .. " applies " .. key) end
    check(has("variant " .. v .. " applied"), v .. " logs what it applied")
    check(has("foci [Minimap[") and has("Minimap:IsMouseOver") and has("cursor within Minimap's rect"), v .. " logs the mouse focus on every read")
    check(same(orig), v .. ": the map's own properties are back")
    check(kid0._click == true and kid0._motion == true, v .. ": the child's mouse states are back")
    check(has("children mouse OK (") and not has("READBACK DIFFERS"), v .. ": the readback verifies the children")
end
-- A read under a window of ours is BLOCKED and counts for nothing (r+2..r+4 are counted).
local blockFrame = CreateFrame("Frame", "ForeverProbeConsoleStandIn", UIParent)
blockFrame:SetFrameStrata("TOOLTIP"); blockFrame:SetFrameLevel(2)
WoW.topFocus = blockFrame
rawset(_G, "GetMouseFoci", function() if WoW.noFoci then return {} end return { WoW.topFocus or Minimap } end)
homeState(); wipeLines()
local blockedRes, openRes
MS.start("blk", function()
    blockedRes = MS.at("blk", "under the console", 20, -15, 140, { 1, 2, 3, 4 }, "Silverleaf")
    WoW.topFocus = nil
    openRes = MS.at("blk", "on open world", 20, -15, 140, { 1, 2, 3, 4 }, "Silverleaf")
end, function() end)
WoW.advance(2)
check(has("under the console r+2: BLOCKED by ForeverProbeConsoleStandIn[TOOLTIP/2]"), "a read under the console is BLOCKED, naming the frame, strata and level")
check(blockedRes and #blockedRes == 3 and blockedRes[1] == "x" and blockedRes[3] == "x", "...and is not counted as a miss")
check(openRes and #openRes == 3 and openRes[1] == 1, "the same placement on open world reads the node at r+2..r+4")
check(has("on open world r+1: Silverleaf"), "r+1 is still logged as evidence")
WoW.topFocus = nil
variant("plain", { "strata:LOW", "click:true", "kidclick:true" })
variant("tooltip", { "strata:TOOLTIP", "click:true" })
variant("motion", { "strata:LOW", "click:false", "motion:true" })
variant("ref", { "strata:TOOLTIP", "click:false", "motion:true", "wheel:false", "kidclick:false", "kidmotion:false" })
-- hidden: alpha 0 and icon scale 0.01 before the first placement; both put back.
variant("hidden", { "alpha:0", "icon:0.01" })
check(Minimap:GetAlpha() == 0.8 and Minimap._iconScale == 1, "hidden: alpha and icon scale are reset")
check(has("HIDDEN (alpha 0, icon scale 0.01)") and has("SetIconScale(0.01) ok"), "hidden: the read lines say so")
check(has("icon scale set back to 1; the original is unknown"), "hidden: the original icon scale is logged as unknown")
check(not WoW.seen["alpha:0.8"], "hidden: no read happened before alpha 0 was in effect")
homeState(); wipeLines(); WoW.seen = {}
fp("nr movetest ladder 0 10 hidden")
WoW.advance(12)
check(WoW.seen["alpha:0"] and WoW.seen["icon:0.01"] and has("HIDDEN") and has("ladder: nodes read down to"), "the ladder takes hidden too")
check(Minimap:GetAlpha() == 0.8 and Minimap._iconScale == 1 and same(orig), "...and restores both")
homeState(); homeKid(); wipeLines(); WoW.seen = {}
FP.Steps.Stop("test")                      -- the round is not active: its stop guard must leave a dry run alone
fp("nr movetest 21 0 0 all")
WoW.advance(10)
check(not has("ABORT"), "the dry run is not stopped by the round's guard")
check(count("restore readback (movetest ") == 4, "all runs four restores (" .. count("restore readback (movetest ") .. ")")
check(WoW.seen["strata:TOOLTIP"] and WoW.seen["kidclick:false"] and WoW.seen["click:false"], "all runs the variants")
check(has("variant plain applied") and has("variant tooltip applied") and has("variant motion applied") and has("variant ref applied"), "...each in turn")
check(same(orig) and kid0._click == true, "all leaves everything home")
fp("steps nr movescan")                    -- the round is active again for the tests that follow
WoW.advance(1.1)
fp("nr movetest 21 0 0 nonsense")
WoW.advance(1)
check(select(1, MS.state()) == nil, "an unknown variant starts nothing")
homeState(); homeKid()

-- Flags: ub, xN, nofocus.
function Minimap.UpdateBlips() WoW.ub = (WoW.ub or 0) + 1 end
WoW.ub = 0
homeState(); wipeLines()
fp("nr movetest 24 20 -15")
WoW.advance(2)
check(WoW.ub == 0 and not has("UpdateBlips() after the placement"), "without ub, UpdateBlips is not called")
homeState(); wipeLines(); WoW.ub = 0
fp("nr movetest 24 20 -15 ub")
WoW.advance(2)
check(WoW.ub == 2 and has("Minimap:UpdateBlips() after the placement ok") and has("Minimap:UpdateBlips() after coming home ok"), "ub calls UpdateBlips after the placement and again after coming home (" .. WoW.ub .. ")")
check(same(orig), "...and the map is home")

homeState(); wipeLines()
fp("nr movetest 24 20 -15 hidden x5")
WoW.advance(10)
check(has("#1 r+1:") and has("#5 r+4:") and count("#3 r+") == 4, "x5 logs r+1..r+4 under each placement's index")
check(has("placement 1 of 5: library nodes at r+2..r+4 [1,1,1]: Silverleaf") and has("placement 5 of 5: library nodes at r+2..r+4 [1,1,1]: Silverleaf"), "...and a summary per placement of the library nodes")
check(not has("placement 6 of 5") and has("HIDDEN"), "...exactly five, in any flag order")
check(Minimap:GetAlpha() == 0.8 and Minimap._iconScale == 1 and same(orig), "...and everything is back")

WoW.noFoci = true
homeState(); wipeLines()
fp("nr movetest 24 20 -15")
WoW.advance(2)
check(has("BLOCKED by nothing") and not has("UNFOCUSED"), "an empty focus list blocks a read without nofocus")
homeState(); wipeLines()
rawset(_G, "IsMouselooking", function() return true end)
rawset(_G, "IsMouseButtonDown", function(b) return b == "RightButton" end)
fp("nr movetest 24 20 -15 nofocus ub")
WoW.advance(2)
check(has("UNFOCUSED (no mouse focus, read anyway)") and not has("BLOCKED"), "nofocus reads anyway, marked UNFOCUSED")
check(has("mouselooking true right true left false"), "...and logs IsMouselooking and the buttons on each read")
check(has("r+4: Silverleaf"), "...and the read lists the node")
WoW.noFoci = nil
WoW.topFocus = blockFrame
homeState(); wipeLines()
fp("nr movetest 24 20 -15 nofocus")
WoW.advance(2)
check(has("BLOCKED by ForeverProbeConsoleStandIn") and not has("UNFOCUSED"), "nofocus still blocks a different top frame")
WoW.topFocus = nil
homeState()

-- The watch step: five 24 px placements with the map at alpha 0, half a second apart.
homeState(); wipeLines(); WoW.seen = {}
sum = nil
MS.start("watch", MS.watchBody, function(x) sum = x end)
WoW.advance(12)
check(sum ~= nil and has("placement 1 of 5") and has("placement 5 of 5") and not has("placement 6 of 5"), "the watch step places five times: " .. tostring(sum))
check(WoW.seen["alpha:0"] and not WoW.seen["alpha:0.8"], "...every one at alpha 0")
check(Minimap:GetAlpha() == 0.8 and same(orig), "...and the map is home afterwards")

-- Nothing runs per frame once a dry run has ended.
homeState(); homeKid(); wipeLines()
fp("nr movetest 21 0 0 plain")
WoW.advance(3)
local n0, f0 = count("restore readback"), MS.frame()
WoW.advance(5)
check(count("restore readback") == n0 and not has("stray save"), "no restore runs after the end, over 5 s of frames")
check(MS.frame() == f0 and select(1, MS.state()) == nil, "the per-frame driver is stopped when idle")
-- A readback that never matches: three more tries, a second apart, then the save is dropped.
homeState(); wipeLines()
Minimap.SetFrameStrata = function(w, v) if v == "TOOLTIP" then w._strata = v end end
fp("nr movetest 21 0 0 tooltip")
WoW.advance(8)
check(count("restore readback") == 4 and has("GAVE UP"), "a stuck readback is tried 3 more times, then given up (" .. count("restore readback") .. " readbacks)")
WoW.advance(5)
check(count("restore readback") == 4 and select(1, MS.state()) == nil, "...and then nothing more runs")
Minimap.SetFrameStrata = nil
homeState()

-- pair: two seeds of one name, listed twice at the small sizes.
homeState(); wipeLines()
WoW.blipsAt = { { "Silverleaf", 20, -15 }, { "Silverleaf", -30, 25 } }
MS.seeds.pairA = { name = "Silverleaf", dx = 20, dy = -15, B = 140, kind = "herbs" }
MS.seeds.pairB = { name = "Silverleaf", dx = -30, dy = 25, B = 140, kind = "herbs" }
sum = nil
MS.start("pair", MS.pairBody, function(s) sum = s end)
WoW.advance(60)
check(sum ~= nil and sum:find("pairA normal:s[1,1,1] pairB normal:s[1,1,1] 24 centred:[2,2,2]", 1, true), "the pair round: each dot at normal size, and the name twice at 24 px centred: " .. tostring(sum))
check(has("lines [Silverleaf | Silverleaf]"), "the raw lines are logged")
check(same(orig), "the minimap is home after the pair round")
WoW.blipsAt = { { "Silverleaf", 20, -15 } }

-- mouselook: skipped without a seed; with one, a 5 s window and two reads every 0.25 s.
homeState(); wipeLines()
rawset(_G, "IsMouselooking", function() return true end)
rawset(_G, "IsMouseButtonDown", function(b) return b == "RightButton" end)
local keep = MS.seeds.single
MS.seeds.single = nil
sum = nil
MS.start("mouselook", MS.lookBody("right, still"), function(s) sum = s end)
WoW.advance(0.5)
check(sum == "no seed" and has("no hover seed: skipped"), "mouselook without a seed says so and skips")
MS.seeds.single = keep
sum = nil
MS.start("mouselook", MS.lookBody("right, still"), function(s) sum = s end)
WoW.advance(9)
check(has("right, still cursor 500,400 mouselooking true right true left false"), "the steering state is logged per frame")
local hitA, nA, hitB, nB = tostring(sum):match("normal (%d+)/(%d+) read the node, 24 px (%d+)/(%d+)")
check(nA and tonumber(nA) >= 8 and hitA == nA and hitB == nB, "placements every 0.5 s, each read r+1..r+4, normal and 24 px centred, all seeing the node: " .. tostring(sum))
local cursorLines = 0
for _, l in ipairs(lines()) do if l:find("right, still cursor", 1, true) then cursorLines = cursorLines + 1 end end
check(cursorLines >= 40 and cursorLines <= 300, "the per-frame lines are capped at 300 (" .. cursorLines .. ")")
check(same(orig), "the minimap is home after the steering round")

-- skin: no frame walk; Minimap's children, the container's children and our button.
local ring = CreateFrame("Frame", "TestRing", Minimap)
ring:SetPoint("CENTER", Minimap, "CENTER")
local container = CreateFrame("Frame", "TestContainer", UIParent)
local cchild = CreateFrame("Frame", "TestContainerChild", container)
cchild:SetPoint("CENTER", Minimap, "CENTER")
local cchild2 = CreateFrame("Frame", "TestContainerOther", container)
cchild2:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 5, -5)
local hiddenKid = CreateFrame("Frame", "TestHiddenKid", Minimap)
hiddenKid:Hide()
local manyKids = {}
for i = 1, 80 do manyKids[i] = CreateFrame("Frame", "TestKid" .. i, Minimap); manyKids[i]:SetPoint("CENTER", Minimap, "CENTER", i, 0) end
local walked = 0
CreateFrame("Button", "LibDBIcon10_NodeRadar", Minimap):SetPoint("TOPLEFT", Minimap, "TOPLEFT", 3, 4)
rawset(_G, "EnumerateFrames", function() walked = walked + 1 end)
rawset(_G, "MinimapCluster", setmetatable({}, { __index = function(_, k)
    if k == "MinimapContainer" then return container end
    return function() touched[#touched + 1] = k; return false end
end }))
homeState(); wipeLines()
sum = nil
MS.start("skin", MS.skinBody, function(s) sum = s end)
WoW.advance(12)
check(sum ~= nil, "the skin round finishes: " .. tostring(sum))
check(walked == 0, "the skin step never calls EnumerateFrames")
check(has("Minimap's parent chain"), "the parent chain is logged")
check(has("before: child of Minimap TestRing shown") and has("[anchored to Minimap]"), "Minimap's children are listed with their points")
check(has("away: child of Minimap TestRing shown"), "...and again while the map is away")
check(has("before: child of the container TestContainerChild shown") and has("TestContainerChild shown true visible true alpha 1 rect n/a; points CENTER>Minimap CENTER"), "the container's children are listed, with whether they are anchored to Minimap")
check(has("child of the container TestContainerOther shown") and has("TOPLEFT>UIParent"), "...each with its own points")
check(has("rect n/a") or has("onscreen"), "each frame's rect is reported")
local firstContainer, firstMinimap, firstButton
for i, l in ipairs(lines()) do
    if not firstContainer and l:find("before: child of the container", 1, true) then firstContainer = i end
    if not firstButton and l:find("before: our minimap button", 1, true) then firstButton = i end
    if not firstMinimap and l:find("before: child of Minimap", 1, true) then firstMinimap = i end
end
check(firstContainer and firstButton and firstMinimap and firstContainer < firstMinimap and firstButton < firstMinimap, "the container's children and our button are reported before Minimap's own")
check(not has("TestHiddenKid") and has("neither shown nor on screen: not listed"), "Minimap's children that are neither shown nor on screen are not listed")
check(has("our minimap button") and has("LibDBIcon10_NodeRadar shown"), "our minimap button's points and state are logged")
check(MS.maxCalls() <= 200, "no frame does more than 200 widget calls (" .. tostring(MS.maxCalls()) .. ")")
local away
for _, l in ipairs(lines()) do away = tonumber(l:match("away for ([%d.]+) s")) or away end
check(away and away >= 2, "the map stays away at least 2 s: " .. tostring(away))
check(same(orig), "the minimap is home after the skin round")

-- Never Hide()n or reparented; MinimapCluster is only asked IsProtected.
check(not WoW.methodsCalled["Minimap:Hide"], "Minimap is never Hide()n")
check(not WoW.methodsCalled["Minimap:SetParent"], "Minimap is never reparented")
check(not WoW.methodsCalled["Minimap:SetScale"], "Minimap's scale is never changed")
check(WoW.methodsCalled["Minimap:SetPoint"] and WoW.methodsCalled["Minimap:SetSize"], "(control) the minimap was moved and resized")
for _, k in ipairs(touched) do check(k == "IsProtected" or k == "GetParent", "MinimapCluster is only read: " .. k) end
MinimapCluster = nil

local uiFrame = CreateFrame("Frame", "SomeUIFrame", UIParent)
local worldFrame = CreateFrame("Frame", "WorldFrame", UIParent)
WoW.focus = uiFrame
rawset(_G, "GetMouseFoci", function() return { WoW.focus } end)
-- Ready gating through the panel: nothing measures before Ready is pressed.
homeState()
WoW.cursorOnMap, WoW.cursor = false, { 500, 400 }
WoW.methodsCalled = {}
fp("steps nr movescan")
WoW.advance(1.1)
local rec = FP.db.steps.records["NodeRadarProbe/movescan"]
check(rec.at == 2, "the round waits at the first Ready (step " .. tostring(rec.at) .. ")")
WoW.advance(20)
S, job = MS.state()
check(rec.at == 2 and job == nil and S == nil, "nothing measures until Ready is pressed")
check(not WoW.methodsCalled["Minimap:SetPoint"] and not WoW.methodsCalled["Minimap:SetSize"], "...and the minimap is not touched")
FP.Steps.Run()
check(rec.at == 3, "Ready moves to the countdown step")
WoW.advance(12)
S, job = MS.state()
check(job == nil and rec.at == 3, "the countdown does not run with the cursor on a UI frame (step " .. tostring(rec.at) .. ")")
WoW.focus = worldFrame
WoW.advance(1.1)
S, job = MS.state()
check(job == nil, "...and counts 3 s once the cursor is on the world")
WoW.advance(10)
check(rec.at == 4, "after the 3 s still-mouse countdown it measured and moved on (step " .. tostring(rec.at) .. ")")
check(same(orig), "...and the minimap is home")
WoW.advance(5)
check(rec.at == 4, "the hover step waits for a node under the cursor")
WoW.advance(200)
local res = rec.results[4]
check(rec.at ~= 4 and res and res.check == "FAIL", "a seed step that times out FAILS (check " .. tostring(res and res.check) .. ")")

done("test_probe_movescan")
