-- Alert: per node name, a rise in its number of blips is a new node; a blink at
-- the map's edge, a zoom or a tracking change doesn't alert; the cooldown; the
-- ring on each blip of the name; Blizzard's ping solo only.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

WoW.tracking[1].active = true                              -- Find Herbs on before the login
local NR = loadAddon()
NR.db.interval = 0.5                                       -- a quick idle cadence: these test behaviour, not cadence
local Alert, Learn = NR.Alert, NR.Learn
NR.db.learn = false                                        -- no experiments here

local function sounds()
    local n = 0
    for _, s in ipairs(WoW.sounds) do if s[1] == 3175 then n = n + 1 end end
    return n
end
local function rings()
    local shown = {}
    for _, f in ipairs(WoW.frames) do
        if f._parent == Minimap and f._strata == "HIGH" and f._shown then
            local p = f._points[#f._points]
            shown[#shown + 1] = { p[4], p[5] }
        end
    end
    return shown
end
local function hideRings()
    for _, f in ipairs(WoW.frames) do if f._parent == Minimap and f._strata == "HIGH" then f._shown = false end end
end

-- The first sweep after the login: a new area, so a node in view alerts.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
WoW.advance(0.6)
eq(sounds(), 1, "a node in view at login alerts (a new area)")
local r = rings()
eq(#r, 1, "...one ring")
check(r[1] and math.abs(r[1][1] - 30) < 4 and math.abs(r[1][2] + 20) < 4, "...on the node's blip")

-- Nothing new: no alert.
hideRings()
WoW.advance(6)
eq(sounds(), 1, "the same node: no new alert")

-- A second node of the same name: a rise; rings on both (which one is new can't be told).
table.insert(WoW.blips, { "Wilted Peacebloom", -60, 40, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), 2, "a second node of the name alerts")
eq(#rings(), 2, "...a ring on each blip of the name")

-- A non-node name: no alert.
hideRings()
WoW.advance(6)
table.insert(WoW.blips, { "Carry Your Weight", 80, -80 })
NR.db.learned.enUS = NR.db.learned.enUS or {}
NR.db.learned.enUS["Carry Your Weight"] = { kind = false, source = "toggle" }
WoW.advance(0.6)
eq(sounds(), 2, "a name that isn't a node never alerts")

-- A blink at the map's edge: gone, then back within 20 s: no alert.
WoW.advance(6)
table.remove(WoW.blips, 2)                                 -- the second Peacebloom leaves
WoW.advance(1)
table.insert(WoW.blips, { "Wilted Peacebloom", -60, 40, kind = "herbs" })
WoW.advance(1)
eq(sounds(), 2, "a node blinking at the edge doesn't alert again")

-- The cooldown: two new nodes 1 s apart, one alert.
WoW.blips = { { "Wilted Peacebloom", 30, -20, kind = "herbs" } }
WoW.advance(25)                                            -- the blink window passes
local before = sounds()
table.insert(WoW.blips, { "Silverleaf", -40, -40, kind = "herbs" })
WoW.advance(0.6)
table.insert(WoW.blips, { "Stunted Silverleaf", 40, 60, kind = "herbs" })
WoW.advance(1)
eq(sounds(), before + 1, "two new nodes inside the cooldown: one alert")

-- A zoom: the counts start over, silently.
WoW.advance(6)
before = sounds()
WoW.fire("MINIMAP_UPDATE_ZOOM")
table.insert(WoW.blips, { "Silverleaf", 70, 10, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), before, "after a zoom, the first sweep is a silent baseline")

-- The map resized (Edit Mode, a skin): silent too.
local rect = Minimap._rect
Minimap._rect = { 800, 500, 180, 180 }
table.insert(WoW.blips, { "Silverleaf", 50, -60, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), before, "after the map changed size, a silent baseline")
Minimap._rect = rect
WoW.advance(0.6)

-- A tracking change: silent too.
WoW.fire("MINIMAP_UPDATE_TRACKING")
table.insert(WoW.blips, { "Silverleaf", -70, -10, kind = "herbs" })
WoW.advance(0.6)
eq(sounds(), before, "after a tracking change, a silent baseline")

-- A zone change: from zero, so the new area's nodes alert.
WoW.advance(6)
WoW.fire("ZONE_CHANGED_NEW_AREA")
WoW.advance(0.6)
eq(sounds(), before + 1, "a new area's nodes alert")

-- Settings: no sound, no ring, a chat line; Blizzard's ping solo only.
NR.db.sound, NR.db.ring, NR.db.chat, NR.db.ping = false, false, true, true
hideRings()
WoW.advance(6)
before = sounds()
newChat()
table.insert(WoW.blips, { "Earthroot", 20, 20, kind = "herbs" })
NR.db.learned.enUS.Earthroot = { kind = "herbs", source = "gather" }
WoW.advance(0.6)
eq(sounds(), before, "sound off: no sound")
eq(#rings(), 0, "ring off: no ring")
local line = newChat()[1]
check(line and line:find("Earthroot"), "a chat line naming it: " .. tostring(line))
eq(#WoW.pings, 1, "solo: Blizzard's ping")
eq(WoW.pings[1][1] > 15 and WoW.pings[1][2] > 15, true, "...on the node")
WoW.group = true
WoW.advance(6)
table.insert(WoW.blips, { "Earthroot", -20, -50, kind = "herbs" })
WoW.advance(0.6)
eq(#WoW.pings, 1, "in a group: no ping (it's sent to the group)")
WoW.group = false

-- The radar off: no sweep at all.
NR.db.enabled = false
local reads = 0
local real = C_TooltipInfo.GetMinimapMouseover
C_TooltipInfo.GetMinimapMouseover = function() reads = reads + 1; return real() end
WoW.advance(2)
eq(reads, 0, "radar off: no sweep")
NR.db.enabled = true
WoW.tracking[1].active = false
WoW.fire("MINIMAP_UPDATE_TRACKING")
WoW.advance(2)
eq(reads, 0, "no gathering tracking on: no sweep")
WoW.tracking[1].active = true
-- GamePadEnable is on by default on a keyboard client (release check, 70450):
-- it alone must not stop the radar.
WoW.cvars.GamePadEnable = "1"
WoW.advance(1)
check(reads > 0, "GamePadEnable alone: the radar sweeps")
reads = 0
WoW.cvars.GamePadEnable = nil
WoW.gamepadUI = true
WoW.advance(2)
eq(reads, 0, "the gamepad on: no sweep")
WoW.gamepadUI = false
WoW.advance(1)
check(reads > 0, "...and sweeping again")
C_TooltipInfo.GetMinimapMouseover = real

-- /nr test.
NR.db.sound = true
before = sounds()
SlashCmdList.NODERADAR("test")
eq(sounds(), before + 1, "/nr test sounds")
eq(WoW.softCursor, false, "the soft cursor off at the end")
done("test_alert")
