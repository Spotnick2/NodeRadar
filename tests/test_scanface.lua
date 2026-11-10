-- #103: the scan's stand-in face. While a burst borrows Minimap, a radar face of ours covers its
-- home under a copy of Blizzard's frame ring, at full in the same call as the borrow, held
-- HOLD s after the restore, then faded over FADE; never left up. Glass MiniMap's own stand-in
-- wins when it has one (ScanStandIn), and its 1.1.0, which has none, gets none of ours.

local HOME
local function fresh(off)
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
    WoW.blips = {}
    -- Blizzard's frame ring, as Blizzard_Minimap lays it out: MinimapBackdrop a child of
    -- Minimap, MinimapCompassTexture's atlas centred on the map (the stubs have no GetAtlas).
    MinimapBackdrop = CreateFrame("Frame", "MinimapBackdrop", Minimap)
    MinimapBackdrop._effScale = Minimap._effScale        -- a child's scale (the stubs don't inherit it)
    MinimapBackdrop:SetFrameLevel(5)
    MinimapBackdrop:SetFrameStrata("LOW")
    MinimapCompassTexture = MinimapBackdrop:CreateTexture(nil, "OVERLAY")
    MinimapCompassTexture:SetAtlas("UI-HUD-Minimap-Frame")
    MinimapCompassTexture.GetAtlas = function(t) return t._atlas end
    MinimapCompassTexture:SetSize(215, 226)
    MinimapCompassTexture:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
    MinimapCompassTextureUnderlay = MinimapBackdrop:CreateTexture(nil, "OVERLAY")
    MinimapCompassTextureUnderlay.GetAtlas = function(t) return t._atlas end
    MinimapCompassTextureUnderlay:SetSize(215, 226)
    MinimapCompassTextureUnderlay:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
    MinimapCompassTextureUnderlay:Hide()                 -- the fixed mode: no underlay
    local NR = loadAddon({ db = { moveScan = not off, moveScanAsked = true } })
    NR.db.learn = false
    NR.MoveScan.PLACEMENTS = 1
    HOME = { Minimap:GetCenter() }
    return NR
end

local function frames(n)
    for _ = 1, n or 1 do
        WoW.now = WoW.now + 0.02
        WoW.tick(0.02)
    end
