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

local TWO_PI = 2 * math.pi
local face, body, lines, sweep, rings
local state             -- nil (hidden), "full" (a borrow under way) or "hold" (held, then fading)
local since, angle = 0, 0

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
    -- Blizzard's ring, and its underlay in the rotating mode, copied on top.
    rings = { face:CreateTexture(nil, "OVERLAY", nil, 1), face:CreateTexture(nil, "OVERLAY", nil, 2) }
    face:SetScript("OnUpdate", step)
end

-- A Blizzard ring texture copied: only while it shows at home, its atlas at its size and
-- centre, converted from its parent's scale to UIParent's.
local function copy(dst, src, ues)
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
    dst:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * k, y * k)
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
    face:ClearAllPoints()
    face:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * k, y * k)
    face:SetSize(w * k, h * k)
    -- Stacked where Blizzard's ring is: whatever draws over the stock ring draws over ours.
    local backdrop = rawget(_G, "MinimapBackdrop")
    face:SetFrameStrata(ask(backdrop, "GetFrameStrata") or ask(Minimap, "GetFrameStrata") or "LOW")
    local level = API.Num(ask(backdrop, "GetFrameLevel")) or ((API.Num(ask(Minimap, "GetFrameLevel")) or 0) + 1)
    face:SetFrameLevel(level)
    copy(rings[1], rawget(_G, "MinimapCompassTextureUnderlay"), ues)
    copy(rings[2], rawget(_G, "MinimapCompassTexture"), ues)
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

-- "full", "hold" or nil (tests, /nr scan log).
function SF.State() return state end

SF._test = {
    face = function() return face end,
    parts = function() return body, lines, sweep, rings end,
}
