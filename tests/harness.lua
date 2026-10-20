-- harness.lua: assertions and loaders. dofile it after wow_stubs.lua.
-- GlassMail's harness, trimmed: no embedded library.

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
TEST_LIBRARY = { enUS = { ["Silverleaf"] = "herbs", ["Stunted Silverleaf"] = "herbs", ["Wilted Peacebloom"] = "herbs" } }
PROBE_TOC = "Tools/NodeRadarProbe/NodeRadarProbe.toc"

-- Lua files listed in a TOC, in load order. The vendored libraries (Libs\,
-- #46) are left out unless `all`: behaviour tests never load them, the stubs
-- answer LibDataBroker and LibDBIcon with fakes (GuildSpy's recipe, Codex);
-- run.ps1's luac -p checks every file.
function tocFiles(toc, all)
    local files = {}
    for line in io.lines(toc or TOC) do
        line = line:gsub("\r", "")
        if line ~= "" and not line:match("^#") and line:match("%.lua$") and (all or not line:match("^Libs\\")) then
            files[#files + 1] = line:gsub("\\", "/")
        end
    end
    return files
end

-- Load the addon the way the client does: every TOC file with (name, ns), its
-- saved tables (opts.db, opts.charDb), then ADDON_LOADED, PLAYER_LOGIN,
-- PLAYER_ENTERING_WORLD.
function loadAddon(opts)
    opts = opts or {}
    local ns = {}
    for _, f in ipairs(tocFiles()) do assert(loadfile(f))("NodeRadar", ns) end
    -- Behaviour tests run on a small fixed library, whatever Data/Nodes.lua
    -- ships (#17): names like Earthroot stay unknown. test_export pins the real one.
    if not opts.realLibrary then NodeRadar.LIBRARY = opts.library or TEST_LIBRARY end
    NodeRadarDB, NodeRadarCharDB = opts.db, opts.charDb
    WoW.fire("ADDON_LOADED", "NodeRadar")
    WoW.fire("PLAYER_LOGIN")
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    return NodeRadar
end

-- Chat lines printed since the last call.
local seenChat = 0
function newChat()
    local lines = {}
    for i = seenChat + 1, #WoW.chat do lines[#lines + 1] = WoW.chat[i] end
    seenChat = #WoW.chat
    return lines
end

function chatHas(pattern)
    for _, line in ipairs(WoW.chat) do
        if line:find(pattern) then return true end
    end
    return false
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

-- Every widget method the test called exists on Forever (the API dump), and
-- the `required` ones ("Type:Method") were called. Skipped without the dump (CI).
function checkMethods(required)
    local f = io.open(WoW.DUMP, "r")
    if not f then
        io.write("  method check SKIPPED (no API dump at " .. WoW.DUMP .. ")\n")
        return
    end
    local widget, documented = {}, {}
    for line in f:lines() do
        local wm = line:match("^(%a+:%a+)%s*$")
        if wm then widget[wm] = true end
        local fn = line:match("^([%a_]+)%(")
        if fn then documented[fn] = true end
    end
    f:close()
    -- Methods a template's Lua mixin adds aren't in the dump: found in the
    -- client's own FrameXML instead (wow-ui-source, 70450).
    local MIXINS = { ["DropdownButton:SetupMenu"] = "Blizzard_Menu/DropdownButton.lua",
                     ["DropdownButton:GenerateMenu"] = "Blizzard_Menu/DropdownButton.lua" }
    -- FrameXML's tooltip accessors (TooltipDataHandler.lua: `SetItemByID = "GetItemByID"`).
    local ACCESSORS = { ["GameTooltip:SetItemByID"] = "Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua" }
    local function inFrameXML(name)
        local acc = ACCESSORS[name]
        if acc then
            local src = io.open("../wow-ui-source/Interface/AddOns/" .. acc, "r")
            if not src then return false end
            local body = src:read("*a")
            src:close()
            return body:find("%s" .. name:match(":(%a+)$") .. ' = "') ~= nil
        end
        local file = MIXINS[name]
        local src = file and io.open("../wow-ui-source/Interface/AddOns/" .. file, "r")
        if not src then return false end
        local body = src:read("*a")
        src:close()
        return body:find("function %a+Mixin:" .. name:match(":(%a+)$") .. "%(") ~= nil
    end
    local n = 0
    for name in pairs(WoW.methodsCalled) do
        n = n + 1
        check(widget[name] or documented[name:match(":(%a+)$")] or inFrameXML(name), "method exists on Forever: " .. name)
    end
    for _, m in ipairs(required or {}) do check(WoW.methodsCalled[m], "called: " .. m) end
    check(n >= 10, "recorded the method calls (" .. n .. ")")
end
