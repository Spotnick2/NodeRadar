-- The compass5 procedure (/fp steps nr compass5, #29): the refined compass in
-- game: pearl at each size, bronze, no frame, four headings (ahead, left, a
-- diagonal, behind), bright and dark ground, a far node, an ore, the tooltip,
-- clicks, Edit Mode, a ride; the settings put back. Runs locally only
-- (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)
local lib = { New = function() return {
    Disc = function(host, size) return { size = size, top = CreateFrame("Frame", nil, host) } end,
    Mask = function(host) return host:CreateTexture() end,
} end }
rawset(_G, "LibStub", setmetatable({}, { __call = function(_, major)
    if major == "LibGlass-1.0" then return lib, 11 end
end }))
WoW.loadedAddons = { GlassMiniMap = true }

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
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
local function record() return FP.db.steps.records["NodeRadarProbe/compass5"] end
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
fp("steps nr compass5")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
leaf = { north = WoW.pos[1] + 40 * K(), west = WoW.pos[2] }
walk(3)
eq(result(2).status, "done", "pearl medium: " .. detail(2))
settle()
S.Answer(true)                                             -- 3
poll(); settle(); poll(); settle(); poll(); settle(); poll(); settle()
check(detail(4):find("glass small") and detail(5):find("glass large"), "the sizes: " .. detail(4) .. ", " .. detail(5))
check(detail(6):find("bronze medium") and detail(7):find("plain medium"), "the frames: " .. detail(6) .. ", " .. detail(7))
eq(record().at, 8, "asked")
S.Answer(true)                                             -- 8
-- The headings, each waited for.
walk(1.2)
eq(result(9).status, "done", "ahead: " .. detail(9))
settle()
walk(1.2)
eq(result(10).status, nil, "the node ahead isn't on the left: waits")
WoW.facing = 3 * math.pi / 2
walk(1.2)
eq(result(10).status, "done", "left: " .. detail(10))
settle()
WoW.facing = 3 * math.pi / 4
walk(1.2)
eq(result(11).status, "done", "the diagonal: " .. detail(11))
settle()
WoW.facing = math.pi
walk(1.2)
eq(result(12).status, "done", "behind: " .. detail(12))
settle()
S.Answer(true)                                             -- 13
settle(); S.Next(); settle(); S.Skip(); settle()           -- 14 bright, 15 dark
S.Answer(true)                                             -- 16
settle(); S.Next(); settle()                               -- 17 far
S.Answer(true)                                             -- 18
S.Skip()                                                   -- 19 ore
-- The tooltip.
WoW.facing = 0
walk(1.2)
eq(result(20).status, nil, "waits for the tooltip")
C.disc._scripts.OnEnter(C.disc)
GameTooltipTextLeft1:SetText("Silverleaf")
walk(1.2)
eq(result(20).status, "done", "the tooltip: " .. detail(20))
settle()
S.Answer(true)                                             -- 21
S.Answer(true)                                             -- 22
S.Answer(true)                                             -- 23
WoW.speed = 7
walk(6)
eq(result(24).status, "done", "riding: " .. detail(24))
WoW.speed = 0
settle()
S.Answer(true)                                             -- 25
eq(result(26).status, "done", "put back: " .. detail(26))
eq(rawget(NR.db, "compass"), nil, "the compass back")
eq(record().at, 27, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_compass5")
