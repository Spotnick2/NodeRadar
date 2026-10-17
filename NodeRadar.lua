-- NodeRadar.lua: bootstrap, saved settings, the radar loop, /nr.
--
-- While Find Herbs or Find Minerals is on, the radar sweeps the minimap every
-- half second (Scan), tells the gathering nodes from the other blips (Learn)
-- and pings when a new one comes into range (Alert). docs/PLAN.md has the
-- design, docs/FOREVER-PROBE.md what it rests on.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API, Scan, Learn, Alert = NR.API, NR.Scan, NR.Learn, NR.Alert

local ADDON_NAME = ...

local DEFAULTS = {
    enabled  = true,
    sound    = true,    -- MAP_PING
    ring     = true,    -- a ring on the new node's blip
    chat     = false,   -- a line in chat
    ping     = false,   -- Blizzard's minimap ping, solo only
    learn    = false,   -- learn unknown names by turning tracking off and on: off, since
                        -- turning it back on costs a global cooldown (release check, 70450)
    cooldown = 5,       -- seconds between alerts
    interval = 2,       -- seconds between sweeps standing still; moving, NR.Interval adapts it
    ringR = 0.2, ringG = 1.0, ringB = 0.4,
}
-- v1's settings (it never worked on Forever): dropped.
local V1_KEYS = { "soundEnabled", "pingEnabled", "chatAlert", "mountedOnly", "scanInterval", "soundID",
                  "pingColorR", "pingColorG", "pingColorB" }

NR.DEFAULTS = DEFAULTS

local function initDB()
    if type(NodeRadarDB) ~= "table" then NodeRadarDB = {} end
    local db = NodeRadarDB
    for _, k in ipairs(V1_KEYS) do db[k] = nil end
    -- Only what the player set is saved; the rest reads the defaults, so a
    -- default can change in a later version.
    setmetatable(db, { __index = DEFAULTS })
    if type(db.learned) ~= "table" then db.learned = {} end
    NR.db = db
    Learn.CleanNames()
    if type(NodeRadarCharDB) ~= "table" then NodeRadarCharDB = {} end
    NR.charDb = NodeRadarCharDB
end

--------------------------------------------------------------------------------
-- The radar
--------------------------------------------------------------------------------

local lastGeometry
local elapsed = 0

local function sameGeometry(a, b)
    return a and b and math.abs(a.w - b.w) < 0.5 and math.abs(a.h - b.h) < 0.5 and math.abs(a.es - b.es) < 0.001
end

-- One radar sweep, when everything allows it.
function NR.Step(now)
    local db = NR.db
    if not (db and db.enabled) or Learn.Busy() or Learn.loading or API.Gamepad() then return end
    local ok, shown = pcall(Minimap.IsVisible, Minimap)
    if not (ok and API.Yes(shown)) then return end
    if not Learn.AnyOn() then return end
    local result = Scan.Sweep()
    if not result then return end
    if lastGeometry and not sameGeometry(lastGeometry, result.geometry) then Alert.Reset() end
    lastGeometry = result.geometry
    Alert.Update(result, now)
    Learn.Consider(result, now)
    return result
end

-- Seconds until the next sweep, from the movement speed (the owner, release
-- check): about YARDS of movement between sweeps, so 0.29 s at 100% (7 yd/s),
-- 0.48 s at 60%, 0.71 s at 40%; never faster than FASTEST; standing still,
-- db.interval (nothing on the map moves but a spawn).
NR.YARDS, NR.FASTEST = 2, 0.2
function NR.Interval()
    local idle = NR.db.interval
    local speed = API.Speed()
    if not speed or speed <= 0 then return idle end
    return math.max(NR.FASTEST, math.min(idle, NR.YARDS / speed))
end

local radar = CreateFrame("Frame")
radar:SetScript("OnUpdate", function(_, dt)
    if not NR.db then return end
    local now = GetTime()
    Learn.Tick(now)
    elapsed = elapsed + (dt or 0)
    if elapsed < NR.Interval() then return end
    elapsed = 0
    NR.Step(now)
end)

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
API.RegisterEvents(events, { "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED", "PLAYER_DEAD", "MINIMAP_UPDATE_ZOOM",
    "MINIMAP_UPDATE_TRACKING" })
