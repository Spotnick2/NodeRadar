-- Track.lua: which herbs and ores the player follows (#47, docs/PLAN.md,
-- "Choosing which herbs and ores").
--
-- One choice per item (several nodes give one: Small, Rich and the Ooze
-- Covered Thorium Veins all give Thorium Ore), saved by item ID for this
-- character, every item tracked until unchecked. Smart, on by default, edits
-- the list as the base rank crosses a line: an item is checked when the skill
-- reaches it, unchecked when it turns grey; the player's own clicks stand in
-- between.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Track = {}
NR.Track = Track

Track.KINDS = { "herbs", "ore" }
Track.GREY = 100      -- skill past a node's requirement where it turns grey (no skill-up)

local lists           -- [kind] = rows sorted by lowest requirement, built once a session

-- The per-character table (NodeRadarCharDB.track), made and cleaned at load:
-- { ignored = { [itemID] = true }, smart = nil | boolean, last = { [kind] = rank } }.
function Track.Load()
    local c = NR.charDb
    local t = type(c.track) == "table" and c.track or {}
    c.track = t
    local ignored = {}
    if type(t.ignored) == "table" then
        for k, v in pairs(t.ignored) do
            if type(k) == "number" and v == true then ignored[k] = true end
        end
    end
    t.ignored = ignored
    if type(t.smart) ~= "boolean" then t.smart = nil end
    local last = {}
    if type(t.last) == "table" then
        for _, kind in ipairs(Track.KINDS) do
            if type(t.last[kind]) == "number" then last[kind] = t.last[kind] end
        end
    end
    t.last = last
    lists = nil
end

local function state() return NR.charDb and NR.charDb.track end

-- One kind's items from NODE_INFO for the client's language (the kind from
-- LIBRARY): { item, kind, nodes = { { name, skill } } by skill, low, high }.
function Track.List(kind)
    if not lists then
        lists = { herbs = {}, ore = {} }
        local l = GetLocale()
        local info, lib = NR.NODE_INFO and NR.NODE_INFO[l], NR.LIBRARY and NR.LIBRARY[l]
        local byItem = {}
        for name, e in pairs(info or {}) do
            local k = lib and lib[name]
            local item, skill = API.Num(e.item), API.Num(e.skill)
            if lists[k] and item and skill then
                local row = byItem[item]
                if not row then
                    row = { item = item, kind = k, nodes = {} }
                    byItem[item] = row
                    table.insert(lists[k], row)
                end
                row.nodes[#row.nodes + 1] = { name = name, skill = skill }
            end
        end
        for _, k in ipairs(Track.KINDS) do
            for _, row in ipairs(lists[k]) do
                table.sort(row.nodes, function(a, b)
                    if a.skill ~= b.skill then return a.skill < b.skill end
                    return a.name < b.name
                end)
                row.low, row.high = row.nodes[1].skill, row.nodes[#row.nodes].skill
            end
            table.sort(lists[k], function(a, b)
                if a.low ~= b.low then return a.low < b.low end
                return a.item < b.item
            end)
        end
    end
    return lists[kind] or {}
end

-- The base rank in a kind's skill line (gear moves only the modifier), or nil.
function Track.Rank(kind)
    return API.Skill(NR.Alert.SKILL_LINES[kind], true)
end

-- An item at a rank: "low" (none of its nodes gatherable yet), "up" (skill-ups),
-- "grey" (every node of it grey), or nil without a rank.
function Track.State(row, rank)
    if not rank then return nil end
    if rank < row.low then return "low" end
    if rank >= row.high + Track.GREY then return "grey" end
    return "up"
end

function Track.Ignored(item)
    local t = state()
    return t ~= nil and t.ignored[item] == true
end

function Track.Smart()
    local t = state()
    return t ~= nil and t.smart ~= false
end

-- The item's name once the client has it, else nil.
function Track.ItemName(row)
    local f = C_Item and C_Item.GetItemNameByID
    if type(f) ~= "function" then return nil end
    local ok, name = pcall(f, row.item)
    if ok and type(name) == "string" and not API.IsSecret(name) and name ~= "" then return name end
end

-- A row by an item ID, or a node's or the item's name (any case); nothing for
-- empty text, and an item's name only once the client has it (Codex, PR #53:
-- an uncached name read as "" matched a bare /nr track).
function Track.Find(text)
    local id, want = tonumber(text), (text or ""):lower()
    if want == "" then return nil end
    for _, kind in ipairs(Track.KINDS) do
        for _, row in ipairs(Track.List(kind)) do
            local itemName = Track.ItemName(row)
            if row.item == id or (itemName and itemName:lower() == want) then return row end
            for _, n in ipairs(row.nodes) do
                if n.name:lower() == want then return row end
            end
        end
    end
end

-- The choices changed: what NodeRadar draws and points at follows at once,
-- and an open page re-reads.
local function changed()
    NR.Icons.Refilter()
    NR.Compass.Refresh()
    if Track.onChanged then Track.onChanged() end
end

-- A kind's items set by a preset at a rank: "all", "none", "gather" (those
-- gatherable), "skillups" (those giving skill-ups). No change made yet.
local function apply(kind, which, rank)
    local ignored = state().ignored
    for _, row in ipairs(Track.List(kind)) do
        local s = Track.State(row, rank)
        local on = which == "all" or (which == "gather" and (s == "up" or s == "grey"))
                   or (which == "skillups" and s == "up")
        ignored[row.item] = (not on) or nil
    end
end

-- The player's checkbox.
function Track.Set(item, on)
    local t = state()
    if not t then return end
    t.ignored[item] = (not on) or nil
    changed()
end

-- A preset button. False when it needs a rank and there's none.
function Track.Preset(kind, which)
    local rank = Track.Rank(kind)
    if (which == "gather" or which == "skillups") and not rank then return false end
    apply(kind, which, rank)
    changed()
    return true
end

-- Smart (#47): each kind with a rank, at each sweep and SKILL_LINES_CHANGED.
-- No `last` (smart just on, a first login) or a rank gone down (unlearned and
-- learned again): Skill-ups only. A rise: each item it reached checked, then
-- each it turned grey unchecked; nothing else touched.
function Track.Follow()
    if not Track.Smart() then return false end
    local t, any = state(), false
    for _, kind in ipairs(Track.KINDS) do
        local rank = Track.Rank(kind)
        local last = t.last[kind]
        if rank and (not last or rank < last) then
            apply(kind, "skillups", rank)
            any = true
        elseif rank and rank > last then
            for _, row in ipairs(Track.List(kind)) do
                if row.low > last and row.low <= rank then t.ignored[row.item] = nil; any = true end
            end
            for _, row in ipairs(Track.List(kind)) do
                local grey = row.high + Track.GREY
                if grey > last and grey <= rank then t.ignored[row.item] = true; any = true end
            end
        end
        if rank then t.last[kind] = rank end
    end
    if any then changed() end
    return any
end

-- Smart on starts over from Skill-ups only; off leaves the list as it is.
function Track.SetSmart(on)
    local t = state()
    if not t then return end
    t.smart = on
    if on then t.last = {} end
    if not Track.Follow() and Track.onChanged then Track.onChanged() end
end

-- How many items of a kind are skipped.
function Track.Count(kind)
    local n = 0
    for _, row in ipairs(Track.List(kind)) do
        if Track.Ignored(row.item) then n = n + 1 end
    end
    return n
end
