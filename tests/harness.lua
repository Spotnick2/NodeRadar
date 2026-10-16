-- harness.lua: assertions and loaders. dofile it after wow_stubs.lua.
-- GlassMail's harness, trimmed: no embedded library. The addon loader comes
-- with the port (#3); v1 reads globals Forever no longer has.

local passed, failed = 0, 0

function check(cond, msg)
    if cond then passed = passed + 1 else
        failed = failed + 1
        io.write("  FAIL: " .. tostring(msg) .. "\n")
    end
end

function eq(actual, expected, msg)
    check(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

function done(name)
    io.write(string.format("%s: %d passed, %d failed\n", name, passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

TOC = "NodeRadar.toc"
PROBE_TOC = "Tools/NodeRadarProbe/NodeRadarProbe.toc"

-- Lua files listed in a TOC, in load order.
function tocFiles(toc)
    local files = {}
    for line in io.lines(toc or TOC) do
        line = line:gsub("\r", "")
        if line ~= "" and not line:match("^#") and line:match("%.lua$") then files[#files + 1] = line:gsub("\\", "/") end
    end
    return files
end

-- ForeverProbe, the probe host (..\ForeverProbe, or $FOREVERPROBE), loaded
-- into these stubs the way the client does: every TOC file with (name, ns),
-- then its ADDON_LOADED. It is private and local, so CI sets
-- FOREVERPROBE_OPTIONAL=1 and a probe test exits as SKIPPED there; locally a
-- missing checkout is an error, never a silent skip.
function loadForeverProbe()
    local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
    local toc = io.open(root .. "/ForeverProbe.toc", "rb")
    if not toc then
        if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
            io.write("SKIPPED: ForeverProbe isn't here (private, local only); the probe tests run locally\n")
            os.exit(0)
        end
        error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
    end
    local files = {}
    for line in toc:read("*a"):gmatch("[^\r\n]+") do
        if line:match("%.lua$") and not line:match("^#") then files[#files + 1] = root .. "/" .. line end
    end
    toc:close()
    for _, file in ipairs(files) do assert(loadfile(file))("ForeverProbe", {}) end
    WoW.fire("ADDON_LOADED", "ForeverProbe")
    return ForeverProbe
end

-- NodeRadarProbe, as the client loads it after its host. Returns its namespace.
function loadProbe()
    local ns = {}
    for _, f in ipairs(tocFiles(PROBE_TOC)) do
        assert(loadfile("Tools/NodeRadarProbe/" .. f))("NodeRadarProbe", ns)
    end
    WoW.fire("ADDON_LOADED", "NodeRadarProbe")
    WoW.fire("PLAYER_LOGIN")
    return ns
end
