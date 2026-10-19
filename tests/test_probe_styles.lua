-- The styles procedure (/fp steps nr styles, #41): NodeRadar's own looks in
-- game. Following the minimap gives glass with Glass MiniMap and bronze
-- without; each style and size is set and read back; our arrow, the hover,
-- a dimmed node, the rim, the Options page, the cost per style; the player's
-- settings put back. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

-- LibGlass-1.0 as Glass MiniMap loads it, faked.
local discs = 0
local lib = { New = function() return {
    Disc = function(host) discs = discs + 1; return { top = CreateFrame("Frame", nil, host) } end,
    Mask = function(host) return host:CreateTexture() end,
} end }
noGlass = false
rawset(_G, "LibStub", setmetatable({}, { __call = function(_, major)
    if noGlass then return nil end
    if major == "LibGlass-1.0" and WoW.loadedAddons and WoW.loadedAddons.GlassMiniMap then return lib, 11 end
end }))
WoW.loadedAddons = { GlassMiniMap = true }

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.db.iconSize = "large"                                   -- the player's own, to be put back
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB

local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 30 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/styles"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

local ABOVE = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16|t"
local blips = { { "Silverleaf", 30, 20, kind = "herbs" } }
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        WoW.blips = blips
        WoW.advance(0.1)
    end
end
local function look() return NR.Icons._test.look() end

walk(1)
fp("steps nr styles")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.icons, true, "NodeRadar's icons on")
walk(3)
eq(result(2).status, "done", "auto with Glass MiniMap: " .. detail(2))
eq(look().style, "glass", "...glass")
check(discs > 0, "...discs built")
settle()
S.Answer(true)                                             -- 3

-- Each style and size, set and read back.
-- (A wait step runs on as soon as its screenshot is taken: each look is
-- checked in what its step recorded.)
local want = { [4] = "glass 10", [5] = "glass 14", [7] = "bronze 10", [8] = "bronze 12", [9] = "bronze 14",
               [11] = "plain 12" }
poll(); settle()
eq(record().at, 6, "glass small and large shown, then asked")
S.Answer(true)                                             -- 6
poll(); settle()
eq(record().at, 10, "bronze's three sizes shown, then asked")
S.Answer(true)                                             -- 10
poll(); settle()
for i, w in pairs(want) do
    eq(result(i).status, "done", "step " .. i .. ": " .. detail(i))
    check(detail(i):find(w, 1, true), "...the look read back: " .. w)
end

-- Our arrow: waits for a node above.
poll()
eq(record().at, 12, "waits for an arrow")
eq(look().style, "bronze", "...in bronze")
blips[1].text = ABOVE .. "Silverleaf"
walk(3)
eq(result(12).status, "done", "an arrow: " .. detail(12))
check(detail(12):find("Silverleaf above"), "...Silverleaf above")
blips[1].text = nil
settle()
S.Answer(true)                                             -- 13
settle()

-- Hovering through the frame.
local r = NR.Icons._test.records()[1]
rawset(_G, "GameTooltip", CreateFrame("Frame"))
rawset(_G, "GameTooltipTextLeft1", GameTooltip:CreateFontString())
GameTooltipTextLeft1:SetText("Silverleaf")
GameTooltip:Show()
WoW.mouseOver = r.frame
poll()
eq(result(14).status, "done", "hovering: " .. detail(14))
WoW.mouseOver = nil
settle()
S.Answer(true)                                             -- 15
settle()
S.Skip()                                                   -- 16: no dimmed node here

-- The rim: a node walked past the edge fades.
eq(record().at, 17, "waits for an icon fading at the edge")
poll()
eq(result(17).status, nil, "...an icon in full view isn't one")
local function east(yd)                                    -- the player east: the node goes west
    WoW.pos[2] = WoW.pos[2] - yd
    blips[1][2] = blips[1][2] - yd / (C_Minimap.GetViewRadius() / 99)
end
east((30 + 80) * C_Minimap.GetViewRadius() / 99)          -- the node near the west edge, at once
for _ = 1, 100 do
    east(0.5)
    walk(0.2)
    if result(17).status then break end
end
eq(result(17).status, "done", "the rim: " .. detail(17))
settle()
S.Answer(true)                                             -- 18
settle()

-- The Options page.
poll()
eq(result(19).status, nil, "waits for the page")
NR.Options._test.panel:Show()
poll()
eq(result(19).status, "done", "the page: " .. detail(19))
settle()
S.Answer(true)                                             -- 20
NR.Options._test.panel:Hide()
settle()

-- The cost, off, glass, bronze.
blips[1][2] = 30
WoW.speed = 7
walk(62)
eq(result(21).status, "done", "off: " .. detail(21))
eq(db.icons.cost["styles off"].icons, false, "...icons were off for it")
eq(db.icons.cost["styles off"].style, "off", "...recorded as off")
walk(62)
eq(result(22).status, "done", "glass: " .. detail(22))
eq(db.icons.cost["styles glass"].style, "glass", "...glass recorded")
walk(62)
eq(result(23).status, "done", "bronze: " .. detail(23))
eq(db.icons.cost["styles bronze"].style, "bronze", "...bronze recorded")
WoW.speed = 0

-- Blizzard's minimap: auto is bronze.
eq(record().at, 24, "asks to turn Glass MiniMap off")
S.Skip()                                                   -- 24: the reload
noGlass = true                                             -- Glass MiniMap on, its LibGlass gone: bronze
NR.Icons._test.reset()
walk(3)
eq(look().style, "bronze", "Glass MiniMap on without glass: bronze")
eq(result(25).status, nil, "...still Glass MiniMap's minimap: waits")
noGlass = false
NR.Icons._test.reset()
walk(3)
eq(look().style, "glass", "glass again")
WoW.loadedAddons = nil                                     -- off, but read as on until the reload
walk(3)
eq(result(25).status, nil, "Glass MiniMap off, the look still glass: waits")
NR.Icons._test.reset()                                     -- what the reload does
walk(3)
eq(result(25).status, "done", "auto without Glass MiniMap: " .. detail(25))
eq(look().style, "bronze", "...bronze")
settle()
S.Answer(true)                                             -- 26
settle()
S.Skip()                                                   -- 27: the reload
eq(result(28).status, "done", "put back: " .. detail(28))
eq(rawget(NR.db, "iconSize"), "large", "the player's size back")
eq(rawget(NR.db, "iconStyle"), nil, "...the style back to the default")
eq(rawget(NR.db, "icons"), nil, "...icons back to the default")
eq(record().at, 29, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_styles")
