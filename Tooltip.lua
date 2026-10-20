-- Tooltip.lua: the skill a node needs in the minimap's tooltip (#62,
-- docs/PLAN.md "The skill in the minimap's tooltip").
--
-- While the cursor is on the minimap the client rebuilds GameTooltip every
-- frame from C_TooltipInfo.GetMinimapMouseover (Minimap_OnUpdate ->
-- SetMinimapMouseover, FrameXML 70450): the lines cleared, the data's lines,
-- then TooltipDataProcessor's post-calls for its type. Ours adds one line per
-- known node, "Requires Herbalism (15)", coloured by difficulty. It only adds
-- lines: the data the sweep reads is never touched.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Tooltip = {}
NR.Tooltip = Tooltip

Tooltip.TYPE = 21      -- Enum.TooltipDataType.MinimapMouseover, as measured (docs/FOREVER-PROBE.md)
Tooltip.SKILL_NAMES = { herbs = "Herbalism", ore = "Mining" }   -- shown only when the client's can't be read
local RED = "ffff2020"

local failed = false   -- a failure is recorded once, never per frame

-- A kind's skill line: its localized name (else the English one), and the
-- effective rank, false when the character hasn't it, or nil unreadable.
local function skill(kind)
    local line = NR.Alert.SKILL_LINES[kind]
    local rank, why = API.Skill(line)
    if not rank and why ~= "absent" then return nil end
    local name = Tooltip.SKILL_NAMES[kind]
    local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, line)
    if ok and type(info) == "table" and not API.IsSecret(info) then
        local n = info.name
        if not API.IsSecret(n) and type(n) == "string" and n ~= "" then name = n end
    end
    return name, rank or false
end

-- The known node names in the tooltip's data, distinct, in its order; nil when
-- any part of it is secret (no line at all then).
local function nodeNames(data)
    if API.IsSecret(data) or type(data) ~= "table" then return nil end
    local lines = data.lines
    if API.IsSecret(lines) or type(lines) ~= "table" then return nil end
    local list, seen = {}, {}
    for _, line in ipairs(lines) do
        if API.IsSecret(line) then return nil end
        if type(line) == "table" then
            local t = line.leftText
            if API.IsSecret(t) then return nil end
            if type(t) == "string" then
                for row in t:gmatch("[^\n]+") do
                    local name = NR.Scan.Plain(row)
                    local info = NR.Learn.Kind(name) and NR.Learn.Info(name)
                    if info and API.Num(info.skill) and not seen[name] then
                        seen[name] = true
                        list[#list + 1] = { name = name, kind = NR.Learn.Kind(name), skill = info.skill }
                    end
                end
            end
        end
    end
    return list
end

-- The text of a requirement: the client's own when it reads as one.
local function requires(skillName, need)
    local f = rawget(_G, "ITEM_MIN_SKILL")
    if type(f) == "string" and not API.IsSecret(f) and f:find("%%s") and f:find("%%d") then
        local ok, text = pcall(string.format, f, skillName, need)
        if ok then return text end
    end
    return ("%s %d"):format(skillName, need)
end

local function add(tooltip, data)
    local list = nodeNames(data)
    if not list or #list == 0 then return end
    local skills = {}
    for _, n in ipairs(list) do
        if skills[n.kind] == nil then
            local name, rank = skill(n.kind)
            skills[n.kind] = name and { name = name, rank = rank } or false
        end
        local s = skills[n.kind]
        if s then
            local colour = s.rank and NR.TrackOptions.colour(n.skill, s.rank) or RED
            local text = requires(s.name, n.skill)
            if #list > 1 then text = n.name .. ": " .. text end
            tooltip:AddLine(("|c%s%s|r"):format(colour, text))
        end
    end
end

-- The post-call: GameTooltip only, once the settings are loaded and on.
function Tooltip.PostCall(tooltip, data)
    local db = NR.db
    if not (db and db.tooltipSkill) or tooltip ~= GameTooltip then return end
    local ok, err = pcall(add, tooltip, data)
    if not ok and not failed then
        failed = true
        API.Fail("tooltip", err)
    end
end

-- Registered once, at load. Without the processor (another client), nothing.
function Tooltip.Register()
    local proc = rawget(_G, "TooltipDataProcessor")
    if type(proc) ~= "table" or type(proc.AddTooltipPostCall) ~= "function" then return false end
    local enum = rawget(_G, "Enum")
    local types = type(enum) == "table" and enum.TooltipDataType
    local kind = type(types) == "table" and API.Num(types.MinimapMouseover) or Tooltip.TYPE
    local ok, err = pcall(proc.AddTooltipPostCall, kind, Tooltip.PostCall)
    if not ok then API.Fail("tooltip", err) end
    return ok
end

Tooltip._test = { reset = function() failed = false end }
