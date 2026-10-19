-- The compasslook procedure (/fp steps nr compasslook, #29): glass drafts of
-- the compass over NodeRadar's own target (its ring hidden meanwhile): a disc,
-- the node's icon, the arrow on the rim, the distance in a glass pill; Glass
-- MiniMap's ring art on look B; the settings and NodeRadar's ring put back.
-- Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

-- LibGlass-1.0 as Glass MiniMap loads it, faked.
local G = { discs = {} }
local lib = { New = function() return {
    Disc = function(host, size)
        local g = { size = size, host = host, rim = host:CreateTexture(), dark = host:CreateTexture(),
                    top = CreateFrame("Frame", nil, host) }
        G.discs[#G.discs + 1] = g
        return g
    end,
    Apply = function(frame, size) G.pill = { frame = frame, size = size }; return { top = CreateFrame("Frame", nil, frame) } end,
    Font = function(parent, size, justify) local fs = parent:CreateFontString(); fs._fontSize = size; return fs end,
    Mask = function(host) return host:CreateTexture() end,
} end }
rawset(_G, "LibStub", setmetatable({}, { __call = function(_, major)
    if major == "LibGlass-1.0" then return lib, 11 end
end }))

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.db.icons = true                                         -- the player's own, kept and put back
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
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 8 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/compasslook"] end
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
-- The draft's host for a look: the disc's host whose size is `size`.
local function host(size)
    for i = #G.discs, 1, -1 do
        local g = G.discs[i]
        if g.host._width == size then return g.host, g end
    end
end
local function iconOf(h)
    for _, t in ipairs(h._regions or {}) do if t._layer == "ARTWORK" then return t end end
end

walk(1)
fp("steps nr compasslook")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.compass, true, "NodeRadar's compass on")
eq(NR.db.icons, true, "...the icons as the player had them")

-- Today's ring first.
poll()
eq(result(2).status, nil, "no node: waits")
leaf = { north = WoW.pos[1] + 40 * K(), west = WoW.pos[2] }
walk(3)
eq(result(2).status, "done", "today's ring: " .. detail(2))
settle()

-- Look A: a glass disc 96, the icon, the arrow, the pill.
poll()
eq(result(3).status, "done", "look A: " .. detail(3))
local h, g = host(96)
check(h and h._shown, "...a 96-unit host shown")
eq(g and g.size, "disc", "...the large disc")
eq(h and h._mouse, false, "...no mouse")
eq(NR.Compass._test.root._alpha, 0, "...NodeRadar's own ring hidden")
local icon = iconOf(h)
eq(icon and icon._file, NR.Compass._test.target().icon, "...the target's item icon in the middle")
eq(G.pill and G.pill.size, "small", "...a small glass pill")
check(detail(3):find("%d+ yd"), "...the distance in it: " .. detail(3))
settle()
S.Answer(true)                                             -- 4
settle()

-- Look B: Glass MiniMap's ring art.
poll()
eq(result(5).status, "done", "look B: " .. detail(5))
local hb, gb = host(96)
check(hb ~= h and hb._shown, "...its own host shown")
eq(gb.rim._file, "Interface\\AddOns\\GlassMiniMap\\Media\\ring_rim", "...Glass MiniMap's rim")
eq(gb.dark._file, "Interface\\AddOns\\GlassMiniMap\\Media\\ring_dark", "...and its dark rim")
eq(h._shown, false, "...look A hidden")
settle()
S.Answer(true)                                             -- 6
settle()

-- Look C: smaller.
poll()
eq(result(7).status, "done", "look C: " .. detail(7))
local hc, gc = host(72)
check(hc and hc._shown, "...a 72-unit host")
eq(gc.size, "disc_small", "...the small disc")
settle()
S.Answer(true)                                             -- 8
settle()
S.Answer(true)                                             -- 9: the best
settle()

-- Riding with A.
WoW.speed = 7
walk(7)
eq(result(10).status, "done", "riding: " .. detail(10))
check(h._shown, "...look A again")
WoW.speed = 0
settle()
S.Answer(true)                                             -- 11
eq(result(12).status, "done", "put back: " .. detail(12))
eq(h._shown, false, "the drafts hidden")
eq(NR.Compass._test.root._alpha, 1, "NodeRadar's ring back")
eq(rawget(NR.db, "compass"), nil, "the compass back to the default")
eq(rawget(NR.db, "icons"), true, "...the icons as they were")
eq(record().at, 13, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_compasslook")
