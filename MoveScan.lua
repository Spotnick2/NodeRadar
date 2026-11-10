-- MoveScan.lua: the minimap scan (#91), opt-in, from client build 70862.
--
-- From 70862 the minimap's mouseover follows only the real cursor (docs/FOREVER-PROBE.md,
-- "70862: the mouseover can't be pointed"), so NodeRadar moves `Minimap` itself under the
-- resting cursor for a few frames, invisible, reads what lies there and puts it back.
-- docs/PLAN.md, "The minimap scan mode (#91)", has every rule; the measurements are in
-- docs/FOREVER-PROBE.md ("Reading by moving the minimap", "The scan's last round").
--
-- A burst, one frame each (the plan's schedule):
--   1. borrow + prepare: admission, Glass MiniMap's ScanBegin, the home saved; alpha 0,
--      clicks and wheel off, clamp off, icon scale 0.01, Blizzard's coordinates and LFG eye
--      hidden, off screen, the read's size;
--   2. place: the map's centre under the cursor, UpdateBlips;
--   3. settle (after a resize the first frame reads nothing, measured);
--   4. read, then restore: geometry first, visibility and input only once it reads back;
--   5. settle: the tooltip suppression one more frame, everything read back.
-- An invalid or interrupted read is never evidence that nothing is there.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local MS = {}
NR.MoveScan = MS

MS.PRESENCE_PX = 15.4   -- screen px: one read lists every node in range (measured 12.8 to 18)
MS.QUIET = 0.2          -- seconds the cursor rests before a burst
MS.STILL_PX = 2         -- screen px it may drift and still be resting
MS.RELEASE = 0.3        -- seconds after a mouse button comes up
MS.BUDGET = 0.25        -- seconds a burst may take, checked every frame
MS.RETRY = 2            -- seconds between retries of a restore left pending
MS.FOLLOWERS_EVERY = 10 -- seconds between searches for frames anchored to the map
MS.STILL_FACTOR = 3     -- standing still, a burst every scanEvery x 3 seconds, at most MAX_EVERY
MS.MAX_EVERY = 10
MS.SOONER = 1           -- a burst asked for sooner never comes closer than this to the last
MS.REFUSALS = 3         -- Glass MiniMap's refusals in a row before the scan turns itself off
MS.PLACE_TOL = 1        -- the cursor's offset from the map's centre, in home-map units
MS.OFF = -2000          -- off screen, in the map's own units

local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
                 FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }

local gen = 0           -- every burst's number; a cancelled one's later frames do nothing
local burst             -- the burst under way, or nil
local saved             -- what the borrow changed, to put back; kept while anything is pending
local pending           -- a restore that couldn't finish: "geometry" or "visibility"
local suppress = false  -- Blizzard's minimap tooltip hidden by the post-hook
local halted            -- why the scan turned itself off this session, or nil
local glassOwed = false -- one ScanEnd owed after any ScanBegin
local glassRefusals = 0
local said = {}         -- one chat line per session per key
local ourScale = false  -- our own SetIconScale calls, ignored by the hook
local lastScale         -- the last icon scale another addon set
local nextAt = 0        -- the next burst is due
local lastBurst = -math.huge
local lastRetry = -math.huge
local lastDown = -math.huge
local cursorX, cursorY, quietSince
local looking, moving = false, false
local followers = { at = -math.huge }
local quickAt = {}                    -- when the quick locate bursts of the last QUICK_WINDOW started
local firstLook = nil                 -- { at, tries }: a first look owed (login, a new area, turned on)
local holdUntil = -math.huge          -- no burst before this (MS.Hold: a sonar playing on the map)
local lastTick, frameDt = nil, 0      -- the frame time (the burst budget's margin)
local waited, waitedSince = {}, nil   -- why no burst, by reason, since the last one (/nr scan log)
local lookEnded                       -- when mouselook last ended (the trace)
-- After mouselook or a click, the minimap's hover answers nothing until the mouse has moved
-- (in game: empty reads 0.5 s after mouselook, and four in a row standing still after a click).
local movedSince = true
local prevX, prevY                    -- the cursor last frame
local settleUntil = -math.huge        -- the cursor's jump as mouselook ends is no move
MS.LOOK_SETTLE = 0.1

MS.stats = { bursts = 0, valid = 0, unread = 0, windows = 0 }

local function rg(name) return rawget(_G, name) end

local function say(key, msg)
    if said[key] then return end
    said[key] = true
    API.Say(msg)
end

-- A method's answer, or nil when it's missing, throws or answers a secret.
local function ask(obj, method, ...)
    local f = obj and obj[method]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, obj, ...)
    if not ok or API.IsSecret(v) then return nil end
    return v
end

local function setOn(obj, method, ...)
    local f = obj and obj[method]
    if type(f) ~= "function" then return false end
    return (pcall(f, obj, ...))
end

local function cursor()
    local ok, x, y = pcall(GetCursorPosition)
    if not ok then return nil end
    return API.Num(x), API.Num(y)
end

--------------------------------------------------------------------------------
-- The icon scale has no getter: the last value another addon set (a hook from load),
-- else 1. A skin that set one before NodeRadar loaded can't be seen (a stated limit).
--------------------------------------------------------------------------------

if type(Minimap.SetIconScale) == "function" then
    hooksecurefunc(Minimap, "SetIconScale", function(_, scale)
        if not ourScale and API.Num(scale) then lastScale = scale end
    end)
end

local function iconScale(v)
    ourScale = true
    local ok = setOn(Minimap, "SetIconScale", v)
    ourScale = false
    return ok
end

--------------------------------------------------------------------------------
-- Blizzard's tooltip: entering the map installs Minimap_OnUpdate, which shows the names at the
-- cursor every frame. Hidden right after its producer while a burst runs, through the settle.
--------------------------------------------------------------------------------

local tipHooked = false
function MS.HookTooltip()
    local tt = rg("GameTooltip")
    if tipHooked or type(tt) ~= "table" or type(tt.SetMinimapMouseover) ~= "function" then return tipHooked end
    tipHooked = pcall(hooksecurefunc, tt, "SetMinimapMouseover", function(self)
        if suppress then pcall(self.Hide, self) end
    end)
    return tipHooked
end
MS.HookTooltip()

function MS.Suppressing() return suppress end

