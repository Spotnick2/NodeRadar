-- Compat.lua: NodeRadar.API, the one route to client calls that can fail,
-- refuse or answer a secret. Loaded first.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = {}
NR.API = API

-- The build docs/FOREVER-PROBE.md was measured on. tests/test_toc.lua holds the
-- same literal: two places that must agree, never derived from each other.
NR.MEASURED_ON_BUILD = "1.60.1.70450"

function API.IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- A number we can do arithmetic on, or nil (missing or secret).
function API.Num(v)
    if type(v) == "number" and not API.IsSecret(v) then return v end
end

-- A plain true; a secret, a nil or an error is not.
function API.Yes(v) return not API.IsSecret(v) and v == true end

-- The one failure recorder: each key once, with a count (/nr failures).
NR.failures = {}
function API.Fail(key, err)
    local f = NR.failures[key]
    if f then
        f.count = f.count + 1
    else
        NR.failures[key] = { err = tostring(err), count = 1 }
    end
end

-- RegisterEvent throws on an unknown name and returns false for a refusal:
-- both are failures, never silent.
function API.RegisterEvents(frame, list)
    local all = true
    for _, event in ipairs(list) do
        local ok, res = pcall(frame.RegisterEvent, frame, event)
        if not ok or res == false then
            API.Fail("event " .. event, ok and "refused" or res)
            all = false
        end
    end
    return all
end

function API.RegisterUnitEvent(frame, event, ...)
    local ok, res = pcall(frame.RegisterUnitEvent, frame, event, ...)
    if not ok or res == false then
        API.Fail("event " .. event, ok and "refused" or res)
        return false
    end
    return true
end

function API.Say(msg) print("|cff00ff00[NodeRadar]|r " .. msg) end

-- The player's speed, or nil when unreadable.
function API.Speed()
    local ok, speed = pcall(GetUnitSpeed, "player")
    return ok and API.Num(speed) or nil
end

function API.Casting()
    return UnitCastingInfo("player") ~= nil or UnitChannelInfo("player") ~= nil
end

function API.Dead() return API.Yes(UnitIsDeadOrGhost("player")) end

-- The Gamepad UI (Options > "Enable Gamepad UI"), read the way Blizzard's own
-- UI reads it (Blizzard_SharedXML/Mainline/InputUtil.lua:11). Not the
-- GamePadEnable CVar: it reads true on a keyboard-and-mouse client with that
-- option off (release check, 70450), which stopped every sweep.
function API.Gamepad()
    local f = InputUtil and InputUtil.IsGamepadUIEnabled
    if type(f) ~= "function" then return false end
    local ok, on = pcall(f)
    return ok and on == true
end

-- A gathering skill with its bonuses (rank + modifier), or nil: the character
-- hasn't the profession, or it's unreadable. Plain on 70450 (#26). With `base`,
-- the rank alone: gear and buffs move only the modifier (#47).
function API.Skill(lineID, base)
    local f = C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID
    if type(f) ~= "function" then return nil end
    local ok, info = pcall(f, lineID)
    if not ok or API.IsSecret(info) or type(info) ~= "table" then return nil end
    local rank, bonus = API.Num(info.rank), API.Num(info.modifier)
    if not rank or (info.modifier ~= nil and not bonus) then return nil end
    if base then return rank end
    return rank + (bonus or 0)
end

-- Cultivation, the Tauren racial: a herb above the skill grows a copy anyone
-- can gather (measured: spell 20552, a 900 s cooldown). Its state is read only
-- on SPELL_UPDATE_COOLDOWN, the one time the client says isOnGCD can be
-- trusted (SpellSharedDocumentation.lua:30; Codex, #26). "cooling" until
-- `cultivationUntil` when that's readable (out of combat), else until the next
-- event; anything unreadable is "unknown", which counts as ready.
API.CULTIVATION = 20552
local cultivation, cultivationUntil = "unknown", nil

function API.KnowsCultivation()
    local f = C_SpellBook and C_SpellBook.IsSpellKnown
    if type(f) ~= "function" then return false end
    local ok, known = pcall(f, API.CULTIVATION)
    return ok and API.Yes(known)
end

function API.OnCooldownUpdate()
    cultivation, cultivationUntil = "unknown", nil
    if not API.KnowsCultivation() then return end
    local f = C_Spell and C_Spell.GetSpellCooldown
    if type(f) ~= "function" then return end
    local ok, cd = pcall(f, API.CULTIVATION)
    if not ok or API.IsSecret(cd) or type(cd) ~= "table" then return end
    local active, gcd = cd.isActive, cd.isOnGCD
    if API.IsSecret(active) or API.IsSecret(gcd) then return end
    if active == false then
        cultivation = "ready"
    elseif active == true and gcd == false then
        cultivation = "cooling"
        local start, duration = API.Num(cd.startTime), API.Num(cd.duration)
        if start and duration then cultivationUntil = start + duration end
    end
end

function API.CultivationReady()
    if not API.KnowsCultivation() then return false end
    if cultivation ~= "cooling" then return true end
    return cultivationUntil ~= nil and GetTime() >= cultivationUntil
end

-- The TOC's version; nil when unreadable.
function API.AddOnVersion(addon)
    local get = C_AddOns and C_AddOns.GetAddOnMetadata
    if not get then return nil end
    local ok, v = pcall(get, addon, "Version")
    if not ok or API.IsSecret(v) or type(v) ~= "string" then return nil end
    return v
end

-- A frame from a template, and whether the template really applied: a missing
-- template doesn't throw, it returns a bare frame, so `proof` names a field
-- the template makes (GlassMail's, from GlassUnitFrames).
function API.SafeFrame(ftype, parent, template, proof)
    local ok, f = pcall(CreateFrame, ftype, nil, parent, template)
    if ok and f then return f, (proof == nil) or f[proof] ~= nil end
    return CreateFrame(ftype, nil, parent), false
end
