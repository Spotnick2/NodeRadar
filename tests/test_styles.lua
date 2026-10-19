-- Icon styles and sizes (#41, docs/PLAN.md "Icon styles and sizes"): the
-- look follows the minimap (glass with Glass MiniMap, else bronze), LibGlass
-- borrowed and every way it fails ending in bronze; each look's geometry and
-- size; one bind for every way a look becomes active; the rim at each look's
-- extent; our own height arrow from the sweep's rows, heights folded.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Mageroyal"] = "herbs"
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
TEST_LIBRARY.enUS["Peacebloom"] = "herbs"

-- LibGlass-1.0, faked: Disc makes part of a disc (a texture and its top
-- frame) before it can throw, as the real one does (Codex, #41).
local G = { minor = 11, discs = 0 }
local function newInst()
    local inst = {}
    function inst.Disc(host, size)
        local w, h = host:GetSize()
        assert(w and w > 0 and w == h, "Disc: the host must be square and sized")
        G.discs = G.discs + 1
        local g = { size = size, host = host }
        g.tint = host:CreateTexture(nil, "BACKGROUND")
        g.top = CreateFrame("Frame", nil, host)
        g.top:SetFrameLevel((host:GetFrameLevel() or 0) + 10)
        if G.discThrowsAt == G.discs then error("Disc broke part-way") end
        G.last = g
        return g
    end
    function inst.Mask(host, file, margin, inset)
        local m = host:CreateTexture()
        m._maskFile, m._inset = file, inset
        return m
    end
    return inst
end
local lib = { New = function(_, opts)
    if G.newThrows then error("New broke") end
    G.preset = opts.preset
    return newInst()
end }
rawset(_G, "LibStub", setmetatable({}, { __call = function(_, major)
    if G.loaded and major == "LibGlass-1.0" then return lib, G.minor end
end }))

local NR = loadAddon()
local Icons, Scan = NR.Icons, NR.Scan
local T = Icons._test
WoW.itemCached[765] = true                                 -- Silverleaf's item: its icon answers

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y, extra)
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    for k, v in pairs(extra or {}) do n[k] = v end
    nodes[#nodes + 1] = n
    return n
end
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs",
                            text = n.text }
    end
    WoW.blips = list
end
local function step()
    WoW.now = WoW.now + 1
    place()
    return NR.Step(WoW.now)
end
local function rec(name)
    for _, r in ipairs(T.records()) do if r.name == name then return r end end
end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6) end
local function fresh(style, size)
    nodes = {}
    Icons.Clear()
    T.reset()
    NR.failures.glass = nil
    NR.db.iconStyle, NR.db.iconSize = style, size
    WoW.now = WoW.now + 30
end
-- What a frame shows: "plain", "glass", "bronze", "yellow", or nil.
local function shows(f)
    local s
    if f.tex._shown then s = "plain" end
    if f.glass and f.glass._shown then s = s and "many" or "glass" end
    if f.bronze and f.bronze._shown then s = s and "many" or "bronze" end
    if f.ring and f.ring._shown then s = s and "many" or "yellow" end
    return s
end
-- A pixel of a generated texture (Tools/make_media.py: 32-bit BGRA, top-left
-- origin, an 18-byte header): r, g, b, a in 0..255.
local function pixel(path, x, y)
    local fh = assert(io.open(path, "rb"))
    local data = fh:read("*a")
    fh:close()
    local w = data:byte(13) + 256 * data:byte(14)
    local i = 18 + (y * w + x) * 4 + 1
    local b, g, r, a = data:byte(i, i + 3)
    return r, g, b, a
end

local ABOVE = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16|t"
local BELOW = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:16:32|t"

--------------------------------------------------------------------------------
-- The height in a row (the measured texts, 70450)
--------------------------------------------------------------------------------

eq(Scan.Height(ABOVE .. "Silverleaf"), "above", "the upper half: above")
eq(Scan.Height(BELOW .. "Earthroot"), "below", "the lower half: below")
eq(Scan.Height("Peacebloom"), "level", "no arrow: level")
eq(Scan.Height("|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:4:8|tPeacebloom"), "level",
    "an arrow not seen before: no arrow")
eq(Scan.Plain(ABOVE .. "Silverleaf"), "Silverleaf", "...and the name as before")

--------------------------------------------------------------------------------
-- The sweep: a blip's height, the rest unchanged
--------------------------------------------------------------------------------

