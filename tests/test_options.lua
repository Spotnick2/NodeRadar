-- The Options page (#13): registered at login, hidden at creation, built on
-- its first show; each control saves the player's choice; a value set some
-- other way shows and is kept; the two sounds; a 5 s idle interval still
-- alerts (Codex). Then every widget method it called exists on 70450.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true
local NR = loadAddon()
NR.db.learn = false
local O = NR.Options._test
local db = NR.db

-- Registered once, at PLAYER_LOGIN.
eq(#WoW.categories, 1, "one category")
eq(WoW.categories[1].name, "NodeRadar", "...named NodeRadar")
check(WoW.categories[1].registered, "...in the AddOns list")
check(WoW.categories[1].frame == O.panel, "...the page")
eq(O.panel._shown, false, "hidden at creation (else the first visit is blank)")
eq(NR.Options.built, nil, "nothing built before it's shown")

-- /nr options opens it.
SlashCmdList.NODERADAR("options")
eq(WoW.openedCategory, 1, "/nr options opens the page")

-- First show: built, and every control reads the settings.
O.panel:Show()
check(NR.Options.built, "built on the first show")
local function checked(key)
    for _, rb in ipairs(O.radios[key]) do if rb:GetChecked() then return rb.value end end
end
eq(checked("interval"), 2, "standing still: 2 s checked")
eq(checked("yards"), 4, "moving: 4 yards checked")
-- The sound is a dropdown (the owner): radio items, the current one selected.
local SOUND_LABELS = { ping = "The minimap ping", sonarping = "Sonar ping", radar = "Radar ping",
                       sonar = "Sonar", radarblip = "Radar blip", deepsea = "Deep-sea sonar",
                       bell = "Bell chime", notify = "Notification", hud = "Sci-fi HUD ping" }
local dd = O.dropdowns.soundKind
check(dd and dd._template == "WowStyle1DropdownTemplate", "the sound: Retail's dropdown")
eq(O.radios.soundKind, nil, "...not a radio group")
local function selected()
    for _, item in ipairs(WoW.menu(dd)) do if item.selected then return item.label end end
end
eq(selected(), "The minimap ping", "the minimap ping selected")
eq(checked("cooldown"), 5, "5 s between alerts checked")

-- A click saves the choice, raw (only what the player sets is saved).
WoW.click(O.radios.interval[3])
eq(rawget(db, "interval"), 5, "5 s standing still saved")
eq(checked("interval"), 5, "...and checked, alone")
WoW.click(O.radios.yards[3])
eq(rawget(db, "yards"), 8, "8 yards saved")
WoW.speed = 7
eq(math.floor(NR.Interval() * 100 + 0.5), 114, "...the radar follows it: 8 yards at 7 yd/s")
WoW.speed = 0

-- A value set some other way: none checked, named, and kept by a refresh.
SlashCmdList.NODERADAR("cd 7")
O.panel:Hide()
O.panel:Show()
eq(checked("cooldown"), nil, "/nr cd 7: no cooldown choice checked")
eq(db.cooldown, 7, "...and 7 kept by the refresh")
local named = false
for _, child in ipairs({ O.panel:GetRegions() }) do
    if type(child._text) == "string" and child._text:find("now 7 s", 1, true) then named = true end
end
check(named, "...named after its title (now 7 s)")

-- The sound: choosing one plays it; the sonar ships with the addon.
local function choose(_, value)
    for _, item in ipairs(WoW.menu(dd)) do if item.label == SOUND_LABELS[value] then return item.pick() end end
    error("no choice " .. tostring(value))
end
local before = #WoW.sounds
choose("soundKind", "sonar")
eq(db.soundKind, "sonar", "Sonar chosen")
local last = WoW.sounds[#WoW.sounds]
eq(#WoW.sounds, before + 1, "...and played on the choice")
eq(last and last[1], "Interface\\AddOns\\NodeRadar\\Media\\Sonar.ogg", "...Media/Sonar.ogg")
eq(next(NR.failures), nil, "...and it played (the file ships): " .. tostring(next(NR.failures)))
check(io.open("Media/Sonar.ogg", "rb") ~= nil, "Media/Sonar.ogg ships")

-- The test button: an alert with the chosen sound.
before = #WoW.sounds
WoW.click(O.test)
eq(#WoW.sounds, before + 1, "the Test button sounds")
eq(WoW.sounds[#WoW.sounds][1], "Interface\\AddOns\\NodeRadar\\Media\\Sonar.ogg", "...the sonar")

-- A sound that doesn't play is a failure, not silence.
WoW.refusedSounds["Interface\\AddOns\\NodeRadar\\Media\\Sonar.ogg"] = true
NR.Alert.PlaySound()
check(NR.failures.sound, "a refused sound is recorded in /nr failures")
WoW.refusedSounds = {}
NR.failures.sound = nil

-- The client's files by FileDataID (both heard on 70450): each plays when
-- chosen, and one a client lacks is a failure in /nr failures.
for key, id in pairs({ sonarping = 569006, radar = 7466154 }) do
    choose("soundKind", key)
    eq(db.soundKind, key, key .. " chosen")
    eq(WoW.sounds[#WoW.sounds][1], id, "...plays FileDataID " .. id)
end
eq(next(NR.failures), nil, "...both played here")
choose("soundKind", "radar")
WoW.refusedSounds[7466154] = true
NR.failures.sound = nil
NR.Alert.PlaySound()
check(NR.failures.sound, "a FileDataID this client lacks: a failure")
WoW.refusedSounds = {}
NR.failures.sound = nil
SlashCmdList.NODERADAR("sound sonarping")
eq(db.soundKind, "sonarping", "/nr sound sonarping")
eq(#WoW.menu(dd), 9, "nine sounds in the dropdown")
eq(selected(), "Sonar ping", "...the one chosen by /nr selected")
local generated = dd._generated or 0
O.panel:Hide()
O.panel:Show()
check((dd._generated or 0) > generated, "...and the page refreshes the dropdown's text on show")

-- Ours from Pixabay: each plays from the file that ships (the stub plays only
-- a file that exists, so a typo in a name fails here).
for key, file in pairs({ sonar = "Sonar.ogg", radarblip = "RadarBlip.ogg", deepsea = "DeepSea.ogg",
                         bell = "BellChime.ogg", notify = "Notification.ogg", hud = "HudPing.ogg" }) do
    choose("soundKind", key)
    eq(WoW.sounds[#WoW.sounds][1], "Interface\\AddOns\\NodeRadar\\Media\\" .. file, key .. " plays " .. file)
end
eq(next(NR.failures), nil, "...all six play: " .. tostring(next(NR.failures)))

-- /nr sound ping | sonar.
SlashCmdList.NODERADAR("sound ping")
eq(db.soundKind, "ping", "/nr sound ping")
eq(WoW.sounds[#WoW.sounds][1], 3175, "...plays the minimap ping")
SlashCmdList.NODERADAR("sound")
eq(db.sound, false, "/nr sound alone still toggles the sound")
SlashCmdList.NODERADAR("sound")

-- The checkboxes: the radar's mirrors /nr.
local on
for _, w in ipairs(WoW.frames) do
    if w._parent == O.panel and w._type == "CheckButton" and w._template == "UICheckButtonTemplate" then
        on = on or w
    end
end
check(on and on:GetChecked(), "the radar checkbox reads on")
WoW.click(on)
eq(db.enabled, false, "...a click turns the radar off")
WoW.click(on)
eq(db.enabled, true, "...and on")

-- Codex (#13): standing still every 5 s, a node that appears still alerts
-- (the stale gap grows with the interval), at a real frame rate.
eq(db.interval, 5, "5 s standing still")
WoW.blips = {}
WoW.advance(12, 1 / 60)                                    -- baselines
before = 0
for _, s in ipairs(WoW.sounds) do if s[1] == 3175 then before = before + 1 end end
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
WoW.advance(11, 1 / 60)
local after = 0
for _, s in ipairs(WoW.sounds) do if s[1] == 3175 then after = after + 1 end end
eq(after, before + 1, "a node appearing while standing still at 5 s alerts")

-- /nr reset clears the new settings too.
SlashCmdList.NODERADAR("reset")
eq(rawget(db, "yards"), nil, "/nr reset: yards")
eq(rawget(db, "soundKind"), nil, "...the sound")
eq(db.yards, 4, "...back to 4 yards")

checkMethods({ "CheckButton:SetChecked", "Button:SetText" })
done("test_options")
