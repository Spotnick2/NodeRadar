--------------------------------------------------------------------------------
-- movescan2 and movescan3 (/fp steps nr movescan2, /fp steps nr movescan3): the last
-- measurements before #91's code (docs/PLAN.md, "Probe before the code"). They reuse
-- the borrow, restore and readback machinery of the movescan round (NodeRadarProbe.lua,
-- NS._ms) and add the plan's burst: borrow + prepare (frame 1), place (2), settle (3),
-- read + restore (4), settle and readback (5), every burst with its own record.
--
--   movescan2 (mostly automatic): the hit square H, a read at the presence size with a
--   node at the rim, the tooltip suppression, what a valid-empty read looks like, a
--   locate-like refinement while the owner moves, the presence size at a second UI scale.
--   movescan3 (interactive): clicks and mouselook in each burst phase, a fight and Edit
--   Mode mid-burst, a low frame rate, what travels with Minimap, a skin that re-anchors it,
--   a riding cadence.
--
-- Saved: NodeRadarProbeDB.movescan2 = { lines (every line, "<time> ms2: <step> b<frame>
-- ..."), results (structured, by key), events (input and combat events by phase),
-- input (tallies), aborts, fpsPending (the maxFPS value to put back) }.
-- Output goes to the /fp console (loud lines only) and the saved log, never chat.
--------------------------------------------------------------------------------
local ADDON, NS = ...
local M = NS._ms
if not M then return end                       -- the main probe file did not load

local Probe = M.Probe
local say, str, num, secret = M.say, M.str, M.num, M.secret
local KEY2, KEY3 = Probe.name .. "/movescan2", Probe.name .. "/movescan3"
local PLACE_TOL = 1                            -- map units: the placement check (docs/PLAN.md, read validity)
local PRESENCE_PX = 15.4                       -- the plan's presence size, in screen pixels

-- The state of the round, in one place (tests reset it).
local W = {
    bf = 0, phase = "idle", suppress = false, inBurst = false, burstN = 0,
    lastMove = 0, lastUp = -99, ml = false, supCount = 0,
}

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

local function db()
    local d = rawget(_G, "NodeRadarProbeDB")
    if type(d) ~= "table" then return nil end
    if type(d.movescan2) ~= "table" then d.movescan2 = {} end
    return d.movescan2
end

local MAX_LINES = 6000
local function slog(step, text, loud)
    local line = ("%.2f ms2: %s b%d %s"):format(GetTime(), step, W.bf, text)
    local d = db()
    if d then
        d.lines = d.lines or {}
        d.lines[#d.lines + 1] = line
        while #d.lines > MAX_LINES do table.remove(d.lines, 1) end
    end
    if loud then say("ms2: " .. step .. " " .. text) end
end

local function store(key, value)
    local d = db()
    if d then d.results = d.results or {}; d.results[key] = value end
end

local function tallyInto(t, key) t[key] = (t[key] or 0) + 1 end

--------------------------------------------------------------------------------
-- Pure logic (tests/test_probe_movescan2.lua)
--------------------------------------------------------------------------------

-- What a read answered, as a shape. Node texts are kept (the shipped library's names);
-- players and anything else are only counted (a probe's saved file is shared).
local function classify(data, kindOf, isPlayer)
    local r = { nodes = {}, nNode = 0, nPlayer = 0, nOther = 0, nlines = 0 }
    if secret(data) then r.kind = "secret"; return r end
    if data == nil then r.kind = "nil"; return r end
    if type(data) ~= "table" then r.kind = "type:" .. type(data); return r end
    local lines = data.lines
    if secret(lines) then r.kind = "lines:secret"; return r end
    if type(lines) ~= "table" then r.kind = "nolines:" .. type(lines); return r end
    r.nlines = #lines
    if r.nlines == 0 then r.kind = "emptylines"; return r end
    for _, ln in ipairs(lines) do
        local t = type(ln) == "table" and ln.leftText or nil
        if secret(t) then
            r.nOther = r.nOther + 1
        elseif type(t) ~= "string" then
            r.nOther = r.nOther + 1
            r.nonText = (r.nonText or 0) + 1
        else
            local rows = 0
            for row in Probe.Plain(t):gmatch("[^\n]+") do
                rows = rows + 1
                if kindOf(row) then
                    r.nNode = r.nNode + 1
                    r.nodes[#r.nodes + 1] = row
                elseif isPlayer(row) then
                    r.nPlayer = r.nPlayer + 1
                else
                    r.nOther = r.nOther + 1
                end
            end
            if rows == 0 then r.blank = (r.blank or 0) + 1 end
        end
    end
    r.kind = r.nNode > 0 and "nodes" or "othersonly"
    return r
end

local function shapeText(sh)
    if not sh then return "?" end
    local s = ("%s n=%d nodes=%d players=%d other=%d"):format(tostring(sh.kind), sh.nlines or 0, sh.nNode or 0, sh.nPlayer or 0, sh.nOther or 0)
    if sh.blank then s = s .. " blank=" .. sh.blank end
    if sh.nonText then s = s .. " nontext=" .. sh.nonText end
    if sh.nNode and sh.nNode > 0 then s = s .. " [" .. table.concat(sh.nodes, " | ") .. "]" end
    return s
end

-- The plan's read validity: Minimap the top focus, the placement within a unit, settled,
-- UpdateBlips without error, the data readable. An invalid read is never evidence of nothing.
local function verdict(v)
    if not v.focus then return false, "top focus is " .. tostring(v.top) end
    if v.perr == nil then return false, "placement unreadable" end
    if v.perr > PLACE_TOL then return false, ("placement error %.1f"):format(v.perr) end
    if not v.settled then return false, "unsettled" end
    if v.ubErr then return false, "UpdateBlips failed" end
    if not v.readable then return false, "data unreadable" end
    return true
end

-- The 1 px sweep across a node: samples are { off = n, hit = true | false | nil (unread) },
-- ascending. The longest run of hits is the hit square's extent; an unread breaks a run.
-- truncLo / truncHi: an unread sample sits next to the run, so the width is a lower bound.
local function findEdges(samples)
    local best, cur
    local r = { unread = 0, hits = 0 }
    for _, s in ipairs(samples) do
        if s.hit == nil then
            r.unread = r.unread + 1
            cur = nil
        elseif s.hit then
            r.hits = r.hits + 1
            if cur then cur.hi = s.off; cur.n = cur.n + 1 else cur = { lo = s.off, hi = s.off, n = 1 } end
            if not best or cur.n > best.n then best = cur end
        else
            cur = nil
        end
    end
    if not best then return r end
    r.lo, r.hi, r.run = best.lo, best.hi, best.n
    r.width = best.hi - best.lo + 1
    r.centre = (best.lo + best.hi) / 2
    r.holes = r.hits - best.n
    for _, s in ipairs(samples) do
        if s.off < best.lo then
            if s.hit == false then r.missLo = s.off end
            if s.hit == nil then r.unreadLo = s.off end
        elseif s.off > best.hi then
            if s.hit == false and not r.missHi then r.missHi = s.off end
            if s.hit == nil and not r.unreadHi then r.unreadHi = s.off end
        end
    end
    r.truncLo = r.unreadLo ~= nil and (r.missLo == nil or r.unreadLo > r.missLo)
    r.truncHi = r.unreadHi ~= nil and (r.missHi == nil or r.unreadHi < r.missHi)
    return r
end

local function edgesText(e)
    if not e or not e.lo then return "no hit" end
    return ("%d px wide (%+d..%+d, centre %+.1f; missed at %s and %s%s%s)"):format(e.width, e.lo, e.hi, e.centre,
        e.missLo and ("%+d"):format(e.missLo) or "none", e.missHi and ("%+d"):format(e.missHi) or "none",
        (e.truncLo or e.truncHi) and "; TRUNCATED by the map's edge, a lower bound" or "",
        e.holes > 0 and ("; %d hits outside the run"):format(e.holes) or "")
end

-- Screen px a yard takes on a borrowed map of `units` frame units at effective scale `es`,
-- the map covering 2R yards across.
local function pxPerYard(units, es, R) return units * es / (2 * R) end
-- The map size (frame units) whose read covers a window of `wy` yards with a hit square of H px.
local function unitsFor(wy, R, H, es) return 2 * R * H / (wy * es) end
-- A node's world spot from the map offset (dx east, dy north, in map units of a B-unit map
-- that spans R yards to its edge) where the player stood at (pn, pw) (UnitPosition: north, west).
local function worldTarget(pn, pw, dx, dy, B, R)
    local k = R / (B / 2)
    return pn + dy * k, pw - dx * k
end
-- The map offset (units of a `units` map) that puts the world spot (tn, tw) under the cursor
-- for a player at (pn, pw).
local function placeFor(tn, tw, pn, pw, units, R)
    local u = (units / 2) / R
    return (pw - tw) * u, (tn - pn) * u
end
-- Where the node lies from the cursor at the read (screen px), for a map placed with the
-- player at (pn1, pw1) and an extra offset (ex, ey), the player now at (pn2, pw2): the map's
-- content moves with the player while its frame stays where it was placed.
local function nodeOffsetPx(ex, ey, pn1, pw1, pn2, pw2, ppy)
    return ex + (pw2 - pw1) * ppy, ey + (pn1 - pn2) * ppy
end
local function expectHit(ox, oy, H) return math.abs(ox) <= H / 2 and math.abs(oy) <= H / 2 end

-- A CVar put to 20 and back, across a reload: the value is saved BEFORE the change and
-- kept until the readback matches.
-- maxFPS applies only while useMaxFPS is 1 (measured: 127 fps with maxFPS 20 alone), so both
-- are taken and both put back.
local FPS_NAME, FPS_CAP = "maxFPS", "20"
local FPS_USE = "useMaxFPS"
local function sameValue(a, b) return a == b or (tonumber(a) ~= nil and tonumber(a) == tonumber(b)) end
local function fpsTake(api, d)
    if d.fpsPending == nil then
        local cur = api.get(FPS_NAME)
        if cur == nil then return false, "no maxFPS CVar" end
        d.fpsPending = { value = cur, use = api.get(FPS_USE) }
    end
    if d.fpsPending.use ~= nil then api.set(FPS_USE, "1") end
    api.set(FPS_NAME, FPS_CAP)
    return true
end
local function fpsGive(api, d)
    local p = d.fpsPending
    if not p then return true end
    api.set(FPS_NAME, p.value)
    if p.use ~= nil then api.set(FPS_USE, p.use) end
    local okV = sameValue(api.get(FPS_NAME), p.value)
    local okU = p.use == nil or sameValue(api.get(FPS_USE), p.use)
    if okV and okU then d.fpsPending = nil; return true end
    return false, ("still %s=%s %s=%s"):format(FPS_NAME, tostring(api.get(FPS_NAME)), FPS_USE, tostring(api.get(FPS_USE)))
end
local cvarApi = {
    get = function(n)
        local f = C_CVar and C_CVar.GetCVar
        if f then local ok, v = pcall(f, n); if ok then return v end end
    end,
    set = function(n, v)
        local f = C_CVar and C_CVar.SetCVar
        if f then pcall(f, n, v) end
    end,
}
local function fpsRestore()
    local d = db()
    if not d or not d.fpsPending then return end
    local ok, why = fpsGive(cvarApi, d)
    slog("fps", ok and "maxFPS put back" or ("maxFPS NOT put back: " .. tostring(why)), true)
end

-- The fake skin (probe-side, flagged): after any SetPoint on Minimap it pulls the frame
-- back to its home anchors, and in "anchor+alpha" mode makes it opaque too.
local function skinAction(mode, inSkin)
    if not mode or inSkin then return nil end
    return mode == "anchor+alpha" and "pull+opaque" or "pull"
end

local function statsOf(list)
    local n = #list
    if n == 0 then return { n = 0 } end
    local a = {}
    local sum = 0
    for i, v in ipairs(list) do a[i] = v; sum = sum + v end
    table.sort(a)
    return { n = n, min = a[1], max = a[n], avg = sum / n, p95 = a[math.max(1, math.ceil(n * 0.95))] }
end
local function statsText(s)
    if s.n == 0 then return "none" end
    return ("n=%d min %.0f avg %.0f p95 %.0f max %.0f"):format(s.n, s.min, s.avg, s.p95, s.max)
end

--------------------------------------------------------------------------------
-- Small readers
--------------------------------------------------------------------------------

local function pos()
    local up = rawget(_G, "UnitPosition")
    if type(up) ~= "function" then return nil end
    local ok, n, w = pcall(up, "player")
    if ok and num(n) and num(w) then return { n, w } end
end

local function viewRadius()
    local ok, r = pcall(function() return C_Minimap.GetViewRadius() end)
    return ok and num(r) or nil
end

local function minimapEs() return num(M.call(Minimap, "GetEffectiveScale")) or 1 end

local function speed()
    local f = rawget(_G, "GetUnitSpeed")
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, "player")
    return ok and num(v) or nil
end

local function topFocus()
    local gf = M.gfn("GetMouseFoci")
    if not gf then return nil, "n/a" end
    local ok, list = pcall(gf)
    if not ok or type(list) ~= "table" then return nil, "error" end
    local f = list[1]
    if f == nil then return nil, "none" end
    if f == Minimap then return f, "Minimap" end
    if f == rawget(_G, "WorldFrame") then return f, "WorldFrame" end
    return f, M.relName(f)
end

local function editModeActive()
    local em = rawget(_G, "EditModeManagerFrame")
    if type(em) ~= "table" then return false end
    local a = M.call(em, "IsEditModeActive")
    return a == true or (a == nil and M.call(em, "IsShown") == true)
end

local function kindOf(name) return M.libraryKind(name) end
local function classifyNow(data) return classify(data, kindOf, M.isPlayerName) end

local function countsOf(sh)
    local c = {}
    for _, nm in ipairs(sh.nodes or {}) do c[nm] = (c[nm] or 0) + 1 end
    return c
end
local function countsText(c)
    local out = {}
    for nm, n in pairs(c) do out[#out + 1] = ("%s x%d"):format(nm, n) end
    table.sort(out)
    return #out > 0 and table.concat(out, ", ") or "no node"
end
-- true | false | nil (unread) for a node name in a read.
local function hitOf(rd, name)
    if not rd or not rd.valid then return nil end
    return (rd.counts[name] or 0) > 0
end
local function hs(h) if h == nil then return "x" end return h and "1" or "0" end

--------------------------------------------------------------------------------
-- The tooltip hook: Blizzard's own minimap tooltip, hidden after its producer
-- (GameTooltip:SetMinimapMouseover, set by TooltipDataHandler: not a widget method of
-- the dump) showed it, only while the scan's flag is on.
--------------------------------------------------------------------------------

local tipHooked
local function ensureTipHook()
    if tipHooked then return true end
    local gt = rawget(_G, "GameTooltip")
    if type(gt) ~= "table" or type(gt.SetMinimapMouseover) ~= "function" then return false end
    local ok = pcall(hooksecurefunc, gt, "SetMinimapMouseover", function(self)
        if W.suppress then
            W.supCount = W.supCount + 1
            pcall(self.Hide, self)
        end
    end)
    tipHooked = ok
    return ok
end

--------------------------------------------------------------------------------
-- The fake skin
--------------------------------------------------------------------------------

local skinHooked
local function ensureSkinHook()
    if skinHooked then return true end
    local ok = pcall(hooksecurefunc, Minimap, "SetPoint", function()
        local act = skinAction(W.skin, W.inSkin)
        if not act then return end
        W.inSkin = true
        W.skinPulls = (W.skinPulls or 0) + 1
        pcall(function()
            Minimap:ClearAllPoints()
            for _, p in ipairs(W.skinHome or {}) do Minimap:SetPoint(p[1], p[2] or UIParent, p[3], p[4], p[5]) end
            if act == "pull+opaque" then Minimap:SetAlpha(1) end
        end)
        W.inSkin = false
    end)
    skinHooked = ok
    return ok
end

--------------------------------------------------------------------------------
-- Tracking: the cursor, mouselook
--------------------------------------------------------------------------------

local function track()
    local x, y = M.cursor2()
    local now = GetTime()
    if x and y then
        if not W.cx or math.sqrt((x - W.cx) ^ 2 + (y - W.cy) ^ 2) > M.THRESH then W.cx, W.cy, W.lastMove = x, y, now end
    end
    local ml = M.gfn("IsMouselooking")
    if ml then
        local ok, v = pcall(ml)
        v = ok and v == true
        if v ~= W.ml then
            W.ml = v
            if W.watch then
                slog("input", ("mouselook %s after burst frame %d (phase %s, borrowed %s)"):format(v and "STARTED" or "ended", W.bf, W.phase,
                    tostring(M.state() ~= nil)), true)
                if v and W.input then W.input.mlStarts = (W.input.mlStarts or 0) + 1; W.input.mlPhase = W.input.mlPhase or {}; tallyInto(W.input.mlPhase, W.phase) end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- The burst: one session of the plan's frame schedule
--------------------------------------------------------------------------------

-- Per frame of a burst: whether GameTooltip is shown and its owner (with o.tipLog, a line each).
local function frameWork(S)
    S.frames = (S.frames or 0) + 1
    local gt = rawget(_G, "GameTooltip")
    local shown = gt ~= nil and M.call(gt, "IsShown") == true
    if shown then S.tipShown = (S.tipShown or 0) + 1 end
    if W.skin and not S.restored then
        local a = num(M.call(Minimap, "GetAlpha"))
        if a and a > 0.01 then S.opaque = (S.opaque or 0) + 1 end
    end
    if S.o.tipLog then
        local owner = gt and M.call(gt, "GetOwner")
        local zi = Minimap.ZoomIn
        local _, tn = topFocus()
        slog("tip", ("f%d (%s): GameTooltip shown %s, owner %s; zoom button shown %s; top focus %s; suppress %s"):format(W.bf, W.phase,
            tostring(shown), owner and M.relName(owner) or "none", type(zi) == "table" and tostring(M.call(zi, "IsShown")) or "n/a", tn, tostring(W.suppress)))
    end
end

-- Why the burst must end now, or nil (the plan's continuation checks). Cleanup never depends on it.
local function contWhy(S)
    local o = S.o
    if W.interrupt then return W.interrupt end
    if InCombatLockdown() and not o.forceCombat then return "combat" end
    if editModeActive() then return "Edit Mode" end
    local n = M.nr()
    if n and n.API and n.API.Gamepad and n.API.Gamepad() then return "gamepad UI" end
    if o.ignoreGate then return nil end
    if W.ml then return "mouselook" end
    local x, y = M.cursor2()
    if x and S.cx0 and math.sqrt((x - S.cx0) ^ 2 + (y - S.cy0) ^ 2) > M.THRESH then return "cursor moved" end
    local f, name = topFocus()
    if name ~= "n/a" and name ~= "error" and not o.tolerateFocus then
        local want = S.isPlaced and Minimap or rawget(_G, "WorldFrame")
        if want and f ~= want and not (S.isPlaced == false and f == nil) then return "top focus " .. name end
    end
    return nil
end

local function readNow(S, label)
    local o = S.o
    local rd = { label = label, bf = W.bf, r = W.bf - (S.placeBf or W.bf), pos1 = S.p1, pos2 = pos() }
    local f, topName = topFocus()
    rd.top = topName
    local focusOK = (f == Minimap) or topName == "n/a"
    local _, perr = M.placementCheck()
    rd.perr = perr
    local fn = C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover
    local okc, data = false, nil
    if type(fn) == "function" then okc, data = pcall(fn) end
    local shape
    if not okc then shape = { kind = "error", nodes = {}, nNode = 0, nPlayer = 0, nOther = 0, nlines = 0 } else shape = classifyNow(data) end
    rd.shape, rd.counts = shape, countsOf(shape)
    rd.settled = (S.nPlaced > 1 and rd.r >= 1) or rd.r >= 2
    local readable = not (shape.kind == "secret" or shape.kind == "lines:secret" or shape.kind == "error")
    rd.valid, rd.why = verdict({ focus = focusOK, top = topName, perr = perr, settled = rd.settled, ubErr = S.ubErr, readable = readable })
    if o.name then rd.count = rd.counts[o.name] or 0 end
    if o.logReads ~= false then
        slog(o.step, ("%s: %s r+%d %s; %s; perr %s; %.0f ms into the burst"):format(label, rd.valid and "VALID" or ("UNREAD(" .. tostring(rd.why) .. ")"), rd.r,
            rd.settled and "settled" or "UNSETTLED", shapeText(shape), perr and ("%.2f"):format(perr) or "nil", debugprofilestop() - S.rec.t0))
    end
    return rd
end

-- One burst. body(S) starts at frame 2 and ends where the read is (the restore is that frame).
-- o: step, label, units | px, name, ignoreGate, abortOnDown, flavor, suppress, clicksOn,
-- forceCombat, tipLog, logReads, holdPrepared (seconds), shot (a screenshot label for a hold),
-- tolerateFocus (a sweep whose cursor may leave the map: those samples are unread, the burst goes on).
local function session(o, body)
    local rec = { step = o.step, label = o.label, reads = {} }
    W.burstN = W.burstN + 1
    rec.n = W.burstN
    rec.t0 = debugprofilestop()
    W.interrupt = nil
    M.setQuiet(true)                                    -- before the borrow's own lines
    local ok, why = M.begin(o.step)
    if not ok then rec.refused = why; M.setQuiet(false); return rec end
    local home = M.state()
    W.inBurst, W.bf, W.phase, W.flavor = true, 1, "prepared", o.flavor
    W.abortOnDown = o.abortOnDown
    if o.suppress ~= false then W.suppress = true end
    local es = minimapEs()
    local units = o.units or (o.px and o.px / es) or 24
    rec.es, rec.units, rec.px = es, units, units * es
    local S = { rec = rec, o = o, dead = false, nPlaced = 0, units = units, es = es, isPlaced = false }
    S.cx0, S.cy0 = M.cursor2()
    local function die(why2) if not S.dead then S.dead = true; rec.interrupted = why2 end end

    function S.frame()
        if S.dead then return false end
        frameWork(S)
        track()
        M.frames(1)
        W.bf = W.bf + 1
        local w = contWhy(S)
        if w then die(w) end
        return not S.dead
    end
    function S.place(dx, dy, ex, ey)
        if S.dead then return false end
        local okp, err = pcall(M.place, dx or 0, dy or 0, ex, ey)
        if not okp then rec.opErr = tostring(err); die("place: " .. tostring(err)); return false end
        local okb, errb = pcall(Minimap.UpdateBlips, Minimap)
        S.ubErr = (not okb) and tostring(errb) or nil
        S.nPlaced, S.isPlaced, S.placeBf, S.p1 = S.nPlaced + 1, true, W.bf, pos()
        W.phase = "placed"
        return true
    end
    function S.read(label)
        if S.dead then return nil end
        local rd = readNow(S, label or o.label or "read")
        rec.reads[#rec.reads + 1] = rd
        return rd
    end
    -- place, then read at r+1 and r+2 (the first of a session: r+1 is expected unsettled)
    function S.sample(label, dx, dy, ex, ey)
        if not S.place(dx, dy, ex, ey) then return nil end
        if not S.frame() then return nil end
        local r1 = S.read(label .. " r+1")
        if not S.frame() then return nil, r1 end
        local r2 = S.read(label .. " r+2")
        return r2, r1
    end
    -- Hold the current state for `sec` seconds; with a screenshot label, until the shot is taken.
    function S.hold(sec, tag, shotLabel)
        W.phase = "hold-" .. tag
        local t, shot, shotAt = GetTime(), nil, nil
        if shotLabel then
            local oks, errs = pcall(Probe.Screenshot, Probe, shotLabel, function(file, w2) shot = file or ("failed: " .. tostring(w2)); shotAt = GetTime() - t end)
            if not oks then shot = "failed: " .. tostring(errs) end
        end
        while (GetTime() - t < sec) or (shotLabel and shot == nil and GetTime() - t < 5) do
            if not S.frame() then break end
        end
        if shot and not S.dead then
            local t2 = GetTime()
            while GetTime() - t2 < 0.3 do if not S.frame() then break end end
        end
        W.phase = tag == "prepared" and "prepared" or "placed"
        return shot, shotAt
    end

    -- frame 1: borrow + prepare
    rec.alpha0 = pcall(Minimap.SetAlpha, Minimap, 0)
    pcall(Minimap.SetMouseClickEnabled, Minimap, o.clicksOn == true)
    pcall(Minimap.EnableMouseWheel, Minimap, false)
    M.setIconScale(o.step, 0.01)
    pcall(M.offscreen)
    pcall(Minimap.SetSize, Minimap, units, units)
    if o.holdPrepared then rec.shot = S.hold(o.holdPrepared, "prepared", o.shot) end
    S.frame()                                            -- end of frame 1
    if not S.dead then body(S) end
    -- the read frame: restore at once, whatever happened
    rec.bodyFrames = W.bf
    local rok = M.restore(o.step .. " burst")
    for i = 1, 3 do
        if rok or not M.state() then break end
        M.frames(1)
        rok = M.restore(o.step .. " burst retry " .. i)
    end
    rec.restoreOK = rok == true
    pcall(Minimap.UpdateBlips, Minimap)
    S.isPlaced, S.restored = false, true
    W.phase = "restored"
    -- the settle frame: the suppression stays through it
    frameWork(S)
    track()
    M.frames(1)
    W.bf = W.bf + 1
    W.phase = "readback"
    rec.readbackOK = M.compare(home, M.snapshot()).all == true
    frameWork(S)                                         -- the settle frame itself, the suppression still on
    W.suppress, W.inBurst, W.abortOnDown, W.phase = false, false, nil, "idle"
    rec.ms, rec.frames, rec.tipShown, rec.tipFrames, rec.opaque = debugprofilestop() - rec.t0, W.bf, S.tipShown or 0, S.frames or 0, S.opaque or 0
    W.bf = 0
    M.setQuiet(false)
    return rec
end

-- One plain burst: place, settle, read (and a hold with a screenshot if asked).
local function burst(o)
    return session(o, function(S)
        local dx, dy, ex, ey = o.dx, o.dy, o.ex, o.ey
        if o.placeFn then dx, dy, ex, ey = o.placeFn() end
        if not S.place(dx, dy, ex, ey) then return end
        if o.holdPlaced then S.rec.shot = S.hold(o.holdPlaced, "placed", o.shot) end
        if not S.frame() then return end                 -- end of frame 2
        if o.unsettled then S.read(o.label); return end  -- read at r+1: before the settle frame
        if not S.frame() then return end                 -- end of frame 3 (settle)
        S.read(o.label)
    end)
end

local function burstLine(rec)
    if rec.refused then return "refused: " .. tostring(rec.refused) end
    local rd = rec.reads[1]
    return ("burst %d: %s; %.0f ms, %d frames; restore %s, readback %s; tooltip shown in %d of %d frames%s"):format(rec.n,
        rd and (rd.valid and "valid" or ("unread (" .. tostring(rd.why) .. ")")) or (rec.interrupted and ("interrupted (" .. tostring(rec.interrupted) .. ")") or "no read"),
        rec.ms or 0, rec.frames or 0, rec.restoreOK and "OK" or "NOT CLEAN", rec.readbackOK and "OK" or "DIFFERS", rec.tipShown or 0, rec.tipFrames or 0,
        rec.interrupted and rd and (" (interrupted: " .. tostring(rec.interrupted) .. ")") or "")
end

--------------------------------------------------------------------------------
-- Admission and the loop of bursts
--------------------------------------------------------------------------------

-- The plan's admission (the checks that can be made here), or false and why.
local function admit(cfg)
    local why = M.refusal()
    if why then return false, why end
    if cfg and cfg.ignoreGate then return true end
    if W.ml then return false, "mouselooking" end
    local md = M.gfn("IsMouseButtonDown")
    if md then
        for _, b in ipairs({ "LeftButton", "RightButton", "MiddleButton" }) do
            local okd, v = pcall(md, b)
            if okd and v == true then return false, "a mouse button is down" end
        end
    end
    if not M.overWorld() then return false, "the cursor is not over the world" end
    local now = GetTime()
    if now - W.lastMove < 0.2 then return false, "the cursor is moving" end
    if now - W.lastUp < 0.3 then return false, "a button was just released" end
    local gt = rawget(_G, "GameTooltip")
    if gt and M.call(gt, "IsShown") == true then return false, "a tooltip is shown" end
    return true
end

-- A job body that runs bursts for cfg.seconds (or until st.stop / cfg.stop), one every cfg.every
-- seconds when admitted. cfg.burst(st) -> the burst's options, cfg.onBurst(st, rec).
local function loopBody(cfg, st)
    return function()
        local S0 = M.state()
        W.home = S0 or M.snapshot()
        if S0 then M.restore("loop start") end
        local t0 = GetTime()
        local nextAt = t0
        st.refused = st.refused or {}
        st.t0 = st.t0 or t0
        while true do
            if st.stop or (cfg.stop and cfg.stop(st)) then break end
            if GetTime() - t0 >= (cfg.seconds or 60) then break end
            track()
            if GetTime() >= nextAt then
                local ok, why = admit(cfg)
                if ok then
                    nextAt = GetTime() + (cfg.every or 1)
                    st.n = (st.n or 0) + 1
                    local rec = burst(cfg.burst(st))
                    if cfg.onBurst then cfg.onBurst(st, rec) end
                else
                    tallyInto(st.refused, why)
                end
            end
            M.frames(1)
        end
        return cfg.summary and cfg.summary(st) or "done"
    end
end

local function startLoop(st, cfg)
    if st.finished then return end
    local S0, job = M.state()
    if job or S0 then return end
    if st.retryAt and GetTime() < st.retryAt then return end
    W.active = true
    M.start(cfg.step, loopBody(cfg, st), function(summary)
        if tostring(summary):find("^refused") then st.retryAt = GetTime() + 1; return end
        st.finished, st.result = true, summary
    end)
end

local function stopLoop(st)
    st.stop = true
end

--------------------------------------------------------------------------------
-- Events: clicks, pings, combat, Edit Mode
--------------------------------------------------------------------------------

local function eventRecord(kind, extra)
    local d = db()
    local borrowed = M.state() ~= nil
    local line = ("%s: burst %d frame %d, phase %s, flavor %s, borrowed %s%s"):format(kind, W.burstN, W.bf, W.phase, tostring(W.flavor), tostring(borrowed),
        extra and (", " .. extra) or "")
    slog("event", line)
    if d then
        d.events = d.events or {}
        d.events[#d.events + 1] = line
        while #d.events > 400 do table.remove(d.events, 1) end
        d.input = d.input or {}
        tallyInto(d.input, kind .. " | " .. W.phase)
    end
    return borrowed
end

local function onEvent(_, event, a1)
    if event == "GLOBAL_MOUSE_DOWN" or event == "GLOBAL_MOUSE_UP" or event == "MINIMAP_PING" then
        if event == "GLOBAL_MOUSE_UP" then W.lastUp = GetTime() end
        if not W.watch then return end
        local kind = event == "MINIMAP_PING" and "MINIMAP_PING" or (event:gsub("GLOBAL_MOUSE_", "") .. " " .. tostring(a1))
        local extra
        if event == "GLOBAL_MOUSE_DOWN" and W.inBurst and W.abortOnDown then
            -- the plan: a mouse button down ends the burst at once, the restore running right here
            local okr = M.restore("GLOBAL_MOUSE_DOWN")
            W.interrupt = "GLOBAL_MOUSE_DOWN"
            extra = "ended the burst; restore " .. (okr and "OK" or "NOT CLEAN")
            if W.input then W.input.endedByDown = (W.input.endedByDown or 0) + 1; if not okr then W.input.restoreBad = (W.input.restoreBad or 0) + 1 end end
        end
        eventRecord(kind, extra)
        local inp = W.input
        if inp then
            inp.counts = inp.counts or {}
            tallyInto(inp.counts, kind)
        end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if W.watch then eventRecord("PLAYER_REGEN_ENABLED") end
        if W.fight then W.fight.inCombat = false end
        return
    end
    if event == "PLAYER_LOGIN" then
        fpsRestore()
        return
    end
end

local listener = CreateFrame("Frame")
Probe:RegisterEvents(listener, { "GLOBAL_MOUSE_DOWN", "GLOBAL_MOUSE_UP", "MINIMAP_PING", "PLAYER_REGEN_ENABLED", "PLAYER_LOGIN" })
listener:SetScript("OnEvent", onEvent)

-- The main file's abort handler tells us first: combat starting, Edit Mode entering, a loading
-- screen, the round stopping. What state the burst was in is the measurement.
local function onAbort(reason, borrowed, hadJob)
    if reason:find("^job end") then              -- a step's job ended (or failed): nothing of ours may outlast it
        W.suppress, W.inBurst, W.abortOnDown, W.skin, W.hold = false, false, nil, nil, nil
        M.setQuiet(false)
        M.setForceCombat(false)
        fpsRestore()
        return
    end
    local line = ("%s: burst %d frame %d, phase %s, flavor %s, map borrowed %s, job %s"):format(reason, W.burstN, W.bf, W.phase, tostring(W.flavor),
        tostring(borrowed), tostring(hadJob))
    slog("abort", line, W.watch)
    local d = db()
    if d then d.aborts = d.aborts or {}; d.aborts[#d.aborts + 1] = line; while #d.aborts > 100 do table.remove(d.aborts, 1) end end
    if reason == "PLAYER_REGEN_DISABLED" and W.fight then
        W.fight.n = (W.fight.n or 0) + 1
        W.fight.inCombat = true
        W.fight.events = W.fight.events or {}
        W.fight.events[#W.fight.events + 1] = { borrowed = borrowed, phase = W.phase, bf = W.bf, hadJob = hadJob }
        if borrowed then W.fight.inBurst = (W.fight.inBurst or 0) + 1 end
    end
    if reason == "EditMode.Enter" and W.edit then
        W.edit.enters = (W.edit.enters or 0) + 1
        W.edit.events = W.edit.events or {}
        W.edit.events[#W.edit.events + 1] = { borrowed = borrowed, phase = W.phase, bf = W.bf }
        if borrowed then W.edit.inBurst = (W.edit.inBurst or 0) + 1 end
    end
    -- whatever the burst had on goes off: the map is restored by the caller right after us
    W.suppress, W.inBurst, W.abortOnDown, W.skin, W.hold = false, false, nil, nil, nil
    M.setQuiet(false)
    M.setForceCombat(false)
    fpsRestore()
    local after = W.burstN
    C_Timer.After(0.3, function()
        local S0 = M.state()
        local same = W.home and M.compare(W.home, M.snapshot()).all
        slog("abort", ("0.3 s after %s: borrow %s, the minimap %s the state before the round"):format(reason, S0 and "STILL OPEN" or "closed",
            W.home and (same and "is back to" or "DIFFERS from") or "was not compared with"), W.watch)
        if W.fight and reason == "PLAYER_REGEN_DISABLED" then W.fight.afterOK = (W.fight.afterOK or 0) + ((not S0 and same) and 1 or 0); W.fight.afterN = (W.fight.afterN or 0) + 1 end
        if W.edit and reason == "EditMode.Enter" then W.edit.afterOK = (W.edit.afterOK or 0) + ((not S0 and same) and 1 or 0); W.edit.afterN = (W.edit.afterN or 0) + 1 end
    end)
    return after
end
M.setAbortHook(onAbort)

do
    local er = rawget(_G, "EventRegistry")
    if type(er) == "table" and type(er.RegisterCallback) == "function" then
        local owner = {}
        pcall(er.RegisterCallback, er, "EditMode.Exit", function()
            if W.edit then W.edit.exits = (W.edit.exits or 0) + 1 end
            if W.watch then slog("event", "EditMode.Exit", true) end
        end, owner)
    end
end

-- The maxFPS cap and the fake skin must never outlast a round.
M.guardRound({ KEY2, KEY3 }, function()
    local d = db()
    return (d and d.fpsPending ~= nil) or W.skin ~= nil or W.suppress
end, function()
    fpsRestore()
    W.skin, W.suppress = nil, false
end)

--------------------------------------------------------------------------------
-- movescan2: the steps
--------------------------------------------------------------------------------

local function homeNow()
    local S0 = M.state()
    W.home = S0 or M.snapshot()
    if S0 then M.restore("round step start") end
end

-- A hover seed with the player's state at that moment (a seed is only good while the player stands).
local function annotate(slot)
    local sd = M.seeds[slot]
    if not sd then return end
    sd.pos, sd.R, sd.es = pos(), viewRadius(), minimapEs()
    sd.zoom = num(M.call(Minimap, "GetZoom"))
    sd.ratio = math.sqrt(sd.dx ^ 2 + sd.dy ^ 2) / (sd.B / 2)
    sd.rotate = (C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("rotateMinimap")) == "1"
    if slot == "s1" then W.zoom0, W.es0 = sd.zoom, sd.es end
    slog("seed", ("%s seeded: %s at (%.1f,%.1f) of a %s px map, %.0f%% of the way to the rim; zoom %s, view radius %s yd, effective scale %.3f, rotating %s"):format(
        slot, sd.name, sd.dx, sd.dy, str(sd.B), sd.ratio * 100, str(sd.zoom), str(sd.R), sd.es or 0, tostring(sd.rotate)), true)
end

local function seed(slot, what)
    local fn = M.seedWait(slot, what)
    return function()
        local v = speed()
        if v and v > 0 then return false, "stand still while seeding (you are moving)" end
        local okk, msg = fn()
        if okk == true then annotate(slot) end
        return okk, msg
    end
end
local function seedCheck(slot) return function() return M.seeds[slot] ~= nil, "the " .. slot .. " seed" end end
local function needSeed(slot)
    return function()
        if not M.seeds[slot] then return "skip", "skipped: no " .. slot .. " seed (its step failed or was skipped)" end
        return true
    end
end

-- A seed is only good while its node is there and the player stands. Before any measurement that
-- uses one: a read at the seed's place on a comfortable 96 unit map. Not listed: no measurement,
-- the seed is dropped and the step asks for a new one (SEED_MSG, see `retrying`).
local SEED_MSG = "SEED NOT LISTED: hover a dot again"
local VERIFY_UNITS = 96
local function verifySeed(slot)
    local sd = M.seeds[slot]
    if not sd then return nil end
    local k = VERIFY_UNITS / sd.B
    local rec = session({ step = "verify", label = slot .. " verification", units = VERIFY_UNITS, name = sd.name, logReads = false, tolerateFocus = true }, function(S)
        S.sample("verify", sd.dx * k, sd.dy * k, 0, 0)
    end)
    local rd = rec.reads[#rec.reads]
    local count = rd and rd.valid and (rd.counts[sd.name] or 0) or nil
    if not count or count < 1 then
        M.seeds[slot] = nil
        slog("verify", ("%s: SEED NOT LISTED: %s at its place on a %d unit map reads %s (%s); no measurement is made, the seed is dropped"):format(slot, sd.name, VERIFY_UNITS,
            count == nil and "UNREAD" or "x0", tostring(rec.refused or (rd and rd.why) or rec.interrupted or "no read")), true)
        return nil
    end
    sd.verify, sd.verifyAll = count, rd.counts
    slog("verify", ("%s: seed verified: %s x%d at its place on a %d unit map (the read lists: %s)"):format(slot, sd.name, count, VERIFY_UNITS, countsText(rd.counts)), true)
    return count
end

-- Before the countdown: a missing seed (dropped by a failed verification) is asked for again.
local function seedReady(slot, what)
    local fn = seed(slot, what)
    return function()
        if M.seeds[slot] then return true end
        local okk, msg = fn()
        if okk == true then return false, "seeded again: now move the mouse onto the world" end
        return false, SEED_MSG .. " (" .. tostring(msg) .. ")"
    end
end
-- A step whose body found its seed gone goes back to waiting (its ready function asks again).
local function retrying(fn)
    return function()
        local done, r = fn()
        if done == true and type(r) == "string" and r:find("^SEED NOT LISTED") then return false, r end
        return done, r
    end
end
local MOUSE_NOTE = " Close or move the /fp console and this window away from the middle of the screen, and rest the mouse on open world."
local function measureSeeded(def, readyText, waitText, step, keep, body, timeout, slot, what)
    def[#def + 1] = M.readyStep(readyText .. MOUSE_NOTE)
    def[#def + 1] = { text = waitText, wait = retrying(M.waitStep(step, 3, keep, body, seedReady(slot, what), true)), timeout = timeout }
end

local function infoRun()
    for _, k in ipairs({ "s1", "pairA", "pairB", "rim", "z2", "sc2", "walk" }) do M.seeds[k] = nil end
    W.zoom0, W.es0, W.H, W.Hsum, W.Hn = nil, nil, nil, nil, nil
    local d = db()
    if d then d.results, d.lines, d.events, d.input, d.aborts = {}, {}, {}, {}, {} end
    local v, b, dt, toc = GetBuildInfo()
    slog("info", ("build %s (%s) %s, interface %s"):format(str(v), str(b), str(dt), str(toc)), true)
    slog("info", ("Minimap: effective scale %.3f, size %sx%s, zoom %s of %s levels, view radius %s yd, rotateMinimap %s"):format(minimapEs(), str(M.call(Minimap, "GetWidth")),
        str(M.call(Minimap, "GetHeight")), str(M.call(Minimap, "GetZoom")), str(M.call(Minimap, "GetZoomLevels")), str(viewRadius()),
        str(C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("rotateMinimap"))), true)
    local api = {}
    for _, name in ipairs({ "SetIconScale", "EnableMouseWheel", "SetMouseClickEnabled", "IsMouseWheelEnabled", "UpdateBlips", "GetZoom" }) do
        api[#api + 1] = name .. "=" .. tostring(type(Minimap[name]) == "function")
    end
    api[#api + 1] = "EnableMouseClicks=" .. tostring(type(Minimap.EnableMouseClicks) == "function")
    for _, name in ipairs({ "IsMouselooking", "UnitPosition", "GetUnitSpeed", "IsMounted", "GetFramerate" }) do
        api[#api + 1] = name .. "=" .. tostring(type(rawget(_G, name)) == "function")
    end
    local gt = rawget(_G, "GameTooltip")
    api[#api + 1] = "GameTooltip.SetMinimapMouseover=" .. tostring(type(gt) == "table" and type(gt.SetMinimapMouseover) == "function")
    api[#api + 1] = "tooltip hook installed=" .. tostring(ensureTipHook())
    api[#api + 1] = "maxFPS=" .. str(cvarApi.get(FPS_NAME))
    slog("info", "API: " .. table.concat(api, ", "), true)
    local d2 = db()
    if d2 and d2.fpsPending then slog("info", "a maxFPS value is still pending from before: put back now", true); fpsRestore() end
    return "info logged"
end

-- ---- item 1: the hit square H ------------------------------------------------

local HIT_SIZES = { 48, 64, 96, 198 }          -- frame units; the node must fit with the cursor around it
local SWEEP = 20                           -- screen px each side of the seed's place

local function hitBody(slot, key)
    return function()
        local sd = M.seeds[slot]
        if not sd then return SEED_MSG end
        homeNow()
        if not verifySeed(slot) then return SEED_MSG end
        local results = { slot = slot, node = sd.name, zoom = sd.zoom, es = sd.es, sizes = {} }
        local summary = {}
        for _, units in ipairs(HIT_SIZES) do
            local k = units / sd.B
            local ox, oy = sd.dx * k, sd.dy * k
            local res = { units = units }
            local rec = session({ step = "hit", label = ("%s %d units"):format(slot, units), units = units, name = sd.name, logReads = false, tolerateFocus = true }, function(S)
                local alive = S.sample("alive", ox, oy, 0, 0)
                res.alive = hitOf(alive, sd.name)
                -- where the node's projected place lies on this map: inside its rect, or clamped at the rim?
                local esn = S.es
                res.nx, res.ny, res.half = ox * esn, oy * esn, units * esn / 2
                res.sq = math.max(math.abs(res.nx), math.abs(res.ny)) / res.half
                res.circ = math.sqrt(res.nx ^ 2 + res.ny ^ 2) / res.half
                if res.alive ~= true then return end
                local agree, differ, unread = 0, 0, 0
                local function sweep(axis, fixed)
                    local samples = {}
                    for off = -SWEEP, SWEEP do
                        local ex, ey = fixed, 0
                        if axis == "y" then ex, ey = fixed, off else ex = off end
                        local r2, r1 = S.sample(axis .. off, ox, oy, ex, ey)
                        if S.dead then break end
                        local h2 = hitOf(r2, sd.name)
                        samples[#samples + 1] = { off = off, hit = h2 }
                        if #samples > 1 or axis == "y" then
                            local h1 = hitOf(r1, sd.name)
                            if h1 == nil then unread = unread + 1 elseif h1 == h2 then agree = agree + 1 else differ = differ + 1 end
                        end
                    end
                    return samples
                end
                local xs = sweep("x", 0)
                local ex = findEdges(xs)
                res.x = ex
                res.xsamples = ""
                for _, s in ipairs(xs) do res.xsamples = res.xsamples .. hs(s.hit) end
                local cx = ex.centre and math.floor(ex.centre + 0.5) or 0
                local ys = sweep("y", cx)
                local ey = findEdges(ys)
                res.y = ey
                res.ysamples = ""
                for _, s in ipairs(ys) do res.ysamples = res.ysamples .. hs(s.hit) end
                res.r1agree, res.r1differ, res.r1unread = agree, differ, unread
            end)
            res.restoreOK, res.readbackOK, res.interrupted, res.frames, res.ms = rec.restoreOK, rec.readbackOK, rec.interrupted, rec.frames, rec.ms
            results.sizes[#results.sizes + 1] = {
                units = units, alive = res.alive, xw = res.x and res.x.width, yw = res.y and res.y.width,
                nodeX = res.nx, nodeY = res.ny, half = res.half, squareRatio = res.sq, circleRatio = res.circ,
                xEdgeLo = res.x and res.x.lo and res.nx and (res.nx + res.x.lo), xEdgeHi = res.x and res.x.hi and res.nx and (res.nx + res.x.hi),
                yEdgeLo = res.y and res.y.lo and res.ny and (res.ny + res.y.lo), yEdgeHi = res.y and res.y.hi and res.ny and (res.ny + res.y.hi),
                x = edgesText(res.x), y = edgesText(res.y), xs = res.xsamples, ys = res.ysamples, r1agree = res.r1agree, r1differ = res.r1differ,
                r1unread = res.r1unread, restoreOK = res.restoreOK, interrupted = res.interrupted,
            }
            local line
            if rec.refused then line = "refused: " .. tostring(rec.refused)
            elseif res.alive ~= true then line = res.alive == nil and "the seed's place was UNREAD (the cursor left the map's rect)" or "the node is NOT LISTED at its seed place: the seed is stale (moved, or the zoom changed)"
            else
                line = ("x: %s; y: %s; r+1 agreed with r+2 in %s of %s placements (%s unread)"):format(edgesText(res.x), edgesText(res.y), str(res.r1agree), str((res.r1agree or 0) + (res.r1differ or 0)), str(res.r1unread))
                if res.x and res.x.width then W.Hsum = (W.Hsum or 0) + res.x.width; W.Hn = (W.Hn or 0) + 1 end
            end
            slog("hit", ("%s %d units (%.1f px): %s%s"):format(slot, units, units * (sd.es or minimapEs()), line, rec.interrupted and ("; INTERRUPTED: " .. tostring(rec.interrupted)) or ""), true)
            if res.nx then
                slog("hit", ("%s %d units: node projected at (%.1f,%.1f) px from the map centre = %.0f%% of the half width (square), %.0f%% of the radius (circle: %s); the map's half width is %.1f px; the cursor at the x edges was %s px from the centre, at the y edges %s"):format(
                    slot, units, res.nx, res.ny, res.sq * 100, res.circ * 100, res.circ > 1 and "OUTSIDE" or "inside", res.half,
                    res.x and res.x.lo and ("%.1f..%.1f"):format(res.nx + res.x.lo, res.nx + res.x.hi) or "n/a",
                    res.y and res.y.lo and ("%.1f..%.1f"):format(res.ny + res.y.lo, res.ny + res.y.hi) or "n/a"), true)
            end
            slog("hit", ("%s %d units samples x [%s] y [%s]"):format(slot, units, res.xsamples or "", res.ysamples or ""))
            summary[#summary + 1] = ("%d:%s/%s"):format(units, str(res.x and res.x.width), str(res.y and res.y.width))
            if rec.interrupted or rec.refused then break end
            M.pause(0.3)
        end
        if W.Hn and W.Hn > 0 then W.H = W.Hsum / W.Hn end
        store(key, results)
        return "H (x/y px) by size: " .. table.concat(summary, " ")
    end
end

-- ---- items 2 and 10: the presence size at the rim, and at a second effective scale -------------

local LADDER = { { u = 20 }, { u = 24 }, { px = 12.8 }, { px = 14 }, { px = PRESENCE_PX }, { px = 16.5 }, { px = 18 } }

local function ladderBody(slot, key)
    return function()
        local sd = M.seeds[slot]
        if not sd then return SEED_MSG end
        homeNow()
        local verified = verifySeed(slot)
        if not verified then return SEED_MSG end
        local es = minimapEs()
        local ctlOff = math.ceil(W.H or 16) + 4          -- the control: the seed's place moved out of its hit square
        slog("ladder", ("%s: node %s at %.0f%% of the way to the rim; effective scale %.3f, zoom %s"):format(slot, sd.name, (sd.ratio or 0) * 100, es, str(num(M.call(Minimap, "GetZoom")))), true)
        local rows = {}
        for _, e in ipairs(LADDER) do
            local units = e.u or (e.px / es)
            local k = units / sd.B
            local row = { units = units, px = units * es }
            local rec = session({ step = "ladder", label = ("%s %.1f px"):format(slot, units * es), units = units, name = sd.name, logReads = false }, function(S)
                local rs = S.sample("seed offset", sd.dx * k, sd.dy * k, 0, 0)
                local rc = S.sample("centred", 0, 0, 0, 0)
                -- the control's side: the first of +x, -x, +y, -y that keeps the cursor on the map's rect (a map of
                -- 20 or 24 units is too small for any: then it reads unread, which is logged)
                local nx, ny, half = sd.dx * k * es, sd.dy * k * es, units * es / 2
                local cex, cey = ctlOff, 0
                for _, c in ipairs({ { ctlOff, 0 }, { -ctlOff, 0 }, { 0, ctlOff }, { 0, -ctlOff } }) do
                    if math.max(math.abs(nx + c[1]), math.abs(ny + c[2])) <= half - 1 then cex, cey = c[1], c[2]; break end
                end
                local rk = S.sample("control", sd.dx * k, sd.dy * k, cex, cey)
                row.s, row.c, row.ctl = hitOf(rs, sd.name), hitOf(rc, sd.name), hitOf(rk, sd.name)
                row.nSeedPlace = rs and rs.valid and (rs.counts[sd.name] or 0) or nil
                row.nCentred = rc and rc.valid and (rc.counts[sd.name] or 0) or nil
                row.nControl = rk and rk.valid and (rk.counts[sd.name] or 0) or nil
                row.allSeedPlace = rs and rs.valid and countsText(rs.counts) or "unread"
                row.all = rc and rc.valid and countsText(rc.counts) or "unread"
                row.cWhy = rc and not rc.valid and rc.why or nil
            end)
            row.interrupted, row.restoreOK = rec.interrupted, rec.restoreOK
            rows[#rows + 1] = row
            local flag = ""
            if row.s == true and row.nSeedPlace and row.nSeedPlace > verified then flag = flag .. " [the seed's place lists MORE of the name than the verification (" .. verified .. "): a neighbour may be counted]" end
            if row.ctl == true then flag = flag .. " [CONTROL LISTS THE NAME " .. ctlOff .. " px from the seed's place: not the seed alone]" end
            slog("ladder", ("%s %.1f px (%.2f units): at its seed place %s x%s (the read lists: %s), %d px away (control) %s x%s, centred %s x%s (verification %d); the centred read lists: %s%s%s"):format(
                slot, row.px, units, hs(row.s), str(row.nSeedPlace), row.allSeedPlace, ctlOff, hs(row.ctl), str(row.nControl), hs(row.c), str(row.nCentred), verified,
                row.all, row.cWhy and (" (UNREAD: " .. row.cWhy .. ")") or "", flag), true)
            if rec.refused then return "refused: " .. tostring(rec.refused) end
            M.pause(0.2)
        end
        store(key, { slot = slot, node = sd.name, es = es, zoom = sd.zoom, ratio = sd.ratio, verified = verified, controlPx = ctlOff, rows = rows })
        local parts = {}
        for _, r in ipairs(rows) do parts[#parts + 1] = ("%.1fpx:s%s/c%s"):format(r.px, hs(r.s), hs(r.c)) end
        return ("es %.2f: %s"):format(es, table.concat(parts, " "))
    end
end

-- ---- item 1: two same-name nodes ------------------------------------------------------

local function pairBody()
    local A, B2 = M.seeds.pairA, M.seeds.pairB
    if not (A and B2) then return "no pair seeds" end
    homeNow()
    if not (verifySeed("pairA") and verifySeed("pairB")) then return SEED_MSG end
    local es = minimapEs()
    local units = 96
    local k = units / A.B
    local vx, vy = B2.dx - A.dx, B2.dy - A.dy
    local dBase = math.sqrt(vx * vx + vy * vy)
    local dPx = dBase * es                               -- base units to screen px: units * effective scale
    local dPxAt = dPx * k
    slog("pair", ("%s twice, %.1f base units apart: %.1f px on screen at the home size, %.1f px on a %d unit map"):format(A.name, dBase, dPx, dPxAt, units), true)
    if A.name ~= B2.name then slog("pair", "WARNING: the two seeds have different names", true) end
    if dPxAt < 1 then return "the two seeds are the same dot" end
    local ux, uy = vx / dBase, vy / dBase
    local line = {}
    local both = 0
    local rec = session({ step = "pair", label = "pair", units = units, name = A.name, logReads = false, tolerateFocus = true }, function(S)
        local t = -SWEEP
        while t <= dPxAt + SWEEP do
            local r2 = S.sample(("t%+.0f"):format(t), A.dx * k, A.dy * k, t * ux, t * uy)
            if S.dead then break end
            local c = r2 and r2.valid and (r2.counts[A.name] or 0) or nil
            line[#line + 1] = ("%+.0f:%s"):format(t, c == nil and "x" or tostring(c))
            if c and c >= 2 then both = both + 1 end
            t = t + 2
        end
    end)
    slog("pair", ("along A to B (screen px from A, the name's multiplicity): %s"):format(table.concat(line, " ")))
    M.pause(0.3)
    -- the two together at the presence size, centred: how many times the name is listed
    local rp = burst({ step = "pair", label = "presence", px = PRESENCE_PX, name = A.name, logReads = false })
    local prd = rp.reads[1]
    local mult = prd and prd.valid and (prd.counts[A.name] or 0) or nil
    slog("pair", ("placements listing it twice: %d; at the presence size (%.1f px) centred: %s"):format(both, PRESENCE_PX, mult == nil and "unread" or ("x" .. mult)), true)
    store("pair", { distancePx = dPx, distancePxAt = dPxAt, along = table.concat(line, " "), twice = both, presenceMultiplicity = mult, restoreOK = rec.restoreOK })
    return ("pair %.1f px apart; listed twice at %d placements; presence read x%s"):format(dPx, both, str(mult))
end

-- ---- item 3: the tooltip suppression -------------------------------------------------------

local function tipBody()
    local sd = M.seeds.s1
    if not sd then return "no seed" end
    homeNow()
    local hooked = ensureTipHook()
    slog("tip", "the producer hook is " .. (hooked and "installed" or "NOT installed (GameTooltip.SetMinimapMouseover is missing)"), true)
    local units = 24
    local k = units / sd.B
    local out = { hooked = hooked, on = { shown = 0, frames = 0, n = 0 }, off = { shown = 0, frames = 0, n = 0 } }
    local function run(tag, suppress, count)
        for i = 1, count do
            W.supCount = 0
            local rec = burst({ step = "tip", label = tag .. " " .. i, units = units, dx = sd.dx * k, dy = sd.dy * k, name = sd.name, suppress = suppress, tipLog = i <= 2 })
            slog("tip", tag .. " " .. burstLine(rec) .. ("; the hook hid it %d times"):format(W.supCount))
            local o = out[tag]
            o.n, o.shown, o.frames = o.n + 1, o.shown + (rec.tipShown or 0), o.frames + (rec.tipFrames or 0)
            o.hid = (o.hid or 0) + W.supCount
            o.valid = (o.valid or 0) + ((rec.reads[1] and rec.reads[1].valid) and 1 or 0)
            M.pause(0.3)
        end
    end
    run("on", true, 6)
    run("off", false, 3)
    -- a long placed hold with a screenshot: suppression on, then off
    for _, tag in ipairs({ "on", "off" }) do
        W.supCount = 0
        local rec = burst({ step = "tip", label = "held " .. tag, units = units, dx = sd.dx * k, dy = sd.dy * k, name = sd.name, suppress = tag == "on", holdPlaced = 1.5,
            shot = "movescan2: held placed burst, tooltip suppression " .. tag, tipLog = true })
        out["held" .. tag] = { shot = rec.shot, shown = rec.tipShown, frames = rec.tipFrames, hid = W.supCount }
        slog("tip", ("held %s: %s; screenshot %s; the hook hid it %d times"):format(tag, burstLine(rec), tostring(rec.shot), W.supCount), true)
        M.pause(0.5)
    end
    store("tooltip", out)
    return ("suppression on: tooltip shown in %d of %d burst frames (%d bursts); off: %d of %d; hook hid it %d times"):format(out.on.shown, out.on.frames, out.on.n,
        out.off.shown, out.off.frames, out.on.hid or 0)
end

-- ---- item 8: what a known-empty read looks like --------------------------------------------

local function emptyBody()
    homeNow()
    local es = minimapEs()
    local kinds = { presence = {}, locate = {}, unsettledPresence = {}, unsettledLocate = {} }
    local function one(group, o)
        o.step, o.logReads = "empty", false
        local rec = burst(o)
        local rd = rec.reads[1]
        local key
        if not rd then key = "no read (" .. tostring(rec.refused or rec.interrupted) .. ")"
        else key = (rd.valid and "valid " or ("unread[" .. tostring(rd.why) .. "] ")) .. shapeText(rd.shape) end
        tallyInto(kinds[group], key)
        slog("empty", ("%s: %s"):format(group, key))
        M.pause(0.15)
    end
    for _ = 1, 6 do one("presence", { label = "presence", px = PRESENCE_PX }) end
    -- a locate-size window: 32 units, the centre and four points around it
    local pts = { { 0, 0 }, { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 } }
    for rep = 1, 2 do
        for _, p in ipairs(pts) do one("locate", { label = "locate", units = 32, ex = p[1], ey = p[2], dx = 0, dy = 0 }) end
        if rep == 1 then M.pause(0.2) end
    end
    for _ = 1, 6 do one("unsettledPresence", { label = "presence at r+1", px = PRESENCE_PX, unsettled = true }) end
    for _ = 1, 6 do one("unsettledLocate", { label = "locate at r+1", units = 32, unsettled = true }) end
    store("empty", kinds)
    local out = {}
    for _, g in ipairs({ "presence", "locate", "unsettledPresence", "unsettledLocate" }) do
        local parts = {}
        for key, n in pairs(kinds[g]) do parts[#parts + 1] = ("%dx %s"):format(n, key) end
        table.sort(parts)
        slog("empty", ("%s: %s"):format(g, table.concat(parts, " ; ")), true)
        out[#out + 1] = g .. "=" .. #parts .. " kinds"
    end
    return "known-empty shapes logged: " .. table.concat(out, ", ")
end

-- ---- item 9: movement between placement and read ------------------------------------------------

local WALK_OFFSETS = { 0, 4, 6, 8, 10, -6, -8, -10 }
local WALK_SECONDS = 45                        -- the step ends after WALK_BURSTS moving bursts, or this long
local WALK_BURSTS = 20

local function walkBody()
    local sd = M.seeds.walk
    if not sd then return SEED_MSG end
    if not (sd.pos and sd.R) then return "the seed has no position or view radius" end
    if sd.rotate then slog("walk", "the minimap ROTATES: this measure does not apply (Scan.Where would be nil)", true); return "rotating minimap" end
    homeNow()
    if not verifySeed("walk") then return SEED_MSG end
    local es = minimapEs()
    local H = W.H or 16
    local tn, tw = worldTarget(sd.pos[1], sd.pos[2], sd.dx, sd.dy, sd.B, sd.R)
    local units = math.max(24, math.min(400, unitsFor(20, sd.R, H, es)))
    local ppy = pxPerYard(units, es, sd.R)
    slog("walk", ("target %s at world (%.1f north, %.1f west); view radius %.0f yd; map %.1f units = %.1f px for a 20 yd window; %.2f px per yard; H %.1f px"):format(
        sd.name, tn, tw, sd.R, units, units * es, ppy, H), true)
    local t0, n, nextAt = GetTime(), 0, GetTime()
    local rows, agree, differ, unreadN, refused = {}, 0, 0, 0, {}
    local movedMax = 0
    local standing = 0
    while GetTime() - t0 < WALK_SECONDS and n < WALK_BURSTS do
        track()
        if GetTime() >= nextAt then
            local ok, why = admit(nil)
            if ok then                                   -- only while the player is actually moving
                local spd = speed()
                if not (spd and spd > 0) then ok, why = false, "not moving (speed 0)"; standing = standing + 1 end
            end
            if ok then
                n = n + 1
                nextAt = GetTime() + 0.5
                local ex = WALK_OFFSETS[(n - 1) % #WALK_OFFSETS + 1]
                local held = n % 3 == 0
                local sp = speed()
                local rec = burst({ step = "walk", label = "walk " .. n, units = units, name = sd.name, logReads = false, holdPlaced = held and 0.6 or nil,
                    placeFn = function()
                        local p = pos()
                        if not p then return 0, 0, ex, 0 end
                        local pdx, pdy = placeFor(tn, tw, p[1], p[2], units, sd.R)
                        return pdx, pdy, ex, 0
                    end })
                local rd = rec.reads[1]
                if rd and rd.pos1 and rd.pos2 then
                    local ox, oy = nodeOffsetPx(ex, 0, rd.pos1[1], rd.pos1[2], rd.pos2[1], rd.pos2[2], ppy)
                    local want = expectHit(ox, oy, H)
                    local got = hitOf(rd, sd.name)
                    local dn, dw = rd.pos2[1] - rd.pos1[1], rd.pos2[2] - rd.pos1[2]
                    local dist = math.sqrt(dn * dn + dw * dw)
                    if dist > movedMax then movedMax = dist end
                    local verdictText = got == nil and "unread" or (got == want and "AGREES" or "DISAGREES")
                    if got == nil then unreadN = unreadN + 1 elseif got == want then agree = agree + 1 else differ = differ + 1 end
                    rows[#rows + 1] = ("%d ex %+d%s speed %s: moved %.2f yd between placement and read (%.1f north, %.1f west), node %.1f,%.1f px from the cursor at the read, model %s, listed %s: %s"):format(
                        n, ex, held and " HELD" or "", str(sp and ("%.1f"):format(sp)), dist, dn, dw, ox, oy, want and "hit" or "miss", hs(got), verdictText)
                    slog("walk", rows[#rows])
                elseif rd then
                    slog("walk", ("%d: no position pair (UnitPosition unreadable?)"):format(n))
                else
                    slog("walk", ("%d: %s"):format(n, burstLine(rec)))
                end
            else
                tallyInto(refused, why)
            end
        end
        M.frames(1)
    end
    local rt = {}
    for why, c in pairs(refused) do rt[#rt + 1] = ("%s %d"):format(why, c) end
    store("walk", { bursts = n, agree = agree, differ = differ, unread = unreadN, movedMax = movedMax, H = H, units = units, ppy = ppy, rows = rows, refused = table.concat(rt, ", ") })
    local txt = ("%d moving bursts in %.0f s (%s): the model (the read covers the world around the player at the READ, the map frame where it was placed) agreed %d, disagreed %d, unread %d; the largest move between placement and read %.2f yd; frames refused: %s"):format(
        n, GetTime() - t0, n >= WALK_BURSTS and "enough" or "TIMED OUT: too few moving bursts", agree, differ, unreadN, movedMax, #rt > 0 and table.concat(rt, ", ") or "none")
    slog("walk", txt, true)
    return txt
end

-- ---- the round --------------------------------------------------------------------------

local def2 = { rev = 1, title = "The last measurements before #91's code (1 of 2, mostly automatic)" }
def2[#def2 + 1] = { text = "Readback only: build, minimap size, zoom, view radius, the APIs the scan needs. It also clears this round's saved results.", auto = true, run = infoRun }
def2[#def2 + 1] = { text = "Stand still where a herb or ore dot sits well inside the minimap (top right of the screen), not at its edge. Hover the dot with the mouse and keep it there: it seeds itself after two seconds on the same name. Don't move the character until the zoom step.",
    wait = seed("s1", "a herb or ore dot"), timeout = 240, check = seedCheck("s1") }
measureSeeded(def2, "Press Ready, then rest the mouse on open world in the middle of the screen. The minimap will blink invisibly for about 25 s (the hit square at four map sizes). It first checks that the dot is still listed; if not, it asks you to hover a dot again.",
    "Keep the mouse in the middle of the screen, over the world, still.", "hit", "mouse in the middle, still", hitBody("s1", "hit_zoom1"), 240, "s1", "a herb or ore dot")
measureSeeded(def2, "Press Ready and keep the mouse still on open world. About 6 s of short blinks (the presence size, and the sizes around it, with a control read).",
    "Keep the mouse in the middle of the screen, over the world, still.", "ladder", "mouse in the middle, still", ladderBody("s1", "ladder_scale1"), 120, "s1", "a herb or ore dot")
M.measure(def2, "Press Ready and keep the mouse still on open world. A few blinks, then two long ones with a screenshot taken during each (tooltip suppression).",
    "Keep the mouse in the middle of the screen, over the world, still.", "tip", "mouse in the middle, still", tipBody, 120, needSeed("s1"), true)
def2[#def2 + 1] = { text = "During the two LONG blinks (the second half of the last step): did a tooltip with a node's name appear next to the mouse?", ask = true }
def2[#def2 + 1] = { text = "Optional (Skip it if there is only one dot): hover one dot of two of the SAME herb or ore and keep it there.",
    wait = seed("pairA", "the first dot"), timeout = 120, check = seedCheck("pairA") }
def2[#def2 + 1] = { text = "Optional: now hover the OTHER dot of the same name and keep it there.", wait = seed("pairB", "the second dot"), timeout = 120, check = seedCheck("pairB") }
M.measure(def2, "Press Ready and keep the mouse still on open world (it skips itself without both seeds, or if either dot is no longer listed).",
    "Keep the mouse in the middle of the screen, over the world, still.", "pair", "mouse in the middle, still", function()
        local r = pairBody()
        if r == SEED_MSG then return "skipped: " .. r end
        return r
    end, 120,
    function() if not (M.seeds.pairA and M.seeds.pairB) then return "skip", "skipped: no pair seeds" end return true end, true)
def2[#def2 + 1] = { text = "Hover the dot NEAREST THE EDGE of the minimap (the rim of the round map) and keep it there. If every dot is near the middle, walk until one is near the edge first. Don't move after it seeds.",
    wait = seed("rim", "the dot nearest the minimap's edge"), timeout = 240, check = seedCheck("rim") }
measureSeeded(def2, "Press Ready and keep the mouse still on open world (the presence size with that dot at the rim).",
    "Keep the mouse in the middle of the screen, over the world, still.", "ladder", "mouse in the middle, still", ladderBody("rim", "ladder_rim"), 120, "rim", "the dot nearest the minimap's edge")
def2[#def2 + 1] = { text = "Change the minimap's ZOOM: click the + or - button beside the minimap, or scroll the wheel over it, by one or two steps. Stay where you are. This step completes by itself when the zoom changes.",
    wait = function()
        local z = num(M.call(Minimap, "GetZoom"))
        if z and W.zoom0 and z ~= W.zoom0 then return true, ("zoom %s -> %s"):format(str(W.zoom0), str(z)) end
        return false, ("zoom is %s: change it with + / - or the wheel"):format(str(z))
    end, timeout = 300 }
def2[#def2 + 1] = { text = "Hover a herb or ore dot again (the zoom moved them) and keep it there.", wait = seed("z2", "a herb or ore dot"), timeout = 240, check = seedCheck("z2") }
measureSeeded(def2, "Press Ready and keep the mouse still on open world (the hit square at the other zoom).",
    "Keep the mouse in the middle of the screen, over the world, still.", "hit", "mouse in the middle, still", hitBody("z2", "hit_zoom2"), 240, "z2", "a herb or ore dot")
def2[#def2 + 1] = { text = "Change the UI SCALE: Esc, Options, the Video (or Graphics) tab, turn on 'Use UI Scale' if it is off, and move the UI Scale slider by about 15 percent (Apply if there is a button). Do NOT reload. Completes by itself when the minimap's effective scale changes.",
    wait = function()
        local es = minimapEs()
        if W.es0 and math.abs(es - W.es0) / W.es0 > 0.03 then return true, ("effective scale %.3f -> %.3f"):format(W.es0, es) end
        return false, ("effective scale is %.3f: change the UI scale"):format(es)
    end, timeout = 300 }
def2[#def2 + 1] = { text = "Close the options window, then hover a herb or ore dot on the minimap and keep it there.", wait = seed("sc2", "a herb or ore dot"), timeout = 240, check = seedCheck("sc2") }
measureSeeded(def2, "Press Ready and keep the mouse still on open world (the presence size at the second UI scale).",
    "Keep the mouse in the middle of the screen, over the world, still.", "ladder", "mouse in the middle, still", ladderBody("sc2", "ladder_scale2"), 120, "sc2", "a herb or ore dot")
def2[#def2 + 1] = { text = "Hover a herb or ore dot you can walk past and keep it there while STANDING still.", wait = seed("walk", "a herb or ore dot"), timeout = 240, check = seedCheck("walk") }
measureSeeded(def2, "Press Ready, rest the mouse on open world, then walk FORWARD with the W key only, in a straight line past that dot, keeping it on the minimap. Do NOT hold any mouse button and do not steer with the mouse. It counts only while you are moving and ends after 20 bursts (or 45 s).",
    "Keep walking forward with W only; the mouse resting on open ground, no mouse button held.", "walk", "mouse still, walking with W", walkBody, 150, "walk", "a herb or ore dot")
def2[#def2 + 1] = { text = "Now go where NO herb or ore dot shows on the minimap (no node in range), stand still, then press Ready.", button = "Ready", run = function() return "ready" end }
M.measure(def2, "Press Ready and rest the mouse on open world. About 8 s of short blinks (what a valid read with nothing there looks like).",
    "Keep the mouse in the middle of the screen, over the world, still.", "empty", "mouse in the middle, still", emptyBody, 120, nil, true)
def2[#def2 + 1] = { text = "Did anything on screen blink or flicker, other than the minimap itself, in any of the blinks of this round? Say what in the note.", ask = true }
def2[#def2 + 1] = { text = "Type /reload (or press Reload now) in this window to save the results.", reload = true }
Probe:Steps("movescan2", def2)

--------------------------------------------------------------------------------
-- movescan3: the steps
--------------------------------------------------------------------------------

-- ---- item 4: clicks and mouselook in each phase ----------------------------------------------

local INPUT_CYCLE = 6
local inputCfg = {
    step = "input", seconds = 240, every = 0.25, ignoreGate = false,
    burst = function(st)
        local i = (st.n - 1) % INPUT_CYCLE
        local o = { step = "input", label = "input " .. st.n, px = PRESENCE_PX, flavor = (st.n % 2 == 0) and "A" or "B", abortOnDown = (st.n % 2 == 0),
            clicksOn = W.input and W.input.control == true, logReads = false }
        if i == 4 then o.holdPrepared = 1.2 end
        if i == 5 then o.holdPlaced = 1.2 end
        return o
    end,
    onBurst = function(st, rec)
        local inp = W.input
        if not inp then return end
        inp.bursts = (inp.bursts or 0) + 1
        if rec.refused then return end
        if not rec.restoreOK then inp.restoreBad = (inp.restoreBad or 0) + 1 end
        if not rec.readbackOK then inp.readbackBad = (inp.readbackBad or 0) + 1 end
        if rec.interrupted then inp.interrupted = inp.interrupted or {}; tallyInto(inp.interrupted, tostring(rec.interrupted)) end
        local rd = rec.reads[1]
        if rd and rd.valid then inp.valid = (inp.valid or 0) + 1 end
    end,
    summary = function(st) return "input loop ended" end,
}

local function inputStart()
    W.input = { counts = {}, st = { refused = {} } }
    W.watch = true
    local d = db()
    if d then d.events, d.input = {}, {} end
    homeNow()
    return "bursts are running whenever the cursor rests on open world"
end
local function inputAlive()
    local inp = W.input
    if not inp then return false end
    if inp.st.finished then inp.st = { refused = {} } end
    startLoop(inp.st, inputCfg)
    return true
end
local function inputCount(button, event)
    local inp = W.input
    return inp and inp.counts and (inp.counts[event .. " " .. button] or 0) or 0
end
local function inputWait(button, event, n, what)
    return function()
        if not inputAlive() then return false, "press the first step's button" end
        local c = inputCount(button, event)
        if c >= n then return true, ("%d %s %s counted"):format(c, button, event) end
        return false, ("%d of %d %s: %s"):format(c, n, event, what)
    end
end
-- An end step is a wait step: it stops the loop and completes once the last burst has finished,
-- so the minimap's state is compared at rest.
local function inputEnd()
    local inp = W.input
    if not inp then return true, "no input run" end
    stopLoop(inp.st)
    local S0, job = M.state()
    if job or S0 then return false, "letting the last burst finish" end
    W.watch = false
    local d = db()
    local tallies = {}
    if d and d.input then for k, v in pairs(d.input) do tallies[#tallies + 1] = ("%s = %d"):format(k, v) end end
    table.sort(tallies)
    slog("input", ("done: %d bursts, %d valid, %d ended by a mouse button down, restore not clean %d, readback differs %d, interrupted %s; mouselook starts %d"):format(
        inp.bursts or 0, inp.valid or 0, inp.endedByDown or 0, inp.restoreBad or 0, inp.readbackBad or 0, str(inp.interrupted), inp.mlStarts or 0), true)
    slog("input", "events by kind | phase: " .. table.concat(tallies, "; "), true)
    store("input", { bursts = inp.bursts, valid = inp.valid, endedByDown = inp.endedByDown, restoreBad = inp.restoreBad, readbackBad = inp.readbackBad,
        mlStarts = inp.mlStarts, mlPhase = inp.mlPhase, tallies = tallies })
    local res = ("%d bursts; restore not clean %d; MINIMAP_PING %d"):format(inp.bursts or 0, inp.restoreBad or 0, (inp.counts or {})["MINIMAP_PING"] or 0)
    W.input = nil
    return true, res
end

-- ---- item 5: a fight, Edit Mode, a low frame rate ---------------------------------------------------

local function homeCompare(tag)
    local S0 = M.state()
    local same = W.home and M.compare(W.home, M.snapshot()).all
    slog(tag, ("map borrow %s; the minimap %s the state before the round"):format(S0 and "STILL OPEN" or "closed", W.home and (same and "is back to" or "DIFFERS from") or "was not compared with"), true)
    return not S0 and same
end

local fightCfg
local function fightCombatBurst(st)
    -- once per fight, in combat: does an unprotected Minimap still move? (the host logs ADDON_ACTION_BLOCKED)
    local tag = ("fight %d"):format(W.fight.n or 0)
    if st.combatDone == W.fight.n then return end
    st.combatDone = W.fight.n
    local S0, job = M.state()
    if job or S0 then return end
    M.setForceCombat(true)
    W.active = true
    M.start("fight", function()
        local S1 = M.state()
        W.home = S1 or W.home
        if S1 then M.restore("combat burst start") end
        local rec = burst({ step = "fight", label = tag .. " in combat", px = PRESENCE_PX, ignoreGate = true, forceCombat = true, holdPlaced = 0.3, logReads = false })
        slog("fight", ("%s: a burst IN COMBAT: %s; operation errors: %s"):format(tag, burstLine(rec), tostring(rec.opErr)), true)
        W.fight.combatBursts = W.fight.combatBursts or {}
        W.fight.combatBursts[#W.fight.combatBursts + 1] = { ok = rec.restoreOK == true and rec.readbackOK == true, refused = rec.refused, opErr = rec.opErr, frames = rec.frames, ms = rec.ms }
        return "combat burst done"
    end, function() M.setForceCombat(false) end)
end

fightCfg = {
    step = "fight", seconds = 300, every = 0.12, ignoreGate = true,
    burst = function(st) return { step = "fight", label = "fight " .. st.n, px = PRESENCE_PX, ignoreGate = true, holdPlaced = (st.n % 4 == 0) and 0.4 or nil, logReads = false } end,
    onBurst = function(st, rec) if rec.refused then tallyInto(st.refused, rec.refused) end end,
}

local function fightStart()
    W.fight = { n = 0 }
    W.watch = true
    homeNow()
    return "bursts are running, back to back"
end
local fightSt
local function fightWait(goal)
    return function()
        local f = W.fight
        if not f then return false, "press the first step's button" end
        fightSt = fightSt or { refused = {} }
        if f.inCombat then
            local S0, job = M.state()
            if not job and not S0 and InCombatLockdown() then fightCombatBurst(fightSt) end
        else
            startLoop(fightSt, fightCfg)
            if fightSt.finished then fightSt = { refused = {} } end
        end
        if (f.n or 0) >= goal then return true, ("%d fights; %d started inside a burst"):format(f.n, f.inBurst or 0) end
        return false, ("%d of %d fights; %d began inside a burst; bursts refused: %s"):format(f.n or 0, goal, f.inBurst or 0, str(fightSt.refused))
    end
end
local function fightEnd()
    local f = W.fight
    if not f then return true, "no fight run" end
    if fightSt then stopLoop(fightSt) end
    local S0, job = M.state()
    if job or S0 then return false, "letting the last burst finish" end
    fightSt = nil
    W.watch = false
    local ok = homeCompare("fight")
    local cb = {}
    for _, c in ipairs(f.combatBursts or {}) do cb[#cb + 1] = c.ok and "ok" or ("BAD " .. tostring(c.refused or c.opErr or "restore")) end
    slog("fight", ("%d fights; %d began while the map was borrowed; after each the minimap was back %d of %d times; bursts run in combat: [%s]"):format(f.n or 0, f.inBurst or 0,
        f.afterOK or 0, f.afterN or 0, table.concat(cb, ", ")), true)
    store("fight", { fights = f.n, inBurst = f.inBurst, events = f.events, afterOK = f.afterOK, afterN = f.afterN, combatBursts = f.combatBursts, homeOK = ok })
    W.fight = nil
    return true, ("%d fights, %d inside a burst, back home %s"):format(f.n or 0, f.inBurst or 0, tostring(ok))
end

local editCfg = {
    step = "editmode", seconds = 240, every = 0.15, ignoreGate = true,
    burst = function(st) return { step = "editmode", label = "editmode " .. st.n, px = PRESENCE_PX, ignoreGate = true, holdPlaced = (st.n % 3 == 0) and 0.5 or nil, logReads = false } end,
    onBurst = function(st, rec) if rec.refused then tallyInto(st.refused, rec.refused) end end,
}
local editSt
local function editStart()
    W.edit = { enters = 0, exits = 0 }
    W.watch = true
    homeNow()
    return "bursts are running, back to back, wherever the cursor is"
end
local function editWait()
    return function()
        local e = W.edit
        if not e then return false, "press the first step's button" end
        editSt = editSt or { refused = {} }
        startLoop(editSt, editCfg)
        if editSt.finished then editSt = { refused = {} } end
        if (e.enters or 0) >= 1 and (e.exits or 0) >= 1 then return true, ("entered %d, left %d; %d entered inside a burst"):format(e.enters, e.exits, e.inBurst or 0) end
        return false, ("Edit Mode entered %d, left %d; bursts refused: %s"):format(e.enters or 0, e.exits or 0, str(editSt.refused))
    end
end
local function editEnd()
    local e = W.edit
    if not e then return true, "no Edit Mode run" end
    if editSt then stopLoop(editSt) end
    local S0, job = M.state()
    if job or S0 then return false, "letting the last burst finish" end
    editSt = nil
    W.watch = false
    local ok = homeCompare("editmode")
    slog("editmode", ("entered %d, left %d; %d entered while the map was borrowed; after each the minimap was back %d of %d times"):format(e.enters or 0, e.exits or 0, e.inBurst or 0,
        e.afterOK or 0, e.afterN or 0), true)
    store("editmode", { enters = e.enters, exits = e.exits, inBurst = e.inBurst, events = e.events, afterOK = e.afterOK, afterN = e.afterN, homeOK = ok })
    W.edit = nil
    return true, ("Edit Mode %d times, %d inside a burst, back home %s"):format(e.enters or 0, e.inBurst or 0, tostring(ok))
end

local function lowfpsBody()
    homeNow()
    local d = db()
    local api = cvarApi
    local ok, why = fpsTake(api, d or {})
    if not ok then slog("lowfps", "cannot cap the frame rate: " .. tostring(why), true); return "no maxFPS" end
    slog("lowfps", ("maxFPS %s saved, set to %s"):format(str(d and d.fpsPending and d.fpsPending.value), FPS_CAP), true)
    local t = GetTime()
    while GetTime() - t < 1.5 do M.frames(1) end
    local gf = rawget(_G, "GetFramerate")
    slog("lowfps", ("frame rate now %s (the cap is %s)"):format(gf and str(select(2, pcall(gf))) or "n/a", FPS_CAP), true)
    local ms, frames, bad = {}, {}, 0
    local nValid = 0
    local n, t0, nextAt = 0, GetTime(), GetTime()
    local refused = {}
    while n < 14 and GetTime() - t0 < 60 do
        track()
        if GetTime() >= nextAt then
            local okA, whyA = admit(nil)
            if okA then
                n = n + 1
                nextAt = GetTime() + 0.8
                local rec = burst({ step = "lowfps", label = "low fps " .. n, px = PRESENCE_PX, tipLog = n <= 2, logReads = false })
                slog("lowfps", burstLine(rec))
                if not rec.refused then
                    ms[#ms + 1], frames[#frames + 1] = rec.ms or 0, rec.frames or 0
                    if not (rec.restoreOK and rec.readbackOK) then bad = bad + 1 end
                    if rec.reads[1] and rec.reads[1].valid then nValid = nValid + 1 end
                end
            else
                tallyInto(refused, whyA)
            end
        end
        M.frames(1)
    end
    local gfps = fpsGive(api, d or {})
    slog("lowfps", "maxFPS put back: " .. tostring(gfps), true)
    local sm = statsOf(ms)
    local over = 0
    for _, v in ipairs(ms) do if v > 250 then over = over + 1 end end
    slog("lowfps", ("burst duration (ms, borrow to readback) %s; frames per burst %s; over the plan's 250 ms budget: %d; valid reads %d; restore not clean %d"):format(statsText(sm), statsText(statsOf(frames)), over, nValid, bad), true)
    store("lowfps", { ms = sm, frames = statsOf(frames), over250 = over, valid = nValid, bad = bad, refused = refused, restored = gfps })
    return ("%d bursts at maxFPS %s: %s ms; %d over 250 ms; restore not clean %d; maxFPS back %s"):format(n, FPS_CAP, statsText(sm), over, bad, tostring(gfps))
end

-- ---- item 6: what travels with Minimap; a skin that re-anchors it ---------------------------------

local ATTACHED = { "QueueStatusButton", "MiniMapLFGFrame", "MiniMapBattlefieldFrame", "MiniMapMailFrame", "MiniMapTrackingFrame", "MiniMapInstanceDifficulty",
    "GameTimeFrame", "MinimapZoneTextButton", "MiniMapWorldMapButton", "LibDBIcon10_NodeRadar" }

local function frameSig(f)
    local l, b, w, h = M.call(f, "GetRect")
    return { l = num(l), b = num(b), w = num(w), h = num(h), shown = M.call(f, "IsShown") == true, alpha = num(M.call(f, "GetEffectiveAlpha")) }
end
local function sigText(s)
    if not s.l then return ("shown %s, no rect"):format(tostring(s.shown)) end
    return ("shown %s, alpha %s, rect %.0f,%.0f %.0fx%.0f"):format(tostring(s.shown), str(s.alpha), s.l, s.b, s.w, s.h)
end
local function moved(a, b) return a.l and b.l and (math.abs(a.l - b.l) > 2 or math.abs(a.b - b.b) > 2) end

local function attachedBody()
    homeNow()
    local items = {}
    for _, nm in ipairs(ATTACHED) do
        local f = rawget(_G, nm)
        if type(f) == "table" and type(f.GetRect) == "function" then items[#items + 1] = { name = nm, f = f } end
    end
    local okk, kids = pcall(function() return { Minimap:GetChildren() } end)
    for i, c in ipairs(okk and kids or {}) do
        if i <= 40 and M.call(c, "IsShown") == true then items[#items + 1] = { name = "Minimap child " .. M.relName(c), f = c } end
    end
    local cluster = rawget(_G, "MinimapCluster")
    local container = type(cluster) == "table" and cluster.MinimapContainer
    if type(container) == "table" then
        local okc, ck = pcall(function() return { container:GetChildren() } end)
        for i, c in ipairs(okc and ck or {}) do if i <= 20 then items[#items + 1] = { name = "container child " .. M.relName(c), f = c } end end
    end
    slog("attached", ("%d candidate frames (the named ones that exist, Minimap's shown children, the container's children)"):format(#items), true)
    for _, it in ipairs(items) do
        it.before = frameSig(it.f)
        slog("attached", ("before: %s: %s; points %s"):format(it.name, sigText(it.before), (M.describeFrame(it.f):match("points (.*)$")) or "?"))
    end
    local during
    local rec = session({ step = "attached", label = "attached", px = PRESENCE_PX, logReads = false, tipLog = false }, function(S)
        if not S.place(0, 0) then return end
        if not S.frame() then return end
        if not S.frame() then return end
        for _, it in ipairs(items) do it.during = frameSig(it.f) end
        during = true
        local shot = S.hold(1.5, "placed", "movescan3: Minimap placed under the cursor, attached frames")
        S.rec.shot = shot
        for _, it in ipairs(items) do it.late = frameSig(it.f) end
        S.read("attached")
    end)
    local travel = {}
    for _, it in ipairs(items) do
        local d1 = it.during and moved(it.before, it.during)
        local d2 = it.late and moved(it.before, it.late)
        slog("attached", ("%s: before %s; during %s; late %s%s"):format(it.name, sigText(it.before), it.during and sigText(it.during) or "n/a", it.late and sigText(it.late) or "n/a",
            (d1 or d2) and " TRAVELS WITH MINIMAP" or ""))
        if d1 or d2 then travel[#travel + 1] = it.name end
    end
    local after = {}
    for _, it in ipairs(items) do after[#after + 1] = moved(it.before, frameSig(it.f)) and it.name or nil end
    store("attached", { n = #items, travels = travel, notBack = after, shot = rec.shot, restoreOK = rec.restoreOK, during = during == true })
    slog("attached", ("frames that travelled with Minimap: %s; not back afterwards: %s; screenshot %s"):format(#travel > 0 and table.concat(travel, ", ") or "none",
        #after > 0 and table.concat(after, ", ") or "none", tostring(rec.shot)), true)
    return ("%d frames checked; travelled: %s"):format(#items, #travel > 0 and table.concat(travel, ", ") or "none")
end

local function skinBody()
    homeNow()
    if not ensureSkinHook() then return "could not hook Minimap:SetPoint" end
    local home = W.home or M.snapshot()
    W.skinHome = home.points
    local out = {}
    for _, mode in ipairs({ "anchor", "anchor+alpha" }) do
        W.skin, W.skinPulls = mode, 0
        local invalid, valid, flicker, restoreBad = 0, 0, 0, 0
        local why = {}
        for i = 1, 6 do
            local held = i == 6
            local rec = burst({ step = "fakeskin", label = ("%s %d"):format(mode, i), px = PRESENCE_PX, logReads = false, holdPlaced = held and 1.0 or nil,
                shot = (held and mode == "anchor+alpha") and "movescan3: a skin re-anchoring Minimap (anchor+alpha)" or nil })
            local rd = rec.reads[1]
            if rd then
                if rd.valid then valid = valid + 1 else invalid = invalid + 1; tallyInto(why, (tostring(rd.why):gsub("[%d%.]+", "N"))) end
            elseif rec.interrupted then                         -- the burst ended before its read: unread, never "nothing there"
                invalid = invalid + 1
                tallyInto(why, "ended: " .. tostring(rec.interrupted))
            end
            if not (rec.restoreOK and rec.readbackOK) then restoreBad = restoreBad + 1 end
            -- visible flicker: Minimap opaque and on screen at some point
            if (rec.opaque or 0) > 0 then flicker = flicker + 1 end
            slog("fakeskin", ("%s %d: %s; pulls so far %d; perr %s; Minimap opaque in %d frames of the borrow"):format(mode, i, burstLine(rec), W.skinPulls or 0,
                rd and str(rd.perr and ("%.1f"):format(rd.perr)) or "n/a", rec.opaque or 0))
            M.pause(0.3)
        end
        local whyT = {}
        for k, v in pairs(why) do whyT[#whyT + 1] = ("%s x%d"):format(k, v) end
        out[mode] = { valid = valid, invalid = invalid, restoreBad = restoreBad, why = table.concat(whyT, ", "), pulls = W.skinPulls, opaqueBursts = flicker }
        slog("fakeskin", ("mode %s: %d valid reads, %d unread (%s), restore not clean %d, the skin pulled the map back %d times, Minimap opaque during %d bursts"):format(mode, valid, invalid,
            table.concat(whyT, ", "), restoreBad, W.skinPulls or 0, flicker), true)
    end
    W.skin = nil
    local okH = homeCompare("fakeskin")
    out.homeOK = okH
    store("fakeskin", out)
    return ("anchor: %d valid / %d unread; anchor+alpha: %d valid / %d unread; home %s"):format(out.anchor.valid, out.anchor.invalid, out["anchor+alpha"].valid, out["anchor+alpha"].invalid, tostring(okH))
end

-- ---- item 7: a riding cadence --------------------------------------------------------------------

local ridingCfg = {
    step = "riding", seconds = 60, every = 2, ignoreGate = false,
    burst = function(st) return { step = "riding", label = "riding " .. st.n, px = PRESENCE_PX, logReads = false } end,
    onBurst = function(st, rec)
        st.rows = st.rows or {}
        if rec.refused then tallyInto(st.refused, rec.refused); return end
        local rd = rec.reads[1]
        st.valid = st.valid or 0
        st.unread = st.unread or {}
        if rd and rd.valid then st.valid = st.valid + 1 else tallyInto(st.unread, tostring(rd and rd.why or rec.interrupted or "no read")) end
        st.ms = st.ms or {}
        st.ms[#st.ms + 1] = rec.ms or 0
        if not (rec.restoreOK and rec.readbackOK) then st.bad = (st.bad or 0) + 1 end
        slog("riding", ("%d: %s; speed %s; mounted %s; reads: %s"):format(st.n, burstLine(rec), str(speed()), tostring(rawget(_G, "IsMounted") and select(2, pcall(rawget(_G, "IsMounted")))),
            rd and countsText(rd.counts) or "none"))
    end,
    summary = function(st)
        local ut = {}
        for k, v in pairs(st.unread or {}) do ut[#ut + 1] = ("%s x%d"):format(k, v) end
        local rt = {}
        for k, v in pairs(st.refused or {}) do rt[#rt + 1] = ("%s %d"):format(k, v) end
        table.sort(ut); table.sort(rt)
        local txt = ("%d bursts in %.0f s: %d valid, unread [%s]; restore not clean %d; burst ms %s; frames refused by the gate [%s]"):format(st.n or 0, GetTime() - (st.t0 or GetTime()),
            st.valid or 0, table.concat(ut, ", "), st.bad or 0, statsText(statsOf(st.ms or {})), table.concat(rt, ", "))
        store("riding", { bursts = st.n, valid = st.valid, unread = ut, restoreBad = st.bad, ms = statsOf(st.ms or {}), refused = rt })
        slog("riding", txt, true)
        return txt
    end,
}

local function ridingBody()
    homeNow()
    local st = { refused = {} }
    return loopBody(ridingCfg, st)()
end

-- ---- the round ----------------------------------------------------------------------------

local def3 = { rev = 1, title = "The last measurements before #91's code (2 of 2, you act)" }
def3[#def3 + 1] = { text = "Plan: the minimap will blink invisibly whenever the mouse rests on open world (the middle of the screen). Close or move the /fp console and this panel off the middle of the screen. Press Start, then keep the mouse in the middle of the screen. You will click, steer and press Esc during the next steps.",
    button = "Start", run = inputStart }
def3[#def3 + 1] = { text = "Left-click on open world (not on the minimap, nothing to interact with) 8 times, a second or two apart. Counted by itself.",
    wait = inputWait("LeftButton", "DOWN", 8, "left-click the world"), timeout = 120 }
def3[#def3 + 1] = { text = "Right-click on open world 8 times: quick taps, no turning. Counted by itself.", wait = inputWait("RightButton", "DOWN", 8, "right-click the world (a quick tap)"), timeout = 120 }
def3[#def3 + 1] = { text = "Now steer: hold the RIGHT button and turn the camera for about a second, release, and do that 3 times. Counted by itself.",
    wait = function()
        if not inputAlive() then return false, "press the first step's button" end
        local c = W.input.mlStarts or 0
        if c >= 3 then return true, ("%d mouselook starts"):format(c) end
        return false, ("%d of 3 mouselook starts: hold the RIGHT button and turn the camera"):format(c)
    end, timeout = 120 }
def3[#def3 + 1] = { text = "Control: for the next few seconds the borrowed minimap keeps its clicks ON. Left-click on open world ONCE. You may see a ping on the minimap; this shows whether a click reaching the borrowed map would be seen.",
    wait = function()
        if not inputAlive() then return false, "press the first step's button" end
        W.input.control = true
        local p = (W.input.counts or {})["MINIMAP_PING"] or 0
        if p >= 1 then return true, "a ping was seen" end
        return false, "left-click on open world once"
    end, timeout = 45 }
def3[#def3 + 1] = { text = "Done with clicks and steering. Saving the input results (it waits for the last blink to finish).", wait = function() if W.input then W.input.control = false end return inputEnd() end, timeout = 30 }

def3[#def3 + 1] = { text = "Fight: find a weak monster. Press Start, then pull it and fight (or let it hit you) three times, three separate fights; out of combat between them. The minimap blinks back to back meanwhile: it is invisible. Counted by itself.",
    button = "Start", run = fightStart }
def3[#def3 + 1] = { text = "Pull and fight a monster; repeat until the counter reaches 3 fights.", wait = fightWait(3), timeout = 360 }
def3[#def3 + 1] = { text = "Done fighting. Saving (it waits for the last blink to finish).", wait = fightEnd, timeout = 30 }

def3[#def3 + 1] = { text = "Edit Mode: press Start, then open Esc, Edit Mode, leave it open for a couple of seconds, then exit it (Esc, or its close/Cancel). The minimap blinks back to back meanwhile.",
    button = "Start", run = editStart }
def3[#def3 + 1] = { text = "Open Edit Mode, wait 2 s, close it. Completes by itself when you have been in and out.", wait = editWait(), timeout = 180 }
def3[#def3 + 1] = { text = "Done with Edit Mode. Saving (it waits for the last blink to finish).", wait = editEnd, timeout = 30 }

M.measure(def3, "Low frame rate: press Ready and rest the mouse on open world. The probe caps your frame rate (CVar maxFPS) at 20 for about 15 s and puts your value back by itself, also after a reload.",
    "Keep the mouse in the middle of the screen, over the world, still. The game will look choppy.", "lowfps", "mouse in the middle, still", lowfpsBody, 120, nil, true)

def3[#def3 + 1] = { text = "Queue for something so the small LFG eye (or any queue icon) shows beside the minimap, top right of the screen; a dungeon or battleground queue will do. If you cannot queue, press Skip.", button = "Queued", run = function() return "queued" end }
M.measure(def3, "Press Ready and rest the mouse on open world. The minimap leaves for about 2 s and a screenshot is taken while it is away.",
    "Keep the mouse in the middle of the screen, over the world, still.", "attached", "mouse in the middle, still", attachedBody, 120, nil, true)
def3[#def3 + 1] = { text = "In that long blink: did the LFG eye (or any icon or button) appear under the mouse in the middle of the screen, or stay behind next to the empty minimap spot? Say which in the note.", ask = true }
M.measure(def3, "A fake skin: for this step the probe re-anchors the minimap every time it is moved, as some skins do. Press Ready and rest the mouse on open world. Watch the minimap's usual place (top right) and the middle of the screen for any flash.",
    "Keep the mouse in the middle of the screen, over the world, still. Watch for flashes.", "fakeskin", "mouse in the middle, still", skinBody, 120, nil, true)
def3[#def3 + 1] = { text = "Did you see the minimap (even a small square) flash at its usual place, or anywhere else, during that step? Say where, and in which half (the second half is the one with it opaque), in the note.", ask = true }

M.measure(def3, "Riding: mount up and ride in open world with the KEYBOARD only (W, A, D; no mouse button) for 60 s after pressing Ready. Rest the mouse on open world before you press it.",
    "Keep riding with the keyboard; keep the mouse still on open world. 60 s.", "riding", "mouse in the middle, riding", ridingBody, 150, nil, true)
def3[#def3 + 1] = { text = "While riding, did you see the minimap blink at all (a flicker at the top right of the screen)?", ask = true }
def3[#def3 + 1] = { text = "Was it annoying, something you would switch off? (Yes = annoying, No = barely or not at all; say 'not', 'barely' or 'annoying' in the note.)", ask = true }
def3[#def3 + 1] = { text = "Type /reload (or press Reload now) in this window to save the results.", reload = true }
Probe:Steps("movescan3", def3)

NS._ms2 = {
    W = W, classify = classify, shapeText = shapeText, verdict = verdict, findEdges = findEdges, edgesText = edgesText,
    pxPerYard = pxPerYard, unitsFor = unitsFor, worldTarget = worldTarget, placeFor = placeFor, nodeOffsetPx = nodeOffsetPx, expectHit = expectHit,
    fpsTake = fpsTake, fpsGive = fpsGive, fpsRestore = fpsRestore, skinAction = skinAction, statsOf = statsOf, hitOf = hitOf,
    session = session, burst = burst, admit = admit, loopBody = loopBody, hitBody = hitBody, ladderBody = ladderBody, pairBody = pairBody, tipBody = tipBody,
    emptyBody = emptyBody, walkBody = walkBody, lowfpsBody = lowfpsBody, attachedBody = attachedBody, skinBody = skinBody, ridingBody = ridingBody,
    verifySeed = verifySeed, retrying = retrying, SEED_MSG = SEED_MSG, seedReady = seedReady,
    infoRun = infoRun, annotate = annotate, inputStart = inputStart, inputEnd = inputEnd, fightStart = fightStart, fightEnd = fightEnd,
    editStart = editStart, editEnd = editEnd, fightWait = fightWait, editWait = editWait, inputWait = inputWait, inputAlive = inputAlive,
    onAbort = onAbort, onEvent = onEvent, db = db, track = track, slog = slog, ensureTipHook = ensureTipHook, ensureSkinHook = ensureSkinHook,
}
