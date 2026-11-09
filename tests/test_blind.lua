-- #90: from client build 70862 the minimap's mouseover follows only the real
-- cursor, so a sweep reads nothing. No sweep runs (no soft cursor for nothing),
-- chat says why once per account and build while the radar is on, and /nr and
-- the Options page say it too. Before 70862 nothing changes.

-- A fresh client on `build`, with these saved settings: the stubs loaded again
-- and the addon from scratch, so each case starts clean (a reload, or another build).
-- WowTestKit keeps its pass and fail counts in the stubs' own load, so loading them again
-- starts them at 0: each case's earlier counts are carried over by replaying them, and
-- the harness (whose done() wraps the kit's) is loaded again on top.
local function fresh(build, db)
    local passed, failed = 0, 0
    if Kit then passed, failed = Kit.counts() end
    dofile("tests/wow_stubs.lua")
    dofile("tests/harness.lua")
    for _ = 1, passed do check(true) end
    for _ = 1, failed do check(false, "(an earlier case's failure, carried over)") end
    NodeRadar, NodeRadarDB, NodeRadarCharDB = nil, nil, nil
    WoW.build = build
    WoW.tracking[1].active = true
    local NR = loadAddon({ db = db })
    NR.db.learn = false
    return NR
end

local function count(pattern)
    local n = 0
    for _, line in ipairs(WoW.chat) do if line:find(pattern, 1, true) then n = n + 1 end end
    return n
end

-- Reads of the minimap and soft-cursor calls over a stretch of time.
local function readsIn(seconds)
    local reads, soft = 0, 0
    local real, realSoft = C_TooltipInfo.GetMinimapMouseover, Minimap.SetUsingSoftCursor
    C_TooltipInfo.GetMinimapMouseover = function(...) reads = reads + 1; return real(...) end
    Minimap.SetUsingSoftCursor = function(...) soft = soft + 1; return realSoft(...) end
    WoW.advance(seconds, 0.1)
    C_TooltipInfo.GetMinimapMouseover, Minimap.SetUsingSoftCursor = real, realSoft
    return reads, soft
end

-- 70862: blind.
local saved = {}
local NR = fresh("70862", saved)
local TEXT = "can't find nodes"
check(NR.API.Blind(), "70862: blind")
eq(count(TEXT), 1, "said once in chat at login")
eq(saved.blindNotice, 70862, "...remembered for this build, in the account's settings")
local reads, soft = readsIn(10)
eq(reads, 0, "no sweep reads the minimap")
eq(soft, 0, "...nor turns the soft cursor on")
eq(NR.Step(GetTime()), nil, "a step does nothing")

SlashCmdList.NODERADAR("status")
eq(count(TEXT), 2, "/nr says it")

NR.Options._test.panel:Show()
local function pageSays(text)
    for _, r in ipairs({ NR.Options._test.page:GetRegions() }) do
        if type(r._text) == "string" and r._text:find(text, 1, true) then return true end
    end
    return false
end
local shown = pageSays("The radar can't see nodes")
check(shown, "the Options page says it")

-- A reload on the same build: not again.
NR = fresh("70862", saved)
eq(count(TEXT), 0, "a reload on the same build: not said again")

-- A newer build: said again, once.
NR = fresh("70901", saved)
eq(count(TEXT), 1, "a newer build: said again")
eq(saved.blindNotice, 70901, "...and remembered")

-- The radar off: nothing said (nothing to explain), and nothing remembered.
local off = { enabled = false }
NR = fresh("70862", off)
eq(count(TEXT), 0, "radar off: not said")
eq(off.blindNotice, nil, "...nor remembered, so turning it on can still say it at the next login")

-- Before 70862: as before.
NR = fresh("70790", {})
check(not NR.API.Blind(), "70790: not blind")
eq(count(TEXT), 0, "nothing said")
reads = readsIn(10)
check(reads > 0, "the radar sweeps")
NR.Options._test.panel:Show()
check(not pageSays("can't see nodes"), "the Options page says nothing of it")

-- #95: what the toggle experiment learned from 70862 on is dropped at load, every
-- locale, "not a node" too, whatever build the client is on now; a gathering's
-- evidence and older entries stay.
local learned = {
    enUS = {
        ["Karuzo Macphisto"] = { kind = "herbs", source = "toggle", build = "70862" },  -- the owner's
        ["The Missing Shipment"] = { kind = "herbs", source = "toggle", build = "70862" },
        ["- 2/6 Roiling Winds destroyed"] = { kind = false, source = "toggle", build = "70901" },
        ["Earthroot"] = { kind = "herbs", source = "gather", build = "70862" },        -- gathered: kept
        ["Copper Vein"] = { kind = "ore", source = "toggle", build = "70840" },        -- before: kept
        ["Odd"] = { kind = "herbs", source = "toggle", build = "beta" },               -- no number: kept
    },
    deDE = { ["Karuzo Macphisto"] = { kind = "herbs", source = "toggle", build = "70862" } },
}
NR = fresh("70790", { learned = learned })
local en, de = NR.db.learned.enUS, NR.db.learned.deDE
eq(en["Karuzo Macphisto"], nil, "a party member the toggle learned on 70862: dropped")
eq(en["The Missing Shipment"], nil, "...a quest: dropped")
eq(en["- 2/6 Roiling Winds destroyed"], nil, "...a 'not a node' from a later build: dropped")
eq(de["Karuzo Macphisto"], nil, "...in every locale")
check(en["Earthroot"] ~= nil, "a gathering's evidence from 70862: kept")
check(en["Copper Vein"] ~= nil, "the toggle's answer from before 70862: kept")
check(en["Odd"] ~= nil, "a build that isn't a number: kept")
eq(NR.Learn.Kind("Karuzo Macphisto"), nil, "the party member is no node any more")

-- An unreadable build isn't blind.
NR = fresh("70862", {})
local real = GetBuildInfo
GetBuildInfo = function() error("no") end
check(not NR.API.Blind(), "an unreadable build: not blind")
GetBuildInfo = real

done("test_blind")
