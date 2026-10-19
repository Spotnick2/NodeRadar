-- Options.lua: the page in Esc > Options > AddOns (#13), built with the
-- porting guide's measured recipe ("An Options page with sub-pages and an About
-- page"), as GlassMail's: a plain Frame with .name, hidden at creation (or the
-- first visit is blank), controls built on the first OnShow, every value
-- re-read on every OnShow, registered once at PLAYER_LOGIN from NodeRadar.lua.
-- Choices are radio groups; the sound, a dropdown (the owner).

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Options = {}
NR.Options = Options

local RADIO_ART = "Interface\\Buttons\\UI-RadioButton"   -- 4 cells: normal, checked, highlight, pushed
Options.HEIGHT = 1000  -- the scroll child's height until fit() reads the real one

local panel = CreateFrame("Frame")
panel.name = "NodeRadar"
panel:Hide()

local category
local refreshers = {}

local function label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
    fs:SetText(text)
    return fs
end

-- A labelled radio button: UIRadioButtonTemplate when the client has it (its
-- own label, rb.text, takes the text), else the client's own radio art and a
-- label of ours.
local function radioButton(parent, text)
    local rb, templated = API.SafeFrame("CheckButton", parent, "UIRadioButtonTemplate", "text")
    if templated then
        rb.text:SetFontObject("GameFontHighlight")
        rb.text:SetText(text)
        return rb
    end
    rb:SetSize(16, 16)
    rb:SetNormalTexture(RADIO_ART)
    rb:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
    rb:SetCheckedTexture(RADIO_ART)
    rb:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
    rb:SetHighlightTexture(RADIO_ART)
    rb:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
    rb:GetHighlightTexture():SetBlendMode("ADD")
    rb.text = label(parent, text)
    rb.text:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    return rb
end

