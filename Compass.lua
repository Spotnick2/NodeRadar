-- Compass.lua: which way to the nearest node (#29, experimental, off by
-- default; docs/PLAN.md, "The compass, experimental").
--
-- The nearest node the player can gather that NodeRadar has measured (#28's
-- records), chosen again at every radar sweep, so it moves on as the player
-- gathers and rides (the owner: following the alerted node fell short). Its
-- item icon on a dark lens under the character, a thin rim (pearl with the
-- icons' glass frame, bronze with their bronze, none with none: #41), an arrow
-- outside the rim toward it with a highlight arc on the rim beneath, the
-- distance in a capsule below, the item's tooltip on hover ("The ring,
-- refined": our own art, Tools/make_media.py). Within 15 yards it hides: the
-- glow on the node is Lueur's (the soft target), and NodeRadar never touches
-- the soft-targeting settings (owner).
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
-- The look, built at medium and scaled to the size (the outer diameter).
Compass.SIZES = { small = 44, medium = 52, large = 60 }   -- nothing under 44 (rough edges, look round 2)
Compass.DISC = 52      -- the medium diameter, what everything is built at
Compass.ICON = 0.58    -- the icon, a share of the diameter (more breathing room than 0.69)
Compass.ARROW = 16     -- the arrow's art at medium
-- CompassArrow's art (Tools/make_media.py): the apex 0.375 of its size above
-- its centre, the base 0.3125 below. Its base 1 unit outside the rim:
Compass.ORBIT = Compass.DISC / 2 + 1 + 0.3125 * Compass.ARROW
Compass.REACH = Compass.ORBIT + 0.375 * Compass.ARROW           -- its farthest point, the apex
Compass.PILL_TOP = Compass.REACH + 3                             -- the capsule 3 units below that
Compass.PILL = { 56, 18 }                                        -- fixed: no width change with the number
Compass.FOOT = Compass.PILL_TOP + Compass.PILL[2]                -- the footprint's reach below the centre (59)
Compass.HOME = { 0, -160 }                                       -- the default place: under the character
-- Snoozing (#46): a node put aside for a while, by its spot. Durations in
-- seconds; "session" until a reload or a logout (they're never saved).
Compass.SNOOZE_NEAR = 8                                          -- world yards: the same node, measured again
Compass.SNOOZES = { ["15"] = 900, ["30"] = 1800, ["60"] = 3600, session = math.huge }
Compass.TINTS = { glass = { 0.97, 0.97, 1 }, bronze = { 0.80, 0.62, 0.38 },    -- the rim: pearl, bronze,
                  yellow = NR.Icons.YELLOW }                                    -- the dots' yellow (#50)

local MEDIA = NR.Alert.MEDIA
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TAU = 2 * math.pi
local target           -- the record pointed at
local lastSweep        -- the last radar sweep reconciled
local shownDist        -- the whole yards on the text
local dressedFor       -- the target the icon and the tooltip were last set for

function Compass.On()
    local db = NR.db
    return db and db.compass and db.enabled and true or false
end

-- The target is chosen for the ring or the marker in the world (#61),
-- whichever is on; the ring shows only with the compass.
function Compass.Choosing()
    local db = NR.db
    return db and db.enabled and (db.compass or db.marker) and true or false
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
-- The ring: a fixed root on UIParent, a body scaled to the size, our own art
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

local function layer(parent, file, size, drawLayer, sub)
    local t = parent:CreateTexture(nil, drawLayer, nil, sub)
    t:SetSize(size, size)
    t:SetPoint("CENTER", parent, "CENTER")
    t:SetTexture(MEDIA .. file)
    return t
end

-- The shadow, separating the widget from the ground: a little larger, nudged down.
local shadow = layer(body, "CompassShadow.tga", Compass.DISC * 1.25, "BACKGROUND", -8)
shadow:ClearAllPoints()
shadow:SetPoint("CENTER", body, "CENTER", 0, -2)
-- The disc: the lens, the icon, the rim, the arc. It takes mouse motion only (the tooltip).
local disc = CreateFrame("Frame", nil, body)
disc:SetSize(Compass.DISC, Compass.DISC)
disc:SetPoint("CENTER", body, "CENTER")
local lens = layer(disc, "CompassLens.tga", Compass.DISC, "BACKGROUND")
local icon = disc:CreateTexture(nil, "ARTWORK")
icon:SetSize(Compass.DISC * Compass.ICON, Compass.DISC * Compass.ICON)
icon:SetPoint("CENTER", disc, "CENTER")
local mask = disc:CreateMaskTexture()
mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
mask:SetAllPoints(icon)
icon:AddMaskTexture(mask)
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
local rim = layer(disc, "CompassRim.tga", Compass.DISC, "OVERLAY", 1)
local arc = layer(disc, "CompassArc.tga", Compass.DISC, "OVERLAY", 2)    -- turned around the disc's centre
-- The arrow, on its own frame over the disc.
local over = CreateFrame("Frame", nil, body)
over:SetAllPoints(body)
over:SetFrameLevel(disc:GetFrameLevel() + 2)
over:EnableMouse(false)
local arrow = over:CreateTexture(nil, "OVERLAY")
arrow:SetSize(Compass.ARROW, Compass.ARROW)
arrow:SetTexture(MEDIA .. "CompassArrow.tga")
-- The capsule: fixed size, cropped to the art's capsule (2..126 x 12..52 of 128 x 64).
local pill = CreateFrame("Frame", nil, body)
pill:SetSize(Compass.PILL[1], Compass.PILL[2])
pill:SetPoint("TOP", body, "CENTER", 0, -Compass.PILL_TOP)
pill:EnableMouse(false)
local pillArt = pill:CreateTexture(nil, "BACKGROUND")
pillArt:SetAllPoints(pill)
pillArt:SetTexture(MEDIA .. "CompassPill.tga")
pillArt:SetTexCoord(2 / 128, 126 / 128, 12 / 64, 52 / 64)
local text = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
text:SetPoint("CENTER", pill, "CENTER")

-- Moving it (#57): Alt-drag, as Apotheca. The hit area is the footprint, the
-- arrow's reach above the centre to the capsule's bottom below it (it takes no
-- mouse: it's only asked IsMouseOver); the grip over it takes clicks, and is
-- shown only while Alt is held over the compass.
local hit = CreateFrame("Frame", nil, body)
hit:SetSize(2 * Compass.REACH, Compass.REACH + Compass.FOOT)
hit:SetPoint("TOP", body, "CENTER", 0, Compass.REACH)
hit:EnableMouse(false)
local grip = CreateFrame("Frame", nil, hit)
grip:SetAllPoints(hit)
grip:SetFrameLevel(over:GetFrameLevel() + 1)             -- above the arrow (Codex)
grip:EnableMouse(true)
grip:RegisterForDrag("LeftButton")
grip:Hide()
local gripFill = grip:CreateTexture(nil, "BACKGROUND")
gripFill:SetAllPoints(grip)
gripFill:SetColorTexture(0, 0, 0, 0.45)
local gripText = grip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
gripText:SetPoint("CENTER", body, "CENTER")
gripText:SetText("Drag to move")
root:SetMovable(true)

-- The item a record gives (NODE_INFO), or nil.
local function itemOf(t)
    local info = t and NR.Learn.Info(t.name)
    return info and API.Num(info.item)
end

local function ownsTooltip()
    local ok, owner = pcall(GameTooltip.GetOwner, GameTooltip)
    return ok and owner == disc
end

-- The item's tooltip over the disc, or none (the accessor shows it, or hides
-- it on a refusal or no data).
local function setTooltip()
    local item = itemOf(target)
    if not item then
        if ownsTooltip() then GameTooltip:Hide() end
        return
    end
    GameTooltip:SetOwner(disc, "ANCHOR_TOP")
    local ok, err = pcall(GameTooltip.SetItemByID, GameTooltip, item)
    if not ok then
        API.Fail("tooltip", err)
        GameTooltip:Hide()
    end
end

-- Mouse motion only: the tooltip, and clicks through to the world (compass4).
disc:SetScript("OnEnter", setTooltip)
disc:SetScript("OnLeave", function() if ownsTooltip() then GameTooltip:Hide() end end)
disc:EnableMouse(false)
disc:SetMouseMotionEnabled(true)
disc:SetMouseClickEnabled(false)

--------------------------------------------------------------------------------
-- Moving it (#57)
--------------------------------------------------------------------------------

local function scale()
    return (Compass.SIZES[NR.db.compassSize] or Compass.SIZES[NR.DEFAULTS.compassSize]) / Compass.DISC
end

-- An offset from UIParent's centre kept so the whole footprint, at the size
-- now, is on UIParent (Codex's bounds). By the numbers: the root is a 1-unit
-- frame, the footprint its scaled child's.
local function clamp(x, y)
    local w, h = API.Num(UIParent:GetWidth()), API.Num(UIParent:GetHeight())
    if not (w and h) then return x, y end
    local s = scale()
    local side, up, down = Compass.REACH * s, Compass.REACH * s, Compass.FOOT * s
    return math.max(-w / 2 + side, math.min(w / 2 - side, x)), math.max(-h / 2 + down, math.min(h / 2 - up, y))
end

-- The root where it's saved (compassX, compassY; else HOME), clamped.
local dragging = false
local function place()
    if dragging or not NR.db then return end
    local x, y = API.Num(NR.db.compassX), API.Num(NR.db.compassY)
    if not (x and y) then x, y = Compass.HOME[1], Compass.HOME[2] end
    x, y = clamp(x, y)
    root:ClearAllPoints()
    root:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

-- A drag ends: stopped, its spot read (the root's centre minus UIParent's, both
-- in UIParent's units, the root at scale 1 under it), clamped, saved, placed.
-- Idempotent: the grip's OnHide calls it too.
local function stopDrag()
    if not dragging then return end
    dragging = false
    root:StopMovingOrSizing()
    local rx, ry = root:GetCenter()
    local ux, uy = UIParent:GetCenter()
    rx, ry, ux, uy = API.Num(rx), API.Num(ry), API.Num(ux), API.Num(uy)
    if rx and ry and ux and uy then
        NR.db.compassX, NR.db.compassY = clamp(rx - ux, ry - uy)
    end
    place()
end

local function altDown()
    local ok, down = pcall(IsAltKeyDown)
    return ok and API.Yes(down)
end

-- The grip from live input (never one key event: a missed key-up can't leave
-- it on): Alt held over the shown compass, not locked. A drag ends when Alt
-- is let go or the lock is set; the mouse leaving the compass doesn't end it.
local function updateGrip()
    if dragging then
        if not altDown() or NR.db.compassLock then
            stopDrag()
            grip:Hide()
        end
        return
    end
    local want = altDown() and not NR.db.compassLock and root:IsVisible() and hit:IsMouseOver()
    grip:SetShown(want and true or false)
end

grip:SetScript("OnDragStart", function()
    if NR.db.compassLock then return end
    dragging = true
    root:StartMoving()
end)
grip:SetScript("OnDragStop", function()
    stopDrag()
    updateGrip()
end)
grip:SetScript("OnHide", stopDrag)
grip:SetScript("OnMouseDown", function() end)            -- a click on the grip stays on it

local function hide()
    grip:Hide()                                        -- its OnHide ends a drag under way
    root:Hide()
    shownDist = nil
    if ownsTooltip() then GameTooltip:Hide() end
end

-- Each frame while shown: the arrow and the arc at (bearing - facing), the
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
    arc:SetRotation(a)
    local whole = math.floor(d + 0.5)
    if whole ~= shownDist then
        shownDist = whole
        text:SetText(whole .. " yd")
    end
    updateGrip()                                       -- after the show-or-hide decision (Codex)
end
root:SetScript("OnUpdate", frame)

-- Alt pressed or let go; the UI's scale or the display's size changed (a drag
-- under way ended first, then placed again so it stays on screen: Codex).
local input = CreateFrame("Frame")
API.RegisterEvents(input, { "MODIFIER_STATE_CHANGED", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" })
input:SetScript("OnEvent", function(_, event, key)
    if not NR.db then return end
    if event == "MODIFIER_STATE_CHANGED" then
        if key == "LALT" or key == "RALT" then updateGrip() end
        return
    end
    stopDrag()
    grip:Hide()
    place()
end)

-- The rim for the icons' frame (Icons.Style()), the size, the icon: set at
-- each sweep and when the style or the size changes.
local style
local function dress()
    style = NR.Icons.Style()
    local tint = Compass.TINTS[style]
    rim:SetShown(tint ~= nil)                               -- none: the lens and the icon only
    arc:SetShown(tint ~= nil)
    if tint then rim:SetVertexColor(tint[1], tint[2], tint[3]) end
    body:SetScale(scale())
    place()                                            -- the size changes the footprint's clamp
    icon:SetTexture(target.icon)
    if target ~= dressedFor then
        dressedFor = target
        -- The target changed under a still cursor: the owned tooltip follows it (Codex).
        if ownsTooltip() then setTooltip() end
    end
end

--------------------------------------------------------------------------------
-- The target: the nearest gatherable record
--------------------------------------------------------------------------------

-- Chosen from the records as they are now: the nearest gatherable (#26's
-- filter as the alert uses it, read fresh), unless the current one is still
-- kept, still gatherable and within HYSTERESIS yards of it (Codex, #29).
--------------------------------------------------------------------------------
-- Snoozing (#46): { name, north, west, instance, untilT }, in memory only
--------------------------------------------------------------------------------

local snoozes = {}

local function instanceNow()
    local ok, _, _, _, inst = pcall(UnitPosition, "player")
    return ok and API.Num(inst) or nil
end

-- Whether a record is snoozed: a live snooze of its name, in this instance,
-- within SNOOZE_NEAR yards of its spot (the node measured again is a new
-- record). Expired ones are dropped as they're met.
function Compass.Snoozed(r)
    if not (r and #snoozes > 0) then return false end
    local now, inst, live, hit = GetTime(), instanceNow(), {}, false
    for _, s in ipairs(snoozes) do
        if now < s.untilT then
            live[#live + 1] = s
            if s.name == r.name and s.instance == inst then
                local dn, dw = s.north - r.north, s.west - r.west
                if math.sqrt(dn * dn + dw * dw) <= Compass.SNOOZE_NEAR then hit = true end
            end
        end
    end
    snoozes = live
    return hit
end

function Compass.SnoozeCount()
    local now, n = GetTime(), 0
    for _, s in ipairs(snoozes) do if now < s.untilT then n = n + 1 end end
    return n
end

-- After a snooze or a clear: the compass chooses again (not a sweep: its
-- freshness kept) and the icons re-dim at once (Codex: Icons.draw reads a
-- cached dim).
local function snoozesChanged()
    Compass.Refresh()
    NR.Icons.Show()
end

-- A record put aside for a duration (a key of SNOOZES), by default the
-- compass's target. Returns the record snoozed, or nil.
function Compass.Snooze(duration, record)
    local secs = Compass.SNOOZES[tostring(duration)]
    local r = record or target
    if not (secs and r) then return nil end
    snoozes[#snoozes + 1] = { name = r.name, north = r.north, west = r.west, instance = instanceNow(),
                              untilT = GetTime() + secs }
    snoozesChanged()
    return r
end

function Compass.ClearSnoozes()
    snoozes = {}
    snoozesChanged()
end

-- The compass's node now, its item's name and distance, for the menu and
-- the button's tooltip: record, label, yards; or nil.
function Compass.Target()
    if not (Compass.On() and target) then return nil end
    local pn, pw = here()
    local info = NR.Learn.Info(target.name)
    local name = info and NR.Track.ItemName({ item = info.item }) or target.name
    return target, name, pn and math.floor(yards(target, pn, pw) + 0.5) or nil
end

-- The node chosen, for the marker (#61): a record, or nil.
function Compass.Chosen() return Compass.Choosing() and target or nil end

local function choose()
    local pn, pw = here()
    if not pn then target = nil; return end
    local best, bestD, kept
    for _, r in ipairs(NR.Icons.Records()) do
        -- The incumbent too: a skipped (#47) or snoozed (#46) one goes, outright.
        if NR.Alert.Wanted(r.name) and not Compass.Snoozed(r) then
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
    if not (target and Compass.On()) then hide(); return end
    dress()
    root:Show()
    frame()
end

-- After each radar sweep's Icons.Update, before the alert and the learner.
function Compass.Reconcile(result, now)
    if not Compass.Choosing() then return end
    lastSweep = now
    refresh()
end

-- A gather took records out (Icons.Gathered, once the list is filtered):
-- chosen again at once. Not a sweep: the freshness isn't renewed.
function Compass.Refresh()
    if not Compass.Choosing() or not lastSweep then return end
    refresh()
end

-- The style or the size changed (NR.Set), or the glass latch tripped in the
-- icons' pass: the ring dressed again now.
function Compass.Restyle()
    if not (Compass.On() and target) then return end
    dress()
    frame()
end

-- Back to the default place (/nr compass reset, /nr reset), shown or not.
function Compass.ResetPosition()
    stopDrag()
    NR.db.compassX, NR.db.compassY = nil, nil
    place()
end

-- The lock set or lifted (NR.Set): a drag under way ends, the grip follows.
function Compass.UpdateGrip()
    updateGrip()
end

-- The records cleared (Icons.Clear), or the compass turned off: no target.
function Compass.Reset()
    target = nil
    hide()
    if NR.Marker then NR.Marker.TargetGone() end   -- the marker's point goes with it (#61)
end

Compass._test = {
    root = root, body = body, disc = disc, arrow = arrow, arc = arc, rim = rim, lens = lens, icon = icon,
    shadow = shadow, pill = pill, text = text, frame = frame, hit = hit, grip = grip, place = place,
    dragging = function() return dragging end,
    target = function() return target end,
    style = function() return style end,
}
