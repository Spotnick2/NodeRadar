-- The gather procedure (/fp steps nr gather, #29): the compass sampled every
-- 0.25 s for 6 s after a gather, the gathered herb's dot still on the map (its
-- loot open); the compass put back. Runs locally only (ForeverProbe is
-- private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)
rawset(_G, "LootFrame", CreateFrame("Frame"))

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
NR.Track.SetSmart(false)
WoW.itemCached[765] = true
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
local function record() return FP.db.steps.records["NodeRadarProbe/gather"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        local l = {}
        for _, n in ipairs(nodes) do
            if not n.gone then
                l[#l + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
            end
        end
        WoW.blips = l
        WoW.advance(0.1)
    end
end

walk(1)
fp("steps nr gather")
WoW.advance(1.1)
eq(result(1).status, "done", "ready: " .. detail(1))
local leaf = { name = "Silverleaf", north = WoW.pos[1] + 3 * K(), west = WoW.pos[2] }
nodes = { leaf, { name = "Earthroot", north = WoW.pos[1] - 60 * K(), west = WoW.pos[2] } }
walk(3)
eq(result(2).status, nil, "no gather yet: waits")
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "Cast-1", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 2366)
LootFrame:Show()
walk(3)                                                    -- the loot open, the dot still there
leaf.gone = true
LootFrame:Hide()
walk(4)
eq(result(2).status, "done", "watched: " .. detail(2))
check(detail(2):find("^true, \"0 of 2%d samples hidden"), "...shown throughout: " .. detail(2):sub(1, 60))
check(detail(2):find("shown Earthroot loot"), "...on the Earthroot while the loot was open")
S.Answer(true)                                             -- 3
eq(result(4).status, "done", "put back: " .. detail(4))
eq(rawget(NR.db, "compass"), nil, "the compass back")
eq(record().at, 5, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_gather")
