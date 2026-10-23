-- NodeRadar.lua: bootstrap, saved settings, the radar loop, /nr.
--
-- While Find Herbs or Find Minerals is on, the radar sweeps the minimap (about
-- every 2 yards moved; Scan), tells the gathering nodes from the other blips (Learn)
-- and pings when a new one comes into range (Alert). docs/PLAN.md has the
-- design, docs/FOREVER-PROBE.md what it rests on.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API, Scan, Learn, Alert, Track, Icons, Compass = NR.API, NR.Scan, NR.Learn, NR.Alert, NR.Track, NR.Icons,
    NR.Compass

local ADDON_NAME = ...

local DEFAULTS = {
    enabled  = true,
    sound    = true,    -- a sound with the alert
    soundKind = "ping", -- which: a key of Alert.SOUNDS (the map ping, the sonar, two FileDataIDs)
    skillOnly = true,   -- alert only for nodes the player's skill can gather (#26)
    icons    = false,   -- the item's icon over each node's dot (#28)
    iconStyle = "auto", -- its frame (#41): auto (glass with Glass MiniMap, else bronze), plain, glass, bronze, yellow (#50)
    iconSize = "medium", -- small, medium or large: Icons.SIZES
    ignoredIcon = "dim", -- a node the player skips (#47), icons on: "dim" (its icon dimmed) or "dot" (Blizzard's)
    compass  = false,   -- experimental (#29): a ring under the character toward the nearest node
    compassSize = "medium", -- its disc: small, medium or large (Compass.SIZES)
    compassLock = false, -- its position locked (#57; else Alt-drag moves it); compassX, compassY: where, nil home
    marker   = false,   -- experimental: distant beacon and nearby stars; softCVars: the
                        -- interact CVars claimed while it's on, to put back (Marker.lua)
    snoozeFor = "session", -- the key binding's snooze (#46): "15", "30", "60" minutes or "session"
    minimapButton = true, -- NodeRadar's minimap button (#46); NodeRadarDB.minimap is LibDBIcon's table
    tooltipSkill = true, -- the skill a node needs, coloured, in the minimap's tooltip (#62)
    ring     = true,    -- the sonar on the new node's blip
    chat     = false,   -- a line in chat
    ping     = false,   -- Blizzard's minimap ping, solo only
    learn    = false,   -- learn unknown names by turning tracking off and on: off, since
                        -- turning it back on costs a global cooldown (release check, 70450)
    cooldown = 5,       -- seconds between alerts
    interval = 2,       -- seconds between sweeps standing still; moving, NR.Interval adapts it
    yards    = 4,       -- moving: about this many yards between sweeps
}
-- Settings no longer used: v1's (it never worked on Forever), and the ring's
-- colour (the sonar is green for herbs, gold for ore). Dropped.
local V1_KEYS = { "soundEnabled", "pingEnabled", "chatAlert", "mountedOnly", "scanInterval", "soundID",
                  "pingColorR", "pingColorG", "pingColorB", "ringR", "ringG", "ringB" }

-- The first port (#9) saved every default, learning on and a 0.5 s interval
-- among them. They're dropped once, so today's defaults apply: a saved value
-- equal to that old default can't be told from one the player chose, and
-- learning costs a global cooldown, so it goes back to off (Codex, PR #10).
local SAVED_DEFAULTS = { enabled = true, sound = true, ring = true, chat = false, ping = false,
                         learn = true, cooldown = 5, interval = 0.5 }
local SCHEMA = 2

NR.DEFAULTS = DEFAULTS

local function initDB()
    if type(NodeRadarDB) ~= "table" then NodeRadarDB = {} end
    local db = NodeRadarDB
    for _, k in ipairs(V1_KEYS) do db[k] = nil end
    if db.schema == nil then
        for k, v in pairs(SAVED_DEFAULTS) do if db[k] == v then db[k] = nil end end
        db.schema = SCHEMA
    end
    -- Only what the player set is saved; the rest reads the defaults, so a
    -- default can change in a later version.
    setmetatable(db, { __index = DEFAULTS })
    if type(db.learned) ~= "table" then db.learned = {} end
    if type(db.minimap) ~= "table" then db.minimap = {} end    -- LibDBIcon's, made once, never replaced (#46)
    NR.db = db
    Learn.CleanNames()
    if type(NodeRadarCharDB) ~= "table" then NodeRadarCharDB = {} end
    NR.charDb = NodeRadarCharDB
    Track.Load()                                    -- which herbs and ores, this character's (#47)
end

--------------------------------------------------------------------------------
-- The radar
--------------------------------------------------------------------------------

local lastGeometry
local elapsed = 0

local function sameGeometry(a, b)
    return a and b and math.abs(a.w - b.w) < 0.5 and math.abs(a.h - b.h) < 0.5 and math.abs(a.es - b.es) < 0.001
end

-- The names the alert counts, so the sweep tells them apart side by side.
local function isNode(name) return Learn.Kind(name) and true or false end

-- One radar sweep, when everything allows it.
function NR.Step(now)
    local db = NR.db
    if not (db and db.enabled) or Learn.Busy() or Learn.loading or API.Gamepad() then return end
    local ok, shown = pcall(Minimap.IsVisible, Minimap)
    if not (ok and API.Yes(shown)) then return end
    if not Learn.AnyOn() then return end
    local result = Scan.Sweep(isNode)
    if not result then return end
    if lastGeometry and not sameGeometry(lastGeometry, result.geometry) then Alert.Reset() end
    lastGeometry = result.geometry
    Track.Follow()                                  -- smart: the list by the skill first (Codex, #47)
    Icons.Update(result, now)                       -- before the alert and the learner (Codex, #28)
    Compass.Reconcile(result, now)                  -- the nearest node, before the learner (#29)
    NR.FarMarker.Update(result)
    Alert.Update(result, now)
    Learn.Consider(result, now)
    -- An experiment just started turns tracking off: whenever the client
    -- delivers MINIMAP_UPDATE_TRACKING, nothing points at a node meanwhile (Codex, #29).
    if Learn.Busy() then Icons.Clear() end
    return result
end

-- Seconds until the next sweep, from the movement speed (the owner, release
-- check): about db.yards of movement between sweeps, by default 4, so 0.57 s
-- at 100% (7 yd/s), 0.95 s at 60%, 1.43 s at 40%; never faster than FASTEST
-- nor slower than standing still; standing still, db.interval (nothing on the
-- map moves but a spawn). 4 yards, not 2: a sweep is garbage to collect (#11),
-- and a node comes in at the map's edge, far off.
NR.FASTEST = 0.5
function NR.Interval()
    local idle = NR.db.interval
    local speed = API.Speed()
    if not speed or speed <= 0 then return idle end
    return math.max(NR.FASTEST, math.min(idle, NR.db.yards / speed))
end

-- A setting changed by the player (the Options page, /nr): saved, and what
-- follows from it done.
function NR.Set(key, value)
    NR.db[key] = value
    if key == "enabled" then Alert.Reset() end
    if key == "enabled" then Icons.Clear() end
    -- The records serve the icons and the compass (#29): each setting does its own part.
    if key == "icons" or key == "compass" or key == "marker" then
        if not Icons.Keeping() then
            Icons.Clear()
        elseif key == "icons" then
            if Icons.On() then Icons.Show() else Icons.Release() end
        elseif not Compass.Choosing() then
            Compass.Reset()
        else
            Compass.Refresh()                       -- the ring shown or hidden, the target kept
        end
    end
    if key == "marker" or key == "enabled" then NR.Marker.Toggle(); NR.FarMarker.Toggle() end
    if key == "iconStyle" or key == "iconSize" then Icons.Restyle() end
    if key == "ignoredIcon" then Icons.Refilter() end
    -- The compass follows the icons' frame (#29), with the icons on or off.
    if key == "iconStyle" or key == "compassSize" then Compass.Restyle() end
    if key == "compassLock" then Compass.UpdateGrip() end
    if key == "minimapButton" then NR.Minimap.Apply() end
end

function NR.VersionText()
    local v = API.AddOnVersion(ADDON_NAME or "NodeRadar")
    if v == nil or v == "" or v == "dev" or v:find("@project%-version@") then return "dev" end
    return v
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
API.RegisterEvents(events, { "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED", "PLAYER_DEAD", "MINIMAP_UPDATE_ZOOM",
    "MINIMAP_UPDATE_TRACKING", "SPELL_UPDATE_COOLDOWN", "SKILL_LINES_CHANGED" })
API.RegisterUnitEvent(events, "UNIT_SPELLCAST_SENT", "player")
API.RegisterUnitEvent(events, "UNIT_SPELLCAST_SUCCEEDED", "player")
local gathering   -- { guid, target }: the gathering cast just sent, until it succeeds

-- The player's zoom (or an addon's) comes through Minimap:SetZoom and resets
-- the alert: zooming out shows many nodes at once. The swap indoors or out
-- fires MINIMAP_UPDATE_ZOOM with no call, so it keeps the history and a node
-- seen on the way out alerts (#63, docs/FOREVER-PROBE.md "Indoors and out").
-- A call to the zoom already set fires nothing and resets nothing.
local zoom = API.Num(Minimap:GetZoom())
hooksecurefunc(Minimap, "SetZoom", function()
    local z = API.Num(Minimap:GetZoom())
    if not z or z ~= zoom then Alert.Reset() end
    zoom = z
end)
events:SetScript("OnEvent", function(_, event, ...)
    local now = GetTime()
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then initDB() end
        return
    end
    if not NR.db then return end
    if event == "PLAYER_LOGIN" then
        NR.Options.Register()
        NR.Minimap.Register()                      -- the button (#46): no libraries, no button
        NR.Tooltip.Register()                      -- the skill in the minimap's tooltip (#62)
    elseif event == "PLAYER_ENTERING_WORLD" then
        Icons.Clear()
        Learn.loading = false
        Alert.NewArea(now)
        Learn.Resume(now)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Alert.NewArea(now)
        Learn.Void("the zone changed")
    elseif event == "LOADING_SCREEN_ENABLED" then
        Icons.Clear()
        Learn.loading = true
        Learn.Void("a loading screen")
    elseif event == "LOADING_SCREEN_DISABLED" then
        Learn.loading = false
        Learn.Resume(now)
    elseif event == "PLAYER_DEAD" then
        Icons.Clear()
        Learn.Void("the player died")
    elseif event == "MINIMAP_UPDATE_ZOOM" then
        zoom = API.Num(Minimap:GetZoom())          -- a swap indoors or out: the history kept (#63)
        if not zoom then Alert.Reset() end
        Learn.Void("the zoom changed")
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        Alert.Reset()
        Icons.Clear()
        Learn.OnTrackingChanged()
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        API.OnCooldownUpdate()                     -- Cultivation's state (#26)
    elseif event == "SKILL_LINES_CHANGED" then
        Track.Follow()                             -- smart (#47)
    elseif event == "UNIT_SPELLCAST_SENT" then
        Learn.OnCastSent(...)
        local unit, target, castGUID, spellID = ...
        gathering = nil
        if unit == "player" and type(target) == "string" and not API.IsSecret(target)
            and not API.IsSecret(castGUID) and not API.IsSecret(spellID) and Learn.CastKind(spellID) then
            gathering = { guid = castGUID, target = target }
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Only a gather that went through: an interrupted one leaves the node (Codex, PR #10).
        local unit, castGUID = ...
        if gathering and unit == "player" and not API.IsSecret(castGUID) and castGUID == gathering.guid then
            Alert.Gathered(gathering.target, now)
            Icons.Gathered(gathering.target)
            gathering = nil
        end
    end
end)

--------------------------------------------------------------------------------
-- /nr
--------------------------------------------------------------------------------

local function onOff(v) return v and "|cff00ff00on|r" or "|cffff4444off|r" end

local TOGGLES = { sound = "sound", ring = "sonar on the node", chat = "chat line",
                  ping = "Blizzard's ping (solo only)", learn = "learning by turning tracking off and on" }

local function status()
    local db = NR.db
    API.Say("radar " .. onOff(db.enabled) .. "; only nodes you can gather " .. onOff(db.skillOnly)
        .. "; item icons on the minimap " .. onOff(db.icons) .. " (" .. tostring(db.iconStyle) .. ", "
        .. tostring(db.iconSize) .. "); the compass (experimental) " .. onOff(db.compass)
        .. "; the marker in the world (experimental) " .. onOff(db.marker)
        .. "; sound " .. onOff(db.sound) .. ", ring " .. onOff(db.ring)
        .. ", chat " .. onOff(db.chat) .. ", Blizzard's ping " .. onOff(db.ping) .. "; learning " .. onOff(db.learn)
        .. "; " .. db.cooldown .. " s between alerts")
    API.Say(("skipped: %d herbs, %d ores; smart %s (this character)"):format(Track.Count("herbs"),
        Track.Count("ore"), onOff(Track.Smart())))
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
    API.Say("/nr: radar on or off. /nr options: the Options page")
    API.Say("/nr sound | ring | chat | ping | learn: toggle the sound, the ring, a chat line, Blizzard's ping "
        .. "(solo only), learning by turning tracking off and on")
    API.Say("/nr sound ping | sonarping | radar | sonar | radarblip | deepsea | bell | notify | hud: which sound.")
    API.Say("/nr skill: alert only for nodes your skill can gather (on by default)")
    API.Say("/nr icons: the item's icon over each node's dot on the minimap, or Blizzard's dots (the default)")
    API.Say("/nr tooltip: the skill a node needs in the minimap's tooltip, coloured (on by default)")
    API.Say("/nr iconstyle auto | plain | glass | bronze | yellow: the icon's frame (auto: glass with Glass MiniMap, "
        .. "else bronze). /nr iconsize small | medium | large")
    API.Say("/nr compass: experimental, a compass under your character pointing at the nearest node (off by default). "
        .. "/nr compasssize small | medium | large. Hold Alt and drag it to move it; /nr compass lock | unlock | reset")
    API.Say("/nr marker: experimental, a distant beacon with approximate height, and exact nearby stars (off by "
        .. "default; your map pin or tracked objective takes priority)")
    API.Say("/nr ignore <node or item> | /nr track <node or item>: skip or follow a herb or ore (a name or an "
        .. "item ID); /nr ignore alone lists the skipped. /nr smart: the list follows your skill")
    API.Say("/nr snooze [15 | 30 | 60 | session]: put the compass's node aside for a while (the key binding's "
        .. "length, set here too); /nr snooze clear. A reload clears them")
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
        NR.Set("enabled", not db.enabled)
        API.Say("radar " .. onOff(db.enabled))
    elseif cmd == "skill" then
        NR.Set("skillOnly", not db.skillOnly)
        API.Say("only nodes you can gather " .. onOff(db.skillOnly))
    elseif cmd == "icons" then
        NR.Set("icons", not db.icons)
        API.Say("item icons on the minimap " .. onOff(db.icons))
    elseif cmd == "tooltip" then
        NR.Set("tooltipSkill", not db.tooltipSkill)
        API.Say("the skill a node needs in the minimap's tooltip " .. onOff(db.tooltipSkill))
    elseif cmd == "iconstyle" and Icons.STYLES[rest:lower()] then
        NR.Set("iconStyle", rest:lower())
        API.Say("icon style: " .. rest:lower())
    elseif cmd == "iconsize" and Icons.SIZES[rest:lower()] then
        NR.Set("iconSize", rest:lower())
        API.Say("icon size: " .. rest:lower())
    elseif cmd == "compasssize" and Compass.SIZES[rest:lower()] then
        NR.Set("compassSize", rest:lower())
        API.Say("compass size: " .. rest:lower())
    elseif cmd == "snooze" and rest:lower() == "clear" then
        Compass.ClearSnoozes()
        API.Say("snoozes cleared")
    elseif cmd == "snooze" and (rest == "" or Compass.SNOOZES[rest:lower()]) then
        if rest ~= "" then db.snoozeFor = rest:lower() end
        NR.Minimap.SnoozeKey()
    elseif cmd == "compass" and rest:lower() == "reset" then
        Compass.ResetPosition()
        API.Say("the compass is back in its place, under your character")
    elseif cmd == "compass" and (rest:lower() == "lock" or rest:lower() == "unlock") then
        NR.Set("compassLock", rest:lower() == "lock")
        API.Say("the compass's position " .. (db.compassLock and "locked" or "unlocked: hold Alt and drag it"))
    elseif cmd == "marker" then
        NR.Set("marker", not db.marker)
        API.Say("the marker in the world (experimental) " .. onOff(db.marker))
    elseif cmd == "compass" then
        NR.Set("compass", not db.compass)
        API.Say("the compass (experimental) " .. onOff(db.compass))
    elseif cmd == "ignore" and rest == "" then
        local any = false
        for _, kind in ipairs(Track.KINDS) do
            for _, row in ipairs(Track.List(kind)) do
                if Track.Ignored(row.item) then
                    any = true
                    API.Say(("skipped: %s (%d)"):format(Track.ItemName(row) or row.nodes[1].name, row.item))
                end
            end
        end
        if not any then API.Say("nothing skipped: every herb and ore is followed") end
    elseif cmd == "track" and rest == "" then
        API.Say("/nr track <node or item>: a node's name, an item's, or an item ID")
    elseif cmd == "ignore" or cmd == "track" then
        local row = Track.Find(rest)
        if row then
            Track.Set(row.item, cmd == "track")
            local names = {}
            for _, n in ipairs(row.nodes) do names[#names + 1] = n.name end
            API.Say(("%s: %s (%s)"):format(Track.ItemName(row) or row.nodes[1].name,
                cmd == "track" and "followed" or "skipped", table.concat(names, ", ")))
        else
            API.Say(("no herb or ore called %s: a node's name, an item's, or an item ID"):format(rest))
        end
    elseif cmd == "smart" then
        Track.SetSmart(not Track.Smart())
        API.Say("smart (the list follows your skill) " .. onOff(Track.Smart()))
    elseif cmd == "options" or cmd == "config" then
        if not NR.Options.Open() then API.Say("the Options page can't open here: Esc > Options > AddOns") end
    elseif cmd == "sound" and Alert.SOUNDS[rest:lower()] then
        NR.Set("soundKind", rest:lower())
        NR.Set("sound", true)
        API.Say("sound: " .. rest:lower())
        Alert.PlaySound()
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
        Compass.ResetPosition()                    -- compassX, compassY: nil defaults, outside DEFAULTS (Codex)
        NR.Minimap.Apply()                         -- the button shown again, in LibDBIcon's table too (Codex, PR #65)
        NR.Marker.Toggle()                         -- off by default: ours cleared, the CVar put back (Codex, PR #74)
        NR.FarMarker.Toggle()
        API.Say("settings reset (learned names kept)")
    else
        help()
    end
end
