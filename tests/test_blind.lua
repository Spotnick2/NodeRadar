-- #90: from client build 70862 the minimap's mouseover follows only the real
-- cursor, so a sweep reads nothing. No sweep runs (no soft cursor for nothing),
-- chat says why once per account and build while the radar is on, and /nr and
-- the Options page say it too. Before 70862 nothing changes.

-- A fresh client on `build`, with these saved settings: the stubs loaded again
-- and the addon from scratch, so each case starts clean (a reload, or another build).
dofile("tests/harness.lua")   -- once: its pass and fail counts carry across the cases
local function fresh(build, db)
    dofile("tests/wow_stubs.lua")
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

-- An unreadable build isn't blind.
NR = fresh("70862", {})
local real = GetBuildInfo
GetBuildInfo = function() error("no") end
check(not NR.API.Blind(), "an unreadable build: not blind")
GetBuildInfo = real

done("test_blind")
