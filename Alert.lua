-- Alert.lua: new nodes and the alert (docs/PLAN.md, "New nodes and the alert").
--
-- A blip's position is the player's, not the world's, so matching blips across
-- sweeps fails while the player moves (Codex). v1 counts instead: per node
-- name, a rise in its number of blips is a new node.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Alert = {}
NR.Alert = Alert

Alert.BLINK = 20      -- seconds: a rise this soon after a drop is the same node at the map's edge
Alert.STALE = 5       -- seconds without a successful sweep before the next is a silent baseline
Alert.MAP_PING = 3175 -- SOUNDKIT.MAP_PING (SoundKitConstants.lua:73)
Alert.RING = "Interface\\Cooldown\\ping4"

local hist            -- { counts, drops, at }; nil: the next sweep is a silent baseline
local lastAlert = -math.huge

-- The next successful sweep sets the counts without alerting.
function Alert.Reset() hist = nil end

-- A new area: counts from zero, so its nodes alert.
function Alert.NewArea(now) hist = { counts = {}, drops = {}, at = now } end

-- Node counts by name, and the node blips by name.
local function nodes(result)
    local counts, blips = {}, {}
    for name, list in pairs(result.byName) do
        local kind = NR.Learn.Kind(name)
        if kind then counts[name], blips[name] = #list, list end
    end
    return counts, blips
end

-- After each successful radar sweep. Returns the names that alerted.
function Alert.Update(result, now)
    if hist and now - hist.at > Alert.STALE then hist = nil end
    local counts, blips = nodes(result)
    if not hist then
        hist = { counts = counts, drops = {}, at = now }
        return nil
    end
    local new = {}
    for name, n in pairs(counts) do
        local before = hist.counts[name] or 0
        if n > before then
            local drop = hist.drops[name]
            if not (drop and now - drop <= Alert.BLINK) then new[#new + 1] = name end
        end
    end
    for name, before in pairs(hist.counts) do
        if (counts[name] or 0) < before then hist.drops[name] = now end
    end
    hist.counts, hist.at = counts, now
    if #new == 0 or now - lastAlert < NR.db.cooldown then return nil end
    lastAlert = now
    table.sort(new)
    Alert.Fire(new, blips)
    return new
end

--------------------------------------------------------------------------------
-- The alert: the sound, a ring on each blip of the new names, a chat line,
-- Blizzard's ping (solo only: it's sent to the group, round 2)
--------------------------------------------------------------------------------

local rings = {}

local function ring()
    for _, r in ipairs(rings) do if not r:IsShown() then return r end end
    local f = CreateFrame("Frame", nil, Minimap)
    f:SetSize(12, 12)
    f:SetFrameStrata("HIGH")   -- v1's "HIGHLIGHT" is a draw layer and throws (round 1)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetTexture(Alert.RING)
    t:SetAllPoints(f)
    f.tex = t
    local anim = f:CreateAnimationGroup()
    local scale = anim:CreateAnimation("Scale")
    scale:SetScale(4, 4)
    scale:SetDuration(1)
    scale:SetSmoothing("OUT")
    local alpha = anim:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0.9)
    alpha:SetToAlpha(0)
    alpha:SetDuration(1)
    alpha:SetSmoothing("OUT")
    anim:SetScript("OnFinished", function() f:Hide() end)
    f.anim = anim
    f:Hide()
    rings[#rings + 1] = f
    return f
end

function Alert.Ring(x, y)
    local f = ring()
    local db = NR.db
    f.tex:SetVertexColor(db.ringR, db.ringG, db.ringB, 0.9)
    f:ClearAllPoints()
    f:SetPoint("CENTER", Minimap, "CENTER", x, y)
    f:Show()
    f.anim:Stop()
    f.anim:Play()
end

function Alert.Fire(names, blips)
    local db = NR.db
    if db.sound then
        local ok, willPlay = pcall(PlaySound, Alert.MAP_PING, "Master")
        if not ok or willPlay == false then API.Fail("sound", ok and "refused" or willPlay) end
    end
    local first
    for _, name in ipairs(names) do
        for _, b in ipairs(blips and blips[name] or {}) do
            first = first or b
            if db.ring then Alert.Ring(b.x, b.y) end
        end
    end
    if db.chat then API.Say(table.concat(names, ", ")) end
    if db.ping and first and not IsInGroup() then
        local ok, err = pcall(Minimap.PingLocation, Minimap, first.x, first.y)
        if not ok then API.Fail("PingLocation", err) end
    end
end

-- /nr test: the alert at the map's centre.
function Alert.Test()
    Alert.Fire({ "test" }, { test = { { x = 0, y = 0 } } })
end
