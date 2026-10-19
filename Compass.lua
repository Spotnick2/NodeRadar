-- Compass.lua: which way to the nearest node (#29, experimental, off by
-- default; docs/PLAN.md, "The compass, experimental").
--
-- The nearest node the player can gather that NodeRadar has measured (#28's
-- records), chosen again at every radar sweep, so it moves on as the player
-- gathers and rides (the owner: following the alerted node fell short). Its
-- item icon in a disc under the character, the arrow orbiting outside the disc
-- toward it, the distance in a pill below, the item's tooltip on hover. The
-- disc follows the icons' frame setting (#41: glass, bronze, plain). Within 15
-- yards it hides: the glow on the node is Lueur's (the soft target), and
-- NodeRadar never touches the soft-targeting settings (owner).
--
-- Measured on 70450 (docs/FOREVER-PROBE.md, "The compass, first round"):
-- GetPlayerFacing is counter-clockwise from north, 0 to 2pi; a point's bearing
-- from UnitPosition (north, west) is atan2(-east, north); an arrow at
-- bearing - facing pointed true. The facing is the character's, not the
-- camera's: turning the camera alone doesn't turn the arrow.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Compass = {}
NR.Compass = Compass

Compass.NEAR = 15      -- yards: hidden this close (Lueur's soft target takes over; Forever loses it at 15)
Compass.HYSTERESIS = 5 -- yards: another node must be this much nearer to take over
Compass.GRACE = 2      -- seconds past the idle interval without a sweep before it hides
Compass.ARROWS = "Interface\\Minimap\\Minimap-PositionArrows"   -- its upper half points up (#41)
-- The look (owner, two look rounds): built at medium, scaled to the size.
Compass.SIZES = { small = 44, medium = 52, large = 60 }   -- the outer diameter; nothing under 44 (rough)
Compass.DISC = 52      -- the medium diameter, what everything is built at
Compass.ARROW = 14     -- the arrow at medium
Compass.ORBIT = Compass.DISC / 2 + 0.7 * Compass.ARROW      -- just outside the disc
Compass.PILL_TOP = Compass.DISC / 2 + 1.5 * Compass.ARROW   -- below the orbit (D put it on the pill)

local RING, RING_BG = 136430, 136467    -- MiniMap-TrackingBorder, UI-Minimap-Background (#41)
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TAU = 2 * math.pi
local target           -- the record pointed at
local lastSweep        -- the last radar sweep reconciled
local shownDist        -- the whole yards on the text
local looks = {}       -- style -> { host, icon, pill, text }, built once each
local look             -- the one in use

function Compass.On()
    local db = NR.db
    return db and db.compass and db.enabled and true or false
end

local function wrap(a) return (a + math.pi) % TAU - math.pi end

-- The player in UnitPosition's frame: north, west; nil when unreadable.
local function here()
    local ok, n, w = pcall(UnitPosition, "player")
    if not ok then return nil end
    n, w = API.Num(n), API.Num(w)
    if n and w then return n, w end
end

local function facing()
    local ok, f = pcall(GetPlayerFacing)
    return ok and API.Num(f) or nil
end

local function onTaxi()
    local ok, v = pcall(UnitOnTaxi, "player")
    return ok and API.Yes(v)
end

local function yards(r, pn, pw) return math.sqrt((r.north - pn) ^ 2 + (r.west - pw) ^ 2) end

--------------------------------------------------------------------------------
-- The ring: a fixed root on UIParent, a body scaled to the size
--------------------------------------------------------------------------------

local root = CreateFrame("Frame", nil, UIParent)
root:SetSize(1, 1)
root:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
root:EnableMouse(false)
root:Hide()
local body = CreateFrame("Frame", nil, root)
body:SetSize(Compass.DISC, Compass.DISC)
body:SetPoint("CENTER", root, "CENTER")
body:EnableMouse(false)
-- The arrow, over any look (a glass disc's top is its host's level + 10).
local over = CreateFrame("Frame", nil, body)
over:SetAllPoints(body)
over:SetFrameLevel(body:GetFrameLevel() + 15)
over:EnableMouse(false)
local arrow = over:CreateTexture(nil, "OVERLAY")
arrow:SetSize(Compass.ARROW, Compass.ARROW)
arrow:SetTexture(Compass.ARROWS)
arrow:SetTexCoord(0, 1, 0, 0.5)

-- The item a record gives (NODE_INFO), or nil.
local function itemOf(t)
    local info = t and NR.Learn.Info(t.name)
    return info and API.Num(info.item)
end

local function ownsTooltip(host)
    local ok, owner = pcall(GameTooltip.GetOwner, GameTooltip)
    return ok and owner == host
end

-- The item's tooltip over the disc, or none (the accessor shows it, or hides
-- it on a refusal or no data).
local function setTooltip(host)
    local item = itemOf(target)
    if not item then
        if ownsTooltip(host) then GameTooltip:Hide() end
        return
    end
    GameTooltip:SetOwner(host, "ANCHOR_TOP")
    local ok, err = pcall(GameTooltip.SetItemByID, GameTooltip, item)
    if not ok then
        API.Fail("tooltip", err)
        GameTooltip:Hide()
    end
end

-- The disc takes mouse motion only: the tooltip, and clicks through to the
-- world (round 2: with the mouse on, a click on the disc didn't reach it).
local function hover(host)
    host:SetScript("OnEnter", setTooltip)
    host:SetScript("OnLeave", function(self) if ownsTooltip(self) then GameTooltip:Hide() end end)
    host:EnableMouse(false)
    host:SetMouseMotionEnabled(true)
    host:SetMouseClickEnabled(false)
end

-- A pill of text under the disc, below the arrow's orbit.
local function pillAt(pill)
    pill:SetSize(64, 22)
    pill:SetPoint("TOP", body, "CENTER", 0, -Compass.PILL_TOP)
    pill:EnableMouse(false)
end

local function buildGlass(inst)
    local d = Compass.DISC
    local host = CreateFrame("Frame", nil, body)
    host:Hide()
    host:SetSize(d, d)
    host:SetPoint("CENTER", body, "CENTER")
    host:EnableMouse(false)
    local pill = CreateFrame("Frame", nil, body)
    pill:Hide()
    pillAt(pill)
    local ok, err = pcall(function()
        local g = inst.Disc(host, "disc_small")
        if type(g) == "table" and g.top then g.top:EnableMouse(false) end
        local inset = d * 0.155                                -- the icon about 0.69 of the disc
        local icon = host:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", host, "TOPLEFT", inset, -inset)
        icon:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -inset, inset)
        icon:AddMaskTexture(inst.Mask(host, "disc_mask_small", nil, inset))
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local pg = inst.Apply(pill, "small")
        if type(pg) == "table" and pg.top then pg.top:EnableMouse(false) end
        local text = inst.Font(type(pg) == "table" and pg.top or pill, 13, "CENTER")
        text:SetPoint("CENTER", pill, "CENTER")
        looks.glass = { host = host, icon = icon, pill = pill, text = text }
    end)
    if not ok then
        NR.Icons.GlassFailed("compass: " .. tostring(err))
        return nil
    end
    hover(host)
    return looks.glass
end

-- A plain pill: the text on a dark rounded backdrop.
local function plainPill()
    local pill = CreateFrame("Frame", nil, body)
    pill:Hide()
    pillAt(pill)
    local bg = pill:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(pill)
    bg:SetColorTexture(0, 0, 0, 0.55)
    local text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER", pill, "CENTER")
    return pill, text
end

-- Blizzard's round button as LibDBIcon lays it out, its 31 units the diameter
-- (#41's layout, but the button sized, not the icon: Codex).
local function buildBronze()
    local d = Compass.DISC
    local k = d / 31
    local host = CreateFrame("Frame", nil, body)
    host:Hide()
    host:SetSize(d, d)
    host:SetPoint("CENTER", body, "CENTER", 0, -1 * k)    -- the icon's centre is 1 above the button's
    local ring = host:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53 * k, 53 * k)
    ring:SetTexture(RING)
    ring:SetPoint("TOPLEFT", host, "TOPLEFT")
    local bg = host:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20 * k, 20 * k)
    bg:SetTexture(RING_BG)
    bg:SetPoint("TOPLEFT", host, "TOPLEFT", 7 * k, -5 * k)
    local icon = host:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17 * k, 17 * k)
    icon:SetPoint("TOPLEFT", host, "TOPLEFT", 7 * k, -6 * k)
    local mask = host:CreateMaskTexture()
    mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local pill, text = plainPill()
    hover(host)
    looks.bronze = { host = host, icon = icon, pill = pill, text = text }
    return looks.bronze
