-- ScanFace.lua: a stand-in at the minimap's home while the scan borrows it (#103).
--
-- From 70862 the scan (MoveScan.lua) moves `Minimap` under the resting cursor for about 150 ms,
-- invisible, up to 8 times in a row while a node is located. Blizzard's frame ring
-- (`MinimapBackdrop`, `MinimapCompassTexture`) is a child of `Minimap`, so the whole stock
-- minimap vanished meanwhile: it read as a blink. Instead a radar face of ours covers the home:
-- a dark disc, faint range rings and a crosshair, a sweep turning clockwise, under a copy of
-- whatever frame ring Blizzard draws there (its atlas, size and place read at the borrow).
--
-- The timing is Glass MiniMap's (GlassMiniMap#59), so both skins look alike: at full opacity
-- in the same call as the borrow (no frame shows the empty spot), held HOLD seconds over the
-- returned map after the restore, then faded over FADE; a borrow meanwhile brings it straight
-- back, so a run of bursts reads as one ping. Never left up: hidden on every exit, and MAX
-- seconds at full without an end starts the hold anyway. A hidden map hides it at once.
--
-- Who draws it, decided at each borrow (#103, agreed with Glass MiniMap's session):
--   - Glass MiniMap not loaded: ours;
--   - version 1 with `ScanStandIn`: ours only if it answers false (its ring failed to build);
--   - version 1 without it (1.1.0): none (ours would stack over its ring).
-- Our own unnamed frame on UIParent, mouse off: nothing of Blizzard's touched, only read.
--
-- The real ground (#117): where it can, the face draws the minimap's own tiles around the player
-- (Data/MinimapTiles.lua, by FileDataID), under the map's mask, with the player arrow, so a look
-- barely shows; the radar face is the fallback (SF.Ground() says why).
--
-- In the map's shape (SF.Shape): a square skin's map gets a square plate, not our disc over it.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local SF = {}
NR.ScanFace = SF

SF.HOLD = 0.4           -- seconds at full after the restore
SF.FADE = 0.2           -- ...then out over this
SF.TURN = 1.2           -- seconds per turn of the sweep
SF.MAX = 1              -- seconds at full without an End: the hold starts anyway
SF.BODY = { 0.03, 0.035, 0.045, 0.92 }
SF.TINT = { 0.92, 0.75, 0.11 }      -- the tracking dots' yellow (Icons.YELLOW, #50)
SF.LINES_ALPHA = 0.3
SF.SWEEP_ALPHA = 0.55
SF.TILE = 1600 / 3      -- yards a minimap tile is wide (#117)
SF.GROUND_TINT = { 1, 1, 1 }        -- measured in /fp steps nr ground
SF.ARROW = 32           -- the player arrow, in the minimap's units
SF.MASK_ATLAS = "ui-hud-minimap-frame-generic-mask"   -- Blizzard's own (Blizzard_Minimap/Camelot)
SF.STOCK_RINGS = { ["ui-hud-minimap-frame"] = true, ["ui-hud-minimap-frame-pointer"] = true }
SF.WARM_EVERY = 1       -- seconds between loads of the tiles around the player, outside a borrow
SF.ARROW_TEXTURE = "Interface\\Minimap\\MinimapArrow"
-- A square map's face (a skin's): a plain plate, the tiles under a square mask (the one the
-- square skins give the map themselves).
SF.SQUARE_BODY = "Interface\\Buttons\\WHITE8X8"
SF.SQUARE_MASK = "Interface\\ChatFrame\\ChatFrameBackground"

local TWO_PI = 2 * math.pi
local face, body, lines, sweep, rings
local clip, mask, top, tiles, arrow -- the real ground (#117): a clipping frame, its mask, the frame above it, 9 tiles, the arrow
local warmedAt = -math.huge
local attempts = 0      -- texture loads attempted by the current warm-up, whatever came of them
local state             -- nil (hidden), "full" (a borrow under way), "hold" (held, then fading), "preview"
local since, angle = 0, 0
local previewFor = 0    -- seconds a preview stays up
local grounded = false  -- the ground drawn for the face shown now

-- A method's answer, nil if it throws or is secret.
local function ask(obj, method, ...)
    if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
    local ok, v, w = pcall(obj[method], obj, ...)
    if not ok or API.IsSecret(v) or API.IsSecret(w) then return nil end
    return v, w
end

-- Who draws the stand-in for a borrow (MoveScan.Glass's answer): true when it's ours.
function SF.Ours(glass, g)
    if glass == "none" then return true end
    if glass ~= "v1" or type(g) ~= "table" then return false end
    local f = rawget(g, "ScanStandIn")
    if type(f) ~= "function" then return false end
    local ok, yes = pcall(f)
    return ok and yes == false
end

local function cancel()
    state = nil
    if not face then return end
    face:Hide()
    face:SetAlpha(1)
end
SF.Cancel = cancel

local function step(_, elapsed)
    angle = (angle - elapsed * TWO_PI / SF.TURN) % TWO_PI    -- clockwise
    sweep:SetRotation(angle)
    if ask(Minimap, "IsVisible") ~= true then return cancel() end   -- the map hidden (ToggleMinimap)
    since = since + elapsed
    if grounded and arrow then
        local okF, facing = pcall(GetPlayerFacing)
        if okF and API.Num(facing) then arrow:SetRotation(facing) end
    end
    if state == "preview" then
        if since >= previewFor then cancel() end
        return
    end
    if state == "full" then
        if since >= SF.MAX then state, since = "hold", 0 end
        return
    end
    if since < SF.HOLD then return end
    local a = 1 - (since - SF.HOLD) / SF.FADE
    if a > 0 then face:SetAlpha(a) else cancel() end
end

local function build()
    if face then return end
    local media = NR.Alert.MEDIA
    face = CreateFrame("Frame", nil, UIParent)
    face:Hide()
    face:EnableMouse(false)
    body = face:CreateTexture(nil, "BACKGROUND")
    body:SetAllPoints(face)
    body:SetTexture(media .. "ScanDisc.tga")
    body:SetVertexColor(SF.BODY[1], SF.BODY[2], SF.BODY[3], SF.BODY[4])
    lines = face:CreateTexture(nil, "ARTWORK")
    lines:SetAllPoints(face)
    lines:SetTexture(media .. "ScanFace.tga")
    lines:SetVertexColor(SF.TINT[1], SF.TINT[2], SF.TINT[3], SF.LINES_ALPHA)
    sweep = face:CreateTexture(nil, "ARTWORK", nil, 1)
    sweep:SetAllPoints(face)
    sweep:SetTexture(media .. "ScanSweep.tga")
    sweep:SetBlendMode("ADD")
    sweep:SetVertexColor(SF.TINT[1], SF.TINT[2], SF.TINT[3], SF.SWEEP_ALPHA)
    -- The real ground (#117): a child frame over the disc, clipped to the face's square and
    -- masked by Blizzard's own minimap mask; the arrow and the ring copies on a frame above it
    -- (a child frame draws over its parent's textures, whatever their layer: Codex).
    clip = CreateFrame("Frame", nil, face)
    clip:SetAllPoints(face)
    clip:EnableMouse(false)
    if type(clip.SetClipsChildren) == "function" then clip:SetClipsChildren(true) end
    mask = clip:CreateMaskTexture()
    mask:SetAllPoints(clip)
    mask:SetAtlas(SF.MASK_ATLAS)
    tiles = {}
    for i = 1, 9 do
        local t = clip:CreateTexture(nil, "BACKGROUND", nil, 1)
        t:AddMaskTexture(mask)
        -- Loaded outside the borrow (SF.Warm), so blocking there costs nothing inside one.
        if type(t.SetBlockingLoadsRequested) == "function" then t:SetBlockingLoadsRequested(true) end
        t:Hide()
        tiles[i] = t
    end
    top = CreateFrame("Frame", nil, face)
    top:SetAllPoints(face)
    top:EnableMouse(false)
    top:SetFrameLevel(clip:GetFrameLevel() + 1)
    arrow = top:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture(SF.ARROW_TEXTURE)
    arrow:SetPoint("CENTER", face, "CENTER", 0, 0)
    arrow:Hide()
    -- Blizzard's ring, and its underlay in the rotating mode, copied on top.
    rings = { top:CreateTexture(nil, "OVERLAY", nil, 1), top:CreateTexture(nil, "OVERLAY", nil, 2) }
    face:SetScript("OnUpdate", step)
end

-- A tile's FileDataID, or nil (Data/MinimapTiles.lua: x east, y south).
function SF.TileID(instance, x, y)
    local list = NR.MINIMAP_TILES and NR.MINIMAP_TILES[instance]
    return list and list[x * 64 + y] or nil
end

-- The stock minimap: its ring showing with Blizzard's atlas. Drawn, not just shown: a skin can
-- fade the stock ring and keep its atlas (Codex).
local function stock()
    local ring = rawget(_G, "MinimapCompassTexture")
    local atlas = ask(ring, "GetAtlas")
    local alpha, palpha = API.Num(ask(ring, "GetAlpha")), API.Num(ask(ask(ring, "GetParent"), "GetEffectiveAlpha"))
    return ask(ring, "IsVisible") == true and type(atlas) == "string" and SF.STOCK_RINGS[atlas:lower()] == true
        and alpha ~= nil and alpha > 0 and palpha ~= nil and palpha > 0
end

-- GetMinimapShape's names (LibDBIcon's convention, which the square skins declare): how many of
-- the four quarters are round.
local ROUND_QUARTERS = { ROUND = 4, SQUARE = 0 }
local function roundQuarters(name)
    if ROUND_QUARTERS[name] then return ROUND_QUARTERS[name] end
    if name:find("^TRICORNER%-") then return 3 end
    if name:find("^CORNER%-") then return 1 end
    if name:find("^SIDE%-") then return 2 end
end
-- EllesmereUI's own (its minimap declares no GetMinimapShape): its module's MinimapShape().
local ELLESMERE = { circle = "round", textured_circle = "round", square = "square", rectangular = "square" }
local function ellesmere()
    local ok, shape = pcall(function()
        local f = EllesmereUI._ModuleNS.EllesmereUIMinimap.MinimapShape
        return f()
    end)
    return ok and type(shape) == "string" and not API.IsSecret(shape) and ELLESMERE[shape] or nil
end

-- The map's shape at home (the square skins'): "round" or "square"; for a square, the height
-- its skin crops off the top and the bottom (Minimap's units: EllesmereUI's 4:3 and title-bar
-- crops, read from the hit rect insets it sets with them); and how it was known, in this order:
-- "EllesmereUI", "declared" (GetMinimapShape; a mixed shape counts by its quarters, three round
-- ones a round map), "stock" (the ring drawn), or nil (a skin that says nothing: round, as the
-- stock map, but no ground).
function SF.Shape()
    local shape, how = ellesmere(), "EllesmereUI"
    if not shape then
        local f = rawget(_G, "GetMinimapShape")
        local ok, name = false, nil
        if type(f) == "function" then ok, name = pcall(f) end
        local n = ok and type(name) == "string" and not API.IsSecret(name) and roundQuarters(name:upper())
        if n then shape, how = n >= 3 and "round" or "square", "declared" end
    end
    -- A declaration before the ring: a square skin can leave Blizzard's ring over its map.
    if not shape and stock() then shape, how = "round", "stock" end
    if not shape then return "round", 0, nil end
    local crop = 0
    if shape == "square" then
        local ok, _, _, t, b = false
        if type(Minimap.GetHitRectInsets) == "function" then ok, _, _, t, b = pcall(Minimap.GetHitRectInsets, Minimap) end
        t, b = ok and API.Num(t), ok and API.Num(b)
        local h = API.Num(ask(Minimap, "GetHeight"))
        if t and b and h and t > 0 and b > 0 then crop = math.min(math.max(t, b), h / 2 - 1) end
    end
    return shape, crop, how
end

-- Where the ground can be drawn now: the player (north, west, instance) and the view radius,
-- or nil and why the radar face is drawn instead.
local function groundAt()
    if SF.GROUND == false then return nil, "off" end
    local okI, indoors = pcall(IsIndoors)
    if not okI or API.IsSecret(indoors) or indoors ~= false then return nil, "indoors" end
    if not NR.Scan.Where() then return nil, "the map rotates or is unreadable" end
    -- The shape: one whose mask we know (Codex: Minimap has no mask getter): the stock map's,
    -- or a skin's that says it (SF.Shape).
    local _, _, how = SF.Shape()
    if not how then return nil, "the minimap's shape is unknown" end
    local okP, n, w, _, inst = pcall(UnitPosition, "player")
    n, w, inst = okP and API.Num(n), okP and API.Num(w), okP and API.Num(inst)
    if not (n and w and inst) then return nil, "no position" end
    if not (NR.MINIMAP_TILES and NR.MINIMAP_TILES[inst]) then return nil, "no tiles for this map" end
    local okR, radius = pcall(C_Minimap.GetViewRadius)
    radius = okR and API.Num(radius)
    if not (radius and radius > 0) then return nil, "no view radius" end
    return { north = n, west = w, instance = inst, radius = radius }
end

-- "tiles", or why the radar face is drawn (/fp steps nr ground).
function SF.Ground()
    local at, why = groundAt()
    if not at then return why end
    return "tiles"
end

-- The tiles around the player, at the face's size `size` (UIParent units). `load`: set the
-- textures (SF.Warm, outside a borrow); else only tiles already holding the right texture and
-- loaded are drawn (Codex: a cold load inside a borrow stalls it). True, or false and why not.
local function drawGround(size, load)
    for _, t in ipairs(tiles) do t:Hide() end
    arrow:Hide()
    local at, why = groundAt()
    if not at then return false, why end
    local perYard = size / 2 / at.radius
    local T = SF.TILE
    local fx, fy = 32 - at.west / T, 32 - at.north / T      -- tiles, continuous: x east, y south
    local tilePx = T * perYard
    local used, loaded = 0, 0
    for x = math.floor(fx - at.radius / T), math.floor(fx + at.radius / T) do
        for y = math.floor(fy - at.radius / T), math.floor(fy + at.radius / T) do
            local id = x >= 0 and x < 64 and y >= 0 and y < 64 and SF.TileID(at.instance, x, y)
            if id and used < #tiles then
                used = used + 1
                local t = tiles[used]
                if t.id ~= id then
                    if not load then return false, "tiles not loaded yet" end
                    attempts = attempts + 1                 -- before the call: a refusal or a throw still cost it
                    t.id = t:SetTexture(id) ~= false and id or nil
                    if not t.id then return false, "a tile was refused" end
                    loaded = loaded + 1
                end
                if not load and type(t.IsObjectLoaded) == "function" and t:IsObjectLoaded() == false then
                    return false, "tiles still loading"
                end
                t:SetVertexColor(SF.GROUND_TINT[1], SF.GROUND_TINT[2], SF.GROUND_TINT[3], 1)
                t:SetSize(tilePx, tilePx)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", face, "CENTER", (x - fx) * tilePx, -(y - fy) * tilePx)
            end
        end
    end
    if used == 0 then return false, "no tile here" end
    if load then return true, loaded end
    for i = 1, used do tiles[i]:Show() end
    local k = size / (API.Num(ask(Minimap, "GetWidth")) or size)
    arrow:SetSize(SF.ARROW * k, SF.ARROW * k)
    local okF, facing = pcall(GetPlayerFacing)
    arrow:SetRotation(okF and API.Num(facing) or 0)
    arrow:Show()
    return true
end

-- A Blizzard ring texture copied: only while it shows at home, its atlas at its size and
-- centre, converted from its parent's scale to UIParent's, anchored to the face (fx, fy its
-- centre then), so a preview moves it with the face (Codex).
local function copy(dst, src, ues, fx, fy)
    dst:Hide()
    if type(src) ~= "table" then return end
    local parent = ask(src, "GetParent")
    local atlas = ask(src, "GetAtlas")
    if ask(src, "IsVisible") ~= true or type(atlas) ~= "string" or atlas == "" then return end
    local alpha, palpha = API.Num(ask(src, "GetAlpha")), API.Num(ask(parent, "GetAlpha"))
    if not (alpha and palpha and alpha > 0 and palpha > 0) then return end
    local es = API.Num(ask(parent, "GetEffectiveScale"))
    local w, h = API.Num(ask(src, "GetWidth")), API.Num(ask(src, "GetHeight"))
    local x, y = ask(src, "GetCenter")
    x, y = API.Num(x), API.Num(y)
    if not (es and w and h and x and y and es > 0 and w > 0 and h > 0) then return end
    local k = es / ues
    dst:SetAtlas(atlas)
    dst:SetSize(w * k, h * k)
    dst:ClearAllPoints()
    dst:SetPoint("CENTER", face, "CENTER", x * k - fx, y * k - fy)
    dst:Show()
end

-- Over the map's home, read now (before the borrow moves it). False: nothing to stand in for.
local function place()
    if ask(Minimap, "IsVisible") ~= true then return false end
    local alpha = API.Num(ask(Minimap, "GetAlpha"))
    if not (alpha and alpha > 0) then return false end      -- an invisible map stays invisible
    local es, ues = API.Num(ask(Minimap, "GetEffectiveScale")), API.Num(ask(UIParent, "GetEffectiveScale"))
    local w, h = API.Num(ask(Minimap, "GetWidth")), API.Num(ask(Minimap, "GetHeight"))
    local x, y = ask(Minimap, "GetCenter")
    x, y = API.Num(x), API.Num(y)
    if not (es and ues and w and h and x and y and es > 0 and ues > 0 and w > 0 and h > 0) then return false end
    build()
    local k = es / ues
    -- In the map's shape: a square skin's map gets a square plate, cropped as its skin crops it,
    -- the radar's rings and sweep a centred square within it (SF.Shape).
    local shape, crop = SF.Shape()
    local fh = (h - 2 * crop) * k
    face:ClearAllPoints()
    face:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * k, y * k)
    face:SetSize(w * k, fh)
    local media = NR.Alert.MEDIA
    body:SetTexture(shape == "square" and SF.SQUARE_BODY or media .. "ScanDisc.tga")
    body:SetVertexColor(SF.BODY[1], SF.BODY[2], SF.BODY[3], SF.BODY[4])
    if shape == "square" then mask:SetTexture(SF.SQUARE_MASK) else mask:SetAtlas(SF.MASK_ATLAS) end
    local d = math.min(w * k, fh)
    for _, t in ipairs({ lines, sweep }) do
        t:ClearAllPoints()
        t:SetPoint("CENTER", face, "CENTER", 0, 0)
        t:SetSize(d, d)
    end
    SF.lastShape = shape
    -- Stacked where Blizzard's ring is: whatever draws over the stock ring draws over ours.
    local backdrop = rawget(_G, "MinimapBackdrop")
    face:SetFrameStrata(ask(backdrop, "GetFrameStrata") or ask(Minimap, "GetFrameStrata") or "LOW")
    local level = API.Num(ask(backdrop, "GetFrameLevel")) or ((API.Num(ask(Minimap, "GetFrameLevel")) or 0) + 1)
    face:SetFrameLevel(level)
    copy(rings[1], rawget(_G, "MinimapCompassTextureUnderlay"), ues, x * k, y * k)
    copy(rings[2], rawget(_G, "MinimapCompassTexture"), ues, x * k, y * k)
    -- The real ground if it can be drawn, the radar's lines and sweep otherwise (#117).
    local okG, drew, why = pcall(drawGround, w * k)
    if not okG then API.Fail("scan face ground", drew) end
    grounded = okG and drew == true
    SF.lastGround = grounded and "tiles" or (okG and why or "failed")
    if not grounded then
        for _, t in ipairs(tiles) do t:Hide() end
        arrow:Hide()
    end
    lines:SetShown(not grounded)
    sweep:SetShown(not grounded)
    return true
end

local function begin(glass, g)
    if not SF.Ours(glass, g) then return cancel() end
    if not place() then return cancel() end
    state, since = "full", 0
    face:SetAlpha(1)
    face:Show()
end

-- MoveScan's borrow, before the map moves: the face at full, in the same call.
function SF.Begin(glass, g)
    local ok, err = pcall(begin, glass, g)
    if not ok then
        pcall(cancel)
        API.Fail("scan face", err)
    end
end

-- The borrow ended (the restore, on every path): held, then faded.
function SF.End()
    if state == "full" then state, since = "hold", 0 end
end

-- "full", "hold", "preview" or nil (tests, /nr scan log).
function SF.State() return state end

-- The tiles around the player loaded ahead of a borrow (MoveScan's driver, outside bursts, only
-- when a look could come), every WARM_EVERY seconds, only while ours would be drawn and the
-- ground could be. Never shows anything. True when it loaded a texture (the borrow then waits a
-- frame, so the load isn't charged to its budget).
function SF.Warm(now, glass, g)
    if now - warmedAt < SF.WARM_EVERY or state then return false end
    warmedAt = now
    if glass == nil and NR.MoveScan then glass, g = NR.MoveScan.Glass() end
    if not SF.Ours(glass, g) then return false end
    if not groundAt() then return false end                -- nothing built or loaded for nothing
    attempts = 0
    local ok, err = pcall(function()
        build()
        local w = API.Num(ask(Minimap, "GetWidth"))
        local es, ues = API.Num(ask(Minimap, "GetEffectiveScale")), API.Num(ask(UIParent, "GetEffectiveScale"))
        if w and es and ues and ues > 0 then drawGround(w * es / ues, true) end
    end)
    if not ok then API.Fail("scan face ground", err) end
    -- Any load attempted counts, refused or thrown after others (Codex, third round): that work
    -- is done on this frame either way, so the borrow waits.
    return attempts > 0
end

-- The stand-in as a borrow would draw it, at the map's home moved by (dx, dy) UIParent units, for
-- `seconds`, without touching the map (/fp steps nr ground: ours beside the real one). Never over
-- a borrow's face. Returns true, or false and why.
function SF.Preview(dx, dy, seconds)
    if state == "full" or state == "hold" then return false, "a borrow's face is up" end
    warmedAt = -math.huge
    SF.Warm(GetTime(), "none")                         -- loaded first: a preview isn't a borrow
    local ok, placed = pcall(place)
    if not ok then pcall(cancel); return false, tostring(placed) end
    if not placed then return false, "the minimap is hidden or unreadable" end
    local p, rel, rp, x, y = face:GetPoint(1)
    face:ClearAllPoints()
    face:SetPoint(p, rel, rp, x + (dx or 0), y + (dy or 0))
    state, since, previewFor = "preview", 0, seconds or 4
    face:SetAlpha(1)
    face:Show()
    return true, SF.lastGround
end

function SF.Grounded() return grounded end

SF._test = {
    face = function() return face end,
    parts = function() return body, lines, sweep, rings end,
    ground = function() return clip, tiles, arrow end,
}
