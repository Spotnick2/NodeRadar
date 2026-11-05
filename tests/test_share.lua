-- Party nodes (#83; docs/PLAN.md "Party nodes"): the sender's snapshots (only
-- after a sweep, wanted measured records with an item, nearest first, whole
-- entries within 255 bytes, the gap, the heartbeat, a refusal changing
-- nothing, the channel and the gates, the gather), the receiver (who, what,
-- order by session and seq, expiry, the roster, loading, off), and the
-- drawing (a receiver that never sweeps, the driver kept alive, local clears
-- leaving the party's frames, one icon a node, the pip and a pooled frame).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
WoW.BLIP_HALF = 12.5
WoW.cvars.rotateMinimap = "0"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
TEST_LIBRARY.enUS["Earthroot"] = "herbs"
local NR = loadAddon()
NR.Track.SetSmart(false)
local Icons, Share = NR.Icons, NR.Share
local T, S = Icons._test, Share._test
WoW.itemCached[765] = true                                 -- Silverleaf
WoW.itemCached[2449] = true                                -- Earthroot

WoW.units.player = { name = "Drakuza", realm = "Memphisto", full = "Drakuza Memphisto" }
WoW.units.party1 = { name = "Kalizo", realm = "Mistwalker", full = "Kalizo Mistwalker" }
local ME, OTHER = "Drakuza Memphisto", "Kalizo Mistwalker"
WoW.group = true

local function K() return C_Minimap.GetViewRadius() / 99 end
local nodes = {}
local function node(name, x, y)
    local n = { name = name, north = WoW.pos[1] + y * K(), west = WoW.pos[2] - x * K() }
    nodes[#nodes + 1] = n
    return n
end
local function place()
    local list = {}
    for _, n in ipairs(nodes) do
        if not n.gone then
            list[#list + 1] = { n.name, -(n.west - WoW.pos[2]) / K(), (n.north - WoW.pos[1]) / K(), kind = "herbs" }
        end
    end
    WoW.blips = list
end
local function step(dt)
    WoW.now = WoW.now + (dt or 1)
    place()
    return NR.Step(WoW.now)
end
local function sent(prefix)
    local out = {}
    for _, m in ipairs(WoW.sent) do if m.prefix == (prefix or "NodeRadar") then out[#out + 1] = m end end
    return out
end
local function lastSent() local s = sent(); return s[#s] end
-- A record as Icons keeps one, put straight in the list (the wire's tests).
local function record(name, north, west)
    local r = { name = name, kind = "herbs", north = north, west = west, misses = 0 }
    table.insert(T.records(), r)
    return r
end
local function fresh()
    nodes = {}
    WoW.blips = {}
    Icons.Clear()
    S.reset()
    WoW.sent, WoW.sendResult, WoW.lockdown = {}, {}, false
    WoW.group, WoW.raid, WoW.instanced = true, false, false
    WoW.pos, WoW.posSecret = { 0, 0, 1 }, false
    WoW.tracking[1].active = true
    WoW.units.party1 = { name = "Kalizo", realm = "Mistwalker", full = "Kalizo Mistwalker" }
    NR.Learn.loading = false
    WoW.now = WoW.now + 100
    Share.OnRoster()
end
local session = math.floor(GetServerTime())             -- this load's, as Share read it at load
local function msg(ses, sq, inst, ...)
    local entries = {}
    for _, e in ipairs({ ... }) do entries[#entries + 1] = e end
    return ("1|%d|%d|%d|%s"):format(ses, sq, inst, table.concat(entries, ";"))
end
local function receive(text, sender, channel)
    WoW.fire("CHAT_MSG_ADDON", "NodeRadar", text, channel or "PARTY", sender or OTHER, "", 0, 0, "", 0)
end
local function sharedList() return T.shared() end
local function frameOf(e) return e and e.frame end
local function shownFrame(e) local f = frameOf(e); return f ~= nil and f._shown == true end
local function centre(f)
    local p = f._points[#f._points]
    return p and p[4], p and p[5]
end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 0.05) end
local function driving() return T.driver:GetScript("OnUpdate") ~= nil end

--------------------------------------------------------------------------------
-- Off by default: nothing sent, nothing kept
--------------------------------------------------------------------------------

eq(NR.db.shareNodes, false, "sharing off by default")
eq(NR.db.partyNodes, false, "showing off by default")
fresh()
node("Silverleaf", 30, 30)
step(1)
eq(#sent(), 0, "off: nothing sent after a sweep")
eq(#T.records(), 0, "...and nothing measured for it")
receive(msg(session + 5, 1, 1, "765,10.0,-10.0,Silverleaf"))
eq(#sharedList(), 0, "off: a message ignored")
eq(WoW.prefixes.NodeRadar, nil, "off: the prefix not registered")

--------------------------------------------------------------------------------
-- The sender, through a real sweep
--------------------------------------------------------------------------------

NR.Set("shareNodes", true)
check(Icons.Keeping(), "sharing keeps records (measures) with icons, compass and marker off")
eq(WoW.prefixes.NodeRadar, true, "turned on: the prefix registered")
fresh()
local leaf = node("Silverleaf", 30, 30)
step(1)
local m = lastSent()
check(m ~= nil, "a sweep's measured node goes out")
eq(m and m.chatType, "PARTY", "...on PARTY in a party")
local snap = m and S.parse(m.text)
check(snap ~= nil, "...in the format the receiver reads")
eq(snap and snap.seq, 1, "...seq 1")
eq(snap and snap.session, session, "...this load's session")
eq(snap and snap.instance, 1, "...the sender's instance")
eq(snap and #snap.list, 1, "...one entry")
local e1 = snap and snap.list[1]
eq(e1 and e1.item, 765, "...the item ID")
eq(e1 and e1.name, "Silverleaf", "...the node's name")
check(e1 and near(e1.north, leaf.north, 0.6) and near(e1.west, leaf.west, 0.6), "...its measured position")

--------------------------------------------------------------------------------
-- The wire: the snapshot, the gap, the heartbeat, a refusal
--------------------------------------------------------------------------------

local function send(dt)
    WoW.now = WoW.now + (dt or 0)
    Share.Send(WoW.now)
end
fresh()
record("Silverleaf", 50, 0)
record("Earthroot", 10, 0)
send(0)
local first = S.parse(lastSent().text)
eq(first.list[1].name, "Earthroot", "nearest first")
eq(first.list[2].name, "Silverleaf", "...then the next")
eq(#sent(), 1, "one message")
send(0.5)
eq(#sent(), 1, "unchanged within the heartbeat: not sent again")
send(5)
eq(#sent(), 1, "...still not at 5 s")
send(5)
eq(#sent(), 2, "unchanged: sent again at the heartbeat (10 s)")
eq(S.parse(lastSent().text).seq, 2, "...seq 2")
record("Silverleaf", -30, 0)
send(0.5)
eq(#sent(), 2, "a change within the 1 s gap: waits")
send(0.5)
eq(#sent(), 3, "...goes out with the first sweep after the gap")
eq(#S.parse(lastSent().text).list, 3, "...with the new node")
-- Moving reorders the list without changing the set: not a change.
WoW.pos = { 0, 40, 1 }
send(1.5)
eq(#sent(), 3, "the player moved, the same set: not resent before the heartbeat")
WoW.pos = { 0, 0, 1 }

fresh()
record("Silverleaf", 10, 0)
WoW.sendResult.PARTY = 3                                   -- the throttle: dropped for good
send(0)
eq(#sent(), 1, "a send tried")
send(1)
eq(#sent(), 2, "refused (3): the next sweep tries again, nothing counted as sent")
eq(S.parse(WoW.sent[2].text).seq, 1, "...with the same seq")
check(NR.failures["share: send"] ~= nil, "...the refusal recorded")
WoW.sendResult.PARTY = nil
send(1)
eq(#sent(), 3, "accepted at last")
send(1)
eq(#sent(), 3, "...and only then is it the last sent")

-- What's left out.
fresh()
record("Silverleaf", 10, 0).misses = 1                     -- not seen this sweep
local p = record("Silverleaf", 12, 0); p.provisional = true
record("Peacebloom of Mystery", 14, 0)                     -- no item known
record("Earthroot", 16, 0)
NR.Track.Set(2449, false)                                  -- Earthroot skipped (#47): not wanted
send(0)
eq(#S.parse(lastSent().text).list, 0, "missed, provisional, unknown and unwanted records: none sent")
NR.Track.Set(2449, true)

-- The empty list is a snapshot too: it's how the receiver learns the last node went.
fresh()
local r = record("Silverleaf", 10, 0)
send(0)
eq(#S.parse(lastSent().text).list, 1, "one node sent")
table.remove(T.records())
send(1)
eq(#sent(), 2, "the node gone: sent")
eq(#S.parse(lastSent().text).list, 0, "...an empty list")

-- 255 bytes, whole entries, nearest first.
fresh()
for i = 1, 15 do record("Silverleaf", i * 10 + 0.04, -i * 10 - 0.04) end
send(0)
local big = lastSent().text
check(#big <= 255, "never over 255 bytes (" .. #big .. ")")
local bs = S.parse(big)
check(bs ~= nil and #bs.list >= 5 and #bs.list < 15, "...whole entries, the farthest left out (" .. (bs and #bs.list or 0) .. ")")
eq(bs and bs.list[1].north, 10, "...nearest first")
local nextEntry = ("%d,%.1f,%.1f,%s"):format(765, (#bs.list + 1) * 10 + 0.04, -(#bs.list + 1) * 10 - 0.04, "Silverleaf")
check(#big + 1 + #nextEntry > 255, "...the next one wouldn't have fitted")

-- The channel and the gates.
fresh()
record("Silverleaf", 10, 0)
WoW.raid = true
send(0)
eq(lastSent().chatType, "RAID", "in a raid: RAID")
fresh()
record("Silverleaf", 10, 0)
WoW.group = false
send(0)
eq(#sent(), 0, "solo: nothing sent")
fresh()
record("Silverleaf", 10, 0)
WoW.lockdown = true
send(0)
eq(#sent(), 0, "messaging lockdown: nothing sent")
fresh()
record("Silverleaf", 10, 0)
WoW.instanced = true
send(0)
eq(#sent(), 0, "in an instance: nothing sent")

-- A new group sends afresh.
fresh()
record("Silverleaf", 10, 0)
send(0)
eq(#sent(), 1, "sent")
WoW.units.party2 = { name = "Third", realm = "One", full = "Third One" }
WoW.fire("GROUP_ROSTER_UPDATE")
send(1)
eq(#sent(), 2, "a new group: the same list sent again at once, not at the heartbeat")
WoW.units.party2 = nil

-- The gather: sent at once (through the gap), without the gathered node.
fresh()
node("Silverleaf", 3, 3)
node("Earthroot", 40, 40)
step(1)
step(1)
local before = #sent()
check(before >= 1 and #S.parse(lastSent().text).list == 2, "two nodes sent")
WoW.now = WoW.now + 1
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "cast-1", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 2366)
eq(#sent(), before + 1, "a gather: a snapshot at once, no sweep")
local after = S.parse(lastSent().text)
eq(#after.list, 1, "...without the gathered node")
eq(after.list[1].name, "Earthroot", "...the other one kept")

-- Off: nothing more.
NR.Set("shareNodes", false)
fresh()
record("Silverleaf", 10, 0)
send(0)
eq(#sent(), 0, "sharing off: nothing sent")

--------------------------------------------------------------------------------
-- The receiver: never swept, icons, compass and marker off (Codex's first case)
--------------------------------------------------------------------------------

NR.Set("partyNodes", true)
check(not Icons.Keeping(), "showing alone measures nothing here")
fresh()
WoW.tracking[1].active = false                             -- no tracking: NR.Step never sweeps
check(step(1) == nil, "no tracking: no sweep")
receive(msg(session + 5, 1, 1, "765,30.0,-40.0,Silverleaf"))
local list = sharedList()
eq(#list, 1, "a party member's node kept")
local entry = list[1]
check(entry.party and entry.item == 765 and entry.name == "Silverleaf", "...as a party entry")
check(driving(), "...the driver running with no local sweep")
WoW.tick()
check(shownFrame(entry), "...drawn")
local x, y = centre(entry.frame)
check(near(x, -(-40 - 0) / K(), 0.01) and near(y, 30 / K(), 0.01), "...where it is from the player")
eq(entry.frame.tex._desaturated or (entry.frame.bronze and entry.frame.bronze.icon._desaturated), false,
   "...never dimmed")
check(entry.frame.pip._shown and entry.frame.arrowFrame._shown, "...with the party pip")
check(entry.frame.arrow._shown ~= true, "...and no height arrow")
eq(entry.frame._mouse, false, "...no mouse")
WoW.pos = { 10, 0, 1 }
WoW.tick()
x, y = centre(entry.frame)
check(near(y, 20 / K(), 0.01), "moved: drawn from the new position, still no sweep")

-- Restyled with icons off.
NR.Set("iconStyle", "yellow")
check(entry.frame.ring and entry.frame.ring._shown, "restyled with icons off: the party icon in the new look")
NR.Set("iconStyle", "auto")

-- Hidden for a moment, then back with no message and no sweep.
WoW.posSecret = true
WoW.tick()
check(not shownFrame(entry), "position unreadable: hidden")
check(driving(), "...the driver kept")
WoW.posSecret = false
WoW.tick()
check(shownFrame(entry), "...readable again: back by itself")
WoW.pos = { 5000, 0, 1 }
WoW.tick()
check(not shownFrame(entry), "past the rim: hidden")
check(driving(), "...the driver kept")
WoW.pos = { 10, 0, 1 }
WoW.tick()
check(shownFrame(entry), "...back in range: shown again")
WoW.pos = { 0, 0, 2 }
WoW.tick()
check(not shownFrame(entry), "another instance: hidden")
WoW.pos = { 0, 0, 1 }

-- A newer snapshot replaces it, the same node keeping its table and frame.
local frame = entry.frame
receive(msg(session + 5, 2, 1, "765,30.2,-40.0,Silverleaf", "2449,0.0,20.0,Earthroot"))
list = sharedList()
eq(#list, 2, "a newer snapshot replaces the list")
check(list[1] == entry and entry.frame == frame, "...the same node keeps its table and frame")
receive(msg(session + 5, 2, 1, ""))
eq(#sharedList(), 2, "the same seq again: dropped")
receive(msg(session + 5, 1, 1, ""))
eq(#sharedList(), 2, "an older seq: dropped")
receive(msg(session + 6, 1, 1, "2449,0.0,20.0,Earthroot"))
eq(#sharedList(), 1, "a newer session (the sender reloaded): replaces, seq starting over")
receive(msg(session + 5, 9, 1, ""))
eq(#sharedList(), 1, "a late message of the older session: dropped")
WoW.tick()
check(not shownFrame(entry) and entry.frame == nil, "the node gone from the list: its frame released")
receive(msg(session + 6, 2, 1, ""))
eq(#sharedList(), 0, "an empty snapshot: nothing left")
WoW.tick()
check(not driving(), "...and the driver stops")

-- Dropped whole.
fresh()
local ok1 = "765,30.0,-40.0,Silverleaf"
local cases = {
    { "the echo", msg(session + 5, 1, 1, ok1), ME },
    { "someone not in the group", msg(session + 5, 1, 1, ok1), "Some Stranger" },
    { "a whisper", msg(session + 5, 1, 1, ok1), OTHER, "WHISPER" },
    { "another version", "2|" .. (session + 5) .. "|1|1|" .. ok1 },
    { "13 entries", msg(session + 5, 1, 1, "765,1,1,S", "765,1,2,S", "765,1,3,S", "765,1,4,S", "765,1,5,S",
        "765,1,6,S", "765,1,7,S", "765,1,8,S", "765,1,9,S", "765,2,1,S", "765,2,2,S", "765,2,3,S", "765,2,4,S") },
    { "item 0", msg(session + 5, 1, 1, "0,30.0,-40.0,Silverleaf") },
    { "a position past 100000", msg(session + 5, 1, 1, "765,300000.0,-40.0,Silverleaf") },
    { "a control character", msg(session + 5, 1, 1, "765,30.0,-40.0,Silver\1leaf") },
    { "an empty entry", msg(session + 5, 1, 1, ok1, "") },
    { "a missing field", msg(session + 5, 1, 1, "765,30.0,Silverleaf") },
    { "over 255 bytes", msg(session + 5, 1, 1, "765,30.0,-40.0," .. ("S"):rep(250)) },
    { "a name over 64 bytes", msg(session + 5, 1, 1, "765,30.0,-40.0," .. ("S"):rep(65)) },
}
for _, c in ipairs(cases) do
    receive(c[2], c[3], c[4])
    eq(#sharedList(), 0, "dropped: " .. c[1])
end
WoW.fire("CHAT_MSG_ADDON", "NodeRadar", WoW.Secret("text"), "PARTY", OTHER)
eq(#sharedList(), 0, "dropped: a secret message")
WoW.fire("CHAT_MSG_ADDON", "NodeRadar", msg(session + 5, 1, 1, ok1), "PARTY", WoW.Secret("sender"))
eq(#sharedList(), 0, "dropped: a secret sender")
WoW.fire("CHAT_MSG_ADDON", "Other", msg(session + 5, 1, 1, ok1), "PARTY", OTHER)
eq(#sharedList(), 0, "dropped: another prefix")
NR.Learn.loading = true
receive(msg(session + 5, 1, 1, ok1))
eq(#sharedList(), 0, "dropped: while loading")
NR.Learn.loading = false
receive(msg(session + 5, 1, 1, ok1))
eq(#sharedList(), 1, "...and the same message accepted once loaded")
receive(msg(session + 5, 2, 1, "765,30.0,-40.0,Silverleaf", "2449,1,2,Earthroot"), OTHER, "RAID")
eq(#sharedList(), 2, "RAID accepted too")
receive(msg(session + 5, 1, 1, "765,1,1,S", "765,1,2,S", "765,1,3,S", "765,1,4,S", "765,1,5,S",
    "765,1,6,S", "765,1,7,S", "765,1,8,S", "765,1,9,S", "765,2,1,S", "765,2,2,S", "765,2,3,S"), "Third One")
-- (Third One isn't in the group: dropped; the twelve-entry case is accepted below.)

-- 12 entries: the most a message may carry.
fresh()
receive(msg(session + 5, 1, 1, "765,1,1,S", "765,1,20,S", "765,1,40,S", "765,1,60,S", "765,1,80,S",
    "765,1,100,S", "765,1,120,S", "765,1,140,S", "765,1,160,S", "765,1,180,S", "765,1,200,S", "765,1,220,S"))
eq(#sharedList(), 12, "twelve entries accepted")

-- In a raid the roster's units include the player: its own messages are still the echo.
fresh()
WoW.raid = true
WoW.units.raid1 = WoW.units.player
WoW.units.raid2 = WoW.units.party1
WoW.fire("GROUP_ROSTER_UPDATE")
check(S.roster()[OTHER] and not S.roster()[ME], "a raid's roster: the others, never the player")
receive(msg(session + 5, 1, 1, ok1), ME, "RAID")
eq(#sharedList(), 0, "in a raid, my own message: the echo, dropped")
receive(msg(session + 5, 1, 1, ok1), OTHER, "RAID")
eq(#sharedList(), 1, "...the other's, kept")
WoW.units.raid1, WoW.units.raid2, WoW.raid = nil, nil, false

-- Expiry with no further message and no sweep.
fresh()
receive(msg(session + 5, 1, 1, ok1))
eq(#sharedList(), 1, "kept")
WoW.now = WoW.now + 24
WoW.tick()
eq(#sharedList(), 1, "...at 24 s")
WoW.now = WoW.now + 1.5
WoW.tick()
eq(#sharedList(), 0, "...gone at 25 s, by the ticker alone")
check(S.ticker() == nil, "...the ticker stopped with nothing kept")

-- The roster.
fresh()
receive(msg(session + 5, 1, 1, ok1))
WoW.units.party1 = nil
WoW.fire("GROUP_ROSTER_UPDATE")
eq(#sharedList(), 0, "the sender left the group: forgotten")
receive(msg(session + 5, 2, 1, ok1))
eq(#sharedList(), 0, "...and its message arriving after the roster event dropped")

-- A loading screen; partyNodes off.
fresh()
receive(msg(session + 5, 1, 1, ok1))
WoW.fire("LOADING_SCREEN_ENABLED")
eq(#sharedList(), 0, "a loading screen: forgotten")
fresh()
receive(msg(session + 5, 1, 1, ok1))
local f1 = sharedList()[1].frame
NR.Set("partyNodes", false)
eq(#sharedList(), 0, "showing off: forgotten")
check(not f1._shown, "...its frame hidden")
NR.Set("partyNodes", true)

-- Local clears leave the party's frames.
fresh()
receive(msg(session + 5, 1, 1, ok1))
WoW.tick()
WoW.fire("MINIMAP_UPDATE_TRACKING")                        -- clears the local records
Icons.Release()
WoW.tick()
eq(#sharedList(), 1, "a tracking change, the icons released: the party's nodes kept")
check(shownFrame(sharedList()[1]) and driving(), "...still drawn")

-- The receiver's own gather drops the shared entry by the player.
fresh()
receive(msg(session + 5, 1, 1, "765,5.0,5.0,Silverleaf", "765,100.0,100.0,Silverleaf"))
WoW.fire("UNIT_SPELLCAST_SENT", "player", "Silverleaf", "cast-2", 2366)
WoW.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 2366)
eq(#sharedList(), 1, "my own gather: the shared node by me goes, the far one stays")
eq(sharedList()[1].north, 100, "...the far one")

-- Two senders, one node: drawn once.
fresh()
WoW.units.party2 = { name = "Third", realm = "One", full = "Third One" }
WoW.fire("GROUP_ROSTER_UPDATE")
receive(msg(session + 5, 1, 1, "765,30.0,-40.0,Silverleaf"))
receive(msg(session + 7, 1, 1, "765,33.0,-41.0,Silverleaf"), "Third One")
eq(#sharedList(), 1, "two senders' entries of one node: one icon")
WoW.units.party2 = nil
WoW.fire("GROUP_ROSTER_UPDATE")

--------------------------------------------------------------------------------
-- One icon a node against the receiver's own icons
--------------------------------------------------------------------------------

NR.Set("icons", true)
fresh()
local own = node("Silverleaf", 20, 20)
step(1)
step(1)
local rec = T.records()[1]
check(rec ~= nil and rec.frame ~= nil, "my own icon")
WoW.tick()
check(rec.frame._shown, "...drawn")
receive(msg(session + 5, 1, 1, ("765,%.1f,%.1f,Silverleaf"):format(own.north + 3, own.west)))
WoW.tick()
check(not shownFrame(sharedList()[1]), "a party node within 8 yards of my drawn icon of its item: not drawn")
receive(msg(session + 5, 2, 1, ("765,%.1f,%.1f,Silverleaf"):format(own.north + 30, own.west)))
WoW.tick()
check(shownFrame(sharedList()[1]), "...30 yards off: drawn")
NR.Set("icons", false)
NR.Set("compass", true)                                     -- records kept, none drawn
receive(msg(session + 5, 3, 1, ("765,%.1f,%.1f,Silverleaf"):format(own.north + 3, own.west)))
step(1)
WoW.tick()
check(#T.records() >= 1, "a record kept for the compass")
check(shownFrame(sharedList()[1]), "...but not drawn: the party node is")
NR.Set("compass", false)

-- A pooled frame changes hands: the pip follows the owner.
NR.Set("icons", true)
fresh()
receive(msg(session + 5, 1, 1, ok1))
local pooled = sharedList()[1].frame
receive(msg(session + 5, 2, 1, ""))                       -- released to the pool
node("Silverleaf", 20, 20)
step(1)
step(1)
local own2 = T.records()[1]
check(own2 and own2.frame == pooled, "my own icon took the party node's frame")
check(not pooled.pip._shown, "...its pip hidden")
NR.Set("icons", false)

done("test_share")