end

-- The icon alone, masked round, the diameter's size.
local function buildPlain()
    local d = Compass.DISC
    local host = CreateFrame("Frame", nil, body)
    host:Hide()
    host:SetSize(d, d)
    host:SetPoint("CENTER", body, "CENTER")
    local icon = host:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(host)
    local mask = host:CreateMaskTexture()
    mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local pill, text = plainPill()
    hover(host)
    looks.plain = { host = host, icon = icon, pill = pill, text = text }
    return looks.plain
end

-- The look for the icons' frame setting, built if needed; a glass that fails
-- here is bronze, and the icons are bound again too (one latch).
local function lookFor()
    local style, inst = NR.Icons.Style()
    if style == "glass" then
        if looks.glass == nil then
            looks.glass = inst and buildGlass(inst) or false
            if not looks.glass then NR.Icons.Restyle() end
        end
        if looks.glass then return looks.glass end
        style = "bronze"
    end
    if style == "bronze" then return looks.bronze or buildBronze() end
    return looks.plain or buildPlain()
end

local function hide()
    root:Hide()
    shownDist = nil
    if look and ownsTooltip(look.host) then GameTooltip:Hide() end
end

-- Each frame while shown: the arrow at (bearing - facing) on its orbit, the
-- distance. Hidden (the target kept) within 15 yards of a level node, when the
-- position or facing can't be read, without a recent sweep, dead or on a taxi;
-- the next usable sweep shows it again.
local function frame()
    local t = target
    if not t then hide(); return end
    local pn, pw = here()
    local f = facing()
    if not (pn and f) or not lastSweep or GetTime() - lastSweep > NR.db.interval + Compass.GRACE
        or API.Dead() or onTaxi() then
        hide()
        return
    end
    local north, east = t.north - pn, -(t.west - pw)
    local d = math.sqrt(north * north + east * east)
    if d <= Compass.NEAR and not t.height then hide(); return end
    local a = wrap(math.atan2(-east, north) - f)           -- counter-clockwise from straight ahead
    arrow:ClearAllPoints()
    arrow:SetPoint("CENTER", body, "CENTER", -Compass.ORBIT * math.sin(a), Compass.ORBIT * math.cos(a))
    arrow:SetRotation(a)
    local whole = math.floor(d + 0.5)
    if whole ~= shownDist and look then
        shownDist = whole
        look.text:SetText(whole .. " yd")
    end
