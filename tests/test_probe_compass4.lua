-- The compass4 procedure (/fp steps nr compass4, #29): NodeRadar's own look
-- in game: glass at each size, bronze, the icon alone, the tooltip, clicks and
-- a camera drag on the disc, pointing behind clear of the pill, Edit Mode,
-- combat, a ride; the compass, its size and the icons' frame put back. Runs
-- locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

local lib = { New = function() return {
    Disc = function(host, size) return { size = size, top = CreateFrame("Frame", nil, host) } end,
    Apply = function(frame) return { top = CreateFrame("Frame", nil, frame) } end,
    Font = function(parent) return parent:CreateFontString() end,
    Mask = function(host) return host:CreateTexture() end,
} end }
rawset(_G, "LibStub", setmetatable({}, { __call = function(_, major)
    if major == "LibGlass-1.0" then return lib, 11 end
end }))
WoW.loadedAddons = nil                                     -- Glass MiniMap "loads" below

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.db.compassSize = "small"                                -- the player's own, to be put back
WoW.itemCached[765] = true
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB
rawset(_G, "GameTooltipTextLeft1", GameTooltip:CreateFontString())

local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 6 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/compass4"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function K() return C_Minimap.GetViewRadius() / 99 end
local leaf
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        WoW.blips = leaf and { { "Silverleaf", -(leaf.west - WoW.pos[2]) / K(), (leaf.north - WoW.pos[1]) / K(),
                                 kind = "herbs" } } or {}
        WoW.advance(0.1)
    end
end
local C = NR.Compass._test

walk(1)
WoW.facing = 0
fp("steps nr compass4")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.compass, true, "the compass on")
-- Glass, medium, once a node is up.
poll()
eq(result(2).status, nil, "no node: waits")
leaf = { north = WoW.pos[1] + 40 * K(), west = WoW.pos[2] }
walk(3)
eq(result(2).status, nil, "up as bronze (no Glass MiniMap): waits for glass")
WoW.loadedAddons = { GlassMiniMap = true }
NR.Icons._test.reset()
walk(3)
eq(result(2).status, "done", "glass medium: " .. detail(2))
check(detail(2):find("glass medium"), "...read back")
settle()
S.Answer(true)                                             -- 3
WoW.posSecret = true                                       -- the compass down, its look still built
walk(3)
eq(result(4).status, nil, "the compass down: waits")
WoW.posSecret = false
walk(3)
-- Small, large: read back in what each step recorded.
poll(); settle(); poll(); settle()
check(detail(4):find("glass small"), "small: " .. detail(4))
check(detail(5):find("glass large"), "large: " .. detail(5))
eq(record().at, 6, "asked")
S.Answer(true)                                             -- 6
poll(); settle(); poll(); settle()
check(detail(7):find("bronze medium"), "bronze: " .. detail(7))
check(detail(8):find("plain medium"), "no frame: " .. detail(8))
S.Answer(true)                                             -- 9
-- The tooltip: back to glass, the mouse on its disc.
walk(1.2)
eq(result(10).status, nil, "waits for the tooltip")
local l = C.look()
check(l == C.looks.glass, "...back to glass")
GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
GameTooltip:Show()
walk(1.2)
eq(result(10).status, nil, "...another's tooltip doesn't count")
GameTooltip:Hide()
l.host._scripts.OnEnter(l.host)
GameTooltipTextLeft1:SetText("Silverleaf")
walk(1.2)
eq(result(10).status, "done", "the tooltip: " .. detail(10))
settle()
S.Answer(true)                                             -- 11
S.Answer(true)                                             -- 12: clicks
S.Answer(true)                                             -- 13: the camera
-- Pointing behind.
walk(1.2)
eq(result(14).status, nil, "the node ahead: turn away")
WoW.facing = math.pi
walk(1.2)
eq(result(14).status, "done", "behind: " .. detail(14))
settle()
S.Answer(true)                                             -- 15
S.Answer(true)                                             -- 16: Edit Mode
S.Answer(true)                                             -- 17: combat
-- A ride.
WoW.speed = 7
walk(6)
eq(result(18).status, "done", "riding: " .. detail(18))
WoW.speed = 0
settle()
S.Answer(true)                                             -- 19
eq(result(20).status, "done", "put back: " .. detail(20))
eq(rawget(NR.db, "compass"), nil, "the compass back to the default")
eq(rawget(NR.db, "compassSize"), "small", "...the player's size")
eq(rawget(NR.db, "iconStyle"), nil, "...the icons' frame back to the default")
eq(record().at, 21, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_compass4")
