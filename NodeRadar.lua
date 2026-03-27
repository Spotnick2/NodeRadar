----------------------------------------------------------------------
-- NodeRadar - Gathering Node Alert for WoW TBC Anniversary
-- Detects herb/ore/gas cloud blips on the minimap and alerts
-- the player with sound and a visual ping. Only fires while mounted,
-- with a configurable cooldown between alerts.
--
-- Usage:  /nr          Toggle on/off
--         /nr help     Show all commands
--         /nr test     Fire a test alert
--         /nr status   Show current settings
----------------------------------------------------------------------

local ADDON_NAME = "NodeRadar"
local NR = CreateFrame("Frame", "NodeRadarFrame")

-- =====================================================================
-- DEFAULT SETTINGS (persisted in NodeRadarDB)
-- =====================================================================
local DEFAULTS = {
    enabled       = true,
    soundEnabled  = true,     -- play a ping/sonar sound
    pingEnabled   = true,     -- flash an expanding ring on the minimap
    chatAlert     = false,    -- print a message in chat
    cooldown      = 5,        -- seconds between alerts
    scanInterval  = 0.3,      -- seconds between minimap scans
    mountedOnly   = true,     -- only alert when mounted
    soundID       = 8332,     -- SOUNDKIT.MAP_PING (built-in minimap ping)
    pingColorR    = 0.2,
    pingColorG    = 1.0,
    pingColorB    = 0.4,
}

-- =====================================================================
-- LOCAL STATE
-- =====================================================================
local db                       -- reference to NodeRadarDB
local lastAlertTime  = 0
local knownBlips     = {}      -- set of blip keys we've already seen
local scanElapsed    = 0
local isTracking     = false   -- Find Herbs / Minerals / Gas active?
local playerMounted  = false

-- Tracking abilities that cause gathering nodes to appear on minimap.
-- These are the English names; other locales will need adjustment.
-- Players can add custom names via /nr addtrack <name> if needed.
local TRACKING_SPELLS = {
    ["Find Herbs"]      = true,
    ["Find Minerals"]   = true,
    ["Find Gas Clouds"] = true,   -- Outland gas clouds (engineering)
}

-- =====================================================================
-- MINIMAP PING VISUAL
-- Creates an expanding, fading ring centered on the minimap.
-- =====================================================================
local pingFrame = CreateFrame("Frame", "NodeRadarPing", Minimap)
pingFrame:SetAllPoints(Minimap)
pingFrame:SetFrameStrata("HIGHLIGHT")
pingFrame:Hide()

local pingTexture = pingFrame:CreateTexture(nil, "OVERLAY")
pingTexture:SetTexture("Interface\\Cooldown\\ping4")
pingTexture:SetPoint("CENTER", Minimap, "CENTER")
pingTexture:SetSize(12, 12)
pingTexture:SetVertexColor(0.2, 1.0, 0.4, 0.9)

-- Animation: scale up + fade out over 0.8 seconds
local pingAnimGroup = pingFrame:CreateAnimationGroup()

local scaleAnim = pingAnimGroup:CreateAnimation("Scale")
scaleAnim:SetScale(8, 8)
scaleAnim:SetDuration(0.8)
scaleAnim:SetSmoothing("OUT")
scaleAnim:SetOrder(1)

local alphaAnim = pingAnimGroup:CreateAnimation("Alpha")
alphaAnim:SetFromAlpha(0.9)
alphaAnim:SetToAlpha(0)
alphaAnim:SetDuration(0.8)
alphaAnim:SetSmoothing("OUT")
alphaAnim:SetOrder(1)

pingAnimGroup:SetScript("OnFinished", function()
    pingFrame:Hide()
    pingTexture:SetAlpha(0.9)
end)

local function FlashMinimapPing()
    pingTexture:SetVertexColor(db.pingColorR, db.pingColorG, db.pingColorB, 0.9)
    pingTexture:SetAlpha(0.9)
    pingFrame:Show()
    pingAnimGroup:Stop()
    pingAnimGroup:Play()