local function sweep() place(); return Scan.Sweep(function(n) return NR.Learn.Kind(n) and true or false end) end
local function shape(res)                                  -- every field but height
    local out = {}
    for _, b in ipairs(res.blips) do
        out[#out + 1] = ("%s %.3f %.3f %d"):format(b.name, b.x, b.y, b.cells)
    end
    table.sort(out)
    local names = {}
    for name, list in pairs(res.byName) do names[#names + 1] = name .. "=" .. #list end
    table.sort(names)
    return table.concat(out, "; ") .. " | " .. table.concat(names, ",")
end
nodes = {}
local quest = "Encroachment|cffffffff\n- 1/4 Razormane Quilboar slain|r"
node("Silverleaf", 31, -23, { text = "Silverleaf\n" .. quest })
node("Earthroot", -40, 30)
local before = sweep()
nodes[1].text = ABOVE .. "Silverleaf\n" .. quest
nodes[2].text = BELOW .. "Earthroot"
local after = sweep()
eq(shape(after), shape(before), "arrows in the rows: the same blips, names, counts, positions and cells")
eq(after.byName.Silverleaf[1].height, "above", "Silverleaf above")
eq(after.byName.Earthroot[1].height, "below", "Earthroot below")
eq(before.byName.Silverleaf[1].height, nil, "...level before")
check(after.byName.Encroachment == nil or after.byName.Encroachment[1].height == nil,
    "the quest's line under the node's arrow carries none")
-- Two nodes of a name at different heights in one cluster: no arrow. 26
-- apart, their squares don't overlap (no cell reads both), yet the grid
-- bridges the 1-unit gap: one blip whose cells disagree.
nodes = {}
node("Silverleaf", 0, 0, { text = ABOVE .. "Silverleaf" })
node("Silverleaf", 26, 0, { text = BELOW .. "Silverleaf" })
local mixed = sweep().byName.Silverleaf
eq(mixed and #mixed, 1, "the pair is one blip")
eq(mixed and mixed[1].height, nil, "...whose cells disagree: no arrow")
-- Overlapping: the cells reading both rows fold to mixed too.
nodes = {}
node("Silverleaf", 0, 0, { text = ABOVE .. "Silverleaf" })
node("Silverleaf", 10, 0, { text = BELOW .. "Silverleaf" })
mixed = sweep().byName.Silverleaf
eq(mixed and #mixed, 1, "an overlapping pair: one blip")
eq(mixed and mixed[1].height, nil, "...no arrow")
-- One blip whose rows name it twice at two heights: folded to none.
nodes = {}
node("Silverleaf", 0, 0, { text = ABOVE .. "Silverleaf\n" .. BELOW .. "Silverleaf" })
eq(sweep().byName.Silverleaf[1].height, nil, "two rows of a name at two heights in one read: no arrow")
-- Two separate blips of a name: each its own.
nodes = {}
node("Silverleaf", -50, 0, { text = ABOVE .. "Silverleaf" })
node("Silverleaf", 50, 0, { text = BELOW .. "Silverleaf" })
local two = sweep()
local hs = {}
for _, b in ipairs(two.byName.Silverleaf) do hs[#hs + 1] = b.height end
table.sort(hs)
eq(table.concat(hs, ","), "above,below", "two separate blips of a name keep their own heights")

--------------------------------------------------------------------------------
-- The style rule
--------------------------------------------------------------------------------

NR.Set("icons", true)
-- Auto, no Glass MiniMap: bronze, not a failure.
fresh(nil, nil)
eq(NR.db.iconStyle, "auto", "the default style: follow the minimap")
eq(NR.db.iconSize, "medium", "the default size: medium")
node("Silverleaf", 31, -23)
step()
local f = rec("Silverleaf").frame
eq(shows(f), "bronze", "auto without Glass MiniMap: bronze")
eq(NR.failures.glass, nil, "...not a failure")
eq(f.bronze.icon._file, 130765, "...the item's icon in the ring")
eq(f.arrowFrame._shown, false, "...level: no arrow")

-- Auto with Glass MiniMap and LibGlass 11: glass, the clean preset.
fresh(nil, nil)
WoW.loadedAddons = { GlassMiniMap = true }
G.loaded = true
node("Silverleaf", 31, -23)
step()
f = rec("Silverleaf").frame
eq(shows(f), "glass", "auto with Glass MiniMap: glass")
eq(G.preset, "clean", "...LibGlass's clean preset")
eq(G.last.size, "disc_small", "...the small disc")
eq(f.glass._width, 18, "...built at 18 (1.5 times the medium icon)")
eq(f.glass.icon._mask and f.glass.icon._mask._maskFile, "disc_mask_small", "...the icon masked round")
eq(f.glass.icon._mask._inset, 3, "...inset a quarter of the icon")
local ip = f.glass.icon._points
check(ip[1][4] == 3 and ip[1][5] == -3 and ip[2][4] == -3 and ip[2][5] == 3, "...the icon exactly 12 inside 18")
eq(G.last.top._mouse, false, "...its top frame takes no mouse")
eq(f.glass._mouse, false, "...nor its host")
check(f.arrowFrame._level > G.last.top._level, "the arrow's frame over the glass's top")

-- Glass MiniMap's LibGlass older than r6: bronze, a failure.
fresh(nil, nil)
G.minor = 5
node("Silverleaf", 31, -23)
step()
eq(shows(rec("Silverleaf").frame), "bronze", "LibGlass minor 5: bronze")
check(NR.failures.glass and NR.failures.glass.err:find("older"), "...a failure: " .. tostring(NR.failures.glass
    and NR.failures.glass.err))
G.minor = 11
-- New throws: bronze, a failure.
fresh(nil, nil)
G.newThrows = true
node("Silverleaf", 31, -23)
step()
eq(shows(rec("Silverleaf").frame), "bronze", "New throws: bronze")
check(NR.failures.glass, "...a failure")
G.newThrows = nil
-- Glass chosen without LibGlass: bronze, a failure.
fresh("glass", nil)
WoW.loadedAddons, G.loaded = nil, false
node("Silverleaf", 31, -23)
step()
eq(shows(rec("Silverleaf").frame), "bronze", "glass chosen, no LibGlass: bronze")
check(NR.failures.glass and NR.failures.glass.err:find("isn't loaded"), "...a failure saying why")
-- Plain: #28's icon, no hosts.
fresh("plain", nil)
node("Silverleaf", 31, -23)
step()
f = rec("Silverleaf").frame
eq(shows(f), "plain", "plain: the icon alone")
eq(f.tex._file, 130765, "...the item's icon")
-- An unknown saved style and size: the defaults drawn, the values kept.
fresh("neon", "huge")
node("Silverleaf", 31, -23)
step()
f = rec("Silverleaf").frame
eq(shows(f), "bronze", "an unknown style draws as auto (bronze here)")
eq(f._width, 12, "...an unknown size as medium")
eq(rawget(NR.db, "iconStyle"), "neon", "...the saved style kept")
eq(rawget(NR.db, "iconSize"), "huge", "...the saved size kept")

--------------------------------------------------------------------------------
-- A Disc that throws part-way, in one sweep with a disc that didn't
--------------------------------------------------------------------------------

fresh(nil, nil)
WoW.loadedAddons, G.loaded = { GlassMiniMap = true }, true
G.discs, G.discThrowsAt = 0, 2
node("Silverleaf", 31, -23)
node("Earthroot", -40, 30)
step()
local a, b2 = rec("Silverleaf").frame, rec("Earthroot").frame
eq(G.discs, 2, "two discs tried in the sweep")
eq(shows(a), "bronze", "the first, built in glass: bronze when the sweep returns")
eq(shows(b2), "bronze", "the second, whose Disc threw: bronze")
local failed = (a.glass == false) and b2 or a
check(a.glass and not a.glass._shown, "the glass built first is hidden")
eq(b2.glass, false, "the failed one isn't kept")
local hidden = true
for _, w in ipairs(WoW.frames) do
    if w._parent == b2 and w ~= b2.bronze and w ~= b2.arrowFrame and w._shown then hidden = false end
end
check(hidden, "...its part-built host stays hidden")
check(NR.failures.glass and NR.failures.glass.err:find("part%-way"), "...a failure")
local discs = G.discs
node("Peacebloom", 20, 40)
step()
step()
eq(G.discs, discs, "later sweeps build no glass")
eq(shows(rec("Peacebloom").frame), "bronze", "...a new node in bronze")
G.discThrowsAt = nil

--------------------------------------------------------------------------------
-- Sizes: each look scaled, never rebuilt
--------------------------------------------------------------------------------

fresh("bronze", nil)
node("Silverleaf", 31, -23)
step()
f = rec("Silverleaf").frame
local host = f.bronze
local k = 12 / 17
check(near(host._width, 31 * k), "bronze: the button 31/17 of the icon, built at medium")
local hp = host._points[1]
check(hp[1] == "CENTER" and hp[2] == f and near(hp[5], -k), "...anchored 1 below so the icon's centre is the node's")
local icon = host.icon
check(near(icon._points[1][4], 7 * k) and near(icon._points[1][5], -6 * k), "...the icon at LibDBIcon's (7, -6)")
eq(icon._width, 12, "...the icon 12")
for name, size in pairs({ small = 10, large = 14, medium = 12 }) do
    NR.Set("iconSize", name)
    eq(f._width, size, name .. ": the frame " .. size)
    check(near(f.bronze:GetScale(), size / 12), "...the ring scaled " .. size .. "/12")
    check(f.bronze == host, "...the same ring, not rebuilt")
end
NR.Set("iconStyle", "glass")
eq(shows(f), "glass", "a style change shows at once, without a sweep")
local gl = f.glass
NR.Set("iconSize", "large")
check(near(gl:GetScale(), 14 / 12) and f.glass == gl, "glass: scaled, not rebuilt")
NR.Set("iconStyle", "plain")
eq(shows(f), "plain", "plain again: the icon itself, the hosts hidden")
eq(f._width, 14, "...at the large size")
NR.Set("iconSize", "medium")

--------------------------------------------------------------------------------
-- Yellow (#50): our ring, the tracking dots' colour, needing nothing loaded
--------------------------------------------------------------------------------

-- The art: a band from 24.5 to 31.5 px, dark at both edges, white between.
local RING = "Media/IconRing.tga"
eq(select(4, pixel(RING, 32, 32)), 0, "the ring's art: clear in the middle")
eq(select(4, pixel(RING, 32 + 22, 32)), 0, "...clear inside the band")
check(select(4, pixel(RING, 32 + 28, 32)) > 250 and pixel(RING, 32 + 28, 32) > 240, "...white across the band")
check(pixel(RING, 32 + 25, 32) < 60 and pixel(RING, 32 + 31, 32) < 60, "...dark at its inner and outer edges")
fresh("yellow", nil)
local loaded = G.loaded
G.loaded = nil                                             -- no LibGlass: yellow needs none
node("Silverleaf", 31, -23)
step()
f = rec("Silverleaf").frame
eq(shows(f), "yellow", "yellow chosen: the ring")
eq(NR.failures.glass, nil, "...no glass failure")
eq(Icons.Style(), "yellow", "...the effective style yellow")
host = f.ring
check(near(host._width, 12 * 1.3) and near(host._height, 12 * 1.3), "the ring 1.3 of the icon, built at medium")
check(host._points[1][1] == "CENTER" and host._points[1][2] == f, "...centred on the node")
eq(host.ring._file, "Interface\\AddOns\\NodeRadar\\Media\\IconRing.tga", "...our ring's art")
check(near(host.ring._vertex[1], Icons.YELLOW[1]) and near(host.ring._vertex[2], Icons.YELLOW[2])
      and near(host.ring._vertex[3], Icons.YELLOW[3]), "...tinted the dots' yellow")
eq(host.icon._file, 130765, "...the item's icon in it")
eq(host.icon._width, 12, "...the icon 12")
check(host.icon._mask and host.icon._mask._file == "Interface\\CharacterFrame\\TempPortraitAlphaMask", "...masked round")
check(near(host.icon._texCoord[1], 0.08) and near(host.icon._texCoord[2], 0.92), "...its border cropped")
eq(host._mouse, false, "...no mouse")
for name, size in pairs({ small = 10, large = 14, medium = 12 }) do
    NR.Set("iconSize", name)
    check(near(f.ring:GetScale(), size / 12) and f.ring == host, name .. ": the ring scaled, not rebuilt")
end
NR.Set("iconStyle", "bronze")
eq(shows(f), "bronze", "yellow to bronze: the ring hidden")
NR.Set("iconStyle", "yellow")
eq(shows(f), "yellow", "...and back: the same ring")
check(f.ring == host, "...not rebuilt")
NR.Set("iconStyle", "plain")
eq(shows(f), "plain", "yellow to plain: the ring hidden")
NR.Set("iconStyle", "auto")
eq(shows(f), "bronze", "auto never yellow (no Glass MiniMap here: bronze)")
-- The dim, on the ring's icon.
WoW.skillLines[182] = { skillID = 182, rank = 10, modifier = 0, maxRank = 300 }
fresh("yellow", nil)
node("Mageroyal", -30, -30)
step()
eq(rec("Mageroyal").frame.ring.icon._desaturated, true, "a node the skill can't gather: dimmed in yellow")
WoW.skillLines[182] = nil
G.loaded = loaded

--------------------------------------------------------------------------------
-- Binding: a reused frame switched to a cached look between sweeps (Codex)
--------------------------------------------------------------------------------

fresh(nil, nil)
NR.db.iconStyle = "bronze"
nodes = {}
local sl = node("Silverleaf", 31, -23, { text = ABOVE .. "Silverleaf" })
step()
f = rec("Silverleaf").frame
NR.Set("iconStyle", "glass")                               -- both looks built on this frame
NR.Set("iconStyle", "bronze")
eq(f.arrowFrame._shown, true, "Silverleaf above: the arrow shown")
nodes = {}
step(); step()                                             -- Silverleaf gone: its frame released
eq(rec("Silverleaf"), nil, "Silverleaf gone")
WoW.skillLines[182] = { skillID = 182, rank = 10, modifier = 0, maxRank = 300 }
node("Mageroyal", -30, -30)
step()
local m = rec("Mageroyal")
check(m.frame == f, "Mageroyal reuses the frame")
NR.Set("iconStyle", "glass")                               -- the cached glass, no sweep
eq(shows(f), "glass", "switched to the cached glass")
check(f.glass.icon._file == m.icon and f.glass.icon._file ~= 130765, "...Mageroyal's icon, not Silverleaf's")
eq(f.glass.icon._desaturated, true, "...dimmed as Mageroyal is")
eq(f.arrowFrame._shown, false, "...no stale arrow: Mageroyal is level")
WoW.skillLines[182] = nil
-- A record's arrow follows its blip each sweep, and goes when level.
fresh("bronze", nil)
sl = node("Silverleaf", 31, -23, { text = BELOW .. "Silverleaf" })
step()
f = rec("Silverleaf").frame
eq(rec("Silverleaf").height, "below", "the record below")
eq(f.arrowFrame._shown, true, "...the arrow shown")
local ap = f.arrow._points[1]
check(ap and near(ap[5], -(12 * 31 / 34 + 2)), "...under the ring")
check(near(f.arrow._texCoord[3], 0.5) and near(f.arrow._texCoord[4], 1), "...Blizzard's lower half")
sl.text = ABOVE .. "Silverleaf"
step()
check(near(f.arrow._points[1][5], 12 * 31 / 34 + 2) and near(f.arrow._texCoord[3], 0), "above: over it, the upper half")
NR.Set("iconStyle", "yellow")
check(near(f.arrow._points[1][5], 12 * 0.65 + 2), "yellow: the arrow over the ring")
sl.text = nil
step()
eq(rec("Silverleaf").height, nil, "level again: no height")
eq(f.arrowFrame._shown, false, "...no arrow")

--------------------------------------------------------------------------------
-- The rim at each look's extent: dropped only once faded out
--------------------------------------------------------------------------------

for _, case in ipairs({ { "plain", 6 }, { "bronze", 12 * 31 / 34 }, { "yellow", 12 * 0.65 } }) do
    fresh(case[1], nil)
    sl = node("Silverleaf", 60, 0)
    step()
    local r = rec("Silverleaf")
    local edge = 99 - case[2]
    WoW.pos[2] = WoW.pos[2] + (edge - 2 - 60) * K()        -- west: the node goes east, 2 inside the edge
    T.draw()
    check(r.frame._shown and r.frame._alpha > 0 and r.frame._alpha < 1, case[1] .. ": fading 2 inside its edge")
    WoW.pos[2] = WoW.pos[2] + 2.5 * K()
    T.draw()
    eq(r.frame._shown, false, "...hidden past it")
    step()
    eq(rec("Silverleaf"), nil, "...and dropped at the sweep")
    WoW.pos = { 0, 0, 1 }
end

-- Mouse: every frame under an icon frame turns it off, the glass's top included
-- (a failed disc's part-built host is never shown, its frames left as built).
local mouse, under = true, 0
for _, w in ipairs(WoW.frames) do
    local p, top = w._parent, w
    while p and not (p.tex and p.arrowFrame) do top, p = p, p._parent end
    local kept = p and (top == p.glass or top == p.bronze or top == p.ring or top == p.arrowFrame)
    if kept and w._type == "Frame" then
        under = under + 1
        if w._mouse ~= false then mouse = false end
    end
end
check(under > 5, "frames under the icon frames: " .. under)
check(mouse, "every one takes no mouse, explicitly")

eq(#WoW.chat, 0, "nothing in chat")
eq(WoW.softCursor, false, "the soft cursor is off")
checkMethods({ "Frame:SetScale", "Frame:CreateMaskTexture", "Texture:AddMaskTexture" })
done("test_styles")
