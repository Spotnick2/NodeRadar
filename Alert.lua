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
Alert.STALE = 5       -- seconds without a successful sweep, past the idle interval, before
                      -- the next is a silent baseline (plus the interval: Codex, #13)
Alert.GATHERED = 15   -- seconds: a drop this soon after gathering that name is the gathered node
Alert.MAP_PING = 3175 -- SOUNDKIT.MAP_PING (SoundKitConstants.lua:73)

local hist            -- { counts, drops, at }; nil: the next sweep is a silent baseline
local lastAlert = -math.huge
local gathered = {}   -- [name] = when the player last gathered one

-- The player gathered a node of that name: the drop that follows is that node
-- gone, not one blinking at the edge, so the next of that name alerts.
function Alert.Gathered(name, now) gathered[name] = now end

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
    if hist and now - hist.at > Alert.STALE + NR.db.interval then hist = nil end
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
        if (counts[name] or 0) < before then
            local g = gathered[name]
            if g and now - g <= Alert.GATHERED then
                gathered[name] = nil
                hist.drops[name] = nil                 -- an earlier blink no longer holds (Codex, PR #10)
            else
                hist.drops[name] = now
            end
        end
    end
    hist.counts, hist.at = counts, now
    if #new == 0 or now - lastAlert < NR.db.cooldown then return nil end
    lastAlert = now
    table.sort(new)
    Alert.Fire(new, blips)
    return new
end

--------------------------------------------------------------------------------
-- The alert: the sound, a sonar on each blip of the new names, a chat line,
-- Blizzard's ping (solo only: it's sent to the group, round 2)
--
-- The sonar (the owner's pick): two thin rings ripple out from the node, the
-- second 0.4 s after the first, and a soft glow stays on it, 3 s in all.
-- Green for herbs, gold for ore. Our own art (Tools/make_media.py), drawn
-- additively: Blizzard's ping4 drew in a black square (release check).
--------------------------------------------------------------------------------

Alert.MEDIA = "Interface\\AddOns\\NodeRadar\\Media\\"
Alert.COLOURS = { herbs = { 0.3, 1.0, 0.4 }, ore = { 1.0, 0.8, 0.25 } }
Alert.SIZE = 20       -- the ring at scale 1, in the map's units (it grows to 1.6)

local sonars = {}

local function part(parent, file, size, layer)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f:SetPoint("CENTER", parent, "CENTER")
    local t = f:CreateTexture(nil, layer)
    t:SetTexture(Alert.MEDIA .. file)
    t:SetBlendMode("ADD")
    t:SetAllPoints(f)
    f.tex = t
    f:SetAlpha(0)                              -- seen only while its animation runs
    return f
end

local function ripple(f, delay)
    local anim = f:CreateAnimationGroup()
    local scale = anim:CreateAnimation("Scale")
    scale:SetScaleFrom(0.2, 0.2)
    scale:SetScaleTo(1.6, 1.6)
    scale:SetDuration(1)
    scale:SetSmoothing("OUT")
    scale:SetStartDelay(delay)
    local alpha = anim:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetDuration(1)
    alpha:SetSmoothing("IN")
    alpha:SetStartDelay(delay)
    f.anim = anim
end

local function fade(anim, from, to, duration, order)
    local a = anim:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(duration)
    a:SetOrder(order)
end

local function sonar()
    for _, s in ipairs(sonars) do if not s:IsShown() then return s end end
    local s = CreateFrame("Frame", nil, Minimap)
    s:SetSize(Alert.SIZE, Alert.SIZE)
    s:SetFrameStrata("HIGH")                   -- v1's "HIGHLIGHT" is a draw layer and throws (round 1)
    s.rings = { part(s, "SonarRing", Alert.SIZE, "OVERLAY"), part(s, "SonarRing", Alert.SIZE, "OVERLAY") }
    ripple(s.rings[1], 0)
    ripple(s.rings[2], 0.4)
    s.glow = part(s, "SonarGlow", Alert.SIZE * 0.8, "ARTWORK")
    local g = s.glow:CreateAnimationGroup()
    fade(g, 0, 0.9, 0.2, 1)                    -- in
    fade(g, 0.9, 0.9, 1.3, 2)                  -- held
    fade(g, 0.9, 0, 1.5, 3)                    -- out: 3 s in all
    g:SetScript("OnFinished", function() s:Hide() end)
    s.glow.anim = g
    s:Hide()
    sonars[#sonars + 1] = s
    return s
end

function Alert.Sonar(x, y, kind)
    local s = sonar()
    local c = Alert.COLOURS[kind] or Alert.COLOURS.herbs
    s:ClearAllPoints()
    s:SetPoint("CENTER", Minimap, "CENTER", x, y)
    s.kind = kind
    s:Show()
    for _, f in ipairs({ s.rings[1], s.rings[2], s.glow }) do
        f.tex:SetVertexColor(c[1], c[2], c[3])
        f:SetAlpha(0)
        f.anim:Stop()
        f.anim:Play()
    end
end

-- The sounds (#13): Blizzard's minimap ping, our own sonar (Tools/make_media.py),
-- and two of the client's files by FileDataID, the owner's picks, both heard on
-- 70450: Spell_Uni_SonarPing_01 and 12.0_UI_Alert_Tonal_Radar_Ping (a 12.0
-- file, in this client too).
Alert.SOUNDS = {
    ping      = { kit = Alert.MAP_PING },
    sonar     = { file = Alert.MEDIA .. "Sonar.ogg" },
    sonarping = { file = 569006 },
    radar     = { file = 7466154 },
}

-- The chosen sound, whatever db.sound says (the Options page's choice plays it).
function Alert.PlaySound()
    local s = Alert.SOUNDS[NR.db.soundKind] or Alert.SOUNDS.ping
    local ok, willPlay
    if s.file then
        ok, willPlay = pcall(PlaySoundFile, s.file, "Master")
    else
        ok, willPlay = pcall(PlaySound, s.kit, "Master")
    end
    if not ok or not willPlay then API.Fail("sound", ok and "refused" or willPlay) end
end

function Alert.Fire(names, blips)
    local db = NR.db
    if db.sound then Alert.PlaySound() end
    local first
    for _, name in ipairs(names) do
        local kind = NR.Learn.Kind(name)
        for _, b in ipairs(blips and blips[name] or {}) do
            first = first or b
            if db.ring then Alert.Sonar(b.x, b.y, kind) end
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
