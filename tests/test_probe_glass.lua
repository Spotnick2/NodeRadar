-- The glass procedure (/fp steps nr glass, #41): NodeRadar's icons on, each
-- look's disc around them (LibGlass as Glass MiniMap loaded it, here a fake),
-- NodeRadar's own texture hidden meanwhile and given back after, released
-- frames included; the setting put back. Runs locally only (ForeverProbe is
-- private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

-- LibGlass-1.0, faked: what the probe asks of it, recorded.
local discs = {}
local function newInst(preset)
    local inst = {}
    function inst.Disc(host, size)
        local w, h = host:GetSize()
        assert(w and w > 0 and w == h, "Disc: the host must be square and sized")
        local g = { host = host, size = size, preset = preset, w = w }
        discs[#discs + 1] = g
        return g
    end
    function inst.SetSurfaceAlpha(g, part, a) g[part] = a; return true end
    function inst.Mask(host, file, margin, inset)
        local m = host:CreateTexture()
        m._mask, m._inset = file, inset
        return m
    end
    return inst
end
local lib = { New = function(_, opts) return newInst(opts.preset) end }
local glassLoaded = false
rawset(_G, "LibStub", setmetatable({}, { __call = function(_, major)
    if glassLoaded and major == "LibGlass-1.0" then return lib, 11 end
end }))

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
local NR = loadAddon()
NR.db.iconStyle = "plain"                                  -- #28's icon (the looks: test_styles)
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
local function record() return FP.db.steps.records["NodeRadarProbe/glass"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end

-- One Silverleaf where the player sees it.
local blips = { { "Silverleaf", 30, 20, kind = "herbs" } }
local function walk(seconds)
    for _ = 1, math.floor(seconds / 0.1 + 0.5) do
        WoW.blips = blips
        WoW.advance(0.1)
    end
end
local function frames()
    local list = {}
    for _, r in ipairs(NR.Icons._test.records()) do if r.frame then list[#list + 1] = r.frame end end
    return list
end
-- The disc hosts on a NodeRadar icon frame: { shown = n, sizes = { ... } }.
local function hostsOn(f)
    local out = { shown = 0, sizes = {} }
    for _, g in ipairs(discs) do
        if g.host._parent == f and g.host._shown then
            out.shown = out.shown + 1
            out.sizes[#out.sizes + 1] = g.w
            out.g = g
        end
    end
    return out
end
local function discIcon(g)
    for _, t in ipairs(g.host._regions or {}) do if t._layer == "ARTWORK" then return t end end
end

-- Without LibGlass: the first step waits.
walk(1)
fp("steps nr glass")
poll()
eq(result(1).status, nil, "no LibGlass: waits")
glassLoaded = true
poll()
eq(result(1).status, "done", "ready: " .. detail(1))
check(detail(1):find("minor 11"), "...LibGlass's minor logged")
eq(NR.db.icons, true, "NodeRadar's icons on")

-- The plain icons first, for comparison.
walk(3)
eq(result(2).status, "done", "plain icons: " .. detail(2))
local f = frames()[1]
check(f, "an icon frame")
eq(#discs, 0, "...no disc yet")
settle()

-- Look A: an 18-unit disc on the icon, the icon round inside, NodeRadar's texture hidden.
poll()
eq(result(3).status, "done", "look A: " .. detail(3))
local a = hostsOn(f)
eq(a.shown, 1, "...one disc on the icon")
eq(a.sizes[1], 18, "...18 units")
eq(a.g.size, "disc_small", "...the small disc textures")
eq(a.g.preset, "clean", "...clean, as Glass MiniMap")
local icon = discIcon(a.g)
eq(icon and icon._file, f.tex._file, "...NodeRadar's icon inside")
check(icon and icon._mask and icon._mask._mask == "disc_mask_small", "...masked round")
eq(icon and icon._mask._inset, 3, "...inset 18%")
eq(f.tex._alpha, 0, "...NodeRadar's own texture hidden")
settle()
S.Answer(true)                                             -- 4
settle()

-- B to E: one disc at a time.
local want = { { 22, "clean" }, { 15, "clean" }, { 18, "pearl" }, { 18, "clean", shadow = 0 } }
for i, w in ipairs(want) do
    local step = 3 + 2 * i
    poll()
    eq(result(step).status, "done", "look " .. step .. ": " .. detail(step))
    local h = hostsOn(f)
    eq(h.shown, 1, "...one disc shown")
    eq(h.sizes[1], w[1], "..." .. w[1] .. " units")
    eq(h.g.preset, w[2], "..." .. w[2])
    eq(h.g.shadow, w.shadow, "...the shadow as asked")
    settle()
    S.Answer(true)
    settle()
end
eq(record().at, 13, "the best look asked")
S.Answer(true)                                             -- 13
settle()

-- Running with look A; a node that leaves frees its frame, still disc-wearing.
WoW.speed = 7
walk(4)
eq(result(14).status, "done", "running: " .. detail(14))
eq(hostsOn(f).sizes[1], 18, "...look A again")
settle()
WoW.speed = 0
blips = {}
walk(6)
eq(#frames(), 0, "the node gone: its frame released")
S.Answer(true)                                             -- 15
settle()

-- The end: every frame's own texture back, no disc shown, the setting back.
eq(result(16).status, "done", "put back: " .. detail(16))
eq(f.tex._alpha, 1, "the released frame's texture given back")
eq(hostsOn(f).shown, 0, "...no disc shown on it")
eq(rawget(NR.db, "icons"), nil, "NodeRadar's icons back to the player's default")
eq(record().at, 17, "at the last reload")
fp("steps stop")

eq(errors(), 0, "no step threw")
eq(#WoW.chat, 0, "nothing in chat")
checkMethods({ "Texture:GetTexture", "Texture:AddMaskTexture" })

done("test_probe_glass")
