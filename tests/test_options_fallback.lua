-- The Options page on a client without WowStyle1DropdownTemplate: the sound is
-- a radio group, two rows of three in columns, and a choice still saves and plays.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.missingTemplates.WowStyle1DropdownTemplate = true
local NR = loadAddon()
local O = NR.Options._test
O.panel:Show()

eq(O.dropdowns.soundKind, nil, "no dropdown without its template")
local s = O.radios.soundKind
eq(s and #s, 6, "the six sounds as radios")
local p1, p4 = s[1]._points[#s[1]._points], s[4]._points[#s[4]._points]
eq(p4[4], p1[4], "two rows: the fourth lines up under the first")
check(p4[5] < p1[5], "...below it")
check(s[1]:GetChecked(), "the minimap ping checked")

for _, rb in ipairs(s) do
    if rb.value == "deepsea" then WoW.click(rb) end
end
eq(NR.db.soundKind, "deepsea", "a radio saves the choice")
eq(WoW.sounds[#WoW.sounds][1], "Interface\\AddOns\\NodeRadar\\Media\\DeepSea.ogg", "...and plays it")
eq(next(NR.failures), nil, "no failure")
done("test_options_fallback")
