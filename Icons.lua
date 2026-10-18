-- Icons.lua: the item's icon over each node's dot on the minimap (#28,
-- docs/PLAN.md, "Item icons on the minimap's nodes").
--
-- A sweep's blip is up to 5.5 units off its node (the grid's centroid), so a
-- new node's centre is measured once (Scan.Centre) and kept as a record in
-- world yards (UnitPosition: north, west). Later sweeps match records to blips
-- by name and distance; every frame draws them from the player's position.
-- Off (the default, Blizzard's dots), none of this runs.

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
Icons.GATHERED = 15    -- yards: a gather drops the records of its name this near the player
Icons.GRACE = 2        -- seconds past the idle interval without a sweep before the icons hide
Icons.SIZE = 12        -- map units (the dot is about 8)
Icons.FADE = 4         -- map units of fading before the icon's edge meets the rim
Icons.DIM = 0.6        -- alpha of a node the player can't gather
Icons.FALLBACK = { herbs = 2383, ore = 2580 }   -- Find Herbs, Find Minerals: their icons

local records = {}     -- { name, kind, north, west, icon, misses, dim, x, y, frame }
local tries = {}       -- { name, north, west, at, seen }: blips that failed to measure
local free = {}        -- hidden frames, reused
local lastSweep        -- when the icons last reconciled
local instance         -- UnitPosition's fourth value at that sweep

local driver = CreateFrame("Frame")

function Icons.On()
    local db = NR.db
    return db and db.icons and db.enabled and true or false
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
    f:Hide()
    Icons._test.frames = Icons._test.frames + 1
    return f
end

local function stop()
    driver:SetScript("OnUpdate", nil)
end

local function hideAll()
    for _, r in ipairs(records) do if r.frame then r.frame:Hide() end end
    stop()
end

-- Everything forgotten: the records, the failed tries, the frames hidden.
function Icons.Clear()
    for _, r in ipairs(records) do release(r) end
    records, tries, lastSweep, instance = {}, {}, nil, nil
    stop()
end

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
    local edge = half - Icons.SIZE / 2
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

-- After each successful radar sweep, before the alert (Codex, #28: the sonar
-- finds a new node's record) and the learner (which can clear them at once).
function Icons.Update(result, now)
    if not Icons.On() then return end
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

    local blips = {}
    for _, b in ipairs(result.blips) do
        if NR.Learn.Kind(b.name) then blips[#blips + 1] = b end
    end

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
        end
    end

    -- Missed: hidden at once, dropped at the second; faded out past the rim, dropped.
    local kept = {}
    for _, r in ipairs(records) do
        r.misses = matched[r] and 0 or r.misses + 1
        if r.misses >= 2 or dist(r.x, r.y) >= half - Icons.SIZE / 2 then
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
                            misses = 0, x = b.cx, y = b.cy }
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

    -- Shown: every record seen this sweep, dimmed as the alert's skill rule says.
    lastSweep = now
    local any = false
    for _, r in ipairs(records) do
        if r.misses == 0 then
            r.dim = not NR.Alert.Gatherable(r.name)
            if not r.frame then r.frame = acquire() end
            r.frame.tex:SetTexture(r.icon)
            r.frame.tex:SetDesaturated(r.dim)
            any = true
        end
    end
    if any then
        driver:SetScript("OnUpdate", draw)
        draw()
    else
        stop()
    end
end

-- The player gathered a node of that name: its records within GATHERED yards
-- go, so a node of the name beside it is measured, not matched to it (Codex).
function Icons.Gathered(name)
    if not Icons.On() then return end
    local pn, pw = player()
    if not pn then return end
    local kept = {}
    for _, r in ipairs(records) do
        if r.name == name and dist(r.north - pn, r.west - pw) <= Icons.GATHERED then
            release(r)
        else
            kept[#kept + 1] = r
        end
    end
    records = kept
end

-- Where the sonar goes for an alerted blip: its record's centre when it has one.
function Icons.At(b)
    local r = b.record
    if r and r.x then return r.x, r.y end
    return b.x, b.y
end

Icons._test = { frames = 0, records = function() return records end, tries = function() return tries end,
                draw = draw, driver = driver }