end
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
local function near(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.01 end
local function shown(NR)
    local f = NR.ScanFace._test.face()
    return f ~= nil and f:IsShown() == true
end

--------------------------------------------------------------------------------
-- 1. No Glass MiniMap: ours, at full in the same frame as the borrow, over the home.
--------------------------------------------------------------------------------

local NR = fresh()
check(NR.ScanFace._test.face() == nil, "(control) nothing built before a scan")
check(untilBorrowed(), "(control) a burst starts")
local face = NR.ScanFace._test.face()
check(shown(NR) and face:GetAlpha() == 1 and NR.ScanFace.State() == "full",
    "the borrow's own frame: the face at full while the map is away")
check(Minimap:GetAlpha() == 0, "(control) ...and the map invisible in that same frame")
local k = Minimap._effScale / UIParent:GetEffectiveScale()
local p = { face:GetPoint(1) }
check(p[1] == "CENTER" and p[2] == UIParent and p[3] == "BOTTOMLEFT" and near(p[4], HOME[1] * k) and near(p[5], HOME[2] * k),
    "centred on the map's home, in UIParent's units (its effective scale converted)")
check(near(face:GetWidth(), 198 * k) and near(face:GetHeight(), 198 * k), "...at the map's size")
check(face:IsMouseEnabled() == false and face:GetParent() == UIParent and face:GetName() == nil,
    "mouse off, an unnamed frame of ours on UIParent")
check(face:GetFrameStrata() == "LOW" and face:GetFrameLevel() == 5, "stacked where Blizzard's ring is")
local body, lines, sweep, rings = NR.ScanFace._test.parts()
check(rings[2]:IsShown() and rings[2]._atlas == "UI-HUD-Minimap-Frame", "Blizzard's frame ring copied: its atlas")
check(near(rings[2]:GetWidth(), 215 * k) and near(rings[2]:GetHeight(), 226 * k), "...its size")
local rp = { rings[2]:GetPoint(1) }
check(rp[2] == UIParent and near(rp[4], HOME[1] * k) and near(rp[5], HOME[2] * k), "...its centre")
check(not rings[1]:IsShown(), "the underlay not drawn when Blizzard's isn't (the fixed mode)")
check(sweep._blend == "ADD", "the sweep drawn additively")

local r0 = sweep._rotation
frames(1)
check(type(sweep._rotation) == "number" and sweep._rotation ~= r0, "the sweep turns every frame")
runBurst()
check(NR.MoveScan._test.burst() == nil and Minimap:GetAlpha() == 1, "(control) the burst over, the map home")
check(shown(NR) and face:GetAlpha() == 1 and NR.ScanFace.State() == "hold", "held at full over the returned map")
frames(math.floor(NR.ScanFace.HOLD / 0.02) - 3)
check(shown(NR) and face:GetAlpha() == 1, "...for HOLD seconds")
frames(6)
check(shown(NR) and face:GetAlpha() < 1 and face:GetAlpha() > 0, "then fading")
frames(math.ceil(NR.ScanFace.FADE / 0.02) + 1)
check(not shown(NR) and NR.ScanFace.State() == nil and face:GetAlpha() == 1, "...then gone, its alpha reset")

--------------------------------------------------------------------------------
-- 2. A borrow during the hold brings it straight back; never left up; a hidden map hides it.
-- (The scan off: the face driven directly.)
--------------------------------------------------------------------------------

NR = fresh(true)
NR.ScanFace.Begin("none")
NR.ScanFace.End()
frames(math.floor((NR.ScanFace.HOLD + NR.ScanFace.FADE / 2) / 0.02))
face = NR.ScanFace._test.face()
check(face:GetAlpha() < 1, "(control) fading")
NR.ScanFace.Begin("none")
check(shown(NR) and face:GetAlpha() == 1 and NR.ScanFace.State() == "full", "a borrow while it fades: back at full")
frames(math.ceil((NR.ScanFace.MAX + NR.ScanFace.HOLD + NR.ScanFace.FADE) / 0.02) + 2)
check(not shown(NR), "never left up: MAX seconds without an end, then held and faded anyway")

NR.ScanFace.Begin("none")
NR.ScanFace.End()
frames(2)
Minimap:Hide()
frames(1)
check(not shown(NR) and NR.ScanFace.State() == nil, "the map hidden during the hold: gone at once")
Minimap:Show()

--------------------------------------------------------------------------------
-- 3. Nothing to stand in for: the map hidden or invisible at home; Blizzard's ring hidden.
--------------------------------------------------------------------------------

NR = fresh(true)
Minimap:SetAlpha(0)
NR.ScanFace.Begin("none")
check(not shown(NR), "an invisible map at home (a skin's choice): no face")
Minimap:SetAlpha(1)
Minimap:Hide()
NR.ScanFace.Begin("none")
check(not shown(NR), "a hidden map: no face")
Minimap:Show()
MinimapCompassTexture:Hide()
NR.ScanFace.Begin("none")
rings = select(4, NR.ScanFace._test.parts())
check(shown(NR) and not rings[2]:IsShown(), "Blizzard's ring hidden (a skin): the face without it")
MinimapCompassTexture:Show()
MinimapBackdrop:SetAlpha(0)
NR.ScanFace.Begin("none")
check(shown(NR) and not rings[2]:IsShown(), "its backdrop at alpha 0: not copied either")
MinimapBackdrop:SetAlpha(1)
MinimapCompassTextureUnderlay:SetAtlas("UI-HUD-Minimap-Frame-Circle")
MinimapCompassTextureUnderlay:Show()
NR.ScanFace.Begin("none")
check(rings[1]:IsShown() and rings[1]._atlas == "UI-HUD-Minimap-Frame-Circle", "the rotating mode's underlay copied too")

--------------------------------------------------------------------------------
-- 4. Glass MiniMap: its stand-in wins; 1.1.0 (no ScanStandIn) gets none.
--------------------------------------------------------------------------------

local function glass(standIn)
    local g = { PUBLIC_API_VERSION = 1, ScanStandIn = standIn }
    g.ScanBegin = function() return true end
    g.ScanEnd = function() end
    rawset(_G, "GlassMiniMap", g)
    WoW.loadedAddons = { GlassMiniMap = true }
end
NR = fresh()
glass(function() return true end)
check(untilBorrowed() and not shown(NR), "Glass MiniMap draws its own (ScanStandIn true): none of ours")
runBurst()
NR = fresh()
glass(function() return false end)
check(untilBorrowed() and shown(NR), "ScanStandIn false (its ring failed): ours")
runBurst()
NR = fresh()
glass(nil)
check(untilBorrowed() and not shown(NR), "Glass MiniMap 1.1.0, no ScanStandIn: none (ours would stack over its ring)")
runBurst()
NR = fresh()
glass(function() error("boom") end)
check(untilBorrowed() and not shown(NR), "a throwing ScanStandIn: none")
runBurst()
check(NR.MoveScan.stats.valid == 1 and Minimap:GetAlpha() == 1, "(control) ...the scan unharmed")
glass(function() return false end)
NR.ScanFace.Begin("none")
check(shown(NR), "(control) shown")
NR.ScanFace.Begin("v1", GlassMiniMap)
check(shown(NR), "(control) Glass without a stand-in: still ours")
GlassMiniMap.ScanStandIn = function() return true end
NR.ScanFace.Begin("v1", GlassMiniMap)
check(not shown(NR), "Glass's stand-in now ready: ours gone at once, never stacked")
rawset(_G, "GlassMiniMap", nil)
WoW.loadedAddons = nil

--------------------------------------------------------------------------------
-- 5. An interrupted burst still holds and fades; a failure inside never stops the scan.
--------------------------------------------------------------------------------

NR = fresh()
check(untilBorrowed(), "(control) a burst")
frames(1)
WoW.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
check(NR.MoveScan._test.burst() == nil or NR.MoveScan._test.burst().phase == "settle", "(control) the click ends it")
check(NR.ScanFace.State() == "hold", "an interrupted burst: held, then faded")
frames(math.ceil((NR.ScanFace.HOLD + NR.ScanFace.FADE) / 0.02) + 2)
check(not shown(NR), "...gone")

NR = fresh()
local create = CreateFrame
CreateFrame = function(...)
    if select(2, ...) == nil and select(3, ...) == UIParent and select(1, ...) == "Frame" then error("no frames") end
    return create(...)
end
check(untilBorrowed(), "a face that fails to build: the burst still starts")
CreateFrame = create
runBurst()
check(NR.failures["scan face"] ~= nil, "...the failure recorded (/nr failures)")
check(Minimap:GetAlpha() == 1 and NR.MoveScan.stats.valid == 1, "...and the scan read and restored as usual")

done("test_scanface")
