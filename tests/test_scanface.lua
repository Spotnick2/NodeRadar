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
check(rp[2] == face and rp[3] == "CENTER" and near(rp[4], 0) and near(rp[5], 0),
    "...its centre: on the face's (the map's), anchored to the face so a preview moves it too")
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

-- A minimap faded at rest (Glass MiniMap's fader: its container at 60%): the face as translucent
-- as the map was at home, held and faded from there, not an opaque pulse at each look.
NR = fresh()
local realEA = Minimap.GetEffectiveAlpha
Minimap.GetEffectiveAlpha = function() return 0.6 end
check(untilBorrowed(), "(control) a burst, the map at 60% at home")
local faded = NR.ScanFace._test.face()
check(near(faded:GetAlpha(), 0.6), "the face at the map's 60% while it's away (got " .. tostring(faded:GetAlpha()) .. ")")
runBurst()
check(near(faded:GetAlpha(), 0.6), "...held at 60%")
frames(math.floor(NR.ScanFace.HOLD / 0.02) + 4)
check(faded:GetAlpha() < 0.6 and faded:GetAlpha() > 0, "...fading from 60%")
Minimap.GetEffectiveAlpha = realEA
frames(40)

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

--------------------------------------------------------------------------------
-- #117: the real ground. Outdoors on a continent with tiles, the face draws the minimap's tiles
-- around the player (Data/MinimapTiles.lua, the shipped table), the arrow on top, the radar's
-- lines and sweep hidden; anywhere else the radar face, and SF.Ground() says why.
--------------------------------------------------------------------------------

-- The player in the middle of Kalimdor tile (x, y), a quarter in from its north-west corner.
local T = 1600 / 3
local function standIn(x, y, inst)
    WoW.pos = { (32 - y - 0.25) * T, (32 - x - 0.25) * T, inst or 1 }
end
local function visibleTiles(NR)
    local _, tiles = NR.ScanFace._test.ground()
    local list = {}
    for _, t in ipairs(tiles or {}) do if t:IsShown() then list[#list + 1] = t end end
    return list
end

NR = fresh()
local TX, TY = 40, 30                                    -- a Kalimdor tile the table has
check(NR.MINIMAP_TILES[1][TX * 64 + TY] ~= nil and NR.MINIMAP_TILES[1][TX * 64 + TY + 1] ~= nil,
    "(control) the shipped table has Kalimdor tile 40_30 and 40_31")
standIn(TX, TY)
check(NR.ScanFace.Ground() == "tiles", "outdoors on Kalimdor with tiles: the ground can be drawn")
check(untilBorrowed(), "(control) a burst")
local _, _, sweep0 = NR.ScanFace._test.parts()
local list = visibleTiles(NR)
local own
for _, t in ipairs(list) do if t._file == NR.MINIMAP_TILES[1][TX * 64 + TY] then own = t end end
check(NR.ScanFace.Grounded() and #list >= 1 and own ~= nil, "the player's own tile drawn, by its FileDataID")
-- 150 yards across half a 198-unit map at scale 1.2 (UIParent 1): its top-left a quarter tile
-- up and to the left of the face's centre.
local perYard = 198 * 1.2 / 2 / 150
local p, rel, rp, ox, oy = own:GetPoint(1)
check(p == "TOPLEFT" and rp == "CENTER" and near(ox, -0.25 * T * perYard) and near(oy, 0.25 * T * perYard),
    "the tile placed from UnitPosition: x east, y south (" .. tostring(ox) .. ", " .. tostring(oy) .. ")")
check(near(own:GetWidth(), T * perYard), "a tile's size: 533 yards at the map's scale")
check(not sweep0:IsShown(), "the ground drawn: the radar's sweep hidden")
local _, _, arrow = NR.ScanFace._test.ground()
check(arrow:IsShown(), "the player arrow on top")
runBurst()

-- Forever's own open-world maps (Tools/export_tiles.py --maps): Zephras Isle (Map 2991) has its
-- tiles too, so the ground is drawn there, not the radar face (the owner, 2026-11-12).
NR = fresh()
local zeph = NR.MINIMAP_TILES[2991]
local zk
for k in pairs(zeph or {}) do zk = k; break end
check(zk ~= nil, "(control) the shipped table has Zephras Isle (2991)")
if zk then
    standIn(math.floor(zk / 64), zk % 64, 2991)
    check(NR.ScanFace.Ground() == "tiles", "on Zephras Isle: the ground can be drawn (got " .. tostring(NR.ScanFace.Ground()) .. ")")
end
for _, inst in ipairs({ 37, 2995, 2980 }) do
    check(NR.MINIMAP_TILES[inst] ~= nil, "(control) the table has Forever's map " .. inst)
end

-- Fallbacks: the radar face, and why.
local function fallsBack(setup, why)
    NR = fresh()
    standIn(TX, TY)
    setup()
    check(NR.ScanFace.Ground() == why, why .. ": Ground() says so (got " .. tostring(NR.ScanFace.Ground()) .. ")")
    untilBorrowed()
    local _, _, sw = NR.ScanFace._test.parts()
    check(not NR.ScanFace.Grounded() and #visibleTiles(NR) == 0 and sw:IsShown(), why .. ": the radar face instead")
    runBurst()
end
fallsBack(function() WoW.indoors = true end, "indoors")
fallsBack(function() WoW.cvars.rotateMinimap = "1" end, "the map rotates or is unreadable")
fallsBack(function() standIn(TX, TY, 530) end, "no tiles for this map")
fallsBack(function() NR.ScanFace.GROUND = false end, "off")
-- The radar look chosen in Options (scanRadar): the radar face with its sweep even where the
-- ground could be drawn, and nothing loaded for it; off again, the ground.
fallsBack(function() NR.db.scanRadar = true end, "the radar look (Options)")
NR = fresh()
standIn(TX, TY)
NR.db.scanRadar = true
check(NR.ScanFace.RadarLook() and NR.ScanFace.Warm(GetTime() + 100, "none") == false, "the radar look: no tiles loaded ahead")
NR.db.scanRadar = false
check(not NR.ScanFace.RadarLook() and NR.ScanFace.Ground() == "tiles", "the radar look off: the ground again")
-- A spot with no tile at all (the ocean beyond the table): no ground, the radar face.
NR = fresh()
WoW.pos = { (32 - 63.5) * T, (32 - 63.5) * T, 1 }
untilBorrowed()
check(not NR.ScanFace.Grounded(), "no tile in view: the radar face")
runBurst()
-- The ground failing: recorded, the radar face, the scan goes on.
NR = fresh()
standIn(TX, TY)
NR.ScanFace.TileID = function() error("broken table") end
check(untilBorrowed(), "a ground that throws: the burst still starts")
check(NR.failures["scan face ground"] ~= nil and not NR.ScanFace.Grounded(), "...recorded, the radar face")
runBurst()

-- Codex's round: the shape, the stacking, the loading.
-- Not the stock minimap (its ring hidden, or another atlas) and no shape said: no ground.
local UNKNOWN = "the minimap's shape is unknown"
fallsBack(function() MinimapCompassTexture:Hide() end, UNKNOWN)
fallsBack(function() MinimapCompassTexture:SetAtlas("Some-Skin-Square-Frame") end, UNKNOWN)
-- Shown but not drawn (Codex: a skin fades the stock ring and keeps its atlas): no ground either.
fallsBack(function() MinimapCompassTexture:SetAlpha(0) end, UNKNOWN)
fallsBack(function() MinimapBackdrop:SetAlpha(0) end, UNKNOWN)
-- A shape-teller that throws, or answers nonsense: still unknown.
fallsBack(function() MinimapCompassTexture:Hide(); GetMinimapShape = function() error("x") end end, UNKNOWN)
GetMinimapShape = nil
fallsBack(function() MinimapCompassTexture:Hide(); GetMinimapShape = function() return "HEXAGON" end end, UNKNOWN)
GetMinimapShape = nil

-- Square minimaps (the owner, 2026-11-10: the round face over a square skin's map). The face
-- takes the map's shape: a square skin's map a square plate, cropped as the skin crops it.
local SQ_BODY, SQ_MASK = "Interface\\Buttons\\WHITE8X8", "Interface\\ChatFrame\\ChatFrameBackground"
local function shaped(setup)
    NR = fresh()
    standIn(TX, TY)
    MinimapCompassTexture:Hide()                        -- a skin hides Blizzard's ring
    setup()
    frames(5)                                           -- the warm-up loads the tiles
    untilBorrowed()
    local f = NR.ScanFace._test.face()
    local b, l, s = NR.ScanFace._test.parts()
    local c = NR.ScanFace._test.ground()
    local m = c and select(1, c:GetRegions())
    return f, b, l, s, m
end
local function cleanShapes() GetMinimapShape, EllesmereUI, Minimap.GetHitRectInsets = nil, nil, nil end
local kS = 1.2                                          -- the stubs' map scale, UIParent 1

-- A skin that says SQUARE (LibDBIcon's GetMinimapShape).
local f, b, l, s, m = shaped(function() GetMinimapShape = function() return "SQUARE" end end)
check(select(1, NR.ScanFace.Shape()) == "square" and select(3, NR.ScanFace.Shape()) == "declared",
    "GetMinimapShape SQUARE: a square map, declared")
check(b._file == SQ_BODY, "a square map: a square plate, not the disc (" .. tostring(b._file) .. ")")
check(near(f:GetWidth(), 198 * kS) and near(f:GetHeight(), 198 * kS), "...the map's whole square")
check(m and m._file == SQ_MASK and m._atlas == nil, "...the ground under a square mask")
check(NR.ScanFace.Grounded() and NR.ScanFace.lastGround == "tiles", "...the shape known: the real ground drawn")
runBurst()
-- Back to the stock map: the disc and the round mask again.
cleanShapes()
MinimapCompassTexture:Show()
check(untilBorrowed(600), "(control) the next look")
check(b._file and b._file:find("ScanDisc") and m._atlas == NR.ScanFace.MASK_ATLAS,
    "the stock map again: the disc and Blizzard's round mask")
runBurst()

-- A declaration wins over the stock ring (a square skin can leave Blizzard's ring over its map);
-- with none, the ring drawn says stock.
NR = fresh()
check(select(1, NR.ScanFace.Shape()) == "round" and select(3, NR.ScanFace.Shape()) == "stock", "the stock ring drawn: round, stock")
GetMinimapShape = function() return "SQUARE" end
check(select(1, NR.ScanFace.Shape()) == "square" and select(3, NR.ScanFace.Shape()) == "declared",
    "SQUARE declared with the ring still drawn: square")
cleanShapes()

-- Mixed shapes by their quarters: three round ones a round map, else square.
MinimapCompassTexture:Hide()
GetMinimapShape = function() return "TRICORNER-BOTTOMLEFT" end
check(select(1, NR.ScanFace.Shape()) == "round", "TRICORNER: three round quarters, round")
GetMinimapShape = function() return "CORNER-TOPLEFT" end
check(select(1, NR.ScanFace.Shape()) == "square", "CORNER: one round quarter, square")
GetMinimapShape = function() return "side-left" end
check(select(1, NR.ScanFace.Shape()) == "square", "SIDE (any case): two round quarters, square")
GetMinimapShape = function() return "ROUND" end
check(select(1, NR.ScanFace.Shape()) == "round" and select(3, NR.ScanFace.Shape()) == "declared", "ROUND declared: round")
cleanShapes()
MinimapCompassTexture:Show()

-- EllesmereUI (no GetMinimapShape): its module's MinimapShape(); rectangular is a square map
-- cropped top and bottom by its hit rect insets (a quarter of 198 in all: 24.75 each side).
local function eui(shape)
    EllesmereUI = { _ModuleNS = { EllesmereUIMinimap = { MinimapShape = function() return shape end } } }
end
f, b, l, s, m = shaped(function()
    eui("rectangular")
    Minimap.GetHitRectInsets = function() return 0, 0, 24.75, 24.75 end
end)
check(select(3, NR.ScanFace.Shape()) == "EllesmereUI" and b._file == SQ_BODY, "EllesmereUI rectangular: a square plate")
check(near(f:GetWidth(), 198 * kS) and near(f:GetHeight(), (198 - 49.5) * kS),
    "...cropped as its skin crops it (" .. tostring(f:GetHeight()) .. ")")
check(near(l:GetWidth(), (198 - 49.5) * kS) and near(s:GetHeight(), (198 - 49.5) * kS),
    "...the radar's rings and sweep a centred square within it, not stretched")
check(NR.ScanFace.Grounded(), "...the real ground")
runBurst()
cleanShapes()
f, b = shaped(function() eui("circle") end)
check(select(1, NR.ScanFace.Shape()) == "round" and b._file:find("ScanDisc"), "EllesmereUI circle: the disc")
check(NR.ScanFace.Grounded(), "...and the ground, round")
runBurst()
-- A square EllesmereUI over a GetMinimapShape another addon left saying ROUND: EllesmereUI's.
cleanShapes()
eui("square")
GetMinimapShape = function() return "ROUND" end
check(select(1, NR.ScanFace.Shape()) == "square", "EllesmereUI's own shape first")
-- No crop without both insets (a skin's hit rect trimmed on one side only).
Minimap.GetHitRectInsets = function() return 0, 0, 20, 0 end
check(select(2, NR.ScanFace.Shape()) == 0, "one inset only: no crop")
cleanShapes()
MinimapCompassTexture:Show()
-- No warm-up while a look couldn't come (Codex: no blocking loads in combat or loading).
local function noWarm(set, unset, why)
    NR = fresh()
    standIn(TX, TY)
    set()
    frames(80)
    local _, tw = NR.ScanFace._test.ground()
    unset()
    check(tw == nil or tw[1].id == nil, why .. ": no tile loaded")
end
noWarm(function() WoW.combat = true end, function() WoW.combat = false end, "in combat")
noWarm(function() NodeRadar.Learn.loading = true end, function() NodeRadar.Learn.loading = false end, "loading")
noWarm(function() WoW.tracking[1].active = false end, function() WoW.tracking[1].active = true end, "no tracking")
noWarm(function() WoW.indoors = true end, function() WoW.indoors = false end, "indoors (no ground to draw)")
-- A frame that loaded a tile starts no borrow (the load isn't charged to its budget).
NR = fresh()
standIn(TX, TY)
local warmedFrame, borrowFrame
local realWarm2 = NR.ScanFace.Warm
local f0 = 0
NR.ScanFace.Warm = function(...)
    local loaded = realWarm2(...)
    if loaded and not warmedFrame then warmedFrame = f0 end
    return loaded
end
for i = 1, 200 do
    f0 = i
    frames(1)
    if NR.MoveScan._test.burst() and not borrowFrame then borrowFrame = i end
end
NR.ScanFace.Warm = realWarm2
check(warmedFrame and borrowFrame and borrowFrame > warmedFrame, "the warm-up's frame borrows nothing; a later one does")
runBurst()
-- A load on the very frame a look is due: that frame borrows nothing (the player crossing into a
-- new tile every frame, the warm-up unthrottled, so every frame loads).
NR = fresh()
check(untilBorrowed(), "(control) a first look")
runBurst()
NR.ScanFace.WARM_EVERY = 0
local coincide, loads = 0, 0
for i = 1, 400 do
    standIn(TX, TY + (i % 2))
    local before = NR.MoveScan._test.burst()
    local loadedNow = false
    local w = NR.ScanFace.Warm
    NR.ScanFace.Warm = function(...) local r = w(...); loadedNow = loadedNow or r; return r end
    frames(1)
    NR.ScanFace.Warm = w
    if loadedNow then loads = loads + 1 end
    if loadedNow and not before and NR.MoveScan._test.burst() then coincide = coincide + 1 end
end
NR.ScanFace.WARM_EVERY = 1
check(loads > 100 and coincide == 0, "a frame that loaded a tile never starts a borrow (" .. loads .. " loads, " .. coincide .. " together)")
runBurst()
-- A warm-up that loads one tile and has the next refused (or throws) still did the work: that
-- frame borrows nothing either (Codex, third round). SetTexture calls observed directly.
NR = fresh()
check(untilBorrowed(), "(control) a first look")
runBurst()
local _, tr = NR.ScanFace._test.ground()
local calls, callsThisFrame = 0, 0
for _, t in ipairs(tr) do
    local real = t.SetTexture
    t.SetTexture = function(self, id)
        calls, callsThisFrame = calls + 1, callsThisFrame + 1
        if calls % 2 == 0 then return false end          -- every second one refused
        return real(self, id)
    end
end
NR.ScanFace.WARM_EVERY = 0
local together, tried = 0, 0
for i = 1, 400 do
    standIn(TX, TY + (i % 2))
    callsThisFrame = 0
    local before = NR.MoveScan._test.burst()
    frames(1)
    if callsThisFrame > 0 then tried = tried + 1 end
    if callsThisFrame > 0 and not before and NR.MoveScan._test.burst() then together = together + 1 end
end
NR.ScanFace.WARM_EVERY = 1
check(tried > 100 and together == 0, "a frame whose warm-up tried a load, refused or not, starts no borrow ("
    .. tried .. " frames tried, " .. together .. " borrowed)")
runBurst()
-- No ground possible (indoors): the warm-up builds nothing at all.
NR = fresh()
standIn(TX, TY)
WoW.indoors = true
local dialog = CreateFrame("Frame", nil, UIParent)
dialog:SetFrameStrata("DIALOG")
WoW.focus = dialog                                      -- no look either: nothing else builds the face
frames(80)
check(NR.ScanFace._test.face() == nil, "indoors, no look: the warm-up built nothing")
WoW.focus, WoW.indoors = nil, false
-- The arrow and the ring copies draw over the tiles: a frame above the tiles' frame.
NR = fresh()
standIn(TX, TY)
untilBorrowed()
local clipF, _, arrowT = NR.ScanFace._test.ground()
local _, _, _, ringsT = NR.ScanFace._test.parts()
check(arrowT:GetParent() ~= clipF and arrowT:GetParent():GetFrameLevel() > clipF:GetFrameLevel()
    and ringsT[2]:GetParent() == arrowT:GetParent(), "the arrow and the ring sit on a frame above the tiles")
runBurst()
-- Tiles never loaded inside a borrow: only ones the warm-up loaded before it are drawn.
NR = fresh()
standIn(TX, TY)
local realWarm = NR.ScanFace.Warm
NR.ScanFace.Warm = function() end                      -- never warmed
untilBorrowed()
check(not NR.ScanFace.Grounded() and NR.ScanFace.lastGround == "tiles not loaded yet",
    "tiles not loaded before the borrow: the radar face (" .. tostring(NR.ScanFace.lastGround) .. ")")
local _, tilesT = NR.ScanFace._test.ground()
check(tilesT[1].id == nil, "...and nothing loaded inside the borrow")
runBurst()
NR.ScanFace.Warm = realWarm
-- A texture not loaded yet (IsObjectLoaded false): the radar face this time.
NR = fresh()
standIn(TX, TY)
frames(5)                                               -- the warm-up runs
local _, tl = NR.ScanFace._test.ground()
check(tl and tl[1].id ~= nil, "(control) the warm-up loaded the tiles, outside any borrow")
for _, t in ipairs(tl) do t.IsObjectLoaded = function() return false end end
untilBorrowed()
check(not NR.ScanFace.Grounded() and NR.ScanFace.lastGround == "tiles still loading", "a tile still loading: the radar face")
runBurst()
-- Glass MiniMap drawing its own stand-in: no warm-up either.
NR = fresh()
standIn(TX, TY)
GlassMiniMap = { PUBLIC_API_VERSION = 1, ScanBegin = function() return true end, ScanEnd = function() end,
                 ScanStandIn = function() return true end }
WoW.addonsLoaded = WoW.addonsLoaded or {}
local realLoaded = C_AddOns.IsAddOnLoaded
C_AddOns.IsAddOnLoaded = function(name) return name == "GlassMiniMap" or realLoaded(name) end
frames(80)
local _, tg = NR.ScanFace._test.ground()
check(tg == nil or tg[1].id == nil, "Glass MiniMap draws its own: no tiles loaded")
C_AddOns.IsAddOnLoaded, GlassMiniMap = realLoaded, nil
runBurst()

-- Preview: beside the home, for its seconds, without a borrow; never over a borrow's face.
NR = fresh()
standIn(TX, TY)
check(untilBorrowed(), "(control) a burst")
local okB, whyB = NR.ScanFace.Preview(-250, 0, 1)
check(okB == false and whyB == "a borrow's face is up", "no preview over a borrow's face")
runBurst()
frames(math.ceil((NR.ScanFace.HOLD + NR.ScanFace.FADE) / 0.02) + 2)
local bursts0 = NR.MoveScan.stats.bursts
local ok, how = NR.ScanFace.Preview(-250, 0, 1)
local f = NR.ScanFace._test.face()
local fx0 = select(4, f:GetPoint(1))
check(ok == true and how == "tiles" and NR.ScanFace.State() == "preview" and f:IsShown(), "Preview: shown, with the ground")
check(near(fx0, HOME[1] * 1.2 - 250), "...250 units left of the home (" .. tostring(fx0) .. ")")
local _, _, _, ringsP = NR.ScanFace._test.parts()
check(ringsP[2]:IsShown() and select(2, ringsP[2]:GetPoint(1)) == f, "...its ring copy moves with it (anchored to the face)")
check(Minimap:GetAlpha() == 1 and NR.MoveScan.stats.bursts == bursts0, "...the minimap untouched")
frames(math.ceil(1 / 0.02) + 2)
check(not f:IsShown() and NR.ScanFace.State() == nil, "...gone after its seconds")

done("test_scanface")
