-- Icons.lua: the item's icon over each node's dot on the minimap (#28,
-- docs/PLAN.md, "Item icons on the minimap's nodes").
--
-- A sweep's blip is up to 5.5 units off its node (the grid's centroid), so a
-- new node's centre is measured once (Scan.Centre) and kept as a record in
-- world yards (UnitPosition: north, west). Later sweeps match records to blips
-- by name and distance; every frame draws them from the player's position.
-- Off (the default, Blizzard's dots), none of this runs. Each icon's frame
-- follows the minimap (#41): glass with Glass MiniMap, else bronze; or a
-- yellow ring, the tracking dots' colour (#50).

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Icons = {}
NR.Icons = Icons

Icons.MATCH = 8        -- map units: a record and a blip of its name are the same node (5.5 + 2)
Icons.INSIDE = 18      -- map units: a blip this far inside the rim is whole (5.5 + 12.5)
Icons.TRIES = 4        -- blips measured a sweep at most
Icons.RETRY = 5        -- seconds before a blip that failed is tried again
Icons.FORGET = 30      -- seconds unseen before a failed try is forgotten
Icons.LINGER = 30      -- seconds at most a gathered node's dot is left out while still seen
Icons.GATHERED = 15    -- yards: a gather drops the records of its name this near the player
Icons.GRACE = 2        -- seconds past the idle interval without a sweep before the icons hide
Icons.SIZE = 12        -- map units: the medium icon (the dot is about 8), what the looks are built at
Icons.FADE = 4         -- map units of fading before the look's edge meets the rim
Icons.DIM = 0.6        -- alpha of a node the player can't gather
Icons.FALLBACK = { herbs = 2383, ore = 2580 }   -- Find Herbs, Find Minerals: their icons

-- The look (#41, docs/PLAN.md "Icon styles and sizes"): the icon's size, and
-- its frame following the minimap: glass with Glass MiniMap, bronze otherwise.
Icons.SIZES = { small = 10, medium = 12, large = 14 }
Icons.STYLES = { auto = true, plain = true, glass = true, bronze = true, yellow = true }
Icons.YELLOW = { 0.92, 0.75, 0.11 }   -- the tracking dots' lit yellow (#50, measured: docs/FOREVER-PROBE.md)
Icons.GLASS_MINOR = 6  -- LibGlass-1.0's clean preset (r6); Disc is r2
Icons.ARROW = 8        -- map units: our height arrow (Blizzard's is hidden by a ring, #41)
-- Half of what each look draws, at an icon of `s`: the rim fades and drops by it.
Icons.EXTENT = {
    plain = function(s) return s / 2 end,
    glass = function(s) return s * 0.75 end,        -- the disc, 1.5 times the icon
    bronze = function(s) return s * 31 / 34 end,    -- the button, 31/17 times the icon
    yellow = function(s) return s * 0.65 end,       -- the ring, 1.3 times the icon
}

-- Blizzard's round minimap button as LibDBIcon lays it out on a 31-unit button
-- (bronze round, docs/FOREVER-PROBE.md): the ring 53 at its top left, the dark
-- background 20 at (7, -5), the icon 17 at (7, -6).
local RING, RING_BG = 136430, 136467    -- MiniMap-TrackingBorder, UI-Minimap-Background
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local ARROWS = "Interface\\Minimap\\Minimap-PositionArrows"

local records = {}     -- { name, kind, north, west, icon, misses, dim, height, x, y, frame }
local tries = {}       -- { name, north, west, at, seen }: blips that failed to measure
local gone = {}        -- { name, north, west, units | yards, at }: nodes just gathered, their dots
                       -- left out until they vanish (the loot window keeps them)
local free = {}        -- hidden frames, reused
local lastSweep        -- when the icons last reconciled
local instance         -- UnitPosition's fourth value at that sweep
local look = { style = "plain", size = Icons.SIZE, extent = Icons.SIZE / 2 }   -- the effective look
-- LibGlass, borrowed from Glass MiniMap (nothing embedded): nil untried, false
-- failed for the session (the latch), else our clean instance.
local glass
local glassMiniMap     -- nil unread, else whether Glass MiniMap is loaded
local restyle          -- the glass latch tripped during a pass: bind everything again

local driver = CreateFrame("Frame")

-- Drawn: the radar and the icons on.
function Icons.On()
    local db = NR.db
    return db and db.icons and db.enabled and true or false
end

-- Kept: the records, for the icons or the compass (#29), whichever is on.
function Icons.Keeping()
    local db = NR.db
    return db and db.enabled and (db.icons or db.compass) and true or false
end

-- The player in UnitPosition's frame: north, west (HereBeDragons-2.0 reads its
-- first value as north, its second as west) and the instance; nil when any is
-- missing or secret.
local function player()
    local ok, n, w, _, inst = pcall(UnitPosition, "player")
    if not ok then return nil end
    n, w, inst = API.Num(n), API.Num(w), API.Num(inst)
    if not (n and w and inst) then return nil end
    return n, w, inst
end

local function dist(x, y) return math.sqrt(x * x + y * y) end

local function release(r)
    if r.frame then
        r.frame:Hide()
        free[#free + 1] = r.frame
        r.frame = nil
    end
end


local function acquire()
    local f = table.remove(free)
    if f then return f end
    f = CreateFrame("Frame", nil, Minimap)
    f:SetSize(Icons.SIZE, Icons.SIZE)
    f:EnableMouse(false)                       -- the player's hover tooltip goes through
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints(f)
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- the icon's border trimmed
    -- The height arrow, over any look (the glass's top is its host's level + 10).
    f.arrowFrame = CreateFrame("Frame", nil, f)
    f.arrowFrame:EnableMouse(false)
    f.arrowFrame:SetAllPoints(f)
    f.arrowFrame:SetFrameLevel(f:GetFrameLevel() + 12)
    f.arrow = f.arrowFrame:CreateTexture(nil, "OVERLAY")
    f.arrow:SetTexture(ARROWS)
    f.arrow:SetSize(Icons.ARROW, Icons.ARROW)
    f.arrowFrame:Hide()
    f:Hide()
    Icons._test.frames = Icons._test.frames + 1
    return f
end

--------------------------------------------------------------------------------
-- The looks (#41)
--------------------------------------------------------------------------------

-- The glass failed: no glass again this session, and everything is bound again
-- (to bronze) when the pass that tripped it ends (Codex, #41).
local function glassFailed(why)
    glass = false
    restyle = true
    API.Fail("glass", why)
end

-- Our LibGlass instance, or nil: the copy a Glass addon loaded, minor 6 or more.
local function glassInst()
    if glass ~= nil then return glass or nil end
    local stub = rawget(_G, "LibStub")
    if not stub then
        glassFailed("LibGlass-1.0 isn't loaded (glass needs Glass MiniMap)")
        return nil
    end
    local ok, lib, minor = pcall(stub, "LibGlass-1.0", true)
    if not (ok and lib) then
        glassFailed("LibGlass-1.0 isn't loaded (glass needs Glass MiniMap)")
        return nil
    end
    if not (API.Num(minor) and minor >= Icons.GLASS_MINOR) then
        glassFailed("LibGlass-1.0 minor " .. tostring(minor) .. " is older than " .. Icons.GLASS_MINOR)
        return nil
    end
    local okNew, inst = pcall(lib.New, lib, { preset = "clean" })
    if not (okNew and type(inst) == "table") then
        glassFailed("LibGlass-1.0 New: " .. tostring(inst))
        return nil
    end
    glass = inst
    return inst
end

local function hasGlassMiniMap()
    if glassMiniMap == nil then
        local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, "GlassMiniMap")
        glassMiniMap = ok and API.Yes(loaded) or false
    end
    return glassMiniMap
end

-- The effective style from the settings: an unknown value is the default,
-- auto follows the minimap, glass that can't be had is bronze.
local function styleOf()
    local db = NR.db
    local style = Icons.STYLES[db.iconStyle] and db.iconStyle or NR.DEFAULTS.iconStyle
    if style == "auto" then style = hasGlassMiniMap() and "glass" or "bronze" end
    if style == "glass" and not glassInst() then style = "bronze" end
    return style
end

-- The effective look for the icons: the style and the size.
local function resolve()
    local db = NR.db
    local size = Icons.SIZES[db.iconSize] or Icons.SIZES[NR.DEFAULTS.iconSize]
    local style = styleOf()
    look = { style = style, size = size, extent = Icons.EXTENT[style](size) }
    return look
end

-- For the compass's ring (#29), which follows the icons' frame setting: the
-- effective style (glass: a pearl rim, bronze: a bronze one, yellow: a yellow
-- one, plain: none; the
-- compass draws our own art). Resolving may latch glass off; it draws no
-- minimap icon.
function Icons.Style()
    local style = styleOf()
    return style, style == "glass" and glass or nil
end


-- A glass disc as Glass MiniMap's Ring.AddDisc builds one, at the medium size:
-- a square host, the icon inset a quarter of its size, masked round. Built
-- hidden, shown only once whole (Disc isn't transactional: Codex, #41).
local function buildGlass(f, inst)
    local host = CreateFrame("Frame", nil, f)
    host:Hide()
    host:EnableMouse(false)
    local size = Icons.SIZE * 1.5
    host:SetSize(size, size)
    host:SetPoint("CENTER", f, "CENTER")
    local ok, err = pcall(function()
        local g = inst.Disc(host, "disc_small")
        if type(g) == "table" and g.top then g.top:EnableMouse(false) end
        local inset = Icons.SIZE / 4
        local icon = host:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", host, "TOPLEFT", inset, -inset)
        icon:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -inset, inset)
        icon:AddMaskTexture(inst.Mask(host, "disc_mask_small", nil, inset))
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        host.icon = icon
    end)
    if not ok then
        glassFailed("Disc: " .. tostring(err))
        return nil
    end
    return host
end

-- Blizzard's round button, at the medium size; SetScale resizes it, the
-- offset scaling with it, so the icon's centre stays on the node.
local function buildBronze(f)
    local k = Icons.SIZE / 17
    local host = CreateFrame("Frame", nil, f)
    host:Hide()
    host:EnableMouse(false)
    host:SetSize(31 * k, 31 * k)
    host:SetPoint("CENTER", f, "CENTER", 0, -1 * k)  -- the icon's centre is 1 above the button's
    local ring = host:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53 * k, 53 * k)
    ring:SetTexture(RING)
    ring:SetPoint("TOPLEFT", host, "TOPLEFT")
    local bg = host:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20 * k, 20 * k)
    bg:SetTexture(RING_BG)
    bg:SetPoint("TOPLEFT", host, "TOPLEFT", 7 * k, -5 * k)
    local icon = host:CreateTexture(nil, "ARTWORK")
    icon:SetSize(Icons.SIZE, Icons.SIZE)
    icon:SetPoint("TOPLEFT", host, "TOPLEFT", 7 * k, -6 * k)
    local mask = host:CreateMaskTexture()
    mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    host.icon = icon
    return host
end

-- Our yellow ring (#50, Media/IconRing.tga, its inner edge the icon's) around
-- the icon masked round, at the medium size.
local function buildRing(f)
    local host = CreateFrame("Frame", nil, f)
    host:Hide()
    host:EnableMouse(false)
    host:SetSize(Icons.SIZE * 1.3, Icons.SIZE * 1.3)
    host:SetPoint("CENTER", f, "CENTER")
    local ring = host:CreateTexture(nil, "OVERLAY")
    ring:SetAllPoints(host)
    ring:SetTexture(NR.Alert.MEDIA .. "IconRing.tga")
    ring:SetVertexColor(Icons.YELLOW[1], Icons.YELLOW[2], Icons.YELLOW[3])
    local icon = host:CreateTexture(nil, "ARTWORK")
    icon:SetSize(Icons.SIZE, Icons.SIZE)
    icon:SetPoint("CENTER", host, "CENTER")
    local mask = host:CreateMaskTexture()
    mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    host.ring, host.icon = ring, icon
    return host
end

-- A frame shows its record in the effective look: the look built if needed,
-- the others hidden, its icon, dim and arrow set, then shown (Codex, #41: a
-- cached look switched to between sweeps never shows another record's state).
local function bind(r)
    local f = r.frame
    local style, size = look.style, look.size
    if style == "glass" and f.glass == nil then
        local inst = glassInst()
        f.glass = inst and buildGlass(f, inst) or false
    end
    if style == "glass" and not (f.glass and glass) then style = "bronze" end
    if style == "bronze" and not f.bronze then f.bronze = buildBronze(f) end
    if style == "yellow" and not f.ring then f.ring = buildRing(f) end
    local host = style == "glass" and f.glass or style == "bronze" and f.bronze
                 or style == "yellow" and f.ring or nil
    if f.glass and f.glass ~= host then f.glass:Hide() end
    if f.bronze and f.bronze ~= host then f.bronze:Hide() end
    if f.ring and f.ring ~= host then f.ring:Hide() end
    f:SetSize(size, size)
    if host then
        host:SetScale(size / Icons.SIZE)
        host.icon:SetTexture(r.icon)
        host.icon:SetDesaturated(r.dim)
        f.tex:Hide()
        host:Show()
    else
        f.tex:SetTexture(r.icon)
        f.tex:SetDesaturated(r.dim)
        f.tex:Show()
    end
    if r.height == "above" or r.height == "below" then
        local up = r.height == "above"
        f.arrow:SetTexCoord(0, 1, up and 0 or 0.5, up and 0.5 or 1)
        f.arrow:ClearAllPoints()
        f.arrow:SetPoint("CENTER", f, "CENTER", 0, (up and 1 or -1) * (Icons.EXTENT[style](size) + 2))
        f.arrowFrame:Show()
    else
        f.arrowFrame:Hide()
    end
end

-- Every shown record bound again; once more if the glass latch tripped
-- meanwhile, and then the compass too (its glass is the same latch's, #29).
local function bindAll()
    local tripped = false
    for _ = 1, 2 do
        restyle = false
        resolve()
        for _, r in ipairs(records) do
            if r.frame and r.misses == 0 then bind(r) end
        end
        if not restyle then break end
        tripped = true
    end
    if tripped and NR.Compass then NR.Compass.Restyle() end
end

-- Whether records of a skipped name are kept (#47): only to draw them dimmed.
-- With Blizzard's dot chosen, or the compass alone, a skipped node is never
-- measured nor kept.
local function keepsSkipped()
    return Icons.On() and NR.db.ignoredIcon ~= "dot"
end

-- The choices changed (#47, Track): the records of skipped names go when they
-- aren't kept, at once; the rest bound again, so a dim follows.
function Icons.Refilter()
    local keep, kept = keepsSkipped(), {}
    for _, r in ipairs(records) do
        if keep or not NR.Alert.Ignored(r.name) then kept[#kept + 1] = r else release(r) end
    end
    records = kept
    if Icons.On() then Icons.Show() end
end

-- The style or size changed (NR.Set): every icon shown in the new look now.
function Icons.Restyle()
    if not Icons.On() then return end
    bindAll()
end

local function stop()
    driver:SetScript("OnUpdate", nil)
end

local function hideAll()
    for _, r in ipairs(records) do if r.frame then r.frame:Hide() end end
    stop()
end

-- Everything forgotten: the records, the failed tries, the frames hidden;
-- the compass pointing at none of them (#29).
function Icons.Clear()
    for _, r in ipairs(records) do release(r) end
    records, tries, gone, lastSweep, instance = {}, {}, {}, nil, nil
    stop()
    if NR.Compass then NR.Compass.Reset() end
end

-- The icons turned off while the compass keeps the records: the frames go,
-- the records stay.
function Icons.Release()
    for _, r in ipairs(records) do release(r) end
    stop()
end

-- The records, for the compass to read (never to change).
function Icons.Records() return records end

-- The item's icon, else the tracking spell's (no item, or no answer).
local function iconOf(name, kind)
    local info = NR.Learn.Info(name)
    local item = info and API.Num(info.item)
    if item then
        local ok, icon = pcall(C_Item.GetItemIconByID, item)
        if ok and icon ~= nil and not API.IsSecret(icon) then return icon end
    end
    local spell = Icons.FALLBACK[kind]
    local ok, icon = pcall(C_Spell.GetSpellTexture, spell)
    if ok and icon ~= nil and not API.IsSecret(icon) then return icon end
end

-- Each frame while an icon shows: where every shown record is now.
local function draw()
    local db = NR.db
    if not (Icons.On() and lastSweep) or GetTime() - lastSweep > db.interval + Icons.GRACE then
        hideAll()
        return
    end
    local pn, pw, inst = player()
    local okR, radius = pcall(C_Minimap.GetViewRadius)
    radius = okR and API.Num(radius)
    local okG, _, _, w = pcall(Minimap.GetRect, Minimap)
    w = okG and API.Num(w)
    if not (pn and radius and w) or inst ~= instance or radius <= 0 or w <= 0 then
        hideAll()
        return
    end
    local half = w / 2
    local k = radius / half
    local edge = half - look.extent
    for _, r in ipairs(records) do
        local f = r.frame
        if f and r.misses == 0 then
            local x, y = -(r.west - pw) / k, (r.north - pn) / k
            local alpha = math.max(0, math.min(1, (edge - dist(x, y)) / Icons.FADE))
            if alpha > 0 then
                f:ClearAllPoints()
                f:SetPoint("CENTER", Minimap, "CENTER", x, y)
                f:SetAlpha(alpha * (r.dim and Icons.DIM or 1))
                f:Show()
            else
                f:Hide()
            end
        end
    end
end

-- The failed try a blip is, if any: its name within MATCH units.
local function tryOf(b, pn, pw, k)
    for _, t in ipairs(tries) do
        if t.name == b.name and dist(-(t.west - pw) / k - b.x, (t.north - pn) / k - b.y) <= Icons.MATCH then
            return t
        end
    end
end

-- Every record seen at the last sweep drawn: at each sweep, and when the
-- icons are turned on over records the compass kept (#29).
function Icons.Show()
    if not Icons.On() then
        stop()                                         -- the compass alone: no frame, no look (#29)
        return
    end
    resolve()
    local any = false
    for _, r in ipairs(records) do
        if r.misses == 0 then
            -- Beyond the skill, skipped (#47), or snoozed (#46).
            r.dim = not NR.Alert.Wanted(r.name) or (NR.Compass ~= nil and NR.Compass.Snoozed(r))
            if not r.frame then r.frame = acquire() end
            any = true
        end
    end
    bindAll()
    if any then
        driver:SetScript("OnUpdate", draw)
        draw()
    else
        stop()
    end
end

-- After each successful radar sweep, before the alert (Codex, #28: the sonar
-- finds a new node's record) and the learner (which can clear them at once).
function Icons.Update(result, now)
    if not Icons.Keeping() then return end
    local where, g = result.where, result.geometry
    local pn, pw, inst = player()
    if not (where and g and pn) then
        Icons.Clear()
        return
    end
    if instance and inst ~= instance then Icons.Clear() end
    instance = inst
    local half = g.w / 2
    local k = where.radius / half
    if Icons.On() then resolve() end                   -- the compass alone resolves no look (#29)

    -- A node just gathered stays on the map while its loot window is open: its
    -- dot is left out (not matched, not measured), or the compass took it for
    -- the nearest, within 15 yards, and hid (the owner's video, #29). An entry
    -- goes once its dot isn't seen, or after LINGER.
    local fresh = {}
    for _, e in ipairs(gone) do
        if now - e.at < Icons.LINGER then e.seen = false; fresh[#fresh + 1] = e end
    end
    gone = fresh
    local function lingering(b)
        for _, e in ipairs(gone) do
            local near = e.units or e.yards / k
            if e.name == b.name and dist(-(e.west - pw) / k - b.x, (e.north - pn) / k - b.y) <= near then
                e.seen = true
                return true
            end
        end
        return false
    end

    local blips = {}
    local keep = keepsSkipped()
    for _, b in ipairs(result.blips) do
        if NR.Learn.Kind(b.name) and (keep or not NR.Alert.Ignored(b.name)) and not lingering(b) then
            blips[#blips + 1] = b
        end
    end
    local seen = {}
    for _, e in ipairs(gone) do if e.seen then seen[#seen + 1] = e end end
    gone = seen

    -- Match: by name within MATCH units, one to one, nearest pairs first.
    local pairsNear = {}
    for _, r in ipairs(records) do
        r.x, r.y = -(r.west - pw) / k, (r.north - pn) / k
        for _, b in ipairs(blips) do
            if b.name == r.name then
                local d = dist(r.x - b.x, r.y - b.y)
                if d <= Icons.MATCH then pairsNear[#pairsNear + 1] = { d = d, r = r, b = b } end
            end
        end
    end
    table.sort(pairsNear, function(a, b) return a.d < b.d end)
    local matched = {}
    for _, p in ipairs(pairsNear) do
        if not matched[p.r] and not p.b.record then
            matched[p.r] = true
            p.b.record = p.r
            p.r.height = p.b.height                -- nil too: an arrow never outlives its height
        end
    end

    -- Missed: hidden at once, dropped at the second; faded out past the rim, dropped.
    local kept = {}
    for _, r in ipairs(records) do
        r.misses = matched[r] and 0 or r.misses + 1
        if r.misses >= 2 or dist(r.x, r.y) >= half - look.extent then
            release(r)
        else
            if r.misses > 0 and r.frame then r.frame:Hide() end
            kept[#kept + 1] = r
        end
    end
    records = kept

    -- New: whole blips with no record. Never tried first, nearest the centre
    -- first; then those tried RETRY s ago or more, longest ago first.
    local fresh, again = {}, {}
    for _, b in ipairs(blips) do
        if not b.record and dist(b.x, b.y) + Icons.INSIDE <= half then
            local t = tryOf(b, pn, pw, k)
            if t then
                t.seen = now
                if now - t.at >= Icons.RETRY then b.try = t; again[#again + 1] = b end
            else
                fresh[#fresh + 1] = b
            end
        end
    end
    table.sort(fresh, function(a, b) return dist(a.x, a.y) < dist(b.x, b.y) end)
    table.sort(again, function(a, b) return a.try.at < b.try.at end)
    local measure = {}
    for _, list in ipairs({ fresh, again }) do
        for _, b in ipairs(list) do
            if #measure < Icons.TRIES then measure[#measure + 1] = b end
        end
    end
    if #measure > 0 and NR.Scan.Centre(measure) then
        for _, b in ipairs(measure) do
            if b.cx then
                local r = { name = b.name, kind = NR.Learn.Kind(b.name), north = pn + b.cy * k, west = pw - b.cx * k,
                            misses = 0, x = b.cx, y = b.cy, height = b.height }
                r.icon = iconOf(r.name, r.kind)
                records[#records + 1] = r
                b.record = r
            elseif b.try then
                b.try.at = now
            else
                tries[#tries + 1] = { name = b.name, north = pn + b.y * k, west = pw - b.x * k, at = now, seen = now }
            end
        end
    end
    local keptTries = {}
    for _, t in ipairs(tries) do
        if now - t.seen < Icons.FORGET then keptTries[#keptTries + 1] = t end
    end
    tries = keptTries

    -- Shown: every record seen this sweep, dimmed as the alert's skill rule
    -- and the player's choices say (#26, #47), each frame bound to its record in the look. Only with the icons
    -- on: for the compass alone, no frame, no look, no driver (Codex, #29).
    lastSweep = now
    Icons.Show()
end

-- The player gathered a node of that name: its records within GATHERED yards
-- go, so a node of the name beside it is measured, not matched to it (Codex).
function Icons.Gathered(name)
    if not Icons.Keeping() then return end
    local pn, pw = player()
    if not pn then return end
    local kept, dropped = {}, false
    local now = GetTime()
    for _, r in ipairs(records) do
        if r.name == name and dist(r.north - pn, r.west - pw) <= Icons.GATHERED then
            release(r)
            gone[#gone + 1] = { name = name, north = r.north, west = r.west, units = Icons.MATCH, at = now }
            dropped = true
        else
            kept[#kept + 1] = r
        end
    end
    records = kept
    -- Gathered before it was measured: its dot is somewhere by the player.
    if not dropped then
        gone[#gone + 1] = { name = name, north = pn, west = pw, yards = Icons.GATHERED, at = now }
    end
    if NR.Compass then NR.Compass.Refresh() end        -- on to the next node, once the list is filtered
end

-- Where the sonar goes for an alerted blip: its record's centre when it has one.
function Icons.At(b)
    local r = b.record
    if r and r.x then return r.x, r.y end
    return b.x, b.y
end

Icons._test = { frames = 0, records = function() return records end, tries = function() return tries end,
                gone = function() return gone end,
                draw = draw, driver = driver, look = function() return look end,
                reset = function() glass, glassMiniMap, restyle, free = nil, nil, nil, {} end }
