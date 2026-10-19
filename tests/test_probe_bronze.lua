-- The bronze procedure (/fp steps nr bronze, #41): on Blizzard's own minimap
-- (it waits while Glass MiniMap is on), each look puts Blizzard's round button
-- ring around NodeRadar's icons, laid out as LibDBIcon's button and scaled to
-- the icon; NodeRadar's own texture is given back after; the setting put back.
-- Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.db.iconStyle = "plain"                                  -- #28's icon (the looks: test_styles)
local FP = loadForeverProbe()
loadProbe()
local S = FP.Steps

local function errors()
    local n = 0
    for _, l in ipairs(NodeRadarProbeDB.log) do if l:find("ERROR") then n = n + 1 end end
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
local function record() return FP.db.steps.records["NodeRadarProbe/bronze"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

local blips = { { "Silverleaf", 30, 20, kind = "herbs" } }
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        WoW.blips = blips
        WoW.advance(0.1)
    end
end
local function frame()
    for _, r in ipairs(NR.Icons._test.records()) do if r.frame then return r.frame end end
end
-- The shown ring hosts on a NodeRadar icon frame, and their parts.
local function rings(f)
    local out = {}
    for _, w in ipairs(WoW.frames) do
        if w._parent == f and w._shown and w._regions then
            local h = { host = w }
            for _, t in ipairs(w._regions) do
                if t._type == "MaskTexture" then h.mask = t
                elseif t._layer == "OVERLAY" then h.ring = t
                elseif t._layer == "BACKGROUND" then h.bg = t
                elseif t._layer == "ARTWORK" then h.icon = t end
            end
            if h.ring then out[#out + 1] = h end
        end
    end
    return out
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

walk(1)
fp("steps nr bronze")
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
eq(NR.db.icons, true, "NodeRadar's icons on")
eq(record().at, 2, "asks to turn Glass MiniMap off and reload")
S.Skip()                                                   -- 2: the reload

-- Glass MiniMap still on: waits.
WoW.loadedAddons = { GlassMiniMap = true }
walk(3)
eq(result(3).status, nil, "Glass MiniMap on: waits")
WoW.loadedAddons = nil
walk(1.2)
eq(result(3).status, "done", "the stock map, plain icons: " .. detail(3))
settle()

-- Look F: the ring around the icon, as LibDBIcon's button, scaled to the icon 12.
local f = frame()
check(f, "an icon frame")
poll()
eq(result(4).status, "done", "look F: " .. detail(4))
local list = rings(f)
eq(#list, 1, "...one ring on the icon")
local h, k = list[1], 12 / 17
check(h and near(h.host._width, 31 * k), "...the button 31 scaled")
eq(h and h.ring._file, 136430, "...MiniMap-TrackingBorder")
check(h and near(h.ring._width, 53 * k), "...the ring 53 scaled")
eq(h and h.bg._file, 136467, "...UI-Minimap-Background behind")
eq(h and h.icon._width, 12, "...the icon 12")
eq(h and h.icon._file, f.tex._file, "...NodeRadar's icon")
local p = h and h.icon._points[1]
check(p and near(p[4], 7 * k) and near(p[5], -6 * k), "...at LibDBIcon's (7, -6)")
local hp = h and h.host._points[1]
check(hp and hp[1] == "CENTER" and hp[2] == f and near(hp[5], -k), "...the icon's centre on the node")
eq(h and h.mask and h.mask._file, "Interface\\CharacterFrame\\TempPortraitAlphaMask", "...masked round")
check(h and h.icon._mask == h.mask, "...the mask on the icon")
eq(f.tex._alpha, 0, "...NodeRadar's own texture hidden")
settle()
S.Answer(true)                                             -- 5
settle()

-- G and H: one ring at a time, at their icon's size.
for i, size in ipairs({ 10, 14 }) do
    local step = 4 + 2 * i
    poll()
    eq(result(step).status, "done", "look " .. step .. ": " .. detail(step))
    local l = rings(f)
    eq(#l, 1, "...one ring shown")
    eq(l[1] and l[1].icon._width, size, "...the icon " .. size)
    check(l[1] and near(l[1].ring._width, 53 * size / 17), "...the ring scaled with it")
    settle()
    S.Answer(true)
    settle()
end
eq(record().at, 10, "the best look asked")
S.Answer(true)                                             -- 10
settle()

WoW.speed = 7
walk(4)
eq(result(11).status, "done", "running: " .. detail(11))
eq(rings(f)[1] and rings(f)[1].icon._width, 12, "...look F again")
settle()
WoW.speed = 0
S.Answer(true)                                             -- 12
settle()

eq(result(13).status, "done", "rings off: " .. detail(13))
eq(#rings(f), 0, "...none shown")
eq(f.tex._alpha, 1, "...NodeRadar's own texture back")
eq(record().at, 14, "asks to turn Glass MiniMap back on")
S.Skip()                                                   -- 14: the reload
eq(result(15).status, "done", "put back: " .. detail(15))
eq(rawget(NR.db, "icons"), nil, "NodeRadar's icons back to the player's default")
eq(record().at, 16, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
checkMethods({ "Frame:CreateMaskTexture", "MaskTexture:SetTexture", "Texture:AddMaskTexture" })

done("test_probe_bronze")