end

-- =====================================================================
-- ALERT SYSTEM
-- =====================================================================
local function FireAlert(reason)
    local now = GetTime()
    if reason ~= "test" and (now - lastAlertTime) < db.cooldown then
        return
    end
    lastAlertTime = now

    if db.soundEnabled then
        PlaySound(db.soundID, "Master")
    end

    if db.pingEnabled then
        FlashMinimapPing()
    end

    if db.chatAlert then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ff00[NodeRadar]|r Gathering node detected nearby!"
        )
    end
end

-- =====================================================================
-- TRACKING STATUS
-- Checks whether Find Herbs / Minerals / Gas Clouds is active.
-- Supports both Classic-era and modern API variants.
-- =====================================================================
local function UpdateTrackingStatus()
    isTracking = false

    -- TBC Classic API
    if GetNumTrackingTypes then
        for i = 1, GetNumTrackingTypes() do
            local name, _, active = GetTrackingInfo(i)
            if active and TRACKING_SPELLS[name] then
                isTracking = true
                return
            end
        end
    end

    -- Modern client fork fallback (C_Minimap)
    if C_Minimap and C_Minimap.GetNumTrackingTypes then
        for i = 1, C_Minimap.GetNumTrackingTypes() do
            local info = C_Minimap.GetTrackingInfo(i)
            if info and info.active and TRACKING_SPELLS[info.name] then
                isTracking = true
                return
            end
        end
    end
end

-- =====================================================================
-- MOUNT CHECK
-- =====================================================================
local function UpdateMountedStatus()
    playerMounted = IsMounted()
end

-- =====================================================================
-- MINIMAP BLIP SCANNER
--
-- How this works:
-- The WoW client renders tracking blips (herb/ore/gas nodes) as
-- anonymous child frames of the Minimap when Find Herbs etc. is
-- active. We iterate Minimap:GetChildren() on a throttled timer and
-- look for small, unnamed, visible frames whose textures match known
-- gathering-POI patterns.
--
-- When a blip frame appears that we haven't seen before, we fire an
-- alert. The knownBlips table is keyed by tostring(frame) (the Lua
-- memory address of the frame), which is unique per frame instance.
--
-- As a secondary source, if the C_VignetteInfo API exists (some
-- modern client forks), we also check for vignette-type objects.
--
-- LIMITATIONS:
-- - Texture paths may vary across client builds; the matcher uses
--   broad substring checks to stay resilient.
-- - If Blizzard changes how blips are rendered (e.g. pure GPU with
--   no Lua frames), this approach would stop working. A database-
--   driven approach (like GatherMate2) would be the fallback.
-- =====================================================================

local function IsLikelyGatherBlip(frame)
    -- Named frames are addon buttons, clock, zoom, etc. Skip them.
    if frame:GetName() then return false end
    if not frame:IsVisible() then return false end

    -- Tracking blips are small icons (roughly 8-16 px)
    local w, h = frame:GetSize()
    if w < 4 or w > 24 or h < 4 or h > 24 then return false end

    -- Inspect the frame's texture regions for POI-like textures
    local regions = { frame:GetRegions() }
    for _, region in ipairs(regions) do
        if region:IsObjectType("Texture") and region:IsVisible() then
            local tex = region:GetTexture()
            if tex then
                -- Numeric texture file IDs (atlas blips) → likely a POI
                if type(tex) == "number" then
                    return true
                end
                -- String paths: match known gathering-POI patterns
                local s = tostring(tex):lower()
                if s:find("objecticons")
                    or s:find("poiicons")
                    or s:find("poi%-")
                    or s:find("tracking")
                    or s:find("gather")
                then
                    return true
                end
            end
            -- Atlas-based textures (modern client forks)
            if region.GetAtlas then
                local atlas = region:GetAtlas()
                if atlas then
                    local a = atlas:lower()
                    if a:find("poi")
                        or a:find("herb")
                        or a:find("mining")
                        or a:find("ore")
                        or a:find("gas")
                        or a:find("gather")
                        or a:find("object")
                    then
                        return true
                    end
                end
            end
        end
    end

    return false
