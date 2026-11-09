-- harness.lua: the addon loaders. dofile it after wow_stubs.lua.
-- check, eq and done are WowTestKit's (done() also fails on a stray "|" in
-- any printed line). GlassMail's harness, trimmed: no embedded library.

TOC = "NodeRadar.toc"
TEST_LIBRARY = { enUS = { ["Silverleaf"] = "herbs", ["Stunted Silverleaf"] = "herbs", ["Wilted Peacebloom"] = "herbs" } }
PROBE_TOC = "Tools/NodeRadarProbe/NodeRadarProbe.toc"

-- Lua files listed in the TOC, in load order. The vendored libraries (Libs\,
-- #46) are left out unless `all`: behaviour tests never load them, the stubs
-- answer LibDataBroker and LibDBIcon with fakes (GuildSpy's recipe, Codex);
-- run.ps1's luac -p checks every file.
function tocFiles(toc, all)
    local files = {}
    for _, f in ipairs(Kit.tocFiles(toc or TOC)) do
        if all or not f:match("^Libs/") then files[#files + 1] = f end
    end
    return files
end

-- The probe's Lua files, in load order, as paths.
function probeFiles() return Kit.tocFiles("NodeRadarProbe.toc", "Tools/NodeRadarProbe/") end

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
    for _, f in ipairs(probeFiles()) do assert(loadfile(f))("NodeRadarProbe", ns) end
    WoW.fire("ADDON_LOADED", "NodeRadarProbe")
    WoW.fire("PLAYER_LOGIN")
    return ns
end

-- Widget methods that are real on the client although the dump's widget walk can't
-- see them (Kit.checkMethods' allow list: each with where it comes from).
METHOD_ALLOW = {
    -- A template's Lua mixin adds these (wow-ui-source, 70450).
    ["DropdownButton:SetupMenu"] = "Blizzard_Menu/DropdownButton.lua (DropdownButtonMixin)",
    ["DropdownButton:GenerateMenu"] = "Blizzard_Menu/DropdownButton.lua (DropdownButtonMixin)",
    -- DropdownButton is an intrinsic <Button> (Blizzard_Menu/DropdownButton.xml), not a widget
    -- type of the dump's walk: it has Button's methods.
    ["DropdownButton:SetPoint"] = "Blizzard_Menu/DropdownButton.xml (an intrinsic Button)",
    ["DropdownButton:SetWidth"] = "Blizzard_Menu/DropdownButton.xml (an intrinsic Button)",
    -- FrameXML's tooltip accessors (TooltipDataHandler.lua: `SetItemByID = "GetItemByID"`).
    ["GameTooltip:SetItemByID"] = "Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua (accessor table)",
}

-- Every widget method the test called exists on Forever (WowTestKit's check
-- against the pinned build's widget methods), and the `required` ones
-- ("Type:Method") were called. Returns how many methods were recorded.
function checkMethods(required)
    local recorded = Kit.checkMethods({ allow = METHOD_ALLOW })
    for _, m in ipairs(required or {}) do check(WoW.methodsCalled[m], "called: " .. m) end
    return recorded
end

-- FINDING (#98): /nr's help prints "a | b | c" with a stray "|" in six lines, which the
-- client reads as an escape. Until they're doubled, done() accepts exactly those: a
-- NodeRadar chat line of "/nr ..." whose only "|" are " | " separators. Any other stray
-- still fails.
local kitDone = done
function done(name)
    local keep = {}
    for _, line in ipairs(WoW.strays) do
        local body = line:gsub("^|cff00ff00%[NodeRadar%]|r /nr ", "")
        local help = body ~= line and not (body:gsub(" | ", "")):find("|", 1, true)
        if not help then keep[#keep + 1] = line end
    end
    WoW.strays = keep
    kitDone(name)
end
