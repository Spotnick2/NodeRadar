-- Compass.lua: which way to the alerted node (#29, experimental, off by
-- default; docs/PLAN.md, "The compass, experimental").
--
-- A ring under the character, its arrow toward the node and the distance in
-- the middle. It points only at a measured record (#28): an alert leaves a
-- pending target, which the first record of its names made after it resolves
-- (a blip at the rim, merged or clipped, has no bounded error: Codex, #29).
-- Within 15 yards it stops: the glow on the node is Lueur's (the soft target),
-- and NodeRadar never touches the soft-targeting settings (owner).
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

Compass.PENDING = 15   -- seconds an alert waits for a node of its names to be measured
Compass.TIMEOUT = 60   -- seconds from the alert, whatever is seen meanwhile
Compass.ARRIVED = 15   -- yards: Lueur's soft target takes over (Forever loses it at 15)
Compass.REBIND = 3     -- yards: the same node measured again after a passing clear
Compass.GRACE = 2      -- seconds past the idle interval without a sweep before it hides
Compass.RADIUS = 48    -- the arrow's distance from the ring's centre
Compass.ARROWS = "Interface\\Minimap\\Minimap-PositionArrows"   -- its upper half points up (#41)

local TAU = 2 * math.pi
local pending          -- { names = { [name] = true }, at }
local target           -- { name, kind, north, west, record, height, at }
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

-- The target gone, and any pending one: the ring hidden.
function Compass.Dismiss()
    target, pending = nil, nil
    hide()
end

-- Each frame while shown: the arrow at (bearing - facing), the distance; the
-- timeout and arrival; hidden (kept) when the position or facing can't be read.
local function frame()
    local t = target
    if not t then hide(); return end
    if GetTime() - t.at > Compass.TIMEOUT or onTaxi() then Compass.Dismiss(); return end
    local pn, pw = here()
    local f = facing()
    if not (pn and f) or not lastSweep or GetTime() - lastSweep > NR.db.interval + Compass.GRACE then
        hide()
        return
    end
    local north, east = t.north - pn, -(t.west - pw)
    local d = math.sqrt(north * north + east * east)
    if t.record and not t.height and d <= Compass.ARRIVED then Compass.Dismiss(); return end
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

local function show()
    local c = NR.Alert.COLOURS[target.kind] or NR.Alert.COLOURS.herbs
    circle:SetVertexColor(c[1], c[2], c[3], 0.85)
    ring:Show()
    frame()
end

--------------------------------------------------------------------------------
-- The target
--------------------------------------------------------------------------------

local function eligible() return Compass.On() and not API.Dead() and not onTaxi() end

-- The nearest record made at `now` whose name `names` holds, or nil.
local function newest(names, now)
    local pn, pw = here()
    if not pn then return nil end
    local best, bestD
    for _, r in ipairs(NR.Icons.Records()) do
        if r.born == now and names[r.name] then
            local d = (r.north - pn) ^ 2 + (r.west - pw) ^ 2
            if not bestD or d < bestD then best, bestD = r, d end
        end
    end
    return best
end

local function aimAt(r, at)
    target = { name = r.name, kind = r.kind, north = r.north, west = r.west, record = r, height = r.height, at = at }
end

-- The alert fired (Alert.Update, after the cooldown and the skill filter): a
-- pending target, resolved at once by a record of its names made this sweep.
function Compass.Alerted(names, now)
    if not eligible() then return end
    local set = {}
    for _, name in ipairs(names) do set[name] = true end
    local r = newest(set, now)
    if r then
        pending = nil
        aimAt(r, now)
        show()                                         -- this sweep was just reconciled
    else
        pending = { names = set, at = now }
    end
end

-- After each radar sweep's Icons.Update, before the alert and the learner:
-- the pending target resolved or lapsed, the target followed, shown.
function Compass.Reconcile(result, now)
    if not Compass.On() then return end
    lastSweep = now
    if pending then
        if now - pending.at > Compass.PENDING then
            pending = nil
        else
            local r = newest(pending.names, now)
            if r then
                aimAt(r, pending.at)
                pending = nil
            end
        end
    end
    local t = target
    if not t then hide(); return end
    if not t.record then
        -- After a passing clear: the same node measured again, within REBIND yards.
        for _, r in ipairs(NR.Icons.Records()) do
            if r.name == t.name and math.sqrt((r.north - t.north) ^ 2 + (r.west - t.west) ^ 2) <= Compass.REBIND then
                t.record, t.north, t.west = r, r.north, r.west
                break
            end
        end
    end
    if t.record then
        t.height = t.record.height
        show()                                         -- its first frame checks the timeout
    else
        hide()
    end
end

-- Icons dropped a record (missed, the rim, gathered): its target is dismissed.
function Compass.Dropped(r)
    if target and target.record == r then Compass.Dismiss() end
end

-- Icons cleared every record: for a passing reason the target keeps its
-- position, hidden until its node is measured again; else it's dismissed.
function Compass.Cleared(why)
    if why == "passing" then
        if target then
            target.record = nil
            hide()
        end
    else
        Compass.Dismiss()
    end
end

Compass._test = {
    ring = ring, arrow = arrow, text = text, circle = circle, frame = frame,
    target = function() return target end, pending = function() return pending end,
}
