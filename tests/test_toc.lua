-- The manifests and the event fixture.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local toc = io.open(TOC):read("*a")
check(toc:find("## Interface: 16001", 1, true), "interface 16001 (1.60.1; 11601 is the transposed-digit bug)")
check(toc:find("## Version: @project-version@", 1, true), "packager version token kept")
check(toc:find("## SavedVariables: NodeRadarDB", 1, true), "saved variables declared")
check(toc:find("## X-Curse-Project-ID: 1751109", 1, true), "the CurseForge project (#15)")
check(toc:find("## X-Wago-ID: mNwwoLNo", 1, true), "the Wago project, the `wago` job's target (#15)")
check(toc:find("## SavedVariablesPerCharacter: NodeRadarCharDB", 1, true), "per-character saved variables declared")
check(not toc:find("ForeverProbe", 1, true), "the addon never depends on the probe host")
check(#tocFiles() >= 1, "the TOC lists files")

-- Every sound that ships is credited in the LICENSE that ships with it (Codex,
-- PR #14): the README isn't packaged.
local license = io.open("LICENSE"):read("*a")
check(not license:find("Glass Mail", 1, true), "LICENSE: NodeRadar's own, no copied notice")
local sounds = 0
for _, f in ipairs({ "Sonar", "RadarBlip", "DeepSea", "BellChime", "Notification", "HudPing" }) do
    local path = "Media/" .. f .. ".ogg"
    if io.open(path, "rb") then sounds = sounds + 1 end
    check(license:find(path, 1, true), "LICENSE credits " .. path)
end
eq(sounds, 6, "the six sounds ship")
local windows = package.config:sub(1, 1) == "\\"
local listed = io.popen(windows and "dir /b Media\\*.ogg" or "ls Media/*.ogg")
local found = 0
for line in listed:lines() do
    local name = line:match("([%w_%-]+%.ogg)")
    if name then
        found = found + 1
        check(license:find("Media/" .. name, 1, true), "LICENSE credits every Media/*.ogg: " .. name)
    end
end
listed:close()
eq(found, sounds, "...the listing saw them all")
for _, f in ipairs(tocFiles(nil, true)) do
    check(io.open(f, "r") ~= nil, "TOC file exists: " .. f)
end
eq(tocFiles(nil, true)[1], "Libs/LibStub/LibStub.lua", "the libraries load first, LibStub before them (#46)")
eq(tocFiles(nil, true)[4], "Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua", "...LibDBIcon after LibDataBroker")
eq(tocFiles()[1], "Compat.lua", "Compat loads first of ours")
eq(tocFiles()[#tocFiles()], "NodeRadar.lua", "the bootstrap loads last")

-- Two places that must agree, never derived from each other (porting guide section 0).
local NR = loadAddon()
eq(NR.MEASURED_ON_BUILD, "1.60.1.70450", "MEASURED_ON_BUILD")

local probe = io.open(PROBE_TOC):read("*a")
check(probe:find("## Interface: 16001", 1, true), "probe: interface 16001")
check(probe:find("## Dependencies: ForeverProbe", 1, true), "probe: a ForeverProbe module")
check(probe:find("## SavedVariables: NodeRadarProbeDB", 1, true), "probe: its own saved log")
for _, f in ipairs(tocFiles(PROBE_TOC)) do
    check(io.open("Tools/NodeRadarProbe/" .. f, "r") ~= nil, "probe TOC file exists: " .. f)
end

-- The checked-in event list matches the dump, when the dump is here.
if WoW.dumpAvailable then
    local fixture = {}
    for line in io.lines(WoW.FIXTURE) do
        local name = line:match("^([A-Z][A-Z0-9_]+)%s*$")
        if name then fixture[name] = true end
    end
    local missing, extra = 0, 0
    for e in pairs(WoW.KNOWN_EVENTS) do if not fixture[e] then missing = missing + 1 end end
    for e in pairs(fixture) do if not WoW.KNOWN_EVENTS[e] then extra = extra + 1 end end
    eq(missing + extra, 0, WoW.FIXTURE .. " matches the dump (regenerate it)")
end

done("test_toc")