end

local function ScanMinimap()
    if not db.enabled then return end
    if not isTracking then return end
    if db.mountedOnly and not playerMounted then return end

    local children = { Minimap:GetChildren() }
    local currentBlips = {}
    local foundNew = false

    for _, child in ipairs(children) do
        if child ~= pingFrame and IsLikelyGatherBlip(child) then
            local key = tostring(child)
            currentBlips[key] = true
            if not knownBlips[key] then
                foundNew = true
            end
        end
    end

    -- Secondary: C_VignetteInfo (available in some client forks)
    if C_VignetteInfo and C_VignetteInfo.GetVignettes then
        local ok, vignettes = pcall(C_VignetteInfo.GetVignettes)
        if ok and vignettes then
            for _, vigID in ipairs(vignettes) do
                local info = C_VignetteInfo.GetVignetteInfo(vigID)
                -- type 2 = object vignette (gathering nodes)
                if info and info.type == 2 then
                    local key = "vig:" .. tostring(vigID)
                    currentBlips[key] = true
                    if not knownBlips[key] then
                        foundNew = true
                    end
                end
            end
        end
    end

    knownBlips = currentBlips

    if foundNew then
        FireAlert("node_detected")
    end
end

-- =====================================================================
-- THROTTLED UPDATE LOOP
-- =====================================================================
local function OnUpdate(self, elapsed)
    scanElapsed = scanElapsed + elapsed
    if scanElapsed < (db and db.scanInterval or 0.3) then return end
    scanElapsed = 0

    UpdateMountedStatus()
    ScanMinimap()
end

-- =====================================================================
-- EVENTS
-- =====================================================================
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= ADDON_NAME then return end

        -- Init saved variables
        if not NodeRadarDB then NodeRadarDB = {} end
        for k, v in pairs(DEFAULTS) do
            if NodeRadarDB[k] == nil then
                NodeRadarDB[k] = v
            end
        end
        db = NodeRadarDB

        UpdateTrackingStatus()
        UpdateMountedStatus()

        print("|cff00ff00[NodeRadar]|r v1.0 loaded. Type |cff88ff88/nr|r for commands.")

    elseif event == "MINIMAP_UPDATE_TRACKING" then
        UpdateTrackingStatus()

    elseif event == "PLAYER_ENTERING_WORLD" then
        UpdateTrackingStatus()
        UpdateMountedStatus()
        wipe(knownBlips)

    elseif event == "ZONE_CHANGED"
        or event == "ZONE_CHANGED_INDOORS"
        or event == "ZONE_CHANGED_NEW_AREA" then
        wipe(knownBlips)

    elseif event == "COMPANION_UPDATE"
        or event == "UNIT_AURA" then
        UpdateMountedStatus()
    end
end

NR:RegisterEvent("ADDON_LOADED")
NR:RegisterEvent("MINIMAP_UPDATE_TRACKING")
NR:RegisterEvent("PLAYER_ENTERING_WORLD")
NR:RegisterEvent("ZONE_CHANGED")
NR:RegisterEvent("ZONE_CHANGED_INDOORS")
NR:RegisterEvent("ZONE_CHANGED_NEW_AREA")
NR:RegisterEvent("COMPANION_UPDATE")
NR:RegisterEvent("UNIT_AURA")
NR:SetScript("OnEvent", OnEvent)
NR:SetScript("OnUpdate", OnUpdate)

-- =====================================================================
-- SLASH COMMANDS  /nr  or  /noderadar
-- =====================================================================
SLASH_NODERADAR1 = "/noderadar"
SLASH_NODERADAR2 = "/nr"

