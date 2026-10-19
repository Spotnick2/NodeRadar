-- TrackOptions.lua: the Herbs and Ores pages under NodeRadar's in Esc > Options
-- > AddOns (#47, docs/PLAN.md "Choosing which herbs and ores"), sub-pages by
-- the porting guide's recipe as Glass Raid Frames' Indicators: each a plain
-- Frame hidden at creation, built on its first OnShow, re-read on every
-- OnShow, registered by Options.Register right after the main page, in order.

NodeRadar = NodeRadar or {}
local NR = NodeRadar
local API = NR.API
local Track = NR.Track
local TrackOptions = {}
NR.TrackOptions = TrackOptions

local COLUMNS = 3     -- the owner: a few columns, not a long list
local COL_W = 215     -- a column's width (three fill the page)
local ROW = 26        -- a row's height: one line, its nodes in its tooltip
local SKILL_NAMES = { herbs = "Herbalism", ore = "Mining" }

-- The gathering colours of a node's requirement at a rank: red (not yet),
-- orange, yellow from +25, green from +50, grey from +100 (Track.GREY).
local function colour(skill, rank)
    if not rank then return "ffffffff" end
    if rank < skill then return "ffff2020" end
    if rank < skill + 25 then return "ffff8040" end
    if rank < skill + 50 then return "ffffff00" end
    if rank < skill + Track.GREY then return "ff40c040" end
    return "ff808080"
end
TrackOptions.colour = colour

local function label(parent, text, font)
    local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
    fs:SetText(text)
    return fs
end

local function button(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    return b
end

local function makePage(kind, name)
    local panel = CreateFrame("Frame")
    panel.name = name
    panel:Hide()
    local ui = { panel = panel, rows = {}, asked = {}, buttons = {} }

    -- An item's skills coloured at a rank: "15", or "245-275" when its nodes differ.
    local function skills(row, rank)
        local low = ("|c%s%d|r"):format(colour(row.low, rank), row.low)
        if row.high == row.low then return low end
        return ("%s-|c%s%d|r"):format(low, colour(row.high, rank), row.high)
    end

    -- Each row from the list: tracked, the item's icon and name (asking the
    -- client once for one it hasn't), its skills coloured.
    local function refresh()
        if not ui.built then return end
        local rank = Track.Rank(kind)
        ui.smart:SetChecked(Track.Smart())
        for _, r in ipairs(ui.rows) do
            local row = r.row
            r.check:SetChecked(not Track.Ignored(row.item))
            local itemName = Track.ItemName(row)
            local okI, icon = pcall(C_Item.GetItemIconByID, row.item)
            if not itemName and not ui.asked[row.item] then
                ui.asked[row.item] = true
                pcall(C_Item.RequestLoadItemDataByID, row.item)
            end
            r.icon:SetTexture(okI and API.Num(icon) or nil)
            r.name:SetText(itemName or row.nodes[1].name)
            r.skill:SetText(skills(row, rank))
        end
    end
    ui.refresh = refresh

    -- A row's tooltip: the item, then each node with its own skill, coloured.
    local function tooltip(r)
        local row, rank = r.row, Track.Rank(kind)
        GameTooltip:SetOwner(r.cell, "ANCHOR_RIGHT")
        GameTooltip:SetText(Track.ItemName(row) or row.nodes[1].name, 1, 1, 1)
        for _, n in ipairs(row.nodes) do
            GameTooltip:AddLine(("%s |c%s%d|r"):format(n.name, colour(n.skill, rank), n.skill), 0.9, 0.9, 0.9)
        end
        GameTooltip:Show()
    end

    local function build()
        local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -4)
        scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)
        local page = CreateFrame("Frame", nil, scroll)
        scroll:SetScrollChild(page)
        ui.page = page
        local title = label(page, name, "GameFontNormalHuge")
        title:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -16)
        local note = label(page, "Unchecked: no alert, no chat line, never the compass's target; on the minimap as "
            .. "the main page says. For this character. Names NodeRadar learned on Forever aren't listed and always "
            .. "count.", "GameFontDisableSmall")
        note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
        note:SetWidth(560)
        note:SetJustifyH("LEFT")

        local smart = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
        smart:SetSize(24, 24)
        smart:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -8)
        local smartText = label(page, "Smart: follow my skill (check a node when I can gather it, uncheck it when "
            .. "it turns grey)")
        smartText:SetPoint("LEFT", smart, "RIGHT", 4, 0)
        smart:SetScript("OnClick", function() Track.SetSmart(smart:GetChecked() == true) end)
        ui.smart = smart
        local smartWhy = label(page, "On, it starts from the nodes that give skill-ups: those you can't gather "
            .. "yet are checked as you reach them, so turning off \"Only nodes I can gather\" doesn't bring them "
            .. "back. Your own clicks stand until the node's next line.", "GameFontDisableSmall")
        smartWhy:SetPoint("TOPLEFT", smart, "BOTTOMLEFT", 0, -4)
        smartWhy:SetWidth(560)
        smartWhy:SetJustifyH("LEFT")

        local prev
        for _, b in ipairs({ { "all", "All", 60 }, { "none", "None", 60 }, { "gather", "All I can gather", 130 },
                             { "skillups", "Skill-ups only", 120 } }) do
            local btn = button(page, b[2], b[3])
            if prev then
                btn:SetPoint("LEFT", prev, "RIGHT", 8, 0)
            else
                btn:SetPoint("TOPLEFT", smartWhy, "BOTTOMLEFT", 0, -10)
            end
            btn:SetScript("OnClick", function()
                if Track.Preset(kind, b[1]) then
                    ui.why:SetText("")
                else
                    ui.why:SetText(("This character has no %s: that one needs the skill."):format(SKILL_NAMES[kind]))
                end
            end)
            ui.buttons[b[1]] = btn
            prev = btn
        end
        local why = label(page, "", "GameFontDisableSmall")
        why:SetPoint("TOPLEFT", ui.buttons.all, "BOTTOMLEFT", 0, -6)
        ui.why = why

        local list = Track.List(kind)
        if #list == 0 then
            why:SetText(("No %s listed for this client's language (%s)."):format(name:lower(), GetLocale()))
        end
        -- In columns, filled top to bottom then across: the lowest skills first.
        local perCol = math.max(1, math.ceil(#list / COLUMNS))
        for i, row in ipairs(list) do
            local col, line = math.floor((i - 1) / perCol), (i - 1) % perCol
            local cell = CreateFrame("Frame", nil, page)
            cell:SetSize(COL_W - 5, ROW - 2)
            cell:SetPoint("TOPLEFT", why, "BOTTOMLEFT", col * COL_W, -8 - line * ROW)
            cell:EnableMouse(true)
            local check = CreateFrame("CheckButton", nil, cell, "UICheckButtonTemplate")
            check:SetSize(24, 24)
            check:SetPoint("LEFT", cell, "LEFT")
            local icon = cell:CreateTexture(nil, "ARTWORK")
            icon:SetSize(18, 18)
            icon:SetPoint("LEFT", check, "RIGHT", 2, 0)
            local itemName = label(cell, "")
            itemName:SetPoint("LEFT", icon, "RIGHT", 5, 0)
            itemName:SetWidth(140)                      -- Khadgar's Whisker, Mountain Silversage whole
            itemName:SetJustifyH("LEFT")
            itemName:SetWordWrap(false)
            local skill = label(cell, "", "GameFontHighlightSmall")
            skill:SetPoint("LEFT", itemName, "RIGHT", 3, 0)
            local r = { row = row, cell = cell, check = check, icon = icon, name = itemName, skill = skill }
            check:SetScript("OnClick", function() Track.Set(row.item, check:GetChecked() == true) end)
            -- The name clicks the box too; hovering shows the nodes.
            cell:SetScript("OnMouseUp", function()
                check:SetChecked(not check:GetChecked())
                Track.Set(row.item, check:GetChecked() == true)
            end)
            cell:SetScript("OnEnter", function() tooltip(r) end)
            cell:SetScript("OnLeave", function()
                if GameTooltip:GetOwner() == cell then GameTooltip:Hide() end
            end)
            ui.rows[i] = r
        end
        page:SetSize(620, 230 + perCol * ROW)
        ui.built = true
    end

    panel:SetScript("OnShow", function()
        if not ui.built then build() end
        refresh()
    end)
    -- An item the page asked for arrived: its name and icon, while shown.
    API.RegisterEvents(panel, { "ITEM_DATA_LOAD_RESULT" })
    panel:SetScript("OnEvent", function(_, _, item)
        if ui.asked[item] and panel:IsShown() then refresh() end
    end)
    return ui
end

local pages = { makePage("herbs", "Herbs"), makePage("ore", "Ores") }

-- The list changed (a click, a preset, smart, a command): an open page re-reads.
Track.onChanged = function()
    for _, ui in ipairs(pages) do
        if ui.panel:IsShown() then ui.refresh() end
    end
end

-- Called by Options.Register, right after the main page: Herbs, then Ores.
function TrackOptions.Register(parent)
    if not (parent and Settings and Settings.RegisterCanvasLayoutSubcategory) then
        API.Fail("track pages", "no parent category or no Settings subcategory API")
        return
    end
    for _, ui in ipairs(pages) do
        local ok, err = pcall(Settings.RegisterCanvasLayoutSubcategory, parent, ui.panel, ui.panel.name)
        if not ok then API.Fail("track pages", err) end
    end
end

TrackOptions._test = { herbs = pages[1], ore = pages[2] }
