-- Share.lua: party nodes (#83, docs/PLAN.md "Party nodes"). A character
-- sends the nodes it measured to its group (`shareNodes`); another draws
-- them on its minimap (`partyNodes`). Both off by default.
--
-- The wire (measured, docs/FOREVER-PROBE.md "Party addon messages", 70790):
-- one snapshot of the sender's wanted records a message, at most 255 bytes
-- (256 arrives cut), never closer than GAP (the throttle refills at one a
-- second and drops what it refuses), again every HEARTBEAT unchanged.
--   1|<session>|<seq>|<instance>|<item>,<north>,<west>,<name>;...
-- The receiver keeps each sender's last snapshot until EXPIRE, a newer
-- session or seq replacing it. In memory only.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Share = {}
NR.Share = Share

Share.PREFIX = "NodeRadar"
Share.VERSION = "1"
Share.BYTES = 255       -- a message's limit: 256 arrives cut to 255 (measured)
Share.GAP = 1           -- seconds between sends at least (the throttle refills at one a second)
Share.HEARTBEAT = 10    -- seconds before an unchanged snapshot goes again
Share.EXPIRE = 25       -- seconds a sender's list is kept without a message
Share.MAX = 12          -- entries a message may carry
Share.NAME_BYTES = 64   -- a node's name, at most
Share.LIMIT = 100000    -- yards: a position past this is malformed
Share.REUSE = 1         -- yards: an incoming entry of the same name this near a kept one is that one
Share.SAME = 8          -- yards: two senders' entries of one item this near are one node
Share.SUCCESS = 0       -- Enum.SendAddonMessageResult.Success
-- The sonar on a node arriving (step 2, best effort: not the sender's alert replayed).
Share.QUIET = 2         -- seconds: a sender's first messages are the silent baseline (a loading burst too)
Share.SEEN = 120        -- seconds: a node of that name seen within SAME yards this recently isn't new
Share.PENDING = 10      -- seconds: a new node ripples on its first draw within this

local session = API.Num(GetServerTime()) or 0   -- orders this load's messages after any earlier load's
local seq = 0
local registered
-- The sender: what was last sent successfully, when; when last tried; the last sweep.
local lastKey, lastAt, lastTry, lastSweep
local party = {}        -- [sender] = { session, seq, at, instance, list }
local shown = {}        -- the entries to draw: every sender's, one a node (Share.List)
local kept = {}         -- [entry] = true: the shown ones, for Share.Live
local seen = {}         -- { name, north, west, instance, at }: the nodes heard of lately (the sonar)
local roster = {}       -- [full name] = true: the group's other members
local rosterKey         -- the roster as a string, to tell a new group
local ticker

function Share.Sending()
    local db = NR.db
    return db and db.enabled and db.shareNodes and true or false
end

function Share.Showing()
    local db = NR.db
    return db and db.enabled and db.partyNodes and true or false
end

local function compass()
    if NR.Compass then NR.Compass.Refresh() end
end

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function text(v)
    if type(v) == "string" and not API.IsSecret(v) then return v end
end

-- The player in UnitPosition's frame: north, west, instance; nil if unreadable.
local function player()
    local ok, n, w, _, inst = call(UnitPosition, "player")
    if not ok then return nil end
    n, w, inst = API.Num(n), API.Num(w), API.Num(inst)
    if not (n and w and inst) then return nil end
    return n, w, inst
end

local function me()
    local ok, name = call(GetUnitName, "player", false)
    return ok and text(name) or nil
end

-- The prefix, once a session, the first time either setting is on (the dump
-- has no unregister). A refusal is recorded and tried again later.
local function register()
    if registered then return end
    local ok, res = call(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix, Share.PREFIX)
    if ok and API.Num(res) == Share.SUCCESS then
        registered = true
    else
        API.Fail("share: register", ok and ("result " .. tostring(API.Num(res))) or res)
    end
end

--------------------------------------------------------------------------------
-- The roster
--------------------------------------------------------------------------------

-- The group's other members by GetUnitName(unit, false), what CHAT_MSG_ADDON's
-- sender equals (measured); not UnitInParty(name), unmeasured with a surname.
local function readRoster()
    local set, names = {}, {}
    local okR, raid = call(IsInRaid)
    local prefix, count = "party", 4
    if okR and API.Yes(raid) then prefix, count = "raid", 40 end
    local self = me()
    for i = 1, count do
        local ok, name = call(GetUnitName, prefix .. i, false)
        name = ok and text(name)
        if name and name ~= self and not set[name] then
            set[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return set, table.concat(names, "\n")
end

--------------------------------------------------------------------------------
-- The receiver's list
--------------------------------------------------------------------------------

local function dist(a, b) return math.sqrt((a.north - b.north) ^ 2 + (a.west - b.west) ^ 2) end

-- Every sender's entries, a node once (two senders' of one item within SAME);
-- the compass chooses again (step 2).
local function rebuild()
    shown, kept = {}, {}
    local senders = {}
    for sender in pairs(party) do senders[#senders + 1] = sender end
    table.sort(senders)                                -- a fixed order: the same one wins each time
    for _, sender in ipairs(senders) do
        local p = party[sender]
        for _, e in ipairs(p.list) do
            local dup = false
            for _, s in ipairs(shown) do
                if s.item == e.item and s.instance == e.instance and dist(s, e) <= Share.SAME then dup = true; break end
            end
            if not dup then shown[#shown + 1] = e; kept[e] = true end
        end
    end
    if NR.Icons then NR.Icons.SetShared(shown) end
    compass()
end

local function stopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end

local function prune(now)
    local live = {}
    for _, s in ipairs(seen) do
        if now - s.at < Share.SEEN then live[#live + 1] = s end
    end
    seen = live
end

-- Each second while a list is kept: the lists past EXPIRE go, and the compass
-- chooses again either way (the receiver moves between messages).
local function expire()
    local now = GetTime()
    local changed = false
    for sender, p in pairs(party) do
        if now - p.at >= Share.EXPIRE then party[sender] = nil; changed = true end
    end
    prune(now)
    if next(party) == nil then stopTicker() end
    if changed then rebuild() else compass() end
end

local function startTicker()
    if not ticker and C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(1, expire) end
end

-- What Icons draws: the entries kept, one a node. Each is { name, item,
-- north, west, instance, icon?, frame? }; the same table across snapshots
-- while its node stays (so its frame, and later the compass's incumbent, do).
function Share.List() return shown end

-- Every shared node forgotten (a loading screen, partyNodes or the radar off,
-- the group left).
function Share.Clear()
    party, seen = {}, {}
    stopTicker()
    rebuild()
end

local function parse(msg)
    local v, ses, sq, inst, body = msg:match("^(%d+)|(%d+)|(%d+)|(%d+)|(.*)$")
    if v ~= Share.VERSION then return nil end
    ses, sq, inst = tonumber(ses), tonumber(sq), tonumber(inst)
    local list = {}
    if body ~= "" then
        for part in (body .. ";"):gmatch("([^;]*);") do
            if #list >= Share.MAX then return nil end
            local item, n, w, name = part:match("^(%d+),(%-?%d+%.?%d*),(%-?%d+%.?%d*),([^,]+)$")
            if not item then return nil end
            item, n, w = tonumber(item), tonumber(n), tonumber(w)
            if not (item and n and w) or item < 1 or item ~= math.floor(item) then return nil end
            if math.abs(n) > Share.LIMIT or math.abs(w) > Share.LIMIT then return nil end
            if #name > Share.NAME_BYTES or name:find("[%c|]") then return nil end
            list[#list + 1] = { item = item, north = n, west = w, name = name, instance = inst }
        end
    end
    return { session = ses, seq = sq, instance = inst, list = list }
end

-- CHAT_MSG_ADDON. Dropped whole: off, loading, a secret, not ours, not the
-- group's channel, too long, from the player (the echo) or someone not in the
-- group now, malformed, or not newer than what that sender sent last.
function Share.OnMessage(prefix, msg, channel, sender)
    if not Share.Showing() or NR.Learn.loading then return end
    prefix, msg, channel, sender = text(prefix), text(msg), text(channel), text(sender)
    if prefix ~= Share.PREFIX or not (msg and sender) then return end
    if channel ~= "PARTY" and channel ~= "RAID" then return end
    -- The roster never holds the player: its own message (the echo) isn't in it.
    if #msg > Share.BYTES or not roster[sender] then return end
    local snap = parse(msg)
    if not snap then return end
    local p = party[sender]
    if p and (snap.session < p.session or (snap.session == p.session and snap.seq <= p.seq)) then return end
    -- The same node keeps its table (its frame, the compass's incumbent, its pending).
    local now = GetTime()
    -- A new session (the sender reloaded) starts its own silent baseline (Codex on PR #86).
    local quiet = p and p.session == snap.session and p.quiet or now + Share.QUIET
    local old = p and p.list or {}
    local used = {}
    prune(now)
    for i, e in ipairs(snap.list) do
        local reused = false
        for j, o in ipairs(old) do
            if not used[j] and o.name == e.name and o.item == e.item and o.instance == e.instance
                and dist(o, e) <= Share.REUSE then
                used[j] = true
                o.north, o.west = e.north, e.west
                snap.list[i] = o
                reused = true
                break
            end
        end
        -- Arriving: pending its ripple, unless in the baseline or heard of lately.
        if not reused and now >= quiet then
            local heard = false
            for _, s in ipairs(seen) do
                if s.name == e.name and s.instance == e.instance and dist(s, e) <= Share.SAME then heard = true; break end
            end
            if not heard then e.pending = now + Share.PENDING end
        end
    end
    for _, e in ipairs(snap.list) do
        e.heard = now
        local found
        for _, s in ipairs(seen) do
            if s.name == e.name and s.instance == e.instance and dist(s, e) <= Share.SAME then found = s; break end
        end
        if found then
            found.north, found.west, found.at = e.north, e.west, now
        else
            seen[#seen + 1] = { name = e.name, north = e.north, west = e.west, instance = e.instance, at = now }
        end
    end
    party[sender] = { session = snap.session, seq = snap.seq, at = now, instance = snap.instance,
                      list = snap.list, quiet = quiet }
    startTicker()
    rebuild()
end

-- Whether a shared entry may be chosen, pointed at or starred now (step 2):
-- showing, still kept, its sender heard from less than EXPIRE ago (read now:
-- the ticker removes a list up to a second late), in the player's instance.
function Share.Live(e)
    if not (e and kept[e] and Share.Showing()) then return false end
    if not e.heard or GetTime() - e.heard >= Share.EXPIRE then return false end
    local _, _, inst = player()
    return inst ~= nil and inst == e.instance
end

-- A live shared entry of that name within `yards` of the player (the stars'
-- heuristic: a soft-interact plate carries no position).
function Share.Near(name, yards)
    local pn, pw = player()
    if not pn then return false end
    for _, e in ipairs(shown) do
        if e.name == name and Share.Live(e)
            and math.sqrt((e.north - pn) ^ 2 + (e.west - pw) ^ 2) <= yards then return true end
    end
    return false
end

-- GROUP_ROSTER_UPDATE (and at login, and when a setting turns on): the roster
-- read again; a sender gone from it forgotten; a new group sends afresh.
function Share.OnRoster()
    local set, key = readRoster()
    roster = set
    if key ~= rosterKey then lastKey, lastAt = nil, nil end
    rosterKey = key
    local changed = false
    for sender in pairs(party) do
        if not roster[sender] then party[sender] = nil; changed = true end
    end
    if changed then
        if next(party) == nil then stopTicker() end
        rebuild()
    end
end

--------------------------------------------------------------------------------
-- The sender
--------------------------------------------------------------------------------

local function channel()
    local okR, raid = call(IsInRaid)
    if okR and API.Yes(raid) then return "RAID" end
    local okG, group = call(IsInGroup)
    if okG and API.Yes(group) then return "PARTY" end
end

local function clean(name)
    return type(name) == "string" and name ~= "" and #name <= Share.NAME_BYTES and not name:find("[%c|,;]")
end

-- The snapshot: the sender's wanted records seen this sweep with an item,
-- nearest first (ties by name, then position), whole entries while the
-- message stays within BYTES. Returns the message and the set's key.
local function snapshot(pn, pw, inst)
    local list = {}
    for _, r in ipairs(NR.Icons.Records()) do
        if r.misses == 0 and not r.provisional and clean(r.name) and NR.Alert.Wanted(r.name) then
            local info = NR.Learn.Info(r.name)
            local item = info and API.Num(info.item)
            if item then
                list[#list + 1] = { s = ("%d,%.1f,%.1f,%s"):format(item, r.north, r.west, r.name), name = r.name,
                                    north = r.north, west = r.west,
                                    d = (r.north - pn) ^ 2 + (r.west - pw) ^ 2 }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.s < b.s
    end)
    local head = ("%s|%.0f|%.0f|%.0f|"):format(Share.VERSION, session, seq + 1, inst)
    local parts, size = {}, #head
    for _, e in ipairs(list) do
        if #parts >= Share.MAX then break end
        local add = #e.s + (#parts > 0 and 1 or 0)
        if size + add > Share.BYTES then break end
        parts[#parts + 1] = e.s
        size = size + add
    end
    local keyed = {}
    for i, s in ipairs(parts) do keyed[i] = s end
    table.sort(keyed)
    return head .. table.concat(parts, ";"), ("%.0f|"):format(inst) .. table.concat(keyed, ";")
end

local retrying = false
local push
-- From 70862 (#91) the scan's looks are sparse: a change the throttle turned away (a gather's
-- withdrawal) is sent again as soon as the throttle allows, not at the next look, possibly tens
-- of seconds later (Codex, PR #102). One timer at a time; the old sweep's half-second cadence
-- needed none.
local function retryLater(now)
    if retrying or not API.Blind() or not (C_Timer and C_Timer.After) then return end
    retrying = true
    C_Timer.After(math.max(0.05, Share.GAP - (now - (lastTry or now)) + 0.05), function()
        retrying = false
        push(GetTime())
    end)
end

push = function(now)
    if not Share.Sending() then return end
    local ch = channel()
    if not ch then return end
    local okL, lockdown = call(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown)
    if not okL or API.IsSecret(lockdown) or lockdown == true then return end
    local okI, instanced = call(IsInInstance)
    if not okI or API.IsSecret(instanced) or instanced ~= false then return end
    local pn, pw, inst = player()
    if not pn then return end
    local msg, key = snapshot(pn, pw, inst)
    if key == lastKey and lastAt and now - lastAt < Share.HEARTBEAT then return end
    if lastTry and now - lastTry < Share.GAP then                -- the next sweep after the gap
        if key ~= lastKey then retryLater(now) end
        return
    end
    register()
    if not registered then return end
    lastTry = now
    local ok, res = call(C_ChatInfo.SendAddonMessage, Share.PREFIX, msg, ch)
    if ok and API.Num(res) == Share.SUCCESS then
        seq = seq + 1
        lastKey, lastAt = key, now
    else
        -- Refused (3: the throttle, dropped for good): nothing advances, the next sweep tries again.
        API.Fail("share: send", ok and ("result " .. tostring(API.Num(res))) or res)
        retryLater(now)
    end
end

-- After each successful radar sweep's Icons.Update (NR.Step).
function Share.Send(now)
    if not Share.Sending() then return end
    lastSweep = now
    push(now)
end

-- The player's own successful gather of a name (after Icons.Gathered): the
-- sender's list goes out at once if its sweep is fresh; the receiver's shared
-- entries of that name by the player go until the sender's next snapshot.
function Share.Gathered(name, now)
    if Share.Sending() and API.LocalFresh(lastSweep, 2) then push(now) end
    if not Share.Showing() then return end
    local pn, pw = player()
    if not pn then return end
    local changed = false
    for _, p in pairs(party) do
        local kept = {}
        for _, e in ipairs(p.list) do
            if e.name == name and math.sqrt((e.north - pn) ^ 2 + (e.west - pw) ^ 2) <= NR.Icons.GATHERED then
                changed = true
            else
                kept[#kept + 1] = e
            end
        end
        p.list = kept
    end
    if changed then rebuild() end
end

-- A setting changed (NR.Set: shareNodes, partyNodes, enabled), and at login.
function Share.Apply()
    if Share.Sending() or Share.Showing() then
        register()
        Share.OnRoster()
    end
    if not Share.Sending() then lastKey, lastAt, lastTry, lastSweep = nil, nil, nil, nil end
    if not Share.Showing() and next(party) ~= nil then Share.Clear() end
end

-- A setting just turned on: send afresh at the next sweep.
function Share.Reset() lastKey, lastAt, lastTry = nil, nil, nil end

Share._test = {
    party = function() return party end,
    roster = function() return roster end,
    ticker = function() return ticker end,
    parse = parse,
    seen = function() return seen end,
    reset = function()
        party, shown, kept, seen, roster, rosterKey, registered = {}, {}, {}, {}, {}, nil, nil
        lastKey, lastAt, lastTry, lastSweep, seq = nil, nil, nil, nil, 0
        stopTicker()
        if NR.Icons then NR.Icons.SetShared(shown) end
    end,
}
