-- The icons procedure (/fp steps nr icons, #28): every NODE_INFO item's icon,
-- cached or not; a node blip's hit area sampled every unit (a square, a disc;
-- its centre and box marked on the minimap) at two zooms; the raw text of a
-- node above and below the player; two nodes of a name side by side, one at
-- the rim. Runs locally only (ForeverProbe is private; CI skips it).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

rawset(_G, "Screenshot", function() WoW.shots = (WoW.shots or 0) + 1 end)
rawset(_G, "EnumerateFrames", function() return nil end)

WoW.tracking[1].active = true
local NR = loadAddon()
NR.db.enabled = false                                      -- the probe sweeps; the radar stays out of it
NR.db.learned.enUS = NR.db.learned.enUS or {}
NR.db.learned.enUS["Copper Vein"] = { kind = "ore", source = "toggle" }
local FP = loadForeverProbe()
local T = loadProbe()._test
local S = FP.Steps
local db = NodeRadarProbeDB

local function logged(pattern)
    for i = #db.log, 1, -1 do if db.log[i]:find(pattern) then return db.log[i] end end
end
local function errors()
    local n = 0
    for _, l in ipairs(db.log) do if l:find("ERROR") then n = n + 1 end end
    return n
end
local function fp(cmd) SlashCmdList.FOREVERPROBE(cmd) end
local function poll() WoW.advance(1.1) end
local function settle()
    for _ = 1, 30 do
        WoW.advance(0.5)
        WoW.fire("SCREENSHOT_SUCCEEDED")
    end
end
local function record() return FP.db.steps.records["NodeRadarProbe/icons"] end
local function result(i) return record().results[i] or {} end
local function detail(i) return tostring(result(i).detail or result(i).lastError) end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 0.5) end
local function area(label, name)
    for _, a in ipairs(db.icons.areas or {}) do
        if a.label == label then
            for _, m in ipairs(a.blips) do if m.name == name then return m end end
        end
    end
