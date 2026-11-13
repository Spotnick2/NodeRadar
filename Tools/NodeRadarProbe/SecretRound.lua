--------------------------------------------------------------------------------
-- The secret round (/fp steps nr secret): what can an addon still read of the minimap's hover
-- tooltip on client build 1.60.1.70938?
--
-- Measured before (not re-measured here): from 70938, NodeRadar's scan reads nothing.
-- C_TooltipInfo.GetMinimapMouseover() still returns a plain table, data.lines is a plain table,
-- but line.leftText is a secret value, on the scan's MOVED map. An empty read is plain.
--
-- This round asks the same on a real hover (the minimap at its normal home, the owner's own
-- mouse on a gathering node's dot): every field of the read, what GameTooltip itself answers,
-- the global secrecy state, and what a TooltipDataProcessor post-call for the MinimapMouseover
-- type receives. A control step hovers another kind of icon (skippable).
--
-- Every frame the top mouse focus is Minimap, the facts are collected; only the distinct shapes
-- (deduped by a signature of plain parts and the word "<secret>") are kept, with a count, up to
-- MAX_SHAPES a step. A secret value is never concatenated, compared or saved: it becomes
-- "<type>:<secret>".
--
-- Nothing is borrowed or moved. NodeRadar's scan is turned off for the round (NodeRadar.Set
-- "moveScan", false; owed back in NodeRadarProbeDB.secret.scanOwed until put back) and the owner
-- answers with keys (override bindings on a hidden button, set out of combat, cleared at the end,
-- on a Stop, and after combat when one ends the round in a fight).
--
-- Lines: NodeRadarProbeDB.secret.lines, each "<time> secret: ...", and the /fp console. Never
-- chat. The shapes: NodeRadarProbeDB.secret.steps[<id>].
--------------------------------------------------------------------------------
local ADDON, NS = ...

local Probe = ForeverProbe:Module("NodeRadarProbe", { api = 1, cmd = "nr" })

local ROUND = "secret"
local HOLD = 3                   -- seconds on the icon before a hover step completes itself
local MAX_SHAPES = 20
local MAX_LINES = 3000
local MAX_DEPTH = 4              -- data -> lines -> [i] -> a colour table -> its fields
local MAX_KEYS = 40
local MAX_TALLY = 12
local GRACE = 5                  -- seconds after load before a missing procedure means "ended"
local DEBOUNCE = 0.25
local KEYFRAME = "NodeRadarProbeSecretKeys"

-- The keys: each clicks the hidden button with a mouse button naming the answer.
local BIND = {
    F9 = "LeftButton", NUMPAD1 = "LeftButton",         -- Yes / Done / Run / Next
    F10 = "RightButton", NUMPAD2 = "RightButton",      -- No
    F11 = "MiddleButton", NUMPAD3 = "MiddleButton",    -- Not sure / Skip
}
local ANSWER = { LeftButton = "yes", RightButton = "no", MiddleButton = "unsure" }

-- Steps that sample, by step number.
local S_SETUP, S_NODE, S_NAME, S_REQ, S_CTRL, S_CTRLASK, S_FINISH = 1, 2, 3, 4, 5, 6, 7
local IDS = {
    [S_NODE] = "node-hover", [S_NAME] = "node-name", [S_REQ] = "node-requires",
    [S_CTRL] = "control-hover", [S_CTRLASK] = "control-ask",
}

local function g(name) return rawget(_G, name) end
local function secret(x) return issecretvalue ~= nil and issecretvalue(x) end

local R = { t0 = GetTime(), index = setmetatable({}, { __mode = "k" }) }   -- the round's state
local frame, evf, keyf

--------------------------------------------------------------------------------
-- The saved table and the log
--------------------------------------------------------------------------------
local function db()
    local d = g("NodeRadarProbeDB")
    if type(d) ~= "table" then return nil end
    if type(d.secret) ~= "table" then d.secret = {} end
    return d.secret
end