local function PrintStatus()
    print("|cff00ff00[NodeRadar] Current Settings:|r")
    print("  Enabled:       " .. (db.enabled      and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Sound:         " .. (db.soundEnabled  and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Minimap Ping:  " .. (db.pingEnabled   and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Chat Alert:    " .. (db.chatAlert     and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Mounted Only:  " .. (db.mountedOnly   and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Cooldown:      " .. db.cooldown .. "s")
    print("  Scan Interval: " .. db.scanInterval .. "s")
    print("  ---")
    print("  Tracking Active: " .. (isTracking    and "|cff00ff00YES|r" or "|cffff6600NO (enable Find Herbs/Minerals/Gas)|r"))
    print("  Currently Mounted: " .. (playerMounted and "Yes" or "No"))
end

local function PrintHelp()
    print("|cff00ff00[NodeRadar] Commands:|r")
    print("  |cff88ff88/nr|r            - Toggle addon on/off")
    print("  |cff88ff88/nr sound|r      - Toggle sound alert")
    print("  |cff88ff88/nr ping|r       - Toggle minimap ping flash")
    print("  |cff88ff88/nr chat|r       - Toggle chat notification")
    print("  |cff88ff88/nr mount|r      - Toggle mounted-only mode")
    print("  |cff88ff88/nr cd <sec>|r   - Set cooldown (1-60)")
    print("  |cff88ff88/nr color r g b|r - Set ping color (0.0-1.0 each)")
    print("  |cff88ff88/nr test|r       - Fire a test alert now")
    print("  |cff88ff88/nr status|r     - Show current settings")
    print("  |cff88ff88/nr reset|r      - Reset all settings to defaults")
end

SlashCmdList["NODERADAR"] = function(msg)
    if not db then return end

    msg = msg or ""
    local args = {}
    for word in msg:gmatch("%S+") do
        args[#args + 1] = word:lower()
    end
    local cmd = args[1] or ""

    if cmd == "" then
        -- Toggle on/off
        db.enabled = not db.enabled
        if not db.enabled then wipe(knownBlips) end
        print("|cff00ff00[NodeRadar]|r " .. (db.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"))

    elseif cmd == "sound" then
        db.soundEnabled = not db.soundEnabled
        print("|cff00ff00[NodeRadar]|r Sound: " .. (db.soundEnabled and "ON" or "OFF"))

    elseif cmd == "ping" then
        db.pingEnabled = not db.pingEnabled
        print("|cff00ff00[NodeRadar]|r Minimap Ping: " .. (db.pingEnabled and "ON" or "OFF"))

    elseif cmd == "chat" then
        db.chatAlert = not db.chatAlert
        print("|cff00ff00[NodeRadar]|r Chat Alert: " .. (db.chatAlert and "ON" or "OFF"))

    elseif cmd == "mount" then
        db.mountedOnly = not db.mountedOnly
        print("|cff00ff00[NodeRadar]|r Mounted Only: " .. (db.mountedOnly and "ON" or "OFF"))

    elseif cmd == "cd" then
        local secs = tonumber(args[2])
        if secs and secs >= 1 and secs <= 60 then
            db.cooldown = secs
            print("|cff00ff00[NodeRadar]|r Cooldown set to " .. secs .. "s")
        else
            print("|cff00ff00[NodeRadar]|r Usage: /nr cd <1-60>")
        end

    elseif cmd == "color" then
        local r = tonumber(args[2])
        local g = tonumber(args[3])
        local b = tonumber(args[4])
        if r and g and b and r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1 then
            db.pingColorR = r
            db.pingColorG = g
            db.pingColorB = b
            print("|cff00ff00[NodeRadar]|r Ping color updated.")
            -- Show a preview
            lastAlertTime = 0
            FlashMinimapPing()
        else
            print("|cff00ff00[NodeRadar]|r Usage: /nr color <r> <g> <b>  (values 0.0 to 1.0)")
        end

    elseif cmd == "test" then
        print("|cff00ff00[NodeRadar]|r Firing test alert...")
        FireAlert("test")

    elseif cmd == "status" then
        PrintStatus()

    elseif cmd == "reset" then
        for k, v in pairs(DEFAULTS) do
            db[k] = v
        end
        wipe(knownBlips)
        print("|cff00ff00[NodeRadar]|r All settings reset to defaults.")

    else
        PrintHelp()
    end
end
