-- NodeRadarProbe: a throwaway measuring addon for NodeRadar (never shipped).
-- A ForeverProbe module (..\ForeverProbe\docs\GUIDE.md): its lines go to the
-- /fp console and NodeRadarProbeDB.log, never to chat. It answers #2: can an
-- addon read the gathering blips the minimap draws?
--
-- The candidate, from the 1.60.1.70425 dump: Minimap:UpdateMouseoverAtPoint(x, y)
-- moves the minimap's mouseover to a point, and C_TooltipInfo.GetMinimapMouseover()
-- reads what is there, the data Blizzard's hover tooltip shows
-- (Blizzard_Minimap/Mainline/Minimap.lua:269). No Blizzard code calls the
-- first, so whether it works, and in which coordinates, is what this measures.
--
--   /fp nr state                 build, the map's geometry, zoom, rotation, tracking, mounted
--   /fp nr under                 what the minimap's mouseover reads now (hover a blip first)
--   /fp nr hover                 keep the blip under the cursor for /fp nr point
--   /fp nr point                 each coordinate convention at the kept blip
--   /fp nr sweep [conv] [step]   sample the whole map: names, points, milliseconds
--   /fp nr radar [seconds]       sweep 3 times a second, logging names as they appear
--   /fp nr stop                  stop the radar
--   /fp nr vignettes             every vignette the client lists
--   /fp nr sound [kit]           PlaySound: MAP_PING (3175), or a kit
--   /fp nr ring                  v1's ring on the minimap (Interface\Cooldown\ping4)
--   /fp nr clear                 empty the saved log
--
-- Procedure: /fp steps nr blips, the whole of #2 in order.

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
local MAP_PING, V1_SOUND = 3175, 8332     -- SoundKitConstants.lua:73; v1's soundID
local RING = "Interface\\Cooldown\\ping4"
local SWEEP_STEP = 8                      -- the map's own units between samples
local SWEEP_EVERY = 0.3                   -- seconds between radar sweeps
local HOVER_SECONDS = 10

-- This session's measurements: hover, points (the conventions job),
-- hoverJob and ride (radars), sweepHit.
local state = {}

local function overMap()
    local ok, v = pcall(Minimap.IsMouseOver, Minimap)
    return ok and yes(v)
end

