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

function API.Gamepad() return GetCVarBool("GamePadEnable") == true end
