-- The compasslook2 procedure (/fp steps nr compasslook2, #29): glass discs
-- just around the icon with the arrow outside (D with Glass MiniMap's ring
-- art, E plain, F smaller), the item's tooltip on hover (only these take the
-- mouse, on the disc alone), the settings and NodeRadar's ring put back. Runs
-- locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

local G = { discs = {} }
local lib = { New = function() return {
    Disc = function(host, size)
        local g = { size = size, host = host, rim = host:CreateTexture(), dark = host:CreateTexture(),
                    top = CreateFrame("Frame", nil, host) }
        G.discs[#G.discs + 1] = g
        return g
    end,
    Apply = function(frame) return { top = CreateFrame("Frame", nil, frame) } end,
    Font = function(parent) return parent:CreateFontString() end,
    Mask = function(host) return host:CreateTexture() end,
} end }
rawset(_G, "LibStub", setmetatable({}, { __call = function(_, major)
    if major == "LibGlass-1.0" then return lib, 11 end
end }))
WoW.Methods.SetItemByID = function(t, id) t._item = id end
WoW.Methods.SetOwner = function(t, owner, anchor) t._owner, t._anchor = owner, anchor end

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.Learn.Info = function(name) if name == "Silverleaf" then return { item = 765, skill = 1 } end end
WoW.itemCached[765] = true
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps
local db = NodeRadarProbeDB
rawset(_G, "GameTooltip", CreateFrame("Frame"))
rawset(_G, "GameTooltipTextLeft1", GameTooltip:CreateFontString())
GameTooltip:Hide()

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
local function record() return FP.db.steps.records["NodeRadarProbe/compasslook2"] end
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
local function host(size, gmm)
    for i = #G.discs, 1, -1 do
        local g = G.discs[i]
        if g.host._width == size and (gmm == nil or (g.rim._file ~= nil) == gmm) then return g.host, g end
    end
end
local function iconOf(h)
    for _, t in ipairs(h._regions or {}) do if t._layer == "ARTWORK" then return t end end
end
local function arrowOf(h)
    for _, w in ipairs(WoW.frames) do
        if w._parent == h and w._regions then
            for _, t in ipairs(w._regions) do if t._layer == "OVERLAY" then return t end end
        end
    end
end

walk(1)
fp("steps nr compasslook2")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
leaf = { north = WoW.pos[1] + 40 * K(), west = WoW.pos[2] }
walk(3)
eq(result(2).status, "done", "the ring: " .. detail(2))
settle()

-- D: a 44 disc, the icon 30, the arrow outside, Glass MiniMap's art, the mouse on the disc.
poll()
eq(result(3).status, "done", "look D: " .. detail(3))
local h, g = host(44, true)
check(h and h._shown, "...a 44-unit disc shown")
eq(g.size, "disc_small", "...the small disc")
eq(g.rim._file, "Interface\\AddOns\\GlassMiniMap\\Media\\ring_rim", "...Glass MiniMap's rim")
eq(iconOf(h)._width, 30, "...the icon 30, nearly the disc")
local ar = arrowOf(h)
WoW.facing = 0
WoW.tick(0.016)
local p = ar and ar._points[#ar._points]
check(p and math.abs(p[5] - (22 + 8)) < 0.6, "...the arrow outside the disc: " .. tostring(p and p[5]))
eq(ar and ar._width, 12, "...a 12-unit arrow")
eq(h._mouse, true, "...the disc takes the mouse (the tooltip)")
eq(g.top._mouse, false, "...its glass top doesn't")
settle()
S.Answer(true)                                             -- 4
settle()
-- E: the plain rim.
poll()
eq(result(5).status, "done", "look E: " .. detail(5))
local he, ge = host(44, false)
check(he and he._shown and ge.rim._file == nil, "...the plain glass rim")
settle()
S.Answer(true)                                             -- 6
settle()
-- F: smaller.
poll()
eq(result(7).status, "done", "look F: " .. detail(7))
local hf = host(36)
check(hf and hf._shown and iconOf(hf)._width == 24, "...36 with the icon 24")
settle()
S.Answer(true)                                             -- 8
settle()
S.Answer(true)                                             -- 9: the best
settle()

-- The tooltip on D.
poll()
eq(result(10).status, nil, "waits for the mouse on the icon")
GameTooltip:Show()                                         -- another tooltip up, the mouse elsewhere
poll()
eq(result(10).status, nil, "...a tooltip, not the disc's: still waiting")
GameTooltip:Hide()
WoW.mouseOver = h
h._scripts.OnEnter(h)
poll()
eq(result(10).status, "done", "the tooltip: " .. detail(10))
eq(GameTooltip._item, 765, "...Silverleaf's item")
check(GameTooltip._owner == h and GameTooltip._anchor == "ANCHOR_TOP", "...owned by the disc, above it")
h._scripts.OnLeave(h)
eq(GameTooltip._shown, false, "...hidden on leave")
WoW.mouseOver = nil
settle()
S.Answer(true)                                             -- 11
settle()
S.Answer(true)                                             -- 12: the click beside it
settle()
WoW.speed = 7
walk(7)
eq(result(13).status, "done", "riding: " .. detail(13))
WoW.speed = 0
settle()
S.Answer(true)                                             -- 14
eq(result(15).status, "done", "put back: " .. detail(15))
eq(h._shown, false, "the drafts hidden")
eq(NR.Compass._test.ring._alpha, 1, "NodeRadar's ring back")
eq(record().at, 16, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
done("test_probe_compasslook2")