-- An on/off setting under `anchor`.
local function checkbox(parent, anchor, text, key)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
    local fs = label(parent, text)
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    local function sync() cb:SetChecked(NR.db[key] == true) end
    cb:SetScript("OnClick", function() NR.Set(key, cb:GetChecked() == true); sync() end)
    refreshers[#refreshers + 1] = sync
    Options._test.checks[key] = cb
    return cb
end

-- Choices side by side under `title`, perRow to a row (all by default):
-- { {value, text}, ... }; onPick runs after a click. A value set some other way
-- (/nr cd 7) checks none of them, is named after the title, and is kept:
-- refreshing only reads (Codex, #13). Returns the first button of the last row.
local function radios(parent, anchor, title, key, choices, unit, onPick, perRow)
    local head = label(parent, title)
    head:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    local group, prev = {}, nil
    local function sync()
        local current, matched = NR.db[key], false
        for _, rb in ipairs(group) do
            rb:SetChecked(rb.value == current)
            matched = matched or rb.value == current
        end
        head:SetText(matched and title or ("%s (now %s %s)"):format(title, tostring(current), unit))
    end
    for i, c in ipairs(choices) do
        local rb = radioButton(parent, c[2])
        rb.value = c[1]
        if perRow then                                 -- in columns, so the rows line up
            local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
            rb:SetPoint("TOPLEFT", head, "BOTTOMLEFT", col * 170, -4 - row * 22)
        elseif prev then
            rb:SetPoint("LEFT", prev.text, "RIGHT", 16, 0)
        else
            rb:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
        end
        rb:SetScript("OnClick", function()
            NR.Set(key, c[1])
            sync()
            if onPick then onPick() end
        end)
        group[#group + 1] = rb
        prev = rb
    end
    refreshers[#refreshers + 1] = sync
    Options._test.radios[key] = group
    return group[perRow and (math.ceil(#group / perRow) - 1) * perRow + 1 or 1]
end

-- A dropdown of choices (the owner, #13): radio items in Retail's
-- WowStyle1DropdownTemplate, as Blizzard's AddOns list draws one on this build
-- (Blizzard_AddOnList/AddonList.xml:126) and GuildSpy uses it. Where the client
-- lacks the template, the radio group, three to a row.
local function dropdown(parent, anchor, title, key, choices, onPick)
    local exists = rawget(_G, "DoesTemplateExist")
    if not (exists and exists("WowStyle1DropdownTemplate")) then
        return radios(parent, anchor, title, key, choices, "", onPick, 3)
    end
    local head = label(parent, title)
    head:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
    local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dd:SetWidth(200)
    dd:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)
    -- A saved value that's no longer a choice (a sound renamed since) reads as
    -- the default, as the alert plays it.
    local function current()
        for _, c in ipairs(choices) do if NR.db[key] == c[1] then return c[1] end end
        return NR.DEFAULTS[key]
    end
    dd:SetupMenu(function(_, root)
        for _, c in ipairs(choices) do
            root:CreateRadio(c[2], function() return current() == c[1] end, function()
                NR.Set(key, c[1])
                if onPick then onPick() end
            end)
        end
    end)
    refreshers[#refreshers + 1] = function() dd:GenerateMenu() end   -- a change by /nr shows
    Options._test.dropdowns[key] = dd
    return dd
end

local function heading(parent, anchor, text)
    local fs = label(parent, text, "GameFontNormal")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -18)
    return fs
end

local function note(parent, anchor, text)
    local fs = label(parent, text, "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
    fs:SetWidth(560)
    fs:SetJustifyH("LEFT")
    return fs
end

-- The page grew past the Options window (#41, the owner's run): everything
-- sits on a scroll child, GlassPanel's recipe (UIPanelScrollFrameTemplate
-- exists on Forever: porting guide), its height fitted to what it holds.
local page, last
local function fit()
    local top, bottom = API.Num(page:GetTop()), last and API.Num(last:GetBottom())
    if top and bottom and top > bottom then page:SetHeight(top - bottom + 16) end
end

local function build()
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)
    page = CreateFrame("Frame", nil, scroll)
    page:SetSize(620, Options.HEIGHT)
    scroll:SetScrollChild(page)
    Options._test.scroll, Options._test.page = scroll, page
    local title = label(page, "NodeRadar", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -16)
    local version = label(page, "", "GameFontDisableSmall")
    version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    refreshers[#refreshers + 1] = function()
        version:SetText("Version " .. NR.VersionText() .. " for World of Warcraft: Forever, by Spotnick")
    end
    local on = checkbox(page, version, "Radar on (with Find Herbs or Find Minerals on)", "enabled")
    on:SetPoint("TOPLEFT", version, "BOTTOMLEFT", 0, -12)

    local looks = heading(page, on, "How often it looks")
    local still = radios(page, looks, "Standing still, every", "interval",
        { { 1, "1 s" }, { 2, "2 s" }, { 5, "5 s" } }, "s")
    local moving = radios(page, still, "Moving, about every", "yards",
        { { 2, "2 yards" }, { 4, "4 yards" }, { 8, "8 yards" } }, "yards")
    local cost = note(page, moving, "Moving, never more often than every half second, nor less often than "
        .. "standing still. More often finds a node a moment sooner, and makes more memory for the game to clean "
        .. "up: every look reads the whole minimap.")

    local alert = heading(page, cost, "The alert")
    local skill = checkbox(page, alert, "Only nodes I can gather (my Herbalism or Mining skill)", "skillOnly")
    local sound = checkbox(page, skill, "A sound", "sound")
    local which = dropdown(page, sound, "Which sound (it plays when chosen)", "soundKind",
        { { "ping", "The minimap ping" }, { "sonarping", "Sonar ping" }, { "radar", "Radar ping" },
          { "sonar", "Sonar" }, { "radarblip", "Radar blip" }, { "deepsea", "Deep-sea sonar" },
          { "bell", "Bell chime" }, { "notify", "Notification" }, { "hud", "Sci-fi HUD ping" } },
        function() NR.Alert.PlaySound() end)
    local sonar = checkbox(page, which, "The sonar on the node (green for herbs, gold for ore)", "ring")
    local chat = checkbox(page, sonar, "A line in chat", "chat")
    local ping = checkbox(page, chat, "Blizzard's ping on the node too (solo only: in a group it shows on everyone's map)", "ping")
    local cd = radios(page, ping, "Between alerts, at least", "cooldown",
        { { 3, "3 s" }, { 5, "5 s" }, { 10, "10 s" } }, "s")
    local test = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    test:SetSize(120, 22)
    test:SetText("Test the alert")
    test:SetPoint("TOPLEFT", cd, "BOTTOMLEFT", 0, -12)
    test:SetScript("OnClick", function() NR.Alert.Test() end)
    Options._test.test = test

    local map = heading(page, test, "The minimap")
    local icons = radios(page, map, "Nodes on the minimap", "icons",
        { { false, "Blizzard's dots" }, { true, "Each node's item icon" } }, "")
    local iconsWhy = note(page, icons, "An icon covers Blizzard's dot once NodeRadar has measured where the node "
        .. "is; near the map's edge the dot shows. Dimmed: your skill can't gather it yet.")
    -- #41: the icon's frame and size, for when icons are on.
    local style = radios(page, iconsWhy, "Each icon's frame", "iconStyle",
        { { "auto", "Follow the minimap" }, { "plain", "None" }, { "glass", "Glass" }, { "bronze", "Bronze" },
          { "yellow", "Yellow" } }, "")
    local styleWhy = note(page, style, "Following the minimap: glass with Glass MiniMap, else a bronze ring like "
        .. "Blizzard's minimap buttons. Glass needs Glass MiniMap (or another Glass addon); without it, bronze. "
        .. "Yellow: a ring the colour of the minimap's tracking dots.")
    local size = radios(page, styleWhy, "Icon size", "iconSize",
        { { "small", "Small" }, { "medium", "Medium" }, { "large", "Large" } }, "")

    -- #29: experimental, off by default, under its own heading.
    local compassHead = heading(page, size, "The compass (experimental)")
    local compass = checkbox(page, compassHead, "Show the compass: which way to the nearest node, under your character",
        "compass")
    local compassWhy = note(page, compass, "Experimental, off by default. Points toward the nearest node you can "
        .. "gather that NodeRadar has measured, and hides within 15 yards of it. Its frame is the icons' (above); "
        .. "hover it for the item. It follows your character's facing, not the camera's: turning the camera alone "
        .. "doesn't turn it.")
    local compassSize = radios(page, compassWhy, "Compass size", "compassSize",
        { { "small", "Small" }, { "medium", "Medium" }, { "large", "Large" } }, "")

    local learning = heading(page, compassSize, "Learning")
    local learn = checkbox(page, learning, "Learn a new name by turning gathering tracking off and on for a moment", "learn")
    local why = note(page, learn, "Standing still, out of combat. Turning tracking back on costs a global cooldown, so "
        .. "it's off by default; NodeRadar also learns every node you gather.")
    local hint = note(page, why, "Type /nr help for every command.")
    hint:SetPoint("TOPLEFT", why, "BOTTOMLEFT", 0, -16)
    last = hint
end

panel:SetScript("OnShow", function()
    if not Options.built then
        Options.built = true
        build()
    end
    for _, refresh in ipairs(refreshers) do refresh() end
    fit()
    C_Timer.After(0, fit)                              -- once the layout has resolved
end)

-- Called once at PLAYER_LOGIN by NodeRadar.lua.
function Options.Register()
    if category or not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
end

-- Open the page; false when the Settings framework can't.
function Options.Open()
    if not (category and Settings and Settings.OpenToCategory) then return false end
    return pcall(Settings.OpenToCategory, category:GetID()) and true or false
end

Options._test = { panel = panel, refreshers = refreshers, radios = {}, dropdowns = {}, checks = {} }
