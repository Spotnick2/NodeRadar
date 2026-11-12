--------------------------------------------------------------------------------
-- The scan's field rounds (NodeRadar #111-#117, client 70888). Each is a guided
-- Probe:Steps procedure; nothing runs at load but the registrations.
--
--   /fp steps nr blank     #111: which part of a borrow leaves the stock minimap's ground blank
--   /fp steps nr queue     #115: the Group Finder eye while queued, and what the scan's hold does to it
--   /fp steps nr range     #112: how far a node's icon stays after the player walks away
--   /fp steps nr ground    #117: the stand-in's real ground (ScanFace.Preview / ScanFace.Ground)
--   /fp steps nr scanbusy  #113/#114/#116: the scan's new refusals and its trouble line
--
-- Lines: NodeRadarProbeDB.scanround.lines, each "<time> <round>: ...", and the /fp console.
-- Never chat. The blank round borrows only Minimap, the way MoveScan does (alpha, anchors,
-- size, icon scale, saved first, restored on every path); never MinimapCluster.
--------------------------------------------------------------------------------
local ADDON, NS = ...

local Probe = ForeverProbe:Module("NodeRadarProbe", { api = 1, cmd = "nr" })

local function say(msg) Probe:Say(msg) end
local function str(v) return Probe.Show(v, true) end
local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function num(v) if type(v) == "number" and not secret(v) then return v end end
local function g(name) return rawget(_G, name) end