local function cursor()
    local x, y = GetCursorPosition()
    return num(x), num(y)
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
-- position in pixels (GetCursorPosition's space).
local CONVENTIONS = {
    { name = "screen",     to = function(px, py) return px, py end },
    { name = "ui",         to = function(px, py, g) return px / g.es, py / g.es end },
    { name = "uiparent",   to = function(px, py, g) return px / g.ues, py / g.ues end },
    { name = "center",     to = function(px, py, g) return px / g.es - g.cx, py / g.es - g.cy end },
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

-- The minimap's mouseover: the names on its lines (one per row), or nil and
-- why. A secret line reads "<secret>" and never matches a name.
local function mouseover()
    local fn = C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover
    if type(fn) ~= "function" then return nil, "MISSING" end
    local ok, data = pcall(fn)
    if not ok then return nil, "ERROR " .. str(data) end
    if secret(data) then return nil, "<secret>" end
    if type(data) ~= "table" then return nil, str(data) end
    local lines = data.lines
    if secret(lines) or type(lines) ~= "table" then return nil, "lines " .. Probe.Shape(lines), data end
    local names = {}
    for _, line in ipairs(lines) do
        local t = type(line) == "table" and line.leftText or nil
        if secret(t) then
            names[#names + 1] = "<secret>"
        elseif type(t) == "string" then
            for row in Probe.Plain(t):gmatch("[^\n]+") do names[#names + 1] = row end
        end
    end
    if #names == 0 then return nil, "no text", data end
    return names, nil, data
end

-- Moves the mouseover to a point (pixels, through a convention) and reads it.
local function sample(conv, g, px, py)
    local x, y = conv.to(px, py, g)
    local ok, err = pcall(Minimap.UpdateMouseoverAtPoint, Minimap, x, y)
    if not ok then return nil, "ERROR " .. str(err) end
    return mouseover()
end

local function join(names) return names and table.concat(names, ", ") or "nothing" end

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
        .. str(okR and r) .. " yd")
    say("mounted " .. str(IsMounted()) .. "; cursor on the minimap " .. str(overMap()))
    say("UpdateMouseoverAtPoint " .. type(Minimap.UpdateMouseoverAtPoint) .. ", GetMinimapMouseover "
        .. type(C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover))
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

-- The blip under the real cursor, kept for the conventions: its names, the
-- cursor in pixels and the map's geometry at that moment.
local function captureHover()
    if not overMap() then return nil, "the cursor isn't on the minimap" end
    local names, why, data = mouseover()
    if not names then return nil, "nothing under the cursor (" .. why .. ")" end
    local px, py = cursor()
    local g = geometry()
    if not (px and py and g) then return nil, "cursor or geometry unreadable" end
    state.hover = { names = names, px = px, py = py, g = g }
    state.points = nil
    say(("hovered %s at cursor (%.1f, %.1f) px, (%.1f, %.1f) from the map's centre in its units"):format(
        join(names), px, py, px / g.es - g.cx, py / g.es - g.cy))
    say("  data: " .. Probe.Describe(data, 3))
    return state.hover
end

-- Tries each convention at the kept blip, one every 0.1 s: the far point
-- first (it must read nothing), then the blip, read at once and 0.1 s later.
-- A convention works when the blip's name comes back and the far point was
-- empty; `later` lists those that answered only after the 0.1 s.
local function tryConventions()
    local h = state.hover
    if not h then
        say("point: no blip kept; hover one, then /fp nr hover")
        return nil
    end
    local job = { i = 0, working = {}, later = {} }
    state.points = job
    local fx, fy = farPixels(h.g)
    local function nextOne()
        job.i = job.i + 1
        local c = CONVENTIONS[job.i]
        if not c then
            job.done = true
            say("point: the blip read back with " .. (#job.working > 0 and table.concat(job.working, ", ") or "NO convention"))
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
            say(("point %s (%.3f, %.3f): far %s; at once %s; 0.1 s later %s%s"):format(c.name, x, y,
                stale and ("STALE " .. join(stale)) or "nothing", now and join(now) or why,
                later and join(later) or whyLater,
                works and " HIT" or ((hitNow or hitLater) and " (a hit, but the far point wasn't empty)" or "")))
            nextOne()
        end)
    end
    nextOne()
    return job
end

-- The conventions to sweep with: the one named, else the first that worked,
-- else all of them.
local function chosen(name)
    if name then
        local c = convention(name)
        return c and { c } or {}
    end
    local w = state.points and state.points.working
    if w and #w > 0 then return { convention(w[1]) } end
    return CONVENTIONS
end

-- Samples the whole map, a square of points `step` apart in its own units,
-- through one convention. Then puts the mouseover back on the cursor when
-- it's on the map, else off the map.
local function sweep(conv, step)
    local g, why = geometry()
    if not g then return nil, why end
    step = step or SWEEP_STEP
    local found, list, points, errors = {}, {}, 0, 0
    local t0 = debugprofilestop()
    for oy = step / 2, g.h, step do
        for ox = step / 2, g.w, step do
            points = points + 1
            local names, whyNot = sample(conv, g, (g.l + ox) * g.es, (g.b + oy) * g.es)
            if names then
                for _, n in ipairs(names) do
                    if not found[n] then
                        found[n] = { x = ox - g.w / 2, y = oy - g.h / 2 }
                        list[#list + 1] = n
                    end
                end
            elseif whyNot and whyNot:find("^ERROR") then
                errors = errors + 1
            end
        end
    end
    local ms = debugprofilestop() - t0
    local px, py = cursor()
    if px and overMap() then sample(conv, g, px, py) else sample(conv, g, farPixels(g)) end
    return { conv = conv.name, found = found, list = list, points = points, ms = ms, errors = errors }
end

local function sweepText(r)
    local parts = {}
    for _, n in ipairs(r.list) do parts[#parts + 1] = ("%s (%.0f, %.0f)"):format(n, r.found[n].x, r.found[n].y) end
    return ("%s: %d names in %d points, %.1f ms%s: %s"):format(r.conv, #r.list, r.points, r.ms,
        r.errors > 0 and (", " .. r.errors .. " errors") or "", #parts > 0 and table.concat(parts, ", ") or "nothing")
end

local function sweepAll(name, step)
    local out, hit = {}, false
    for _, c in ipairs(chosen(name)) do
        local r, why = sweep(c, step)
        local line = r and sweepText(r) or (c.name .. ": " .. why)
        say("sweep " .. line)
        out[#out + 1] = line
        if r and state.hover then
            for _, n in ipairs(state.hover.names) do if r.found[n] then hit = true end end
        end
    end
    if #out == 0 then say("sweep: no convention named " .. str(name)) end
    return table.concat(out, " | "), hit
end

--------------------------------------------------------------------------------
-- The radar: a sweep every SWEEP_EVERY seconds from one OnUpdate
--------------------------------------------------------------------------------

local job
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function()
    if not job then return end
    local now = GetTime()
    if job.last and now - job.last < SWEEP_EVERY then return end
    job.last = now
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
    return ("%s: %d sweeps, %d skipped with the cursor on the map, %.1f ms average, %.1f ms max%s; %d names: %s"):format(
        r.conv, r.sweeps, r.skipped, r.sweeps > 0 and r.totalMs / r.sweeps or 0, r.maxMs,
        r.hoverNames and (", hover read wrong " .. r.flicker .. " times") or "", #r.order,
        #parts > 0 and table.concat(parts, ", ") or "none")
end

-- Sweeps until stopped (or for `seconds`), logging each name the first time
-- it's found. Without hoverNames it skips while the cursor is on the map, as
-- NodeRadar would; with them it sweeps anyway and, after each sweep, checks
-- the mouseover still reads the hovered blip.
local function startRadar(seconds, hoverNames)
    if job then job.finish() end
    local conv = chosen()[1]
    local now = GetTime()
    local r = { conv = conv.name, sweeps = 0, skipped = 0, totalMs = 0, maxMs = 0, seen = {}, order = {},
                started = now, hoverNames = hoverNames, flicker = 0 }
    local function finish()
        if r.done then return end
        r.done = true
        if job and job.r == r then job = nil end
        say("radar " .. radarText(r))
    end
    job = { r = r, untilT = seconds and (now + seconds), finish = finish, fn = function()
        if not hoverNames and overMap() then r.skipped = r.skipped + 1; return end
        local s = sweep(conv)
        if not s then return end
        r.sweeps, r.totalMs, r.maxMs = r.sweeps + 1, r.totalMs + s.ms, math.max(r.maxMs, s.ms)
        for _, n in ipairs(s.list) do
            if not r.seen[n] then
                r.seen[n] = GetTime() - r.started
                r.order[#r.order + 1] = n
                say(("radar +%.1f s: %s at (%.0f, %.0f)"):format(r.seen[n], n, s.found[n].x, s.found[n].y))
            end
        end
        if hoverNames and not shares(mouseover(), hoverNames) then r.flicker = r.flicker + 1 end
    end }
    say("radar started with " .. conv.name .. (seconds and (" for " .. seconds .. " s") or "")
        .. (hoverNames and (", hovering " .. join(hoverNames)) or ""))
    return r
end

local function stopRadar()
    if job then job.finish() end
end

--------------------------------------------------------------------------------
-- v1's other pieces: vignettes, the sound, the ring
--------------------------------------------------------------------------------

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

local ring
local function showRing()
    local id = GetFileIDFromPath(RING)
    say("GetFileIDFromPath(" .. RING .. ") = " .. str(id))
    if not ring then
        ring = CreateFrame("Frame", nil, Minimap)
        ring:SetAllPoints(Minimap)
        ring:SetFrameStrata("HIGHLIGHT")
        local t = ring:CreateTexture(nil, "OVERLAY")
        t:SetTexture(RING)
        t:SetPoint("CENTER", Minimap, "CENTER")
        t:SetSize(12, 12)
        t:SetVertexColor(0.2, 1.0, 0.4, 0.9)
        local anim = ring:CreateAnimationGroup()
        local scale = anim:CreateAnimation("Scale")
        scale:SetScale(8, 8)
        scale:SetDuration(2)
        scale:SetSmoothing("OUT")
        local alpha = anim:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0.9)
        alpha:SetToAlpha(0)
        alpha:SetDuration(2)
        alpha:SetSmoothing("OUT")
        anim:SetScript("OnFinished", function() ring:Hide() end)
        ring.anim = anim
    end
    ring:Show()
    ring.anim:Stop()
    ring.anim:Play()
    return str(id)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

Probe:Command("state", function() report(); vignettes() end, "build, the map's geometry, tracking, mounted")
Probe:Command("under", function() under() end, "what the minimap's mouseover reads now")
Probe:Command("hover", function()
    local h, why = captureHover()
    if not h then say("hover: " .. why) end
end, "keep the blip under the cursor (for point)")
Probe:Command("point", function() tryConventions() end, "each coordinate convention at the kept blip")
Probe:Command("sweep", function(args)
    local name, step = (args or ""):match("^(%a*)%s*(%d*)")
    sweepAll(name ~= "" and name or nil, tonumber(step))
end, "[conv] [step]: sample the whole map")
Probe:Command("radar", function(args) startRadar(tonumber(args)) end, "[seconds]: sweep 3 times a second")
Probe:Command("stop", function() stopRadar() end, "stop the radar")
Probe:Command("vignettes", function() vignettes() end, "every vignette the client lists")
Probe:Command("sound", function(args) sound(tonumber(args) or MAP_PING) end, "[kit]: PlaySound, MAP_PING by default")
Probe:Command("ring", function() showRing() end, "v1's ring on the minimap")
Probe:Command("clear", function() Probe:ClearLog(); say("log cleared") end, "empty the saved log")

--------------------------------------------------------------------------------
-- The procedure: #2 in order
--------------------------------------------------------------------------------

Probe:Steps("blips", {
    rev = 1,
    title = "Gathering blips on the minimap (#2)",
    { text = "Go outdoors near herbs or ore you can gather, out of combat. Then press Next." },
    { text = "Turn on Find Herbs or Find Minerals (the minimap's tracking menu).", wait = function()
          local on = tracking(true)
          if #on > 0 then return true, table.concat(on, ", ") end
          return false, "no gathering tracking on yet"
      end },
    { text = "Reading the minimap, the tracking and the vignettes.", auto = true, run = function()
          local _, g = report()
          local n = vignettes()
          return g and ("%.0fx%.0f, scale %.3f"):format(g.w, g.h, g.es) or "geometry unreadable", n .. " vignettes"
      end },
    { text = "Stand still and don't turn. Put the cursor on a herb or ore blip on the minimap and hold it there "
          .. "until this step completes.",
      screenshot = "hovering a blip",
      wait = function()
          local h, why = captureHover()
          if h then return true, join(h.names) end
          return false, why
      end },
    { text = "Still without moving: take the cursor off the minimap, onto the game world, and leave it there. "
          .. "Each way of pointing at the blip is tried, about a second.",
      wait = function()
          local j = state.points
          if not j then
              if overMap() then return false, "the cursor is still on the minimap" end
              j = tryConventions()
              if not j then return false, "no blip kept: go Back a step" end
          end
          if not j.done then return false, ("trying %d of %d"):format(j.i, #CONVENTIONS) end
          return true, #j.working > 0 and table.concat(j.working, ", ") or "none"
      end,
      check = function()
          local j = state.points
          local w = j and j.working or {}
          return #w > 0, #w > 0 and ("read the blip: " .. table.concat(w, ", ")) or "no convention read the blip"
      end },
    { text = "Keep the cursor off the minimap. Sweep the whole map once.", button = "Sweep", run = function()
          state.hoverJob = nil
          local text, hit = sweepAll()
          state.sweepHit = hit
          return text
      end,
      check = function()
          return state.sweepHit == true, state.sweepHit and "found the hovered blip" or "didn't find the hovered blip"
      end },
    { text = "Did a tooltip appear, or anything flicker on the minimap, while it swept?", ask = true },
    { text = "Put the cursor back on the blip and hold it there. It sweeps 3 times a second for "
          .. HOVER_SECONDS .. " s while you hover.",
      wait = function()
          local r = state.hoverJob
          if not r then
              if not overMap() then return false, "put the cursor on the blip" end
              local names = mouseover()
              if not names then return false, "nothing under the cursor yet" end
              r = startRadar(HOVER_SECONDS, names)
              state.hoverJob = r
          end
          if not r.done then return false, ("sweeping, %d so far"):format(r.sweeps) end
          return true, radarText(r)
      end,
      check = function()
          local r = state.hoverJob
          if not r then return false, "didn't run" end
          return r.flicker == 0, ("the mouseover read wrong after %d of %d sweeps"):format(r.flicker, r.sweeps)
      end },
    { text = "Did the blip's tooltip flicker, vanish or change name during those seconds?", ask = true },
    { text = "Mount up.", event = "PLAYER_MOUNT_DISPLAY_CHANGED", check = function()
          local m = IsMounted()
          return yes(m), "IsMounted " .. str(m)
      end },
    { text = "Ride past a few nodes for a minute or two, the cursor off the minimap. New names show here as "
          .. "the radar finds them. Press Done when you've passed a few.",
      wait = function()
          local r = state.ride
          if not r or r.done then
              r = startRadar()
              state.ride = r
          end
          return false, #r.order > 0 and table.concat(r.order, ", ") or "nothing yet"
      end },
    { text = "Stopping the radar.", auto = true, run = function()
          stopRadar()
          return state.ride and radarText(state.ride) or "no radar ran"
      end },
    { text = "Did the radar's names match the nodes that came up on your minimap? (/fp shows them with times.)", ask = true },
    { text = "Play SOUNDKIT.MAP_PING (3175).", button = "Play", run = function() return sound(MAP_PING) end },
    { text = "Did you hear a ping?", ask = true },
    { text = "Play v1's sound, 8332.", button = "Play", run = function() return sound(V1_SOUND) end },
    { text = "Did you hear a sound?", ask = true },
    { text = "Show v1's ring on the minimap.", button = "Show", screenshot = "v1's ring", run = showRing },
    { text = "Did a green ring grow from the centre of the minimap and fade?", ask = true },
    { text = "Type /reload (or press Reload now) to save the results.", reload = true },
})

--------------------------------------------------------------------------------
-- Boot, and the events worth a line while the procedure runs
--------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED", "MINIMAP_UPDATE_TRACKING", "PLAYER_MOUNT_DISPLAY_CHANGED",
    "VIGNETTE_MINIMAP_UPDATED" })
boot:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        Probe:Ready()
        if type(NodeRadarProbeDB) ~= "table" then NodeRadarProbeDB = {} end
        if type(NodeRadarProbeDB.log) ~= "table" then NodeRadarProbeDB.log = {} end
        Probe:UseLog(NodeRadarProbeDB.log, MAX_LOG)
        NodeRadarProbeDB.loads = (NodeRadarProbeDB.loads or 0) + 1
        say("loaded (" .. NodeRadarProbeDB.loads .. " loads). /fp nr for the commands, /fp steps nr blips for #2")
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        local on = tracking(true)
        say("MINIMAP_UPDATE_TRACKING; gathering on: " .. (#on > 0 and table.concat(on, ", ") or "none"))
    elseif event == "PLAYER_MOUNT_DISPLAY_CHANGED" then
        say("PLAYER_MOUNT_DISPLAY_CHANGED; IsMounted " .. str(IsMounted()))
    elseif event == "VIGNETTE_MINIMAP_UPDATED" then
        local info = not secret(a1) and C_VignetteInfo.GetVignetteInfo(a1) or nil
        say(("VIGNETTE_MINIMAP_UPDATED onMinimap=%s %s type=%s atlas=%s"):format(str(a2),
            str(info and info.name), str(info and info.type), str(info and info.atlasName)))
    end
end)

NS._test = { Probe = Probe, state = state, CONVENTIONS = CONVENTIONS }
