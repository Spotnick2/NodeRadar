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
-- Procedures: /fp steps nr ids (round 3, #7); /fp steps nr release (NodeRadar's release check, #3);
-- /fp steps nr walk (its walk alone); /fp steps nr memory (a leak, or garbage?);
-- /fp steps nr blipsize (how wide the grid can be); /fp steps nr skill and
-- /fp steps nr cultivation (the gathering skill and Cultivation, #26); /fp steps nr
-- coords (a blip's map coordinates, #27); /fp steps nr waypoint and waypointframe (Blizzard's marker,
-- #29); /fp steps nr icons (hit areas, position arrows, item icons, #28) and iconcheck (NodeRadar's
-- icons in game, #28); /fp steps nr glass and bronze (glass discs and bronze rings around them, #41);
-- /fp steps nr styles (NodeRadar's own frames, #41); /fp steps nr compass, compass3, compasslook, compasslook2, compass4 and compass5 (#29); yellow (#50); track and track2 (#47); gather (#29); compassmove (#57); marker (#61); snooze (#46).

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

-- One of the toggle's sweeps: its names, or nil and why. A failed sweep, or
-- one where any point failed to read, must never read as "nothing there", or
-- everything would seem to vanish (Codex on #8).
local function toggleSweep(conv, t, label)
    local r, why = sweep(conv, nil, true)
    if not r then
        t.failed = t.failed or (label .. " sweep failed: " .. str(why))
        return nil
    end
    if r.errors > 0 then
        t.failed = t.failed or (("%s sweep had %d point errors in %d"):format(label, r.errors, r.points))
        return nil
    end
    return r.list
end

local function set(list)
    local s = {}
    for _, n in ipairs(list or {}) do s[n] = true end
    return s
end

-- A name is a node of this tracking only when it was there before, gone with
-- the tracking confirmed off, and back once it's on again (Codex on #8: a herb
-- someone else gathers mid-test vanishes too, but never comes back: `gone`).
local function toggleVerdict(t)
    t.vanished, t.gone = {}, {}
    if t.failed then return end
    local during, after = set(t.during), set(t.after)
    for _, n in ipairs(t.before) do
        if not during[n] then
            if after[n] then t.vanished[#t.vanished + 1] = n else t.gone[#t.gone + 1] = n end
        end
    end
    if t.offState ~= false then t.failed = "tracking never went off" end
end

--------------------------------------------------------------------------------
-- The global cooldown of the restore (the release check, #3): turning a
-- gathering tracking back on casts its spell (round 3). Does it start a global
-- cooldown? Watched three ways for 2 s, since none is measured yet: Retail's
-- GCD spell (61304), the tracking spell's own cooldown, and the action bar's
-- first 12 slots that weren't cooling down before (a cooldown of 1.6 s or less).
--------------------------------------------------------------------------------

local GCD_SPELL = 61304
local gcdFrame = CreateFrame("Frame")

local function cooldownOf(fn, arg)
    if type(fn) ~= "function" then return nil end
    local ok, info = pcall(fn, arg)
    if not ok or type(info) ~= "table" then return nil end
    return { active = info.isActive == true, onGCD = info.isOnGCD == true, duration = num(info.duration) }
end

local function slotsCooling()
    local s = {}
    for slot = 1, 12 do
        local c = cooldownOf(C_ActionBar and C_ActionBar.GetActionCooldown, slot)
        if c and c.active then s[slot] = c.duration or 0 end
    end
    return s
end

-- Starts watching just before the restore; state.gcd holds the answer.
local function watchGcd(spellID)
    local g = { samples = 0, gcdSpell = false, tracking = false, slots = {}, before = slotsCooling() }
    state.gcd = g
    local untilT = GetTime() + 2
    gcdFrame:SetScript("OnUpdate", function()
        if GetTime() >= untilT then
            gcdFrame:SetScript("OnUpdate", nil)
            local slots = {}
            for slot in pairs(g.slots) do slots[#slots + 1] = slot end
            table.sort(slots)
            g.seen = g.gcdSpell or g.tracking or #slots > 0
            g.done = true
            say(("gcd after the restore: %s (%d samples; GCD spell %s, tracking spell %s, action slots %s)"):format(
                g.seen and "SEEN" or "none seen", g.samples, str(g.gcdSpell), str(g.tracking),
                #slots > 0 and table.concat(slots, " ") or "none"))
            return
        end
        g.samples = g.samples + 1
        local c = cooldownOf(C_Spell.GetSpellCooldown, GCD_SPELL)
        if c and c.active then g.gcdSpell = true end
        c = cooldownOf(C_Spell.GetSpellCooldown, spellID)
        if c and (c.active or c.onGCD) then g.tracking = true end
        for slot, d in pairs(slotsCooling()) do
            if not g.before[slot] and d <= 1.6 then g.slots[slot] = true end
        end
    end)
end

local function toggleTracking(gcd)
    local i, info = gatherIndex()
    if not i then
        say("toggle: no gathering tracking on")
        return nil
    end
    local conv = convention(MEASURED)
    local t = { index = i, name = info.name }
    state.toggle = t
    t.before = toggleSweep(conv, t, "before") or {}
    local ok, err = pcall(C_Minimap.SetTracking, i, false)
    t.offCall = ok and "returned" or ("ERROR " .. str(err))
    say(("toggle %s: %s before; SetTracking(%d, false) %s"):format(str(t.name), join(t.before), i, t.offCall))
    C_Timer.After(1.5, function()
        t.offState = trackingOn(i)
        t.during = toggleSweep(conv, t, "middle")
        if gcd then watchGcd(num(info.spellID)) end
        local ok2, err2 = pcall(C_Minimap.SetTracking, i, true)
        t.onCall = ok2 and "returned" or ("ERROR " .. str(err2))
        say(("toggle: tracking on %s after off; %s while off; SetTracking(%d, true) %s"):format(str(t.offState),
            t.during and join(t.during) or "NO SWEEP", i, t.onCall))
        C_Timer.After(2.5, function()
            t.back = trackingOn(i)
            t.after = toggleSweep(conv, t, "after")
            toggleVerdict(t)
            t.done = true
            say(("toggle: back on %s; %s after; vanished while off and back: %s; gone and not back: %s%s"):format(
                str(t.back), t.after and join(t.after) or "NO SWEEP", join(t.vanished), join(t.gone),
                t.failed and ("; INCONCLUSIVE: " .. t.failed) or ""))
        end)
    end)
    return t
end

Probe:Command("toggle", function(args) toggleTracking(args == "gcd") end,
    "[gcd]: gathering tracking off and on, sweeping each time (gcd: watch the global cooldown)")
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
          if t.failed then return false, "inconclusive: " .. t.failed end
          return #t.vanished > 0 and t.back == true,
              ("vanished while off and back: %s; gone and not back: %s; tracking back on %s"):format(join(t.vanished),
                  join(t.gone), str(t.back))
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
-- The release check (#3, docs/PLAN.md "Release check, in game"): NodeRadar
-- itself, end to end. Reads NodeRadar's own tables (same project).
--------------------------------------------------------------------------------

local function nr()
    local n = rawget(_G, "NodeRadar")
    if type(n) == "table" and type(n.db) == "table" and n.Learn and n.Scan then return n end
end

-- NodeRadar's learning paused while the probe toggles tracking itself, and
-- put back after, or at the next login if a reload came in between.
-- The player's own setting is kept raw ({ value = nil } for "the default"), so
-- putting it back never turns a default into a saved choice.
local function setLearning(n, on)
    if NodeRadarProbeDB.restoreLearn == nil then NodeRadarProbeDB.restoreLearn = { value = rawget(n.db, "learn") } end
    n.db.learn = on
end

local function pauseLearning(n) setLearning(n, false) end

local function resumeLearning()
    local n = nr()
    local saved = NodeRadarProbeDB.restoreLearn
    if n and type(saved) == "table" then
        n.db.learn = saved.value
        NodeRadarProbeDB.restoreLearn = nil
    end
end

local function learned(n) return n.db.learned[GetLocale()] or {} end

local function snapshot(n)
    local s = {}
    for name, e in pairs(learned(n)) do s[name] = tostring(e.kind) .. "/" .. tostring(e.source) end
    return s
end

-- The names learned (or relearned) from a source since a snapshot.
local function learnedSince(n, snap, source)
    local list = {}
    for name, e in pairs(learned(n)) do
        if e.source == source and snap[name] ~= tostring(e.kind) .. "/" .. tostring(e.source) then
            list[#list + 1] = name .. " = " .. tostring(e.kind)
        end
    end
    table.sort(list)
    return list
end

local function trackingOnBySpell(n, spellID)
    for _, t in ipairs(n.Learn.Trackings()) do
        if t.spellID == spellID then return t.active end
    end
    return false
end

-- NodeRadar's alerts, counted (a secure hook: NodeRadar's code runs unchanged).
local alerts, hooked = {}, false
local function hookAlerts(n)
    if hooked then return end
    hooked = true
    hooksecurefunc(n.Alert, "Fire", function(names)
        for _, name in ipairs(names or {}) do alerts[#alerts + 1] = name end
        say("NodeRadar alert: " .. join(names))
    end)
end

local SKINS = { "GlassMiniMap", "SexyMap", "ElvUI", "Leatrix_Maps", "BasicMinimap" }

-- Steps both procedures use (each gets fresh tables).
local function readyStep()
    return { text = "Stand near herbs or ore, out of combat, with Find Herbs or Find Minerals on and NodeRadar on (/nr).",
      wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          if not n.db.enabled then return false, "NodeRadar is off: type /nr" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          state.learnStart, state.gatherStart = nil, nil      -- a fresh run's "since"
          return true, "ready"
      end }
end

local function readStep()
    return { text = "Reading NodeRadar and the client.", auto = true, run = function()
          report()
          local n = nr()
          local skins = {}
          for _, a in ipairs(SKINS) do
              local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, a)
              if ok and loaded == true then skins[#skins + 1] = a end
          end
          local nodes, others = 0, 0
          for _, e in pairs(learned(n)) do if e.kind then nodes = nodes + 1 else others = others + 1 end end
          local okC, cursorPad = pcall(IsGamePadCursorControlEnabled)
          say(("NodeRadar: learn %s, cooldown %s, interval %s; learned %d nodes and %d others; skins %s; "
              .. "Gamepad UI %s, GamePadEnable %s, gamepad cursor %s, so the radar %s")
              :format(str(n.db.learn), str(n.db.cooldown), str(n.db.interval), nodes, others, join(skins),
                  str(n.API.Gamepad()), str(GetCVarBool("GamePadEnable")), str(okC and cursorPad),
                  n.API.Gamepad() and "STOPS (Gamepad UI on)" or "runs"))
          return "skins: " .. join(skins), ("learned %d nodes, %d others"):format(nodes, others),
              "radar " .. (n.API.Gamepad() and "stopped by the Gamepad UI" or "runs")
      end }
end

-- NodeRadar learns a name by itself: learning on for the step (off by default:
-- the restore costs a global cooldown), the player's setting put back after.
local function learnStep()
    return { text = "Stand still near a herb or ore NodeRadar doesn't know yet (the line below lists the unknown "
          .. "names it sees). Learning is on for this step; it learns one by itself within about 15 seconds.",
      wait = function()
          local n = nr()
          setLearning(n, true)
          state.learnStart = state.learnStart or snapshot(n)
          local got = learnedSince(n, state.learnStart, "toggle")
          if #got > 0 then
              resumeLearning()
              return true, "learned: " .. table.concat(got, ", ")
          end
          if n.Learn.Busy() then return false, "learning..." end
          local r = n.Scan.Sweep()
          local unknown = {}
          for name in pairs(r and r.byName or {}) do
              if n.Learn.Kind(name) == nil then unknown[#unknown + 1] = name end
          end
          table.sort(unknown)
          return false, "unknown here: " .. join(unknown)
      end }
end

local function walkStep()
    return { text = "Walk past a few nodes for a minute or two, the cursor off the minimap. NodeRadar pings each new "
          .. "one; the line below counts its alerts. Press Done when you've passed a few.",
      wait = function()
          resumeLearning()                                 -- if the learning step was ended by hand
          hookAlerts(nr())
          local last = {}
          for i = math.max(1, #alerts - 4), #alerts do last[#last + 1] = alerts[i] end
          return false, ("%d alerts; last: %s"):format(#alerts, join(last))
      end }
end

local function walkAskStep()
    return { text = "Did NodeRadar ping once for each new node, without repeating for one it had already pinged?", ask = true }
end

Probe:Steps("release", {
    rev = 2,
    title = "NodeRadar's release check (#3)",
    readyStep(),
    readStep(),
    { text = "Stand still and watch your action bars. Press Toggle: your gathering tracking goes off and back on "
          .. "(about 4 seconds) while the probe watches the global cooldown.",
      button = "Toggle", run = function()
          local n = nr()
          if n.Learn.Busy() then error("NodeRadar is learning right now: wait a few seconds, then Retry", 0) end
          pauseLearning(n)
          state.gcd = nil
          if not toggleTracking(true) then
              resumeLearning()
              error("no gathering tracking on: turn it on, then Retry", 0)
          end
          return "started"
      end },
    { text = "Toggling, about 4 seconds.",
      wait = function()
          local t, g = state.toggle, state.gcd
          if not (t and t.done and g and g.done) then return false, "toggling" end
          resumeLearning()
          return true, g.seen and "global cooldown SEEN" or "no global cooldown seen", "back on: " .. str(t.back)
      end,
      check = function()
          local t, g = state.toggle, state.gcd
          local ok = t ~= nil and t.back == true and g ~= nil and g.done == true
          return ok, ok and ("measured: " .. (g.seen and "a global cooldown" or "no global cooldown"))
              or "tracking didn't come back, or nothing measured"
      end },
    { text = "When tracking came back on, did your action bars show a global-cooldown sweep?", ask = true },
    learnStep(),
    { text = "Now gather a node (any herb or ore).",
      wait = function()
          resumeLearning()                                 -- if the learning step was ended by hand
          local n = nr()
          state.gatherStart = state.gatherStart or snapshot(n)
          local got = learnedSince(n, state.gatherStart, "gather")
          if #got > 0 then return true, "learned: " .. table.concat(got, ", ") end
          return false, "waiting for a gather"
      end },
    walkStep(),
    walkAskStep(),
    { text = "Press Test: NodeRadar's own alert at the minimap's centre.", button = "Test", screenshot = "NodeRadar's ring",
      run = function()
          SlashCmdList.NODERADAR("test")
          return "/nr test"
      end },
    { text = "Did a green ring show at the minimap's centre, with the ping sound? (Name your minimap skin in the "
          .. "note, or 'stock'.)", ask = true },
    { text = "Press Off: your gathering tracking goes off as if NodeRadar were in the middle of learning. Then "
          .. "reload.",
      button = "Off", run = function()
          local n = nr()
          if n.Learn.Busy() then error("NodeRadar is learning right now: wait a few seconds, then Retry", 0) end
          local i, info = gatherIndex()
          if not i then error("no gathering tracking on: turn it on, then Retry", 0) end
          local spell = num(info.spellID)
          n.charDb.pendingRestore = spell
          NodeRadarProbeDB.reloadTest = spell
          local ok, err = pcall(C_Minimap.SetTracking, i, false)
          return ok and "off" or ("ERROR " .. str(err)), "pendingRestore " .. str(spell)
      end },
    { text = "Type /reload (or press Reload now).", reload = true },
    { text = "After the reload, NodeRadar turns your tracking back on by itself.", timeout = 20,
      wait = function()
          local n = nr()
          local spell = NodeRadarProbeDB.reloadTest
          if not (n and spell) then return false, "nothing to check: go Back two steps" end
          local on = trackingOnBySpell(n, spell)
          if on and n.charDb.pendingRestore == nil then
              NodeRadarProbeDB.reloadTest = nil
              return true, "restored, nothing pending"
          end
          return false, ("tracking on %s, pending %s"):format(str(on), str(n.charDb.pendingRestore))
      end },
    { text = "Press Mark: NodeRadar's alert cooldown becomes 7 s and the probe notes how many names it knows.",
      button = "Mark", run = function()
          local n = nr()
          local count = 0
          for _ in pairs(learned(n)) do count = count + 1 end
          NodeRadarProbeDB.persist = { cooldown = n.db.cooldown, learned = count }
          n.db.cooldown = 7
          return "learned " .. count, "cooldown 7 (was " .. str(NodeRadarProbeDB.persist.cooldown) .. ")"
      end },
    { text = "Exit the game fully (not /reload), start it again and log back in.", reload = "exit" },
    { text = "Reading NodeRadar's saved settings after the restart.", auto = true,
      run = function()
          local n = nr()
          local p = NodeRadarProbeDB.persist
          if not (n and p) then return "nothing marked" end
          local count = 0
          for _ in pairs(learned(n)) do count = count + 1 end
          state.persisted = n.db.cooldown == 7 and count >= p.learned
          local text = ("cooldown %s (7 marked), learned %d (%d marked)"):format(str(n.db.cooldown), count, p.learned)
          n.db.cooldown = p.cooldown
          NodeRadarProbeDB.persist = nil
          local fails = {}
          for key, f in pairs(n.failures) do fails[#fails + 1] = key .. ": " .. f.err end
          say("after the restart: " .. text .. "; NodeRadar failures: " .. join(fails))
          return text
      end,
      check = function()
          return state.persisted == true, state.persisted and "settings and learned names survived" or "something was lost"
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

-- The release check's walk again, alone: learning by itself and the alerts
-- never ran in its first run (the radar stopped on GamePadEnable, 70450).
Probe:Steps("walk", {
    rev = 1,
    title = "NodeRadar on a walk: learning by itself, alerts (#3)",
    readyStep(),
    readStep(),
    learnStep(),
    walkStep(),
    walkAskStep(),
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Memory: the owner saw NodeRadar at 54.7 MB (70450). A leak, or a sweep's
-- garbage (625 mouseover reads, each a new table) not yet collected?
--------------------------------------------------------------------------------

local function memKB()
    local ok = pcall(UpdateAddOnMemoryUsage)
    local okGet, kb = pcall(GetAddOnMemoryUsage, "NodeRadar")
    return ok and okGet and num(kb) or nil
end

local function collect()
    local ok, err = pcall(collectgarbage, "collect")
    if not ok then say("collectgarbage('collect'): ERROR " .. str(err)) end
    return ok
end

local function kb(v) return v and ("%.0f KB"):format(v) or "?" end

-- What one mouseover read allocates at an empty point and on the map, and one
-- of NodeRadar's sweeps, with the collector stopped when the client allows it.
local function allocations(n)
    local g = geometry()
    if not g then error("the map's geometry is unreadable", 0) end
    local stopped = pcall(collectgarbage, "stop")
    local r = { stopped = stopped }
    setSoft(true)
    local okRun, err = pcall(function()
        local fx, fy = farPixels(g)
        Minimap:UpdateMouseoverAtPoint(fx, fy)
        local data = C_TooltipInfo.GetMinimapMouseover()
        r.emptyType = secret(data) and "secret" or type(data)
        if type(data) == "table" and not secret(data) then
            local keys = {}
            for k in pairs(data) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            r.emptyKeys = table.concat(keys, ",")
            r.emptyLines = type(data.lines) == "table" and #data.lines or nil
        end
        local c0 = collectgarbage("count")
        for _ = 1, 200 do C_TooltipInfo.GetMinimapMouseover() end
        r.perEmptyRead = (collectgarbage("count") - c0) / 200
        c0 = collectgarbage("count")
        for _ = 1, 200 do Minimap:UpdateMouseoverAtPoint(fx, fy) end
        r.perMove = (collectgarbage("count") - c0) / 200
    end)
    setSoft(false)
    if okRun then
        okRun, err = pcall(function()
            local c0 = collectgarbage("count")
            for _ = 1, 5 do n.Scan.Sweep() end
            r.perSweep = (collectgarbage("count") - c0) / 5
        end)
    end
    -- Whatever happened above: a stopped collector would grow the whole UI.
    if stopped then pcall(collectgarbage, "restart") end
    if not okRun then error(str(err), 0) end
    return r
end

Probe:Steps("memory", {
    rev = 1,
    title = "NodeRadar's memory: a leak, or garbage not yet collected?",
    readyStep(),
    { text = "Reading NodeRadar's memory, then collecting the garbage once.", auto = true, run = function()
          local before = memKB()
          collect()
          local after = memKB()
          state.mem = { before = before, base = after }
          NodeRadarProbeDB.memory = { before = before, afterCollect = after }
          say(("memory: NodeRadar %s, %s after a full collection"):format(kb(before), kb(after)))
          return "NodeRadar " .. kb(before), kb(after) .. " after a collection"
      end },
    { text = "Measuring what a mouseover read and a sweep allocate (a moment).", auto = true, run = function()
          local r = allocations(nr())
          local saved = NodeRadarProbeDB.memory or {}
          for k, v in pairs(r) do saved[k] = v end
          NodeRadarProbeDB.memory = saved
          say(("memory: empty read -> %s (%s; %s lines); %.2f KB a read, %.2f KB a move, %.1f KB a sweep (collector stopped: %s)")
              :format(r.emptyType, str(r.emptyKeys), str(r.emptyLines), r.perEmptyRead, r.perMove, r.perSweep or -1, str(r.stopped)))
          return ("%.1f KB a sweep"):format(r.perSweep or -1), ("%.2f KB an empty read"):format(r.perEmptyRead)
      end },
    { text = "Play as usual for a minute: ride or walk near nodes, or stand. The probe samples NodeRadar's memory "
          .. "every 5 s, then collects once more.",
      wait = function()
          local s = state.mem
          if not s then return false, "go Back two steps" end
          local now = GetTime()
          s.start = s.start or now
          s.samples = s.samples or {}
          if not s.last or now - s.last >= 5 then
              s.last = now
              s.samples[#s.samples + 1] = memKB()
          end
          local peak = 0
          for _, v in ipairs(s.samples) do peak = math.max(peak, v or 0) end
          if now - s.start < 60 then
              return false, ("%d s: NodeRadar %s (peak %s)"):format(now - s.start, kb(s.samples[#s.samples]), kb(peak))
          end
          collect()
          s.retained = memKB()
          local saved = NodeRadarProbeDB.memory or {}
          saved.samples, saved.peak, saved.retained = s.samples, peak, s.retained
          NodeRadarProbeDB.memory = saved
          say(("memory: a minute's peak %s; %s after a collection (%s at the start)"):format(kb(peak), kb(s.retained), kb(s.base)))
          return true, "peak " .. kb(peak), kb(s.retained) .. " after a collection (" .. kb(s.base) .. " at the start)"
      end,
      check = function()
          local s = state.mem
          local grew = s and s.retained and s.base and s.retained - s.base
          return grew ~= nil and grew < 256, grew and ("kept %s more after a minute"):format(kb(grew)) or "not measured"
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Blip size: memory run 1 (70450) found 2.8 MB of garbage a sweep, 2.5 KB a
-- read, empty or not. Fewer reads need a wider grid: how wide can it be and
-- still read every node blip? Each node blip NodeRadar sees is sampled every
-- map unit around it; a grid of step S misses none when the blip's hit points
-- cover every remainder (x mod S, y mod S).
--------------------------------------------------------------------------------

local SIZE_HALF, SIZE_STEPS = 24, { 8, 10, 12, 14, 16, 18, 20, 24 }

local function blipMask(n, name, b, g)
    local cells, count = {}, 0
    local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
    for dy = -SIZE_HALF, SIZE_HALF do
        for dx = -SIZE_HALF, SIZE_HALF do
            local ox, oy = g.w / 2 + b.x + dx, g.h / 2 + b.y + dy
            if ox >= 0 and ox <= g.w and oy >= 0 and oy <= g.h then
                Minimap:UpdateMouseoverAtPoint((g.l + ox) * g.es, (g.b + oy) * g.es)
                local names = mouseover()
                for _, row in ipairs(names or {}) do
                    if n.Scan.Plain(row) == name then
                        cells[#cells + 1] = { dx, dy }
                        count = count + 1
                        minx, maxx = math.min(minx, dx), math.max(maxx, dx)
                        miny, maxy = math.min(miny, dy), math.max(maxy, dy)
                        break
                    end
                end
            end
        end
    end
    -- The widest step whose every offset lands a sample on the blip.
    local safe
    for _, s in ipairs(SIZE_STEPS) do
        local seen, left = {}, s * s
        for _, c in ipairs(cells) do
            local k = (c[1] % s) .. ":" .. (c[2] % s)
            if not seen[k] then seen[k] = true; left = left - 1 end
        end
        if left == 0 then safe = s end
    end
    return { name = name, points = count, w = count > 0 and maxx - minx + 1 or 0,
             h = count > 0 and maxy - miny + 1 or 0, safe = safe }
end

local function measureBlips()
    local n = nr()
    local r = n.Scan.Sweep()
    if not r then error("NodeRadar's sweep failed", 0) end
    local g = geometry()
    if not g then error("the map's geometry is unreadable", 0) end
    local okZoom, zoom = pcall(Minimap.GetZoom, Minimap)
    local out = { zoom = okZoom and num(zoom) or nil, w = g.w, h = g.h, es = g.es, blips = {} }
    -- Known nodes first, then names NodeRadar hasn't learned yet (a herb it
    -- hasn't met); never a name it knows isn't a node.
    local picked, seen = {}, {}
    for _, b in ipairs(r.blips) do
        local kind = n.Learn.Kind(b.name)
        seen[#seen + 1] = b.name .. " (" .. (kind == nil and "unknown" or tostring(kind)) .. ")"
        if kind then table.insert(picked, 1, b) elseif kind == nil then picked[#picked + 1] = b end
    end
    setSoft(true)
    local ok, err = pcall(function()
        for i = 1, math.min(4, #picked) do
            local b = picked[i]
            local m = blipMask(n, b.name, b, g)
            m.kind = n.Learn.Kind(b.name) or "unknown"
            out.blips[#out.blips + 1] = m
        end
    end)
    pcall(Minimap.UpdateMouseoverAtPoint, Minimap, farPixels(g))
    setSoft(false)
    if not ok then error(str(err), 0) end
    if #out.blips == 0 then
        error("no node on the minimap (saw: " .. join(seen) .. "): stand where one shows, then Retry", 0)
    end
    local parts, safest = {}, math.huge
    for _, b in ipairs(out.blips) do
        parts[#parts + 1] = ("%s [%s] %dx%d (%d points) safe %s"):format(b.name, b.kind, b.w, b.h, b.points, str(b.safe))
        safest = math.min(safest, b.safe or 0)
    end
    out.safe = safest
    local saved = NodeRadarProbeDB.blipSize or {}
    saved[#saved + 1] = out
    NodeRadarProbeDB.blipSize = saved
    local text = ("zoom %s, map %.0fx%.0f: %s"):format(str(out.zoom), g.w, g.h, table.concat(parts, "; "))
    say("blip size: " .. text)
    return "a step of " .. safest .. " misses none", text
end

Probe:Steps("blipsize", {
    rev = 1,
    title = "How big a node's blip is: how wide the grid can be",
    { text = "Stand where a herb or ore shows on the minimap, with NodeRadar on.",
      wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          NodeRadarProbeDB.blipSize = nil
          return true, "ready"
      end },
    { text = "Measuring the node blips (a moment).", auto = true, run = function()
          local done, text = measureBlips()
          state.sizeZoom = NodeRadarProbeDB.blipSize[1].zoom
          return done, text
      end },
    { text = "Zoom the minimap in or out (its + and − buttons or the mouse wheel), keeping a node in view.",
      wait = function()
          local ok, zoom = pcall(Minimap.GetZoom, Minimap)
          zoom = ok and num(zoom) or nil
          if zoom == nil or zoom == state.sizeZoom then return false, "zoom " .. str(zoom) end
          return true, "zoom " .. str(zoom)
      end },
    { text = "Measuring again at this zoom.", auto = true, run = measureBlips },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- The player's gathering skill and the nodes above it (#26). What
-- C_SkillInfo.GetSkillLineInfoByID returns for Herbalism and Mining; a node's
-- world tooltip (C_TooltipInfo.GetWorldCursor), in case it names its
-- requirement; what the client says when a gather is refused (UI_ERROR_MESSAGE,
-- logged by the boot frame); a skill-up. And Forever's Tauren racial,
-- Cultivation: which of Wowhead's two IDs the spellbook carries, and whether
-- its 15-minute cooldown reads plainly, out of combat and in it.
--------------------------------------------------------------------------------

local SKILL_LINES = { { 182, "Herbalism" }, { 186, "Mining" } }
local CULTIVATION = { 20552, 1312643 }    -- Wowhead (Forever): the instant one, the 3 s cast with a 15 min cooldown

-- A skill line's numbers, nil when unreadable; logged in full unless quiet.
local function skillLine(id, label, quiet)
    local fn = C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID
    if type(fn) ~= "function" then
        if not quiet then say("C_SkillInfo.GetSkillLineInfoByID: MISSING") end
        return nil
    end
    local ok, info = pcall(fn, id)
    if not ok then
        if not quiet then say(("skill %d (%s): ERROR %s"):format(id, label, str(info))) end
        return nil
    end
    if not quiet then
        say(("skill %d (%s): %s"):format(id, label, type(info) == "table" and Probe.Describe(info) or str(info)))
    end
    if info == nil then return nil end                 -- not this character's profession
    if secret(info) or type(info) ~= "table" then return { shape = Probe.Shape(info) } end
    return { rank = num(info.rank), modifier = num(info.modifier), maxRank = num(info.maxRank),
             secret = secret(info.rank) or secret(info.modifier) or nil }
end

local function skills(quiet)
    local out = {}
    for _, s in ipairs(SKILL_LINES) do out[s[2]] = skillLine(s[1], s[2], quiet) or false end
    return out
end

local function skillText(all)
    local parts = {}
    for _, s in ipairs(SKILL_LINES) do
        local e = all[s[2]]
        parts[#parts + 1] = s[2] .. " " .. (e and (str(e.rank) .. "+" .. str(e.modifier) .. "/" .. str(e.maxRank)
            .. (e.secret and " (secret)" or "")) or "none")
    end
    return table.concat(parts, ", ")
end

-- Cultivation's two IDs: known, and the cooldown as the client gives it;
-- logged unless quiet.
local function cultivation(quiet)
    local out = {}
    for _, id in ipairs(CULTIVATION) do
        local okK, known = pcall(function() return C_SpellBook.IsSpellKnown(id) end)
        local okC, cd = pcall(function() return C_Spell.GetSpellCooldown(id) end)
        local e = { known = okK and str(known) or "ERROR " .. str(known) }
        if okC and type(cd) == "table" and not secret(cd) then
            e.cooldown = Probe.Describe(cd)
            e.secret = secret(cd.startTime) or secret(cd.duration) or secret(cd.isActive) or nil
            e.cooling = yes(cd.isActive) or (num(cd.duration) or 0) > 1.5
        else
            e.cooldown = okC and str(cd) or "ERROR " .. str(cd)
        end
        if not quiet then say(("Cultivation %d: known %s, cooldown %s"):format(id, e.known, e.cooldown)) end
        out[id] = e
    end
    return out
end

local function race()
    local ok, name, file, id = Probe:Try("UnitRace", UnitRace, "player")
    say(("race %s (%s, %s)"):format(str(file), str(name), str(id)))
    return ok and not secret(file) and file or nil
end

-- The world tooltip under the cursor: its lines as "text [rrggbb]", or nil and why.
local function worldTooltip()
    local fn = C_TooltipInfo and C_TooltipInfo.GetWorldCursor
    if type(fn) ~= "function" then return nil, "MISSING" end
    local ok, data = pcall(fn)
    if not ok then return nil, "ERROR " .. str(data) end
    if secret(data) or type(data) ~= "table" or secret(data.lines) or type(data.lines) ~= "table" then
        return nil, Probe.Shape(data)
    end
    local lines, first = {}, nil
    for _, line in ipairs(data.lines) do
        local t = type(line) == "table" and line.leftText or nil
        if secret(t) then
            lines[#lines + 1] = "<secret>"
        elseif type(t) == "string" and t ~= "" then
            first = first or Probe.Plain(t)
            lines[#lines + 1] = Probe.Plain(t) .. " [" .. colour(line.leftColor) .. "]"
        end
    end
    if #lines == 0 then return nil, "no text" end
    return lines, nil, first
end

-- A wait: done when the cursor is on a node NodeRadar knows (its tooltip saved).
local function hoverNode(label)
    return function()
        local n = nr()
        if not n then return false, "NodeRadar isn't loaded" end
        local lines, why, first = worldTooltip()
        if not lines then return false, "nothing under the cursor (" .. str(why) .. ")" end
        if not n.Learn.Kind(first) then return false, "not a node: " .. table.concat(lines, " | ") end
        local text = table.concat(lines, " | ")
        say("world tooltip, " .. label .. ": " .. text)
        local saved = NodeRadarProbeDB.skillTooltips or {}
        saved[#saved + 1] = { label = label, lines = lines }
        NodeRadarProbeDB.skillTooltips = saved
        return true, text
    end
end

Probe:Steps("skill", {
    rev = 1,
    title = "Gathering skill and the nodes above it (#26)",
    { text = "On your gatherer, reading the skills, the race and Cultivation.", auto = true, run = function()
          NodeRadarProbeDB.skillTooltips = nil
          local all = skills()
          state.skillStart = all
          race()
          cultivation()
          return skillText(all)
      end },
    { text = "Find a herb or ore ABOVE your skill and put the mouse on it (in the world, not the minimap) until "
          .. "this step completes. Type the requirement in the Note box if the tooltip shows one.",
      wait = hoverNode("above"), screenshot = "node above the skill" },
    { text = "Try to gather it (right-click). The client's answer is logged.", event = "UI_ERROR_MESSAGE" },
    { text = "Did it gather anyway?", ask = true },
    { text = "Now put the mouse on a node you CAN gather, until this step completes.",
      wait = hoverNode("gatherable"), screenshot = "node within the skill" },
    { text = "Gather nodes until your skill goes up (Skip if none comes).", wait = function()
          local now, start = skills(true), state.skillStart or {}
          for _, s in ipairs(SKILL_LINES) do
              local a, b = start[s[2]], now[s[2]]
              if a and b and a.rank and b.rank and b.rank ~= a.rank then
                  skills()
                  return true, skillText(now)
              end
          end
          return false, skillText(now)
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

Probe:Steps("cultivation", {
    rev = 1,
    title = "Cultivation, the Tauren racial (#26)",
    { text = "On a Tauren (Herbalism not needed): reading Cultivation.", auto = true, run = function()
          return race(), cultivation()
      end },
    { text = "Stand by a herb and cast Cultivation on it.", wait = function()
          local all = cultivation(true)
          for _, id in ipairs(CULTIVATION) do
              local e = all[id]
              if e.secret or e.cooling then
                  cultivation()
                  return true, id .. (e.secret and " cooldown secret" or " cooling: " .. e.cooldown)
              end
          end
          return false, "not cooling yet"
      end },
    { text = "While it cools down, get into combat (attack something).", wait = function()
          if not yes(InCombatLockdown()) then return false, "not in combat" end
          local all = cultivation()
          local parts = {}
          for _, id in ipairs(CULTIVATION) do parts[#parts + 1] = id .. ": " .. all[id].cooldown end
          return true, table.concat(parts, "; ")
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- A blip's map coordinates (#27). The conversion #27 plans, which is
-- HereBeDragons-Pins' minimap drawing inverted (HereBeDragons-Pins-2.0.lua:
-- the map's edge is C_Minimap.GetViewRadius() yards, up is north, a rotating
-- map turns by GetPlayerFacing()): the blip's offset in the map's units x
-- radius / half-width = yards; the zone map's y grows southward. Checked
-- against where the player stands when gathering that node (within reach).
--------------------------------------------------------------------------------

local function cvar(name)
    local ok, v = pcall(C_CVar.GetCVar, name)
    return ok and not secret(v) and v or nil
end

-- The player's zone-map position and the map's size in yards; nil and why.
local function playerPos()
    local okM, map = pcall(C_Map.GetBestMapForUnit, "player")
    map = okM and num(map)
    if not map then return nil, "no map" end
    local okP, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if not okP or pos == nil or secret(pos) then return nil, "no position on map " .. map end
    local okXY, x, y = pcall(pos.GetXY, pos)
    x, y = okXY and num(x), okXY and num(y)
    if not (x and y) then return nil, "position unreadable on map " .. map end
    local okS, w, h = pcall(C_Map.GetMapWorldSize, map)
    w, h = okS and num(w), okS and num(h)
    if not (w and h) or w <= 0 or h <= 0 then return nil, "no world size for map " .. map end
    return { map = map, x = x, y = y, w = w, h = h }
end

-- Everything the conversion reads, at one moment; nil and why.
local function snapshot()
    local g, why = geometry()
    if not g then return nil, why end
    local p, whyP = playerPos()
    if not p then return nil, whyP end
    local okR, radius = pcall(C_Minimap.GetViewRadius)
    local okZ, zoom = pcall(Minimap.GetZoom, Minimap)
    local okI, ignored = pcall(C_Minimap.IsRotateMinimapIgnored)
    local okIn, indoors = pcall(IsIndoors)
    local s = { radius = okR and num(radius), zoom = okZ and num(zoom), halfW = g.w / 2, halfH = g.h / 2,
                rotate = cvar("rotateMinimap") == "1", ignored = okI and yes(ignored),
                indoors = okIn and yes(indoors), facing = num(GetPlayerFacing()), pos = p }
    s.rotating = s.rotate and not s.ignored
    if not s.radius then return nil, "no view radius" end
    if s.rotating and not s.facing then return nil, "rotating, but no facing" end
    return s
end

local function snapText(s)
    return ("zoom %s, radius %.1f yd over %.1f units (%.3f yd/unit), %s, rotate %s%s, map %d at (%.4f, %.4f), "
        .. "%.0f x %.0f yd"):format(str(s.zoom), s.radius, s.halfW, s.radius / s.halfW,
        s.indoors and "indoors" or "outdoors", tostring(s.rotate), s.ignored and " (ignored)" or "",
        s.pos.map, s.pos.x, s.pos.y, s.pos.w, s.pos.h)
end

-- A blip's map coordinates and distance, from a snapshot: (x, y) are its
-- offset from the map's centre in the map's own units, y up.
local function predict(s, bx, by)
    local k = s.radius / s.halfW
    local right, down = bx * k, -by * k              -- yards on the screen
    local east, south = right, down
    if s.rotating then                               -- undo HereBeDragons' turn by the facing
        local c, sn = math.cos(s.facing), math.sin(s.facing)
        east, south = right * c + down * sn, -right * sn + down * c
    end
    return s.pos.x + east / s.pos.w, s.pos.y + south / s.pos.h, math.sqrt(east * east + south * south)
end

-- The node blips now, each with its predicted coordinates; saved for the gather.
local function predictNodes(label)
    local n = nr()
    if not n then error("NodeRadar isn't loaded", 0) end
    local s, why = snapshot()
    if not s then error(why, 0) end
    local r = n.Scan.Sweep(function(name) return n.Learn.Kind(name) end)
    if not r then error("NodeRadar's sweep failed", 0) end
    local out, parts = { label = label, snap = snapText(s), nodes = {}, at = GetTime() }, {}
    for _, b in ipairs(r.blips) do
        if n.Learn.Kind(b.name) then
            local x, y, d = predict(s, b.x, b.y)
            out.nodes[#out.nodes + 1] = { name = b.name, x = x, y = y, yards = d }
            parts[#parts + 1] = ("%s (%.1f, %.1f) %.0f yd"):format(b.name, x * 100, y * 100, d)
        end
    end
    if #out.nodes == 0 then error("no node on the minimap: stand where one shows, then Retry", 0) end
    state.coordsPredicted = out
    local saved = NodeRadarProbeDB.coords or {}
    saved[#saved + 1] = out
    NodeRadarProbeDB.coords = saved
    say(("coords %s: %s; %s"):format(label, out.snap, table.concat(parts, ", ")))
    return table.concat(parts, ", ")
end

-- A wait: done when the player gathers a node predicted by the last step;
-- the error is from the prediction to where the player stood.
local function gatheredNear()
    local g, p = state.lastGather, state.coordsPredicted
    if not p then return false, "no prediction yet: go Back and Predict" end
    if not (g and g.at >= p.at) then return false, "gather one of the " .. #p.nodes .. " predicted" end
    if not g.pos then return true, "gathered " .. str(g.name) .. ", position unreadable" end
    local best
    for _, nd in ipairs(p.nodes) do
        if nd.name == g.name then
            local d = math.sqrt(((nd.x - g.pos.x) * g.pos.w) ^ 2 + ((nd.y - g.pos.y) * g.pos.h) ^ 2)
            if not best or d < best.d then best = { d = d, nd = nd } end
        end
    end
    if not best then return true, str(g.name) .. " gathered: none of that name was predicted" end
    local text = ("%s (%s): predicted (%.2f, %.2f), stood at (%.2f, %.2f), %.1f yd apart (seen %.0f yd away)")
        :format(g.name, p.label, best.nd.x * 100, best.nd.y * 100, g.pos.x * 100, g.pos.y * 100, best.d,
            best.nd.yards)
    say("coords " .. text)
    local saved = NodeRadarProbeDB.coordsChecked or {}
    saved[#saved + 1] = text
    NodeRadarProbeDB.coordsChecked = saved
    state.coordsPredicted = nil
    return true, text
end

-- A wait: the view radius at every zoom, recorded as the owner zooms.
local function everyZoom()
    local radii = NodeRadarProbeDB.coordsRadii or {}
    NodeRadarProbeDB.coordsRadii = radii
    local s, why = snapshot()
    if not s then return false, str(why) end
    local where = s.indoors and "indoor" or "outdoor"
    radii[where] = radii[where] or {}
    if s.zoom and radii[where][s.zoom] == nil then
        radii[where][s.zoom] = s.radius
        say("coords radius: " .. snapText(s))
    end
    local missing = {}
    for z = 0, 5 do if not (radii.outdoor and radii.outdoor[z]) then missing[#missing + 1] = z end end
    if #missing > 0 then return false, "outdoors, zooms still to see: " .. table.concat(missing, " ") end
    local parts = {}
    for z = 0, 5 do parts[#parts + 1] = ("%d=%.1f"):format(z, radii.outdoor[z]) end
    return true, "outdoor radii " .. table.concat(parts, " ")
end

local function rotateIs(on)
    return function()
        local v = cvar("rotateMinimap")
        if (v == "1") == on then return true, "rotateMinimap " .. str(v) end
        return false, "rotateMinimap " .. str(v)
    end
end

Probe:Steps("coords", {
    rev = 1,
    title = "A blip's map coordinates (#27)",
    { text = "Outdoors, with Find Herbs or Find Minerals on: reading the minimap and your position.", auto = true,
      run = function()
          NodeRadarProbeDB.coordsRadii, state.coordsPredicted = nil, nil
          local s, why = snapshot()
          if not s then error(why, 0) end
          say("coords now: " .. snapText(s))
          return snapText(s)
      end },
    { text = "Zoom the minimap through all six levels, all the way in and all the way out (+ and -).",
      wait = everyZoom },
    { text = "Zoom back out, and stand still where a herb or ore shows 40-80 yards away, Rotate Minimap off. "
          .. "Then Run.", button = "Predict", run = function() return predictNodes("north-up") end },
    { text = "Walk to one of those nodes and gather it.", wait = gatheredNear },
    { text = "Turn on Rotate Minimap (Esc > Options, Interface).", wait = rotateIs(true) },
    { text = "Turn to face any direction but north, stand still with another node 40-80 yards away, then Run.",
      button = "Predict", run = function() return predictNodes("rotating") end },
    { text = "Walk to one of those nodes and gather it.", wait = gatheredNear },
    { text = "Turn Rotate Minimap back off (unless you use it).", wait = rotateIs(false) },
    { text = "Optional: go inside a building or cave where the minimap zooms in, then Run (or Skip).",
      button = "Read", run = function()
          local s, why = snapshot()
          if not s then error(why, 0) end
          say("coords inside: " .. snapText(s))
          return snapText(s)
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Blizzard's waypoint marker on a node (#29). Does Forever draw the user
-- waypoint's on-screen navigation marker (Blizzard_QuestNavigation's
-- SuperTrackedFrame, on C_Navigation's frame) when an addon sets one; at what
-- distance, clamped at the screen's edge; what arrival does; the events'
-- order when we set, when the player sets their own, when we clear; whether
-- it survives a reload. The node's point is NodeRadar's own
-- Scan.MapPosition (#27). Every event of it is logged by the boot frame,
-- marked "(ours)" while one of our setters runs.
--------------------------------------------------------------------------------

local function wpRead(f, ...)
    if type(f) ~= "function" then return "MISSING" end
    local ok, a = pcall(f, ...)
    if not ok then return "ERROR " .. str(a) end
    return a
end

-- The waypoint, the super-track and the navigation frame, as one line.
local function navState()
    local pt = wpRead(C_Map.GetUserWaypoint)
    local where = "none"
    if type(pt) == "table" and not secret(pt) then
        local p = pt.position
        local x, y = p and num(p.x), p and num(p.y)
        where = ("map %s (%s, %s)"):format(str(pt.uiMapID), x and ("%.2f"):format(x * 100) or "?",
            y and ("%.2f"):format(y * 100) or "?")
    elseif pt ~= nil then
        where = str(pt)
    end
    local frame = wpRead(C_Navigation.GetFrame)
    -- Both returns kept: `stf and pcall(...)` would keep only the first (Codex on #39).
    local stf, shown = rawget(_G, "SuperTrackedFrame"), "absent"
    if stf then
        local ok, v = pcall(stf.IsShown, stf)
        shown = ok and (yes(v) and "shown" or "hidden") or "unreadable"
    end
    local loaded = wpRead(C_AddOns.IsAddOnLoaded, "Blizzard_QuestNavigation")
    return ("waypoint %s at %s; super-tracking anything %s, the waypoint %s, quest %s; nav frame %s, valid %s, "
        .. "distance %s, clamped %s, state %s; SuperTrackedFrame %s; Blizzard_QuestNavigation loaded %s")
        :format(str(wpRead(C_Map.HasUserWaypoint)), where, str(wpRead(C_SuperTrack.IsSuperTrackingAnything)),
            str(wpRead(C_SuperTrack.IsSuperTrackingUserWaypoint)), str(wpRead(C_SuperTrack.GetSuperTrackedQuestID)),
            frame == nil and "none" or type(frame) == "string" and frame or "present",
            str(wpRead(C_Navigation.HasValidScreenPosition)), str(wpRead(C_Navigation.GetDistance)),
            str(wpRead(C_Navigation.WasClampedToScreen)), str(wpRead(C_Navigation.GetTargetState)),
            shown, str(loaded))
end

local function wpSay(label)
    local s = navState()
    say("waypoint " .. label .. ": " .. s)
    return s
end

-- The nearest node blip's map point, from NodeRadar's own conversion.
local function nearestNode()
    local n = nr()
    if not n then error("NodeRadar isn't loaded", 0) end
    local r = n.Scan.Sweep(function(name) return n.Learn.Kind(name) end)
    if not r then error("NodeRadar's sweep failed", 0) end
    local best
    for _, b in ipairs(r.blips) do
        if n.Learn.Kind(b.name) then
            local map, x, y = n.Scan.MapPosition(r, b)
            local d = b.x * b.x + b.y * b.y
            if map and (not best or d < best.d) then best = { d = d, name = b.name, map = map, x = x, y = y } end
        end
    end
    if not best then error("no node with coordinates on the minimap (outdoors, north-up): stand where one shows", 0) end
    return best
end

-- Sets our waypoint on a point and super-tracks it, logging each answer;
-- state.wpOurs marks our events. Returns the line.
local function setOurs(p)
    local canSet = wpRead(C_Map.CanSetUserWaypointOnMap, p.map)
    state.wpOurs = true
    local okPt, point = pcall(UiMapPoint.CreateFromCoordinates, p.map, p.x, p.y)
    local wasSet = okPt and wpRead(C_Map.SetUserWaypoint, point) or ("ERROR " .. str(point))
    local before = navState()
    local okT, errT = pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    state.wpOurs = false
    state.wpTarget = p
    local line = ("set %s (%.2f, %.2f) on map %d: CanSetUserWaypointOnMap %s, SetUserWaypoint -> %s, then "
        .. "super-track %s"):format(p.name, p.x * 100, p.y * 100, p.map, str(canSet), str(wasSet),
        okT and "ok" or ("ERROR " .. str(errT)))
    say("waypoint " .. line)
    say("waypoint between the two setters: " .. before)
    return line .. "; " .. wpSay("after")
end

local function clearOurs(order)
    state.wpOurs = true
    if order == "tracking first" then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false)
        wpSay("tracking off, waypoint still set")
        pcall(C_Map.ClearUserWaypoint)
    else
        pcall(C_Map.ClearUserWaypoint)
        wpSay("waypoint cleared, tracking left alone")
    end
    state.wpOurs = false
    return wpSay("cleared, " .. order)
end

local function waypointFree()
    local has, any = wpRead(C_Map.HasUserWaypoint), wpRead(C_SuperTrack.IsSuperTrackingAnything)
    if has == false and any == false then return true, "no waypoint, nothing super-tracked" end
    return false, "waypoint " .. str(has) .. ", super-tracking " .. str(any)
end

Probe:Steps("waypoint", {
    rev = 1,
    title = "Blizzard's waypoint marker on a node (#29)",
    { text = "Remove any map waypoint you have and stop tracking quests on screen (super-track), so the "
          .. "waypoint is free.", wait = waypointFree },
    { text = "Stand still outdoors with a herb or ore 40-80 yards away on the minimap, then press Set.",
      button = "Set", run = function() return setOurs(nearestNode()) end },
    { text = "Reading the marker (a moment).", wait = function()
          local frame = wpRead(C_Navigation.GetFrame)
          if frame ~= nil and type(frame) ~= "string" then return true, wpSay("marker") end
          return false, "no navigation frame yet"
      end, timeout = 8 },
    { text = "Do you see Blizzard's waypoint marker over the node, with a distance?", ask = true,
      screenshot = "the marker on the node" },
    { text = "Turn until the node is behind you.", wait = function()
          if wpRead(C_Navigation.WasClampedToScreen) == true then return true, wpSay("clamped") end
          return false, "not clamped yet"
      end, screenshot = "the marker at the edge" },
    { text = "Is the marker held at the screen's edge, pointing toward the node?", ask = true },
    { text = "Walk to the node (don't gather it yet) until the marker reacts, or press Done when you stand on it.",
      wait = function()
          local t = state.wpEvents or {}
          if t.reached or wpRead(C_SuperTrack.IsSuperTrackingUserWaypoint) == false
              or wpRead(C_Map.HasUserWaypoint) == false then
              return true, wpSay("arrived")
          end
          return false, "distance " .. str(wpRead(C_Navigation.GetDistance))
      end },
    { text = "What happened on arrival? (Type it in the Note box: message, marker gone, pin gone.)", ask = true },
    { text = "Setting ours again on the same point.", auto = true, run = function()
          local p = state.wpTarget
          if not p then error("no point: go back to Set", 0) end
          clearOurs("waypoint first")
          return setOurs(p)
      end },
    { text = "Now put your own waypoint on the world map (Ctrl-click a spot), over ours.", wait = function()
          local pt = wpRead(C_Map.GetUserWaypoint)
          local p = state.wpTarget
          local x = type(pt) == "table" and pt.position and num(pt.position.x)
          if p and x and math.abs(x - p.x) > 0.001 then return true, wpSay("the player's own") end
          return false, "still ours"
      end },
    { text = "Remove your waypoint (on the world map), and untrack anything.", wait = waypointFree },
    { text = "Clearing order: setting ours, then clearing the waypoint first.", auto = true, run = function()
          setOurs(state.wpTarget)
          return clearOurs("waypoint first")
      end },
    { text = "Clearing order: setting ours, then turning the tracking off first.", auto = true, run = function()
          setOurs(state.wpTarget)
          return clearOurs("tracking first")
      end },
    { text = "Setting ours once more, to see whether it survives a reload.", auto = true,
      run = function() return setOurs(state.wpTarget) end },
    { text = "Type /reload (or press Reload now).", reload = true },
    { text = "After the reload: is our waypoint still there?", auto = true, run = function()
          return wpSay("after the reload")
      end },
    -- Tracking first: the waypoint first leaves the super-track on (measured
    -- above). Same text and rev, so the run left at step 16 resumes with this.
    { text = "Clearing it.", auto = true, run = function() return clearOurs("tracking first") end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

-- SuperTrackedFrame's visibility, read again: the first run's read always
-- said hidden (Codex on #39).
Probe:Steps("waypointframe", {
    rev = 1,
    title = "SuperTrackedFrame read again (#29)",
    { text = "Remove any map waypoint you have and stop tracking quests on screen (super-track), so the "
          .. "waypoint is free.", wait = waypointFree },
    { text = "Stand outdoors facing a herb or ore 40-80 yards away on the minimap, then press Set.",
      button = "Set", run = function()
          state.wpSetAt = GetTime()
          return setOurs(nearestNode())
      end },
    { text = "Reading the marker frame (a few seconds).", wait = function()
          local frame = wpRead(C_Navigation.GetFrame)
          if frame ~= nil and type(frame) ~= "string" and GetTime() - (state.wpSetAt or 0) >= 3 then
              return true, wpSay("frame")
          end
          return false, "waiting for the navigation frame"
      end, timeout = 10, screenshot = "facing the node" },
    { text = "Clearing ours, the tracking first.", auto = true, run = function() return clearOurs("tracking first") end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Item icons on the minimap's nodes (#28), its first round. A node blip's
-- exact hit area: every map unit over ±30 around it, a square or a disc, its
-- size and centre; the drawn dot against it (our marks at the measured centre
-- and box, and a screenshot); the raw text of a node above and below the player
-- (the Minimap-PositionArrows texture Scan.Plain strips); what C_Item answers
-- for every NODE_INFO item, cached or not. Saved in NodeRadarProbeDB.icons.
--------------------------------------------------------------------------------

local MASK_HALF = 30
local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- The raw left texts at a point (map units from the map's centre). The soft
-- cursor must be on.
local function rawAt(g, x, y)
    Minimap:UpdateMouseoverAtPoint((g.cx + x) * g.es, (g.cy + y) * g.es)
    local ok, data = pcall(C_TooltipInfo.GetMinimapMouseover)
    local out = {}
    if not ok or secret(data) or type(data) ~= "table" or secret(data.lines) or type(data.lines) ~= "table" then
        return out
    end
    for _, line in ipairs(data.lines) do
        local t = type(line) == "table" and line.leftText or nil
        if type(t) == "string" and not secret(t) then out[#out + 1] = t end
    end
    return out
end

-- One blip's hit area: the 4-connected group of hit cells nearest its grid
-- centre (another node of the name nearby is a second group), its box, how
-- full the box is (a square fills it, a disc about 70-79%), its corners, its
-- centre; the rows as text, top first ('#' this group, 'o' another).
local function hitArea(n, name, b, g)
    local hit = {}
    for dy = -MASK_HALF, MASK_HALF do
        for dx = -MASK_HALF, MASK_HALF do
            local x, y = b.x + dx, b.y + dy
            if math.abs(x) <= g.w / 2 and math.abs(y) <= g.h / 2 then
                Minimap:UpdateMouseoverAtPoint((g.cx + x) * g.es, (g.cy + y) * g.es)
                for _, row in ipairs(mouseover() or {}) do
                    if n.Scan.Plain(row) == name then hit[dx .. ":" .. dy] = { dx, dy }; break end
                end
            end
        end
    end
    local seen, best, bestD, groups = {}, nil, math.huge, 0
    for key, c in pairs(hit) do
        if not seen[key] then
            groups = groups + 1
            local group, stack, d = {}, { c }, math.huge
            seen[key] = true
            while #stack > 0 do
                local p = table.remove(stack)
                group[#group + 1] = p
                d = math.min(d, p[1] * p[1] + p[2] * p[2])
                for _, o in ipairs(NEIGHBOURS) do
                    local k = (p[1] + o[1]) .. ":" .. (p[2] + o[2])
                    if hit[k] and not seen[k] then seen[k] = true; stack[#stack + 1] = hit[k] end
                end
            end
            if d < bestD then best, bestD = group, d end
        end
    end
    if not best then return { name = name, points = 0, groups = 0 } end
    local mine = {}
    local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(best) do
        mine[p[1] .. ":" .. p[2]] = true
        minx, maxx = math.min(minx, p[1]), math.max(maxx, p[1])
        miny, maxy = math.min(miny, p[2]), math.max(maxy, p[2])
    end
    local w, h = maxx - minx + 1, maxy - miny + 1
    local corners = 0
    for _, k in ipairs({ minx .. ":" .. miny, minx .. ":" .. maxy, maxx .. ":" .. miny, maxx .. ":" .. maxy }) do
        if mine[k] then corners = corners + 1 end
    end
    local fill = #best / (w * h)
    local rows = {}
    for y = maxy, miny, -1 do
        local row = {}
        for x = minx, maxx do
            local k = x .. ":" .. y
            row[#row + 1] = mine[k] and "#" or hit[k] and "o" or "."
        end
        rows[#rows + 1] = table.concat(row)
    end
    local x, y = b.x + (minx + maxx) / 2, b.y + (miny + maxy) / 2
    return {
        name = name, points = #best, w = w, h = h, fill = fill, corners = corners, groups = groups,
        shape = corners == 4 and fill >= 0.95 and "square" or corners == 0 and fill < 0.9 and "disc" or "other",
        x = x, y = y, offset = { x - b.x, y - b.y },
        window = minx == -MASK_HALF or maxx == MASK_HALF or miny == -MASK_HALF or maxy == MASK_HALF,
        rim = math.sqrt(x * x + y * y) + math.max(w, h) / 2 > g.w / 2,
        rows = rows,
    }
end

-- Our marks on the minimap: a red cross at each measured centre, a blue box
-- around its hit area. Unnamed children of Minimap, mouse pass-through.
local marks = {}
local function hideMarks() for _, f in ipairs(marks) do f:Hide() end end
local function showMarks(list)
    hideMarks()
    for i, m in ipairs(list) do
        local f = marks[i]
        if not f then
            f = CreateFrame("Frame", nil, Minimap)
            f:EnableMouse(false)
            local function tex(r, g, b)
                local t = f:CreateTexture(nil, "OVERLAY")
                t:SetColorTexture(r, g, b, 0.9)
                return t
            end
            f.cross = { tex(1, 0, 0), tex(1, 0, 0) }
            f.box = { tex(0, 0.8, 1), tex(0, 0.8, 1), tex(0, 0.8, 1), tex(0, 0.8, 1) }
            for j, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do f.box[j]:SetPoint(side, f, side) end
            f.cross[1]:SetPoint("CENTER", f, "CENTER")
            f.cross[2]:SetPoint("CENTER", f, "CENTER")
            f.cross[1]:SetSize(4, 1)
            f.cross[2]:SetSize(1, 4)
            marks[i] = f
        end
        f:ClearAllPoints()
        f:SetPoint("CENTER", Minimap, "CENTER", m.x, m.y)
        f:SetSize(m.w, m.h)
        f.box[1]:SetSize(m.w, 1)
        f.box[2]:SetSize(m.w, 1)
        f.box[3]:SetSize(1, m.h)
        f.box[4]:SetSize(1, m.h)
        f:Show()
    end
end

local function iconsDB()
    NodeRadarProbeDB.icons = NodeRadarProbeDB.icons or {}
    return NodeRadarProbeDB.icons
end

local function measureHitAreas(label)
    local n = nr()
    if not n then error("NodeRadar isn't loaded", 0) end
    local r = n.Scan.Sweep()
    if not r then error("NodeRadar's sweep failed", 0) end
    local g = geometry()
    if not g then error("the map's geometry is unreadable", 0) end
    -- One herb and one ore when both show, then other nodes: three at most.
    local picked, kinds, seen = {}, {}, {}
    for _, b in ipairs(r.blips) do
        local kind = n.Learn.Kind(b.name)
        seen[#seen + 1] = b.name
        if kind and not kinds[kind] then kinds[kind] = true; picked[#picked + 1] = b; b.picked = true end
    end
    for _, b in ipairs(r.blips) do
        if #picked >= 3 then break end
        if n.Learn.Kind(b.name) and not b.picked then picked[#picked + 1] = b end
    end
    if #picked == 0 then error("no node on the minimap (saw: " .. join(seen) .. "): stand where one shows, then Retry", 0) end
    local okZoom, zoom = pcall(Minimap.GetZoom, Minimap)
    local out = { label = label, zoom = okZoom and num(zoom) or nil, radius = num(C_Minimap.GetViewRadius()),
                  w = g.w, h = g.h, es = g.es, blips = {} }
    local t0 = debugprofilestop()
    setSoft(true)
    local ok, err = pcall(function()
        for _, b in ipairs(picked) do
            local m = hitArea(n, b.name, b, g)
            m.kind = n.Learn.Kind(b.name)
            m.raw = m.x and rawAt(g, m.x, m.y) or {}
            out.blips[#out.blips + 1] = m
        end
    end)
    pcall(Minimap.UpdateMouseoverAtPoint, Minimap, farPixels(g))
    setSoft(false)
    if not ok then error(str(err), 0) end
    out.ms = debugprofilestop() - t0
    local db = iconsDB()
    db.areas = db.areas or {}
    db.areas[#db.areas + 1] = out
    local drawn, parts = {}, {}
    for _, m in ipairs(out.blips) do
        if m.points > 0 then
            drawn[#drawn + 1] = m
            parts[#parts + 1] = ("%s [%s] %s %dx%d, %d points, fill %.2f, corners %d, centre %+.1f %+.1f from the grid's, "
                .. "groups %d%s%s"):format(m.name, str(m.kind), m.shape, m.w, m.h, m.points, m.fill, m.corners,
                m.offset[1], m.offset[2], m.groups, m.window and ", touches the window" or "", m.rim and ", at the rim" or "")
        else
            parts[#parts + 1] = m.name .. ": no hit"
        end
    end
    showMarks(drawn)
    local text = ("%s: zoom %s, radius %s yd, map %.0fx%.0f, %.0f ms: %s"):format(label, str(out.zoom), str(out.radius),
        g.w, g.h, out.ms, table.concat(parts, "; "))
    say("hit areas " .. text)
    return text
end

-- The raw text of a node blip with a position arrow, unlike `other`'s.
local function arrowFound(other)
    local n = nr()
    if not n then return nil, "NodeRadar isn't loaded" end
    local r = n.Scan.Sweep()
    local g = geometry()
    if not (r and g) then return nil, "no sweep" end
    local found
    setSoft(true)
    local ok, err = pcall(function()
        for _, b in ipairs(r.blips) do
            if n.Learn.Kind(b.name) then
                for _, t in ipairs(rawAt(g, b.x, b.y)) do
                    local tex = t:match("|T([^|]*PositionArrows[^|]*)|t")
                    if tex and tex ~= other then found = { name = b.name, raw = t, tex = tex }; return end
                end
            end
        end
    end)
    pcall(Minimap.UpdateMouseoverAtPoint, Minimap, farPixels(g))
    setSoft(false)
    if not ok then return nil, "ERROR " .. str(err) end
    return found, "no node with an arrow" .. (other and " other than the first" or "") .. " yet"
end

local function arrowWait(which)
    return function()
        hideMarks()
        local arrows = iconsDB().arrows or {}
        iconsDB().arrows = arrows
        local found, why = arrowFound(which == "below" and arrows.above and arrows.above.tex or nil)
        if not found then return false, why end
        arrows[which] = found
        say(("arrow %s: %s, raw %q"):format(which, found.name, found.raw))
        return true, ("%s: %s"):format(found.name, found.tex)
    end
end

-- What C_Item answers for every NODE_INFO item of this locale, cached or not.
local function itemIcons()
    local n = nr()
    local info = n and n.NODE_INFO and n.NODE_INFO[GetLocale()]
    if type(info) ~= "table" then error("no NODE_INFO for " .. tostring(GetLocale()), 0) end
    local names, list = {}, {}
    for name, v in pairs(info) do
        if v.item and not names[v.item] then names[v.item] = name; list[#list + 1] = v.item end
    end
    table.sort(list)
    local t = { items = #list, cached = 0, uncached = 0, icon = 0, uncachedIcon = 0, instant = 0, differ = 0,
                errors = 0, examples = {} }
    for _, id in ipairs(list) do
        local okC, cached = pcall(C_Item.IsItemDataCachedByID, id)
        local okI, icon = pcall(C_Item.GetItemIconByID, id)
        local okN, _, _, _, _, instant = pcall(C_Item.GetItemInfoInstant, id)
        if not (okC and okI and okN) then t.errors = t.errors + 1 end
        cached = okC and yes(cached)
        icon = okI and not secret(icon) and icon or nil
        instant = okN and not secret(instant) and instant or nil
        if cached then t.cached = t.cached + 1 else t.uncached = t.uncached + 1 end
        if icon ~= nil then
            t.icon = t.icon + 1
            if not cached then t.uncachedIcon = t.uncachedIcon + 1 end
        end
        if instant ~= nil then t.instant = t.instant + 1 end
        if icon ~= nil and instant ~= nil and icon ~= instant then t.differ = t.differ + 1 end
        if not cached and #t.examples < 5 then
            t.examples[#t.examples + 1] = ("%s %d: icon %s, instant %s"):format(names[id], id, str(icon), str(instant))
        end
    end
    iconsDB().items = t
    local text = ("%d items: %d cached, %d not; GetItemIconByID answered %d (%d of the uncached), "
        .. "GetItemInfoInstant's icon %d, %d differ, %d errors; uncached: %s"):format(t.items, t.cached, t.uncached,
        t.icon, t.uncachedIcon, t.instant, t.differ, t.errors, join(t.examples))
    say("item icons " .. text)
    return text
end

local function zoomChanged()
    hideMarks()
    local ok, zoom = pcall(Minimap.GetZoom, Minimap)
    zoom = ok and num(zoom) or nil
    local areas = iconsDB().areas
    local last = areas and areas[#areas] and areas[#areas].zoom
    if zoom == nil or zoom == last then return false, "zoom " .. str(zoom) end
    return true, "zoom " .. str(zoom)
end

local MARKS_ASK = "Stay still. Is each red cross on the middle of a node's yellow dot, with the blue box around the "
    .. "dot? (The box is where the node answers the mouse.)"

Probe:Steps("icons", {
    rev = 1,
    title = "Item icons on the minimap's nodes: hit areas, arrows, icons (#28)",
    { text = "Have NodeRadar loaded and gathering tracking on.", wait = function()
          if not nr() then return false, "NodeRadar isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          NodeRadarProbeDB.icons = nil
          return true, "ready"
      end },
    { text = "Reading the items' icons (a moment).", auto = true, run = itemIcons },
    { text = "Stand still where a herb or ore shows on the minimap (one of each if you can), then press Measure. "
          .. "The game freezes a second or two.", button = "Measure",
      run = function() return measureHitAreas("first zoom") end },
    { text = MARKS_ASK, ask = true, screenshot = "hit areas, first zoom" },
    { text = "Zoom the minimap in or out (its + and - buttons or the mouse wheel), keeping a node in view.",
      wait = zoomChanged },
    { text = "Stand still with a node in view, then press Measure.", button = "Measure",
      run = function() return measureHitAreas("second zoom") end },
    { text = MARKS_ASK, ask = true, screenshot = "hit areas, second zoom" },
    { text = "Find a node above you (up a slope or on a ledge): the minimap marks it with an arrow. "
          .. "Skip if there's none near.", wait = arrowWait("above") },
    { text = "Now a node below you. Skip if there's none near.", wait = arrowWait("below") },
    { text = "Optional: two nodes of one name touching on the minimap, or one at its edge. Stand so and press "
          .. "Measure, or Skip.", button = "Measure", run = function() return measureHitAreas("extra") end },
    { text = MARKS_ASK .. " (Skip if you skipped the last step.)", ask = true, screenshot = "hit areas, extra" },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Item icons, second round (#28): NodeRadar's own icons on, checked in game.
-- Over the dots standing still, running, turning, after a zoom and indoors;
-- the hover tooltip; the player's arrow; a node above (its arrow's text, and
-- whether Blizzard's triangle still shows); a gathered node's record against
-- UnitPosition at the cast (the axes); the cost, icons off then on along the
-- same route; the stock map's square. The setting is put back at the end.
--------------------------------------------------------------------------------

local BELOW = "Interface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:16:32"   -- round 1

local function iconRecords()
    local n = nr()
    return n and n.Icons and n.Icons._test.records() or {}
end

-- A widget method's answer, both of pcall's returns kept (not `w and pcall(...)`,
-- which keeps one: Codex on #39); nil for no widget or a throw.
local function ask(w, method)
    if not w then return nil end
    local ok, v = pcall(w[method], w)
    if ok then return v end
end

local function shownIcons()
    local list = {}
    for _, r in ipairs(iconRecords()) do
        if yes(ask(r.frame, "IsShown")) then list[#list + 1] = r end
    end
    return list
end

local function iconsText()
    local parts = {}
    for _, r in ipairs(shownIcons()) do
        parts[#parts + 1] = ("%s at %+.1f %+.1f%s"):format(r.name, r.x or 0, r.y or 0, r.dim and " (dimmed)" or "")
    end
    return #parts .. " icons: " .. join(parts)
end

-- NodeRadar's icons setting, raw, put back by the last step.
local function iconsOn(n, on)
    if NodeRadarProbeDB.restoreIcons == nil then NodeRadarProbeDB.restoreIcons = { value = rawget(n.db, "icons") } end
    if n.db.icons ~= on then n.Set("icons", on) end
end

local function iconsBack()
    local n, saved = nr(), NodeRadarProbeDB.restoreIcons
    if not (n and saved) then return "nothing to put back" end
    n.Set("icons", saved.value)
    NodeRadarProbeDB.restoreIcons = nil
    return "icons setting put back: " .. str(saved.value)
end

local function moving()
    local ok, speed = pcall(GetUnitSpeed, "player")
    speed = ok and num(speed)
    return speed and speed > 0
end

-- The cost: every mouseover read counted (our hook, after Blizzard's own),
-- NodeRadar's sweep timed, the memory allocated per frame summed (all addons:
-- compared off against on, on the same route).
local cost = {}
hooksecurefunc(Minimap, "UpdateMouseoverAtPoint", function() if cost.on then cost.reads = cost.reads + 1 end end)
local costFrame = CreateFrame("Frame")

local function costStart(n, label)
    local orig = n.Step
    cost = { label = label, reads = 0, kb = 0, last = collectgarbage("count"), steps = 0, worst = 0, t0 = GetTime(),
             on = true, orig = orig }
    n.Step = function(now)
        local t = debugprofilestop()
        local r = orig(now)
        local ms = debugprofilestop() - t
        if r then
            cost.steps = cost.steps + 1
            cost.worst = math.max(cost.worst, ms)
        end
        return r
    end
    costFrame:SetScript("OnUpdate", function()
        local c = collectgarbage("count")
        if c > cost.last then cost.kb = cost.kb + (c - cost.last) end
        cost.last = c
    end)
end

local function costStop(n)
    if cost.orig then n.Step = cost.orig end
    costFrame:SetScript("OnUpdate", nil)
    cost.on = false
    local secs = GetTime() - cost.t0
    local out = { label = cost.label, secs = secs, reads = cost.reads, kb = cost.kb, sweeps = cost.steps,
                  worst = cost.worst, icons = n.db.icons == true }
    local db = iconsDB()
    db.cost = db.cost or {}
    db.cost[cost.label] = out
    local text = ("%s: %.0f s, %d sweeps, %.0f reads/s, %.0f KB/s allocated (all addons), worst sweep %.1f ms"):format(
        out.label, secs, out.sweeps, out.reads / secs, out.kb / secs, out.worst)
    say("cost " .. text)
    return text
end

local COST_SECONDS = 60
local function costWait(label, on)
    return function()
        local n = nr()
        if not n then return false, "NodeRadar isn't loaded" end
        if not (cost.on and cost.label == label) then
            if not moving() then return false, "start riding the loop" end
            iconsOn(n, on)
            costStart(n, label)
        end
        local left = COST_SECONDS - (GetTime() - cost.t0)
        if left > 0 then return false, ("%.0f s left"):format(left) end
        return true, costStop(n)
    end
end

-- A gather's cast: the nearest icon record of its name, in yards from where
-- the player stands (the gather's reach is about 5), before the gather drops it.
local function gatherIcon(name)
    local ok, pn, pw = pcall(UnitPosition, "player")
    pn, pw = ok and num(pn), ok and num(pw)
    if not (pn and pw) then return end
    local best
    for _, r in ipairs(iconRecords()) do
        if r.name == name then
            local d = math.sqrt((r.north - pn) ^ 2 + (r.west - pw) ^ 2)
            if not best or d < best.yards then best = { name = name, yards = d, north = r.north - pn, west = r.west - pw } end
        end
    end
    if best then
        best.at = GetTime()
        state.gatherIcon = best
        say(("gather: the %s icon's record %.1f yd from the player (north %+.1f, west %+.1f)"):format(name, best.yards,
            best.north, best.west))
    end
end

Probe:Steps("iconcheck", {
    rev = 1,
    title = "Item icons, second round: NodeRadar's icons in game (#28)",
    { text = "Have NodeRadar loaded and gathering tracking on. NodeRadar's icons go on now, and back as they were at "
          .. "the end.", wait = function()
          local n = nr()
          if not (n and n.Icons) then return false, "NodeRadar (with icons) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          NodeRadarProbeDB.icons = nil
          iconsOn(n, true)
          return true, "icons on"
      end },
    { text = "Stand still where herbs or ore show on the minimap, until icons cover their dots.", wait = function()
          local list = shownIcons()
          if #list == 0 then return false, "no icon yet" end
          return true, iconsText()
      end, screenshot = "icons standing still" },
    { text = "Is each icon on its node's dot? Type anything off in the Note box (an icon beside its dot, a dot "
          .. "without one).", ask = true },
    { text = "Put the mouse on an icon on the minimap and hold it there.", wait = function()
          local over
          for _, r in ipairs(shownIcons()) do
              if yes(ask(r.frame, "IsMouseOver")) then over = r end
          end
          if not over then return false, "the mouse isn't on an icon" end
          if not yes(ask(rawget(_G, "GameTooltip"), "IsShown")) then
              return false, "on " .. over.name .. ", no tooltip yet"
          end
          return true, ("on %s: the tooltip shows %s"):format(over.name,
              str(ask(rawget(_G, "GameTooltipTextLeft1"), "GetText")))
      end, screenshot = "hovering an icon" },
    { text = "Did Blizzard's tooltip show the node as it does without icons?", ask = true },
    { text = "Walk onto a node with an icon and stand on it (don't gather it).", wait = function()
          for _, r in ipairs(shownIcons()) do
              if r.x and math.sqrt(r.x * r.x + r.y * r.y) < 4 then return true, "on " .. r.name end
          end
          return false, iconsText()
      end, screenshot = "standing on a node" },
    { text = "The icon now covers your arrow. Is that acceptable at this size? (Note box: smaller, or hide it near "
          .. "you.)", ask = true },
    { text = "Find a node above you (up a slope or on a ledge). Skip if there's none near.", wait = function()
          local found, why = arrowFound(BELOW)
          if not found then return false, why end
          local arrows = iconsDB().arrows or {}
          iconsDB().arrows = arrows
          arrows.above = found
          say(("arrow above: %s, raw %q"):format(found.name, found.raw))
          return true, ("%s: %s"):format(found.name, found.tex)
      end, screenshot = "a node above, with icons" },
    { text = "Can you still see Blizzard's small arrow by that node's icon?", ask = true },
    { text = "Zoom the minimap in or out, standing still.", wait = function()
          local ok, zoom = pcall(Minimap.GetZoom, Minimap)
          zoom = ok and num(zoom)
          if zoom == nil then return false, "zoom unreadable" end
          state.icZoom = state.icZoom or zoom
          if zoom == state.icZoom then return false, "zoom " .. zoom end
          state.icZoom = nil
          return true, "zoom " .. zoom .. "; " .. iconsText()
      end, screenshot = "right after the zoom" },
    { text = "Right after the zoom, were the icons on their dots?", ask = true },
    { text = "Run past nodes with icons, keeping some in view.", wait = function()
          if not moving() then state.icRun = nil; return false, "not moving" end
          if #shownIcons() == 0 then return false, "moving, no icon in view" end
          state.icRun = (state.icRun or 0) + 1
          if state.icRun < 3 then return false, "moving with icons" end
          state.icRun = nil
          return true, iconsText()
      end, screenshot = "running" },
    { text = "Now turn while running (a full circle).", wait = function()
          local ok, facing = pcall(GetPlayerFacing)
          facing = ok and num(facing)
          if not (facing and moving()) then return false, "turn while running" end
          state.icFacing = state.icFacing or facing
          local d = math.abs(facing - state.icFacing)
          d = math.min(d, 2 * math.pi - d)
          if d < 2 then return false, ("turned %.1f rad"):format(d) end
          state.icFacing = nil
          return true, iconsText()
      end, screenshot = "turning" },
    { text = "Running and turning, did the icons stay on their dots? (Note box: lagging, jumping, blinking.)",
      ask = true },
    { text = "Optional: walk into a building or a cave with nodes in view. Skip if none is near.", wait = function()
          local ok, v = pcall(IsIndoors)
          if not (ok and yes(v)) then return false, "outdoors" end
          return true, "indoors; " .. iconsText()
      end, screenshot = "indoors" },
    { text = "Gather a node that has an icon.", wait = function()
          local g = state.gatherIcon
          if not g or GetTime() - g.at > 30 then return false, "no gather of a node with an icon yet" end
          state.gatherIcon = nil
          return true, ("%s: its record %.1f yd from you at the cast (north %+.1f, west %+.1f)"):format(g.name,
              g.yards, g.north, g.west)
      end },
    { text = "The cost, icons OFF: ride a loop past nodes for a minute (the step starts when you move).",
      wait = costWait("icons off", false), timeout = 300 },
    { text = "The cost, icons ON: ride the same loop again for a minute.", wait = costWait("icons on", true),
      timeout = 300 },
    { text = "Optional, Blizzard's own minimap: turn Glass MiniMap off in the AddOns list, then press Reload. "
          .. "Skip this and the next three steps to keep it.", reload = true },
    { text = "With a node in view on the stock minimap, stand still and press Measure.", button = "Measure",
      run = function() return measureHitAreas("stock map") end },
    { text = MARKS_ASK .. " And are the icons on their dots here too?", ask = true, screenshot = "the stock map" },
    { text = "Turn Glass MiniMap back on in the AddOns list, then press Reload.", reload = true },
    { text = "Putting NodeRadar's icons setting back.", auto = true, run = function()
          hideMarks()
          return iconsBack()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Glass discs around NodeRadar's icons (#41)
--------------------------------------------------------------------------------

-- LibGlass-1.0 as a Glass addon (Glass MiniMap) loaded it: nothing embedded. Each
-- look is a disc as Glass MiniMap's Ring.AddDisc builds one (a square host, the
-- icon inset 18% and masked round), a child of NodeRadar's icon frame so it
-- follows its position, fade and dim; NodeRadar's own texture is hidden meanwhile.
local LOOKS = {
    A = { size = 18, preset = "clean", text = "18 units, clean (Glass MiniMap's), the icon 12 as today" },
    B = { size = 22, preset = "clean", text = "22 units, clean, the icon 14" },
    C = { size = 15, preset = "clean", text = "15 units, clean, the icon 9" },
    D = { size = 18, preset = "pearl", text = "18 units, pearl (the Glass suite's theme)" },
    E = { size = 18, preset = "clean", shadow = false, text = "18 units, clean, no shadow" },
    -- Bronze, for Blizzard's own minimap (the owner): its round button's ring.
    F = { bronze = true, icon = 12, text = "bronze ring, the icon 12 as today (the ring about 22 units)" },
    G = { bronze = true, icon = 10, text = "bronze ring, the icon 10 (the ring about 18, the glass disc's size)" },
    H = { bronze = true, icon = 14, text = "bronze ring, the icon 14 (the ring about 26)" },
}

-- Blizzard's round minimap button as LibDBIcon lays it out on a 31-unit button:
-- the ring (MiniMap-TrackingBorder) 53 at its top left, the dark background 20
-- at (7, -5), the icon 17 at (7, -6), here masked round. Scaled to the icon.
local RING, RING_BG = 136430, 136467
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function bronzeFor(f, look)
    local k = look.icon / 17
    local host = CreateFrame("Frame", nil, f)
    host:SetSize(31 * k, 31 * k)
    host:SetPoint("CENTER", f, "CENTER", 0, -1 * k)    -- the icon's centre on the node: 1 above the button's
    local ring = host:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53 * k, 53 * k)
    ring:SetTexture(RING)
    ring:SetPoint("TOPLEFT", host, "TOPLEFT")
    local bg = host:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20 * k, 20 * k)
    bg:SetTexture(RING_BG)
    bg:SetPoint("TOPLEFT", host, "TOPLEFT", 7 * k, -5 * k)
    local icon = host:CreateTexture(nil, "ARTWORK")
    icon:SetSize(look.icon, look.icon)
    icon:SetPoint("TOPLEFT", host, "TOPLEFT", 7 * k, -6 * k)
    local mask = host:CreateMaskTexture()
    mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return { host = host, icon = icon, ring = ring }
end
local glass = { look = nil, insts = {}, discs = {} }       -- discs[frame][key] = { host, icon }
local glassFrame = CreateFrame("Frame")

local function libGlass()
    local stub = rawget(_G, "LibStub")
    if not stub then return nil end
    local ok, lib, minor = pcall(stub, "LibGlass-1.0", true)
    if ok and lib then return lib, minor end
end

local function glassInst(preset)
    if glass.insts[preset] == nil then
        local lib = libGlass()
        local ok, inst = pcall(lib.New, lib, { preset = preset })
        glass.insts[preset] = ok and inst or false
        if not ok then say("LibGlass New(" .. preset .. "): ERROR " .. str(inst)) end
    end
    return glass.insts[preset] or nil
end

local function discFor(f, key)
    glass.discs[f] = glass.discs[f] or {}
    local d = glass.discs[f][key]
    if d then return d end
    if LOOKS[key].bronze then
        d = bronzeFor(f, LOOKS[key])
        glass.discs[f][key] = d
        return d
    end
    local look, inst = LOOKS[key], glassInst(LOOKS[key].preset)
    if not inst then return nil end
    local host = CreateFrame("Frame", nil, f)
    host:SetSize(look.size, look.size)
    host:SetPoint("CENTER", f, "CENTER")
    local ok, g = pcall(inst.Disc, host, "disc_small")
    if not ok then
        say("Glass.Disc: ERROR " .. str(g))
        glass.discs[f][key] = false
        return nil
    end
    if look.shadow == false then inst.SetSurfaceAlpha(g, "shadow", 0) end
    local inset = math.floor(look.size * 0.18 + 0.5)
    local icon = host:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", host, "TOPLEFT", inset, -inset)
    icon:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -inset, inset)
    icon:AddMaskTexture(inst.Mask(host, "disc_mask_small", nil, inset))
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    d = { host = host, icon = icon }
    glass.discs[f][key] = d
    return d
end

-- Every frame while a look is on: each icon frame shows that look's disc only,
-- with the frame's own icon (frames are reused for other nodes). Every frame
-- ever given a disc gets its own texture back first, released ones included.
local function glassSync()
    for f, list in pairs(glass.discs) do
        for key, d in pairs(list) do
            if d and key ~= glass.look then d.host:Hide() end
        end
        f.tex:SetAlpha(1)
    end
    if not glass.look then return end
    for _, r in ipairs(iconRecords()) do
        local f = r.frame
        local d = f and f.tex and discFor(f, glass.look)
        if d then
            d.icon:SetTexture(f.tex:GetTexture())
            d.icon:SetDesaturated(yes(f.tex:IsDesaturated()))
            d.host:Show()
            f.tex:SetAlpha(0)
        end
    end
end

local function glassLook(key)
    glass.look = key
    glassSync()
    glassFrame:SetScript("OnUpdate", key and glassSync or nil)
end

-- Every icon on the map wears the look: what a look's step waits for.
local function lookShown(key)
    return function()
        if glass.look ~= key then glassLook(key) end
        local list = shownIcons()
        if #list == 0 then return false, "no icon in view" end
        for _, r in ipairs(list) do
            local d = glass.discs[r.frame] and glass.discs[r.frame][key]
            if not (d and yes(ask(d.host, "IsShown"))) then return false, "building the discs" end
        end
        return true, ("look %s on %s"):format(key, iconsText())
    end
end

local glassSteps = {
    rev = 1,
    title = "Glass discs around NodeRadar's icons (#41)",
    { text = "Have NodeRadar and Glass MiniMap loaded and gathering tracking on. NodeRadar's icons go on now, and "
          .. "back as they were at the end.", wait = function()
          local n = nr()
          if not (n and n.Icons) then return false, "NodeRadar (with icons) isn't loaded" end
          local lib, minor = libGlass()
          if not lib then return false, "LibGlass-1.0 isn't loaded (turn Glass MiniMap on)" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          iconsOn(n, true)
          return true, "icons on, LibGlass-1.0 minor " .. str(minor)
      end },
    { text = "Stand still where herbs or ore show on the minimap, until icons cover their dots. Stay still for the "
          .. "looks that follow.", wait = function()
          glassLook(nil)
          if #shownIcons() == 0 then return false, "no icon yet" end
          return true, iconsText()
      end, screenshot = "glass: plain icons" },
}
for _, key in ipairs({ "A", "B", "C", "D", "E" }) do
    table.insert(glassSteps, { text = "Look " .. key .. ": " .. LOOKS[key].text .. ". Stay still.",
                               wait = lookShown(key), screenshot = "glass: look " .. key })
    table.insert(glassSteps, { text = "Look " .. key .. " (" .. LOOKS[key].text .. "): do you like it? Note box: "
                                   .. "what you'd change (size, the icon inside, the glass).", ask = true })
end
for _, s in ipairs({
    { text = "Which look did you like best? Type its letter in the Note box (A to E, or plain).", ask = true },
    { text = "Look A again: run past nodes, turning a bit, until this step completes.", wait = function()
          if glass.look ~= "A" then glassLook("A") end
          if not moving() then state.glRun = nil; return false, "not moving" end
          if #shownIcons() == 0 then return false, "moving, no icon in view" end
          state.glRun = (state.glRun or 0) + 1
          if state.glRun < 3 then return false, "moving with discs" end
          state.glRun = nil
          return true, iconsText()
      end, screenshot = "glass: running" },
    { text = "Running, did the discs stay on their nodes? (Note box: lagging, blinking, too busy.)", ask = true },
    { text = "Taking the discs off, NodeRadar's icons setting back.", auto = true, run = function()
          glassLook(nil)
          return iconsBack()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}) do table.insert(glassSteps, s) end
Probe:Steps("glass", glassSteps)

local function glassMiniMapOn()
    local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, "GlassMiniMap")
    return ok and yes(loaded)
end

local bronzeSteps = {
    rev = 1,
    title = "Bronze rings around NodeRadar's icons, on Blizzard's minimap (#41)",
    { text = "Have NodeRadar loaded and gathering tracking on. NodeRadar's icons go on now, and back as they were "
          .. "at the end.", wait = function()
          local n = nr()
          if not (n and n.Icons) then return false, "NodeRadar (with icons) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          iconsOn(n, true)
          return true, "icons on"
      end },
    { text = "Turn Glass MiniMap off in the AddOns list, then press Reload.", reload = true },
    { text = "Stand still where herbs or ore show on the minimap, until icons cover their dots. Stay still for the "
          .. "looks that follow.", wait = function()
          glassLook(nil)
          if glassMiniMapOn() then return false, "Glass MiniMap is still on: turn it off and reload" end
          if #shownIcons() == 0 then return false, "no icon yet" end
          return true, iconsText()
      end, screenshot = "bronze: plain icons" },
}
for _, key in ipairs({ "F", "G", "H" }) do
    table.insert(bronzeSteps, { text = "Look " .. key .. ": " .. LOOKS[key].text .. ". Stay still.",
                                wait = lookShown(key), screenshot = "bronze: look " .. key })
    table.insert(bronzeSteps, { text = "Look " .. key .. " (" .. LOOKS[key].text .. "): do you like it? Note box: "
                                    .. "what you'd change (size, the ring, the icon inside).", ask = true })
end
for _, s in ipairs({
    { text = "Which look did you like best? Type its letter in the Note box (F, G, H, or plain).", ask = true },
    { text = "Look F again: run past nodes, turning a bit, until this step completes.", wait = function()
          if glass.look ~= "F" then glassLook("F") end
          if not moving() then state.glRun = nil; return false, "not moving" end
          if #shownIcons() == 0 then return false, "moving, no icon in view" end
          state.glRun = (state.glRun or 0) + 1
          if state.glRun < 3 then return false, "moving with rings" end
          state.glRun = nil
          return true, iconsText()
      end, screenshot = "bronze: running" },
    { text = "Running, did the rings stay on their nodes? (Note box: lagging, blinking, too busy.)", ask = true },
    { text = "Taking the rings off.", auto = true, run = function()
          glassLook(nil)
          return "rings off"
      end },
    { text = "Turn Glass MiniMap back on in the AddOns list, then press Reload.", reload = true },
    { text = "Putting NodeRadar's icons setting back.", auto = true, run = iconsBack },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}) do table.insert(bronzeSteps, s) end
Probe:Steps("bronze", bronzeSteps)

--------------------------------------------------------------------------------
-- NodeRadar's own looks in game (#41): /fp steps nr styles
--------------------------------------------------------------------------------

-- NodeRadar's icons, style and size, raw, put back by the last step.
local function lookOn(n, style, size)
    if NodeRadarProbeDB.restoreLook == nil then
        NodeRadarProbeDB.restoreLook = { icons = rawget(n.db, "icons"), style = rawget(n.db, "iconStyle"),
                                         size = rawget(n.db, "iconSize") }
    end
    if n.db.icons ~= true then n.Set("icons", true) end
    if style ~= nil and n.db.iconStyle ~= style then n.Set("iconStyle", style) end
    if size ~= nil and n.db.iconSize ~= size then n.Set("iconSize", size) end
end

local function lookBack()
    local n, saved = nr(), NodeRadarProbeDB.restoreLook
    if not (n and saved) then return "nothing to put back" end
    n.Set("iconStyle", saved.style)
    n.Set("iconSize", saved.size)
    n.Set("icons", saved.icons)
    NodeRadarProbeDB.restoreLook = nil
    return ("put back: icons %s, style %s, size %s"):format(str(saved.icons), str(saved.style), str(saved.size))
end

local function lookText(n)
    local l = n.Icons._test.look()
    return ("%s %s (setting %s, %s)"):format(l.style, l.size, str(n.db.iconStyle), str(n.db.iconSize))
end

-- Waits until icons show in this look: the setting set, the effective look and
-- the frames read back.
local function showLook(style, size, want)
    return function()
        local n = nr()
        if not (n and n.Icons and n.Icons._test.look) then return false, "NodeRadar (#41) isn't loaded" end
        lookOn(n, style, size)
        local l = n.Icons._test.look()
        if want and l.style ~= want then return false, "the look is " .. lookText(n) .. ", not " .. want end
        local list = shownIcons()
        if #list == 0 then return false, "no icon in view" end
        return true, lookText(n) .. "; " .. iconsText()
    end
end

-- A shown record matching `test`, or nil.
local function shownWhere(test)
    for _, r in ipairs(shownIcons()) do if test(r) then return r end end
end

local function costLook(label, style)
    return function()
        local n = nr()
        if not n then return false, "NodeRadar isn't loaded" end
        if not (cost.on and cost.label == label) then
            if not moving() then return false, "start riding the loop" end
            if style then lookOn(n, style, "medium") else n.Set("icons", false) end
            costStart(n, label)
        end
        local left = COST_SECONDS - (GetTime() - cost.t0)
        if left > 0 then return false, ("%.0f s left"):format(left) end
        local text = costStop(n)
        iconsDB().cost[label].style = style or "off"
        return true, text
    end
end

Probe:Steps("styles", {
    rev = 1,
    title = "Icon frames and sizes, NodeRadar's own (#41)",
    { text = "Have NodeRadar and Glass MiniMap loaded and gathering tracking on. NodeRadar's icons go on now, and "
          .. "your settings come back at the end.", wait = function()
          local n = nr()
          if not (n and n.Icons and n.Icons._test.look) then return false, "NodeRadar (#41) isn't loaded" end
          if not glassMiniMapOn() then return false, "Glass MiniMap is off: turn it on and reload" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          NodeRadarProbeDB.icons = nil
          lookOn(n, "auto", "medium")
          return true, "icons on: " .. lookText(n)
      end },
    { text = "Stand still where herbs or ore show on the minimap, until NodeRadar's icons cover their dots. Stay "
          .. "still for the sizes that follow.", wait = showLook("auto", "medium", "glass"),
      screenshot = "styles: auto, Glass MiniMap" },
    { text = "Following the minimap with Glass MiniMap: glass discs, medium. Is each on its node?", ask = true },
    { text = "Glass, small.", wait = showLook("glass", "small", "glass"), screenshot = "styles: glass small" },
    { text = "Glass, large.", wait = showLook("glass", "large", "glass"), screenshot = "styles: glass large" },
    { text = "Did glass look right at small and large? (Note box: which size you'd keep as the default.)",
      ask = true },
    { text = "Bronze, small.", wait = showLook("bronze", "small", "bronze"), screenshot = "styles: bronze small" },
    { text = "Bronze, medium.", wait = showLook("bronze", "medium", "bronze"), screenshot = "styles: bronze medium" },
    { text = "Bronze, large.", wait = showLook("bronze", "large", "bronze"), screenshot = "styles: bronze large" },
    { text = "Did bronze look right at each size on Glass MiniMap?", ask = true },
    { text = "No frame (the plain icon), medium.", wait = showLook("plain", "medium", "plain"),
      screenshot = "styles: plain" },
    { text = "Bronze again: find a node above or below you (a slope, a ledge), until NodeRadar's arrow shows by "
          .. "it.", wait = function()
          local n = nr()
          if n then lookOn(n, "bronze", "medium") end
          local r = shownWhere(function(r) return r.height ~= nil end)
          if not r then return false, "no icon with an arrow yet" end
          return true, ("%s %s"):format(r.name, r.height)
      end, screenshot = "styles: our arrow" },
    { text = "Is NodeRadar's small arrow where Blizzard's would be (above the frame for a node above, under it "
          .. "for one below), and does it look like Blizzard's?", ask = true },
    { text = "Put the mouse on a framed icon and hold it there.", wait = function()
          local over
          for _, r in ipairs(shownIcons()) do
              if yes(ask(r.frame, "IsMouseOver")) then over = r end
          end
          if not over then return false, "the mouse isn't on an icon" end
          if not yes(ask(rawget(_G, "GameTooltip"), "IsShown")) then return false, "on " .. over.name .. ", no tooltip yet" end
          return true, ("on %s: the tooltip shows %s"):format(over.name, str(ask(rawget(_G, "GameTooltipTextLeft1"),
              "GetText")))
      end, screenshot = "styles: hovering" },
    { text = "Did Blizzard's tooltip show the node through the frame?", ask = true },
    { text = "Optional: a node your skill can't gather in view (dimmed). Skip if none.", wait = function()
          local r = shownWhere(function(r) return r.dim end)
          if not r then return false, "no dimmed icon in view" end
          return true, r.name .. " dimmed"
      end, screenshot = "styles: dimmed" },
    { text = "Walk so a node with an icon leaves past the minimap's edge, watching it go.", wait = function()
          local r = shownWhere(function(r) return r.frame and (ask(r.frame, "GetAlpha") or 1) < 0.95 and not r.dim end)
          if not r then return false, "no icon fading at the edge yet" end
          return true, r.name .. " fading at the edge"
      end, screenshot = "styles: the rim" },
    { text = "Did the framed icon fade out at the edge, rather than pop off?", ask = true },
    { text = "Open Esc > Options > AddOns > NodeRadar and leave it open.", wait = function()
          local n = nr()
          local p = n and n.Options and n.Options._test and n.Options._test.panel
          if not yes(ask(p, "IsVisible")) then return false, "NodeRadar's page isn't open" end
          return true, "the page is open"
      end, screenshot = "styles: the Options page" },
    { text = "Does the whole page fit, down to the Learning section and the /nr help line, without anything cut "
          .. "off? Then close it.", ask = true },
    { text = "The cost, icons OFF: ride a loop past nodes for a minute (the step starts when you move).",
      wait = costLook("styles off", nil), timeout = 300 },
    { text = "The cost, GLASS: ride the same loop again for a minute.", wait = costLook("styles glass", "glass"),
      timeout = 300 },
    { text = "The cost, BRONZE: the same loop once more.", wait = costLook("styles bronze", "bronze"), timeout = 300 },
    { text = "Now Blizzard's own minimap: turn Glass MiniMap off in the AddOns list, then press Reload.",
      reload = true },
    { text = "Stand still with nodes in view.", wait = function()
          local n = nr()
          if n then lookOn(n, "auto", "medium") end            -- the cost loops left bronze chosen
          if glassMiniMapOn() then return false, "Glass MiniMap is still on: turn it off and reload" end
          return showLook("auto", "medium", "bronze")()
      end, screenshot = "styles: auto, Blizzard's minimap" },
    { text = "Following the minimap without Glass MiniMap: bronze rings. Is each on its node, as in the bronze round?",
      ask = true },
    { text = "Turn Glass MiniMap back on in the AddOns list, then press Reload.", reload = true },
    { text = "Putting your NodeRadar settings back.", auto = true, run = lookBack },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- The compass, first round (#29): /fp steps nr compass
--------------------------------------------------------------------------------

-- GetPlayerFacing and an arrow drawn at `angle - facing` were measured with
-- RXPGuides (porting guide, 70374). Here: the convention in the four directions
-- and across north, our bearing to one of #28's records, a draft ring's art and
-- turn direction, the distance against a walk, and a flight.
local TAU = 2 * math.pi
local ARROWS_FILE = "Interface\\Minimap\\Minimap-PositionArrows"
local function wrap(a) return (a + math.pi) % TAU - math.pi end   -- to -pi..pi

local function facing()
    local ok, f = pcall(GetPlayerFacing)
    return ok and num(f) or nil
end

-- The player in UnitPosition's frame: north, west (#28, measured by a gather).
local function here()
    local ok, n, w = pcall(UnitPosition, "player")
    n, w = ok and num(n), ok and num(w)
    if n and w then return n, w end
end

-- A world point's bearing from the player, counter-clockwise from north as
-- GetPlayerFacing counts, and its horizontal distance in yards.
local function bearing(n, w)
    local pn, pw = here()
    if not pn then return nil end
    local north, east = n - pn, -(w - pw)
    return math.atan2(-east, north) % TAU, math.sqrt(north * north + east * east)
end

local compass = { target = nil }
local compassFrame = CreateFrame("Frame", nil, UIParent)
compassFrame:SetSize(120, 120)
compassFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
compassFrame:EnableMouse(false)
compassFrame:Hide()
local ring = compassFrame:CreateTexture(nil, "BACKGROUND")
ring:SetAllPoints(compassFrame)
ring:SetTexture("Interface\\AddOns\\NodeRadar\\Media\\SonarRing.tga")
ring:SetVertexColor(1, 0.85, 0.4, 0.8)
local arrow = compassFrame:CreateTexture(nil, "OVERLAY")
arrow:SetSize(28, 28)
arrow:SetTexture(ARROWS_FILE)
arrow:SetTexCoord(0, 1, 0, 0.5)                            -- Blizzard's upward triangle (#41): its zero is up
local distText = compassFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
distText:SetPoint("CENTER", compassFrame, "CENTER")

-- Each frame while shown: the arrow on the ring at (bearing - facing), turned to match.
compassFrame:SetScript("OnUpdate", function()
    local t = compass.target
    local f = facing()
    local b, d = nil, nil
    if t then b, d = bearing(t.north, t.west) end
    if not (b and f) then arrow:Hide(); distText:SetText("?"); return end
    local a = wrap(b - f)                                  -- counter-clockwise from straight ahead
    arrow:ClearAllPoints()
    arrow:SetPoint("CENTER", compassFrame, "CENTER", -48 * math.sin(a), 48 * math.cos(a))
    arrow:SetRotation(a)
    arrow:Show()
    distText:SetText(("%d yd"):format(d + 0.5))
    compass.angle, compass.dist = a, d
end)

local function compassText()
    local t = compass.target
    if not t then return "no target" end
    local b, d = bearing(t.north, t.west)
    local f = facing()
    return ("%s: bearing %s, facing %s, off by %s, %s yd"):format(t.name, str(b and ("%.2f"):format(b)),
        str(f and ("%.2f"):format(f)), str(b and f and ("%+.2f"):format(wrap(b - f))), str(d and ("%.1f"):format(d)))
end

-- Waits until the facing is within 0.15 rad of `want` for two polls.
local function faceTo(label, want)
    return function()
        local f = facing()
        if not f then return false, "facing unreadable" end
        if math.abs(wrap(f - want)) > 0.15 then
            state.cmpHold = nil
            return false, ("facing %.2f rad (%s is %.2f)"):format(f, label, want)
        end
        state.cmpHold = (state.cmpHold or 0) + 1
        if state.cmpHold < 2 then return false, "hold still" end
        state.cmpHold = nil
        local db = iconsDB()
        db.compass = db.compass or {}
        db.compass[label] = f
        return true, ("%s: facing %.3f rad"):format(label, f)
    end
end

-- Waits until the node sits `want` radians counter-clockwise of straight ahead.
local function nodeAt(label, want)
    return function()
        if not compass.target then return false, "no target" end
        local t = compass.target
        local b = bearing(t.north, t.west)
        local f = facing()
        if not (b and f) then return false, "unreadable" end
        local off = wrap(b - f)
        if math.abs(wrap(off - want)) > 0.15 then
            state.cmpHold = nil
            return false, ("the node is %+.2f rad from straight ahead (%s: %+.2f)"):format(off, label, want)
        end
        state.cmpHold = (state.cmpHold or 0) + 1
        if state.cmpHold < 2 then return false, "hold still" end
        state.cmpHold = nil
        return true, label .. "; " .. compassText()
    end
end

-- The gather that ends the walk (from the boot's UNIT_SPELLCAST_SENT).
local function compassGather(name)
    local t = compass.target
    if not (t and t.start) then return end
    local pn, pw = here()
    if not pn then return end
    local walked = math.sqrt((pn - t.start.n) ^ 2 + (pw - t.start.w) ^ 2)
    local off = math.sqrt((pn - t.north) ^ 2 + (pw - t.west) ^ 2)
    compass.gathered = { name = name, at = GetTime(), start = t.start.d, walked = walked, off = off,
                         same = name == t.name }
    say(("compass gather: %s; at the start %.1f yd away, straight-line walked %.1f yd, the record %.1f yd from the "
        .. "player"):format(name, t.start.d, walked, off))
end

Probe:Steps("compass", {
    rev = 1,
    title = "The compass, first round: facing, bearing, a draft ring (#29)",
    { text = "Have NodeRadar loaded and gathering tracking on, outdoors, out of combat. NodeRadar's icons go on now "
          .. "(the compass aims at their measured nodes), and back as they were at the end.", wait = function()
          local n = nr()
          if not (n and n.Icons) then return false, "NodeRadar (with icons) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          lookOn(n, nil, nil)
          if not facing() then return false, "GetPlayerFacing reads nothing" end
          if not here() then return false, "UnitPosition reads nothing" end
          return true, "facing and position read"
      end },
    { text = "Turn your character to face NORTH (the minimap's player arrow pointing straight up). Hold still.",
      wait = faceTo("north", 0) },
    { text = "Now face WEST (the arrow pointing left).", wait = faceTo("west", math.pi / 2) },
    { text = "Now SOUTH (pointing down).", wait = faceTo("south", math.pi) },
    { text = "Now EAST (pointing right).", wait = faceTo("east", 3 * math.pi / 2) },
    { text = "Turn slowly through north (from east, past north, toward west), until this step completes.",
      wait = function()
          local f = facing()
          if not f then return false, "facing unreadable" end
          local last = state.cmpLast
          state.cmpLast = f
          if last and math.abs(f - last) > math.pi then
              state.cmpLast = nil
              return true, ("crossed north: %.3f -> %.3f rad"):format(last, f)
          end
          return false, ("facing %.2f rad"):format(f)
      end },
    { text = "Stand still with a node's icon on the minimap, 40 yards or more away if you can. The compass "
          .. "appears below the screen's centre.", wait = function()
          local best
          for _, r in ipairs(shownIcons()) do
              local _, d = bearing(r.north, r.west)
              if d and (not best or d < best.d) and not r.dim then best = { r = r, d = d } end
          end
          if not best then return false, "no icon you can gather in view" end
          local r = best.r
          local pn, pw = here()
          compass.target = { name = r.name, north = r.north, west = r.west,
                             start = { n = pn, w = pw, d = best.d } }
          compassFrame:Show()
          return true, compassText()
      end },
    { text = "Turn until that node is straight ahead of your character: on the minimap, straight above your "
          .. "arrow. Hold still.", wait = nodeAt("ahead", 0), screenshot = "compass: the node ahead" },
    { text = "Does the compass's arrow point straight up, at the top of the ring?", ask = true },
    { text = "Now turn right until the node is on your LEFT (on the minimap, straight left of your arrow). Hold "
          .. "still.", wait = nodeAt("on the left", math.pi / 2), screenshot = "compass: the node on the left" },
    { text = "Does the arrow point left, at the ring's left side?", ask = true },
    { text = "Now ride to the node following the compass (not the minimap), and gather it.", wait = function()
          local g = compass.gathered
          if not g then return false, compass.dist and ("%d yd to go"):format(compass.dist) or "go" end
          compass.gathered = nil
          local db = iconsDB()
          db.compass = db.compass or {}
          db.compass.walk = g
          return true, ("%s%s: %.1f yd at the start, %.1f yd walked in a straight line, the record %.1f yd from you")
              :format(g.name, g.same and "" or " (not the target)", g.start, g.walked, g.off)
      end, timeout = 600 },
    { text = "Following the compass, did it lead you to the node? Note box: easy to read, its size, where it sits, "
          .. "anything confusing.", ask = true, screenshot = "compass: at the node" },
    { text = "Optional: take a flight from a flight master. Skip if none is near.", wait = function()
          local ok, on = pcall(UnitOnTaxi, "player")
          if not (ok and yes(on)) then return false, "not on a flight: UnitOnTaxi " .. str(on) end
          return true, "UnitOnTaxi true on the flight; facing " .. str(facing()) .. ", position " .. str(here())
      end },
    { text = "Land (or let the flight finish).", wait = function()
          local ok, on = pcall(UnitOnTaxi, "player")
          if ok and on == false then return true, "UnitOnTaxi false after landing" end
          return false, "on the flight: UnitOnTaxi " .. str(on)
      end },
    { text = "Taking the compass down, NodeRadar's icons back.", auto = true, run = function()
          compassFrame:Hide()
          compass.target = nil
          return lookBack()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- The compass, third round (#29): the nearest node, /fp steps nr compass3
--------------------------------------------------------------------------------

-- NodeRadar's compass and icons settings, raw, put back by the last step.
local function compassOn(n, compassOnOff, icons)
    if NodeRadarProbeDB.restoreCompass == nil then
        NodeRadarProbeDB.restoreCompass = { compass = rawget(n.db, "compass"), icons = rawget(n.db, "icons") }
    end
    if n.db.icons ~= icons then n.Set("icons", icons) end
    if n.db.compass ~= compassOnOff then n.Set("compass", compassOnOff) end
end

local function compassBack()
    local n, saved = nr(), NodeRadarProbeDB.restoreCompass
    if not (n and saved) then return "nothing to put back" end
    n.Set("compass", saved.compass)
    n.Set("icons", saved.icons)
    NodeRadarProbeDB.restoreCompass = nil
    return ("put back: compass %s, icons %s"):format(str(saved.compass), str(saved.icons))
end

-- The candidates and the choice, logged when the target changes (cw.events):
-- every record's name and distance, the chosen one's misses and height.
local cw = { events = {} }
local function cwNote(kind, text)
    cw.events[#cw.events + 1] = { kind = kind, at = GetTime(), text = text }
    say("compass3 " .. kind .. ": " .. text)
end
local function candidates(n)
    local parts = {}
    for _, r in ipairs(n.Icons.Records()) do
        local _, d = bearing(r.north, r.west)
        parts[#parts + 1] = ("%s %s%s"):format(r.name, d and ("%.0f"):format(d) or "?",
            n.Alert.Gatherable(r.name) and "" or " (not gatherable)")
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end
local watch = CreateFrame("Frame")
watch:SetScript("OnUpdate", function()
    if not cw.on then return end
    local n = nr()
    local T = n and n.Compass and n.Compass._test
    if not T then return end
    local t = T.target()
    if t ~= cw.target then
        if t then
            local _, d = bearing(t.north, t.west)
            cwNote("target", ("%s %.1f yd, misses %s, %s; candidates: %s"):format(t.name, d or -1, str(t.misses),
                t.height and ("height " .. t.height) or "level", candidates(n)))
            cw.changes = (cw.changes or 0) + 1
        else
            cwNote("none", "no target; candidates: " .. candidates(n))
        end
        cw.target = t
    end
    local shownNow = yes(ask(T.root, "IsShown"))
    if shownNow ~= cw.shown then
        local d = t and select(2, bearing(t.north, t.west))   -- the distance, bearing's second value
        cwNote(shownNow and "shown" or "hidden", t and ("%s at %.1f yd"):format(t.name, d or -1) or "no target")
        cw.shown = shownNow
    end
end)

local function lastEvent(kind, since)
    for i = #cw.events, 1, -1 do
        local e = cw.events[i]
        if e.kind == kind and e.at >= since then return e end
    end
end

local function ringShown()
    local n = nr()
    local T = n and n.Compass and n.Compass._test
    return T and yes(ask(T.root, "IsShown"))
end

Probe:Steps("compass3", {
    rev = 1,
    title = "The compass, third round: the nearest node (#29)",
    { text = "Have NodeRadar loaded and gathering tracking on, outdoors among herbs or ore. NodeRadar's compass "
          .. "goes on and its icons off (the compass alone), and both back as they were at the end.",
      wait = function()
          local n = nr()
          if not (n and n.Compass and n.Compass.Refresh) then return false, "NodeRadar (the nearest-node compass) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          compassOn(n, true, false)
          cw.events, cw.on, cw.changes, cw.target, cw.shown = {}, true, 0, nil, nil
          return true, "compass on, icons off"
      end },
    { text = "Ride among nodes until the ring shows under your character.", wait = function()
          if not ringShown() then return false, "no ring yet" end
          return true, "the ring up; candidates: " .. candidates(nr())
      end, screenshot = "compass3: the ring", timeout = 600 },
    { text = "Does it point at the nearest node you can gather? (Note box: which it pointed at, if not.)",
      ask = true },
    { text = "Gather the node it points at (it hides within 15 yards), then press Next once it points at the "
          .. "next one.", screenshot = "compass3: the next node" },
    { text = "After the gather, did it move on to the next nearest node?", ask = true },
    { text = "Ride on, gathering two or three more by the ring alone, then press Next.",
      screenshot = "compass3: riding on" },
    { text = "Riding, did it ever flick between two nodes about as far, or point somewhere odd? (Note box: "
          .. "what.)", ask = true },
    { text = "With the ring up, zoom the minimap in.", wait = function()
          local ok, zoom = pcall(Minimap.GetZoom, Minimap)
          zoom = ok and num(zoom)
          if zoom == nil then return false, "zoom unreadable" end
          state.cwZoom = state.cwZoom or zoom
          if zoom == state.cwZoom then return false, "zoom " .. zoom end
          state.cwZoom = nil
          return true, ("zoom %d; the ring %s; candidates: %s"):format(zoom, ringShown() and "up" or "DOWN",
              candidates(nr()))
      end, screenshot = "compass3: zoomed in" },
    { text = "After the zoom, is the ring still on a node you can see on the minimap?", ask = true },
    { text = "Optional: ride into a clump of one herb (several of a name close together). Press Next there.",
      screenshot = "compass3: a clump" },
    { text = "In the clump, was the ring still useful? (Note box: what it did.) Skip if you skipped.", ask = true },
    { text = "Walk up to a node until the ring hides, then walk away from it (not gathering) until it shows again.",
      wait = function()
          state.cwStart = state.cwStart or GetTime()
          local hid = lastEvent("hidden", state.cwStart)
          local back = hid and lastEvent("shown", hid.at)
          if not hid then return false, "walk up to the node" end
          if not back then return false, "hidden (" .. hid.text .. "): now walk away" end
          state.cwStart = nil
          return true, ("hidden at %s, shown again at %s"):format(hid.text, back.text)
      end, timeout = 300 },
    { text = "Optional: take a flight with nodes in view on the way. Skip if none is near.", wait = function()
          local ok, on = pcall(UnitOnTaxi, "player")
          if not (ok and yes(on)) then
              state.cwTaxi = nil
              return false, "not on a flight: UnitOnTaxi " .. str(on)
          end
          state.cwTaxi = (state.cwTaxi or 0) + 1
          if state.cwTaxi < 3 then return false, "flying" end
          state.cwTaxi = nil
          state.cwFlew = true
          return true, "UnitOnTaxi true on the flight; the ring " .. (ringShown() and "UP" or "down")
      end },
    { text = "Land (or let the flight finish).", wait = function()
          if not state.cwFlew then return true, "no flight taken" end
          local ok, on = pcall(UnitOnTaxi, "player")
          if ok and on == false then
              state.cwFlew = nil
              return true, "UnitOnTaxi false after landing"
          end
          return false, "on the flight: UnitOnTaxi " .. str(on)
      end },
    { text = "The cost, the compass alone: ride a loop past nodes for a minute (the step starts when you move).",
      wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          if not (cost.on and cost.label == "compass3") then
              if not moving() then return false, "start riding the loop" end
              compassOn(n, true, false)
              costStart(n, "compass3")
          end
          local left = COST_SECONDS - (GetTime() - cost.t0)
          if left > 0 then return false, ("%.0f s left"):format(left) end
          return true, costStop(n)
      end, timeout = 300 },
    { text = "Putting NodeRadar's compass and icons back.", auto = true, run = function()
          cw.on = false
          local db = iconsDB()
          db.compass3 = { events = cw.events, changes = cw.changes }
          return compassBack() .. "; " .. cw.changes .. " target changes"
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- The compass's look (#29): /fp steps nr compasslook
--------------------------------------------------------------------------------

-- Drafts of a glass compass over NodeRadar's own target (its ring hidden
-- meanwhile): a LibGlass disc (Glass MiniMap's recipe), the node's item icon
-- in the middle, Blizzard's triangle on the rim, the distance in a glass pill
-- under it. LibGlass is the copy Glass MiniMap loaded, as in the glass round.
-- Its own function: the chunk is at Lua 5.1's 200 locals (a do-block's still count).
;(function()
local GMM_MEDIA = "Interface\\AddOns\\GlassMiniMap\\Media\\"
local CLOOKS = {
    A = { size = 96, text = "a glass ring 96 units, the icon, a pill" },
    B = { size = 96, gmm = true, text = "the same with Glass MiniMap's own ring art" },
    C = { size = 72, text = "a smaller glass ring, 72 units" },
    -- Round 2 (the owner: C, "smaller is better"; B's art "looks nice"; "the ring to the size of the
    -- icon and the arrow outside"; the item's tooltip on hover): a disc just around the icon.
    D = { size = 44, icon = 30, out = true, gmm = true, tip = true,
          text = "a disc just around the icon (44), the arrow outside, Glass MiniMap's ring art" },
    E = { size = 44, icon = 30, out = true, tip = true, text = "the same with the plain glass rim" },
    F = { size = 36, icon = 24, out = true, gmm = true, tip = true, text = "smaller still (36), Glass MiniMap's art" },
}
-- The item a record gives (NodeRadar's NODE_INFO), for the tooltip.
local function itemOf(t)
    local n = nr()
    local info = n and t and n.Learn.Info(t.name)
    return info and num(info.item)
end
local cl = { built = {}, key = nil }
local clFrame = CreateFrame("Frame")

local function nrRing()
    local n = nr()
    return n and n.Compass and n.Compass._test.root
end

local function buildCLook(key)
    if cl.built[key] ~= nil then return cl.built[key] or nil end
    local spec, inst = CLOOKS[key], glassInst("clean")
    if not inst then cl.built[key] = false; return nil end
    local s = spec.size
    local host = CreateFrame("Frame", nil, UIParent)
    host:Hide()
    host:SetSize(s, s)
    host:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
    host:EnableMouse(spec.tip == true)                    -- the tooltip looks take the mouse, on the disc only
    if spec.tip then
        host:SetScript("OnEnter", function(self)
            local item = itemOf(cl.target)
            if not item then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local okTip, errTip = pcall(GameTooltip.SetItemByID, GameTooltip, item)
            if not okTip then say("compasslook tooltip: ERROR " .. str(errTip)) end
            GameTooltip:Show()
        end)
        host:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local ok, err = pcall(function()
        local g = inst.Disc(host, s >= 96 and "disc" or "disc_small")
        if g.top then g.top:EnableMouse(false) end
        if spec.gmm then
            g.rim:SetTexture(GMM_MEDIA .. "ring_rim")
            g.dark:SetTexture(GMM_MEDIA .. "ring_dark")
        end
        local icon = host:CreateTexture(nil, "ARTWORK")
        local iconSize = spec.icon or s * 0.42
        icon:SetSize(iconSize, iconSize)
        icon:SetPoint("CENTER", host, "CENTER")
        local mask = host:CreateMaskTexture()
        mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local over = CreateFrame("Frame", nil, host)          -- the arrow over the glass's top (host + 10)
        over:SetAllPoints(host)
        over:SetFrameLevel(host:GetFrameLevel() + 12)
        over:EnableMouse(false)
        local arrowTex = over:CreateTexture(nil, "OVERLAY")
        local arrowSize = spec.out and 12 or s * 0.24
        arrowTex:SetSize(arrowSize, arrowSize)
        arrowTex:SetTexture(ARROWS_FILE)
        arrowTex:SetTexCoord(0, 1, 0, 0.5)
        local pill = CreateFrame("Frame", nil, host)
        pill:SetSize(64, 22)
        pill:SetPoint("TOP", host, "BOTTOM", 0, -4)
        pill:EnableMouse(false)
        local pg = inst.Apply(pill, "small")
        if pg.top then pg.top:EnableMouse(false) end
        local fs = inst.Font(pg.top or pill, 13, "CENTER")
        fs:SetPoint("CENTER", pill, "CENTER")
        cl.built[key] = { host = host, icon = icon, arrow = arrowTex, text = fs,
                          radius = spec.out and s / 2 + 8 or s / 2 - s * 0.1 }
    end)
    if not ok then
        say("compasslook " .. key .. ": ERROR " .. str(err))
        cl.built[key] = false
        return nil
    end
    return cl.built[key]
end

-- Each frame while a look is on: NodeRadar's target, its icon, the arrow, the distance.
local function clSync()
    local n = nr()
    local t = n and n.Compass and n.Compass._test.target()
    local ring = nrRing()
    for key, d in pairs(cl.built) do
        if d and key ~= cl.key then d.host:Hide() end
    end
    local d = cl.key and buildCLook(cl.key)
    if not d then return end
    if ring then ring:SetAlpha(0) end
    local f = facing()
    local b, dist
    if t then b, dist = bearing(t.north, t.west) end
    cl.target = t
    if not (t and b and f) then d.host:Hide(); return end
    local a = wrap(b - f)
    d.arrow:ClearAllPoints()
    d.arrow:SetPoint("CENTER", d.host, "CENTER", -d.radius * math.sin(a), d.radius * math.cos(a))
    d.arrow:SetRotation(a)
    d.icon:SetTexture(t.icon)
    d.text:SetText(("%d yd"):format(dist + 0.5))
    d.host:Show()
end

local function clLook(key)
    cl.key = key
    clSync()
    clFrame:SetScript("OnUpdate", key and clSync or nil)
    if not key then
        for _, d in pairs(cl.built) do if d then d.host:Hide() end end
        local ring = nrRing()
        if ring then ring:SetAlpha(1) end
    end
end

local function clShown(key)
    return function()
        if cl.key ~= key then clLook(key) end
        local d = cl.built[key]
        if d == false then return false, "this look failed to build (see the log)" end
        if not (d and yes(ask(d.host, "IsShown"))) then return false, "no target: ride until a node is in view" end
        return true, ("look %s on %s"):format(key, str(d.text:GetText()))
    end
end

local clSteps = {
    rev = 1,
    title = "The compass's look: a glass ring, the icon, a pill (#29)",
    { text = "Have NodeRadar loaded with gathering tracking on, and Glass MiniMap on. NodeRadar's compass goes "
          .. "on (your icons setting kept), and back as it was at the end.", wait = function()
          local n = nr()
          if not (n and n.Compass and n.Compass.Refresh) then return false, "NodeRadar (the compass) isn't loaded" end
          local lib, minor = libGlass()
          if not lib then return false, "LibGlass-1.0 isn't loaded (turn Glass MiniMap on)" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          compassOn(n, true, n.db.icons)
          return true, "compass on, LibGlass-1.0 minor " .. str(minor)
      end },
    { text = "Ride until NodeRadar's ring shows (today's look, for comparison), then stand still.",
      wait = function()
          clLook(nil)
          if not ringShown() then return false, "no ring yet" end
          return true, "today's ring up"
      end, screenshot = "compasslook: today's ring", timeout = 600 },
}
for _, key in ipairs({ "A", "B", "C" }) do
    table.insert(clSteps, { text = "Look " .. key .. ": " .. CLOOKS[key].text .. ". Stay still.", wait = clShown(key),
                            screenshot = "compasslook: look " .. key })
    table.insert(clSteps, { text = "Look " .. key .. " (" .. CLOOKS[key].text .. "): do you like it? Note box: what "
                                .. "you'd change (size, the icon, the pill, the arrow).", ask = true })
end
for _, st in ipairs({
    { text = "Which look did you like best? Type its letter in the Note box (A, B, C, or today's).", ask = true },
    { text = "Look A again: ride to a node or two by it, until this step completes.", wait = function()
          if cl.key ~= "A" then clLook("A") end
          if not moving() then state.clRun = nil; return false, "not moving" end
          state.clRun = (state.clRun or 0) + 1
          if state.clRun < 5 then return false, "riding with look A" end
          state.clRun = nil
          return true, "rode with look A"
      end, screenshot = "compasslook: riding" },
    { text = "Riding, was it readable over the ground, at a glance? (Note box: anything.)", ask = true },
    { text = "Taking the drafts down, NodeRadar's compass back.", auto = true, run = function()
          clLook(nil)
          return compassBack()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}) do table.insert(clSteps, st) end
Probe:Steps("compasslook", clSteps)

local cl2Steps = {
    rev = 1,
    title = "The compass's look, second round: a disc around the icon, the arrow outside, a tooltip (#29)",
    clSteps[1],
    { text = "Ride until NodeRadar's ring shows, then stand still.", wait = clSteps[2].wait, timeout = 600 },
}
for _, key in ipairs({ "D", "E", "F" }) do
    table.insert(cl2Steps, { text = "Look " .. key .. ": " .. CLOOKS[key].text .. ". Stay still.", wait = clShown(key),
                             screenshot = "compasslook2: look " .. key })
    table.insert(cl2Steps, { text = "Look " .. key .. " (" .. CLOOKS[key].text .. "): do you like it? Note box: "
                                 .. "what you'd change.", ask = true })
end
for _, st in ipairs({
    { text = "Which look did you like best? Type its letter in the Note box (D, E, F, or round 1's C).", ask = true },
    { text = "Look D again: hold the mouse on the icon.", wait = function()
          if cl.key ~= "D" then clLook("D") end
          local d = cl.built.D
          if not (d and yes(ask(d.host, "IsMouseOver"))) then return false, "the mouse isn't on the icon" end
          if not yes(ask(rawget(_G, "GameTooltip"), "IsShown")) then return false, "on the icon, no tooltip yet" end
          return true, "the tooltip shows " .. str(ask(rawget(_G, "GameTooltipTextLeft1"), "GetText"))
      end, screenshot = "compasslook2: the tooltip" },
    { text = "Is that the item's tooltip (the herb or ore it gives)?", ask = true },
    { text = "With look D up, click the ground or a creature right next to the disc (not on it). Did the click "
          .. "reach the world?", ask = true },
    { text = "Look D: ride to a node or two by it, until this step completes.", wait = function()
          if cl.key ~= "D" then clLook("D") end
          if not moving() then state.clRun = nil; return false, "not moving" end
          state.clRun = (state.clRun or 0) + 1
          if state.clRun < 5 then return false, "riding with look D" end
          state.clRun = nil
          return true, "rode with look D"
      end, screenshot = "compasslook2: riding" },
    { text = "Riding, was the arrow outside the disc easy to read? (Note box: anything.)", ask = true },
    { text = "Taking the drafts down, NodeRadar's compass back.", auto = true, run = function()
          clLook(nil)
          return compassBack()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}) do table.insert(cl2Steps, st) end
Probe:Steps("compasslook2", cl2Steps)
end)()

--------------------------------------------------------------------------------
-- The compass's look, NodeRadar's own (#29): /fp steps nr compass4
--------------------------------------------------------------------------------

;(function()
-- NodeRadar's compass, its size and the icons' frame, raw, put back at the end.
local function c4On(n, size, style)
    if NodeRadarProbeDB.restoreC4 == nil then
        NodeRadarProbeDB.restoreC4 = { compass = rawget(n.db, "compass"), size = rawget(n.db, "compassSize"),
                                       style = rawget(n.db, "iconStyle") }
    end
    if n.db.compass ~= true then n.Set("compass", true) end
    if size ~= nil and n.db.compassSize ~= size then n.Set("compassSize", size) end
    if style ~= nil and n.db.iconStyle ~= style then n.Set("iconStyle", style) end
end

local function c4Back()
    local n, saved = nr(), NodeRadarProbeDB.restoreC4
    if not (n and saved) then return "nothing to put back" end
    n.Set("iconStyle", saved.style)
    n.Set("compassSize", saved.size)
    n.Set("compass", saved.compass)
    NodeRadarProbeDB.restoreC4 = nil
    return ("put back: compass %s, size %s, style %s"):format(str(saved.compass), str(saved.size), str(saved.style))
end

local function c4()
    local n = nr()
    return n and n.Compass and n.Compass._test
end

-- Which look is up, at what size: "glass medium".
local function c4Text()
    local T, n = c4(), nr()
    local style = T and T.style and T.style() or "none"                -- the refined look: the rim's style
    return ("%s %s"):format(style, str(n and n.db.compassSize))
end

-- Waits until the compass is up in that size and style (`want` the style shown).
local function c4Shown(size, style, want)
    return function()
        local n, T = nr(), c4()
        if not (n and T and T.style) then return false, "NodeRadar (the compass's look) isn't loaded" end
        c4On(n, size, style)
        if not yes(ask(T.root, "IsShown")) then return false, "the compass isn't up: ride until a node is in view" end
        local text = c4Text()
        if want and not text:find("^" .. want) then return false, "up as " .. text .. ", not " .. want end
        return true, text
    end
end

local steps4 = {
    rev = 1,
    title = "The compass's look, NodeRadar's own (#29)",
    { text = "Have NodeRadar loaded with gathering tracking on, and Glass MiniMap on. NodeRadar's compass goes "
          .. "on; its size and the icons' frame setting come back as they were at the end.", wait = function()
          local n, T = nr(), c4()
          if not (n and T and T.style) then return false, "NodeRadar (the compass's look) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          c4On(n, "medium", "auto")
          return true, "compass on, medium, following the minimap"
      end },
    { text = "Ride until the compass shows under your character, then stand still.",
      wait = c4Shown("medium", "auto", "glass"), screenshot = "compass4: glass medium", timeout = 600 },
    { text = "Glass, medium: the icon in its disc, the arrow outside, the distance below. Like it? (Note box.)",
      ask = true },
    { text = "Small.", wait = c4Shown("small", "auto", "glass"), screenshot = "compass4: glass small" },
    { text = "Large.", wait = c4Shown("large", "auto", "glass"), screenshot = "compass4: glass large" },
    { text = "Did the three sizes look right? (Note box: which you'd keep.)", ask = true },
    { text = "Bronze (the icons' frame set to bronze).", wait = c4Shown("medium", "bronze", "bronze"),
      screenshot = "compass4: bronze" },
    { text = "No frame (the icon alone).", wait = c4Shown("medium", "plain", "plain"),
      screenshot = "compass4: no frame" },
    { text = "Did bronze and the icon alone look right? (Note box.)", ask = true },
    { text = "Back to glass. Hold the mouse on the compass's icon.", wait = function()
          local ok, why = c4Shown("medium", "auto", "glass")()
          if not ok then return false, why end
          local T = c4()
          local tip = rawget(_G, "GameTooltip")
          local okO, owner = pcall(tip.GetOwner, tip)
          if not (okO and owner == T.disc and yes(ask(tip, "IsShown"))) then return false, "no tooltip from the compass yet" end
          return true, "the tooltip shows " .. str(ask(rawget(_G, "GameTooltipTextLeft1"), "GetText"))
      end, screenshot = "compass4: the tooltip" },
    { text = "Is that the item's tooltip (the herb or ore the node gives)?", ask = true },
    { text = "Left-click a creature or the ground right ON the compass's icon, then right-click there too. Did "
          .. "both clicks reach the world (targeting, moving, interacting)?", ask = true },
    { text = "Start a camera drag (hold the left or right mouse button) with the cursor ON the compass's icon. "
          .. "Did the camera turn?", ask = true },
    { text = "Turn so the node is behind you (the arrow at the bottom), and hold still.", wait = function()
          local n, T = nr(), c4()
          local t = T and T.target()
          if not t then return false, "no target" end
          local b = bearing(t.north, t.west)
          local f = facing()
          if not (b and f) then return false, "unreadable" end
          local a = wrap(b - f)
          if math.abs(a) < 2.6 then return false, ("the node %.1f rad from straight ahead: turn away"):format(a) end
          return true, ("the node %.1f rad from straight ahead"):format(a)
      end, screenshot = "compass4: pointing behind" },
    { text = "Pointing behind, is the arrow clear of the distance pill?", ask = true },
    { text = "Open Edit Mode (Esc > Edit Mode) with the compass up, then close it. Any error or anything odd?",
      ask = true },
    { text = "Optional: fight a creature with the compass up. Any error or 'action blocked' message?", ask = true },
    { text = "Ride to a node or two by the compass, until this step completes.", wait = function()
          if not moving() then state.c4Run = nil; return false, "not moving" end
          state.c4Run = (state.c4Run or 0) + 1
          if state.c4Run < 5 then return false, "riding" end
          state.c4Run = nil
          return true, "rode with " .. c4Text()
      end, screenshot = "compass4: riding" },
    { text = "Riding, was it readable at a glance? (Note box: anything.)", ask = true },
    { text = "Putting NodeRadar's compass, its size and the icons' frame back.", auto = true, run = c4Back },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("compass4", steps4)

-- Round 5: the refined look (our own art), the critique's checks.
local function c4Angle()
    local T = c4()
    local t = T and T.target()
    if not t then return nil end
    local b = bearing(t.north, t.west)
    local f = facing()
    if not (b and f) then return nil end
    return wrap(b - f)
end
local function headingStep(label, want, style, round)
    return { text = "Turn so the node is " .. label .. " of you, and hold still until the next step shows.",
             wait = function()
                 local ok, why = c4Shown("medium", style or "auto")()
                 if not ok then return false, why end
                 local a = c4Angle()
                 if not a then return false, "no target" end
                 if math.abs(wrap(a - want)) > 0.3 then
                     return false, ("the node %.1f rad from straight ahead (%s: %.1f)"):format(a, label, want)
                 end
                 return true, ("%s: %.2f rad"):format(label, a)
             end, screenshot = (round or "compass5") .. ": " .. label }
end
local steps5 = {
    rev = 1,
    title = "The compass refined: a lens, a pearl or bronze rim, a bigger arrow, an arc (#29)",
    steps4[1],
    { text = "Ride until the compass shows under your character, then stand still.",
      wait = c4Shown("medium", "auto", "glass"), screenshot = "compass5: pearl medium", timeout = 600 },
    { text = "The refined compass (pearl): the lens, the thin rim, the arrow and its arc, the capsule. Like it? "
          .. "(Note box.)", ask = true },
    { text = "Small.", wait = c4Shown("small", "auto", "glass"), screenshot = "compass5: pearl small" },
    { text = "Large.", wait = c4Shown("large", "auto", "glass"), screenshot = "compass5: pearl large" },
    { text = "Bronze.", wait = c4Shown("medium", "bronze", "bronze"), screenshot = "compass5: bronze" },
    { text = "No frame (the lens and the icon).", wait = c4Shown("medium", "plain", "plain"),
      screenshot = "compass5: no frame" },
    { text = "Did each size and each frame look right, the small one's edges included? (Note box.)", ask = true },
    headingStep("straight ahead", 0),
    headingStep("on the left", math.pi / 2),
    headingStep("behind-right (a diagonal)", -3 * math.pi / 4),
    headingStep("behind", math.pi),
    { text = "Through those turns, did the arrow and the arc stay together and point right, the icon and the "
          .. "capsule still? Is the arrow clear of the capsule behind? (Note box.)", ask = true },
    { text = "Stand on bright ground with the compass up, then press Next.", screenshot = "compass5: bright ground" },
    { text = "Now somewhere dark (a cave, a building, or at night), then press Next. Skip if none is near.",
      screenshot = "compass5: dark" },
    { text = "Was it readable on both? (Note box.)", ask = true },
    { text = "With a node far away (100 yards or more), then press Next.", screenshot = "compass5: far" },
    { text = "Does the three-digit distance fit the capsule?", ask = true },
    { text = "Optional: an ore node (if this character mines), then press Next. Skip if not.",
      screenshot = "compass5: ore" },
    { text = "Hold the mouse on the compass's icon.", wait = function()
          local ok, why = c4Shown("medium", "auto")()
          if not ok then return false, why end
          local T = c4()
          local tip = rawget(_G, "GameTooltip")
          local okO, owner = pcall(tip.GetOwner, tip)
          if not (okO and owner == T.disc and yes(ask(tip, "IsShown"))) then return false, "no tooltip from the compass yet" end
          return true, "the tooltip shows " .. str(ask(rawget(_G, "GameTooltipTextLeft1"), "GetText"))
      end, screenshot = "compass5: the tooltip" },
    { text = "Is that the item's tooltip, and did hovering leave the compass's look unchanged?", ask = true },
    { text = "Left-click and right-click ON the icon, and start a camera drag there. Did all of it reach the world?",
      ask = true },
    { text = "Edit Mode in and out, and optionally a fight, with the compass up. Any error or anything odd?",
      ask = true },
    { text = "Ride to a node or two by the compass, until this step completes.", wait = steps4[18].wait,
      screenshot = "compass5: riding" },
    { text = "Riding, was it readable at a glance? (Note box: anything.)", ask = true },
    { text = "Putting NodeRadar's compass, its size and the icons' frame back.", auto = true, run = c4Back },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("compass5", steps5)

-- The yellow frame (#50): the dots' colour measured, the icons and the
-- compass in yellow, the narrower arrow at the diagonals.
local yellowSteps = {
    rev = 1,
    title = "A yellow frame, the tracking dots' colour, and a narrower compass arrow (#50)",
    { text = "Have NodeRadar loaded with gathering tracking on. NodeRadar's icons go off for a moment (to see "
          .. "Blizzard's dots), then on in yellow, and its compass on; your settings come back at the end.",
      wait = function()
          local n, T = nr(), c4()
          if not (n and T and T.style and n.Icons.STYLES.yellow) then return false, "NodeRadar (#50) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          lookOn(n, "yellow", "medium")
          n.Set("icons", false)
          c4On(n, "medium", "yellow")
          return true, "icons off for the dots, the frame yellow, the compass on"
      end },
    { text = "Stand still where a few herb or ore dots show on the minimap (Blizzard's yellow dots: NodeRadar's "
          .. "icons are off), then press Next.", screenshot = "yellow: the dots" },
    { text = "Now NodeRadar's icons in yellow, medium: stay still until they cover the dots.",
      wait = showLook("yellow", "medium", "yellow"), screenshot = "yellow: medium" },
    { text = "Small.", wait = showLook("yellow", "small", "yellow"), screenshot = "yellow: small" },
    { text = "Large.", wait = showLook("yellow", "large", "yellow"), screenshot = "yellow: large" },
    { text = "Does the rings' yellow match the dots you just saw, and does it read at each size? (Note box: "
          .. "lighter, darker, more orange, thicker...)", ask = true },
    { text = "Optional: a node above or below you, until NodeRadar's small arrow shows by its ring. Skip if none.",
      wait = function()
          local n = nr()
          if n then lookOn(n, "yellow", "medium") end
          local r = shownWhere(function(r) return r.height ~= nil end)
          if not r then return false, "no icon with an arrow yet" end
          return true, ("%s %s"):format(r.name, r.height)
      end, screenshot = "yellow: the height arrow" },
    { text = "Optional: a node your skill can't gather in view (dimmed). Skip if none.", wait = function()
          local r = shownWhere(function(r) return r.dim end)
          if not r then return false, "no dimmed icon in view" end
          return true, r.name .. " dimmed"
      end, screenshot = "yellow: dimmed" },
    { text = "Ride until the compass shows under your character, then stand still.",
      wait = c4Shown("medium", "yellow", "yellow"), screenshot = "yellow: the compass", timeout = 600 },
    { text = "The compass's rim in yellow: like it? (Note box.)", ask = true },
    headingStep("ahead-left", math.pi / 4, "yellow", "yellow"),
    headingStep("ahead-right", -math.pi / 4, "yellow", "yellow"),
    headingStep("behind-left", 3 * math.pi / 4, "yellow", "yellow"),
    headingStep("behind-right", -3 * math.pi / 4, "yellow", "yellow"),
    { text = "At those four slants, did the narrower arrow clearly point at the node?", ask = true },
    { text = "Putting NodeRadar's icons, compass, size and frame back.", auto = true, run = function()
          return c4Back() .. "; " .. lookBack()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("yellow", yellowSteps)

-- After a gather (the owner's video): the compass sampled every 0.25 s for 6 s
-- from the gather's success, with the loot window's state.
local watch = { samples = nil, t0 = nil }
local watcher = CreateFrame("Frame")
watcher:Hide()
local acc = 0
watcher:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 0.25 then return end
    acc = 0
    local n, T = nr(), c4()
    if not (n and T and watch.samples) then return end
    local t = T.target()
    local loot = rawget(_G, "LootFrame")
    watch.samples[#watch.samples + 1] = { at = GetTime() - watch.t0, shown = yes(ask(T.root, "IsShown")),
        target = t and t.name, loot = yes(ask(loot, "IsShown")) }
    if GetTime() - watch.t0 >= 6 then watcher:Hide() end
end)
local castFrame = CreateFrame("Frame")
pcall(castFrame.RegisterUnitEvent, castFrame, "UNIT_SPELLCAST_SUCCEEDED", "player")
castFrame:SetScript("OnEvent", function(_, _, _, _, spellID)
    local n = nr()
    if not (watch.armed and n and n.Learn.CastKind and n.Learn.CastKind(spellID)) then return end
    watch.armed = false
    watch.samples, watch.t0, acc = {}, GetTime(), 0
    watcher:Show()
end)

local function watchText()
    local parts, hidden = {}, 0
    for _, sm in ipairs(watch.samples) do
        if not sm.shown then hidden = hidden + 1 end
        parts[#parts + 1] = ("%.2f %s%s%s"):format(sm.at, sm.shown and "shown" or "hidden", sm.target and (" " .. sm.target) or "",
            sm.loot and " loot" or "")
    end
    return ("%d of %d samples hidden: %s"):format(hidden, #watch.samples, table.concat(parts, "; "))
end

local gatherSteps = {
    rev = 1,
    title = "The compass after a gather: on to the next node at once (#29)",
    steps4[1],
    { text = "Ride to a herb with the compass on it, gather it (leave the loot window open a couple of seconds), and "
          .. "wait: the step watches the compass for 6 s after the gather.", wait = function()
          if not watch.samples then watch.armed = true; return false, "waiting for a gather" end
          if GetTime() - watch.t0 < 6.2 then return false, "watching" end
          return true, watchText()
      end, timeout = 900 },
    { text = "Right after the gather, did the compass stay on the next node (no hiding while the loot was open)?",
      ask = true },
    { text = "Putting NodeRadar's compass back.", auto = true, run = function()
          watch.samples, watch.armed = nil, false
          return c4Back()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("gather", gatherSteps)

-- Moving it (#57): Alt-drag, as Apotheca.
local function moveSaved()
    local n = nr()
    return n and n.db and { x = rawget(n.db, "compassX"), y = rawget(n.db, "compassY"), lock = rawget(n.db, "compassLock") }
end
local function moveText()
    local n, T = nr(), c4()
    if not (n and T) then return "not loaded" end
    local okP, point, rel, _, px, py = pcall(T.root.GetPoint, T.root, 1)
    return ("saved %s, %s; anchored %s %s, %s; locked %s"):format(str(n.db.compassX), str(n.db.compassY),
        str(okP and point), str(okP and px), str(okP and py), str(n.db.compassLock))
end
local moveSteps = {
    rev = 1,
    title = "Moving the compass with Alt-drag (#57)",
    { text = "Have NodeRadar loaded with gathering tracking on. NodeRadar's compass goes on; its place, lock, size "
          .. "and the icons' frame come back as they were at the end.", wait = function()
          local n, T = nr(), c4()
          if not (n and T and T.grip and n.Compass.ResetPosition) then return false, "NodeRadar (#57) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          if NodeRadarProbeDB.restoreMove == nil then NodeRadarProbeDB.restoreMove = moveSaved() end
          c4On(n, "medium", "auto")
          if n.db.compassLock then n.Set("compassLock", false) end
          return true, moveText()
      end },
    { text = "Ride until the compass shows under your character, then stand still.",
      wait = c4Shown("medium", "auto"), timeout = 600 },
    { text = "Hold the mouse on the compass's icon without Alt (its tooltip), then hold Alt.", wait = function()
          local T = c4()
          if not (T and yes(ask(T.grip, "IsShown"))) then return false, "no grip yet: hold Alt over the compass" end
          return true, "the grip is up; the tooltip " .. (yes(ask(rawget(_G, "GameTooltip"), "IsShown")) and "still shown"
              or "gone")
      end, screenshot = "compassmove: the grip" },
    { text = "Does \"Drag to move\" cover the compass while Alt is held, and go away when you let go of Alt?",
      ask = true },
    { text = "Hold Alt and drag the compass somewhere else on the screen, then let go.", wait = function()
          local n, T = nr(), c4()
          if not (n and T) then return false, "NodeRadar isn't loaded" end
          if n.db.compassX == nil or T.dragging() then return false, "not moved yet" end
          return true, moveText()
      end, screenshot = "compassmove: moved" },
    { text = "Type /reload (or press Reload now): it should come back where you left it.", reload = true },
    { text = "Ride until the compass shows again.", wait = function()
          local ok, why = c4Shown("medium", "auto")()
          if not ok then return false, why end
          return true, moveText()
      end, screenshot = "compassmove: after the reload", timeout = 600 },
    { text = "Is it where you left it?", ask = true },
    { text = "Hold Alt and drag it past the right edge of the screen, then let go.", wait = function()
          local n = nr()
          local w = n and ask(UIParent, "GetWidth")
          if not (n and w and n.db.compassX) then return false, "not dropped yet" end
          if n.db.compassX < w / 2 - 120 then return false, "not near the right edge yet: " .. str(n.db.compassX) end
          return true, moveText() .. "; the screen " .. str(w) .. " wide"
      end, screenshot = "compassmove: at the edge" },
    { text = "Did it come back fully on the screen?", ask = true },
    { text = "Hold Alt, start dragging it, and let go of Alt before the mouse button. Did it stop following the "
          .. "mouse when Alt went up?", ask = true },
    { text = "Type /nr compass lock, then hold Alt over the compass: nothing should appear.", wait = function()
          local n, T = nr(), c4()
          if not (n and T and n.db.compassLock) then return false, "not locked yet" end
          if not yes(IsAltKeyDown()) then return false, "locked: now hold Alt over it" end
          if yes(ask(T.grip, "IsShown")) then return false, "the grip is up though locked" end
          return true, "locked, Alt held: no grip"
      end },
    { text = "Type /nr compass reset: back under your character.", wait = function()
          local n = nr()
          if not n or n.db.compassX ~= nil then return false, "not reset yet" end
          return true, moveText()
      end, screenshot = "compassmove: reset" },
    { text = "Putting the compass's place, lock and settings back.", auto = true, run = function()
          local n, saved = nr(), NodeRadarProbeDB.restoreMove
          if n and saved then
              n.db.compassX, n.db.compassY = saved.x, saved.y
              n.Set("compassLock", saved.lock)
              n.Compass._test.place()
          end
          NodeRadarProbeDB.restoreMove = nil
          return c4Back() .. "; " .. moveText()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("compassmove", moveSteps)
end)()

--------------------------------------------------------------------------------
-- Choosing which herbs and ores (#47): /fp steps nr track
--------------------------------------------------------------------------------

;(function()
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

-- NodeRadar's icons, the skipped node's look, the compass and this character's
-- list, raw, put back by the last step.
local function trOn(n)
    if NodeRadarProbeDB.restoreTrack == nil then
        NodeRadarProbeDB.restoreTrack = { icons = rawget(n.db, "icons"), ignoredIcon = rawget(n.db, "ignoredIcon"),
                                          compass = rawget(n.db, "compass"), track = copy(n.charDb.track) }
    end
    if n.db.icons ~= true then n.Set("icons", true) end
    if n.db.compass ~= true then n.Set("compass", true) end
end

local function trBack()
    local n, saved = nr(), NodeRadarProbeDB.restoreTrack
    if not (n and saved) then return "nothing to put back" end
    n.charDb.track = copy(saved.track)
    n.Track.Load()
    n.Set("ignoredIcon", saved.ignoredIcon)
    n.Set("compass", saved.compass)
    n.Set("icons", saved.icons)
    NodeRadarProbeDB.restoreTrack = nil
    return ("put back: icons %s, skipped look %s, compass %s, the list"):format(str(saved.icons),
        str(saved.ignoredIcon), str(saved.compass))
end

local function pageOf(kind)
    local n = nr()
    local P = n and n.TrackOptions and n.TrackOptions._test
    return P and P[kind]
end

-- A page's rows: how many show the item's name, how many still a node's.
local function rowsText(kind)
    local ui = pageOf(kind)
    if not (ui and ui.built) then return "not built" end
    local named, fallback = 0, 0
    for _, r in ipairs(ui.rows) do
        if ask(r.name, "GetText") == r.row.nodes[1].name and #r.row.nodes >= 1 then
            fallback = fallback + 1
        else
            named = named + 1
        end
    end
    return ("%d rows: %d with the item's name, %d still a node's"):format(#ui.rows, named, fallback)
end

local function pageShown(kind, label)
    return function()
        local ui = pageOf(kind)
        if not ui then return false, "NodeRadar (#47) isn't loaded" end
        if not yes(ask(ui.panel, "IsVisible")) then return false, "the " .. label .. " page isn't open" end
        return true, rowsText(kind)
    end
end

-- The skipped list and the ranks, for the log.
local function listText(n)
    local T = n.Track
    local out = {}
    for _, kind in ipairs(T.KINDS) do
        local skipped = {}
        for _, row in ipairs(T.List(kind)) do
            if T.Ignored(row.item) then skipped[#skipped + 1] = T.ItemName(row) or row.nodes[1].name end
        end
        out[#out + 1] = ("%s (rank %s): %d of %d skipped%s"):format(kind, str(T.Rank(kind)), #skipped, #T.List(kind),
            #skipped > 0 and (": " .. table.concat(skipped, ", ")) or "")
    end
    return table.concat(out, "; ") .. "; smart " .. str(T.Smart())
end

local chosen   -- { name, item }: the herb near the player this round skips

local function presetStep(label, which, want)
    return { text = "On the Herbs page, press " .. label .. ".", wait = function()
                 local n = nr()
                 local T = n and n.Track
                 if not T then return false, "NodeRadar (#47) isn't loaded" end
                 local rank = T.Rank("herbs")
                 local ok = true
                 for _, row in ipairs(T.List("herbs")) do
                     local s = T.State(row, rank)
                     if T.Ignored(row.item) ~= want(s) then ok = false end
                 end
                 if not ok then return false, "the list isn't " .. which .. " yet" end
                 return true, listText(n)
             end, screenshot = "track: " .. which }
end

local steps = {
    rev = 1,
    title = "Choosing which herbs and ores, presets and smart (#47)",
    { text = "Have NodeRadar loaded with Find Herbs on. NodeRadar's icons and compass go on; they, the skipped "
          .. "nodes' look and this character's list come back as they were at the end.", wait = function()
          local n = nr()
          if not (n and n.Track and n.TrackOptions) then return false, "NodeRadar (#47) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          trOn(n)
          return true, listText(n)
      end },
    { text = "Open Esc > Options > AddOns. Is there a + beside NodeRadar, with Herbs and Ores under it? Open "
          .. "Herbs.", wait = pageShown("herbs", "Herbs"), screenshot = "track: Herbs" },
    { text = "Did Herbs show fully on this first visit (not blank): each herb's icon and name, and under it "
          .. "each node with the skill it needs in colour? Scroll to the bottom. (Note box.)", ask = true },
    { text = "Leave it open a few seconds (item names the client didn't have arrive), then press Count.",
      button = "Count", run = function() return rowsText("herbs") end },
    { text = "Open Ores.", wait = pageShown("ore", "Ores"), screenshot = "track: Ores" },
    { text = "Did Ores show right too?", ask = true },
    { text = "Smart is on (the default): with your Herbalism it keeps only what gives skill-ups, so herbs you "
          .. "can't gather yet are unchecked (red numbers), and grey ones too. Does the Herbs page show that?",
      ask = true },
    { text = "Close Options. Ride until a herb shows as an icon on the minimap, then stand still.", wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          for _, r in ipairs(iconRecords()) do
              local info = n.Learn.Info(r.name)
              if info and r.misses == 0 and not r.dim and yes(ask(r.frame, "IsShown")) then
                  chosen = { name = r.name, item = info.item }
                  return true, ("%s (item %d)"):format(r.name, info.item)
              end
          end
          return false, "no herb icon in view yet"
      end, screenshot = "track: before", timeout = 600 },
    { text = "Skipping that herb now: its icon should dim, and the compass leave it.", wait = function()
          local n = nr()
          if not (n and chosen) then return false, "no herb chosen" end
          if not n.Track.Ignored(chosen.item) then n.Track.Set(chosen.item, false) end
          local dimmed = false
          for _, r in ipairs(iconRecords()) do if r.name == chosen.name and r.dim then dimmed = true end end
          local t = n.Compass._test.target()
          if not dimmed then return false, "its icon isn't dimmed" end
          if t and t.name == chosen.name then return false, "the compass still points at it" end
          return true, ("%s dimmed; the compass on %s"):format(chosen.name, t and t.name or "nothing (hidden)")
      end, screenshot = "track: skipped, dimmed" },
    { text = "Is that herb's icon dimmed, and did the compass leave it (another node, or hidden)?", ask = true },
    { text = "Now with Blizzard's dot for a skipped node.", wait = function()
          local n = nr()
          if not (n and chosen) then return false, "no herb chosen" end
          if n.db.ignoredIcon ~= "dot" then n.Set("ignoredIcon", "dot") end
          for _, r in ipairs(iconRecords()) do
              if r.name == chosen.name then return false, "its record is still there" end
          end
          return true, chosen.name .. ": no record, Blizzard's dot"
      end, screenshot = "track: skipped, Blizzard's dot" },
    { text = "Is only Blizzard's dot left there for that herb (no icon)?", ask = true },
    { text = "Tracking it again, the dimmed look back: its icon returns at the next sweep.", wait = function()
          local n = nr()
          if not (n and chosen) then return false, "no herb chosen" end
          if n.db.ignoredIcon ~= "dim" then n.Set("ignoredIcon", "dim") end
          if n.Track.Ignored(chosen.item) then n.Track.Set(chosen.item, true) end
          for _, r in ipairs(iconRecords()) do
              if r.name == chosen.name and not r.dim and yes(ask(r.frame, "IsShown")) then
                  return true, chosen.name .. " back"
              end
          end
          return false, "its icon isn't back yet"
      end, screenshot = "track: tracked again" },
    { text = "Open the Herbs page again and keep it open for the next presses.", wait = pageShown("herbs", "Herbs") },
    presetStep("None", "none", function() return true end),
    presetStep("All I can gather", "all I can gather", function(s) return not (s == "up" or s == "grey") end),
    presetStep("Skill-ups only", "skill-ups only", function(s) return s ~= "up" end),
    presetStep("All", "all", function() return false end),
    { text = "Did the checkboxes follow each press?", ask = true },
    { text = "Uncheck Smart at the top of the page.", wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          if n.Track.Smart() then return false, "smart is still on" end
          return true, listText(n)
      end },
    { text = "Check Smart again: the list should go back to what gives skill-ups.", wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          if not n.Track.Smart() then return false, "smart is off" end
          return true, listText(n)
      end, screenshot = "track: smart again" },
    { text = "Did turning Smart back on uncheck the herbs you can't gather yet (and any grey)?", ask = true },
    { text = "Close Options, then put the mouse on a herb in the world (not on the minimap) for its tooltip, then "
          .. "press Next.", screenshot = "track: a node's tooltip" },
    { text = "Does that tooltip show the Herbalism needed in a colour? (Note box: the herb, the colour, and your "
          .. "Herbalism; it checks the colour lines.)", ask = true },
    { text = "Putting NodeRadar's icons, the skipped look, the compass and the list back.", auto = true, run = trBack },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("track", steps)

-- Round 2: the columns, a row's tooltip, smart off and on (each toggle logged),
-- and a node's own tooltip in the world read by the probe (round 1: Next can't
-- be pressed while hovering a node).
local realSetSmart
local function logSmart(n)
    if realSetSmart then return end
    realSetSmart = n.Track.SetSmart
    n.Track.SetSmart = function(on)
        say(("SMART %s (was %s)"):format(str(on), str(n.Track.Smart())))
        return realSetSmart(on)
    end
end
local function unlogSmart(n)
    if realSetSmart and n then n.Track.SetSmart = realSetSmart end
    realSetSmart = nil
end

-- The game's tooltip lines with their colours: "Earthroot [1.00 1.00 1.00] | ...".
local function tipLines()
    local out = {}
    for i = 1, 6 do
        local fs = rawget(_G, "GameTooltipTextLeft" .. i)
        local text = ask(fs, "GetText")
        if type(text) == "string" and text ~= "" then
            local ok, r, g, b = pcall(fs.GetTextColor, fs)
            out[#out + 1] = ok and ("%s [%.2f %.2f %.2f]"):format(text, r or -1, g or -1, b or -1) or text
        end
    end
    return table.concat(out, " | ")
end

local steps2 = {
    rev = 1,
    title = "Herbs and Ores in columns, smart again, a node's tooltip (#47)",
    { text = "Have NodeRadar loaded with Find Herbs on. Your list comes back as it was at the end.", wait = function()
          local n = nr()
          if not (n and n.Track and n.TrackOptions) then return false, "NodeRadar (#47) isn't loaded" end
          trOn(n)
          logSmart(n)
          return true, listText(n)
      end },
    { text = "Open Esc > Options > AddOns > NodeRadar > Herbs.", wait = pageShown("herbs", "Herbs"),
      screenshot = "track2: Herbs in columns" },
    { text = "Herbs in three columns: does every name fit, with its skill beside it? (Note box.)", ask = true },
    { text = "Hold the mouse on a herb's name in the list.", wait = function()
          local ui = pageOf("herbs")
          if not (ui and ui.built) then return false, "the Herbs page isn't built" end
          local owner = ask(rawget(_G, "GameTooltip"), "GetOwner")
          for _, r in ipairs(ui.rows) do
              if owner == r.cell and yes(ask(rawget(_G, "GameTooltip"), "IsShown")) then
                  return true, tipLines()
              end
          end
          return false, "no row's tooltip yet"
      end, screenshot = "track2: a row's tooltip" },
    { text = "Does the tooltip list that herb's node(s) with the skill each needs?", ask = true },
    { text = "Open Ores.", wait = pageShown("ore", "Ores"), screenshot = "track2: Ores in columns" },
    { text = "Ores right too? Hover Thorium Ore (bottom right): its veins at 245 and 275?", ask = true },
    { text = "Back to Herbs. Click Smart once to turn it off.", wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          if n.Track.Smart() then return false, "smart is still on" end
          return true, listText(n)
      end },
    { text = "Click it once more to turn it on, and wait.", wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          if not n.Track.Smart() then return false, "smart is off" end
          local ui = pageOf("herbs")
          return true, listText(n) .. "; the box " .. str(ui and ask(ui.smart, "GetChecked"))
      end, screenshot = "track2: smart on" },
    { text = "Is Smart ticked, with the herbs you can't gather yet unchecked?", ask = true },
    { text = "Close Options. Put the mouse on a herb in the world (not the minimap) and keep it there until this "
          .. "step completes.", wait = function()
          local n = nr()
          local tip = rawget(_G, "GameTooltip")
          if not (n and yes(ask(tip, "IsShown"))) then return false, "no tooltip" end
          if ask(tip, "GetOwner") == rawget(_G, "Minimap") then return false, "that's the minimap's tooltip" end
          local first = ask(rawget(_G, "GameTooltipTextLeft1"), "GetText")
          if not (type(first) == "string" and n.Learn.Kind(first)) then return false, "not a node's tooltip" end
          return true, ("Herbalism %s: %s"):format(str(n.Track.Rank("herbs")), tipLines())
      end, screenshot = "track2: a node's tooltip" },
    { text = "Putting your list back.", auto = true, run = function()
          local n = nr()
          unlogSmart(n)
          return trBack()
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("track2", steps2)
end)()

;(function()
-- What NodeRadar's icons hold now, against a fresh sweep: each blip, matched to
-- a record or not (and why not: skipped, a failed measure waiting, too near the
-- rim), each record, each failed try. For "icons and dots side by side".
local function iconsDump()
    local n = nr()
    if not (n and n.Icons and n.Icons._test) then say("icons: NodeRadar isn't loaded"); return end
    local T = n.Icons._test
    local okP, pn, pw, _, inst = pcall(UnitPosition, "player")
    say(("icons: on %s, keeping %s, look %s; at %s %s instance %s; skipped look %s"):format(str(n.Icons.On()),
        str(n.Icons.Keeping()), str(T.look().style), str(okP and pn), str(okP and pw), str(okP and inst),
        str(n.db.ignoredIcon)))
    local result = n.Scan.Sweep(function(name) return n.Learn.Kind(name) and true or false end)
    if not result then say("icons: the sweep failed"); return end
    local g, where = result.geometry, result.where
    local k = where and g and where.radius / (g.w / 2)
    for _, b in ipairs(result.blips) do
        if n.Learn.Kind(b.name) then
            local near, nearD
            for _, r in ipairs(T.records()) do
                if r.name == b.name and k and okP then
                    local rx, ry = -(r.west - pw) / k, (r.north - pn) / k
                    local d = math.sqrt((rx - b.x) ^ 2 + (ry - b.y) ^ 2)
                    if not nearD or d < nearD then near, nearD = r, d end
                end
            end
            say(("  blip %s at %+.1f %+.1f (%d cells, from the centre %.1f): nearest record %s; wanted %s, skipped %s"):format(
                b.name, b.x, b.y, b.cells or 0, math.sqrt(b.x ^ 2 + b.y ^ 2),
                nearD and ("%.1f units away"):format(nearD) or "none", str(n.Alert.Wanted(b.name)),
                str(n.Alert.Ignored(b.name))))
            -- No record of it: measured again now, and why it fails.
            if not (nearD and nearD <= n.Icons.MATCH) then
                local okC = n.Scan.Centre({ b })
                say(("    measured now: %s"):format(not okC and "the measure failed" or b.cx
                    and ("centre %+.1f %+.1f"):format(b.cx, b.cy) or tostring(b.why)))
            end
        end
    end
    for _, r in ipairs(T.records()) do
        say(("  record %s at %+.1f %+.1f: misses %s, dim %s, height %s, shown %s"):format(r.name, r.x or 0, r.y or 0,
            str(r.misses), str(r.dim), str(r.height), str(r.frame and ask(r.frame, "IsShown"))))
    end
    local now = GetTime()
    for _, t in ipairs(T.tries()) do
        say(("  failed measure %s: tried %.0f s ago, seen %.0f s ago"):format(t.name, now - t.at, now - t.seen))
    end
end
Probe:Command("icons", function() iconsDump() end, "NodeRadar's icons against a fresh sweep")
end)()

;(function()
--------------------------------------------------------------------------------
-- The navigation frame as an anchor for a far-node marker (#61): Forever
-- draws no waypoint marker (the waypoint round), but art of our own could be
-- anchored to C_Navigation.GetFrame() with showInGameNavigation set. Does that
-- frame follow the node's spot on screen, with the CVar as it is and with it on?
-- Our own marker (a gold square) is anchored to it, and both are read.
--------------------------------------------------------------------------------

local mark                       -- our gold square on the navigation frame
local function markOn()
    local nav = wpRead(C_Navigation.GetFrame)
    if nav == nil or type(nav) == "string" then return nil, "no navigation frame" end
    if not mark then
        mark = CreateFrame("Frame", nil, UIParent)
        mark:SetSize(24, 24)
        mark:SetFrameStrata("HIGH")
        local t = mark:CreateTexture(nil, "OVERLAY")
        t:SetAllPoints(mark)
        t:SetColorTexture(1, 0.82, 0, 0.85)
        local label = mark:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("BOTTOM", mark, "TOP", 0, 2)
        label:SetText("NodeRadar probe")
    end
    if mark.on ~= nav then
        mark:ClearAllPoints()
        local ok, err = pcall(mark.SetPoint, mark, "CENTER", nav, "CENTER", 0, 0)
        if not ok then return nil, "can't anchor to it: " .. str(err) end
        mark.on = nav
    end
    mark:Show()
    return true
end
local function markOff()
    if mark then mark:Hide(); mark.on = nil end
end

-- Where our square is on screen (from UIParent's centre), the CVar, the nav state.
local function markRead(label)
    local x, y = "?", "?"
    if mark and mark:IsShown() then
        local ok, cx, cy = pcall(mark.GetCenter, mark)
        local ux, uy = UIParent:GetCenter()
        if ok and num(cx) and num(cy) and ux and uy then x, y = ("%.0f"):format(cx - ux), ("%.0f"):format(cy - uy) end
    end
    local line = ("%s: our square at %s, %s from the screen's centre; showInGameNavigation %s; %s"):format(label, x, y,
        str(wpRead(C_CVar.GetCVar, "showInGameNavigation")), navState())
    say("marker " .. line)
    return line
end

local seenAt                     -- the square's x at the last read, to see it move
local markerSteps = {
    rev = 1,
    title = "Blizzard's navigation frame as an anchor for a marker on a far node (#61)",
    { text = "Remove any map waypoint you have and stop tracking quests on screen (super-track), so the "
          .. "waypoint is free. Your waypoint setting and the navigation option come back as they were.",
      wait = function()
          if NodeRadarProbeDB.markerCVar == nil then
              NodeRadarProbeDB.markerCVar = wpRead(C_CVar.GetCVar, "showInGameNavigation") or "unset"
          end
          return waypointFree()
      end },
    { text = "Stand still outdoors with a herb or ore 40-80 yards away on the minimap, facing it, then press Set.",
      button = "Set", run = function() return setOurs(nearestNode()) end },
    { text = "Putting our gold square on the navigation frame, the option as it was.", wait = function()
          local ok, why = markOn()
          if not ok then return false, why end
          return true, markRead("as it was")
      end, timeout = 8, screenshot = "marker: the option as it was" },
    { text = "Is the gold square (\"NodeRadar probe\") over the node out in the world, where the herb or ore is?",
      ask = true },
    { text = "Turning the in-game navigation option on (showInGameNavigation 1).", auto = true,
      run = function()
          local ok = wpRead(C_CVar.SetCVar, "showInGameNavigation", "1")
          markOff()
          return "SetCVar -> " .. str(ok)
      end },
    { text = "Reading again (a moment).", wait = function()
          local ok, why = markOn()
          if not ok then return false, why end
          seenAt = nil
          return true, markRead("the option on")
      end, timeout = 8, screenshot = "marker: the option on" },
    { text = "Now: is the gold square over the node? Do you also see Blizzard's own marker or a distance?",
      ask = true },
    { text = "Turn slowly a little to one side, so the node moves across your screen.", wait = function()
          if not (mark and mark:IsShown()) then markOn() end
          local ok, cx = pcall(mark.GetCenter, mark)
          cx = ok and num(cx)
          if not cx then return false, "the square isn't on screen" end
          if not seenAt then seenAt = cx; return false, "turn a little" end
          if math.abs(cx - seenAt) < 120 then return false, "turn a little more" end
          return true, markRead("turned")
      end, screenshot = "marker: turned" },
    { text = "Did the square stay on the node as it moved across the screen?", ask = true },
    { text = "Turn until the node is behind you.", wait = function()
          if wpRead(C_Navigation.WasClampedToScreen) == true then return true, markRead("behind") end
          return false, "not clamped yet"
      end, screenshot = "marker: behind" },
    { text = "Where is the square now? (Note box: at the screen's edge, gone, somewhere odd.)", ask = true },
    { text = "Optional: ride away until the node is 100 yards or more behind or around you, then face it.",
      wait = function()
          local d = num(wpRead(C_Navigation.GetDistance))
          if not d or d < 100 then return false, "distance " .. str(d) end
          return true, markRead("far")
      end, screenshot = "marker: far" },
    { text = "Far away, was the square still on the node? (Skip if you skipped the ride.)", ask = true },
    { text = "Putting everything back: our square off, the option as it was, our waypoint cleared.", auto = true,
      run = function()
          markOff()
          local was = NodeRadarProbeDB.markerCVar
          if was and was ~= "unset" then wpRead(C_CVar.SetCVar, "showInGameNavigation", was) end
          NodeRadarProbeDB.markerCVar = nil
          return clearOurs("tracking first") .. "; showInGameNavigation " .. str(wpRead(C_CVar.GetCVar,
              "showInGameNavigation"))
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("marker", markerSteps)
end)()

;(function()
--------------------------------------------------------------------------------
-- Snoozing the compass's node, the minimap button and its menu (#46):
-- /fp steps nr snooze
--------------------------------------------------------------------------------

local function snOn(n)
    if NodeRadarProbeDB.restoreSnooze == nil then
        NodeRadarProbeDB.restoreSnooze = { compass = rawget(n.db, "compass"), icons = rawget(n.db, "icons"),
                                           button = rawget(n.db, "minimapButton"), snoozeFor = rawget(n.db, "snoozeFor") }
    end
    if n.db.compass ~= true then n.Set("compass", true) end
    if n.db.icons ~= true then n.Set("icons", true) end
    if n.db.minimapButton ~= true then n.Set("minimapButton", true) end
end

local function snText(n)
    local record, name, yards = n.Compass.Target()
    local dimmed = 0
    for _, r in ipairs(iconRecords()) do if r.dim then dimmed = dimmed + 1 end end
    return ("the compass on %s%s; %d snoozed; %d icons dimmed"):format(str(name), yards and (", " .. yards .. " yd") or "",
        n.Compass.SnoozeCount(), dimmed)
end

local before      -- the compass's node when the snooze step began
local steps = {
    rev = 2,
    title = "Snoozing the compass's node; the minimap button and its menu (#46)",
    { text = "Have NodeRadar loaded with gathering tracking on. Its compass, icons and minimap button go on; they "
          .. "come back as they were at the end.", wait = function()
          local n = nr()
          if not (n and n.Minimap and n.Compass.Snooze) then return false, "NodeRadar (#46) isn't loaded" end
          if #tracking(true) == 0 then return false, "no gathering tracking on" end
          snOn(n)
          if not n.Minimap.Available() then return false, "no minimap button: the libraries didn't load?" end
          return true, "the button registered; " .. snText(n)
      end },
    { text = "Find NodeRadar's button around the minimap (a flower), drag it along the ring if you like, and hold "
          .. "the mouse on it for its tooltip.", wait = function()
          -- LibDBIcon shows its own tooltip (LibDBIconTooltip), the compartment GameTooltip.
          for _, name in ipairs({ "LibDBIconTooltip", "GameTooltip" }) do
              local first = ask(rawget(_G, name .. "TextLeft1"), "GetText")
              if yes(ask(rawget(_G, name), "IsShown")) and first == "NodeRadar" then
                  return true, "its tooltip is up (" .. name .. ")"
              end
          end
          return false, "no NodeRadar tooltip yet"
      end, screenshot = "snooze: the button's tooltip" },
    { text = "Is the button there, and does its tooltip say what the compass points at and what the clicks do?",
      ask = true },
    { text = "Ride until the compass points at a node with another one in view, then stand still.", wait = function()
          local n = nr()
          if not n then return false, "NodeRadar isn't loaded" end
          local record = n.Compass.Target()
          local count = 0
          for _, r in ipairs(iconRecords()) do if r.misses == 0 then count = count + 1 end end
          if not record then return false, "the compass has no node yet" end
          if count < 2 then return false, "only one node in view" end
          before = record
          return true, snText(n)
      end, timeout = 900 },
    { text = "Left-click NodeRadar's button: a menu. Choose \"Snooze ...\" > 15 minutes.", wait = function()
          local n = nr()
          if not (n and before) then return false, "no node noted" end
          if n.Compass.SnoozeCount() < 1 then return false, "nothing snoozed yet" end
          local now = n.Compass.Target()
          if now == before then return false, "the compass is still on the snoozed node" end
          return true, snText(n)
      end, screenshot = "snooze: snoozed" },
    { text = "Did the compass move on to another node, and is the snoozed node's icon dimmed on the minimap?",
      ask = true },
    { text = "Open the menu again and choose \"Clear snoozes\".", wait = function()
          local n = nr()
          if not n or n.Compass.SnoozeCount() > 0 then return false, "still snoozed" end
          return true, snText(n)
      end },
    { text = "In Esc > Options > Key Bindings, find NodeRadar's \"Snooze the compass's node\", bind a key, close "
          .. "the window and press it.", wait = function()
          local n = nr()
          if not n or n.Compass.SnoozeCount() < 1 then return false, "nothing snoozed yet" end
          return true, snText(n)
      end, timeout = 900 },
    { text = "Did the key snooze it (a line in chat saying for how long)? (Note box: anything.)", ask = true },
    { text = "In the button's menu, untick \"The compass (experimental)\", open the menu again, then tick it back. "
          .. "Did the menu say \"The compass is off\" in between?", ask = true },
    { text = "Right-click the button.", wait = function()
          local n = nr()
          local p = n and n.Options and n.Options._test and n.Options._test.panel
          if not yes(ask(p, "IsVisible")) then return false, "NodeRadar's Options page isn't open" end
          return true, "the Options page is open"
      end, screenshot = "snooze: right-click" },
    { text = "Optional: close Options, open the AddOns compartment (the button listing addons by the minimap) and "
          .. "click NodeRadar there. Did its menu open?", ask = true },
    { text = "Optional: with Glass MiniMap Bar loaded, did it collect NodeRadar's button? (Skip without it.)",
      ask = true },
    { text = "Snooze the compass's node once more (the menu or the key), then press Next.", wait = function()
          local n = nr()
          if not n or n.Compass.SnoozeCount() < 1 then return false, "nothing snoozed" end
          return true, snText(n)
      end },
    { text = "Type /reload (or press Reload now): the snooze should be gone after it.", reload = true },
    { text = "After the reload.", wait = function()
          local n = nr()
          if not (n and n.Compass) then return false, "NodeRadar isn't loaded" end
          return true, snText(n)
      end },
    { text = "Putting the compass, icons, button and the key's length back.", auto = true, run = function()
          local n, saved = nr(), NodeRadarProbeDB.restoreSnooze
          if not (n and saved) then return "nothing to put back" end
          n.Compass.ClearSnoozes()
          n.db.snoozeFor = saved.snoozeFor
          n.Set("minimapButton", saved.button)
          n.Set("icons", saved.icons)
          n.Set("compass", saved.compass)
          NodeRadarProbeDB.restoreSnooze = nil
          return ("put back: compass %s, icons %s, button %s"):format(str(saved.compass), str(saved.icons),
              str(saved.button))
      end },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
}
Probe:Steps("snooze", steps)
end)()

--------------------------------------------------------------------------------
-- Boot, and the events worth a line while the procedure runs
--------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED", "PLAYER_LOGIN", "MINIMAP_UPDATE_TRACKING", "MINIMAP_PING",
    "VIGNETTE_MINIMAP_UPDATED", "OBJECT_ENTERED_AOI", "OBJECT_LEFT_AOI", "SKILL_LINES_CHANGED", "UI_ERROR_MESSAGE",
    "USER_WAYPOINT_UPDATED", "SUPER_TRACKING_CHANGED", "NAVIGATION_FRAME_CREATED", "NAVIGATION_FRAME_DESTROYED",
    "NAVIGATION_DESTINATION_REACHED" })
-- The player's casts only: the target's name is what a gathering cast is
-- aimed at (the name-learning fallback, #7).
local okSent, errSent = pcall(boot.RegisterUnitEvent, boot, "UNIT_SPELLCAST_SENT", "player")
if not okSent then say("UNIT_SPELLCAST_SENT: ERROR " .. str(errSent)) end
-- A gather the client refuses (#26).
local okFailed, errFailed = pcall(boot.RegisterUnitEvent, boot, "UNIT_SPELLCAST_FAILED", "player")
if not okFailed then say("UNIT_SPELLCAST_FAILED: ERROR " .. str(errFailed)) end
boot:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        Probe:Ready()
        if type(NodeRadarProbeDB) ~= "table" then NodeRadarProbeDB = {} end
        if type(NodeRadarProbeDB.log) ~= "table" then NodeRadarProbeDB.log = {} end
        Probe:UseLog(NodeRadarProbeDB.log, MAX_LOG)
        NodeRadarProbeDB.loads = (NodeRadarProbeDB.loads or 0) + 1
        say("loaded (" .. NodeRadarProbeDB.loads .. " loads). /fp nr for the commands, /fp steps nr release for #3")
    elseif event == "PLAYER_LOGIN" then
        resumeLearning()                               -- a reload came between pause and resume
    elseif event == "OBJECT_ENTERED_AOI" or event == "OBJECT_LEFT_AOI" then
        aoi(event, a1)
    elseif event == "UNIT_SPELLCAST_SENT" then
        say(("UNIT_SPELLCAST_SENT spell=%s target=%s"):format(str(a4), str(a2)))
        -- A gather: where the player stands, within reach of the node (#27).
        local n = nr()
        if n and not secret(a4) and n.Learn.CastKind(a4) and type(a2) == "string" and not secret(a2) then
            state.lastGather = { name = a2, at = GetTime(), pos = playerPos() }
            gatherIcon(a2)                             -- #28: before the gather drops its record
            compassGather(a2)                          -- #29: the walk the compass led
        end
    elseif event == "UNIT_SPELLCAST_FAILED" then
        say(("UNIT_SPELLCAST_FAILED spell=%s"):format(str(a3)))
    elseif event == "UI_ERROR_MESSAGE" then
        -- The client's own text; the type is what a shipped check would use.
        say(("UI_ERROR_MESSAGE type=%s message=%s"):format(str(a1), str(a2)))
    elseif event == "USER_WAYPOINT_UPDATED" or event == "SUPER_TRACKING_CHANGED" or event == "NAVIGATION_FRAME_CREATED"
        or event == "NAVIGATION_FRAME_DESTROYED" or event == "NAVIGATION_DESTINATION_REACHED" then
        -- #29: which fire inside our own setters, which after, and arrival.
        state.wpEvents = state.wpEvents or {}
        if event == "NAVIGATION_DESTINATION_REACHED" then state.wpEvents.reached = true end
        say(("%s%s %s"):format(event, state.wpOurs and " (ours)" or "",
            event == "NAVIGATION_DESTINATION_REACHED" and ("isWaypoint=" .. str(a1)) or ""))
    elseif event == "SKILL_LINES_CHANGED" then
        say("SKILL_LINES_CHANGED: " .. skillText(skills(true)))
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

NS._test = { Probe = Probe, state = state, CONVENTIONS = CONVENTIONS, nearestNode = nearestNode, marks = marks }