local MAX_LINES = 4000
local function slog(round, text)
    local line = ("%.2f %s: %s"):format(GetTime(), round, text)
    local d = g("NodeRadarProbeDB")
    if type(d) == "table" then
        if type(d.scanround) ~= "table" then d.scanround = {} end
        local l = d.scanround.lines
        if type(l) ~= "table" then l = {}; d.scanround.lines = l end
        l[#l + 1] = line
        while #l > MAX_LINES do table.remove(l, 1) end
    end
    say(round .. ": " .. text)
end

-- A method call that never throws: nil when missing, thrown or secret.
local function call(obj, m, ...)
    local f = obj and obj[m]
    if type(f) ~= "function" then return nil end
    local ok, a, b, c, d, e = pcall(f, obj, ...)
    if not ok or secret(a) then return nil end
    return a, b, c, d, e
end
local function v(x) if x == nil then return "-" end; if type(x) == "number" then return ("%.2f"):format(x) end; return str(x) end

local function nrAddon() local n = g("NodeRadar"); if type(n) == "table" then return n end end

--------------------------------------------------------------------------------
-- The running step, and one watcher for everything that outlives a step's run
--------------------------------------------------------------------------------

-- The running procedure of ours and its step number, or nil.
local function stepState()
    local FP = g("ForeverProbe")
    local S = type(FP) == "table" and FP.Steps
    if type(S) ~= "table" or type(S.Active) ~= "function" then return nil end
    local ok, proc, rec = pcall(S.Active)
    if ok and type(proc) == "table" and proc.module == Probe and type(rec) == "table" then return proc.name, rec.at end
end
local function stepIs(round, lo, hi)
    local name, at = stepState()
    return name == round and type(at) == "number" and at >= lo and at <= hi
end

-- watch{ id, round, lo, hi, every, fn(w, dt) -> true when finished, stop(w, why) }: fn runs every
-- `every` seconds (0: each frame) while the procedure `round` is on a step lo..hi. When it isn't
-- (a Stop, a Skip past, a reload that didn't resume) or fn finishes or throws, stop(w, why) runs once:
-- the one place a borrow is put back.
local watches, watchFrame = {}, nil
local function pump(_, dt)
    local ended
    for id, w in pairs(watches) do
        w.acc = (w.acc or 0) + dt
        if w.acc >= (w.every or 0) then
            local elapsed = w.acc
            w.acc = 0
            local fin, why
            if not stepIs(w.round, w.lo, w.hi) then
                fin, why = true, "the step was left"
            else
                local ok, a = pcall(w.fn, w, elapsed)
                if not ok then fin, why = true, "ERROR " .. tostring(a)
                elseif a then fin = true end
            end
            if fin then ended = ended or {}; ended[#ended + 1] = { w, why } end
        end
    end
    for _, e in ipairs(ended or {}) do
        watches[e[1].id] = nil
        if e[1].stop then
            local ok, err = pcall(e[1].stop, e[1], e[2])
            if not ok then say("scanround: stop of " .. tostring(e[1].id) .. " FAILED " .. tostring(err)) end
        end
    end
    if next(watches) == nil and watchFrame then watchFrame:SetScript("OnUpdate", nil) end
end
local function watch(w)
    if watches[w.id] then return watches[w.id] end
    watches[w.id] = w
    if not watchFrame then watchFrame = CreateFrame("Frame") end
    watchFrame:SetScript("OnUpdate", pump)
    return w
end
-- Ends a watch now (its stop runs).
local function unwatch(id, why)
    local w = watches[id]
    if not w then return end
    watches[id] = nil
    if w.stop then pcall(w.stop, w, why or "ended") end
end

-- The same few trace lines helpers.
local function traceLines(sinceTime, filter)
    local n = nrAddon()
    local t = n and n.trace
    local out = {}
    if type(t) ~= "table" then return out end
    for _, line in ipairs(t) do
        local ts = tonumber(line:match("^(%S+)"))
        if ts and ts >= sinceTime and (not filter or line:find(filter, 1, true)) then out[#out + 1] = line end
    end
    return out
end

local function playerPos()
    local ok, n, w = pcall(UnitPosition, "player")
    n, w = ok and num(n), ok and num(w)
    if n and w then return ("%.1f north %.1f west"):format(n, w) end
    return "unreadable"
end
local function speed()
    local ok, s = pcall(GetUnitSpeed, "player")
    return ok and num(s) or nil
end
local function inCombat()
    local ok, c = pcall(InCombatLockdown)
    return ok and c == true
end
local function viewRadius()
    local ok, r = pcall(C_Minimap.GetViewRadius)
    return ok and num(r) or nil
end

--------------------------------------------------------------------------------
-- blank (#111): which part of a borrow leaves the ground blank
--------------------------------------------------------------------------------
do
local ROUND = "blank"
local REPEATS = 4
local FRAMES = 6                 -- frames a change is held
local OFF = -2000                -- off screen, MoveScan's MS.OFF
local GAP = 1                    -- seconds from a shot's end to the next repeat
local SETTLE = 0.5               -- seconds from the restore to the screenshot
local SHOT_MAX = 8               -- seconds to wait for a screenshot before going on
-- A mask that hides everything is a texture with no alpha. The probe ships none: this path is a
-- guess, and the arm skips unless Minimap:GetMaskTexture is readable (it isn't in the 70888 dump).
local BLANK_MASK = "Interface\\AddOns\\NodeRadarProbe\\blank"

local B = {}                     -- the round's state (reset at each start)
local hooked = false
local lastScale = 1              -- the last icon scale anyone but us set (it has no getter)
local ourScale = false
local evf

local function setIconScale(x)
    ourScale = true
    local ok, err = pcall(function() Minimap:SetIconScale(x) end)
    ourScale = false
    return ok, err
end

local function hooks()
    if hooked then return end
    hooked = true
    if type(Minimap.SetIconScale) == "function" then
        hooksecurefunc(Minimap, "SetIconScale", function(_, s)
            if not ourScale and num(s) then lastScale = s end
        end)
    end
    if type(Minimap.SetZoom) == "function" then
        hooksecurefunc(Minimap, "SetZoom", function(_, z)
            if B.running then
                B.zoomCalls = (B.zoomCalls or 0) + 1
                slog(ROUND, ("Minimap:SetZoom(%s) during %s"):format(v(z), B.where or "?"))
            end
        end)
    end
end

local function snapshot()
    local s = { alpha = call(Minimap, "GetAlpha"), w = call(Minimap, "GetWidth"), h = call(Minimap, "GetHeight"),
                zoom = call(Minimap, "GetZoom"), points = {}, scale = lastScale }
    local n = call(Minimap, "GetNumPoints") or 0
    for i = 1, n do
        local ok, p, rel, rp, x, y = pcall(Minimap.GetPoint, Minimap, i)
        if not ok or secret(p) or p == nil then return nil end
        s.points[i] = { p, rel, rp, x, y }
    end
    if #s.points == 0 or not (s.alpha and s.w and s.h) then return nil end
    if B.maskReadable then s.mask = call(Minimap, "GetMaskTexture") end
    return s
end

local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 0.01 end
-- The differences between two snapshots, as text; "" when identical.
local function compare(a, b)
    local d = {}
    if not near(a.alpha, b.alpha) then d[#d + 1] = ("alpha %s -> %s"):format(v(a.alpha), v(b.alpha)) end
    if not near(a.w, b.w) or not near(a.h, b.h) then d[#d + 1] = ("size %sx%s -> %sx%s"):format(v(a.w), v(a.h), v(b.w), v(b.h)) end
    if #a.points ~= #b.points then d[#d + 1] = "anchor count " .. #a.points .. " -> " .. #b.points
    else
        for i, p in ipairs(a.points) do
            local q = b.points[i]
            if p[1] ~= q[1] or p[2] ~= q[2] or p[3] ~= q[3] or not near(p[4], q[4]) or not near(p[5], q[5]) then
                d[#d + 1] = ("anchor %d %s %s %s %s,%s -> %s %s %s %s,%s"):format(i, v(p[1]), v(call(p[2], "GetDebugName")), v(p[3]), v(p[4]), v(p[5]),
                    v(q[1]), v(call(q[2], "GetDebugName")), v(q[3]), v(q[4]), v(q[5]))
            end
        end
    end
    if a.mask ~= nil and a.mask ~= b.mask then d[#d + 1] = ("mask %s -> %s"):format(v(a.mask), v(b.mask)) end
    return table.concat(d, "; ")
end
local function describe(s)
    local p = s.points[1]
    return ("alpha %s, %sx%s, anchor %s %s %s %s,%s, zoom %s"):format(v(s.alpha), v(s.w), v(s.h), v(p[1]), v(call(p[2], "GetDebugName")),
        v(p[3]), v(p[4]), v(p[5]), v(s.zoom))
end

-- Puts everything back: geometry first (anchors, size), then the icon scale, the mask, then
-- visibility (alpha). Each call alone in a pcall. Returns the errors, as text.
local function putBack(s)
    local errs = {}
    local function try(label, f)
        local ok, err = pcall(f)
        if not ok then errs[#errs + 1] = label .. ": " .. tostring(err) end
    end
    local t = B.touched or {}
    if t.points then
        try("ClearAllPoints", function() Minimap:ClearAllPoints() end)
        for _, p in ipairs(s.points) do
            try("SetPoint", function() Minimap:SetPoint(p[1], p[2], p[3], p[4], p[5]) end)
        end
    end
    if t.size then try("SetSize", function() Minimap:SetSize(s.w, s.h) end) end
    if t.scale then
        local ok, err = setIconScale(s.scale)
        if not ok then errs[#errs + 1] = "SetIconScale: " .. tostring(err) end
    end
    if t.mask and s.mask ~= nil then try("SetMaskTexture", function() Minimap:SetMaskTexture(s.mask) end) end
    if t.alpha then try("SetAlpha", function() Minimap:SetAlpha(s.alpha) end) end
    return errs
end

-- Restores B.snap and reads it back. Returns true when everything is home.
local function restore(tag)
    local s = B.snap
    if not s then return true end
    local errs = putBack(s)
    local now = snapshot()
    local diff = now and compare(s, now) or "unreadable"
    if #errs == 0 and diff == "" then
        B.borrowed = false
        return true, describe(now)
    end
    -- One more try: a restore that didn't read back is retried before it is reported.
    local errs2 = putBack(s)
    local now2 = snapshot()
    local diff2 = now2 and compare(s, now2) or "unreadable"
    if #errs2 == 0 and diff2 == "" then
        slog(ROUND, tag .. ": the first restore did not read back (" .. diff .. " " .. table.concat(errs, ", ") .. "); the second did")
        B.borrowed = false
        return true, describe(now2)
    end
    B.clean = false
    slog(ROUND, "NOT CLEAN " .. tag .. ": " .. diff2 .. " " .. table.concat(errs2, ", ") .. "; saved " .. describe(s))
    return false
end

local function arms()
    local list = { "a", "b", "c", "d" }
    if type(Minimap.GetMaskTexture) == "function" and type(Minimap.SetMaskTexture) == "function" then
        local ok, m = pcall(Minimap.GetMaskTexture, Minimap)
        if ok and not secret(m) and (type(m) == "string" or type(m) == "number") then
            B.maskReadable = true
            list[#list + 1] = "e"
        else
            slog(ROUND, "arm e (mask) skipped: Minimap:GetMaskTexture is not readable (" .. (ok and v(m) or tostring(m)) .. "), so the mask can't be saved")
        end
    else
        slog(ROUND, "arm e (mask) skipped: Minimap:GetMaskTexture does not exist on this build")
    end
    return list
end

local DESC = {
    a = "alpha 0 only", b = "off screen only", c = "SetSize 20 only",
    d = "alpha 0 + off screen + SetSize 20 + SetIconScale 0.01 + UpdateBlips",
    e = "SetMaskTexture(blank) + off screen + SetSize 20 + SetIconScale 0.01 + UpdateBlips",
}

local function apply(arm)
    local function off()
        Minimap:ClearAllPoints()
        Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", OFF, OFF)
    end
    B.touched = {}
    local t = B.touched
    if arm == "a" then t.alpha = true; Minimap:SetAlpha(0)
    elseif arm == "b" then t.points = true; off()
    elseif arm == "c" then t.size = true; Minimap:SetSize(20, 20)
    elseif arm == "d" then
        t.alpha, t.points, t.size = true, true, true
        Minimap:SetAlpha(0)
        t.scale = true; setIconScale(0.01)
        off()
        Minimap:SetSize(20, 20)
    elseif arm == "e" then
        t.points, t.size = true, true
        t.mask = true
        Minimap:SetMaskTexture(BLANK_MASK)
        t.scale = true; setIconScale(0.01)
        off()
        Minimap:SetSize(20, 20)
    end
end

local function finish(why)
    if B.finished then return end
    B.finished = true
    if B.borrowed then restore("end (" .. tostring(why) .. ")") end
    B.running = false
    if evf then evf:UnregisterAllEvents() end
    B.aborted = why
    local parts = {}
    for _, arm in ipairs(B.arms or {}) do
        parts[#parts + 1] = ("%s: %d zoom event(s), %d done"):format(arm, (B.zoomEvents or {})[arm] or 0, (B.doneReps or {})[arm] or 0)
    end
    B.summary = ("%s; %s; SetZoom calls %d; clean %s"):format(why and ("ended: " .. tostring(why)) or "all arms ran", table.concat(parts, ", "),
        B.zoomCalls or 0, tostring(B.clean ~= false))
    slog(ROUND, "SUMMARY " .. B.summary)
    B.done = true
end

local function stillEnough()
    local sp = speed()
    return sp == nil or sp == 0
end

-- One repeat per state change, driven each frame while the procedure is on its steps.
local function tick(w, dt)
    local now = GetTime()
    if B.done then return true end
    if inCombat() then finish("combat"); return true end
    if B.phase == "gap" then
        if now < B.nextAt then return end
        if not stillEnough() then
            if not B.movedWarned then B.movedWarned = true; slog(ROUND, "waiting: the player is moving") end
            return
        end
        B.movedWarned = nil
        local arm = B.arms[B.armI]
        B.snap = snapshot()
        if not B.snap then finish("the minimap's state is unreadable"); return true end
        B.arm, B.where = arm, ("arm %s repeat %d"):format(arm, B.rep)
        B.phase, B.f = "hold", 0
        B.borrowed = true
        local ok, err = pcall(apply, arm)
        if not ok then slog(ROUND, "ERROR applying arm " .. arm .. ": " .. tostring(err)); finish("an error"); return true end
        B.t0 = now
    elseif B.phase == "hold" then
        B.f = B.f + 1
        if (B.arm == "d" or B.arm == "e") and B.f == 3 then
            local ok, err = pcall(Minimap.UpdateBlips, Minimap)
            if not ok then slog(ROUND, "UpdateBlips ERROR " .. tostring(err)) end
        end
        if B.f >= FRAMES then
            local held = now - B.t0
            local mid = snapshot()
            local ok, home = restore("arm " .. B.arm .. " repeat " .. B.rep)
            B.restoredAt = now
            B.lastLine = ("arm %s repeat %d: %s for %d frames (%.3f s; borrowed state %s); restore %s%s"):format(B.arm, B.rep, DESC[B.arm], B.f, held,
                mid and describe(mid) or "unreadable", ok and "read back clean: " or "NOT CLEAN", ok and home or "")
            B.doneReps = B.doneReps or {}
            B.doneReps[B.arm] = (B.doneReps[B.arm] or 0) + 1
            if not ok then slog(ROUND, B.lastLine); finish("a restore did not read back"); return true end
            B.phase, B.where = "settle", ("arm %s repeat %d (after restore)"):format(B.arm, B.rep)
        end
    elseif B.phase == "settle" then
        if now - B.restoredAt >= SETTLE then
            local label = ("blank arm %s repeat %d"):format(B.arm, B.rep)
            B.phase, B.shotAt = "shot", now
            B.shotDone = false
            local line, arm, rep = B.lastLine, B.arm, B.rep
            local okq, err = pcall(Probe.Screenshot, Probe, label, function(file, why)
                B.shotDone = true
                slog(ROUND, line .. "; screenshot " .. (file and tostring(file) or ("FAILED " .. tostring(why))) .. " (" .. label .. ")")
            end)
            if not okq then B.shotDone = true; slog(ROUND, line .. "; screenshot ERROR " .. tostring(err)) end
        end
    elseif B.phase == "shot" then
        if B.shotDone or now - B.shotAt > SHOT_MAX then
            if not B.shotDone then slog(ROUND, B.lastLine .. "; screenshot never answered") end
            B.rep = B.rep + 1
            if B.rep > REPEATS then B.rep, B.armI = 1, B.armI + 1 end
            if B.armI > #B.arms then finish(nil); return true end
            B.phase, B.nextAt, B.where = "gap", now + GAP, "between repeats"
        end
    end
end

local function onEvent(_, event)
    if event == "MINIMAP_UPDATE_ZOOM" then
        B.zoomEvents = B.zoomEvents or {}
        B.zoomEvents[B.arm or "-"] = (B.zoomEvents[B.arm or "-"] or 0) + 1
        slog(ROUND, ("MINIMAP_UPDATE_ZOOM during %s (phase %s, frame %s)"):format(B.where or "?", tostring(B.phase), tostring(B.f)))
    else
        slog(ROUND, event .. ": restoring")
        finish(event)
        unwatch("blank", event)
    end
end

-- The first step's check: the preconditions, with the reason when one fails.
local function preconditions(moving)
    local why = {}
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("GlassMiniMap") then
        why[#why + 1] = "Glass MiniMap is loaded: this round measures the stock minimap (disable it and /reload)"
    end
    local n = nrAddon()
    if n and type(n.db) == "table" and n.db.moveScan then
        why[#why + 1] = "NodeRadar's scan is on: type /nr scan to turn it off, then press Check again"
    end
    if inCombat() then why[#why + 1] = "in combat" end
    local sp = speed()
    if sp and sp > 0 and not moving then why[#why + 1] = "moving (speed " .. v(sp) .. "): stand still" end
    local indoors = pcall(IsIndoors) and select(2, pcall(IsIndoors))
    if indoors == true then why[#why + 1] = "indoors: stand outdoors" end
    local mm = Minimap
    if call(mm, "IsProtected") == true and inCombat() then why[#why + 1] = "Minimap is protected in combat" end
    if not snapshot() then why[#why + 1] = "Minimap's anchors, size or alpha are unreadable" end
    local a = call(Minimap, "GetAlpha")
    if a and a < 0.99 then why[#why + 1] = "the minimap's alpha is " .. v(a) .. " (an earlier borrow left it): /reload" end
    B.preOK = #why == 0
    B.preWhy = B.preOK and "all clear" or table.concat(why, "; ")
    slog(ROUND, "preconditions " .. (B.preOK and "OK" or "FAILED") .. ": " .. B.preWhy
        .. "; GlassMiniMap loaded " .. tostring(C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("GlassMiniMap"))
        .. ", NodeRadar " .. (n and ("db.moveScan " .. tostring(n.db and n.db.moveScan)) or "not loaded")
        .. ", build " .. tostring(select(2, GetBuildInfo())) .. ", zoom " .. v(call(Minimap, "GetZoom")) .. ", " .. (snapshot() and describe(snapshot()) or ""))
    return B.preOK, B.preWhy
end

local function start()
    if B.running then return "already running" end
    local keepPre = { preOK = B.preOK, preWhy = B.preWhy }
    B = { preOK = keepPre.preOK, preWhy = keepPre.preWhy }
    hooks()
    if not preconditions() then
        B.done, B.aborted, B.summary = true, "refused", "refused: " .. B.preWhy
        return B.summary
    end
    B.arms = arms()
    B.armI, B.rep, B.phase, B.nextAt, B.where = 1, 1, "gap", GetTime() + GAP, "start"
    B.running, B.clean, B.zoomEvents, B.doneReps = true, true, {}, {}
    if not evf then evf = CreateFrame("Frame"); evf:SetScript("OnEvent", onEvent) end
    Probe:RegisterEvents(evf, { "PLAYER_REGEN_DISABLED", "PLAYER_LEAVING_WORLD", "MINIMAP_UPDATE_ZOOM" })
    slog(ROUND, ("started: arms %s, %d repeats each, %d frames held, screenshot %.1f s after each restore"):format(table.concat(B.arms, ","), REPEATS, FRAMES, SETTLE))
    watch({ id = "blank", round = ROUND, lo = 2, hi = 3, every = 0, fn = tick,
            stop = function(_, why) if why then finish(why) end end })
    return "started"
end

Probe:Steps("blank", {
    rev = 1,
    title = "The minimap's ground goes blank after a look (#111)",
    { text = "Stock UI only (Glass MiniMap off), NodeRadar's scan off (/nr scan if it is on), out of combat, standing still outdoors. Press Check.",
      button = "Check", run = function() local ok, why = preconditions(); return ok, why end,
      check = function() return B.preOK == true, B.preWhy end },
    { text = "Stand still and leave the mouse alone. Press Start: five arms (alpha, move, resize, all together, mask), 4 repeats each, with a screenshot after each. Do not move, press keys or change the zoom until it finishes (about 90 s).",
      button = "Start", run = start },
    { text = "Running the arms, one second apart. Stay still. It finishes by itself.",
      wait = function()
          if B.done then return true, B.summary end
          return false, ("arm %s repeat %s (%s)"):format(tostring(B.arms and B.arms[B.armI] or "?"), tostring(B.rep), tostring(B.phase))
      end, timeout = 600,
      check = function() return B.done == true and not B.aborted and B.clean ~= false, B.summary end },
    { text = "Did the minimap's ground go blank after any of the arms? Which? (The screenshots are named blank arm <a-e> repeat <1-4>: a alpha, b move, c resize, d all together, e mask.) Type the arm in the note.",
      ask = true },
})

----------------------------------------------------------------------------
-- blankmask (#111): alpha 0 against an empty mask texture, each from a fresh baseline
--   /fp steps nr blankmask
-- The other scanners hide the minimap with an empty mask instead of alpha 0, because alpha
-- below 1 is said to leave the ground blank until the player moves. Each arm starts after a
-- short walk (the ground freshly drawn), with a baseline screenshot, then the same borrow
-- (hide, off screen, SetSize 20, SetIconScale 0.01, UpdateBlips, 6 frames, put back), then
-- its screenshot. The mask arm runs only with a known initial mask (see maskSkip).
----------------------------------------------------------------------------
local MR = "blankmask"
local STOCK_MASK = "ui-hud-minimap-frame-generic-mask"
local MASK_PATH = "Interface\\AddOns\\NodeRadarProbe\\Empty.tga"
local OWN_ADDONS = { NodeRadar = true, ForeverProbe = true, NodeRadarProbe = true }
local MK = { others = {} }          -- others: every non-stock mask written since load, not by us
local ownMask = false               -- set around the probe's own SetMaskTexture calls

local function setMask(val)
    ownMask = true
    local ok, a = pcall(Minimap.SetMaskTexture, Minimap, val)
    ownMask = false
    return ok, a
end

-- Classifies every write: ours (the flag), stock (the atlas name, any case), or other (logged).
if type(Minimap) == "table" and type(Minimap.SetMaskTexture) == "function" then
    pcall(hooksecurefunc, Minimap, "SetMaskTexture", function(_, val)
        if ownMask then return end
        pcall(function()
            local text
            if secret(val) then text = "<secret>" else text = tostring(val) end
            if not secret(val) and text:lower() == STOCK_MASK then return end
            MK.others[#MK.others + 1] = text
            slog(MR, "a mask other than the stock one was set: " .. text)
        end)
    end)
end

-- The loaded add-ons that are neither Blizzard's nor ours; nil when the list can't be read.
local function extraAddons()
    local A = g("C_AddOns")
    if type(A) ~= "table" or type(A.GetNumAddOns) ~= "function" or type(A.GetAddOnInfo) ~= "function"
        or type(A.IsAddOnLoaded) ~= "function" then return nil end
    local okN, n = pcall(A.GetNumAddOns)
    if not okN or type(n) ~= "number" then return nil end
    local extra = {}
    for i = 1, n do
        local ok, info = pcall(A.GetAddOnInfo, i)
        local name = ok and (type(info) == "table" and info.name or info) or nil
        if type(name) == "string" and not secret(name) then
            local okL, loaded = pcall(A.IsAddOnLoaded, i)
            if okL and loaded and not name:find("^Blizzard_") and not OWN_ADDONS[name] then extra[#extra + 1] = name end
        end
    end
    return extra
end

-- Why the mask arm can't run now, or nil. Order: combat, Glass MiniMap, a burst, unknown mask, Empty.tga.
local emptyTex
local function maskSkip()
    if inCombat() then return "in combat" end
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("GlassMiniMap") then return "Glass MiniMap is loaded" end
    local n = nrAddon()
    local ms = n and n.MoveScan
    if type(ms) == "table" and type(ms._test) == "table" and type(ms._test.burst) == "function" then
        local ok, b = pcall(ms._test.burst)
        if ok and b then return "NodeRadar's scan is mid-burst" end
    end
    if type(Minimap) ~= "table" or type(Minimap.SetMaskTexture) ~= "function" then return "Minimap:SetMaskTexture does not exist" end
    local extra = extraAddons()
    if extra == nil then return "initial mask unknown: the add-on list is unreadable" end
    if #extra > 0 then
        return "initial mask unknown: run it with only NodeRadar, ForeverProbe and NodeRadarProbe enabled (" .. table.concat(extra, ", ") .. ")"
    end
    if #MK.others > 0 then
        return "a mask other than the stock one was set: " .. table.concat(MK.others, ", ")
    end
    local ok, res = pcall(function()
        if not emptyTex then
            local f = CreateFrame("Frame", nil, UIParent)
            f:Hide()
            emptyTex = f:CreateTexture(nil, "BACKGROUND")
            emptyTex:Hide()
        end
        local set = emptyTex:SetTexture(MASK_PATH)
        local tex = emptyTex:GetTexture()
        local loaded = type(emptyTex.IsObjectLoaded) == "function" and emptyTex:IsObjectLoaded() or nil
        return { set = set, tex = tex, loaded = loaded }
    end)
    local pre = ok and res or {}
    slog(MR, ("Empty.tga preflight: SetTexture returned %s, GetTexture %s, IsObjectLoaded %s%s"):format(v(pre.set), v(pre.tex), v(pre.loaded),
        ok and "" or (" ERROR " .. tostring(res))))
    if not (ok and pre.set == true and pre.tex ~= nil and pre.loaded ~= false) then
        return "Empty.tga isn't loaded: a new file needs a full client restart (exit the game, not /reload)"
    end
    return nil
end

local W = {}                         -- the running arm's state
local ARMS, questAreas               -- defined below; mfinish (the restore) uses both
local mevf
local function msnapshot() local s = snapshot(); if s then s.mask = nil end; return s end

local function mfinish(why)
    if W.finished then return end
    W.finished = true
    local s, t = W.snap, W.touched or {}
    if W.sizeBumped and s then
        W.sizeBumped = nil
        local ok, err = pcall(Minimap.SetSize, Minimap, s.w, s.h)
        slog(MR, ("arm %s: the repaint's size put back (stopped): pcall %s %s"):format(tostring(W.arm), tostring(ok), v(err)))
    end
    local errs = {}
    local function try(label, f)
        local ok, err = pcall(f)
        if not ok then errs[#errs + 1] = label .. ": " .. tostring(err) end
    end
    if s and W.borrowed then
        -- One pcall around it all: an error must still leave the map shown and home.
        local okAll, errAll = pcall(function()
            -- geometry first, then the icon scale, the mask, then visibility
            if t.points then
                try("ClearAllPoints", function() Minimap:ClearAllPoints() end)
                for _, p in ipairs(s.points) do try("SetPoint", function() Minimap:SetPoint(p[1], p[2], p[3], p[4], p[5]) end) end
            end
            if t.size then try("SetSize", function() Minimap:SetSize(s.w, s.h) end) end
            if t.scale then local ok, err = setIconScale(s.scale); if not ok then errs[#errs + 1] = "SetIconScale: " .. tostring(err) end end
            if t.mask then
                local ok, a = setMask(STOCK_MASK)
                slog(MR, ("arm %s: setter returned SetMaskTexture(stock) pcall %s, %s"):format(W.arm, tostring(ok), v(a)))
                if not ok then errs[#errs + 1] = "SetMaskTexture: " .. tostring(a) end
            end
            local late = ARMS[W.arm] and ARMS[W.arm].quest == "late"
            if t.quest and not late then questAreas(true, "restore, map home, alpha still 0") end
            if t.alpha then try("SetAlpha", function() Minimap:SetAlpha(s.alpha) end) end
            if t.quest and late then questAreas(true, "restore, after the alpha is back") end
            local now = msnapshot()
            local diff = now and compare(s, now) or "unreadable"
            W.geometry = diff == "" and #errs == 0
            slog(MR, ("arm %s: geometry restored: %s%s%s"):format(W.arm, W.geometry and "yes" or "NO",
                diff ~= "" and (" (" .. diff .. ")") or "", #errs > 0 and (" errors " .. table.concat(errs, ", ")) or ""))
            W.borrowed = false
        end)
        if not okAll then
            slog(MR, ("arm %s: RESTORE ERROR %s: putting everything back blind"):format(tostring(W.arm), tostring(errAll)))
            pcall(Minimap.ClearAllPoints, Minimap)
            for _, p in ipairs(s.points) do pcall(Minimap.SetPoint, Minimap, p[1], p[2], p[3], p[4], p[5]) end
            pcall(Minimap.SetSize, Minimap, s.w, s.h)
            setIconScale(s.scale)
            if t.mask then setMask(STOCK_MASK) end
            pcall(Minimap.SetAlpha, Minimap, s.alpha)
            W.geometry, W.borrowed = false, false
        end
    end
    if mevf then mevf:UnregisterAllEvents() end
    W.endedBy = why
    W.done = true
    slog(MR, ("arm %s: ended: %s"):format(tostring(W.arm), tostring(why or "done")))
end

local function mshot(label, nextPhase)
    W.phase, W.shotAt, W.shotDone = "shot", GetTime(), false
    W.afterShot = nextPhase
    local okq, err = pcall(Probe.Screenshot, Probe, label, function(file, why)
        W.shotDone = true
        slog(MR, ("arm %s: screenshot %s (%s)"):format(W.arm, file and tostring(file) or ("FAILED " .. tostring(why)), label))
    end)
    if not okq then W.shotDone = true; slog(MR, "screenshot ERROR " .. tostring(err)) end
end

-- The arms: how the map is hidden (alpha 0, the empty mask, or not at all: off screen and 20 px
-- hide it anyway), whether the zoom is nudged mid-borrow as HereBeDragons does on
-- MINIMAP_UPDATE_ZOOM (SetZoom(z +- 1) then SetZoom(z), the same frame), and a repaint tried
-- after the restore at alpha 1 (the same zoom nudge, or the size 1 px up for a frame).
ARMS = {
    alpha = { hide = "alpha" }, mask = { hide = "mask" },
    zalpha = { hide = "alpha", nudge = true },
    zoff = { nudge = true },
    zfix = { hide = "alpha", nudge = true, after = "zoom" },
    zsize = { hide = "alpha", nudge = true, after = "size" },
    zmask = { hide = "mask", nudge = true },
    -- blankquest: the quest areas' tracking off for the borrow, as MoveScan does, and back on
    -- with the map home: at alpha 0 (MoveScan's order) or after the alpha is back.
    qalpha = { hide = "alpha", quest = "early" },
    -- blankmove: each part of a borrow alone, done while the player moves (the terrain redrawn
    -- while the map is borrowed: the blank came back in real looks only while moving).
    valpha = { hide = "alpha", moving = true, noOff = true, noSize = true, noScale = true },
    voff = { moving = true, noSize = true, noScale = true },
    vsize = { moving = true, noOff = true, noScale = true },
    vall = { hide = "alpha", moving = true },
    vmask = { hide = "mask", moving = true },
    -- blankcursor: a presence look's own placement: the map 15.4 screen px (MS.PRESENCE_PX)
    -- centred under the cursor, on screen, and the mouseover read at frame 3.
    von = { hide = "alpha", moving = true, noOff = true, noSize = true, cursor = 15.4 },
    vonq = { hide = "alpha", moving = true, noOff = true, noSize = true, cursor = 15.4, quest = "early" },
    vonmask = { hide = "mask", moving = true, noOff = true, noSize = true, cursor = 15.4 },
    qlate = { hide = "alpha", quest = "late" },
}

-- The quest areas' tracking switched as MoveScan.QuestAreas does (C_Minimap.SetTracking on the
-- QuestPOIs filter), but directly: NodeRadar's questOff bookkeeping would let its driver put
-- them back on mid-arm. Off: true when they were on and now read off. On: true when they read on.
local function questIndex()
    local M = g("C_Minimap")
    if type(M) ~= "table" or type(M.GetTrackingFilter) ~= "function" then return nil end
    local E = g("Enum")
    local want = E and E.MinimapTrackingFilter and rawget(E.MinimapTrackingFilter, "QuestPOIs") or 65536
    local okN, n = pcall(M.GetNumTrackingTypes)
    for i = 1, (okN and num(n)) or 0 do
        local ok, f = pcall(M.GetTrackingFilter, i)
        if ok and type(f) == "table" and not secret(f) and f.filterID == want then return i end
    end
end
local function questActive(i)
    local ok, info = pcall(C_Minimap.GetTrackingInfo, i)
    if not ok or type(info) ~= "table" or secret(info) then return nil end
    return info.active == true
end
function questAreas(on, label)
    local i = questIndex()
    if not i then slog(MR, ("arm %s: %s: no QuestPOIs tracking"):format(tostring(W.arm), label)); return nil end
    local before = questActive(i)
    local r
    if not on and before ~= true then r = false
    else
        local ok, err = pcall(C_Minimap.SetTracking, i, on)
        if not ok then slog(MR, "SetTracking ERROR " .. tostring(err)) end
        r = questActive(i) == on
    end
    slog(MR, ("arm %s: %s: quest areas %s -> %s (%s)"):format(tostring(W.arm), label, v(before), v(questActive(i)), tostring(r)))
    return r
end

local function nudge(label)
    local ok, z0, z1, z2 = pcall(function()
        local z = Minimap:GetZoom()
        Minimap:SetZoom(z < 2 and z + 1 or z - 1)
        local mid = Minimap:GetZoom()
        Minimap:SetZoom(z)
        return z, mid, Minimap:GetZoom()
    end)
    slog(MR, ("arm %s: %s zoom nudge pcall %s: %s -> %s -> %s"):format(W.arm, label, tostring(ok), v(z0), v(z1), v(z2)))
end

local function mapply()
    local s = W.snap
    local t = {}
    W.touched = t
    local function step(label, f)
        local ok, a = pcall(f)
        slog(MR, ("arm %s: setter returned %s pcall %s, %s"):format(W.arm, label, tostring(ok), v(a)))
        return ok
    end
    local hide = ARMS[W.arm].hide
    if hide == "alpha" then t.alpha = true; step("SetAlpha(0)", function() return Minimap:SetAlpha(0) end)
    elseif hide == "mask" then t.mask = true; local ok, a = setMask(MASK_PATH); slog(MR, ("arm %s: setter returned SetMaskTexture(Empty.tga) pcall %s, %s"):format(W.arm, tostring(ok), v(a))) end
    if ARMS[W.arm].quest then
        t.quest = questAreas(false, "borrow") == true
        if not t.quest then slog(MR, ("arm %s: the quest areas weren't on, so this arm proves nothing"):format(W.arm)) end
    end
    local spec = ARMS[W.arm]
    if not spec.noScale then t.scale = true; step("SetIconScale(0.01)", function() local ok, e = setIconScale(0.01); if not ok then error(e) end end) end
    if not spec.noOff then
        t.points = true
        step("off screen", function() Minimap:ClearAllPoints(); Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", OFF, OFF) end)
    end
    if not spec.noSize then
        t.size = true
        step("SetSize(20, 20)", function() return Minimap:SetSize(20, 20) end)
    end
    if spec.cursor then
        t.points, t.size = true, true
        step(("under the cursor, %.1f px"):format(spec.cursor), function()
            local es = Minimap:GetEffectiveScale()
            local x, y = GetCursorPosition()
            Minimap:SetSize(spec.cursor / es, spec.cursor / es)
            Minimap:ClearAllPoints()
            Minimap:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / es, y / es)
            return ("%.0f,%.0f es %.2f"):format(x, y, es)
        end)
    end
end

-- One arm, a phase each frame: still -> baseline shot -> hold (borrowed) -> restore -> settle -> shot.
local function mtick()
    local now = GetTime()
    if W.done then return true end
    if inCombat() then mfinish("combat"); return true end
    local ph = W.phase
    if ph == "still" then
        local mov = ARMS[W.arm].moving
        if mov then
            local sp = speed()
            if not (sp and sp > 0) then W.stillSince = nil; return end   -- waits for the player to move
        elseif not stillEnough() then W.stillSince = nil; return end
        W.stillSince = W.stillSince or now
        if now - W.stillSince >= 0.5 then
            W.snap = msnapshot()
            if not W.snap then mfinish("the minimap's state is unreadable"); return true end
            slog(MR, ("arm %s: baseline, %s, player %s"):format(W.arm, describe(W.snap), playerPos()))
            mshot("blankmask baseline " .. W.arm .. (W.rep and (" #" .. W.rep) or ""), "borrow")
        end
    elseif ph == "borrow" then
        if not ARMS[W.arm].moving and not stillEnough() then slog(MR, "the player moved before the borrow: ending"); mfinish("moved"); return true end
        W.borrowed, W.phase, W.f, W.t0 = true, "hold", 0, now
        local ok, err = pcall(mapply)
        if not ok then slog(MR, "ERROR applying " .. tostring(err)); mfinish("an error"); return true end
    elseif ph == "hold" then
        W.f = W.f + 1
        if W.f == 2 and ARMS[W.arm].nudge then nudge("mid-borrow") end
        if W.f == 3 then
            local ok, err = pcall(Minimap.UpdateBlips, Minimap)
            slog(MR, ("arm %s: setter returned UpdateBlips pcall %s, %s"):format(W.arm, tostring(ok), v(err)))
        end
        if W.f == 4 and ARMS[W.arm].cursor then
            local ok, data = pcall(C_TooltipInfo.GetMinimapMouseover)
            local lines = ok and type(data) == "table" and not secret(data) and type(data.lines) == "table" and not secret(data.lines) and #data.lines or nil
            slog(MR, ("arm %s: the mouseover read: pcall %s, %s line(s)"):format(W.arm, tostring(ok), v(lines)))
        end
        if W.f >= FRAMES then
            slog(MR, ("arm %s: held %d frames, %.3f s"):format(W.arm, W.f, now - W.t0))
            mfinish(nil)             -- the restore, and the geometry read back
            W.done = false
            W.finished = false
            W.phase, W.restoredAt = "settle", now
            local after = ARMS[W.arm].after
            if after == "zoom" then nudge("repaint (after the restore, alpha 1)")
            elseif after == "size" and W.snap then
                local ok, err = pcall(Minimap.SetSize, Minimap, W.snap.w + 1, W.snap.h + 1)
                W.sizeBumped = ok
                slog(MR, ("arm %s: repaint: SetSize(+1) pcall %s %s"):format(W.arm, tostring(ok), v(err)))
            end
        end
    elseif ph == "settle" then
        if W.sizeBumped then
            W.sizeBumped = nil
            local ok, err = pcall(Minimap.SetSize, Minimap, W.snap.w, W.snap.h)
            local now2 = msnapshot()
            local diff = now2 and compare(W.snap, now2) or "unreadable"
            if diff ~= "" or not ok then W.geometry = false end
            slog(MR, ("arm %s: repaint: size put back pcall %s %s, geometry %s"):format(W.arm, tostring(ok), v(err), diff == "" and "home" or diff))
        end
        if now - W.restoredAt >= SETTLE then
            slog(MR, ("arm %s: zoom %s before the after shot"):format(W.arm, v(call(Minimap, "GetZoom"))))
            mshot("blankmask after " .. W.arm .. (W.rep and (" #" .. W.rep) or ""), "end")
        end
    elseif ph == "shot" then
        if W.shotDone or now - W.shotAt > SHOT_MAX then
            if not W.shotDone then slog(MR, "screenshot never answered") end
            if W.afterShot == "end" then
                W.finished, W.done = true, true
                slog(MR, ("arm %s: SUMMARY geometry restored %s; mask visually restored: see the screenshots and the answer"):format(W.arm, tostring(W.geometry)))
                return true
            end
            W.phase = W.afterShot
        end
    end
end

local function mstart(arm, round, lo, hi, rep)
    if W.running and not W.done then return "already running" end
    W = { arm = arm, running = true, rep = rep }
    hooks()
    local ok, why = preconditions(ARMS[arm].moving)
    if not ok then W.done, W.skipped = true, true; slog(MR, "arm " .. arm .. " skipped: " .. why); return "skipped: " .. why end
    if ARMS[arm].hide == "mask" then
        local r = maskSkip()
        if r then W.done, W.skipped = true, true; slog(MR, "mask arm skipped: " .. r); return "skipped: " .. r end
    end
    if not mevf then
        mevf = CreateFrame("Frame")
        mevf:SetScript("OnEvent", function(_, event)
            if event == "MINIMAP_UPDATE_ZOOM" then
                slog(MR, ("MINIMAP_UPDATE_ZOOM in phase %s (frame %s)"):format(tostring(W.phase), tostring(W.f)))
            else
                slog(MR, event .. ": restoring")
                mfinish(event)
                unwatch(MR, event)
            end
        end)
    end
    Probe:RegisterEvents(mevf, { "PLAYER_REGEN_DISABLED", "PLAYER_LEAVING_WORLD", "MINIMAP_UPDATE_ZOOM" })
    W.phase = "still"
    slog(MR, ("arm %s started: build %s, %s"):format(arm, tostring(select(2, GetBuildInfo())), describe(msnapshot() or { points = { {} }, alpha = 0, w = 0, h = 0 })))
    watch({ id = MR, round = round or MR, lo = lo or 3, hi = hi or 8, every = 0, fn = mtick, stop = function(_, why) mfinish(why or "stopped") end })
    return "started"
end

-- A wait that finishes once the player has walked and then stood still for a second. A watcher
-- samples the speed every 0.1 s, since the step's own poll is about once a second.
local walkState = {}
local function walkWait(tag, at, round)
    return function()
        local ws = walkState[tag]
        if not ws then
            ws = {}
            walkState[tag] = ws
            watch({ id = MR .. "walk" .. tag, round = round or MR, lo = at, hi = at, every = 0.1, fn = function()
                local now = GetTime()
                local sp = speed()
                if sp and sp > 0 then ws.moved, ws.stillAt = true, nil
                elseif ws.moved then ws.stillAt = ws.stillAt or now end
                if ws.moved and ws.stillAt and now - ws.stillAt >= 1 and not ws.ok then
                    ws.ok = true
                    slog(MR, "walked and stopped (" .. tag .. "): the ground is freshly drawn, player " .. playerPos())
                end
                return ws.ok
            end, stop = function() if not ws.ok then walkState[tag] = nil end end })
            return false, "walk a few yards first"
        end
        if ws.ok then return true, "walked and stopped" end
        return false, ws.moved and "stand still for a second" or "walk a few yards first"
    end
end

local function armDone(w)
    return function()
        if w.done then return true end
        return false, ("arm %s, %s"):format(tostring(w.arm), tostring(w.phase))
    end
end

local ASK = "Is the minimap round and its ground drawn, as before? Look at the minimap itself: the map terrain (roads, water, grass) inside the round frame. "
    .. "Answer yes if it matches the baseline screenshot; No if blank ground, wrong shape or anything else, and say which in the note. Not sure if you can't tell."

Probe:Steps(MR, {
    rev = 1,
    title = "Alpha 0 against an empty mask texture, from a fresh baseline (#111)",
    { text = "Stock UI, only NodeRadar, ForeverProbe and NodeRadarProbe loaded for the mask arm (skips itself otherwise), NodeRadar's scan off (/nr scan), out of combat, outdoors. "
        .. "Empty.tga is new: exit the game fully once after deploying it (/reload does not load a new file). Press Check.",
      button = "Check", run = function()
          walkState.alpha, walkState.mask = nil, nil
          local ok, why = preconditions()
          local r = maskSkip()
          slog(MR, "mask arm would " .. (r and ("skip: " .. r) or "run"))
          return ok, why .. "; mask arm: " .. (r or "will run")
      end,
      check = function() return B.preOK == true, B.preWhy end },
    { text = "Alpha arm: walk a few yards and stop, so the ground is freshly drawn. Then leave the mouse and keys alone.",
      wait = walkWait("alpha", 2), timeout = 180 },
    { text = "Press Start: the alpha arm takes a baseline screenshot, hides the minimap with alpha 0 and moves/resizes it the way a scan borrow does, puts it back, and takes a second screenshot. Do not move or press keys until it finishes.",
      button = "Start", run = function() return mstart("alpha") end },
    { text = "Running the alpha arm. Stay still.", wait = function() return armDone(W)() end, timeout = 60,
      check = function() return W.done == true and not W.skipped and W.geometry == true, W.endedBy and ("ended: " .. tostring(W.endedBy)) or "geometry restored" end },
    { text = "ALPHA ARM. " .. ASK .. " (Screenshots: blankmask baseline alpha, blankmask after alpha.)", ask = true },
    { text = "Mask arm: walk a few yards and stop again, so the ground is freshly drawn (the alpha arm may have left it blank). Then leave the mouse and keys alone.",
      wait = walkWait("mask", 6), timeout = 180 },
    { text = "Press Start: the mask arm does the same with an empty mask texture instead of alpha 0. It skips itself, and says why in the result, unless its conditions hold.",
      button = "Start", run = function() return mstart("mask") end },
    { text = "Running the mask arm (or skipped). Stay still.", wait = function() return armDone(W)() end, timeout = 60,
      check = function() return W.arm == "mask" and W.done == true and not W.skipped and W.geometry == true,
          W.skipped and "skipped, see the log" or (W.endedBy and ("ended: " .. tostring(W.endedBy)) or "geometry restored") end },
    { text = "MASK ARM (press Skip if it said it skipped). " .. ASK .. " (Screenshots: blankmask baseline mask, blankmask after mask.)", ask = true },
})

----------------------------------------------------------------------------
-- blankzoom (#111): the blank ground needs a redraw while the map is hidden?
--   /fp steps nr blankzoom
-- blank and blankmask (70888) never left the ground blank: nothing redrew the map while it was
-- hidden. In a real look HereBeDragons nudges the zoom on MINIMAP_UPDATE_ZOOM mid-borrow. Each
-- arm here is blankmask's borrow plus that nudge at frame 2, after a walk (fresh ground):
--   zalpha  alpha 0 + nudge: the suspected bug
--   zoff    no alpha change (off screen and 20 px hide it) + nudge: is alpha the factor?
--   zfix    zalpha, then the zoom nudged again after the restore, at alpha 1: a repaint?
--   zsize   zalpha, then the size 1 px up for a frame after the restore: a repaint?
--   zmask   the empty mask instead of alpha 0 + nudge (only NodeRadar, ForeverProbe and
--           NodeRadarProbe loaded; skips itself otherwise)
----------------------------------------------------------------------------
local ZR = "blankzoom"
local ZARMS = { "zalpha", "zoff", "zfix", "zsize", "zmask" }
local ZDESC = {
    zalpha = "alpha 0, the zoom nudged mid-borrow (the suspected bug)",
    zoff = "no alpha change, the zoom nudged mid-borrow",
    zfix = "alpha 0, the zoom nudged mid-borrow, then nudged again after the restore",
    zsize = "alpha 0, the zoom nudged mid-borrow, then the size 1 px up for a frame after the restore",
    zmask = "the empty mask instead of alpha 0, the zoom nudged mid-borrow (skips itself unless only the three add-ons are loaded)",
}
local zstarted = {}
local zsteps = {
    rev = 1,
    title = "The blank ground after a zoom nudge while the map is hidden (#111)",
    { text = "Stock UI (Glass MiniMap off), NodeRadar's scan off (/nr scan), out of combat, outdoors. The last arm (mask) runs only with just NodeRadar, ForeverProbe and NodeRadarProbe loaded and skips itself otherwise. Press Check.",
      button = "Check", run = function()
          zstarted = {}
          for _, a in ipairs(ZARMS) do walkState["z" .. a] = nil end
          local ok, why = preconditions()
          local r = maskSkip()
          slog(MR, "blankzoom: mask arm would " .. (r and ("skip: " .. r) or "run"))
          return ok, why .. "; mask arm: " .. (r or "will run")
      end,
      check = function() return B.preOK == true, B.preWhy end },
}
for i, arm in ipairs(ZARMS) do
    local walkAt, runAt = 2 * i, 2 * i + 1
    zsteps[#zsteps + 1] = { text = ("Arm %d of %d (%s): walk a few yards and stop, so the ground is freshly drawn. Then leave the mouse and keys alone: it starts by itself.")
        :format(i, #ZARMS, arm), wait = walkWait("z" .. arm, walkAt, ZR), timeout = 180 }
    zsteps[#zsteps + 1] = { text = ("Running arm %s: %s. A screenshot before and after. Stay still."):format(arm, ZDESC[arm]),
        wait = function()
            if not zstarted[arm] then
                zstarted[arm] = true
                local r = mstart(arm, ZR, runAt, runAt)
                if r ~= "started" then return true, r end
            end
            if W.arm == arm and W.done then return true, W.skipped and "skipped" or ("geometry restored " .. tostring(W.geometry)) end
            return false, ("arm %s, %s"):format(arm, tostring(W.phase))
        end, timeout = 60,
        check = function() return W.arm == arm and W.done == true and not W.skipped and W.geometry == true,
            W.skipped and "skipped, see the log" or (W.endedBy and ("ended: " .. tostring(W.endedBy)) or "geometry restored") end }
end
zsteps[#zsteps + 1] = { text = "Which arms left the minimap's ground blank (the terrain missing inside the round frame) until you walked? Type their names in the note "
    .. "(zalpha, zoff, zfix, zsize, zmask), or none. Not sure if you couldn't tell: the screenshots say.", ask = true }
Probe:Steps(ZR, zsteps)

----------------------------------------------------------------------------
-- blankquest (#111): the quest areas switched back on while the map is still at alpha 0
--   /fp steps nr blankquest
-- blankzoom (70888) never blanked the ground, a zoom nudge included. The other thing a real
-- look does to the map is the quest areas' tracking: off for the borrow, back on once the map
-- is home but before its alpha (MoveScan's order). qalpha does that; qlate switches them back
-- on after the alpha. Then real looks: the scan on, a screenshot after each of 8 looks, the
-- zoom and tracking events during them logged.
----------------------------------------------------------------------------
local QR = "blankquest"
local QLOOKS = 8
local qstarted, QS = {}, {}
local qevf

-- Where the player is in the minimap's tiles (533.33 yd, x = 32 - west/T east, y = 32 - north/T
-- south, as ScanFace draws them): the tile, the distance to its nearest edge, and how far until
-- the set of tiles the view disc needs changes (its bounding box crossing a tile line).
local TILE = 1600 / 3
local function tileInfo()
    local ok, n, w = pcall(UnitPosition, "player")
    n, w = ok and num(n), ok and num(w)
    local r = viewRadius()
    if not (n and w) then return "position unreadable" end
    local fx, fy = 32 - w / TILE, 32 - n / TILE
    local function d(f) local fr = f - math.floor(f); return math.min(fr, 1 - fr) * TILE end
    local edge = math.min(d(fx), d(fy))
    local set = r and math.min(d(fx - r / TILE), d(fx + r / TILE), d(fy - r / TILE), d(fy + r / TILE)) or nil
    return ("tile %d,%d, %.0f yd from its edge, view radius %s, %s yd until the tiles in view change"):format(math.floor(fx), math.floor(fy), edge,
        v(r), set and ("%.0f"):format(set) or "?"), edge, set
end

local function looksWatch(round, at, max)
    if QS.watching or QS.finished then return end
    -- shotDue at once: "look 0", the ground before any look.
    QS = { watching = true, n = 0, prev = nil, events = 0, shotDue = true, endAt = -math.huge, max = max or QLOOKS }
    if not qevf then
        qevf = CreateFrame("Frame")
        qevf:SetScript("OnEvent", function(_, event, ...)
            if not QS.watching then return end
            local n = nrAddon()
            local b = n and n.MoveScan and n.MoveScan._test and n.MoveScan._test.burst and n.MoveScan._test.burst()
            slog(MR, ("look watch: %s%s %s"):format(event, select("#", ...) > 0 and (" " .. v((...))) or "", b and "DURING a look" or "between looks"))
        end)
    end
    Probe:RegisterEvents(qevf, { "MINIMAP_UPDATE_ZOOM", "MINIMAP_UPDATE_TRACKING" })
    slog(MR, ("look watch: started, quest areas %s, zoom %s"):format(v(questIndex() and questActive(questIndex())), v(call(Minimap, "GetZoom"))))
    watch({ id = "blanklooks", round = round or QR, lo = at or 6, hi = at or 6, every = 0, fn = function()
        local now = GetTime()
        local n = nrAddon()
        local t = n and n.MoveScan and n.MoveScan._test
        local b = t and t.burst and t.burst()
        if b and not QS.prev then QS.startAt = now end
        if QS.prev and not b then
            QS.n = QS.n + 1
            QS.endAt, QS.shotDue = now, true
            slog(MR, ("look %d: ended after %.3f s, zoom %s, quest areas %s; %s"):format(QS.n, now - (QS.startAt or now), v(call(Minimap, "GetZoom")),
                v(questIndex() and questActive(questIndex())), (tileInfo())))
        end
        QS.prev = b
        -- Why the scan isn't looking, logged on each change and shown in the step's status.
        local ms = n and n.MoveScan
        if not b and ms and type(ms.Refusal) == "function" and now - (QS.refAt or 0) >= 0.5 then
            QS.refAt = now
            local okR, r = pcall(ms.Refusal, now)
            if not okR then r = "Refusal ERROR " .. tostring(r) end   -- nil: admitted
            if r == "the cursor is not over the world" then
                local okF, foci = pcall(GetMouseFoci)
                local f = okF and type(foci) == "table" and foci[1]
                r = r .. (f and (" (under it: %s, strata %s, level %s, mouse %s)"):format(v(call(f, "GetDebugName")), v(call(f, "GetFrameStrata")),
                    v(call(f, "GetFrameLevel")), v(call(f, "IsMouseEnabled")))
                    or (" (under it: nothing: GetMouseFoci %s, %s entries; WorldFrame mouse %s, shown %s; IsMouselooking %s; cursor %s,%s)"):format(
                        okF and type(foci) or ("ERROR " .. tostring(foci)), okF and type(foci) == "table" and #foci or "-",
                        v(call(g("WorldFrame"), "IsMouseEnabled")), v(call(g("WorldFrame"), "IsShown")),
                        v(select(2, pcall(g("IsMouselooking") or function() return "absent" end))), v((GetCursorPosition())), v(select(2, GetCursorPosition()))))
            end
            if r ~= QS.refusal then slog(MR, "look watch: the scan's refusal now " .. v(r)) end
            QS.refusal = r
        end
        if QS.shotDue and not b and now - QS.endAt >= SETTLE then
            QS.shotDue = false
            local k = QS.n
            local okq, err = pcall(Probe.Screenshot, Probe, k == 0 and "blankquest look 0 (before any look)" or ("blankquest look " .. k), function(file, why)
                slog(MR, ("look %d: screenshot %s"):format(k, file and tostring(file) or ("FAILED " .. tostring(why))))
            end)
            if not okq then slog(MR, "screenshot ERROR " .. tostring(err)) end
            if k >= QS.max then QS.done = true end   -- by the count, never by the screenshot's answer
        end
        return QS.done
    end, stop = function(_, why)
        QS.watching = false
        if QS.done then QS.finished = true end   -- once: the wait's next poll must not start it again
        if qevf then qevf:UnregisterAllEvents() end
        slog(MR, ("look watch: ended (%s), %d looks"):format(tostring(why or "done"), QS.n or 0))
    end })
end

local qsteps = {
    rev = 1,
    title = "The quest areas back on at alpha 0, then real looks (#111)",
    { text = "Stock UI (Glass MiniMap off), NodeRadar's scan off for now (/nr scan), out of combat, outdoors, with a quest tracked so the minimap shows quest areas. Press Check.",
      button = "Check", run = function()
          qstarted, QS = {}, {}
          walkState.qqalpha, walkState.qqlate = nil, nil
          local ok, why = preconditions()
          local i = questIndex()
          slog(MR, ("blankquest: quest areas tracking %s"):format(i and v(questActive(i)) or "absent"))
          return ok, why .. "; quest areas " .. (i and (questActive(i) and "on" or "OFF: turn Quest Areas on in the minimap's tracking menu") or "absent")
      end,
      check = function() local i = questIndex(); return B.preOK == true and i ~= nil and questActive(i) == true, B.preWhy end },
}
for k, arm in ipairs({ "qalpha", "qlate" }) do
    local walkAt, runAt = 2 * k, 2 * k + 1
    qsteps[#qsteps + 1] = { text = ("Arm %s: walk a few yards and stop, so the ground is freshly drawn. Then leave the mouse and keys alone: it starts by itself."):format(arm),
        wait = walkWait("q" .. arm, walkAt, QR), timeout = 180 }
    qsteps[#qsteps + 1] = { text = ("Running arm %s: alpha 0 and the quest areas off for the borrow, back on %s. A screenshot before and after. Stay still.")
        :format(arm, arm == "qalpha" and "with the map home but still at alpha 0 (the scan's order)" or "after the alpha is back"),
        wait = function()
            if not qstarted[arm] then
                qstarted[arm] = true
                local r = mstart(arm, QR, runAt, runAt)
                if r ~= "started" then return true, r end
            end
            if W.arm == arm and W.done then return true, W.skipped and "skipped" or ("geometry restored " .. tostring(W.geometry)) end
            return false, ("arm %s, %s"):format(arm, tostring(W.phase))
        end, timeout = 60,
        check = function() return W.arm == arm and W.done == true and not W.skipped and W.geometry == true,
            W.skipped and "skipped, see the log" or (W.endedBy and ("ended: " .. tostring(W.endedBy)) or "geometry restored") end }
end
qsteps[#qsteps + 1] = { text = ("Real looks: turn the scan on (/nr scan), then STAND STILL for the whole step, the mouse resting over the world (not over the minimap or anyone). "
    .. "It takes a screenshot first, then one after each of %d looks (about a minute), and goes on by itself at %d of %d."):format(QLOOKS, QLOOKS, QLOOKS),
    wait = function()
        if QS.finished then return true, ("%d looks"):format(QS.n or 0) end
        local n = nrAddon()
        if not (n and n.db and n.db.moveScan) then return false, "turn the scan on: /nr scan" end
        looksWatch()
        if QS.done then return true, ("%d looks"):format(QS.n) end
        return false, ("%d of %d looks"):format(QS.n or 0, QLOOKS)
    end, timeout = 300 }
qsteps[#qsteps + 1] = { text = "Which left the minimap's ground blank (the terrain missing inside the round frame) until you walked: qalpha, qlate, or a look (its number)? "
    .. "Type them in the note, or none. Not sure if you couldn't tell: the screenshots say.", ask = true }
Probe:Steps(QR, qsteps)

----------------------------------------------------------------------------
-- blankmove (#111): each part of a borrow alone, while the player moves
--   /fp steps nr blankmove
-- blankquest (70888, Glass MiniMap loaded): real looks blanked the ground in about half the
-- shots while the player walked slowly, and it came back within seconds; standing still,
-- no round ever blanked it. So the terrain must be redrawn while the map is borrowed. Each arm
-- here runs VREPS times while the player moves, a screenshot just before and 0.5 s after:
--   valpha alpha 0 only   voff off screen only   vsize SetSize 20 only (at home: a flash)
--   vall   the scan's way (alpha 0, off screen, 20 px, icon scale)
--   vmask  vall with the empty mask instead of alpha 0 (only the three add-ons; else skipped)
----------------------------------------------------------------------------
local VR = "blankmove"
local VREPS = 4
local VARMS = { "valpha", "voff", "vsize", "vall", "vmask" }
local VDESC = { valpha = "alpha 0 only", voff = "off screen only", vsize = "the size 20 px only (a short flash at home)",
    vall = "the scan's way: alpha 0, off screen, 20 px, icon scale", vmask = "the scan's way with the empty mask instead of alpha 0" }
local vstate = {}
local vsteps = {
    rev = 1,
    title = "The blank ground: each part of a look while moving (#111)",
    { text = "Stock UI (Glass MiniMap off), NodeRadar's scan off (/nr scan), out of combat, outdoors in open ground. For the last part (mask) only NodeRadar, ForeverProbe and NodeRadarProbe may be loaded (it skips itself otherwise). Press Check.",
      button = "Check", run = function()
          vstate = {}
          local ok, why = preconditions(true)
          local r = maskSkip()
          slog(MR, "blankmove: mask arm would " .. (r and ("skip: " .. r) or "run"))
          return ok, why .. "; mask arm: " .. (r or "will run")
      end,
      check = function() return B.preOK == true, B.preWhy end },
}
for i, arm in ipairs(VARMS) do
    local at = i + 1
    vsteps[#vsteps + 1] = { text = ("Part %d of %d, %s: %s. KEEP WALKING OR RUNNING the whole time (auto-run is fine, steer with the keys), mouse left alone. "
        .. "It goes on by itself after %d repeats; it pauses whenever you stop."):format(i, #VARMS, arm, VDESC[arm], VREPS),
        wait = function()
            local st = vstate[arm]
            if not st then st = { n = 0 }; vstate[arm] = st end
            if st.skipped then return true, st.skipped end
            if st.n == 0 or (W.arm == arm and W.done) then
                if st.n >= VREPS then return true, ("%d repeats"):format(st.n) end
                st.n = st.n + 1
                local r = mstart(arm, VR, at, at, st.n)
                if r ~= "started" then st.skipped = r; return true, r end
            end
            return false, ("%s repeat %d of %d: %s"):format(arm, st.n, VREPS, W.phase == "still" and "keep moving" or tostring(W.phase))
        end, timeout = 240 }
end
vsteps[#vsteps + 1] = { text = "Done: you can stop. Did you see the minimap's ground go blank during any part? Which (valpha, voff, vsize, vall, vmask)? Note it, or none. Not sure is fine: the screenshots say.", ask = true }
Probe:Steps(VR, vsteps)

----------------------------------------------------------------------------
-- blankcursor (#111): a presence look's own placement while moving, then real looks
--   /fp steps nr blankcursor
-- blankmove (70888, stock UI): no part of a borrow blanked the ground while moving, but the map
-- went off screen there; a real look places it on screen, 15.4 px under the cursor, and reads
-- the mouseover. Real looks blanked it (blankquest, Glass MiniMap loaded).
--   von      alpha 0, 15.4 px under the cursor, the read
--   vonq     von, the quest areas off for it and back on at alpha 0 (the scan's order)
--   vonmask  von with the empty mask instead of alpha 0 (only the three add-ons)
--   then the scan's own looks, 8, a screenshot after each
----------------------------------------------------------------------------
local CR = "blankcursor"
local CARMS = { "von", "vonq", "vonmask" }
local CDESC = { von = "alpha 0, the map 15 px under the cursor, the mouseover read",
    vonq = "the same, with the quest areas off and back on at alpha 0", vonmask = "the same with the empty mask instead of alpha 0" }
local csteps = {
    rev = 1,
    title = "The blank ground: a look's placement under the cursor while moving (#111)",
    { text = "Only NodeRadar, ForeverProbe and NodeRadarProbe loaded, NodeRadar's scan off (/nr scan), a quest tracked (quest areas on the minimap), out of combat, outdoors in open ground. Press Check.",
      button = "Check", run = function()
          vstate, QS = {}, {}
          local ok, why = preconditions(true)
          local r = maskSkip()
          local i = questIndex()
          slog(MR, ("blankcursor: mask arm would %s; quest areas %s"):format(r and ("skip: " .. r) or "run", i and v(questActive(i)) or "absent"))
          return ok, why .. "; mask arm: " .. (r or "will run") .. "; quest areas " .. (i and (questActive(i) and "on" or "OFF") or "absent")
      end,
      check = function() return B.preOK == true, B.preWhy end },
}
for i, arm in ipairs(CARMS) do
    local at = i + 1
    csteps[#csteps + 1] = { text = ("Part %d of 4, %s: %s. KEEP RUNNING the whole time (auto-run, steer with the keys), the mouse resting over the world. "
        .. "Goes on by itself after %d repeats; pauses whenever you stop."):format(i, arm, CDESC[arm], VREPS),
        wait = function()
            local st = vstate[arm]
            if not st then st = { n = 0 }; vstate[arm] = st end
            if st.skipped then return true, st.skipped end
            if st.n == 0 or (W.arm == arm and W.done) then
                if st.n >= VREPS then return true, ("%d repeats"):format(st.n) end
                st.n = st.n + 1
                local r = mstart(arm, CR, at, at, st.n)
                if r ~= "started" then st.skipped = r; return true, r end
            end
            return false, ("%s repeat %d of %d: %s"):format(arm, st.n, VREPS, W.phase == "still" and "keep moving" or tostring(W.phase))
        end, timeout = 240 }
end
csteps[#csteps + 1] = { text = ("Part 4 of 4, the scan's own looks: turn the scan on (/nr scan), then MOVE THE CURSOR OFF THIS PANEL onto open ground (not the minimap, not anyone) and let go of the mouse: no mouse buttons, no mouse steering (the scan waits otherwise). KEEP RUNNING, steering with the keys only. "
    .. "A screenshot first, then after each of %d looks; goes on by itself at %d of %d."):format(QLOOKS, QLOOKS, QLOOKS),
    wait = function()
        if QS.finished then return true, ("%d looks"):format(QS.n or 0) end
        local n = nrAddon()
        if not (n and n.db and n.db.moveScan) then return false, "turn the scan on: /nr scan" end
        looksWatch(CR, #CARMS + 2)
        if QS.done then return true, ("%d looks"):format(QS.n) end
        return false, ("%d of %d looks%s"):format(QS.n or 0, QLOOKS, QS.refusal and ("; the scan waits: " .. tostring(QS.refusal)) or "")
    end, timeout = 300 }
csteps[#csteps + 1] = { text = "Done: you can stop (and turn the scan off: /nr scan). Did the ground go blank in any part (von, vonq, vonmask, the looks)? Note it, or none.", ask = true }
Probe:Steps(CR, csteps)

----------------------------------------------------------------------------
-- blanklake (#111): real looks where the blank was seen
--   /fp steps nr blanklake
-- The only blanks (70888) were at Brightwater Lake in Tirisfal (map 67, 46), about 15 yd from a
-- minimap tile's edge; every clean run was elsewhere. Real looks there, each logged with where
-- the player is in the tiles and a screenshot after it.
----------------------------------------------------------------------------
local LR = "blanklake"
local LLOOKS = 12
local lsteps = {
    rev = 1,
    title = "The blank ground: real looks at Brightwater Lake (#111)",
    { text = "Go to Brightwater Lake in Tirisfal Glades (map 67, 46), any add-ons. Turn the scan on (/nr scan). Press Check: it shows where you are in the minimap's tiles.",
      button = "Check", run = function()
          QS = {}
          local info = tileInfo()
          slog(MR, "blanklake: " .. info)
          local n = nrAddon()
          return n and n.db and n.db.moveScan == true, info .. ((n and n.db and n.db.moveScan) and "" or "; the scan is off: /nr scan")
      end },
    { text = ("Walk slowly (the walk key, / on the number pad) around the lake's east shore, back and forth, the cursor resting on open ground (nudge the mouse once after clicking this panel). "
        .. "A screenshot first, then after each of %d looks; goes on by itself."):format(LLOOKS),
      wait = function()
          if QS.finished then return true, ("%d looks"):format(QS.n or 0) end
          local n = nrAddon()
          if not (n and n.db and n.db.moveScan) then return false, "turn the scan on: /nr scan" end
          looksWatch(LR, 2, LLOOKS)
          if QS.done then return true, ("%d looks"):format(QS.n) end
          return false, ("%d of %d looks; %s%s"):format(QS.n or 0, LLOOKS, (tileInfo()), QS.refusal and ("; the scan waits: " .. tostring(QS.refusal)) or "")
      end, timeout = 400 },
    { text = "Did the minimap's ground go blank after any look? Note roughly when, or none. Not sure is fine: the screenshots say.", ask = true },
}
Probe:Steps(LR, lsteps)
end

--------------------------------------------------------------------------------
-- queue (#115): the Group Finder eye while queued
--------------------------------------------------------------------------------
do
local ROUND = "queue"
local HOLD = 3
local Q = {}

local function eye() local e = g("QueueStatusButton"); if type(e) == "table" then return e end end

local function frameLine(f, depth)
    local l, b, w, h = call(f, "GetRect")
    local regions, shownRegions = call(f, "GetNumRegions"), 0
    if regions and regions > 0 then
        local ok, list = pcall(function() return { f:GetRegions() } end)
        if ok then for _, r in ipairs(list) do if call(r, "IsShown") == true then shownRegions = shownRegions + 1 end end end
    end
    return ("%s%s: shown %s visible %s alpha %s eff %s | mouse %s motion %s click %s | %s lvl %s | rect %s,%s %sx%s | regions %s (shown %s)"):format(
        ("  "):rep(depth), tostring(call(f, "GetDebugName") or "?"), v(call(f, "IsShown")), v(call(f, "IsVisible")), v(call(f, "GetAlpha")),
        v(call(f, "GetEffectiveAlpha")), v(call(f, "IsMouseEnabled")), v(call(f, "IsMouseMotionEnabled")), v(call(f, "IsMouseClickEnabled")),
        v(call(f, "GetFrameStrata")), v(call(f, "GetFrameLevel")), v(l), v(b), v(w), v(h), v(regions), shownRegions)
end

-- The whole subtree: one line per frame, children indented. onlyMouse: just the frames that take the mouse.
local function dump(label, onlyMouse)
    local root = eye()
    if not root then slog(ROUND, label .. ": QueueStatusButton does not exist"); return 0 end
    local count = 0
    local function walk(f, depth)
        if count >= 300 or depth > 10 then return end
        count = count + 1
        if not onlyMouse or call(f, "IsMouseEnabled") == true or call(f, "IsMouseMotionEnabled") == true then
            slog(ROUND, label .. " " .. frameLine(f, depth))
        end
        local ok, kids = pcall(function() return { f:GetChildren() } end)
        if ok then for _, k in ipairs(kids) do walk(k, depth + 1) end end
    end
    walk(root, 0)
    return count
end

local function foci(label)
    local ok, list = pcall(GetMouseFoci)
    if not ok or type(list) ~= "table" then slog(ROUND, label .. ": GetMouseFoci failed " .. tostring(list)); return nil end
    local names = {}
    for _, f in ipairs(list) do names[#names + 1] = tostring(call(f, "GetDebugName") or "?") end
    local e = eye()
    slog(ROUND, ("%s: GetMouseFoci = [%s]; cursor over the eye: %s"):format(label, table.concat(names, ", "),
        e and v(call(e, "IsMouseOver")) or "no eye"))
    return names
end

-- A hold: runs `measure` once the cursor has rested for HOLD seconds (a move over 3 px starts again).
local function holdWait(key, measure)
    return function()
        local now = GetTime()
        local cx, cy = GetCursorPosition()
        local h = Q.hold
        if not h or h.key ~= key then h = { key = key, t0 = now, x = cx, y = cy }; Q.hold = h end
        if math.abs(cx - h.x) > 3 or math.abs(cy - h.y) > 3 then h.t0, h.x, h.y = now, cx, cy end
        local left = HOLD - (now - h.t0)
        if left > 0 then return false, ("measuring in %d s: keep the mouse still"):format(math.ceil(left)) end
        if not h.result then
            local ok, r = pcall(measure)
            h.result = ok and (r or "measured") or ("FAILED " .. tostring(r))
            if not ok then slog(ROUND, key .. " MEASURE FAILED " .. tostring(r)) end
        end
        if h.pending then return false, "finishing" end
        Q.hold = nil
        return true, h.result
    end
end

-- Step 3: the scan's hold on the eye, saved first, put back on every path.
local function eyeRestore(why)
    local e, s = eye(), Q.saved
    if not (e and s) then return end
    local errs = {}
    if s.mouse ~= nil then local ok, err = pcall(e.EnableMouse, e, s.mouse); if not ok then errs[#errs + 1] = tostring(err) end end
    local ok, err = pcall(e.SetAlpha, e, s.alpha)
    if not ok then errs[#errs + 1] = tostring(err) end
    local a, m = call(e, "GetAlpha"), call(e, "IsMouseEnabled")
    local clean = #errs == 0 and a ~= nil and math.abs(a - s.alpha) < 0.01 and (s.mouse == nil or m == s.mouse)
    slog(ROUND, ("eye restore (%s): alpha %s -> %s, mouse %s -> %s %s%s"):format(tostring(why), v(s.alpha), v(a), v(s.mouse), v(m),
        clean and "clean" or "NOT CLEAN", #errs > 0 and (" " .. table.concat(errs, ", ")) or ""))
    if not clean then Q.dirty = true end
    Q.saved = nil
end

local function hiddenHold()
    local now = GetTime()
    local e = eye()
    if not e then return true, "no eye" end
    if not Q.hidden then
        Q.hiddenDone, Q.dirty = false, nil
        Q.saved = { alpha = call(e, "GetAlpha") or 1, mouse = call(e, "IsMouseEnabled") }
        Q.hidden = { t0 = now, x = select(1, GetCursorPosition()), y = select(2, GetCursorPosition()) }
        local ok1, e1 = pcall(e.SetAlpha, e, 0)
        local ok2, e2 = true, nil
        if Q.saved.mouse ~= nil then ok2, e2 = pcall(e.EnableMouse, e, false) end
        slog(ROUND, ("the eye held as the scan holds it: SetAlpha(0) %s, EnableMouse(false) %s; saved alpha %s mouse %s"):format(
            ok1 and "ok" or tostring(e1), ok2 and "ok" or tostring(e2), v(Q.saved.alpha), v(Q.saved.mouse)))
        watch({ id = "queueeye", round = ROUND, lo = 3, hi = 3, every = 0.25, fn = function() return Q.hiddenDone end,
                stop = function(_, why) if Q.saved then eyeRestore(why or "done") end end })
        return false, "the eye is hidden: hold the mouse still over where it was"
    end
    local h = Q.hidden
    local cx, cy = GetCursorPosition()
    if math.abs(cx - h.x) > 3 or math.abs(cy - h.y) > 3 then h.t0, h.x, h.y = now, cx, cy; Q.shotAsked = nil end
    local held = now - h.t0
    if held >= HOLD / 2 and not Q.shotAsked then
        Q.shotAsked = true
        Q.shotDone = false
        local okq, err = pcall(Probe.Screenshot, Probe, "queue eye hidden", function(file, why)
            Q.shotDone = true
            slog(ROUND, "screenshot of the eye area while hidden: " .. (file and tostring(file) or ("FAILED " .. tostring(why))))
        end)
        if not okq then Q.shotDone = true; slog(ROUND, "screenshot ERROR " .. tostring(err)) end
    end
    if held < HOLD or not Q.shotDone then return false, "holding: keep the mouse still" end
    foci("while hidden")
    dump("while hidden", true)
    Q.hiddenDone = true
    unwatch("queueeye", "done")
    Q.hidden = nil
    local a, m = call(e, "GetAlpha"), call(e, "IsMouseEnabled")
    return true, ("restored: alpha %s mouse %s%s"):format(v(a), v(m), Q.dirty and " (NOT CLEAN)" or "")
end

Probe:Steps("queue", {
    rev = 1,
    title = "The Group Finder eye while queued (#115)",
    { text = "Queue for something in the Group Finder (any dungeon or role), wait until the eye shows, then press Check now.",
      button = "Check now", run = function()
          local e = eye()
          slog(ROUND, "build " .. tostring(select(2, GetBuildInfo())) .. "; QueueStatusButton " .. (e and ("exists, " .. frameLine(e, 0)) or "MISSING"))
          local n = dump("subtree")
          return ("%d frame(s) in the subtree; eye visible %s"):format(n, v(e and call(e, "IsVisible")))
      end,
      check = function() local e = eye(); return e ~= nil and call(e, "IsVisible") == true, "the eye must be visible (queued)" end },
    { text = "Hold your mouse still over the eye for 3 s. It measures by itself.",
      wait = holdWait("eye-foci", function()
          local names = foci("over the eye")
          return names and (#names .. " mouse focus entr" .. (#names == 1 and "y" or "ies")) or "no foci"
      end), timeout = 90 },
    { text = "Now the eye is hidden the way the scan hides it. Hold your mouse still over where it was for 3 s, and do not click. It restores by itself and takes a screenshot meanwhile.",
      wait = hiddenHold, timeout = 90,
      check = function() return not Q.dirty, "the eye's alpha and mouse state came back" end },
    { text = "Did the eye flicker, or stay partly visible (a ring, a border, an icon) while it was hidden? (The screenshot is named 'queue eye hidden'.)", ask = true },
})
end

--------------------------------------------------------------------------------
-- range (#112): how far a node's icon stays
--------------------------------------------------------------------------------
do
local ROUND = "range"
local R = { seen = {}, label = "?" }

local function watching()
    local n = nrAddon()
    return n, n and n.db
end

local function logZoom(tag)
    slog(ROUND, ("%s: Minimap:GetZoom() %s, C_Minimap.GetViewRadius() %s, player at %s"):format(tag, v(call(Minimap, "GetZoom")), v(viewRadius()), playerPos()))
end

-- Logs every new "locate:" trace line as it appears, with the player's place and the view then.
local function startWatcher()
    unwatch("range", "restart")
    R.seen = {}
    R.t0 = GetTime()
    R.drops = {}
    watch({ id = "range", round = ROUND, lo = 2, hi = 5, every = 0.2, fn = function()
        for _, line in ipairs(traceLines(R.t0 - 0.1, "locate:")) do
            if not R.seen[line] then
                R.seen[line] = true
                local yd = line:match("%((%d+) yd%)") or line:match("(%d+) yd")
                slog(ROUND, ("[%s] %s | player %s, view radius %s, zoom %s%s"):format(R.label, line, playerPos(), v(viewRadius()), v(call(Minimap, "GetZoom")),
                    yd and (" | reported distance " .. yd .. " yd") or ""))
                if line:find("dropped", 1, true) and yd then R.drops[#R.drops + 1] = ("%s: %s yd"):format(R.label, yd) end
            end
        end
    end })
end

Probe:Steps("range", {
    rev = 1,
    title = "How far a node's icon stays (#112)",
    { text = "Turn the minimap scan on (/nr scan) and the icons on (Options), stand outdoors, then press Check.",
      button = "Check", run = function()
          local n, db = watching()
          if not n then slog(ROUND, "NodeRadar is not loaded"); return "NodeRadar is not loaded" end
          slog(ROUND, ("build %s; db.moveScan %s, db.icons %s; trace lines %s"):format(tostring(select(2, GetBuildInfo())), tostring(db and db.moveScan),
              tostring(db and db.icons), type(n.trace) == "table" and #n.trace or "no trace"))
          logZoom("start")
          return ("scan %s, icons %s"):format(tostring(db and db.moveScan), tostring(db and db.icons))
      end,
      check = function() local n, db = watching(); return db and db.moveScan == true and db.icons == true, "the scan and the icons must both be on" end },
    { text = "Zoom the minimap all the way out (the - button), then press Check.",
      button = "Check", run = function() R.label = "zoomed out"; logZoom("zoomed out"); startWatcher(); return ("zoom %s, radius %s"):format(v(call(Minimap, "GetZoom")), v(viewRadius())) end },
    { text = "Find a herb or vein with no other of its name near it and wait until its icon shows on the minimap. Then walk (don't mount) straight away from it until its icon goes, and press Done.",
      button = "Done", run = function()
          logZoom("walk ended (" .. R.label .. ")")
          local lines = traceLines(R.t0 - 0.1, "locate:")
          slog(ROUND, ("[%s] %d locate: line(s) since the walk began; drops %s"):format(R.label, #lines, #R.drops > 0 and table.concat(R.drops, ", ") or "none"))
          return #R.drops > 0 and table.concat(R.drops, ", ") or ("no drop line (" .. #lines .. " locate lines)")
      end },
    { text = "Now zoom the minimap in one step (the + button once), then press Check.",
      button = "Check", run = function() R.label = "one step in"; logZoom("one step in"); startWatcher(); return ("zoom %s, radius %s"):format(v(call(Minimap, "GetZoom")), v(viewRadius())) end },
    { text = "Again: find a lone herb or vein, wait for its icon, walk straight away (don't mount) until its icon goes, and press Done.",
      button = "Done", run = function()
          logZoom("walk ended (" .. R.label .. ")")
          local lines = traceLines(R.t0 - 0.1, "locate:")
          slog(ROUND, ("[%s] %d locate: line(s) since the walk began; drops %s"):format(R.label, #lines, #R.drops > 0 and table.concat(R.drops, ", ") or "none"))
          return #R.drops > 0 and table.concat(R.drops, ", ") or ("no drop line (" .. #lines .. " locate lines)")
      end },
    { text = "Anything odd (an icon that stayed long after you left, went early, or flickered)? Say what in the note.", ask = true },
})
end

--------------------------------------------------------------------------------
-- ground (#117): the stand-in's real ground
--------------------------------------------------------------------------------
do
local ROUND = "ground"
local SECONDS = 4

local function face()
    local n = nrAddon()
    local sf = n and n.ScanFace
    if type(sf) == "table" and type(sf.Preview) == "function" and type(sf.Ground) == "function" then return sf end
end

local function stopRound(why)
    slog(ROUND, "STOPPED: " .. why)
    local FP = g("ForeverProbe")
    if type(FP) == "table" and type(FP.Steps) == "table" and type(FP.Steps.Stop) == "function" then pcall(FP.Steps.Stop, why) end
end

local function show(tag)
    return function()
        local sf = face()
        if not sf then
            stopRound("NodeRadar.ScanFace.Preview / Ground do not exist on this build of NodeRadar")
            return "ScanFace.Preview missing"
        end
        local w = num(call(Minimap, "GetWidth")) or 140
        local es, ues = num(call(Minimap, "GetEffectiveScale")) or 1, num(call(UIParent, "GetEffectiveScale")) or 1
        local dx = -(w * es / ues + 10)
        local okG, ground, gwhy = pcall(sf.Ground)
        slog(ROUND, ("%s: zoom %s, radius %s, rotate %s, indoors %s, player %s; Minimap %sx%s (es %s, UIParent es %s) so dx %.1f; Ground() = %s%s"):format(
            tag, v(call(Minimap, "GetZoom")), v(viewRadius()), tostring(GetCVar and GetCVar("rotateMinimap")),
            tostring(select(2, pcall(IsIndoors))), playerPos(), v(w), v(call(Minimap, "GetHeight")), v(es), v(ues), dx,
            okG and v(ground) or ("ERROR " .. tostring(ground)), gwhy and (" (" .. v(gwhy) .. ")") or ""))
        -- The player's tile: our table's FileDataID against the client's own answer for its path
        -- (GetFileIDFromPath; the listfile's IDs aren't proof the client has those files).
        do
            local okP, n, wv, _, inst = pcall(UnitPosition, "player")
            local T = 1600 / 3
            local folder = ({ [0] = "azeroth", [1] = "kalimdor" })[okP and inst or -1]
            if okP and n and wv and folder then
                local x, y = math.floor(32 - wv / T), math.floor(32 - n / T)
                local path = ("world/minimaps/%s/map%d_%d.blp"):format(folder, x, y)
                local tiles = NodeRadar and NodeRadar.MINIMAP_TILES and NodeRadar.MINIMAP_TILES[inst]
                local okF, fid = pcall(GetFileIDFromPath, path)
                slog(ROUND, ("%s: tile %d_%d: table %s, GetFileIDFromPath(%s) = %s"):format(tag, x, y,
                    v(tiles and tiles[x * 64 + y]), path, okF and v(fid) or ("ERROR " .. tostring(fid))))
            end
        end
        local ok, res, why = pcall(sf.Preview, dx, 0, SECONDS)
        local okS, shape, crop, how = false
        if type(sf.Shape) == "function" then okS, shape, crop, how = pcall(sf.Shape) end
        slog(ROUND, ("%s: Preview(%.1f, 0, %d) = %s%s; lastGround %s; shape %s"):format(tag, dx, SECONDS, ok and v(res) or ("ERROR " .. tostring(res)),
            why and (", " .. v(why)) or "", v(sf.lastGround), okS and (v(shape) .. " crop " .. v(crop) .. " from " .. v(how)) or "?"))
        C_Timer.After(1, function()
            local okq, err = pcall(Probe.Screenshot, Probe, "ground " .. tag, function(file, w2)
                slog(ROUND, tag .. ": screenshot " .. (file and tostring(file) or ("FAILED " .. tostring(w2))))
            end)
            if not okq then slog(ROUND, tag .. ": screenshot ERROR " .. tostring(err)) end
        end)
        return ok and res and "preview shown" or ("no preview: " .. (ok and v(why) or tostring(res)))
    end
end

Probe:Steps("ground", {
    rev = 1,
    title = "The stand-in's ground against the real minimap (#117)",
    { text = "Needs NodeRadar's ScanFace.Preview. Stand still outdoors. Press Check.",
      button = "Check", run = function()
          local sf = face()
          if not sf then stopRound("NodeRadar.ScanFace.Preview / Ground do not exist on this build of NodeRadar"); return "missing" end
          local ok, ground, why = pcall(sf.Ground)
          slog(ROUND, "build " .. tostring(select(2, GetBuildInfo())) .. "; ScanFace.Ground() = " .. (ok and v(ground) or tostring(ground)) .. (why and (" (" .. v(why) .. ")") or ""))
          return ok and v(ground) or "error"
      end },
    { text = "Zoom the minimap all the way out, stand still outdoors, then press Show: our copy appears for 4 s to the left of the real map, with a screenshot.",
      button = "Show", run = show("zoomed out") },
    { text = "Zoom the minimap all the way in (the closest zoom), then press Show.",
      button = "Show", run = show("closest zoom") },
    { text = "Turn on Rotate Minimap (Esc > Options > Interface > Display, or skip this step), then press Show.",
      button = "Show", run = show("rotated") },
    { text = "Go inside a building or a cave (or skip this step), then press Show. Turn Rotate Minimap back off afterwards if you like.",
      button = "Show", run = show("indoors") },
    { text = "Does ours line up with the real minimap (terrain, roads, water) and is its colour close? The shots are named 'ground <case>'. Say what differs in the note.", ask = true },
})
end

--------------------------------------------------------------------------------
-- scanbusy (#113, #114, #116): the scan's new refusals and its trouble line
--------------------------------------------------------------------------------
do
local ROUND = "scanbusy"
local SB = { hits = {}, seen = {} }

local function ms()
    local n = nrAddon()
    local m = n and n.MoveScan
    if type(m) == "table" then return m end
end
local function refusal()
    local m = ms()
    local r = m and m.lastRefusal
    if r ~= nil and (type(r) ~= "string" or secret(r)) then return "<" .. type(r) .. ">" end
    return r
end
local function trouble()
    local m = ms()
    if not (m and type(m.Trouble) == "function") then return nil end
    local ok, key, text, hint = pcall(m.Trouble)
    if not ok then return "ERROR", tostring(key) end
    return key, text, hint
end

-- A step that waits for lastRefusal to read `expected`. A watcher samples every 0.1 s, so a refusal that flickers
-- between polls still counts; each new value seen is logged once.
local function refusalStep(index, text, expected, timeout)
    return { text = text, timeout = timeout or 30,
        wait = function()
            if not ms() then return false, "NodeRadar.MoveScan is missing" end
            if not SB.hits[expected] and not watches["sb" .. index] then
                SB.seen = {}
                watch({ id = "sb" .. index, round = ROUND, lo = index, hi = index, every = 0.1, fn = function()
                    local r = refusal()
                    local key = tostring(r)
                    if not SB.seen[key] then
                        SB.seen[key] = true
                        slog(ROUND, ("step %d: lastRefusal now %s%s"):format(index, v(r), r == expected and "  <- the expected one" or ""))
                    end
                    if r == expected then SB.hits[expected] = true; return true end
                end })
            end
            if SB.hits[expected] then return true, "lastRefusal = " .. expected end
            return false, ("last refusal %s, want %s"):format(v(refusal()), expected)
        end,
        check = function() return SB.hits[expected] == true, "want '" .. expected .. "'; saw " .. v(refusal()) end }
end

-- Trouble() key wanted.
local function troubleStep(text, wantKey, timeout)
    return { text = text, timeout = timeout or 60,
        wait = function()
            local key, t, hint = trouble()
            if not ms() then return false, "NodeRadar.MoveScan is missing" end
            if key == wantKey then
                slog(ROUND, ("Trouble() = %s, %s, %s"):format(v(key), v(t), v(hint)))
                SB.trouble = { key, t, hint }
                return true, "Trouble() key " .. tostring(key)
            end
            return false, "Trouble() key " .. v(key) .. ", want " .. wantKey
        end,
        check = function() return SB.trouble ~= nil and SB.trouble[1] == wantKey, "Trouble() text: " .. v(SB.trouble and SB.trouble[2]) end }
end

local noTracking = troubleStep("", "no tracking")
local regenFrame
local function regenStart()
    if regenFrame then return end
    regenFrame = CreateFrame("Frame")
    regenFrame:SetScript("OnEvent", function()
        SB.regenAt, SB.delta, SB.line = GetTime(), nil, nil
        slog(ROUND, "PLAYER_REGEN_ENABLED")
    end)
    Probe:RegisterEvents(regenFrame, { "PLAYER_REGEN_ENABLED" })
end

local list = {
    rev = 1,
    title = "The scan's refusals and trouble line (#113, #114, #116)",
    { text = "Turn the minimap scan on (/nr scan), stand outdoors out of combat with the mouse over the world, then press Check.",
      button = "Check", run = function()
          local m = ms()
          local n = nrAddon()
          slog(ROUND, ("build %s; MoveScan %s, db.moveScan %s, lastRefusal %s, Trouble %s"):format(tostring(select(2, GetBuildInfo())), m and "present" or "MISSING",
              tostring(n and n.db and n.db.moveScan), v(refusal()), m and type(m.Trouble) or "-"))
          local k, t, h = trouble()
          slog(ROUND, ("Trouble() = %s, %s, %s"):format(v(k), v(t), v(h)))
          return ("lastRefusal %s, Trouble %s"):format(v(refusal()), v(k))
      end,
      check = function() local n = nrAddon(); return n and n.db and n.db.moveScan == true and ms() ~= nil, "the scan must be on" end },
    refusalStep(2, "Start aiming a ground-targeted spell or a targeted item (the cursor turns into a targeting cursor) and hold it over the world.", "aiming a spell"),
    refusalStep(3, "Cancel that. Pick up an item from your bags onto the cursor and hold it over the world.", "something on the cursor"),
    refusalStep(4, "Put the item back. Hover a creature or player with your mouse and hold still.", "a unit under the mouse"),
    refusalStep(5, "Rest your mouse just outside the minimap's edge (on a button around it, or within a finger's width of the edge).", "the cursor is near the minimap"),
    refusalStep(6, "Open a loot window (kill something or open a container) and leave it open.", "a loot window is open", 90),
    { text = "Close the loot window. Then turn off Find Herbs and Find Minerals (the minimap's tracking menu), and leave the mouse over the world.",
      wait = noTracking.wait, timeout = 90, check = noTracking.check },
    { text = "Open Esc > Options > AddOns > NodeRadar. Is there a red line under the minimap scan saying why it isn't running?", ask = true, screenshot = "scanbusy options page" },
    { text = "Close the options and turn your tracking back on (Find Herbs and/or Find Minerals).",
      wait = function()
          local key = trouble()
          if key ~= "no tracking" then return true, "Trouble() key " .. v(key) end
          return false, "Trouble() key still 'no tracking'"
      end, timeout = 180 },
    { text = "Fight something. When the fight ends, stand still (don't move, keep the mouse over the world). It measures by itself.",
      wait = function()
          regenStart()
          if not SB.regenAt then return false, "waiting for the fight to end" end
          if not SB.delta then
              for _, line in ipairs(traceLines(SB.regenAt - 0.05, "scan: ")) do
                  if line:find("scan: burst", 1, true) or line:find("scan: read", 1, true) then
                      local ts = tonumber(line:match("^(%S+)"))
                      SB.delta, SB.line = math.max(0, ts - SB.regenAt), line
                      slog(ROUND, ("first look %.1f s after PLAYER_REGEN_ENABLED: %s"):format(SB.delta, line))
                      break
                  end
              end
          end
          if SB.delta then return true, ("%.1f s to the first look"):format(SB.delta) end
          return false, ("%.0f s since the fight ended, no look yet (lastRefusal %s)"):format(GetTime() - SB.regenAt, v(refusal()))
      end, timeout = 120,
      check = function() return SB.delta ~= nil and SB.delta < 2, SB.delta and ("%.1f s (pass under 2 s)"):format(SB.delta) or "no look seen" end },
}
-- Steps 2..: a wait with no `check` text wanted; the table rows above reuse troubleStep's functions.
Probe:Steps("scanbusy", list)
end

--------------------------------------------------------------------------------
-- snap (#122): NodeRadar's minimap icons with and without pixel snapping, live
--   /fp nr snap        toggle: snapping off on every icon texture and mask (and back)
-- An A/B for the eye: walk or ride slowly with icons on and watch an icon against the
-- ground and its blip, once each way. Off: SetSnapToPixelGrid(false) and
-- SetTexelSnappingBias(0) on every region of NodeRadar's icon frames (found by their
-- fields: .tex and .arrowFrame), new frames too (a 0.5 s ticker); back: each region's own
-- values, read before the first change.
--------------------------------------------------------------------------------
do
local ROUND = "snap"
local SN = { off = false, saved = {}, ticker = nil }

local function iconFrames()
    local out = {}
    local kids = { pcall(Minimap.GetChildren, Minimap) }
    if not table.remove(kids, 1) then return out end
    for _, f in ipairs(kids) do
        if type(f) == "table" and type(rawget(f, "tex")) == "table" and type(rawget(f, "arrowFrame")) == "table" then
            out[#out + 1] = f
        end
    end
    return out
end

-- Every texture and mask under a frame, its descendants' too.
local function regions(f, out, depth)
    if depth > 4 then return out end
    local regs = { pcall(f.GetRegions, f) }            -- every region (call() keeps only five)
    if table.remove(regs, 1) then
        for _, r in ipairs(regs) do
            if type(r) == "table" and type(r.SetSnapToPixelGrid) == "function" then out[#out + 1] = r end
        end
    end
    local kids = { pcall(f.GetChildren, f) }
    if table.remove(kids, 1) then
        for _, c in ipairs(kids) do regions(c, out, depth + 1) end
    end
    return out
end

local function apply()
    local n, failed = 0, 0
    for _, f in ipairs(iconFrames()) do
        for _, r in ipairs(regions(f, {}, 0)) do
            if not SN.saved[r] then
                SN.saved[r] = { snap = call(r, "IsSnappingToPixelGrid"), bias = call(r, "GetTexelSnappingBias") }
                local ok = pcall(r.SetSnapToPixelGrid, r, false) and pcall(r.SetTexelSnappingBias, r, 0)
                if ok then n = n + 1 else failed = failed + 1 end
            end
        end
    end
    if n > 0 or failed > 0 then slog(ROUND, ("snapping off on %d more regions (%d failed)"):format(n, failed)) end
    return n
end

local function restore()
    local n = 0
    for r, s in pairs(SN.saved) do
        if s.snap ~= nil then pcall(r.SetSnapToPixelGrid, r, s.snap) end
        if s.bias ~= nil then pcall(r.SetTexelSnappingBias, r, s.bias) end
        n = n + 1
    end
    SN.saved = {}
    return n
end

Probe:Command("snap", function()
    if not SN.off then
        SN.off = true
        local frames = #iconFrames()
        local first
        for _, f in ipairs(iconFrames()) do first = first or f.tex; break end
        if first then
            slog(ROUND, ("before: an icon texture snaps %s, bias %s"):format(v(call(first, "IsSnappingToPixelGrid")), v(call(first, "GetTexelSnappingBias"))))
        end
        apply()
        SN.ticker = C_Timer.NewTicker(0.5, apply)
        slog(ROUND, ("OFF: pixel snapping off on NodeRadar's icons (%d frames so far). /fp nr snap again to put it back."):format(frames))
    else
        SN.off = false
        if SN.ticker then SN.ticker:Cancel(); SN.ticker = nil end
        slog(ROUND, ("ON: pixel snapping back as it was on %d regions"):format(restore()))
    end
end, "#122: NodeRadar's minimap icons with pixel snapping off, and back (a toggle)")
end

--------------------------------------------------------------------------------
-- mem: where NodeRadar's memory churn comes from (the owner: 50-80 MB with two gatherers)
--   /fp nr mem [seconds per phase, default 20]
-- The memory the game shows includes garbage not yet collected: what matters is how fast it
-- grows. Phases, each `secs` seconds: as is; other frames not quieted (scanQuiet off); the scan
-- off; the scan back on with icons, compass and marker off. Every 0.5 s UpdateAddOnMemoryUsage
-- and NodeRadar's figure; the growth summed (drops are collections), per second, with the
-- scan's bursts and the minimap's descendants. Settings put back at the end. Stand still or
-- walk the same way through all of it, the cursor over the world.
--------------------------------------------------------------------------------
do
local ROUND = "mem"
local MM = {}

local function descendants()
    local n = 0
    local function walk(f, d)
        local ok, kids = pcall(function() return { f:GetChildren() } end)
        if not ok then return end
        for _, k in ipairs(kids) do n = n + 1; if d < 6 then walk(k, d + 1) end end
    end
    walk(Minimap, 1)
    return n
end

local function memNow()
    local up, get = g("UpdateAddOnMemoryUsage"), g("GetAddOnMemoryUsage")
    if type(up) ~= "function" or type(get) ~= "function" then return nil end
    pcall(up)
    local ok, kb = pcall(get, "NodeRadar")
    return ok and tonumber(kb) or nil
end

local PHASES = {
    { name = "as is", set = function() end },
    { name = "others not quieted (scanQuiet off)", set = function(n) n.db.scanQuiet = false end },
    { name = "the scan off", set = function(n) n.db.scanQuiet = MM.saved.scanQuiet; n.Set("moveScan", false) end },
    { name = "the scan on, icons, compass and marker off", set = function(n)
        n.Set("moveScan", true); n.Set("icons", false); n.Set("compass", false); n.Set("marker", false) end },
}

local function finish(why)
    local n = nrAddon()
    if MM.ticker then MM.ticker:Cancel(); MM.ticker = nil end
    if n and n.db and MM.saved then
        n.db.scanQuiet = MM.saved.scanQuiet
        if n.db.moveScan ~= MM.saved.moveScan then n.Set("moveScan", MM.saved.moveScan) end
        for _, k in ipairs({ "icons", "compass", "marker" }) do
            if n.db[k] ~= MM.saved[k] then n.Set(k, MM.saved[k]) end
        end
    end
    slog(ROUND, "ended (" .. tostring(why) .. "), settings put back")
    MM.running = false
end

local function phaseLine(p)
    local secs = p.t1 - p.t0
    slog(ROUND, ("%s: %.0f s, grew %.0f KB (%.1f KB/s), %d drops, %s -> %s KB now, %d bursts, %s minimap descendants"):format(
        p.name, secs, p.grew, secs > 0 and p.grew / secs or 0, p.drops, v(p.first), v(p.last), p.bursts, tostring(p.desc)))
end

Probe:Command("mem", function(args)
    local n = nrAddon()
    if not (n and n.db) then slog(ROUND, "NodeRadar isn't loaded"); return end
    if MM.running then finish("stopped"); return end
    local secs = tonumber(args and args:match("%d+")) or 20
    if not memNow() then slog(ROUND, "GetAddOnMemoryUsage is missing"); return end
    MM = { running = true, i = 0, saved = { scanQuiet = n.db.scanQuiet, moveScan = n.db.moveScan, icons = n.db.icons,
        compass = n.db.compass, marker = n.db.marker } }
    slog(ROUND, ("started: %d phases of %d s; NodeRadar at %s KB; scan %s, icons %s, compass %s, marker %s; build %s"):format(
        #PHASES, secs, v(memNow()), tostring(n.db.moveScan), tostring(n.db.icons), tostring(n.db.compass), tostring(n.db.marker),
        tostring(select(2, GetBuildInfo()))))
    local function nextPhase()
        MM.i = MM.i + 1
        local p = PHASES[MM.i]
        if not p then finish("done"); return end
        pcall(p.set, n)
        local ms = n.MoveScan and n.MoveScan.stats
        MM.p = { name = p.name, t0 = GetTime(), grew = 0, drops = 0, prev = memNow(), b0 = ms and ms.bursts or 0, desc = descendants() }
        MM.p.first = MM.p.prev
    end
    nextPhase()
    MM.ticker = C_Timer.NewTicker(0.5, function()
        local p = MM.p
        if not p then return end
        local m = memNow()
        if m and p.prev then
            if m >= p.prev then p.grew = p.grew + (m - p.prev) else p.drops = p.drops + 1 end
        end
        p.prev, p.last = m or p.prev, m or p.last
        if GetTime() - p.t0 >= secs then
            p.t1 = GetTime()
            local ms = n.MoveScan and n.MoveScan.stats
            p.bursts = (ms and ms.bursts or 0) - p.b0
            phaseLine(p)
            nextPhase()
        end
    end)
end, "NodeRadar's memory churn by phase: as is, others not quieted, the scan off, icons off (/fp nr mem [s]; again to stop)")
end

--------------------------------------------------------------------------------
-- alloc: which of NodeRadar's functions allocate (the memory churn, `mem`'s follow-up)
--   /fp nr alloc [seconds, default 20]
-- Wraps every function in NodeRadar's module tables (NR.MoveScan, NR.Learn, NR.ScanFace, NR.API,
-- ...; not _test) for `secs` seconds, adding collectgarbage("count")'s growth across each call
-- (inclusive: a caller counts its callees; a collection inside a call reads negative and is
-- skipped), then puts every function back and logs the top 25 by KB. Calls through a local
-- copy of a function aren't seen; they count in their caller.
--------------------------------------------------------------------------------
do
local ROUND = "alloc"
local AL = {}

local function restoreAll()
    for _, w in ipairs(AL.wrapped or {}) do
        if w.t[w.k] == w.wrapper then w.t[w.k] = w.orig end
    end
    AL.wrapped = {}
end

local function report()
    local list = {}
    for name, s in pairs(AL.stats or {}) do list[#list + 1] = { name, s } end
    table.sort(list, function(a, b) return a[2].kb > b[2].kb end)
    local total = collectgarbage("count")
    slog(ROUND, ("%d functions wrapped; the top by KB allocated in %.0f s (inclusive):"):format(#(AL.wrapped or {}), GetTime() - AL.t0))
    for i = 1, math.min(25, #list) do
        local name, s = list[i][1], list[i][2]
        if s.kb < 1 then break end
        slog(ROUND, ("%2d. %s: %.0f KB in %d calls (%.2f KB a call)"):format(i, name, s.kb, s.calls, s.kb / math.max(1, s.calls)))
    end
end

Probe:Command("alloc", function(args)
    local n = nrAddon()
    if not n then slog(ROUND, "NodeRadar isn't loaded"); return end
    if AL.running then
        if AL.timer then AL.timer:Cancel() end
        restoreAll(); report(); AL.running = false
        slog(ROUND, "stopped early, everything put back")
        return
    end
    local secs = tonumber(args and args:match("%d+")) or 20
    AL = { running = true, stats = {}, wrapped = {}, t0 = GetTime() }
    for modName, mod in pairs(n) do
        if type(mod) == "table" and modName ~= "_test" and modName ~= "db" and modName ~= "charDb" and modName ~= "trace" then
            for k, f in pairs(mod) do
                if type(f) == "function" and k ~= "_test" then
                    local name = modName .. "." .. k
                    local st = { kb = 0, calls = 0 }
                    AL.stats[name] = st
                    local orig = f
                    -- No table of our own per call: the results pass through as varargs.
                    local function done(before, ok, ...)
                        local d = collectgarbage("count") - before
                        if d > 0 then st.kb = st.kb + d end
                        st.calls = st.calls + 1
                        if not ok then error((...), 0) end
                        return ...
                    end
                    local wrapper = function(...)
                        return done(collectgarbage("count"), pcall(orig, ...))
                    end
                    mod[k] = wrapper
                    AL.wrapped[#AL.wrapped + 1] = { t = mod, k = k, orig = orig, wrapper = wrapper }
                end
            end
        end
    end
    slog(ROUND, ("started: %d functions wrapped for %d s; play as usual, the scan on"):format(#AL.wrapped, secs))
    AL.timer = C_Timer.NewTimer(secs, function()
        restoreAll(); report(); AL.running = false
        slog(ROUND, "ended (done), everything put back")
    end)
end, "Which NodeRadar functions allocate memory: wraps them for N s, then the top 25 by KB (/fp nr alloc [s])")
end