API.RegisterUnitEvent(events, "UNIT_SPELLCAST_SENT", "player")
events:SetScript("OnEvent", function(_, event, ...)
    local now = GetTime()
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then initDB() end
        return
    end
    if not NR.db then return end
    if event == "PLAYER_ENTERING_WORLD" then
        Learn.loading = false
        Alert.NewArea(now)
        Learn.Resume(now)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Alert.NewArea(now)
        Learn.Void("the zone changed")
    elseif event == "LOADING_SCREEN_ENABLED" then
        Learn.loading = true
        Learn.Void("a loading screen")
    elseif event == "LOADING_SCREEN_DISABLED" then
        Learn.loading = false
        Learn.Resume(now)
    elseif event == "PLAYER_DEAD" then
        Learn.Void("the player died")
    elseif event == "MINIMAP_UPDATE_ZOOM" then
        Alert.Reset()
        Learn.Void("the zoom changed")
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        Alert.Reset()
        Learn.OnTrackingChanged()
    elseif event == "UNIT_SPELLCAST_SENT" then
        Learn.OnCastSent(...)
    end
end)

--------------------------------------------------------------------------------
-- /nr
--------------------------------------------------------------------------------

local function onOff(v) return v and "|cff00ff00on|r" or "|cffff4444off|r" end

local TOGGLES = { sound = "sound", ring = "ring on the map", chat = "chat line",
                  ping = "Blizzard's ping (solo only)", learn = "learning by turning tracking off and on" }

local function status()
    local db = NR.db
    API.Say("radar " .. onOff(db.enabled) .. "; sound " .. onOff(db.sound) .. ", ring " .. onOff(db.ring)
        .. ", chat " .. onOff(db.chat) .. ", Blizzard's ping " .. onOff(db.ping) .. "; learning " .. onOff(db.learn)
        .. "; " .. db.cooldown .. " s between alerts")
    local on = {}
    for _, t in ipairs(Learn.Trackings()) do if t.active then on[#on + 1] = t.kind end end
    API.Say("gathering tracking on: " .. (#on > 0 and table.concat(on, ", ") or "none (turn on Find Herbs or Find Minerals)"))
    local nodes, others = 0, 0
    for _, e in pairs(db.learned[GetLocale()] or {}) do
        if e.kind then nodes = nodes + 1 else others = others + 1 end
    end
    local lib = 0
    for _ in pairs(NR.LIBRARY and NR.LIBRARY[GetLocale()] or {}) do lib = lib + 1 end
    API.Say(("known: %d nodes and %d other names learned here, %d nodes shipped (%s)"):format(nodes, others, lib, GetLocale()))
    local version, build = GetBuildInfo()
    local running = version .. "." .. build
    if running ~= NR.MEASURED_ON_BUILD then
        API.Say("measured on " .. NR.MEASURED_ON_BUILD .. "; you're on " .. running .. ": report anything odd")
    end
end

local function known()
    local list = {}
    for name, e in pairs(NR.db.learned[GetLocale()] or {}) do
        list[#list + 1] = ("%s: %s (%s)"):format(name, e.kind or "not a node", e.source or "?")
    end
    table.sort(list)
    if #list == 0 then API.Say("nothing learned yet") end
    for _, line in ipairs(list) do API.Say(line) end
end

local function help()
    API.Say("/nr: radar on or off")
    API.Say("/nr sound | ring | chat | ping | learn: toggle the sound, the ring, a chat line, Blizzard's ping "
        .. "(solo only), learning by turning tracking off and on")
    API.Say("/nr cd <1-60>: seconds between alerts. /nr test: an alert now. /nr status")
    API.Say("/nr known: the names learned. /nr forget <name>. /nr failures. /nr reset: the settings")
end

SLASH_NODERADAR1 = "/noderadar"
SLASH_NODERADAR2 = "/nr"
SlashCmdList.NODERADAR = function(msg)
    local db = NR.db
    if not db then return end
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        db.enabled = not db.enabled
        Alert.Reset()
        API.Say("radar " .. onOff(db.enabled))
    elseif TOGGLES[cmd] then
        db[cmd] = not db[cmd]
        API.Say(TOGGLES[cmd] .. " " .. onOff(db[cmd]))
    elseif cmd == "cd" then
        local secs = tonumber(rest)
        if secs and secs >= 1 and secs <= 60 then
            db.cooldown = secs
            API.Say(secs .. " s between alerts")
        else
            API.Say("/nr cd <1-60>")
        end
    elseif cmd == "test" then
        Alert.Test()
    elseif cmd == "status" then
        status()
    elseif cmd == "known" then
        known()
    elseif cmd == "forget" then
        if rest == "" then
            API.Say("/nr forget <name>, as /nr known shows it")
        else
            Learn.Forget(rest)
            API.Say("forgot " .. rest)
        end
    elseif cmd == "failures" then
        local any = false
        for key, f in pairs(NR.failures) do
            any = true
            API.Say(("%s: %s (x%d)"):format(key, f.err, f.count))
        end
        if not any then API.Say("no failures") end
    elseif cmd == "reset" then
        for k in pairs(DEFAULTS) do db[k] = nil end
        API.Say("settings reset (learned names kept)")
    else
        help()
    end
end
