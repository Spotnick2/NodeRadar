-- The party procedures (/fp steps nr party, partygeo, partyplate, #83) and the
-- listener for the probe-only prefix NRProbe: the prefix registered, every
-- CHAT_MSG_ADDON logged (echo, other sender, secrets, a position message), the
-- roster, the sends and their result codes, the 255/256-byte payloads, the
-- background stream resuming after a reload and stopping, the CVars put back on
-- every way out. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
WoW.cvars.rotateMinimap = "0"
WoW.cvars.softTargetInteract = "1"
WoW.cvars.SoftTargetIconGameObject = "0"
WoW.cvars.SoftTargetInteractRange = "10.000000"
WoW.map, WoW.mapPos, WoW.mapSize = 1411, { x = 0.5, y = 0.5 }, { 5287, 3525 }
WoW.pos = { 100.5, 200.25, 1 }
WoW.units.player = { name = "Hasten", realm = "Windrunner", full = "Hasten Windrunner" }
local NR = loadAddon()
NR.db.enabled = false
local FP = loadForeverProbe()
local NS = loadProbe()
local T = NS._partyTest
local S = FP.Steps
local db = NodeRadarProbeDB

local function party() return NodeRadarProbeDB.party end
local function logged(pattern)
    local l = party().lines
    for i = #l, 1, -1 do if l[i]:find(pattern) then return l[i] end end
end
local function count(pattern)
    local n = 0
    for _, l in ipairs(party().lines) do if l:find(pattern) then n = n + 1 end end
    return n
end
local function errors()
    local c = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") and not l:find("UI_ERROR_MESSAGE") then c = c + 1 end end
    return c
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function rec(name) return FP.db.steps.records["NodeRadarProbe/" .. name] end
local function tick(s) for _ = 1, math.floor(s / 0.05 + 0.5) do WoW.now = WoW.now + 0.05; WoW.tick(0.05) end end
local function settle() for _ = 1, 4 do tick(0.5); WoW.fire("SCREENSHOT_SUCCEEDED") end end
local function mine() -- what this client sent on our prefix, in order
    local out = {}
    for _, m in ipairs(WoW.sent) do if m.prefix == "NRProbe" then out[#out + 1] = m end end
    return out
end
local function rx(text, sender, prefix, channel)
    WoW.fire("CHAT_MSG_ADDON", prefix or "NRProbe", text, channel or "PARTY", sender or "Moira Stormrage",
        sender or "Moira Stormrage", 0, 0, "", 0)
end
local function reload(newSession)
    WoW.fire("PLAYER_LOGOUT")
    FP.run = FP.run + 1
    T.wipe(newSession)
    WoW.fire("PLAYER_LOGIN")
end

--------------------------------------------------------------------------------
-- The prefix, at load
--------------------------------------------------------------------------------

eq(WoW.prefixes.NRProbe, true, "the prefix NRProbe registered at load")
check(logged("RegisterAddonMessagePrefix%(NRProbe%) %-> 0; registered true; session %d+; player \"Hasten Windrunner\""),
    "...its result, the session and the player's full name logged")

--------------------------------------------------------------------------------
-- The listener
--------------------------------------------------------------------------------

local before = #party().lines
rx("hello|1", "Hasten Windrunner")
local l = logged("RX PARTY")
check(l and l:find("sender=Hasten Windrunner player=Hasten Windrunner echo=true len=7 ", 1, true), "an echo: same sender, true")
check(l and l:find("payload=hello|1", 1, true), "...with its payload: " .. tostring(l))
check(l and l:find("t=%d+%.%d%d"), "...and the time")
rx("hello|2", "Moira Stormrage", "NRProbe", "RAID")
l = logged("RX RAID")
check(l and l:find("sender=Moira Stormrage player=Hasten Windrunner echo=false len=7 ", 1, true), "another sender, echo false, the channel")
local n = #party().lines
rx("hello|3", "Moira Stormrage", "OtherAddon")
eq(#party().lines, n, "another prefix: nothing logged")
rx("a\0b\n\\c", "Moira Stormrage")
l = logged("RX PARTY")
check(l and l:find("len=6 ", 1, true) and l:find("payload=a\\000b\\010\\\\c", 1, true), "control bytes and the backslash escaped: " .. tostring(l))
rx(("x"):rep(255) .. "OVER")
l = logged("RX PARTY")
check(l and l:find("len=259 ", 1, true) and l:find("payload=" .. ("x"):rep(255) .. "$"), "the payload logged up to 255 bytes, its true length kept")

-- Secrets: every argument tested first, "secret" logged.
local ok = pcall(WoW.fire, "CHAT_MSG_ADDON", "NRProbe", WoW.Secret("text"), "PARTY", "Moira Stormrage", "t", 0, 0, "", 0)
eq(ok, true, "a secret text didn't throw")
l = logged("RX PARTY")
check(l and l:find("len=secret ", 1, true) and l:find("payload=secret", 1, true), "...logged as secret")
ok = pcall(WoW.fire, "CHAT_MSG_ADDON", "NRProbe", "hello|9", WoW.Secret("channel"), WoW.Secret("sender"), WoW.Secret("t"),
    WoW.Secret("z"), WoW.Secret("l"), WoW.Secret("n"), WoW.Secret("i"))
eq(ok, true, "a secret sender, channel and the rest didn't throw")
l = logged("RX secret")
check(l and l:find("sender=secret ", 1, true) and l:find("echo=?", 1, true) and l:find("payload=hello|9", 1, true),
    "...sender secret, echo unknown: " .. tostring(l))
ok = pcall(WoW.fire, "CHAT_MSG_ADDON", WoW.Secret("prefix"), "hello|9", "PARTY", "Moira Stormrage", "", 0, 0, "", 0)
eq(ok, true, "a secret prefix didn't throw")
check(logged("prefix secret"), "...logged")

-- A position message against the receiver's own position.
WoW.pos = { 100.5, 200.25, 1 }
rx("pos|100.00|200.00|1")
check(logged("pos: theirs 100.00, 200.00 inst 1; mine 100.50, 200.25 inst 1; diff 0.50, 0.25 %(0.56 yd%)"),
    "a position message: the receiver's own position and the difference")
WoW.posSecret = true
rx("pos|100.00|200.00|1")
check(logged("pos: own position not readable"), "...an unreadable own position says so")
WoW.posSecret = nil

-- The roster.
WoW.group = true
WoW.units.party1 = { name = "Moira", realm = "Stormrage", full = "Moira Stormrage" }
WoW.fire("GROUP_ROSTER_UPDATE")
check(logged("GROUP_ROSTER_UPDATE: IsInGroup true, IsInRaid false"), "GROUP_ROSTER_UPDATE: IsInGroup and IsInRaid")
check(logged("party1 GetUnitName%(unit, false%) \"Moira Stormrage\", UnitName %(\"Moira\", \"Stormrage\"%)"),
    "...the full name and both UnitName returns of a party unit")
WoW.raid = true
WoW.units.raid3 = { name = "Nissa", realm = "Ward", full = "Nissa Ward" }
WoW.fire("GROUP_ROSTER_UPDATE")
check(logged("IsInRaid true"), "...a raid")
check(logged("raid3 GetUnitName%(unit, false%) \"Nissa Ward\", UnitName %(\"Nissa\", \"Ward\"%)"), "...a raid unit")
WoW.raid, WoW.units.raid3 = false, nil

--------------------------------------------------------------------------------
-- /fp steps nr party (on H)
--------------------------------------------------------------------------------

WoW.sent = {}
WoW.sendResult.PARTY = function(text) return #text > 255 and 2 or 0 end   -- the 256-byte one refused
fp("steps nr party")
local function r(i) return rec("party").results[i] or {} end
local function d(i) return tostring(r(i).detail or r(i).lastError) end
S.Answer(true)                                             -- 1: the setup
tick(0.2)
eq(r(2).status, "done", "identity: " .. d(2))
check(logged("identity: GetUnitName%(player, false%) \"Hasten Windrunner\", UnitName%(player%) %(\"Hasten\", \"Windrunner\"%), InChatMessagingLockdown false"),
    "the identity: the full name, both UnitName returns, the lockdown")
check(logged("setup: IsInGroup true"), "...and the roster")

-- 3: hello.
eq(r(3).status, "done", "hello sent: " .. d(3))
eq(#mine(), 1, "...one message")
eq(mine()[1].text, "hello|1", "...hello|1")
eq(mine()[1].chatType, "PARTY", "...on PARTY")
check(logged("TX PARTY len 7 t=[%d%.]+ %-> 0 payload=hello|1"), "...its result code logged")

-- 4: the stream.
local session = T.session()
tick(31)
eq(r(4).status, "done", "stream: " .. d(4))
check(d(4):find("stream: 60 done: 0 x60", 1, true), "...60 sent, every result code tallied: " .. d(4))
local all = mine()
local seqs = {}
for _, m in ipairs(all) do
    local s, nn = m.text:match("^seq|(%d+)|(%d+)$")
    if s then seqs[#seqs + 1] = { tonumber(s), tonumber(nn) } end
end
eq(#seqs, 60 + 5, "...60 numbered messages, then the burst's five")
local inOrder = true
for i, s in ipairs(seqs) do inOrder = inOrder and s[1] == session and s[2] == i end
check(inOrder, "...numbered 1..n of this session in order")
-- The stream at two a second.
local t1, t2 = {}, {}
for _, line in ipairs(party().lines) do
    local t, nn = line:match("^[%d%.]+ TX PARTY len %d+ t=([%d%.]+) %-> 0 payload=seq|%d+|(%d+)$")
    if t then t1[tonumber(nn)] = tonumber(t) end
end
check(t1[2] and t1[1] and math.abs((t1[2] - t1[1]) - 0.5) < 0.06, "...half a second apart")

-- 5: the burst of five, in one frame.
eq(r(5).status, "done", "burst: " .. d(5))
check(d(5):find("burst of 5: 0 x5", 1, true), "...five results")
local frame
local sameFrame = true
for i = 61, 65 do
    local line = logged("payload=seq|%d+|" .. i .. "$")
    local t = line and line:match("t=([%d%.]+)")
    frame = frame or t
    sameFrame = sameFrame and t == frame
end
check(frame and sameFrame, "...all five at the same time")

-- 6: the sizes.
eq(r(6).status, "done", "sizes: " .. d(6))
local s255, s256, sName, sEmpty
all = mine()
for _, m in ipairs(all) do
    if m.text:find("^size255|") then s255 = m.text
    elseif m.text:find("^size256|") then s256 = m.text
    elseif m.text:find("^name|") then sName = m.text
    elseif m.text:find("^1|") then sEmpty = m.text end
end
eq(s255 and #s255, 255, "a payload of exactly 255 bytes")
eq(s256 and #s256, 256, "a payload of 256 bytes")
eq(sName and #sName, #("name|" .. session .. "|") + T.nameBytes(), "a long non-ASCII name, sent byte for byte")
check(sName and sName:find("\195\134", 1, true), "...its accented letters as UTF-8")
check(T.nameBytes() >= 40, "...of 40 bytes or more")
eq(sEmpty, ("1|%d|1|0|"):format(session), "an empty snapshot")
check(d(6):find("255 bytes len 255 -> 0; 256 bytes len 256 -> 2;", 1, true), "...each length and result logged: " .. d(6))
check(d(6):find("empty snapshot len " .. #sEmpty .. " -> 0", 1, true), "...the empty snapshot's too")

-- 7, 8: the same spot, three positions a second apart.
WoW.sendResult.PARTY = nil
WoW.pos = { 10.123, 20.456, 1 }
S.Answer(true)
tick(4)
eq(r(8).status, "done", "positions: " .. d(8))
check(d(8):find("pos: 3 done: 0 x3", 1, true), "...three sent")
local poss = {}
for _, m in ipairs(mine()) do if m.text:find("^pos|") then poss[#poss + 1] = m.text end end
eq(#poss, 3, "...three position messages")
eq(poss[1], "pos|10.12|20.46|1", "...north, west to 0.01 yard, the instance")
local pt = {}
for _, line in ipairs(party().lines) do
    local t = line:match("t=([%d%.]+) %-> 0 payload=pos|")
    if t then pt[#pt + 1] = tonumber(t) end
end
check(#pt == 3 and math.abs(pt[2] - pt[1] - 1) < 0.06 and math.abs(pt[3] - pt[2] - 1) < 0.06, "...a second apart")

-- 9: the background stream.
eq(r(9).status, "done", "the background stream starts: " .. d(9))
eq(party().stream.manual, false, "...saved as a flag, with the procedure")
local mark = #mine()
tick(3.05)
eq(#mine() - mark, 3, "...one a second")
eq(mine()[#mine()].text, ("seq|%d|%d"):format(session, 68), "...numbered on from the stream and burst")

-- 10: a reload; the stream starts again, with the new session.
local newSession = session + 5000
reload(newSession)
S.Resume()
check(logged("stream resumed after the load %(with the procedure%), session " .. newSession), "after the reload: the stream resumed")
mark = #mine()
tick(3.05)
eq(#mine() - mark, 3, "...one a second again")
eq(mine()[mark + 1].text, ("seq|%d|1"):format(newSession), "...a new session, numbered from 1")
eq(mine()[mark + 3].text, ("seq|%d|3"):format(newSession), "...in order")

-- 11, 12: the group left and joined, the other window reloaded: the stream goes on.
mark = #mine()
S.Answer(true)
tick(2.05)
check(#mine() - mark == 2, "the stream ran while the group was left and joined")
WoW.fire("GROUP_ROSTER_UPDATE")
tick(2.05)
check(#mine() - mark == 4, "...and while the other window reloaded")
S.Answer(true)

-- 13: it stops.
eq(r(13).status, "done", "the stream stops: " .. d(13))
mark = #mine()
tick(3)
eq(#mine(), mark, "...nothing sent after it")
eq(party().stream, nil, "...the flag cleared")
eq(#WoW.tickers, 0, "...no ticker left")

-- 14, 15: combat.
tick(1.2)
eq(r(14).status, nil, "combat: waits for the fight")
eq(#mine(), mark, "...nothing sent yet")
WoW.combat, WoW.lockdown = true, true
tick(1.2)
eq(r(14).status, "done", "in combat: " .. d(14))
check(logged("in combat: InCombatLockdown true, InChatMessagingLockdown true"), "...both read")
mark = #mine()
local cm = {}
for _, m in ipairs(mine()) do if m.text:find("^combat|") then cm[#cm + 1] = m.text end end
eq(table.concat(cm, ","), "combat|1,combat|2,combat|3", "...three sent")
check(d(14):find("in combat: 0 x3", 1, true), "...their results: " .. d(14))
tick(1.2)
eq(r(15).status, nil, "...still waiting for the end of the fight")
WoW.combat, WoW.lockdown = false, false
tick(1.2)
eq(r(15).status, "done", "out of combat: " .. d(15))
check(logged("out of combat: InCombatLockdown false, InChatMessagingLockdown false"), "...both read")
cm = {}
for _, m in ipairs(mine()) do if m.text:find("^combat|") then cm[#cm + 1] = m.text end end
eq(#cm, 6, "...three more sent")

-- 16, 17: a raid.
WoW.raid = true
WoW.units.raid3 = { name = "Nissa", realm = "Ward", full = "Nissa Ward" }
WoW.sendResult.PARTY = 5
S.Answer(true)
tick(0.2)
eq(r(17).status, "done", "raid: " .. d(17))
check(logged("raid: IsInRaid true"), "...IsInRaid read")
check(d(17):find("RAID -> 0; PARTY -> 5", 1, true), "...a send on RAID and one on PARTY, both results: " .. d(17))
local last2 = { mine()[#mine() - 1], mine()[#mine()] }
eq(last2[1].chatType .. last2[1].text, "RAIDraid|1", "...RAID first")
eq(last2[2].chatType .. last2[2].text, "PARTYraid|2", "...then PARTY")
S.Next()                                                    -- 18
tick(0.2)
eq(r(19).status, "done", "the end: everything stopped")
eq(#WoW.tickers, 0, "...no ticker left")
eq(rec("party").at, 20, "...waiting for the reload of both windows")
WoW.sendResult.PARTY, WoW.raid, WoW.units.raid3 = nil, false, nil
fp("steps stop")

-- The stream stops with its procedure, without being asked.
mark = #mine()
fp("steps nr party")
S.Answer(true)
tick(0.2)
eq(mine()[mark + 1].text, "hello|1", "...a new session's hello count starts again")
for _ = 1, 3 do S.Skip() end                               -- to the background stream
tick(0.2)
eq(rec("party").results[9].status, "done", "a second run: the background stream on")
tick(2.05)
check(#mine() - mark >= 2, "...running")
fp("steps stop")
tick(1.2)
mark = #mine()
tick(3)
eq(#mine(), mark, "the procedure stopped: the stream stops by itself")
check(logged("stream off: its procedure ended"), "...logged")
eq(party().stream, nil, "...the flag cleared, so a load doesn't start it")

-- Stopped mid-stream and started again: the old ticker is gone, 60 messages and no more.
fp("steps nr party")
S.Answer(true)
tick(3.05)                                                  -- the stream under way
fp("steps stop")
mark = #mine()
fp("steps nr party")
S.Answer(true)
tick(31)
local seqCount = 0
for i = mark + 1, #mine() do if mine()[i].text:find("^seq|") then seqCount = seqCount + 1 end end
eq(seqCount, 60 + 5, "a restart mid-stream: its own 60 and the burst, no stale ticker's")
fp("steps stop")
tick(1.2)

-- Run again in the same session: the hello is numbered on.
mark = #mine()
fp("steps nr party")
S.Answer(true)
tick(0.2)
eq(mine()[mark + 1].text, "hello|4", "a later run: the hello numbered on")
fp("steps stop")
tick(1.2)

-- By hand, it outlives a procedure, and /fp nr stream off stops it.
fp("nr stream on")
tick(2.05)
mark = #mine()
check(mark > 0 and party().stream.manual == true, "/fp nr stream on: a stream by hand")
tick(2.05)
check(#mine() > mark, "...it runs without a procedure")
fp("nr stream off")
mark = #mine()
tick(3)
eq(#mine(), mark, "/fp nr stream off stops it")

--------------------------------------------------------------------------------
-- /fp steps nr partygeo (on M)
--------------------------------------------------------------------------------

WoW.tracking[1].active = true
WoW.viewRadius = { [0] = 233.33, [1] = 200, [2] = 166.67, [3] = 133.33, [4] = 100, [5] = 66.67 }
Minimap._zoom = 4
WoW.pos, WoW.speed = { 300.5, 400.25, 1 }, 0
fp("steps nr partygeo")
local function g(i) return rec("partygeo").results[i] or {} end
tick(1.2)
eq(g(1).status, nil, "geo: waits while a gathering tracking is on")
WoW.tracking[1].active = false
tick(1.2)
eq(g(1).status, "done", "...tracking off: " .. tostring(g(1).detail))
S.Answer(true)                                             -- 2: standing still
tick(3)
eq(g(3).status, "done", "still: " .. tostring(g(3).detail))
eq(count("geo still #%d"), 8, "...eight samples")
l = logged("geo still #8")
check(l:find("UnitPosition (300.50, 400.25, 0.00, inst 1)", 1, true), "...UnitPosition's four returns: " .. l)
check(l:find("speed 0.00", 1, true) and l:find("GetViewRadius 100.00", 1, true), "...the speed and the view radius")
check(l:find("Minimap %d+%.%d+ x %d+%.%d+, zoom 4"), "...the minimap's size and zoom")
check(l:find("Scan.Where", 1, true) and l:find("1411", 1, true), "...Scan.Where's table")
local t1s = logged("geo still #1"):match("^([%d%.]+)")
local t2s = logged("geo still #2"):match("^([%d%.]+)")
check(math.abs((t2s - t1s) - 0.25) < 0.06, "...a quarter second apart")
WoW.speed, WoW.pos = 14, { 330.5, 400.25, 1 }
S.Answer(true)                                             -- 4: riding
tick(3)
l = logged("geo riding #8")
check(l and l:find("speed 14.00", 1, true) and l:find("330.50", 1, true), "riding: the speed and the moved position")
Minimap._zoom = 5
S.Answer(true)
tick(3)
l = logged("geo zoomin #8")
check(l and l:find("zoom 5", 1, true) and l:find("GetViewRadius 66.67", 1, true), "zoomed in: the zoom and the radius")
Minimap._zoom = 0
S.Answer(true)
tick(3)
l = logged("geo zoomout #8")
check(l and l:find("zoom 0", 1, true) and l:find("GetViewRadius 233.33", 1, true), "zoomed out")
S.Answer(true)
tick(3)
check(logged("geo outdoors #8"), "outdoors sampled")
WoW.instanced = true
S.Answer(true)
tick(3)
l = logged("geo indoors #8")
check(l and l:find("Scan.Where nil (IsInInstance true, rotateMinimap 0", 1, true), "indoors: Scan.Where nil, and why: " .. tostring(l))
WoW.instanced = false
S.Answer(true)
tick(3)
check(logged("geo outdoors2 #8"), "back outdoors sampled")
eq(rec("partygeo").at, 16, "...waiting for the reload")
fp("steps stop")

--------------------------------------------------------------------------------
-- /fp steps nr partyplate (on M)
--------------------------------------------------------------------------------

WoW.plates = {
    { unit = "nameplate1", name = "Silverleaf", object = true, soft = true },
    { unit = "nameplate2", name = "Mottled Boar" },
}
local function cvars() return WoW.cvars.softTargetInteract, WoW.cvars.SoftTargetIconGameObject, WoW.cvars.SoftTargetInteractRange end
local function original(msg)
    local a, b, c = cvars()
    eq(a .. "," .. b .. "," .. c, "1,0,10.000000", msg)
end
local function claimed(msg)
    local a, b, c = cvars()
    eq(a .. "," .. b .. "," .. c, "3,1,60", msg)
end
local function p(i) return rec("partyplate").results[i] or {} end
WoW.combat = true
fp("steps nr partyplate")
tick(1.2)
eq(p(1).status, nil, "partyplate: waits out of combat")
original("...the CVars untouched in combat")
WoW.combat = false
tick(1.2)
eq(p(1).status, "done", "set up: " .. tostring(p(1).detail))
claimed("...the three CVars claimed")
check(tostring(p(1).detail):find("SoftTargetInteractRange 10.000000 -> 60", 1, true), "...each read back")
eq(WoW.cvars.SoftTargetNameplateInteract, nil, "...and no other CVar touched")
S.Answer(true)                                             -- 2
tick(0.2)
eq(p(3).status, "done", "the plates: " .. tostring(p(3).detail))
check(tostring(p(3).detail):find("2 plates:", 1, true), "...every plate")
check(logged("nameplate1 name \"Silverleaf\", UnitIsGameObject true, UnitIsUnit%(softinteract%) true"),
    "...a herb: name, game object, the soft target")
check(logged("nameplate2 name \"Mottled Boar\", UnitIsGameObject false, UnitIsUnit%(softinteract%) false"),
    "...a creature: not")
check(tostring(p(3).detail):find("UnitExists(softinteract) true", 1, true), "...UnitExists(softinteract)")
settle()
check((WoW.shots or 0) >= 1, "...a screenshot taken")
S.Answer(false)                                            -- 4
tick(0.6)
eq(p(5).status, "done", "put back: " .. tostring(p(5).detail))
original("...the summary puts the CVars back")
eq(NodeRadarProbeDB.partyplate.saved, nil, "...nothing left pending")
fp("steps stop")

-- Every other way out puts them back.
fp("steps nr partyplate")
tick(1.2)
claimed("a second run claims again")
fp("steps stop")
tick(1)
original("Stop puts them back")

fp("steps nr partyplate")
tick(1.2)
claimed("a third run")
fp("steps nr partygeo")                                    -- another procedure started
tick(1)
original("another procedure started puts them back")
fp("steps stop")

fp("steps nr partyplate")
tick(1.2)
claimed("a fourth run")
reload(T.session() + 1)                                    -- a reload keeps the claim pending, then Stop
S.Resume()
claimed("a reload leaves them while the procedure goes on")
check(NodeRadarProbeDB.partyplate.saved ~= nil, "...still pending in the saved data")
fp("steps stop")
tick(1)
original("...and a Stop after the reload puts them back")

fp("steps nr partyplate")
tick(1.2)
WoW.cvars.SoftTargetInteractRange = "45"                   -- the player's own change
fp("steps stop")
tick(1)
eq(WoW.cvars.softTargetInteract .. "," .. WoW.cvars.SoftTargetIconGameObject, "1,0", "the player's change: the others put back")
eq(WoW.cvars.SoftTargetInteractRange, "45", "...theirs kept")
check(logged("left as you changed them: SoftTargetInteractRange"), "...and said so")
WoW.cvars.SoftTargetInteractRange = "10.000000"

fp("steps nr partyplate")
tick(1.2)
claimed("a sixth run")
WoW.combat = true
fp("steps stop")
tick(1)
claimed("in combat the put-back waits")
WoW.combat = false
tick(1)
original("...and is done when the fight ends")

--------------------------------------------------------------------------------

eq(errors(), 0, "no step threw, nothing logged as an error")
for _, line in ipairs(WoW.chat) do
    check(not line:find("party") and not line:find("RX ") and not line:find("TX "), "nothing of the probe in chat: " .. line)
end
done("test_probe_party")
