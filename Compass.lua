-- Compass.lua: which way to the nearest node (#29, experimental, off by
-- default; docs/PLAN.md, "The compass, experimental").
--
-- A ring under the character, its arrow toward the nearest node the player
-- can gather that NodeRadar has measured (#28's records), and the distance in
-- the middle. Chosen again at every radar sweep, so it moves on as the player
-- gathers and rides (the owner: following the alerted node fell short). Within
-- 15 yards it hides: the glow on the node is Lueur's (the soft target), and
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
Compass.RADIUS = 48    -- the arrow's distance from the ring's centre
Compass.ARROWS = "Interface\\Minimap\\Minimap-PositionArrows"   -- its upper half points up (#41)

local TAU = 2 * math.pi
local target           -- the record pointed at
local lastSweep        -- the last radar sweep reconciled
local shownDist        -- the whole yards on the text

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
-- The ring
--------------------------------------------------------------------------------

local ring = CreateFrame("Frame", nil, UIParent)
ring:SetSize(120, 120)
ring:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
ring:EnableMouse(false)
ring:Hide()
local circle = ring:CreateTexture(nil, "BACKGROUND")
circle:SetAllPoints(ring)
circle:SetTexture(NR.Alert.MEDIA .. "SonarRing.tga")
local arrow = ring:CreateTexture(nil, "OVERLAY")
arrow:SetSize(28, 28)
arrow:SetTexture(Compass.ARROWS)
arrow:SetTexCoord(0, 1, 0, 0.5)
local text = ring:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
text:SetPoint("CENTER", ring, "CENTER")

local function hide()
    ring:Hide()
    shownDist = nil
end

-- Each frame while shown: the arrow at (bearing - facing), the distance.
-- Hidden (the target kept) within 15 yards of a level node, when the position
-- or facing can't be read, without a recent sweep, dead or on a taxi; the next
-- usable sweep shows it again.
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
    arrow:SetPoint("CENTER", ring, "CENTER", -Compass.RADIUS * math.sin(a), Compass.RADIUS * math.cos(a))
    arrow:SetRotation(a)
    local whole = math.floor(d + 0.5)
    if whole ~= shownDist then
        shownDist = whole
        text:SetText(whole .. " yd")
    end
end
ring:SetScript("OnUpdate", frame)

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
    local c = NR.Alert.COLOURS[target.kind] or NR.Alert.COLOURS.herbs
    circle:SetVertexColor(c[1], c[2], c[3], 0.85)
    ring:Show()
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

-- The records cleared (Icons.Clear), or the compass turned off: no target.
function Compass.Reset()
    target = nil
    hide()
end

Compass._test = {
    ring = ring, arrow = arrow, text = text, circle = circle, frame = frame,
    target = function() return target end,
}
