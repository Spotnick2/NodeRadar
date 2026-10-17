-- Boot: the addon loads on the stubbed client with v1's settings in the saved
-- table, registers its events without a failure, and every /nr command runs.
-- Then every widget method it called exists on 70450.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local NR = loadAddon({ db = { enabled = false, soundEnabled = true, mountedOnly = true, cooldown = 9, soundID = 8332 } })
eq(NR.db.enabled, false, "a saved setting kept")
eq(NR.db.cooldown, 9, "...another")
eq(NR.db.soundEnabled, nil, "v1's settings dropped")
eq(NR.db.mountedOnly, nil, "...mountedOnly too (no mounts on the beta)")
eq(NR.db.sound, true, "a new setting at its default")
eq(type(NR.db.learned), "table", "the learned names' table")
eq(type(NR.charDb), "table", "the per-character table")
eq(next(NR.failures), nil, "no failure at login: " .. tostring(next(NR.failures)))

-- Every command.
local function nr(cmd) SlashCmdList.NODERADAR(cmd) end
newChat()
nr("")
eq(NR.db.enabled, true, "/nr turns the radar on")
for _, cmd in ipairs({ "sound", "ring", "chat", "ping", "learn" }) do
    local was = NR.db[cmd]
    nr(cmd)
    eq(NR.db[cmd], not was, "/nr " .. cmd .. " toggles it")
    nr(cmd)
end
nr("cd 12")
eq(NR.db.cooldown, 12, "/nr cd")
nr("cd 0")
eq(NR.db.cooldown, 12, "/nr cd out of range changes nothing")
NR.Learn.Record("Earthroot", "herbs", "gather")
NR.Learn.Record("Carry Your Weight", false, "toggle")
newChat()
nr("known")
local lines = table.concat(newChat(), "\n")
check(lines:find("Earthroot: herbs %(gather%)"), "/nr known lists a node")
check(lines:find("Carry Your Weight: not a node %(toggle%)"), "...and a name that isn't")
nr("forget Carry Your Weight")
eq(NR.Learn.Kind("Carry Your Weight"), nil, "/nr forget, a name with spaces and capitals")
newChat()
nr("status")
lines = table.concat(newChat(), "\n")
check(lines:find("radar"), "/nr status")
check(lines:find("known: 1 nodes and 0 other names learned here, 3 nodes shipped %(enUS%)"), "...counts what's known")
check(not lines:find("measured on"), "...no build warning on the measured build")
nr("failures")
check(chatHas("no failures"), "/nr failures")
nr("test")
nr("reset")
eq(NR.db.cooldown, 5, "/nr reset puts the defaults back")
eq(NR.Learn.Kind("Earthroot"), "herbs", "...and keeps the learned names")
nr("help")
check(chatHas("/nr known"), "help lists the commands")

-- A build the notes weren't measured on: status says so.
local real = GetBuildInfo
GetBuildInfo = function() return "1.60.1", "70999", "Nov 1 2026", 16001 end
newChat()
nr("status")
check(table.concat(newChat(), "\n"):find("measured on 1%.60%.1%.70450; you're on 1%.60%.1%.70999"),
    "a newer build is named in /nr status")
GetBuildInfo = real

-- A running radar, to record every method the sweep and the alert call.
WoW.tracking[1].active = true
WoW.blips = { { "Earthroot", 30, -20, kind = "herbs" } }
WoW.fire("ZONE_CHANGED_NEW_AREA")
WoW.advance(1)
eq(next(NR.failures), nil, "no failure while sweeping")

local f = io.open(WoW.DUMP, "r")
if f then
    local widget, documented = {}, {}
    for line in f:lines() do
        local wm = line:match("^(%a+:%a+)%s*$")
        if wm then widget[wm] = true end
        local fn = line:match("^([%a_]+)%(")
        if fn then documented[fn] = true end
    end
    f:close()
    local n = 0
    for name in pairs(WoW.methodsCalled) do
        n = n + 1
        check(widget[name] or documented[name:match(":(%a+)$")], "method exists on Forever: " .. name)
    end
    for _, m in ipairs({ "UpdateMouseoverAtPoint", "SetUsingSoftCursor", "GetRect", "GetEffectiveScale" }) do
        check(WoW.methodsCalled["Minimap:" .. m], "called on the Minimap: " .. m)
    end
    check(n >= 10, "recorded the method calls (" .. n .. ")")
else
    io.write("  method check SKIPPED (no API dump at " .. WoW.DUMP .. ")\n")
end

done("test_boot")