end
local function markAt(x, y)
    for _, f in ipairs(T.marks) do
        local p = f._points[#f._points]
        if f._shown and p and p[2] == Minimap and near(p[4], x) and near(p[5], y) then return f end
    end
end

-- Items: some cached, the rest not.
local items, cachedCount = {}, 0
for _, v in pairs(NR.NODE_INFO.enUS) do
    if v.item and not items[v.item] then
        items[v.item] = true
        if cachedCount < 3 then WoW.itemCached[v.item] = true; cachedCount = cachedCount + 1 end
    end
end
local itemCount = 0
for _ in pairs(items) do itemCount = itemCount + 1 end

-- A herb's square and an ore's disc.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" }, { "Copper Vein", -40, 30, half = 9, disc = true } }

fp("steps nr icons")
poll()
eq(result(1).status, "done", "ready")
eq(result(2).status, "done", "items read: " .. detail(2))
local it = db.icons.items
eq(it.items, itemCount, "every distinct item")
eq(it.cached, cachedCount, "...the cached counted")
eq(it.uncached, itemCount - cachedCount, "...the uncached")
eq(it.icon, cachedCount, "GetItemIconByID's answers counted")
eq(it.uncachedIcon, 0, "...none for the uncached (the stub's model)")
eq(it.instant, itemCount, "GetItemInfoInstant's icon for every one")
eq(it.differ, 0, "...the same icon as GetItemIconByID's")
eq(#it.examples, 5, "five uncached examples")

-- The first measure.
S.Run()
eq(result(3).status, "done", "measured: " .. detail(3))
local sq, disc = area("first zoom", "Wilted Peacebloom"), area("first zoom", "Copper Vein")
check(sq and disc, "both blips measured")
eq(sq.shape, "square", "the herb's square: " .. table.concat(sq.rows, "/"))
check(sq.w == 17 and sq.h == 17, "...17 units wide: " .. sq.w .. "x" .. sq.h)
eq(sq.corners, 4, "...its corners hit")
check(near(sq.x, 30) and near(sq.y, -20), "...its centre measured: " .. sq.x .. ", " .. sq.y)
eq(sq.groups, 1, "...one group")
eq(#sq.rows, sq.h, "...its rows saved")
eq(sq.rows[1], ("#"):rep(17), "...the top row full")
eq(sq.kind, "herbs", "...its kind")
eq(sq.raw[1], "Wilted Peacebloom", "...the raw text at its centre")
eq(disc.shape, "disc", "the ore's disc: fill " .. disc.fill .. ", corners " .. disc.corners)
check(near(disc.x, -40) and near(disc.y, 30), "...its centre: " .. disc.x .. ", " .. disc.y)
eq(sq.rim or disc.rim, false, "neither at the rim")
check(markAt(30, -20) and markAt(-40, 30), "a mark at each measured centre")
local m = markAt(30, -20)
check(m._width == 17 and m._height == 17 and m._parent == Minimap and m._mouse == false,
    "...the box the hit area's size, a pass-through child of Minimap")
check(logged("hit areas first zoom: zoom 0"), "the measure logged")
S.Answer(true)                                              -- 4
settle()

-- The second zoom: the marks go, the zoom is waited for.
poll()
eq(record().at, 5, "waits for a zoom change")
check(not markAt(30, -20), "the marks hidden")
Minimap._zoom = 2
poll()
eq(result(5).status, "done", "zoomed")
S.Run()
eq(result(6).status, "done", "measured again: " .. detail(6))
check(area("second zoom", "Wilted Peacebloom"), "...saved under its label")
S.Answer(true)                                              -- 7
settle()

-- The position arrows: none, then above, then a different one below.
poll()
eq(record().at, 8, "waits for a node with an arrow")
local ARROW = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:32:32:0:16:%s|t"
WoW.blips[1].text = ARROW:format("0:16") .. "Wilted Peacebloom"
poll()
eq(result(8).status, "done", "above: " .. detail(8))
check(db.icons.arrows.above.tex:find("PositionArrows:0:0:0:0:32:32:0:16:0:16$"), "...the texture kept whole")
eq(db.icons.arrows.above.raw, WoW.blips[1].text, "...and the raw text")
poll()
eq(record().at, 9, "below: the same arrow isn't taken")
WoW.blips[1].text = ARROW:format("16:32") .. "Wilted Peacebloom"
poll()
eq(result(9).status, "done", "below: " .. detail(9))
check(db.icons.arrows.below.tex:find("16:32$"), "...its own texture")
check(logged('arrow below: Wilted Peacebloom, raw'), "...logged")

-- Two of a name side by side, and one at the rim.
WoW.blips = { { "Wilted Peacebloom", 20, -20, kind = "herbs" }, { "Wilted Peacebloom", 44, -20, kind = "herbs" },
              { "Silverleaf", 93, 0, kind = "herbs" } }
S.Run()
eq(result(10).status, "done", "measured the extra: " .. detail(10))
local pair, rim = area("extra", "Wilted Peacebloom"), area("extra", "Silverleaf")
eq(pair and pair.groups, 2, "the pair: two groups")
eq(pair and pair.w, 17, "...the one measured is one node wide")
eq(rim and rim.rim, true, "the rim node is at the rim")
S.Answer(true)                                              -- 11
settle()
eq(record().at, 12, "at the reload")
fp("steps stop")
eq(errors(), 0, "no step threw")

-- Three herbs and an ore: the ore is among the three measured.
WoW.blips = { { "Wilted Peacebloom", 20, -60, kind = "herbs" }, { "Silverleaf", -20, -60, kind = "herbs" },
              { "Stunted Silverleaf", 40, -30, kind = "herbs" }, { "Copper Vein", -40, 60, half = 9, disc = true } }
local sweep = NR.Scan.Sweep
NR.Scan.Sweep = function(...)                              -- the ore last (the sweep's order follows a hash)
    local r = sweep(...)
    local last = function(b) return b.name == "Copper Vein" and 1 or 0 end
    table.sort(r.blips, function(a, b) return last(a) < last(b) end)
    return r
end
fp("steps nr icons")
poll()
S.Run()
NR.Scan.Sweep = sweep
eq(result(3).status, "done", "measured four: " .. detail(3))
eq(#db.icons.areas[1].blips, 3, "three at most")
check(area("first zoom", "Copper Vein"), "...the ore among them, though swept last")
fp("steps stop")

-- No node: the measure says what it saw.
WoW.blips = { { "Carry Your Weight", -40, 40 } }
fp("steps nr icons")
poll()
S.Run()
check(detail(3):find("saw: Carry Your Weight"), "no node: what was seen: " .. detail(3))
fp("steps stop")

eq(#WoW.chat, 0, "nothing in chat")
eq(WoW.softCursor, false, "the soft cursor is off")

done("test_probe_icons")
