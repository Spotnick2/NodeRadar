-- Boot: the addon loads on the stubbed client with v1's settings in the saved
-- table, registers its events without a failure, and every /nr command runs.
-- Then every widget method it called exists on 70450.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- Names saved before the escape codes came out (release check, 70450), as the owner's file had them.
local ARROW = "|TInterface\\Minimap\\Minimap-PositionArrows:0:0:0:0:16:32:0:16:16:32|t"
local NR = loadAddon({ db = { enabled = false, soundEnabled = true, mountedOnly = true, cooldown = 9, soundID = 8332,
    learned = { enUS = {
        [ARROW .. "Peacebloom"] = { kind = "herbs", source = "toggle" },
        ["Peacebloom"] = { kind = "herbs", source = "gather" },
        [ARROW .. "Mageroyal"] = { kind = "herbs", source = "gather" },
        ["Mageroyal"] = { kind = false, source = "toggle" },
        ["For Honor|cffffffff"] = { kind = false, source = "toggle" },
        ["|T.:0|t"] = { kind = false, source = "toggle" },
    } } } })
local L = NR.db.learned.enUS
eq(L["Peacebloom"].source, "gather", "a dirty name cleaned onto a gathered one: the gathered one kept")
eq(L[ARROW .. "Peacebloom"], nil, "...the dirty key gone")
eq(L["Mageroyal"].kind, "herbs", "a dirty gathered name beats a clean toggle's 'not a node'")
eq(L["For Honor"].kind, false, "a colour code cleaned")
eq(L[""], nil, "a name that was only a code: dropped")
local dirty = 0
for name in pairs(L) do if name:find("|", 1, true) then dirty = dirty + 1 end end
eq(dirty, 0, "no escape code left in the learned names")
NR.db.interval = 0.5                                       -- a quick idle cadence: this tests behaviour, not cadence
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
check(lines:find("known: 3 nodes and 1 other names learned here, 3 nodes shipped %(enUS%)"), "...counts what's known (with the cleaned names)")
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
WoW.advance(2.5)                                           -- past one idle sweep (2 s after /nr reset)
eq(next(NR.failures), nil, "no failure while sweeping")

checkMethods({ "Minimap:UpdateMouseoverAtPoint", "Minimap:SetUsingSoftCursor", "Minimap:GetRect",
    "Minimap:GetEffectiveScale" })

done("test_boot")