end
root:SetScript("OnUpdate", frame)

-- The look in use, the size, the icon: set at each sweep and when the style or
-- size changes.
local dressedFor
local function dress()
    local wanted = lookFor()
    for _, l in pairs(looks) do
        if l and l ~= wanted then
            if ownsTooltip(l.host) then GameTooltip:Hide() end
            l.host:Hide()
            l.pill:Hide()
        end
    end
    if wanted ~= look then shownDist = nil end         -- a look switched to gets its distance (compass4: empty pills)
    look = wanted
    body:SetScale((Compass.SIZES[NR.db.compassSize] or Compass.SIZES[NR.DEFAULTS.compassSize]) / Compass.DISC)
    look.host:Show()
    look.pill:Show()
    look.icon:SetTexture(target.icon)
    if target ~= dressedFor then
        dressedFor = target
        shownDist = nil
        -- The target changed under a still cursor: the owned tooltip follows it (Codex).
        if ownsTooltip(look.host) then setTooltip(look.host) end
    end
end

--------------------------------------------------------------------------------
-- The target: the nearest gatherable record
--------------------------------------------------------------------------------

-- Chosen from the records as they are now: the nearest gatherable (#26's
-- filter as the alert uses it, read fresh), unless the current one is still
-- kept, still gatherable and within HYSTERESIS yards of it (Codex, #29).
local function choose()
    local pn, pw = here()
    if not pn then target = nil; return end
    local best, bestD, kept
    for _, r in ipairs(NR.Icons.Records()) do
        if NR.Alert.Gatherable(r.name) then
            local d = yards(r, pn, pw)
            if not bestD or d < bestD then best, bestD = r, d end
            if r == target then kept = d end
        end
    end
    if kept and best ~= target and kept - bestD < Compass.HYSTERESIS then best = target end
    target = best
end

local function refresh()
    choose()
    if not target then hide(); return end
    dress()
    root:Show()
    frame()
end

-- After each radar sweep's Icons.Update, before the alert and the learner.
function Compass.Reconcile(result, now)
    if not Compass.On() then return end
    lastSweep = now
    refresh()
end

-- A gather took records out (Icons.Gathered, once the list is filtered):
-- chosen again at once. Not a sweep: the freshness isn't renewed.
function Compass.Refresh()
    if not Compass.On() or not lastSweep then return end
    refresh()
end

-- The style or the size changed (NR.Set), or the glass latch tripped in the
-- icons' pass: the ring dressed again now.
function Compass.Restyle()
    if not (Compass.On() and target) then return end
    dress()
    frame()
end

-- The records cleared (Icons.Clear), or the compass turned off: no target.
function Compass.Reset()
    target = nil
    hide()
end

Compass._test = {
    root = root, body = body, arrow = arrow, frame = frame,
    target = function() return target end,
    look = function() return look end,
    looks = looks,
}