local function slog(text)
    local line = ("%.2f %s: %s"):format(GetTime(), ROUND, text)
    local d = db()
    if d then
        if type(d.lines) ~= "table" then d.lines = {} end
        d.lines[#d.lines + 1] = line
        while #d.lines > MAX_LINES do table.remove(d.lines, 1) end
    end
    Probe:Say(ROUND .. ": " .. text)
end

local function newBucket()
    return { samples = 0, offMap = 0, hover = 0, tally = {}, shapes = {}, shapesDropped = 0,
             postFired = 0, postShapes = {}, postShapesDropped = 0 }
end
local function bucket(id)
    local d = db()
    if not d then return nil end
    if type(d.steps) ~= "table" then d.steps = {} end
    local b = d.steps[id]
    if type(b) ~= "table" then b = newBucket(); d.steps[id] = b end
    return b
end

-- How many of each outcome; at most MAX_TALLY distinct outcomes a name.
local function tally(b, name, outcome)
    local t = b.tally[name]
    if not t then t = {}; b.tally[name] = t end
    if t[outcome] == nil then
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        if n >= MAX_TALLY then outcome = "other" end
    end
    t[outcome] = (t[outcome] or 0) + 1
end

-- A distinct shape of facts (the signature is its facts joined), counted; capped.
local function addShape(b, key, facts)
    local idx = R.index[b]
    if not idx then idx = { shapes = {}, postShapes = {} }; R.index[b] = idx end
    local sig = table.concat(facts, "\n")
    local s = idx[key][sig]
    if s then s.count = s.count + 1; return "dup" end
    local list = b[key]
    if #list >= MAX_SHAPES then b[key .. "Dropped"] = (b[key .. "Dropped"] or 0) + 1; return "dropped" end
    s = { count = 1, facts = facts, at = GetTime() }
    list[#list + 1] = s
    idx[key][sig] = s
    return "new"
end

--------------------------------------------------------------------------------
-- Describing values without ever touching a secret
--------------------------------------------------------------------------------
local function clean(s)
    s = s:sub(1, 80):gsub("[\r\n]", " "):gsub("|", "||")
    return s
end

-- "<type>:<secret>" for a secret, else the type and the plain value of a string, number or boolean.
local function desc(x)
    if secret(x) then return type(x) .. ":<secret>" end
    local t = type(x)
    if t == "string" then return 'string:"' .. clean(x) .. '"' end
    if t == "number" then return ("number:%.4g"):format(x) end
    if t == "boolean" then return "boolean:" .. tostring(x) end
    if t == "nil" then return "nil" end
    return t
end
-- secret / plain / nil / type:<t>, for the tallies.
local function cls(x)
    if secret(x) then return "secret" end
    local t = type(x)
    if t == "nil" then return "nil" end
    if t == "string" then return "plain" end
    return "type:" .. t
end

-- A function's first answer as text ("absent" when it isn't a function, "threw" when it throws)
-- and the raw first value.
local function fdesc(f, ...)
    if type(f) ~= "function" then return "absent" end
    local ok, a = pcall(f, ...)
    if not ok then return "threw" end
    return desc(a), a
end
local function gdesc(name, ...) return fdesc(g(name), ...) end
local function tdesc(t, name, ...)
    local ok, f = pcall(function() return type(t) == "table" and t[name] or nil end)
    return fdesc(ok and f or nil, ...)
end
local function mfn(obj, m)
    local ok, f = pcall(function() return obj ~= nil and obj[m] or nil end)
    if ok and type(f) == "function" then return f end
end
local function mdesc(obj, m, ...)
    local f = mfn(obj, m)
    if not f then return "absent" end
    return fdesc(f, obj, ...)
end
-- A method's first n answers, each described.
local function mdescN(obj, m, n)
    local f = mfn(obj, m)
    if not f then return "absent" end
    local r = { pcall(f, obj) }
    if not r[1] then return "threw" end
    local out = {}
    for i = 2, n + 1 do out[#out + 1] = desc(r[i]) end
    return table.concat(out, ",")
end

local function keyName(k)
    if secret(k) then return ".<secretkey>" end
    local t = type(k)
    if t == "number" then return "[" .. ("%g"):format(k) .. "]" end
    if t == "string" then return "." .. clean(k) end
    return ".<" .. t .. ">"
end

-- Every key of a table: its value's type, whether secret, the plain value; tables one level
-- deeper (to MAX_DEPTH), in a fixed order. Appends "path=desc" strings to out.
local function walk(t, prefix, depth, out)
    if secret(t) then out[#out + 1] = prefix .. "=table:<secret>"; return end
    local keys = {}
    local ok = pcall(function() for k in pairs(t) do keys[#keys + 1] = k end end)
    if not ok then out[#out + 1] = prefix .. "=<pairs threw>"; return end
    local named = {}
    for i = 1, #keys do named[i] = { name = keyName(keys[i]), key = keys[i] } end
    table.sort(named, function(a, b) return a.name < b.name end)
    if #named == 0 then out[#out + 1] = prefix .. "={}"; return end
    for i, e in ipairs(named) do
        if i > MAX_KEYS then out[#out + 1] = prefix .. "=... " .. (#named - MAX_KEYS) .. " more keys"; break end
        local path = prefix .. e.name
        local okv, val = pcall(function() return t[e.key] end)
        if not okv then
            out[#out + 1] = path .. "=<read threw>"
        elseif secret(val) then
            out[#out + 1] = path .. "=" .. desc(val)
        elseif type(val) == "table" then
            if depth < MAX_DEPTH then walk(val, path, depth + 1, out) else out[#out + 1] = path .. "=table" end
        else
            out[#out + 1] = path .. "=" .. desc(val)
        end
    end
end

local function nrAddon() local n = g("NodeRadar"); if type(n) == "table" then return n end end

--------------------------------------------------------------------------------
-- Which step of ours is running
--------------------------------------------------------------------------------
local function stepAt()
    local FP = g("ForeverProbe")
    local S = type(FP) == "table" and FP.Steps
    if type(S) ~= "table" or type(S.Active) ~= "function" then return nil end
    local ok, proc, rec = pcall(S.Active)
    if ok and type(proc) == "table" and proc.module == Probe and proc.name == ROUND and type(rec) == "table" then
        return rec.at, proc
    end
end

--------------------------------------------------------------------------------
-- One sample: everything an addon can ask about the hover, as facts
--------------------------------------------------------------------------------
local function inCombat() local ok, c = pcall(InCombatLockdown); return ok and c == true end

local function collect(b)
    local F = {}
    local function add(k, val) F[#F + 1] = k .. "=" .. val end

    -- The read.
    local okR, data = pcall(function() return g("C_TooltipInfo").GetMinimapMouseover() end)
    local readClass
    if not okR then readClass = "threw"
    elseif secret(data) then readClass = "secret"
    elseif data == nil then readClass = "nil"
    elseif type(data) ~= "table" then readClass = "type:" .. type(data)
    else readClass = "table" end
    add("read", readClass)
    tally(b, "read", readClass)
    if readClass == "table" then
        walk(data, "data", 1, F)
        local okL, lines = pcall(function() return data.lines end)
        if okL and not secret(lines) and type(lines) == "table" then
            tally(b, "data.#lines", tostring(#lines))
            local line1 = lines[1]
            if not secret(line1) and type(line1) == "table" then
                tally(b, "data.lines[1].leftText", cls(line1.leftText))
                tally(b, "data.lines[1].rightText", cls(line1.rightText))
            end
        else
            tally(b, "data.#lines", okL and cls(lines) or "threw")
        end
        add("hasanysecretvalues(data)", (gdesc("hasanysecretvalues", data)))
    end

    -- Global secrecy state.
    add("C_Secrets.HasSecretRestrictions", (tdesc(g("C_Secrets"), "HasSecretRestrictions")))
    add("canaccesssecrets", (gdesc("canaccesssecrets")))

    -- GameTooltip itself.
    local gt = g("GameTooltip")
    add("GameTooltip:IsShown", (mdesc(gt, "IsShown")))
    local okO, owner = pcall(function() return gt:GetOwner() end)
    local od = (not okO and "threw") or (secret(owner) and "<secret>") or (owner == nil and "nil")
        or (rawequal(owner, g("Minimap")) and "Minimap" or "other")
    add("GameTooltip:GetOwner==Minimap", od)
    tally(b, "gtt.owner", od)
    local nd, n = mdesc(gt, "NumLines")
    add("GameTooltip:NumLines", nd)
    add("GameTooltip:HasSecretValues", (mdesc(gt, "HasSecretValues")))
    add("GameTooltip:IsPreventingSecretValues", (mdesc(gt, "IsPreventingSecretValues")))
    if not secret(n) and type(n) == "number" then
        for i = 1, math.min(n, 8) do
            local L, Rt = g("GameTooltipTextLeft" .. i), g("GameTooltipTextRight" .. i)
            local ld, lraw = mdesc(L, "GetText")
            add("gtt.left" .. i, ld)
            if i == 1 then tally(b, "gtt.left1.text", cls(lraw)) end
            add("gtt.left" .. i .. ".color", mdescN(L, "GetTextColor", 4))
            add("gtt.left" .. i .. ".HasSecretValues", (mdesc(L, "HasSecretValues")))
            add("gtt.left" .. i .. ".HasAnySecretAspect", (mdesc(L, "HasAnySecretAspect")))
            local rd = mdesc(Rt, "GetText")
            add("gtt.right" .. i, rd)
            add("gtt.right" .. i .. ".HasSecretValues", (mdesc(Rt, "HasSecretValues")))
        end
    end
    local okT, td = pcall(function() return gt:GetTooltipData() end)
    if not okT then add("GameTooltip:GetTooltipData", mfn(gt, "GetTooltipData") and "threw" or "absent")
    elseif type(td) == "table" and not secret(td) then walk(td, "gtt.data", 1, F)
    else add("GameTooltip:GetTooltipData", desc(td)) end

    -- NodeRadar's scan.
    local nr = nrAddon()
    local ms = nr and nr.MoveScan
    add("scan.on", ms and type(ms.On) == "function" and (select(2, pcall(ms.On)) == true and "true" or "false") or "absent")
    return F
end

-- The top mouse focus: the frame and its name.
local function topFocus()
    local f = g("GetMouseFoci")
    if type(f) ~= "function" then return nil, "missing" end
    local ok, t = pcall(f)
    if not ok or secret(t) or type(t) ~= "table" then return nil, "unreadable" end
    local top = t[1]
    if top == nil then return nil, "none" end
    local okN, name = pcall(function() return top:GetDebugName() end)
    return top, (okN and not secret(name) and type(name) == "string") and name or "?"
end

local function sample(id, dt)
    local b = bucket(id)
    if not b then return end
    local top, name = topFocus()
    if top == nil or not rawequal(top, g("Minimap")) then
        b.offMap = b.offMap + 1
        tally(b, "top focus off the map", name)
        return
    end
    b.samples = b.samples + 1
    b.hover = b.hover + (dt or 0)
    addShape(b, "shapes", collect(b))
end

--------------------------------------------------------------------------------
-- The post-call (registered at load): what a MinimapMouseover tooltip's processors receive
--------------------------------------------------------------------------------
local function onPost(tooltip, data)
    local ok, err = pcall(function()
        R.postSeen = (R.postSeen or 0) + 1
        local at = stepAt()
        local id = at and IDS[at]
        local b = id and bucket(id)
        if not b then return end
        b.postFired = b.postFired + 1
        local F = {}
        F[#F + 1] = "tooltip==GameTooltip=" .. tostring(rawequal(tooltip, g("GameTooltip")))
        if secret(data) then F[#F + 1] = "data=<secret>"
        elseif type(data) ~= "table" then F[#F + 1] = "data=" .. desc(data)
        else
            walk(data, "post.data", 1, F)
            local okL, lines = pcall(function() return data.lines end)
            local line1 = okL and not secret(lines) and type(lines) == "table" and lines[1]
            if line1 and not secret(line1) and type(line1) == "table" then
                tally(b, "post.data.lines[1].leftText", cls(line1.leftText))
            else
                tally(b, "post.data.lines[1].leftText", "no line")
            end
        end
        local ld, lraw = mdesc(g("GameTooltipTextLeft1"), "GetText")
        F[#F + 1] = "post.gtt.left1=" .. ld
        tally(b, "post.gtt.left1.text", cls(lraw))
        addShape(b, "postShapes", F)
    end)
    if not ok then R.postErr = tostring(err) end
end
do
    local proc = g("TooltipDataProcessor")
    local enum = g("Enum")
    local types = type(enum) == "table" and enum.TooltipDataType
    local kind = type(types) == "table" and type(types.MinimapMouseover) == "number" and types.MinimapMouseover or 21
    R.postKind = kind
    if type(proc) == "table" and type(proc.AddTooltipPostCall) == "function" then
        R.postRegistered = pcall(proc.AddTooltipPostCall, kind, onPost)
    end
end

--------------------------------------------------------------------------------
-- The keys: override bindings on a hidden button, never left behind
--------------------------------------------------------------------------------
local lastKey = -9
local function act(which)
    local FP = g("ForeverProbe")
    local S = type(FP) == "table" and FP.Steps
    local at, proc = stepAt()
    if not (type(S) == "table" and at and proc) then return end
    local step = proc.steps[at]
    if type(step) ~= "table" then return end
    if step.ask then
        if which == "yes" then S.Answer(true) elseif which == "no" then S.Answer(false) else S.Unsure() end
    elseif which == "yes" then
        if step.run then S.Run() elseif step.wait or step.event then S.DoneByHand() else S.Next() end
    elseif which == "unsure" then
        S.Skip()
    end
end

local function keyFrame()
    if not keyf then
        keyf = CreateFrame("Button", KEYFRAME, UIParent)
        keyf:Hide()
        keyf:RegisterForClicks("AnyUp", "AnyDown")
        keyf:SetScript("OnClick", function(_, button)
            local now = GetTime()
            if now - lastKey < DEBOUNCE then return end
            lastKey = now
            local which = ANSWER[button]
            if which then
                local ok, err = pcall(act, which)
                if not ok then slog("ERROR in a key: " .. tostring(err)) end
            end
        end)
    end
    return keyf
end

-- Binds the keys. Returns ok, text.
local function bind()
    if R.bound then return true, "already bound" end
    local f = g("SetOverrideBindingClick")
    if type(f) ~= "function" then return false, "SetOverrideBindingClick is missing" end
    if inCombat() then return false, "in combat" end
    local kf = keyFrame()
    local bad = {}
    for key, button in pairs(BIND) do
        local ok = pcall(f, kf, true, key, KEYFRAME, button)
        if not ok then bad[#bad + 1] = key end
    end
    R.bound = true
    return #bad == 0, #bad == 0 and "bound" or ("not bound: " .. table.concat(bad, ","))
end

-- Clears them; in combat it stays pending and the driver retries.
local function unbind()
    if not R.bound then return true end
    if inCombat() then R.unbindPending = true; return false end
    local f = g("ClearOverrideBindings")
    if type(f) == "function" and keyf and pcall(f, keyf) then
        R.bound, R.unbindPending = false, nil
        return true
    end
    R.unbindPending = true
    return false
end

--------------------------------------------------------------------------------
-- NodeRadar's scan: off for the round, owed back
--------------------------------------------------------------------------------
local function pauseScan()
    local n = nrAddon()
    local d = db()
    if not (n and type(n.db) == "table" and type(n.Set) == "function" and d) then return "NodeRadar not loaded" end
    if n.db.moveScan == true then
        d.scanOwed = true
        local ok, err = pcall(n.Set, "moveScan", false)
        if not ok then return "could not turn it off: " .. tostring(err) end
        return "turned off for the round"
    end
    return d.scanOwed and "already off by this round" or "was already off"
end
local function restoreScan()
    local d = db()
    if not (d and d.scanOwed) then return end
    local n = nrAddon()
    if n and type(n.db) == "table" and type(n.Set) == "function" then
        if n.db.moveScan ~= true then pcall(n.Set, "moveScan", true) end
        d.scanOwed = nil
        slog("NodeRadar's scan put back on")
    end
end

local function cleanup(why)
    local was = R.bound
    unbind()
    restoreScan()
    if was and not R.bound then slog("keys cleared (" .. tostring(why) .. ")") end
    R.active = nil
end
local function pending()
    local d = db()
    return R.bound or (d and d.scanOwed) or false
end

--------------------------------------------------------------------------------
-- The driver
--------------------------------------------------------------------------------
local function drive0(dt)
    local at = stepAt()
    if not at then
        -- The procedure is not running (a Stop, the end, or not resumed yet).
        if R.active or (GetTime() - R.t0 > GRACE and pending()) then cleanup("the procedure is not running") end
        if R.unbindPending then unbind() end
        if not pending() and frame then frame:SetScript("OnUpdate", nil) end
        return
    end
    if at >= S_NODE and not R.active then R.active = true end
    if R.active and not R.bound then bind() end
    local id = IDS[at]
    if id then sample(id, dt) end
end

local lastErr
local function drive(_, dt)
    local ok, err = pcall(drive0, dt)
    if not ok and err ~= lastErr then lastErr = err; slog("ERROR in the driver: " .. tostring(err)) end
end

local function ensure()
    if not frame then frame = CreateFrame("Frame") end
    if frame:GetScript("OnUpdate") ~= drive then frame:SetScript("OnUpdate", drive) end
    if not evf then
        evf = CreateFrame("Frame")
        evf:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_LOGIN" then R.t0 = GetTime(); ensure() end
        end)
        Probe:RegisterEvents(evf, { "PLAYER_LOGIN" })
    end
end
ensure()

--------------------------------------------------------------------------------
-- The steps
--------------------------------------------------------------------------------
local function tallyText(b, name)
    local t = b.tally[name]
    if not t then return "none" end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. " " .. t[k] end
    return table.concat(parts, ", ")
end

local function summaryOf(id)
    local d = db()
    local b = d and d.steps and d.steps[id]
    if not b then return id .. ": no data" end
    return ("%s: %d map frames (%d off the map, %.1f s on it), %d shapes; read %s; data.lines[1].leftText %s; GameTooltipTextLeft1 %s; owner %s; post-call fired %d, its leftText %s")
        :format(id, b.samples, b.offMap, b.hover, #b.shapes, tallyText(b, "read"), tallyText(b, "data.lines[1].leftText"),
                tallyText(b, "gtt.left1.text"), tallyText(b, "gtt.owner"), b.postFired, tallyText(b, "post.data.lines[1].leftText"))
end

local function setup()
    ensure()
    if inCombat() then R.setupOK = false; slog("setup refused: in combat"); return false, "in combat: press Back, then Start again out of combat" end
    local d = db()
    if not d then R.setupOK = false; return false, "NodeRadarProbeDB is not there" end
    d.steps = {}
    R.index = setmetatable({}, { __mode = "k" })
    local _, build = GetBuildInfo()
    local nr = nrAddon()
    local meta = C_AddOns and C_AddOns.GetAddOnMetadata
    local okV, ver = pcall(meta or function() return nil end, "NodeRadar", "Version")
    d.build, d.date = tostring(build), date("%Y-%m-%d %H:%M:%S")
    d.nrVersion = okV and type(ver) == "string" and ver or "?"
    d.tooltipSkill = nr and nr.db and nr.db.tooltipSkill
    d.scanWasOn = nr and nr.db and nr.db.moveScan == true
    d.postRegistered, d.postKind = R.postRegistered == true, R.postKind
    local paused = pauseScan()
    R.active = true
    local ok, keys = bind()
    local bursting = nr and nr.MoveScan and type(nr.MoveScan.Bursting) == "function" and select(2, pcall(nr.MoveScan.Bursting)) == true
    R.setupOK = ok and not bursting
    slog(("setup: build %s, NodeRadar %s, tooltipSkill %s, scan was %s (%s), keys %s, post-call %s (type %s)%s"):format(
        d.build, d.nrVersion, tostring(d.tooltipSkill), d.scanWasOn and "on" or "off", paused, keys,
        d.postRegistered and "registered" or "NOT registered", tostring(d.postKind), bursting and "; a scan burst is still running: Back, Start again" or ""))
    return R.setupOK, ("scan %s; keys %s"):format(paused, keys)
end

local function hoverWait(id)
    return function()
        ensure()
        local d = db()
        local b = d and d.steps and d.steps[id]
        local t = b and b.hover or 0
        if t >= HOLD then return true, ("%.1f s on the minimap"):format(t) end
        return false, ("%.1f of %d s with the mouse on the minimap"):format(t, HOLD)
    end
end

local function finish()
    ensure()
    local d = db()
    for _, id in ipairs({ "node-hover", "node-name", "node-requires", "control-hover", "control-ask" }) do
        slog("summary " .. summaryOf(id))
    end
    slog(("summary: post-call registered %s, fired %d times in the session, error %s"):format(
        tostring(R.postRegistered == true), R.postSeen or 0, tostring(R.postErr)))
    if d then d.finished = date("%Y-%m-%d %H:%M:%S") end
    cleanup("finished")
    return not pending(), pending() and "keys or scan still owed (combat?): retried by itself" or "keys cleared, scan restored"
end

Probe:Steps(ROUND, {
    rev = 1,
    title = "What a hover on the minimap still reads (secret values, 70938)",
    { text = "SETUP. Stand still, out of combat, outdoors, with a herb or ore dot in view on the minimap (the small yellow dot of your gathering tracking). "
          .. "Press Start (or F9): it turns NodeRadar's minimap scan off for this round so nothing moves your minimap, binds three keys so you never need the mouse, "
          .. "and records the build. THE KEYS for every step: F9 (or Numpad 1) = Yes / Done / Next; F10 (or Numpad 2) = No; F11 (or Numpad 3) = Not sure / Skip. "
          .. "If the check says FAIL, press Back and Start again.",
      button = "Start", run = setup,
      check = function() return R.setupOK == true, R.setupOK and "set up" or "setup failed (see the log)" end },
    { text = "REAL HOVER ON THE NODE. Move the mouse onto the small yellow herb or ore dot on the minimap (the minimap where it normally sits) and keep the mouse completely still on it. "
          .. "A tooltip should appear beside the cursor. WATCH that tooltip: (1) does its first line name the node, for example 'Peacebloom' or 'Copper Vein'? "
          .. "(2) is there a second line under the name starting 'Requires Herbalism' or 'Requires Mining' with a number in brackets? "
          .. "(3) or is the tooltip empty, blank, or not shown at all? This step finishes by itself after 3 s on the dot. Then do NOT move the mouse: "
          .. "answer the next questions with the keys (F9 yes, F10 no, F11 not sure). If nothing happens for 20 s, F9 ends this step by hand.",
      wait = hoverWait("node-hover"), timeout = 180 },
    { text = "Mouse still on the dot. Does the tooltip's FIRST line show the node's name as readable text (e.g. 'Peacebloom')? F9 = yes, F10 = no (blank, garbled or no tooltip), F11 = not sure.",
      ask = true },
    { text = "Mouse still on the dot. Is there a SECOND line under the name reading 'Requires Herbalism (N)' or 'Requires Mining (N)'? F9 = yes, F10 = no, F11 = not sure.",
      ask = true },
    { text = "CONTROL, skippable. Move the mouse onto a DIFFERENT kind of icon on the minimap: a quest-giver '!' or '?', a quest-area circle, or a party member's dot, and keep the mouse still on it. "
          .. "WATCH its tooltip: is the first line readable text (a name), or blank or missing? This step finishes by itself after 3 s on the icon. "
          .. "If there is no such icon in view, press F11 now (Skip) and press F11 again on the next question. F9 ends this step by hand.",
      wait = hoverWait("control-hover"), timeout = 180 },
    { text = "Control icon, mouse still on it. Does its tooltip show readable text (a name)? F9 = yes, readable; F10 = no, blank or missing; F11 = not sure, or there was no such icon in view.",
      ask = true },
    { text = "FINISH. You can move the mouse now. Press Finish (or F9): NodeRadar's scan goes back on if it was on, the three keys are cleared, and a summary line per step goes to the /fp console. Nothing goes to chat.",
      button = "Finish", run = finish,
      check = function() return not pending(), pending() and "keys or scan still owed" or "everything put back" end },
})

NS._secret = { state = function() return R end, walk = walk, desc = desc, collect = collect, addShape = addShape,
               bucket = bucket, pending = pending, MAX_SHAPES = MAX_SHAPES }
