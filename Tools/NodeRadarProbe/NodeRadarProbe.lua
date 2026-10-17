-- NodeRadarProbe: a throwaway measuring addon for NodeRadar (never shipped).
-- A ForeverProbe module (..\ForeverProbe\docs\GUIDE.md): its lines go to the
-- /fp console and NodeRadarProbeDB.log, never to chat. It answers #2: can an
-- addon read the gathering blips the minimap draws?
--
-- Minimap:UpdateMouseoverAtPoint(x, y) moves the minimap's mouseover to a
-- point, and C_TooltipInfo.GetMinimapMouseover() reads what is there, the data
-- Blizzard's hover tooltip shows (Blizzard_Minimap/Mainline/Minimap.lua:271).
-- Rounds 1 and 2 (70450, docs/FOREVER-PROBE.md): it works with the point in
-- GetCursorPosition's space, with the cursor anywhere once
-- Minimap:SetUsingSoftCursor(true). But a sweep reads every named blip. Round 3
-- (#7) measures three ways to tell nodes from the rest: object IDs from
-- OBJECT_ENTERED_AOI, the owner's idea (turn gathering tracking off and see
-- what vanishes), and each line's colour.
--
--   /fp nr state                        build, the map's geometry, zoom, rotation, tracking
--   /fp nr under                        what the minimap's mouseover reads now (hover a blip first)
--   /fp nr hover                        keep the blip under the cursor for point and ping
--   /fp nr point [soft]                 each coordinate convention at the kept blip
--   /fp nr sweep [conv] [step] [soft]   sample the whole map: names, where, milliseconds
--   /fp nr radar [seconds] [soft]       sweep 3 times a second, logging names as they appear
--   /fp nr stop                         stop the radar
--   /fp nr soft on|off                  Minimap:SetUsingSoftCursor
--   /fp nr ping [dx dy]                 Minimap:PingLocation, at the kept blip by default
--   /fp nr vignettes                    every vignette the client lists
--   /fp nr sound [kit]                  PlaySound: MAP_PING (3175), or a kit
--   /fp nr ring                         v1's ring on the minimap (Interface\Cooldown\ping4)
--   /fp nr toggle                       gathering tracking off and on, sweeping each time
--   /fp nr pairs                        names paired with the game-object IDs in range
--   /fp nr clear                        empty the saved log
--
-- Procedure: /fp steps nr ids (round 3, #7).

local ADDON, NS = ...
local MAX_LOG = 3000

local Probe = ForeverProbe:Module("NodeRadarProbe", { api = 1, cmd = "nr" })

local function say(msg) Probe:Say(msg) end
local function str(v) return Probe.Show(v, true) end
local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
-- A number we can do arithmetic on, or nil (missing or secret).
local function num(v) if type(v) == "number" and not secret(v) then return v end end
-- A plain true; a secret or an error is not.
local function yes(v) return not secret(v) and v == true end

-- The gathering tracking spells (Blizzard_Minimap/Mainline/Minimap.lua:36-39).
local GATHER_SPELLS = { [2383] = "herbs", [8387] = "herbs", [2580] = "ore", [8388] = "ore" }
local MAP_PING = 3175                     -- SoundKitConstants.lua:73
local RING = "Interface\\Cooldown\\ping4"
local SWEEP_STEP = 8                      -- the map's own units between samples
local SWEEP_EVERY = 0.3                   -- seconds between radar sweeps
local NEAR = 12                           -- the map's units: a sweep found the blip where it is

-- This session's measurements: hover (the kept blip), points and softPoints
-- (the conventions jobs), hoverJob, walk and radar (radars), sweeps.
local state = {}

local function overMap()
    local ok, v = pcall(Minimap.IsMouseOver, Minimap)
    return ok and yes(v)
end

local function cursor()
    local x, y = GetCursorPosition()
    return num(x), num(y)
end

local function setSoft(on)
    local ok, err = pcall(Minimap.SetUsingSoftCursor, Minimap, on)
    if not ok then say("SetUsingSoftCursor(" .. tostring(on) .. "): ERROR " .. str(err)) end
    return ok
end

-- The minimap's rect in its own units, its effective scale and UIParent's;
-- nil and why when any part is missing or secret.
local function geometry()
    local es, ues = num(Minimap:GetEffectiveScale()), num(UIParent:GetEffectiveScale())
    local l, b, w, h = Minimap:GetRect()
    l, b, w, h = num(l), num(b), num(w), num(h)
    if not (es and ues and l and b and w and h) or w == 0 or h == 0 then return nil, "geometry unreadable" end
    return { es = es, ues = ues, l = l, b = b, w = w, h = h, cx = l + w / 2, cy = b + h / 2 }
end

-- Ways UpdateMouseoverAtPoint might read its point, each made from a screen
-- position in pixels (GetCursorPosition's space). Round 2 measured `screen`
-- (MEASURED, the radar's default); `center` is what PingLocation takes.
local MEASURED = "screen"
local CONVENTIONS = {
    { name = "center",     to = function(px, py, g) return px / g.es - g.cx, py / g.es - g.cy end },
    { name = "screen",     to = function(px, py) return px, py end },
    { name = "ui",         to = function(px, py, g) return px / g.es, py / g.es end },
    { name = "uiparent",   to = function(px, py, g) return px / g.ues, py / g.ues end },
    { name = "centerpx",   to = function(px, py, g) return px - g.cx * g.es, py - g.cy * g.es end },
    { name = "bottomleft", to = function(px, py, g) return px / g.es - g.l, py / g.es - g.b end },
    { name = "topleft",    to = function(px, py, g) return px / g.es - g.l, g.b + g.h - py / g.es end },
    { name = "unit",       to = function(px, py, g) return (px / g.es - g.l) / g.w, (py / g.es - g.b) / g.h end },
    { name = "unittop",    to = function(px, py, g) return (px / g.es - g.l) / g.w, (g.b + g.h - py / g.es) / g.h end },
    { name = "radius",     to = function(px, py, g) return (px / g.es - g.cx) / (g.w / 2), (py / g.es - g.cy) / (g.h / 2) end },
}

local function convention(name)
    for _, c in ipairs(CONVENTIONS) do if c.name == name then return c end end
end

-- A point well off the map, in pixels: a sample goes there first, so a stale
-- answer can't pass for a new one.
local function farPixels(g) return (g.l - 3 * g.w) * g.es, (g.b - 3 * g.h) * g.es end

-- A line's colour as "rrggbb", or what it is instead (missing, secret).
local function colour(c)
    if secret(c) then return "<secret>" end
    if type(c) ~= "table" then return str(c) end
    local r, g, b = num(c.r), num(c.g), num(c.b)
    if not (r and g and b) then return "<unreadable>" end
    return ("%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- The minimap's mouseover: the names on its lines (one per row), or nil and
-- why; then the data, and each name's line colour (round 3, #7). A secret line
-- reads "<secret>" and never matches a name.
local function mouseover()
    local fn = C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover
    if type(fn) ~= "function" then return nil, "MISSING" end
    local ok, data = pcall(fn)
    if not ok then return nil, "ERROR " .. str(data) end
    if secret(data) then return nil, "<secret>" end
    if type(data) ~= "table" then return nil, str(data) end
    local lines = data.lines
    if secret(lines) or type(lines) ~= "table" then return nil, "lines " .. Probe.Shape(lines), data end
    local names, colours = {}, {}
    for _, line in ipairs(lines) do
        local t = type(line) == "table" and line.leftText or nil
        local c = type(line) == "table" and colour(line.leftColor) or "?"
        if secret(t) then
            names[#names + 1] = "<secret>"
        elseif type(t) == "string" then
            for row in Probe.Plain(t):gmatch("[^\n]+") do
                names[#names + 1] = row
                colours[row] = c
            end
        end
    end
    if #names == 0 then return nil, "no text", data end
    return names, nil, data, colours
end

-- Moves the mouseover to a point (pixels, through a convention) and reads it.
local function sample(conv, g, px, py)
    local x, y = conv.to(px, py, g)
    local ok, err = pcall(Minimap.UpdateMouseoverAtPoint, Minimap, x, y)
    if not ok then return nil, "ERROR " .. str(err) end
    local names, why, _, colours = mouseover()
    return names, why, colours
end

local function join(names) return names and #names > 0 and table.concat(names, ", ") or "nothing" end

local function shares(a, b)
    if not (a and b) then return false end
    for _, x in ipairs(a) do
        for _, y in ipairs(b) do if x == y and x ~= "<secret>" then return true end end
    end
    return false
end

--------------------------------------------------------------------------------
-- What the client says
--------------------------------------------------------------------------------

-- The gathering tracking types; logs them unless quiet. Returns the active ones.
local function tracking(quiet)
    local n = C_Minimap.GetNumTrackingTypes()
    local active = {}
    for i = 1, n do
        local info = C_Minimap.GetTrackingInfo(i) or {}
        local spell = num(info.spellID)
        local kind = spell and GATHER_SPELLS[spell]
        if kind then
            if not quiet then
                say(("tracking %d %s spell=%s active=%s (%s)"):format(i, str(info.name), str(spell), str(info.active), kind))
            end
            if yes(info.active) then active[#active + 1] = kind .. " " .. spell end
        end
    end
    if not quiet then
        say(n .. " tracking types; gathering on: " .. (#active > 0 and table.concat(active, ", ") or "none"))
    end
    return active
end

local function report()
    say("client " .. table.concat({ GetBuildInfo() }, " ", 1, 2))
    local g, why = geometry()
    if g then
        say(("minimap %.1fx%.1f at (%.1f, %.1f) in its units; effective scale %.3f, UIParent %.3f"):format(
            g.w, g.h, g.l, g.b, g.es, g.ues))
    else
        say("minimap: " .. why)
    end
    local okZ, z = pcall(Minimap.GetZoom, Minimap)
    local okR, r = pcall(C_Minimap.GetViewRadius)
    say("zoom " .. str(okZ and z) .. "; rotateMinimap " .. str(GetCVarBool("rotateMinimap")) .. "; view radius "
        .. str(okR and r) .. " yd; cursor on the minimap " .. str(overMap()))
    say("UpdateMouseoverAtPoint " .. type(Minimap.UpdateMouseoverAtPoint) .. ", SetUsingSoftCursor "
        .. type(Minimap.SetUsingSoftCursor) .. ", PingLocation " .. type(Minimap.PingLocation)
        .. ", GetMinimapMouseover " .. type(C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover))
    return tracking(), g
end

local function under()
    local names, why, data = mouseover()
    local px, py = cursor()
    say("mouseover: " .. (names and join(names) or why) .. "; cursor " .. str(px) .. ", " .. str(py)
        .. "; on the minimap " .. str(overMap()))
    if data then say("  data: " .. Probe.Describe(data, 3)) end
    return names
end

-- The blip under the real cursor, kept for the conventions and the ping: its
-- names, the cursor in pixels, its offset from the map's centre in the map's
-- units, and the map's geometry at that moment.
local function captureHover()
    if not overMap() then return nil, "the cursor isn't on the minimap" end
    local names, why, data = mouseover()
    if not names then return nil, "nothing under the cursor (" .. why .. ")" end
    local px, py = cursor()
    local g = geometry()
    if not (px and py and g) then return nil, "cursor or geometry unreadable" end
    state.hover = { names = names, px = px, py = py, g = g, dx = px / g.es - g.cx, dy = py / g.es - g.cy }
    state.points, state.softPoints = nil, nil
    say(("hovered %s at cursor (%.1f, %.1f) px, (%.1f, %.1f) from the map's centre in its units"):format(
        join(names), px, py, state.hover.dx, state.hover.dy))
    say("  data: " .. Probe.Describe(data, 3))
    return state.hover
end

-- Tries each convention at the kept blip, one every 0.1 s: the far point
-- first (it must read nothing), then the blip, read at once and 0.1 s later.
-- A convention works when the blip's name comes back and the far point was
-- empty; `later` lists those that answered only after the 0.1 s. With `soft`
-- the minimap uses the soft cursor for the whole job, and stops after it.
local function tryConventions(soft)
    local h = state.hover
    if not h then
        say("point: no blip kept; hover one, then /fp nr hover")
        return nil
    end
    local job = { i = 0, working = {}, later = {}, soft = soft }
    local label = soft and "point (soft)" or "point"
    if soft then state.softPoints = job; setSoft(true) else state.points = job end
    local fx, fy = farPixels(h.g)
    local function nextOne()
        job.i = job.i + 1
        local c = CONVENTIONS[job.i]
        if not c then
            if soft then setSoft(false) end
            job.done = true
            say(label .. ": the blip read back with "
                .. (#job.working > 0 and table.concat(job.working, ", ") or "NO convention")
                .. "; cursor on the map " .. str(overMap()))
            return
        end
        local stale = sample(c, h.g, fx, fy)
        local now, why = sample(c, h.g, h.px, h.py)
        local x, y = c.to(h.px, h.py, h.g)
        C_Timer.After(0.1, function()
            local later, whyLater = mouseover()
            local hitNow, hitLater = shares(now, h.names), shares(later, h.names)
            local works = (hitNow or hitLater) and not stale
            if works then
                job.working[#job.working + 1] = c.name
                if not hitNow then job.later[c.name] = true end
            end
            say(("%s %s (%.3f, %.3f): far %s; at once %s; 0.1 s later %s%s"):format(label, c.name, x, y,
                stale and ("STALE " .. join(stale)) or "nothing", now and join(now) or why,
                later and join(later) or whyLater,
                works and " HIT" or ((hitNow or hitLater) and " (a hit, but the far point wasn't empty)" or "")))
            nextOne()
        end)
    end
    nextOne()
    return job
end

-- The conventions to sweep with: the one named, else the first that worked
-- (with the soft cursor when `soft`), else all of them.
local function chosen(name, soft)
    if name then
        local c = convention(name)
        return c and { c } or {}
    end
    local job = soft and state.softPoints or state.points
    local w = job and job.working
    if w and #w > 0 then return { convention(w[1]) } end
    return CONVENTIONS
end

-- Samples the whole map, a square of points `step` apart in its own units,
-- through one convention, and keeps where each name was found (the centre of
-- its hits, from the map's centre in its units). Then puts the mouseover back
-- on the cursor when it's on the map, else off the map. With `soft` the
-- minimap uses the soft cursor for the sweep only.
local function sweep(conv, step, soft)
    local g, why = geometry()
    if not g then return nil, why end
    step = step or SWEEP_STEP
    local found, list, points, errors = {}, {}, 0, 0
    local t0 = debugprofilestop()
    if soft then setSoft(true) end
    for oy = step / 2, g.h, step do
        for ox = step / 2, g.w, step do
            points = points + 1
            local names, whyNot, colours = sample(conv, g, (g.l + ox) * g.es, (g.b + oy) * g.es)
            if names then
                for _, n in ipairs(names) do
                    local f = found[n]
                    if not f then
                        f = { sx = 0, sy = 0, hits = 0, colour = colours and colours[n] }
                        found[n] = f
                        list[#list + 1] = n
                    end
                    f.sx, f.sy, f.hits = f.sx + ox - g.w / 2, f.sy + oy - g.h / 2, f.hits + 1
                end
            elseif whyNot and whyNot:find("^ERROR") then
                errors = errors + 1
            end
        end
    end
    local px, py = cursor()
    if px and overMap() then sample(conv, g, px, py) else sample(conv, g, farPixels(g)) end
    if soft then setSoft(false) end
    local ms = debugprofilestop() - t0
    for _, f in pairs(found) do f.x, f.y = f.sx / f.hits, f.sy / f.hits end
    return { conv = conv.name, soft = soft, found = found, list = list, points = points, ms = ms, errors = errors }
end

local function sweepText(r)
    local parts = {}
    for _, n in ipairs(r.list) do
        local f = r.found[n]
        parts[#parts + 1] = ("%s (%.0f, %.0f) x%d #%s"):format(n, f.x, f.y, f.hits, tostring(f.colour))
    end
    return ("%s%s: %d names in %d points, %.1f ms%s: %s"):format(r.conv, r.soft and " soft" or "", #r.list, r.points,
        r.ms, r.errors > 0 and (", " .. r.errors .. " errors") or "", #parts > 0 and table.concat(parts, ", ") or "nothing")
end

-- Whether a sweep found the kept blip where it is (within NEAR of it).
local function foundHover(r)
    local h = state.hover
    if not (r and h) then return false end
    for _, n in ipairs(h.names) do
        local f = r.found[n]
        if f and (f.x - h.dx) ^ 2 + (f.y - h.dy) ^ 2 <= NEAR * NEAR then return true end
    end
    return false
end

-- Sweeps with each chosen convention; true when one found the kept blip where it is.
local function sweepAll(name, step, soft)
    local out, hit = {}, false
    for _, c in ipairs(chosen(name, soft)) do
        local r, why = sweep(c, step, soft)
        local line = r and sweepText(r) or (c.name .. ": " .. why)
        if r and foundHover(r) then
            hit = true
            line = line .. " (the kept blip, where it is)"
        end
        say("sweep " .. line)
        out[#out + 1] = line
    end
    if #out == 0 then say("sweep: no convention named " .. str(name)) end
    return table.concat(out, " | "), hit
end

--------------------------------------------------------------------------------
-- The radar: a sweep every SWEEP_EVERY seconds from one OnUpdate
--------------------------------------------------------------------------------

-- The procedure of ours that is running and its step ("ids:6"), or nil. Read
-- from the host's internals until it says so itself (Spotnick2/ForeverProbe#17).
local function procedureStep()
    local steps = ForeverProbe.Steps
    if type(steps) ~= "table" or type(steps.Active) ~= "function" then return nil end
    local ok, proc, rec = pcall(steps.Active)
    if ok and type(proc) == "table" and proc.module == Probe and type(rec) == "table" then
        return proc.name .. ":" .. tostring(rec.at)
    end
end

--------------------------------------------------------------------------------
-- Objects in range (round 3, #7): OBJECT_ENTERED_AOI / OBJECT_LEFT_AOI carry a
-- GUID; a game object's ("GameObject-0-server-instance-zone-ID-spawn") holds its
-- object ID, the same in every language. state.inRange[guid] = ID while it's in
-- range; state.pairs[name] = the IDs in range every time a sweep saw the name.
--------------------------------------------------------------------------------

state.inRange, state.pairs, state.aoiCounts = {}, {}, {}

-- A GUID's kind and, for a game object or a creature, its ID; nil for a secret.
local function guidParts(guid)
    if secret(guid) or type(guid) ~= "string" then return nil end
    local f = {}
    for part in guid:gmatch("[^%-]+") do f[#f + 1] = part end
    local kind = f[1]
    local id = (kind == "GameObject" or kind == "Creature" or kind == "Vehicle") and tonumber(f[6]) or nil
    return kind, id
end

local function aoi(event, guid)
    local kind, id = guidParts(guid)
    local key = (kind or "<secret>") .. (event == "OBJECT_ENTERED_AOI" and "+" or "-")
    state.aoiCounts[key] = (state.aoiCounts[key] or 0) + 1
    if kind ~= "GameObject" then return end
    if event == "OBJECT_ENTERED_AOI" then
        state.inRange[guid] = id
        say(("AOI+ GameObject %s (%s)"):format(str(id), guid))
    else
        state.inRange[guid] = nil
        say(("AOI- GameObject %s"):format(str(id)))
    end
end

-- Pairs each name a sweep saw with the game-object IDs in range now: the
-- intersection over every sweep that saw it. Skipped while nothing is in range.
local function pairNames(list)
    local ids = {}
    for _, id in pairs(state.inRange) do if id then ids[id] = true end end
    if not next(ids) then return end
    for _, n in ipairs(list) do
        local cand = state.pairs[n]
        if not cand then
            cand = {}
            for id in pairs(ids) do cand[id] = true end
            state.pairs[n] = cand
        else
            for id in pairs(cand) do if not ids[id] then cand[id] = nil end end
        end
    end
end

local function idList(set)
    local list = {}
    for id in pairs(set) do list[#list + 1] = id end
    table.sort(list)
    return table.concat(list, " ")
end

-- ClosestGameObjectPosition for every game-object ID in range: documented with
-- secret returns (UnitDocumentation.lua:34); logs what comes back.
local function closest()
    local seen, out = {}, {}
    for _, id in pairs(state.inRange) do
        if id and not seen[id] then
            seen[id] = true
            local p = Probe.Pack(pcall(ClosestGameObjectPosition, id))
            local line = ("ClosestGameObjectPosition(%d): %s n=%d %s, %s, %s"):format(id, p[1] and "returned" or "ERROR",
                p.n - 1, str(p[2]), str(p[3]), str(p[4]))
            say(line)
            out[#out + 1] = line
        end
    end
    return #out .. " IDs asked"
end

local function pairsText()
    local names, parts = {}, {}
    for n in pairs(state.pairs) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do parts[#parts + 1] = n .. " = [" .. idList(state.pairs[n]) .. "]" end
    return #parts > 0 and table.concat(parts, "; ") or "no pairs"
end

local job
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function()
    if not job then return end
    local now = GetTime()
    if job.last and now - job.last < SWEEP_EVERY then return end
    job.last = now
    -- A radar a step started ends with the step: Stop, Back, or another procedure.
    if job.owned and procedureStep() ~= job.ownerStep then
        job.finish("its step was left")
        return
    end
    if job.untilT and now >= job.untilT then
        local j = job
        job = nil
        j.finish()
        return
    end
    job.fn()
end)

local function radarText(r)
    local parts = {}
    for _, n in ipairs(r.order) do parts[#parts + 1] = ("%s +%.1f s"):format(n, r.seen[n]) end
    return ("%s%s: %d sweeps, %d skipped with the cursor on the map, %.1f ms average, %.1f ms max%s; %d names: %s"):format(
        r.conv, r.soft and " soft" or "", r.sweeps, r.skipped, r.sweeps > 0 and r.totalMs / r.sweeps or 0, r.maxMs,
        r.hoverNames and (", hover read wrong " .. r.flicker .. " times") or "", #r.order,
        #parts > 0 and table.concat(parts, ", ") or "none")
end

-- Sweeps until stopped (or for `seconds`), logging each name the first time
-- it's found. Without hoverNames it skips while the cursor is on the map, as
-- NodeRadar would; with them it sweeps anyway and, after each sweep, checks
-- the mouseover still reads the hovered blip. An `owned` radar belongs to the
-- procedure step that started it and stops when that step is left.
local function startRadar(seconds, hoverNames, owned, soft)
    if job then job.finish() end
    local conv = chosen(nil, soft)
    conv = #conv == 1 and conv[1] or convention(MEASURED)
    local now = GetTime()
    local r = { conv = conv.name, soft = soft, sweeps = 0, skipped = 0, totalMs = 0, maxMs = 0, seen = {}, order = {},
                started = now, hoverNames = hoverNames, flicker = 0 }
    local function finish(why)
        if r.done then return end
        r.done = true
        if job and job.r == r then job = nil end
        say("radar " .. (why and ("stopped, " .. why .. ": ") or "") .. radarText(r))
    end
    job = { r = r, untilT = seconds and (now + seconds), finish = finish, owned = owned,
            ownerStep = owned and procedureStep() or nil, fn = function()
        if not hoverNames and overMap() then r.skipped = r.skipped + 1; return end
        local s = sweep(conv, nil, soft)
        if not s then return end
        pairNames(s.list)
        r.sweeps, r.totalMs, r.maxMs = r.sweeps + 1, r.totalMs + s.ms, math.max(r.maxMs, s.ms)
        for _, n in ipairs(s.list) do
            if not r.seen[n] then
                r.seen[n] = GetTime() - r.started
                r.order[#r.order + 1] = n
                say(("radar +%.1f s: %s at (%.0f, %.0f) #%s"):format(r.seen[n], n, s.found[n].x, s.found[n].y,
                    tostring(s.found[n].colour)))
            end
        end
        if hoverNames and not shares(mouseover(), hoverNames) then r.flicker = r.flicker + 1 end
    end }
    say("radar started with " .. conv.name .. (soft and " (soft cursor)" or "") .. (seconds and (" for " .. seconds .. " s") or "")
        .. (hoverNames and (", hovering " .. join(hoverNames)) or ""))
    return r
end

local function stopRadar()
    if job then job.finish() end
end

--------------------------------------------------------------------------------
-- Marking a node: Blizzard's ping, v1's ring
--------------------------------------------------------------------------------

-- Minimap:PingLocation at an offset from the map's centre in its units (as
-- Blizzard's click does, Minimap.lua:133-143), the kept blip's by default.
local function ping(dx, dy)
    local h = state.hover
    dx, dy = dx or (h and h.dx), dy or (h and h.dy)
    if not (dx and dy) then
        say("ping: no blip kept and no offset given")
        return "no offset"
    end
    local ok, err = pcall(Minimap.PingLocation, Minimap, dx, dy)
    local okP, x, y = pcall(Minimap.GetPingPosition, Minimap)
    say(("PingLocation(%.1f, %.1f): %s; GetPingPosition %s, %s"):format(dx, dy, ok and "returned" or ("ERROR " .. str(err)),
        str(okP and x), str(okP and y)))
    return ok and "returned" or "ERROR", str(okP and x), str(okP and y)
end

local function vignettes()
    local ok, list = pcall(C_VignetteInfo.GetVignettes)
    if not ok or type(list) ~= "table" then
        say("vignettes: " .. str(list))
        return 0
    end
    for i, guid in ipairs(list) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        if info then
            say(("vignette %d %s type=%s atlas=%s onMinimap=%s id=%s"):format(i, str(info.name), str(info.type),
                str(info.atlasName), str(info.onMinimap), str(info.vignetteID)))
        end
    end
    say(#list .. " vignettes")
    return #list
end

local function sound(kit)
    local ok, willPlay, handle = pcall(PlaySound, kit, "Master")
    say(("PlaySound(%s, Master): %s willPlay=%s handle=%s"):format(kit, ok and "returned" or "ERROR",
        str(willPlay), str(handle)))
    return str(willPlay), str(handle)
end

-- v1's ring, with a real strata: v1's "HIGHLIGHT" is a draw layer and threw
-- (round 1). Kept only once it's whole, so a throw can't leave half a ring.
local ring
local function showRing()
    local id = GetFileIDFromPath(RING)
    say("GetFileIDFromPath(" .. RING .. ") = " .. str(id))
    if not ring then
        local f = CreateFrame("Frame", nil, Minimap)
        f:SetAllPoints(Minimap)
        f:SetFrameStrata("HIGH")
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetTexture(RING)
        t:SetPoint("CENTER", Minimap, "CENTER")
        t:SetSize(12, 12)
        t:SetVertexColor(0.2, 1.0, 0.4, 0.9)
        local anim = f:CreateAnimationGroup()
        local scale = anim:CreateAnimation("Scale")
        scale:SetScale(8, 8)
        scale:SetDuration(2)
        scale:SetSmoothing("OUT")
        local alpha = anim:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0.9)
        alpha:SetToAlpha(0)
        alpha:SetDuration(2)
        alpha:SetSmoothing("OUT")
        anim:SetScript("OnFinished", function() f:Hide() end)
        f.anim = anim
        ring = f
    end
    ring:Show()
    ring.anim:Stop()
    ring.anim:Play()
    return str(id)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

-- The words of a command's arguments, and whether "soft" is one of them.
local function words(args)
    local list, soft = {}, false
    for w in (args or ""):gmatch("%S+") do
        if w == "soft" then soft = true else list[#list + 1] = w end
    end
    return list, soft
end

Probe:Command("state", function() report(); vignettes() end, "build, the map's geometry, tracking")
Probe:Command("under", function() under() end, "what the minimap's mouseover reads now")
Probe:Command("hover", function()
    local h, why = captureHover()
    if not h then say("hover: " .. why) end
end, "keep the blip under the cursor (for point and ping)")
Probe:Command("point", function(args)
    local _, soft = words(args)
    tryConventions(soft)
end, "[soft]: each coordinate convention at the kept blip")
Probe:Command("sweep", function(args)
    local w, soft = words(args)
    local name, step = w[1], tonumber(w[2])
    if tonumber(name) then name, step = nil, tonumber(name) end
    sweepAll(name, step, soft)
end, "[conv] [step] [soft]: sample the whole map")
Probe:Command("radar", function(args)
    local w, soft = words(args)
    state.radar = startRadar(tonumber(w[1]), nil, false, soft)
end, "[seconds] [soft]: sweep 3 times a second")
Probe:Command("stop", function() stopRadar() end, "stop the radar")
Probe:Command("soft", function(args)
    local on = args == "on"
    if setSoft(on) then say("SetUsingSoftCursor(" .. tostring(on) .. ")") end
end, "on|off: Minimap:SetUsingSoftCursor")
Probe:Command("ping", function(args)
    local w = words(args)
    ping(tonumber(w[1]), tonumber(w[2]))
end, "[dx dy]: Minimap:PingLocation, at the kept blip by default")
Probe:Command("vignettes", function() vignettes() end, "every vignette the client lists")
Probe:Command("sound", function(args) sound(tonumber(args) or MAP_PING) end, "[kit]: PlaySound, MAP_PING by default")
Probe:Command("ring", function() showRing() end, "v1's ring on the minimap")
Probe:Command("clear", function() Probe:ClearLog(); say("log cleared") end, "empty the saved log")

--------------------------------------------------------------------------------
-- The owner's idea (#7): the blips that vanish while gathering tracking is off
-- are the nodes. Sweeps, turns the active gathering tracking off, sweeps 1.5 s
-- later, turns it back on, sweeps 2.5 s after that. Logs what each call
-- returned and the tracking's state; the host logs a blocked call.
--------------------------------------------------------------------------------

local function gatherIndex()
    for i = 1, C_Minimap.GetNumTrackingTypes() do
        local info = C_Minimap.GetTrackingInfo(i) or {}
        local spell = num(info.spellID)
        if spell and GATHER_SPELLS[spell] and yes(info.active) then return i, info end
    end
end

local function trackingOn(i)
    local info = C_Minimap.GetTrackingInfo(i)
    return info ~= nil and yes(info.active)
end

local function soften(r) return r and r.list or {} end

local function toggleTracking()
    local i, info = gatherIndex()
    if not i then
        say("toggle: no gathering tracking on")
        return nil
    end
    local conv = convention(MEASURED)
    local t = { index = i, name = info.name }
    state.toggle = t
    t.before = soften(sweep(conv, nil, true))
    local ok, err = pcall(C_Minimap.SetTracking, i, false)
    t.offCall = ok and "returned" or ("ERROR " .. str(err))
    say(("toggle %s: %s before; SetTracking(%d, false) %s"):format(str(t.name), join(t.before), i, t.offCall))
    C_Timer.After(1.5, function()
        t.offState = trackingOn(i)
        t.during = soften(sweep(conv, nil, true))
        local ok2, err2 = pcall(C_Minimap.SetTracking, i, true)
        t.onCall = ok2 and "returned" or ("ERROR " .. str(err2))
        say(("toggle: tracking on %s after off; %s while off; SetTracking(%d, true) %s"):format(str(t.offState),
            join(t.during), i, t.onCall))
        C_Timer.After(2.5, function()
            t.back = trackingOn(i)
            t.after = soften(sweep(conv, nil, true))
            local during = {}
            for _, n in ipairs(t.during) do during[n] = true end
            t.vanished = {}
            for _, n in ipairs(t.before) do if not during[n] then t.vanished[#t.vanished + 1] = n end end
            t.done = true
            say(("toggle: back on %s; %s after; vanished while off: %s"):format(str(t.back), join(t.after),
                join(t.vanished)))
        end)
    end)
    return t
end

Probe:Command("toggle", function() toggleTracking() end, "gathering tracking off and on, sweeping each time")
Probe:Command("pairs", function()
    closest()
    say("pairs: " .. pairsText())
end, "names paired with the game-object IDs in range; ClosestGameObjectPosition")

--------------------------------------------------------------------------------
-- The procedure: round 3 (#7)
--------------------------------------------------------------------------------

local function aoiCounts()
    local counts = {}
    for k, v in pairs(state.aoiCounts) do counts[#counts + 1] = k .. "=" .. v end
    table.sort(counts)
    return #counts > 0 and table.concat(counts, " ") or "no AOI events"
end

Probe:Steps("ids", {
    rev = 1,
    title = "Telling nodes from other blips, round 3 (#7)",
    { text = "Stand near a herb or ore, out of combat, and turn on Find Herbs or Find Minerals.",
      wait = function()
          local on = tracking(true)
          if #on > 0 then return true, table.concat(on, ", ") end
          return false, "no gathering tracking on yet"
      end },
    { text = "Reading the minimap: every blip's name and colour.", auto = true, run = function()
          report()
          return (sweepAll(MEASURED, nil, true))
      end },
    { text = "Stand still, out of combat. Press Toggle: your gathering tracking goes off for a moment, then back "
          .. "on (about 4 seconds).",
      button = "Toggle", run = function()
          if not toggleTracking() then
              error("no gathering tracking on: turn Find Herbs or Find Minerals on, then Retry", 0)
          end
          return "started"
      end },
    { text = "Toggling, about 4 seconds.",
      wait = function()
          local t = state.toggle
          if not t then return false, "no toggle ran: go Back a step" end
          if not t.done then return false, "toggling" end
          return true, "vanished while off: " .. join(t.vanished), "back on: " .. str(t.back)
      end,
      check = function()
          local t = state.toggle
          if not (t and t.done) then return false, "didn't finish" end
          return #t.vanished > 0 and t.back == true,
              ("vanished while off: %s; tracking back on %s"):format(join(t.vanished), str(t.back))
      end },
    { text = "Is your gathering tracking back on? (If not, turn it on again before going on.) Did anything else "
          .. "happen: a cast, an error, a cooldown? Say what in the note.", ask = true },
    { text = "Walk among nodes for two or three minutes, the cursor off the minimap. Pass several kinds of herb "
          .. "or ore if you can, and gather one or two on the way. The panel line shows the names seen and the "
          .. "game objects in range. Press Done when you've passed a few.",
      wait = function()
          local r = state.walk
          if not r or r.done then
              r = startRadar(nil, nil, true, true)
              state.walk = r
          end
          local n = 0
          for _ in pairs(state.inRange) do n = n + 1 end
          return false, ("%d names, %d game objects in range"):format(#r.order, n)
      end },
    { text = "Stopping the radar; pairing names with object IDs.", auto = true, run = function()
          stopRadar()
          closest()
          say("AOI events: " .. aoiCounts())
          local text = pairsText()
          say("pairs: " .. text)
          return text, aoiCounts()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Boot, and the events worth a line while the procedure runs
--------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED", "MINIMAP_UPDATE_TRACKING", "MINIMAP_PING", "VIGNETTE_MINIMAP_UPDATED",
    "OBJECT_ENTERED_AOI", "OBJECT_LEFT_AOI" })
-- The player's casts only: the target's name is what a gathering cast is
-- aimed at (the name-learning fallback, #7).
local okSent, errSent = pcall(boot.RegisterUnitEvent, boot, "UNIT_SPELLCAST_SENT", "player")
if not okSent then say("UNIT_SPELLCAST_SENT: ERROR " .. str(errSent)) end
boot:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        Probe:Ready()
        if type(NodeRadarProbeDB) ~= "table" then NodeRadarProbeDB = {} end
        if type(NodeRadarProbeDB.log) ~= "table" then NodeRadarProbeDB.log = {} end
        Probe:UseLog(NodeRadarProbeDB.log, MAX_LOG)
        NodeRadarProbeDB.loads = (NodeRadarProbeDB.loads or 0) + 1
        say("loaded (" .. NodeRadarProbeDB.loads .. " loads). /fp nr for the commands, /fp steps nr ids for #7")
    elseif event == "OBJECT_ENTERED_AOI" or event == "OBJECT_LEFT_AOI" then
        aoi(event, a1)
    elseif event == "UNIT_SPELLCAST_SENT" then
        say(("UNIT_SPELLCAST_SENT spell=%s target=%s"):format(str(a4), str(a2)))
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        local on = tracking(true)
        say("MINIMAP_UPDATE_TRACKING; gathering on: " .. (#on > 0 and table.concat(on, ", ") or "none"))
    elseif event == "MINIMAP_PING" then
        -- Documented with secret payloads (MinimapDocumentation.lua:260): shown secret-safe.
        say(("MINIMAP_PING unit=%s x=%s y=%s"):format(str(a1), str(a3), str(a2)))
    elseif event == "VIGNETTE_MINIMAP_UPDATED" then
        local info = not secret(a1) and C_VignetteInfo.GetVignetteInfo(a1) or nil
        say(("VIGNETTE_MINIMAP_UPDATED onMinimap=%s %s type=%s atlas=%s"):format(str(a2),
            str(info and info.name), str(info and info.type), str(info and info.atlasName)))
    end
end)

NS._test = { Probe = Probe, state = state, CONVENTIONS = CONVENTIONS }
