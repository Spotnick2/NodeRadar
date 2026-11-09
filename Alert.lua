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
--
-- From 70862 (the minimap scan, #91) the gathered node is also counted out at once: the scan's
-- reads are sparse, and mining a vein then reaching the next one read 1 then 1, never the 0 in
-- between (the owner's run: no sound). The loot window keeps the scan from reading the gathered
-- dot back in (the cursor isn't over the world). Before 70862 the sweep's own drop does it.
-- A vein can be mined more than once: while the player is still within NEAR yards of where
-- they gathered, a rise of that name is that same node, back in the count (the owner's run:
-- a sound on the vein being mined).
Alert.NEAR = 15
local spots = {}      -- [name] = { north, west }: where the player gathered one (70862 on)
local owed = {}       -- [name] = { at, ... }: one time a token, nodes a count's rise announced,
                      -- not yet located (70862 on)
-- Each token lives OWED_TTL seconds at most (its own age: a later rise doesn't renew it), and a
-- fall, a gather or a new area retires the oldest (Codex, PR #102: an old token silenced a later,
-- unrelated replacement).
Alert.OWED_TTL = 60
local function owedLive(name, now)
    local list = owed[name]
    if not list then return nil end
    for i = #list, 1, -1 do if now - list[i] > Alert.OWED_TTL then table.remove(list, i) end end
    if #list == 0 then owed[name] = nil; return nil end
    return list
end
local function owedRetire(name, n, now)
    local list = owedLive(name, now)                  -- the expired out first (Codex, PR #102)
    for _ = 1, n do if list and #list > 0 then table.remove(list, 1) end end   -- the oldest live first
end
local risenFrom = {}
local prevCounts = {}

local function here()
    local ok, north, west = pcall(UnitPosition, "player")
    north, west = ok and API.Num(north), ok and API.Num(west)
    if north and west then return north, west end
end

local function near(spot)
    local n, w = here()
    return n ~= nil and (n - spot[1]) ^ 2 + (w - spot[2]) ^ 2 <= Alert.NEAR ^ 2
end

function Alert.Gathered(name, now)
    gathered[name] = now
    owedRetire(name, 1, now)
    if API.Blind() and hist and (hist.counts[name] or 0) > 0 then
        hist.counts[name] = hist.counts[name] - 1
        local n, w = here()
        spots[name] = n and { n, w } or nil
        API.Trace("alert: gathered " .. tostring(name) .. ", counted out")
    end
end

-- The next successful sweep sets the counts without alerting.
function Alert.Reset(why)
    hist = nil
    owed = {}
    -- One baseline: a node the next read counts silently is located silently too (Codex,
    -- PR #102: a node shown by a zoom out sounded once located).
    if NR.Locate then NR.Locate.Rebaseline() end
    API.Trace("alert: reset (" .. tostring(why or "?") .. "): the next read is a silent baseline")
end

-- A new area: counts from zero, so its nodes alert.
function Alert.NewArea(now)
    hist = { counts = {}, drops = {}, at = now }
    owed = {}
    API.Trace("alert: a new area, counts from zero")
end

-- Whether the player can gather a node of that name (#26): only a known
-- requirement above a readable skill says no, and for herbs not while
-- Cultivation is ready. Everything unknown alerts.
Alert.SKILL_LINES = { herbs = 182, ore = 186 }   -- Herbalism, Mining
function Alert.Gatherable(name)
    if not NR.db.skillOnly then return true end
    local info = NR.Learn.Info(name)
    local need = info and API.Num(info.skill)
    if not need then return true end
    local kind = NR.Learn.Kind(name)
    local have = API.Skill(Alert.SKILL_LINES[kind])
    if not have or have >= need then return true end
    return kind == "herbs" and API.CultivationReady()
end

-- Node counts by name, and the node blips by name.
local function nodes(result)
    local counts, blips = {}, {}
    for name, list in pairs(result.byName) do
        local kind = NR.Learn.Kind(name)
        if kind then counts[name], blips[name] = #list, list end
    end
    return counts, blips
end

-- Whether the player chose to skip a node of that name (#47): its item
-- unchecked. A name without NODE_INFO (learned on Forever) can't be listed, so
-- it's never skipped.
function Alert.Ignored(name)
    local info = NR.Learn.Info(name)
    return info ~= nil and NR.Track.Ignored(info.item)
end

-- Everything NodeRadar does for a node is for these: gatherable, not skipped.
function Alert.Wanted(name)
    return Alert.Gatherable(name) and not Alert.Ignored(name)
end

-- After each successful radar sweep. Returns the names that alerted.
function Alert.Update(result, now)
    local counts, blips = nodes(result)
    return Alert.Counts(counts, now, blips, result)
end

-- Node counts by name: the old sweep's, or the minimap scan's presence read (#91), which has
-- no positions (blips nil: the sound and the chat line's names, no sonar, no ping). `every`:
-- the seconds between successful reads at most, so a scan's slower cadence never blanks the
-- baseline (the old sweep's interval otherwise).
-- `blink`: the seconds a rise after a drop counts as the same node at the edge (BLINK by
-- default; the scan's sparse reads use a shorter one, #91).
function Alert.Counts(counts, now, blips, result, every, blink)
    if hist and now - hist.at > Alert.STALE + (every or NR.db.interval) then
        hist = nil
        API.Trace("alert: stale, baseline")
    end
    if not hist then
        hist = { counts = counts, drops = {}, at = now }
        API.Trace("alert: baseline set")
        return nil
    end
    local new = {}
    risenFrom = {}
    for name, spot in pairs(spots) do
        if not near(spot) then spots[name] = nil end      -- moved away: a new one alerts again
    end
    for name, n in pairs(counts) do
        local before = hist.counts[name] or 0
        if n > before and spots[name] then
            API.Trace("alert: " .. name .. " back while still at the one gathered: the same node, silent")
        elseif n > before then
            risenFrom[name] = before
            local drop = hist.drops[name]
            if not (drop and now - drop <= (blink or Alert.BLINK)) then
                new[#new + 1] = name
            else
                API.Trace(("alert: %s rose %.1f s after a drop: a blink, silent"):format(name, now - drop))
            end
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
    prevCounts = hist.counts
    hist.counts, hist.at = counts, now
    -- From 70862 (#91): each rise is owed a located node, which then ripples without a second
    -- sound (Alert.Located).
    if API.Blind() then
        -- A fall retires as many tokens (the nodes they were for may be the ones gone).
        for name in pairs(owed) do
            local fall = (prevCounts[name] or 0) - (counts[name] or 0)
            if fall > 0 then owedRetire(name, fall, now) end
        end
        for _, name in ipairs(new) do
            if Alert.Wanted(name) then
                local list = owedLive(name, now) or {}
                for _ = 1, (counts[name] or 0) - (risenFrom[name] or 0) do list[#list + 1] = now end
                owed[name] = list
            end
        end
    end
    -- Counted whatever the skill and the choices (a skill-up or a node tracked
    -- again mustn't make old nodes new); a node the player can't gather or
    -- skips neither alerts nor spends the cooldown (#26, #47).
    local fire = {}
    for _, name in ipairs(new) do
        if Alert.Wanted(name) then fire[#fire + 1] = name end
    end
    if #fire == 0 then
        if #new > 0 then API.Trace("alert: new but not wanted: " .. table.concat(new, ", ")) end
        return nil
    end
    if now - lastAlert < NR.db.cooldown then
        API.Trace("alert: cooldown, silent: " .. table.concat(fire, ", "))
        return nil
    end
    lastAlert = now
    table.sort(fire)
    API.Trace("alert: FIRED " .. table.concat(fire, ", "))
    Alert.Fire(fire, blips, result)
    return fire
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
    if NR.MoveScan and NR.MoveScan.On() then NR.MoveScan.Hold(NR.MoveScan.SONAR_HOLD) end   -- seen whole (#91)
    for _, f in ipairs({ s.rings[1], s.rings[2], s.glow }) do
        f.tex:SetVertexColor(c[1], c[2], c[3])
        f:SetAlpha(0)
        f.anim:Stop()
        f.anim:Play()
    end
end

-- The sounds (#13), the owner's picks: Blizzard's minimap ping; two of the
-- client's files by FileDataID, both heard on 70450 (Spell_Uni_SonarPing_01,
-- and 12.0_UI_Alert_Tonal_Radar_Ping, a 12.0 file in this client too); six
-- of ours from Pixabay (Tools/import_sounds.py, README "Sounds").
Alert.SOUNDS = {
    ping      = { kit = Alert.MAP_PING },
    sonarping = { file = 569006 },
    radar     = { file = 7466154 },
    sonar     = { file = Alert.MEDIA .. "Sonar.ogg" },
    radarblip = { file = Alert.MEDIA .. "RadarBlip.ogg" },
    deepsea   = { file = Alert.MEDIA .. "DeepSea.ogg" },
    bell      = { file = Alert.MEDIA .. "BellChime.ogg" },
    notify    = { file = Alert.MEDIA .. "Notification.ogg" },
    hud       = { file = Alert.MEDIA .. "HudPing.ogg" },
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

-- The chat line: each blip of each name with its zone-map coordinates (#27),
-- "Peacebloom (45.2, 61.8)"; a blip without them, or a name without blips,
-- is the name alone.
function Alert.ChatLine(names, blips, result)
    local parts = {}
    for _, name in ipairs(names) do
        local list = blips and blips[name] or {}
        if #list == 0 then parts[#parts + 1] = name end
        for _, b in ipairs(list) do
            local map, x, y = NR.Scan.MapPosition(result, b)
            parts[#parts + 1] = map and ("%s (%.1f, %.1f)"):format(name, x * 100, y * 100) or name
        end
    end
    return table.concat(parts, ", ")
end

function Alert.Fire(names, blips, result)
    local db = NR.db
    if db.sound then Alert.PlaySound() end
    local first
    for _, name in ipairs(names) do
        local kind = NR.Learn.Kind(name)
        for _, b in ipairs(blips and blips[name] or {}) do
            first = first or b
            if db.ring then
                local x, y = NR.Icons.At(b)            -- the node's measured centre, with icons on (#28)
                Alert.Sonar(x, y, kind)
            end
        end
    end
    if db.chat then API.Say(Alert.ChatLine(names, blips, result)) end
    if db.ping and first and not IsInGroup() then
        local ok, err = pcall(Minimap.PingLocation, Minimap, first.x, first.y)
        if not ok then API.Fail("PingLocation", err) end
    end
end

-- A node the scan located where none was known (#91, Locate.lua): a rise already announced
-- it (only its sonar, no second sound), or it's new to us (the full alert: a node replaced
-- another between two reads, or one beside the node just gathered, which counts can't see).
function Alert.Located(r, now)
    local pn, pw = UnitPosition("player")
    pn, pw = API.Num(pn), API.Num(pw)
    local okR, radius = pcall(C_Minimap.GetViewRadius)
    radius = okR and API.Num(radius)
    local w = API.Num(Minimap:GetWidth())
    local blip
    if pn and radius and w and radius > 0 then
        local k = radius / (w / 2)
        blip = { x = -(r.west - pw) / k, y = (r.north - pn) / k }
    end
    if not Alert.Wanted(r.name) then return end          -- skipped or beyond the skill: nothing (Codex, PR #102)
    local list = owedLive(r.name, now)
    if list then
        table.remove(list)                               -- the newest: the rise this node most likely is
        API.Trace("alert: " .. r.name .. " located, already announced: its sonar")
        if blip and NR.db.ring then Alert.Sonar(blip.x, blip.y, r.kind or NR.Learn.Kind(r.name)) end
        -- The solo ping the sound couldn't place, now it can (Codex, PR #102).
        if blip and NR.db.ping and not IsInGroup() then
            local ok, err = pcall(Minimap.PingLocation, Minimap, blip.x, blip.y)
            if not ok then API.Fail("PingLocation", err) end
        end
        return
    end
    if r.quiet then return end                          -- there at the first look after a reset
    if now - lastAlert < NR.db.cooldown then
        API.Trace("alert: cooldown, silent: " .. r.name .. " (located)")
        return
    end
    lastAlert = now
    API.Trace("alert: FIRED " .. r.name .. " (located at a new spot)")
    Alert.Fire({ r.name }, { [r.name] = { blip } })
end

-- /nr test: the alert at the map's centre.
function Alert.Test()
    Alert.Fire({ "test" }, { test = { { x = 0, y = 0 } } })
end