--------------------------------------------------------------------------------
-- Glass MiniMap (GlassMiniMap#56, PUBLIC_API_VERSION 1): its frames stay home during a
-- scan only after ScanBegin returned true. Not loaded: nothing to ask. Loaded without
-- version 1 (every release before #56): its ring would follow the map, so no scan.
--------------------------------------------------------------------------------

function MS.Glass()
    local addons = rg("C_AddOns")
    local f = addons and addons.IsAddOnLoaded
    local ok, loaded = false, nil
    if type(f) == "function" then ok, loaded = pcall(f, "GlassMiniMap") end
    if not (ok and loaded == true) then return "none" end
    local g = rg("GlassMiniMap")
    if type(g) == "table" and rawget(g, "PUBLIC_API_VERSION") == 1 and type(rawget(g, "ScanBegin")) == "function"
        and type(rawget(g, "ScanEnd")) == "function" then
        return "v1", g
    end
    return "old"
end

local function glassEnd()
    if not glassOwed then return end
    glassOwed = false
    local _, g = MS.Glass()
    local f = g and rawget(g, "ScanEnd")
    if type(f) ~= "function" then return end
    local ok, err = pcall(f, "NodeRadar")
    if not ok then API.Fail("GlassMiniMap.ScanEnd", err) end
end

--------------------------------------------------------------------------------
-- Followers: a shown frame outside the map's tree but anchored into it travels with the
-- borrowed map without taking its alpha. Never touched (the contract): found, and the scan
-- waits while one shows, naming it once. Searched every FOLLOWERS_EVERY seconds, not per
-- frame. Blizzard's coordinates and LFG eye are the two the borrow hides itself.
--------------------------------------------------------------------------------

local function coords()
    local cluster = rg("MinimapCluster")
    local box = type(cluster) == "table" and rawget(cluster, "MinimapContainer")
    local c = type(box) == "table" and rawget(box, "PlayerCoords")
    return type(c) == "table" and c or nil
end

local function inside(f)
    for _ = 1, 12 do
        if f == Minimap then return true end
        local p = ask(f, "GetParent")
        if not p then return false end
        f = p
    end
    return false
end

local function anchoredIn(f, memo, depth)
    if memo[f] ~= nil then return memo[f] end
    memo[f] = false
    if depth > 6 then return false end
    local n = API.Num(ask(f, "GetNumPoints")) or 0
    for i = 1, n do
        local ok, _, rel = pcall(f.GetPoint, f, i)
        if ok and type(rel) == "table" and not API.IsSecret(rel) and (inside(rel) or anchoredIn(rel, memo, depth + 1)) then
            memo[f] = true
            return true
        end
    end
    return false
end

local function shows(f)
    if ask(f, "IsVisible") ~= true then return false end
    local a = API.Num(ask(f, "GetEffectiveAlpha"))
    return a == nil or a > 0
end

function MS.FindFollower()
    local memo, seen = {}, { [Minimap] = true }
    local own = coords()
    if own then seen[own] = true end
    local eye = rg("QueueStatusButton")
    if type(eye) == "table" then seen[eye] = true end
    local found
    local function look(parent, depth)
        local ok, kids = pcall(function() return { parent:GetChildren() } end)
        if not ok then return end
        for _, f in ipairs(kids) do
            if found then return end
            if not seen[f] then
                seen[f] = true
                if not inside(f) then
                    if shows(f) and anchoredIn(f, memo, 0) then
                        found = f
                    elseif depth < 3 then
                        look(f, depth + 1)
                    end
                end
            end
        end
    end
    look(UIParent, 1)
    local cluster = rg("MinimapCluster")
    if not found and type(cluster) == "table" then look(cluster, 1) end
    return found
end

local function follower(now)
    if now - followers.at >= MS.FOLLOWERS_EVERY then
        local ok, f = pcall(MS.FindFollower)
        followers.frame, followers.at = ok and f or nil, now
    end
    local f = followers.frame
    if f and shows(f) then return f end
    return nil
end

--------------------------------------------------------------------------------
-- The home: what the borrow changes, saved before the first change.
--------------------------------------------------------------------------------

local function points()
    local n = API.Num(ask(Minimap, "GetNumPoints"))
    if not n then return nil end
    local list = {}
    for i = 1, n do
        local ok, p, rel, rp, x, y = pcall(Minimap.GetPoint, Minimap, i)
        if not ok or API.IsSecret(p) or API.IsSecret(rel) or API.IsSecret(rp) or API.IsSecret(x) or API.IsSecret(y) then
            return nil
        end
        list[i] = { p, rel, rp, x, y }
    end
    return list
end

local function same(a, b) return a == b or (API.Num(a) and API.Num(b) and math.abs(a - b) < 0.01) end

local function samePoints(a, b)
    if not (a and b) or #a ~= #b then return false end
    for i, p in ipairs(a) do
        local q = b[i]
        if not (p[1] == q[1] and p[2] == q[2] and p[3] == q[3] and same(p[4], q[4]) and same(p[5], q[5])) then
            return false
        end
    end
    return true
end

-- A Blizzard frame anchored to the map, hidden for the borrow: its alpha and mouse.
local function holdFrame(f)
    if type(f) ~= "table" then return nil end
    local alpha = API.Num(ask(f, "GetAlpha"))
    if not alpha then return nil end
    return { f = f, alpha = alpha, mouse = ask(f, "IsMouseEnabled") }
end

local function home()
    local s = {
        points = points(),
        w = API.Num(ask(Minimap, "GetWidth")), h = API.Num(ask(Minimap, "GetHeight")),
        es = API.Num(ask(Minimap, "GetEffectiveScale")),
        alpha = API.Num(ask(Minimap, "GetAlpha")),
        clamp = ask(Minimap, "IsClampedToScreen"),
        click = ask(Minimap, "IsMouseClickEnabled"),
        wheel = ask(Minimap, "IsMouseWheelEnabled"),
    }
    if not (s.points and #s.points > 0 and s.w and s.h and s.es and s.alpha and s.w > 0 and s.es > 0)
        or type(s.clamp) ~= "boolean" or type(s.click) ~= "boolean" or type(s.wheel) ~= "boolean" then
        return nil
    end
    local eye = rg("QueueStatusButton")
    s.held = {}
    for _, f in ipairs({ coords(), type(eye) == "table" and eye or nil }) do
        local h = holdFrame(f)
        if h then s.held[#s.held + 1] = h end
    end
    return s
end

--------------------------------------------------------------------------------
-- The restore: geometry first (anchors, size, clamp), read back; then visibility and input,
-- only once the geometry is home: a map that can't go home stays invisible and click-off.
-- The icon scale moves nothing: at once. Every call in its own pcall. Idempotent.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- The minimap's quest-area tracking (Enum.MinimapTrackingFilter.QuestPOIs): off during a borrow.
--------------------------------------------------------------------------------

local QUEST_POIS = 65536
do
    local enum = rg("Enum")
    local f = type(enum) == "table" and rawget(enum, "MinimapTrackingFilter")
    if type(f) == "table" and API.Num(rawget(f, "QuestPOIs")) then QUEST_POIS = f.QuestPOIs end
end

local function questIndex()
    local get = C_Minimap.GetTrackingFilter
    if type(get) ~= "function" then return nil end
    local okN, n = pcall(C_Minimap.GetNumTrackingTypes)
    n = okN and API.Num(n) or 0
    for i = 1, n do
        local ok, filter = pcall(get, i)
        if ok and type(filter) == "table" and not API.IsSecret(filter) and filter.filterID == QUEST_POIS then return i end
    end
end

local function questActive(i)
    local ok, info = pcall(C_Minimap.GetTrackingInfo, i)
    if not ok or type(info) ~= "table" or API.IsSecret(info) then return nil end
    return API.Yes(info.active)
end

-- false: turn them off for a borrow, if on; returns whether we did (and owe them back).
-- true: back on; returns whether they read on.
function MS.QuestAreas(on)
    local i = questIndex()
    if not i then return on end
    if not on then
        if questActive(i) ~= true then return false end
        if NR.db then NR.db.questOff = true end           -- before: a crash mid-scan still puts it back
        pcall(C_Minimap.SetTracking, i, false)
        return true
    end
    pcall(C_Minimap.SetTracking, i, true)
    if questActive(i) == true then
        if NR.db then NR.db.questOff = nil end
        return true
    end
    return false
end

-- Whether the quest areas read off now (true when there's no such tracking).
function MS.QuestAreasOff()
    local i = questIndex()
    return not i or questActive(i) == false
end

-- At login and after a loading screen: a scan cut short (a crash, a logout) put back.
local lastQuestTry = -math.huge       -- declared before both its users (Codex, PR #102)
function MS.QuestAreasBack()
    if burst or saved or not (NR.db and NR.db.questOff) then return end
    lastQuestTry = GetTime()
    if MS.QuestAreas(true) then API.Trace("scan: the quest areas a cut-short scan turned off are back on") end
end

local function gatheringKey()
    local parts = {}
    for _, t in ipairs(NR.Learn.Trackings()) do parts[#parts + 1] = t.spellID .. (t.active and "+" or "-") end
    return table.concat(parts, ",")
end
local lastGathering

local function halt(why)
    if not halted then
        halted = why
        API.Fail("scan", why)
        API.Say("the minimap scan turned itself off for this session: " .. why .. ". /nr scan turns it on again.")
    end
end

local function geometryHome(s)
    return samePoints(points(), s.points) and same(ask(Minimap, "GetWidth"), s.w)
        and same(ask(Minimap, "GetHeight"), s.h) and ask(Minimap, "IsClampedToScreen") == s.clamp
end

local function visibilityHome(s)
    if not (same(ask(Minimap, "GetAlpha"), s.alpha) and ask(Minimap, "IsMouseClickEnabled") == s.click
        and ask(Minimap, "IsMouseWheelEnabled") == s.wheel) then
        return false
    end
    for _, h in ipairs(s.held) do
        if not same(ask(h.f, "GetAlpha"), h.alpha) then return false end
        if h.mouse ~= nil and ask(h.f, "IsMouseEnabled") ~= h.mouse then return false end
    end
    return true
end

-- `keep`: the snapshot stays for the settle frame's readback (Codex, PR #101), released only
-- once everything reads back there.
local function restore(keep)
    local s = saved
    if not s then return true end
    if s.scaled and iconScale(lastScale or 1) then s.scaled = false end   -- kept until the setter works
    if not geometryHome(s) then
        -- Invisible and inert again first: a correction after the visibility came back (the
        -- settle frame's readback) must never leave a shown, clickable map away from home
        -- if it fails (Codex, PR #101).
        setOn(Minimap, "SetAlpha", 0)
        for _, h in ipairs(s.held) do
            setOn(h.f, "SetAlpha", 0)
            if h.mouse ~= nil then setOn(h.f, "EnableMouse", false) end
        end
        setOn(Minimap, "SetMouseClickEnabled", false)
        setOn(Minimap, "EnableMouseWheel", false)
        -- The quest areas ignore alpha and mask: off again too (Codex, PR #102).
        if not s.quest then s.quest = MS.QuestAreas(false) end
        setOn(Minimap, "ClearAllPoints")
        for _, p in ipairs(s.points) do setOn(Minimap, "SetPoint", p[1], p[2], p[3], p[4], p[5]) end
        setOn(Minimap, "SetSize", s.w, s.h)
        setOn(Minimap, "SetClampedToScreen", s.clamp)
    end
    if not geometryHome(s) then
        pending = "geometry"
        glassEnd()
        halt("the minimap couldn't be put back yet; retried until it can")
        return false
    end
    -- The geometry is home: the quest areas back on now, never while the map is away.
    if s.quest and MS.QuestAreas(true) then s.quest = nil end
    setOn(Minimap, "SetAlpha", s.alpha)
    for _, h in ipairs(s.held) do
        setOn(h.f, "SetAlpha", h.alpha)
        if h.mouse ~= nil then setOn(h.f, "EnableMouse", h.mouse) end
    end
    setOn(Minimap, "EnableMouseWheel", s.wheel)
    setOn(Minimap, "SetMouseClickEnabled", s.click)       -- last
    glassEnd()
    if not visibilityHome(s) then
        pending = "visibility"
        halt("the minimap's visibility or input couldn't be put back yet; retried until it can")
        return false
    end
    if s.scaled then
        pending = "icon scale"
        halt("the minimap's dots couldn't be put back to their size yet; retried until they can")
        return false
    end
    if s.quest then
        pending = "quest areas"
        halt("the minimap's quest areas couldn't be turned back on yet; retried until they can")
        return false
    end
    pending = nil
    if not keep then saved = nil end
    return true
end

-- What's left of a restore that couldn't finish: tried again now. Never dropped.
function MS.Retry()
    if not saved then return true end
    lastRetry = GetTime()
    return restore()
end

function MS.Pending() return pending end

--------------------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------------------

local function editMode()
    local em = rg("EditModeManagerFrame")
    return ask(em, "IsEditModeActive") == true
end

local function inCombat()
    local ok, c = pcall(UnitAffectingCombat, "player")
    return InCombatLockdown() or (ok and API.Yes(c))
end

local function menuOpen()
    local menu = rg("Menu")
    local get = type(menu) == "table" and rawget(menu, "GetManager")
    if type(get) ~= "function" then return false end
    local ok, mgr = pcall(get)
    return ok and ask(mgr, "IsAnyMenuOpen") == true
end

local function buttonDown()
    local ok, down = pcall(IsMouseButtonDown)
    return ok and down == true
end

local function mouselooking()
    local ok, on = pcall(IsMouselooking)
    return ok and on == true
end

local function topFocus()
    local ok, foci = pcall(GetMouseFoci)
    if not ok or type(foci) ~= "table" then return nil end
    return foci[1]
end

-- A frame drawn below the map (a UI suite's full-screen layer): the borrowed map is above it.
local function below(f)
    local theirs, mine = STRATA[ask(f, "GetFrameStrata")], STRATA[ask(Minimap, "GetFrameStrata")]
    if not (theirs and mine) then return false end
    if theirs ~= mine then return theirs < mine end
    local a, b = API.Num(ask(f, "GetFrameLevel")), API.Num(ask(Minimap, "GetFrameLevel"))
    return a ~= nil and b ~= nil and a < b
end

local function overWorld(f)
    return f ~= nil and (f == rg("WorldFrame") or (f ~= Minimap and not inside(f) and below(f)))
end

local function tooltipShown()
    local tt = rg("GameTooltip")
    return ask(tt, "IsShown") == true
end

local function eyeShown()
    local eye = rg("QueueStatusButton")
    return type(eye) == "table" and ask(eye, "IsVisible") == true
end

local function instanced()
    local ok, inside1 = pcall(IsInInstance)
    return not ok or API.IsSecret(inside1) or inside1 == true
end

-- The scan's context: what a burst's read is about. Anything changing cancels it.
local function context()
    local okR, r = pcall(C_Minimap.GetViewRadius)
    return { zoom = API.Num(ask(Minimap, "GetZoom")), radius = okR and API.Num(r) or nil,
             es = API.Num(ask(Minimap, "GetEffectiveScale")) }
end

local function sameContext(a, b)
    return a and b and a.zoom == b.zoom and a.radius == b.radius and same(a.es, b.es)
end

function MS.On()
    local db = NR.db
    return db ~= nil and db.enabled == true and db.moveScan == true and API.Blind() and not halted
end

-- Why no burst may start now, or nil.
function MS.Refusal(now)
    if not MS.On() then return "off" end
    if saved or pending then return "a restore is pending" end
    if inCombat() then return "in combat" end
    if ask(Minimap, "IsProtected") == true then return "the minimap is protected" end
    if API.Gamepad() then return "the gamepad UI" end
    if editMode() then return "Edit Mode" end
    if NR.Learn.loading then return "loading" end
    if API.Dead() then return "dead" end
    local okT, taxi = pcall(UnitOnTaxi, "player")
    if okT and API.Yes(taxi) then return "on a taxi" end
    if instanced() then return "in an instance" end
    if ask(Minimap, "IsVisible") ~= true then return "the minimap is hidden" end
    if ask(Minimap, "IsMouseMotionEnabled") == false then return "the minimap's mouse motion is off" end
    if not NR.Learn.AnyOn() then return "no gathering tracking on" end
    if mouselooking() then return "mouselook" end
    if buttonDown() then return "a mouse button is down" end
    if now - lastDown < MS.RELEASE then return "a mouse button was just released" end
    if not movedSince then return "the mouse hasn't moved since a click or mouselook" end
    if not overWorld(topFocus()) then return "the cursor is not over the world" end
    if not (quietSince and now - quietSince >= MS.QUIET) then return "the cursor is moving" end
    local x, y = cursor()
    local es = API.Num(ask(Minimap, "GetEffectiveScale"))
    local okR, l, b, w, h = pcall(Minimap.GetRect, Minimap)
    if not (x and es and okR and API.Num(l) and API.Num(b) and API.Num(w) and API.Num(h)) then
        return "the minimap's place is unreadable"
    end
    if x / es >= l and x / es <= l + w and y / es >= b and y / es <= b + h then return "the cursor is over the minimap" end
    if tooltipShown() then return "a tooltip is shown" end
    if menuOpen() then return "a menu is open" end
    local f = follower(now)
    if f then
        say("follower", "the minimap scan waits: a frame anchored to the minimap would follow it to your mouse ("
            .. tostring(ask(f, "GetDebugName") or "unnamed") .. ").")
        return "a frame follows the minimap"
    end
    local glass = MS.Glass()
    if glass == "old" then
        say("glass", "the minimap scan needs Glass MiniMap 1.1.0 or later (an older one's ring would follow the minimap to your mouse).")
        return "Glass MiniMap needs updating"
    end
    return nil
end

-- Why the burst under way must end now, or nil. `phase`: "off" (off screen) or "placed".
local function interrupted(b, now)
    if not MS.On() then return "turned off" end
    if inCombat() then return "combat" end
    if editMode() then return "Edit Mode" end
    if NR.Learn.loading then return "loading" end
    if API.Gamepad() then return "the gamepad UI" end
    if mouselooking() then return "mouselook" end
    if buttonDown() then return "a mouse button" end
    if now - b.t0 > MS.BUDGET then return "over budget" end
    if not sameContext(b.context, context()) then return "the map changed" end
    local x, y = cursor()
    if not (x and y) or math.abs(x - b.x) > MS.STILL_PX or math.abs(y - b.y) > MS.STILL_PX then return "the cursor moved" end
    if tooltipShown() then return "a tooltip" end
    if menuOpen() then return "a menu" end
    if not b.eye and eyeShown() then return "the LFG eye" end
    local top = topFocus()
    if b.phase == "placed" then
        if top ~= Minimap and not (b.frame <= b.placedAt + 1) then return "covered" end
    elseif not overWorld(top) then
        return "covered"
    end
    return nil
end

--------------------------------------------------------------------------------
-- A burst
--------------------------------------------------------------------------------

local function finish(b, reason)
    if burst ~= b then return end
    b.reason = reason
    -- A window placed but not read (interrupted): back in Locate's queue.
    if b.cur and b.cur.kind == "window" and not b.cur.read and NR.Locate then NR.Locate.Unread(b.cur) end
    restore(true)
    if NR.ScanFace then NR.ScanFace.End() end            -- held over the returned map, then faded
    pcall(Minimap.UpdateBlips, Minimap)
    b.phase = "settle"
    -- A node still being located: the next burst soon (the plan's locate bursts, LOCATE_GAP
    -- apart), so its sonar and compass follow the sound by a second or two, not a few looks.
    -- At most LOCATE_RUN of them in any QUICK_WINDOW (the owner: three new nodes blinked a long
    -- while); then the usual cadence, until the allowance comes back (MS.Tick: in game a search
    -- left unfinished by its run went on at one window every 6 s for half a minute).
    local busy = NR.Locate and NR.Locate.Busy()
    if NR.Locate then NR.Locate.TakeFresh() end
    local quick = busy and MS.QuickLeft(GetTime()) > 0
    local soon = quick and MS.LOCATE_GAP or MS.Every()
    -- A first look that didn't read (in game the first burst after every reload ran over budget
    -- on a 275 ms loading frame, then waited the 6 s cadence): tried again soon, a few times.
    if firstLook then
        if b.observation then
            firstLook = nil
        elseif firstLook.tries < MS.FIRST_TRIES and GetTime() - firstLook.at < MS.FIRST_WINDOW then
            firstLook.tries = firstLook.tries + 1
            soon = math.min(soon, MS.FIRST_RETRY)
        else
            firstLook = nil
        end
    end
    lastBurst, nextAt = GetTime(), GetTime() + soon
    MS.TraceBurst(b, GetTime(), quick, soon)
end

-- A first look owed (login, a new area, the scan turned on): the next burst at once, and one
-- that doesn't read is tried again after FIRST_RETRY, FIRST_TRIES times within FIRST_WINDOW.
MS.FIRST_RETRY = 1
MS.FIRST_TRIES = 3
MS.FIRST_WINDOW = 10
function MS.WantFirst(now)
    firstLook = { at = now, tries = 0 }
    nextAt = math.min(nextAt, now)
end

-- No burst for `seconds` (Alert.Sonar: the rings are drawn on the minimap, and a burst hides and
-- moves it; in game the next quick burst, 0.3 s on, cut every located node's sonar short).
MS.SONAR_HOLD = 1.5
function MS.Hold(seconds)
    holdUntil = math.max(holdUntil, GetTime() + seconds)
end

-- Quick locate bursts left in the rolling allowance (LOCATE_RUN a QUICK_WINDOW, every name's).
function MS.QuickLeft(now)
    while quickAt[1] and now - quickAt[1] >= MS.QUICK_WINDOW do table.remove(quickAt, 1) end
    return MS.LOCATE_RUN - #quickAt
end

-- One line a burst (Codex, PR #102: one-window bursts in game, the cause unmeasured): how long
-- the map was away and in how many frames, the slowest of them, the client's frame rate (30 is
-- the background cap, maxFPSBk), what ended it, whether its presence read held, its windows,
-- why no further window was placed, and when the next burst is due.
function MS.TraceBurst(b, now, quick, soon)
    local okF, fps = pcall(GetFramerate)
    fps = okF and API.Num(fps)
    API.Trace(("scan: burst %d ms, %d frames (slowest %d ms), %s fps; %s; presence %s; %d window%s%s; next in %.1f s%s"):format(
        (now - b.t0) * 1000, b.frame, (b.dtMax or 0) * 1000, fps and ("%.0f"):format(fps) or "?",
        tostring(b.reason), b.observation and "read" or "not read",
        MS.stats.windows - (b.w0 or MS.stats.windows), MS.stats.windows - (b.w0 or MS.stats.windows) == 1 and "" or "s",
        b.stop and (", then " .. b.stop) or "", soon, quick and " (locating)" or "")
        .. (NR.Locate and ("; queued %d search, %d re-check"):format(NR.Locate.Queued()) or ""))
end

-- Seconds between bursts: scanEvery moving, three times that standing still.
function MS.Every()
    local every = API.Num(NR.db and NR.db.scanEvery) or 2
    if moving then return every end
    return math.min(MS.MAX_EVERY, every * MS.STILL_FACTOR)
end

local function borrow(now)
    local glass, g = MS.Glass()
    if glass == "v1" then
        local ok, acquired = pcall(rawget(g, "ScanBegin"), "NodeRadar")
        glassOwed = true
        if not (ok and acquired == true) then
            glassEnd()
            glassRefusals = glassRefusals + 1
            if not ok then API.Fail("GlassMiniMap.ScanBegin", acquired) end
            API.Trace("scan: Glass MiniMap refused the borrow")
            if glassRefusals >= MS.REFUSALS then halt("Glass MiniMap refused it " .. MS.REFUSALS .. " times") end
            lastBurst, nextAt = now, now + MS.Every()
            return nil
        end
        glassRefusals = 0
    end
    local s = home()
    if not s then
        glassEnd()
        API.Fail("scan", "the minimap's home is unreadable")
        lastBurst, nextAt = now, now + MS.Every()
        return nil
    end
    local x, y = cursor()
    gen = gen + 1
    local b = { gen = gen, t0 = now, frame = 1, x = x, y = y, phase = "off", context = context(),
                es = s.es, homeW = s.w, eye = eyeShown(), placements = 0, w0 = MS.stats.windows }
    b.cur = { units = MS.PRESENCE_PX / s.es, ox = 0, oy = 0, kind = "presence" }
    saved, burst, suppress = s, b, true
    MS.stats.bursts = MS.stats.bursts + 1
    -- The stand-in at the home first, read while the map is still there (#103).
    if NR.ScanFace then NR.ScanFace.Begin(glass, g) end
    -- Invisible and inert before it moves.
    setOn(Minimap, "SetAlpha", 0)
    for _, h in ipairs(s.held) do
        setOn(h.f, "SetAlpha", 0)
        if h.mouse ~= nil then setOn(h.f, "EnableMouse", false) end
    end
    setOn(Minimap, "SetMouseClickEnabled", false)
    setOn(Minimap, "EnableMouseWheel", false)
    setOn(Minimap, "SetClampedToScreen", false)
    s.scaled = iconScale(0.01)
    -- The quest areas the minimap draws ignore its alpha and its mask: at a locate window's size
    -- they flash across the screen (the owner's screenshots). Their tracking off for the borrow,
    -- the only tracking the scan touches (the owner, 2026-11-09), saved first so a scan cut short
    -- still puts it back (at login, after a loading screen).
    s.quest = MS.QuestAreas(false)
    setOn(Minimap, "ClearAllPoints")
    setOn(Minimap, "SetPoint", "CENTER", UIParent, "BOTTOMLEFT", MS.OFF, MS.OFF)
    setOn(Minimap, "SetSize", b.cur.units, b.cur.units)
    b.resized = true
    return b
end

-- The player in UnitPosition's frame (north, west), for a placement's context.
local function playerPos()
    local ok, n, w = pcall(UnitPosition, "player")
    n, w = ok and API.Num(n), ok and API.Num(w)
    if n and w then return n, w end
end

-- Put placement p's map point (ox, oy: map units from the map's centre, at its own size)
-- under the cursor. A new size needs the settle frame (measured): the read at +2, else +1.
local function place(b, p)
    if not b.resized and not same(ask(Minimap, "GetWidth"), p.units) then
        setOn(Minimap, "SetSize", p.units, p.units)
        b.resized = true
    end
    b.wait = b.resized and 2 or 1
    b.resized = false
    setOn(Minimap, "ClearAllPoints")
    setOn(Minimap, "SetPoint", "CENTER", UIParent, "BOTTOMLEFT", b.x / b.es - p.ox, b.y / b.es - p.oy)
    b.cur, b.placedAt, b.phase, b.rereads = p, b.frame, "placed", 0
    b.placements = b.placements + 1
    p.pn, p.pw = playerPos()
    b.blipsOK = pcall(Minimap.UpdateBlips, Minimap)
end

-- The names a read lists, or nil and why (unread: nil, no lines, malformed or secret).
-- A valid read always has lines (the player at the centre, measured).
function MS.ReadNames()
    local ok, data = pcall(C_TooltipInfo.GetMinimapMouseover)
    if not ok then return nil, "the read failed" end
    if data == nil then return nil, "nothing" end
    if API.IsSecret(data) or type(data) ~= "table" then return nil, "secret" end
    local lines = data.lines
    if API.IsSecret(lines) or type(lines) ~= "table" then return nil, "secret" end
    if #lines == 0 then
        MS.emptyType = data.type                         -- for the trace (#91: empty reads in game)
        return nil, "no lines"
    end
    local names = {}
    for _, line in ipairs(lines) do
        local t = type(line) == "table" and line.leftText or nil
        if API.IsSecret(t) then return nil, "secret" end
        if type(t) == "string" then
            for row in t:gmatch("[^\n]+") do
                local name = NR.Scan.Plain(row)
                if name ~= "" then names[#names + 1] = name end
            end
        end
    end
    return names
end

-- Why this frame's read can't count, or nil.
local function invalid(b)
    local p = b.cur
    if b.frame < b.placedAt + b.wait then return "unsettled" end
    if topFocus() ~= Minimap then return "not the top focus" end
    if not b.blipsOK then return "UpdateBlips failed" end
    local cx, cy = Minimap:GetCenter()
    local w = API.Num(ask(Minimap, "GetWidth"))
    cx, cy = API.Num(cx), API.Num(cy)
    local h = API.Num(ask(Minimap, "GetHeight"))
    if not (cx and cy and w and h and w > 0) then return "the placement is unreadable" end
    -- The read's size, really (a refused or overridden resize reads a normal map's centre only).
    if math.abs(w - p.units) > 0.01 or math.abs(h - p.units) > 0.01 then return "not the read's size" end
    local k = b.homeW / w
    if math.abs((b.x / b.es - cx - p.ox) * k) > MS.PLACE_TOL or math.abs((b.y / b.es - cy - p.oy) * k) > MS.PLACE_TOL then
        return "the map is not where it was put"
    end
    return nil
end

-- Node names' counts in a read's names.
local function countsOf(names)
    local counts = {}
    for _, name in ipairs(names) do
        if NR.Learn.Kind(name) then counts[name] = (counts[name] or 0) + 1 end
    end
    return counts
end

-- Returns true when the read is final; false: read again next frame (an empty read, at most
-- MS.REREADS times, within the budget: 5 of 16 in the owner's run came back with no lines).
MS.REREADS = 2
local function read(b, now)
    local why = invalid(b)
    local names
    if not why then names, why = MS.ReadNames() end
    -- An empty read is read again next frame: the presence read up to REREADS times (an
    -- empty one there is a failed read), a window once before its empty answer counts as no
    -- node (Codex, PR #102: one frame's answer is a thin basis for dropping a record).
    if not names and why == "no lines" and (b.rereads or 0) < (b.cur.kind == "presence" and MS.REREADS or 1) then
        b.rereads = (b.rereads or 0) + 1
        return false
    end
    if b.cur.kind ~= "presence" then
        -- A locate window: an empty answer is no node there. The presence read always lists
        -- the player (the cursor on its arrow), so an empty one there is a failed read; a window
        -- off to the side has nothing else to list (in game 266 of 267 re-checks of gone veins
        -- came back with no lines and were kept as ghosts). An invalid read is tried again.
        b.cur.read = true
        MS.stats.windows = MS.stats.windows + 1
        local w = b.cur.window
        local listed = {}
        for name in pairs(names and countsOf(names) or {}) do listed[#listed + 1] = name end
        API.Trace(("locate: window %.0f yd%s at %.0f,%.0f from you: %s"):format(w.size, w.record and " (re-check)" or "",
            b.cur.ox * (2 * (b.cur.radius or 0) / b.cur.units), b.cur.oy * (2 * (b.cur.radius or 0) / b.cur.units),
            names and (#listed > 0 and table.concat(listed, ", ") or "no node")
                or (why == "no lines" and "no node (no lines)" or ("unread: " .. tostring(why)))))
        if names or why == "no lines" then                -- nil was never measured as a valid empty: unread
            local pn, pw = playerPos()
            if NR.Locate then NR.Locate.Read(b.cur, names and countsOf(names) or {}, pn, pw, now) end
        elseif NR.Locate then
            NR.Locate.Unread(b.cur)
        end
        return true
    end
    if not names then
        b.cur.read = true
        MS.stats.unread = MS.stats.unread + 1
        MS.lastUnread = why
        if why == "no lines" then
            -- What differs about an empty read (in game, 4 in a row standing still): the map's
            -- size and place against the cursor, the hover, the frames since placement.
            local x, y = cursor()
            local cx, cy = Minimap:GetCenter()
            cx, cy = API.Num(cx), API.Num(cy)
            local w = API.Num(ask(Minimap, "GetWidth"))
            API.Trace(("scan: unread (no lines): type %s, frame +%d, %d rereads, size %s/%s, cursor %s from the centre, mouse over %s, mouselook ended %s s ago"):format(
                tostring(MS.emptyType), b.frame - b.placedAt, b.rereads or 0, w and ("%.2f"):format(w) or "?",
                ("%.2f"):format(b.cur.units), (x and cx) and ("%.2f,%.2f"):format(x / b.es - cx, y / b.es - cy) or "?",
                tostring(ask(Minimap, "IsMouseOver")), lookEnded and ("%.1f"):format(now - lookEnded) or "never"))
        else
            API.Trace("scan: unread (" .. tostring(why) .. ")")
        end
        return true
    end
    MS.stats.valid = MS.stats.valid + 1
    local counts = countsOf(names)
    b.cur.read = true
    b.observation = { counts = counts, at = now, gen = b.gen }
    if NR.Locate then NR.Locate.Presence(counts, now) end
    MS.lastCounts = counts                               -- /nr status
    local seen = {}
    for name, n in pairs(counts) do seen[#seen + 1] = name .. " x" .. n end
    table.sort(seen)
    API.Trace("scan: read " .. (#seen > 0 and table.concat(seen, ", ") or "no node"))
    return true
end

-- The next placement of this burst, if there's room: Locate's windows, up to MS.PLACEMENTS a
-- burst and while the budget allows another (a margin for its settle frame).
MS.PLACEMENTS = 8
MS.LOCATE_GAP = 0.3     -- seconds between bursts while Locate has windows open
MS.LOCATE_RUN = 8       -- such quick bursts at most in any QUICK_WINDOW (about 3 s of blinking)
MS.QUICK_WINDOW = 20    -- seconds (Codex, PR #102: a run that didn't finish its search comes back)
MS.MARGIN = 0.06
local function nextPlacement(b, now)
    -- Room for a resized placement's three frames at the current frame rate (Codex, PR #102:
    -- a fixed margin at a low frame rate admitted placements that timed out unread).
    local margin = math.max(MS.MARGIN, 3 * frameDt)
    if not NR.Locate then return nil end
    if b.placements >= MS.PLACEMENTS then b.stop = "the placement limit"; return nil end
    if now - b.t0 > MS.BUDGET - margin then
        b.stop = ("the budget (%d ms in, margin %d ms)"):format((now - b.t0) * 1000, margin * 1000)
        return nil
    end
    -- The locate windows are large maps, where the quest areas' outlines would show: only once
    -- their tracking reads off (Codex, PR #102: a refused or thrown toggle went unchecked).
    if saved and saved.quest and not MS.QuestAreasOff() then
        API.Trace("scan: the quest areas didn't turn off: no locate window this burst")
        b.stop = "the quest areas on"
        return nil
    end
    local okR, radius = pcall(C_Minimap.GetViewRadius)
    radius = okR and API.Num(radius)
    local pn, pw = playerPos()
    if not (radius and pn) then b.stop = "no map geometry"; return nil end
    local p = NR.Locate.Next(pn, pw, radius, b.es)
    if not p then b.stop = "no window due" end
    return p
end

local function stepBurst(b, now)
    b.frame = b.frame + 1
    if b.phase ~= "settle" and frameDt > (b.dtMax or 0) then b.dtMax = frameDt end
    if b.phase == "settle" then
        -- The frame after the restore: the suppression ends, everything is read back.
        suppress, burst = false, nil
        pcall(Minimap.UpdateBlips, Minimap)
        if saved then restore() end
        if b.observation and b.gen ~= gen then API.Trace("scan: the read was cancelled (gen " .. b.gen .. " vs " .. gen .. ")") end
        if b.observation and b.gen == gen and NR.Observe then NR.Observe("presence", b.observation, now) end
        -- The consumers after every burst that read (Share's heartbeat and retries, the
        -- compass's choice as the player moves; Codex, PR #102), or when the records changed.
        if NR.Locate and NR.Located then
            local changed, new = NR.Locate.Take()
            if changed or (b.observation and b.gen == gen) then NR.Located(new, now) end
        end
        return
    end
    local why = interrupted(b, now)
    if why then return finish(b, why) end
    if b.phase == "off" then return place(b, b.cur) end
    if b.frame >= b.placedAt + b.wait then
        if read(b, now) == false then return end
        -- A failed presence read ends the burst: its windows' empty answers would prove nothing
        -- and could drop live records (Codex, PR #102).
        if b.cur.kind == "presence" and not b.observation then return finish(b, "the presence read failed") end
        local p = nextPlacement(b, now)
        if p then return place(b, p) end
        return finish(b, "done")
    end
end

-- Stop at once: whatever is borrowed goes home (the setting off, combat, a loading screen).
function MS.Stop(reason)
    local b = burst
    if b and NR.Locate then NR.Locate.Cancel() end       -- the settle frame's too (Codex, PR #102)
    if b and b.phase ~= "settle" then finish(b, reason or "stopped") end
    if burst then
        suppress, burst = false, nil
        if saved then restore() end
    end
    gen = gen + 1
end

-- A cancel: a read under way is dropped (a tracking, zone or zoom change, a gather).
function MS.Cancel() gen = gen + 1 end

--------------------------------------------------------------------------------
-- The driver: one frame, every frame while the scan is on or a restore is pending.
--------------------------------------------------------------------------------

function MS.Tick(now)
    if lastTick then frameDt = math.min(0.5, math.max(0, now - lastTick)) end
    lastTick = now
    if pending and not burst and now - lastRetry >= MS.RETRY then MS.Retry() end
    -- A saved quest-area obligation (a scan cut short) retried on its own, scan on or not
    -- (Codex, PR #102: a refused restore at login waited for the next loading screen).
    if NR.db and NR.db.questOff and not (burst or saved) and now - lastQuestTry >= MS.RETRY then MS.QuestAreasBack() end
    if not (MS.On() or burst) then return end
    local x, y = cursor()
    local look = mouselooking()
    if looking and not look then settleUntil = now + MS.LOOK_SETTLE end
    if x and y then
        -- A real move only: frame to frame, outside mouselook and the jump as it ends (the
        -- cursor reappears where it was: in game that jump passed for a move, and every read
        -- after it was empty).
        if prevX and not look and now >= settleUntil and (x ~= prevX or y ~= prevY) then movedSince = true end
        prevX, prevY = x, y
        if not cursorX or math.abs(x - cursorX) > MS.STILL_PX or math.abs(y - cursorY) > MS.STILL_PX then
            quietSince, cursorX, cursorY = now, x, y
        end
    end
    if buttonDown() then lastDown, movedSince = now, false end
    -- The end of mouselook or a stop after moving asks for a burst sooner.
    local speed = API.Speed()
    local move = speed ~= nil and speed > 0
    if looking and not look then lookEnded = now end
    if look then movedSince = false end
    if (looking and not look) or (moving and not move) then
        nextAt = math.min(nextAt, math.max(now, lastBurst + MS.SOONER))
    end
    looking, moving = look, move
    if burst then return stepBurst(burst, now) end
    local locating = NR.Locate and NR.Locate.Busy()
    if locating and MS.QuickLeft(now) > 0 then
        nextAt = math.min(nextAt, lastBurst + MS.LOCATE_GAP)  -- the allowance back: locating goes on quickly
    else
        nextAt = math.min(nextAt, lastBurst + MS.Every())   -- starting to move: the shorter wait
    end
    if now < nextAt or now < holdUntil then return end
    local why = MS.Refusal(now)
    MS.lastRefusal = why
    if why then
        -- What kept it waiting since the last look, for /nr scan log.
        waited[why] = (waited[why] or 0) + 1
        waitedSince = waitedSince or now
        return
    end
    if waitedSince and now - waitedSince >= 1 then
        local list = {}
        for reason, n in pairs(waited) do list[#list + 1] = { reason, n } end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(3, #list) do parts[i] = ("%s (%d frames)"):format(list[i][1], list[i][2]) end
        API.Trace(("scan: waited %.0f s: %s"):format(now - waitedSince, table.concat(parts, ", ")))
    end
    waited, waitedSince = {}, nil
    -- A quick locate burst (sooner than the cadence) spends the allowance.
    if locating and now - lastBurst < MS.Every() then quickAt[#quickAt + 1] = now end
    borrow(now)
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function() MS.Tick(GetTime()) end)

local events = CreateFrame("Frame")
API.RegisterEvents(events, { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_LEAVING_WORLD",
    "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED", "GLOBAL_MOUSE_DOWN", "MINIMAP_UPDATE_ZOOM",
    "MINIMAP_UPDATE_TRACKING", "ZONE_CHANGED_NEW_AREA", "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED", "PLAYER_LOGIN",
    "PLAYER_LOGOUT" })
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        MS.HookTooltip()
        lastGathering = gatheringKey()
        MS.QuestAreasBack()
    elseif event == "PLAYER_LOGOUT" then
        -- The session's trace, saved (a reload too) while the scan is on: the next look at it
        -- needs no paste. The session before it is kept as scanLogPrevious.
        local db = NR.db
        if db and db.moveScan and API.Blind() and #NR.trace > 0 then
            local build, version = API.Build(), NR.VersionText and NR.VersionText() or "?"
            db.scanLogPrevious = db.scanLog
            db.scanLog = { build = build, version = version, saved = time(), stats = MS.stats, lines = NR.trace }
        end
    elseif event == "PLAYER_REGEN_ENABLED" or event == "LOADING_SCREEN_DISABLED" then
        if pending then MS.Retry() end
        MS.QuestAreasBack()
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        -- Our own quest-area toggle isn't a reason to stop; a gathering tracking change is.
        local key = gatheringKey()
        if key ~= lastGathering then MS.Stop(event) end
        lastGathering = key
    elseif event == "GLOBAL_MOUSE_DOWN" then
        lastDown, movedSince = GetTime(), false
        if burst then MS.Stop("a mouse button") end
    else
        -- Combat, a loading screen, logout: home now (Minimap stays unprotected, so this is
        -- allowed after the lockdown starts); the rest cancels what's under way.
        MS.Stop(event)
        if event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then followers.at = -math.huge end
    end
end)
do
    local er = rg("EventRegistry")
    if type(er) == "table" and type(er.RegisterCallback) == "function" then
        pcall(er.RegisterCallback, er, "EditMode.Enter", function() MS.Stop("Edit Mode") end, MS)
        pcall(er.RegisterCallback, er, "EditMode.Exit", function() if pending then MS.Retry() end end, MS)
    end
end

-- The setting turned on or off (NR.Set): off goes home at once; on starts afresh.
function MS.Apply()
    if NR.db and NR.db.moveScan then
        halted, glassRefusals = nil, 0
        followers.at, nextAt = -math.huge, 0
        MS.WantFirst(GetTime())
    end
    if not MS.On() then MS.Stop("turned off") end
end

MS._test = {
    reset = function()
        gen, burst, saved, pending, suppress, halted, glassOwed, glassRefusals = 0, nil, nil, nil, false, nil, false, 0
        said, nextAt, lastBurst, lastRetry, lastDown = {}, 0, -math.huge, -math.huge, -math.huge
        cursorX, cursorY, quietSince, looking, moving, movedSince = nil, nil, nil, false, false, true
        prevX, prevY, settleUntil = nil, nil, -math.huge
        quickAt, firstLook, holdUntil = {}, nil, -math.huge
        followers = { at = -math.huge }
        MS.stats = { bursts = 0, valid = 0, unread = 0, windows = 0 }
    end,
    burst = function() return burst end,
    saved = function() return saved end,
    lastScale = function() return lastScale end,
}

--------------------------------------------------------------------------------
-- The login prompt: once per account (NodeRadarDB.moveScanAsked), on 70862 or later, at the
-- first quiet moment at least 10 s after entering the world (out of combat, not loading, no
-- gamepad UI). Our own small window, not Blizzard's popups.
--------------------------------------------------------------------------------

MS.ASK_AFTER = 10
local askAt, prompt

local function button(parent, text, onClick)
    local b = API.SafeFrame("Button", parent, "UIPanelButtonTemplate")
    b:SetSize(190, 24)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

function MS.ShowPrompt()
    if not prompt then
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(460, 150)
        f:SetPoint("TOP", UIParent, "TOP", 0, -140)
        f:SetFrameStrata("DIALOG")
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(f)
        bg:SetColorTexture(0, 0, 0, 0.85)
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
        title:SetText("NodeRadar")
        local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
        text:SetWidth(432)
        text:SetJustifyH("LEFT")
        text:SetText(NR.SCAN_TEXT .. " Try it?")
        local function answer(on)
            NR.db.moveScanAsked = true
            f:Hide()
            if on then
                NR.Set("moveScan", true)
                API.Say("the minimap scan is on (/nr scan, or Options, turns it off).")
            end
        end
        local yes = button(f, "Try the minimap scan", function() answer(true) end)
        yes:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
        local no = button(f, "Not now", function() answer(false) end)
        no:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)
        f.yes, f.no, f.text = yes, no, text
        prompt = f
    end
    prompt:Show()
    return prompt
end

function MS.AskSoon(now)
    local db = NR.db
    if db and not db.moveScanAsked and not db.moveScan and API.Blind() then askAt = now + MS.ASK_AFTER end
end

local asker = CreateFrame("Frame")
asker:SetScript("OnUpdate", function()
    if not askAt then return end
    local now = GetTime()
    local db = NR.db
    if not db or db.moveScanAsked or db.moveScan then askAt = nil; return end
    if now < askAt or inCombat() or NR.Learn.loading or API.Gamepad() then return end
    askAt = nil
    MS.ShowPrompt()
end)

MS._test.prompt = function() return prompt end
MS._test.askAt = function() return askAt end
