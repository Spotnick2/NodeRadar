-- Learn.lua: which names are gathering nodes (docs/PLAN.md, "Which names are
-- nodes"). A node is a name that vanishes when its gathering tracking goes off
-- (round 3, #7), learned once per name: from gathering casts, and from the
-- toggle experiment. The shipped library (Data/Nodes.lua) is a head start.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Scan = NR.Scan
local Learn = {}
NR.Learn = Learn

-- The gathering tracking spells (Blizzard_Minimap/Mainline/Minimap.lua:36-39).
Learn.TRACKING = { [2383] = "herbs", [8387] = "herbs", [2580] = "ore", [8388] = "ore" }
-- Herb Gathering and Mining (round 3 measured 2366); other ranks by these names.
Learn.CASTS = { [2366] = "herbs", [2575] = "ore" }

Learn.MIDDLE = 1.5     -- seconds from tracking off to the middle sweep
Learn.AFTER = 2.5      -- seconds from tracking back on to the after sweep
Learn.RETRY = 0.5      -- seconds between restore attempts
Learn.GAP = 10         -- seconds between experiments
Learn.GIVE_UP = 10     -- seconds after the first restore attempt before saying so in chat
Learn.ATTEMPTS = 3     -- experiments per unknown name per session

Learn.tested = {}      -- [name] = { [kind] = true }: the toggles a name survived, this session
Learn.attempts = {}    -- [name] = experiments tried this session
Learn.loading = false

local exp              -- the running experiment, or a restore after a reload
local lastExp = -math.huge

--------------------------------------------------------------------------------
-- What's known
--------------------------------------------------------------------------------

local function mine(create)
    local l = GetLocale()
    if create and not NR.db.learned[l] then NR.db.learned[l] = {} end
    return NR.db.learned[l]
end

-- "herbs", "ore", false (not a node) or nil (unknown).
function Learn.Kind(name)
    local m = mine()
    local e = m and m[name]
    if e ~= nil then return e.kind end
    local lib = NR.LIBRARY and NR.LIBRARY[GetLocale()]
    return lib and lib[name] or nil
end

-- Gathering is the strongest evidence: it overrides a toggle's answer, and a
-- toggle never overrides it.
function Learn.Record(name, kind, source)
    local m = mine(true)
    local e = m[name]
    if e and e.source == "gather" and source ~= "gather" then return false end
    m[name] = { kind = kind, source = source, build = select(2, GetBuildInfo()) }
    Learn.tested[name], Learn.attempts[name] = nil, nil
    return true
end

-- Names saved before Scan.Plain (release check, 70450) carry escape codes
-- ("|T…|tPeacebloom", "For Honor|cffffffff"): cleaned once, at login. A clash
-- with the clean name keeps the gathered one, else the one already clean.
function Learn.CleanNames()
    for _, names in pairs(NR.db.learned) do
        local dirty = {}
        for name in pairs(names) do
            if type(name) == "string" and name:find("|", 1, true) then dirty[#dirty + 1] = name end
        end
        for _, name in ipairs(dirty) do
            local e, clean = names[name], Scan.Plain(name)
            names[name] = nil
            local cur = names[clean]
            if clean ~= "" and (cur == nil or (e.source == "gather" and cur.source ~= "gather")) then
                names[clean] = e
            end
        end
    end
end

function Learn.Forget(name)
    local m = mine()
    if m then m[name] = nil end
    Learn.tested[name], Learn.attempts[name] = nil, nil
end

--------------------------------------------------------------------------------
-- From gathering: UNIT_SPELLCAST_SENT's target is the node's name (round 3)
--------------------------------------------------------------------------------

local castNames
local function spellName(id)
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    local n = ok and type(info) == "table" and info.name or nil
    if type(n) == "string" and not API.IsSecret(n) and n ~= "" then return n end
end

local function castKind(spellID)
    if Learn.CASTS[spellID] then return Learn.CASTS[spellID] end
    if not castNames then
        castNames = {}
        for id, kind in pairs(Learn.CASTS) do
            local n = spellName(id)
            if n then castNames[n] = kind end
        end
    end
    local n = spellName(spellID)
    return n and castNames[n] or nil
end

function Learn.OnCastSent(unit, target, _, spellID)
    if unit ~= "player" or API.IsSecret(spellID) or type(spellID) ~= "number" then return end
    if API.IsSecret(target) or type(target) ~= "string" or target == "" then return end
    local kind = castKind(spellID)
    if kind then Learn.Record(target, kind, "gather") end
end

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

-- The gathering trackings: { index, spellID, kind, active }.
function Learn.Trackings()
    local list = {}
    for i = 1, C_Minimap.GetNumTrackingTypes() do
        local info = C_Minimap.GetTrackingInfo(i)
        local spell = info and API.Num(info.spellID)
        local kind = spell and Learn.TRACKING[spell]
        if kind then list[#list + 1] = { index = i, spellID = spell, kind = kind, active = API.Yes(info.active) } end
    end
    return list
end

function Learn.AnyOn()
    for _, t in ipairs(Learn.Trackings()) do if t.active then return true end end
    return false
end

local function find(spellID)
    for _, t in ipairs(Learn.Trackings()) do if t.spellID == spellID then return t end end
end

-- Every tracking's state, to tell a change of the player's from ours.
local function states()
    local s = {}
    for i = 1, C_Minimap.GetNumTrackingTypes() do
        local info = C_Minimap.GetTrackingInfo(i)
        s[i] = info ~= nil and API.Yes(info.active)
    end
    return s
end

local function cooling(spellID)
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    return not ok or type(info) ~= "table" or info.isActive == true   -- unreadable: don't start
end

-- Our change seen, by the tick or the event, whichever comes first. Seeing our
-- restore moves straight to "after", so a later off is the player's in any
-- order of events and frames (Codex on #9).
local function acknowledge(index, on)
    exp.awaiting = nil
    exp.states[index] = on
    if on and exp.phase == "restore" then exp.phase, exp.onAt = "after", GetTime() end
end

-- Our change, awaited until its state is seen (exp.awaiting); any other change
-- of that tracking is the player's (Codex on #9: no time window).
local function setTracking(index, on)
    exp.awaiting = on
    local ok, err = pcall(C_Minimap.SetTracking, index, on)
    if not ok then API.Fail("SetTracking " .. tostring(on), err) end
    return ok
end

--------------------------------------------------------------------------------
-- The toggle experiment
--------------------------------------------------------------------------------

function Learn.Busy() return exp ~= nil end

local function void(reason)
    if exp and not exp.void then exp.void = reason end
end
Learn.Void = void

local function finish(now)
    exp = nil
    lastExp = now
end

local function canRestore()
    return not InCombatLockdown() and not API.Casting() and not API.Dead() and not Learn.loading
end

local function canStart(now)
    return NR.db.learn and not exp and now - lastExp >= Learn.GAP and not InCombatLockdown()
        and not API.Casting() and not API.Dead() and API.Speed() == 0 and not Learn.loading
        and not API.Gamepad()
end

-- After a radar sweep: start an experiment for the first unknown name, when
-- everything allows it. `before` is that sweep.
function Learn.Consider(before, now)
    if not canStart(now) then return end
    local active = {}
    for _, t in ipairs(Learn.Trackings()) do if t.active then active[#active + 1] = t end end
    if #active == 0 then return end
    for _, blip in ipairs(before.blips) do
        local name = blip.name
        if Learn.Kind(name) == nil and (Learn.attempts[name] or 0) < Learn.ATTEMPTS then
            local survived = Learn.tested[name] or {}
            for _, t in ipairs(active) do
                if not survived[t.kind] and not cooling(t.spellID) then
                    Learn.attempts[name] = (Learn.attempts[name] or 0) + 1
                    local kinds = {}
                    for _, a in ipairs(active) do kinds[a.kind] = true end
                    exp = { spellID = t.spellID, kind = t.kind, kinds = kinds, before = before, phase = "middle",
                            due = now + Learn.MIDDLE, states = states(), geometry = before.geometry }
                    -- Saved before the call: a reload in between must still restore it.
                    NR.charDb.pendingRestore = t.spellID
                    if not setTracking(t.index, false) then void("SetTracking off failed") end
                    return true
                end
            end
        end
    end
end

-- At login and after every loading screen: this character's pending restore.
function Learn.Resume(now)
    if exp or not NR.charDb.pendingRestore then return end
    exp = { spellID = NR.charDb.pendingRestore, restoreOnly = true, phase = "restore", restoreSince = now,
            void = "restore after a reload", states = states() }
end

local function changed(r)
    local a, b = exp.geometry, r.geometry
    return math.abs(a.w - b.w) > 0.5 or math.abs(a.h - b.h) > 0.5 or math.abs(a.es - b.es) > 0.001
end

local function diagnostic(label)
    if exp.void then return nil end
    if API.Gamepad() then void("the gamepad came on"); return nil end
    local r, why = Scan.Sweep()
    if not r then void(label .. " sweep failed: " .. tostring(why)); return nil end
    if changed(r) then void("the map changed"); return nil end
    return r
end

-- A name is that kind when it was there before, gone in the middle and back
-- after; false when every blip of it stayed through the toggle of every
-- gathering tracking that was on; anything else stays unknown.
local function verdict(e)
    for name, blips in pairs(e.before.byName) do
        if Learn.Kind(name) == nil then
            local middle, after = Scan.Count(e.middle, name), Scan.Count(e.after, name)
            if middle == 0 and after > 0 then
                Learn.Record(name, e.kind, "toggle")
            elseif middle == #blips then
                local survived = Learn.tested[name] or {}
                Learn.tested[name] = survived
                survived[e.kind] = true
                local all = true
                for kind in pairs(e.kinds) do if not survived[kind] then all = false end end
                if all then Learn.Record(name, false, "toggle") end
            end
        end
    end
end

-- Every frame while an experiment or a restore runs.
function Learn.Tick(now)
    if not exp then return end
    if not exp.restoreOnly then
        local speed = API.Speed()
        if speed == nil or speed > 0 then void("the player moved") end
    end
    local t = find(exp.spellID)
    if t and exp.awaiting ~= nil and t.active == exp.awaiting then acknowledge(t.index, t.active) end
    if exp.phase == "middle" and now >= exp.due then
        if t and t.active then void("tracking didn't go off") else exp.middle = diagnostic("middle") end
        exp.phase, exp.restoreSince = "restore", now
    end
    if exp.phase == "restore" then
        if not t then
            NR.charDb.pendingRestore = nil   -- the character no longer has that tracking
            finish(now)
            return
        end
        if t.active then
            exp.phase, exp.onAt = "after", now
        elseif canRestore() and (not exp.lastTry or now - exp.lastTry >= Learn.RETRY) then
            exp.lastTry, exp.firstTry = now, exp.firstTry or now
            setTracking(t.index, true)
        end
        if exp.phase == "restore" and exp.firstTry and not exp.warned and now - exp.firstTry >= Learn.GIVE_UP then
            exp.warned = true
            API.Say(("turned %s off to learn a node and couldn't turn it back on: please turn it on.")
                :format(spellName(exp.spellID) or "gathering tracking"))
        end
    elseif exp.phase == "after" then
        if not (t and t.active) then
            -- It was on (seen) and went off: the player's, theirs to keep off.
            void("the player changed tracking")
            NR.charDb.pendingRestore = nil
            finish(now)
        elseif now - exp.onAt >= Learn.AFTER then
            NR.charDb.pendingRestore = nil
            if not exp.restoreOnly then
                exp.after = diagnostic("after")
                if not exp.void then verdict(exp) end
            end
            finish(now)
        end
    end
end

-- MINIMAP_UPDATE_TRACKING: a change we didn't make voids the experiment, and
-- the player's choice wins (Codex).
function Learn.OnTrackingChanged()
    if not exp then return end
    local current = states()
    local t = find(exp.spellID)
    for i, on in pairs(current) do
        local ours = t ~= nil and t.index == i
        if exp.states[i] ~= on then
            if ours and exp.awaiting ~= nil and on == exp.awaiting then
                acknowledge(i, on)                     -- our own change, seen
            else
                -- The player's. If they turned ours off after it was back on, the
                -- next tick ends the experiment without restoring it.
                void("the player changed tracking")
            end
        end
    end
    exp.states = current
end
