# NodeRadar on Forever: what the probe measures

`Tools/NodeRadarProbe` is a ForeverProbe module (`..\ForeverProbe\docs\GUIDE.md`). Its lines go to
the `/fp` console and `NodeRadarProbeDB.log`, never to chat.

## Running it

```powershell
pwsh Tools\deploy.ps1 -Probe         # NodeRadar, ForeverProbe, then NodeRadarProbe
```

In game: `/console scriptErrors 1`, `/reload`, then **`/fp steps nr release`** (NodeRadar's
release check, #3) and follow the panel. It needs a character with Herbalism or Mining, outdoors
near nodes, one full client exit along the way. End with `/reload`; the session reads the results
from `SavedVariables\NodeRadarProbe.lua`, `ForeverProbe.lua` and `NodeRadar.lua`.

## The `release` procedure (#3)

NodeRadar itself, end to end (docs/PLAN.md, "Release check, in game"):

| Step | Measures |
|---|---|
| 1–2 | NodeRadar on, a gathering tracking on; its settings, learned counts, the minimap skin, the gamepad |
| 3–5 | **Does the restore cost a global cooldown?** The probe's own toggle (NodeRadar's learning paused meanwhile, put back after, or at the next login): for 2 s after `SetTracking(i, true)`, Retail's GCD spell (61304), the tracking spell's cooldown, and action slots 1–12 that start a ≤ 1.6 s cooldown. Then: did you see a sweep? Decides `learn`'s default |
| 6 | NodeRadar learns an unknown name **by itself** (the line lists the unknown names it sees) |
| 7 | it learns one **by gathering** |
| 8–9 | a walk: NodeRadar's alerts counted (a secure hook on `Alert.Fire`); one per new node? |
| 10–11 | `/nr test`: the ring at the centre, with a screenshot; the skin named in the note |
| 12–14 | tracking off with a restore pending, as mid-experiment; `/reload`; NodeRadar restores it by itself (20 s) |
| 15–17 | cooldown set to 7 and the learned count noted; **a full client exit**; both read back, then the cooldown put back |

`/fp steps nr walk` is steps 1–2, 6 and 8–9 alone: NodeRadar learning a name by itself (learning on
for that step, the player's own setting put back after, a default kept a default) and the walk's
alerts.

The commands, for one-offs (`/fp nr` lists them):

| Command | What |
|---|---|
| `state` | build, the map's rect and scales, zoom, rotation, gathering tracking, vignettes |
| `under` | what `GetMinimapMouseover()` reads now, and its data's shape |
| `hover` | keep the blip under the cursor (names, cursor pixels, offset from the map's centre, geometry) |
| `point [soft]` | each coordinate convention at the kept blip: far point, at once, 0.1 s later; `soft` with the soft cursor on |
| `sweep [conv] [step] [soft]` | sample the whole map; names, where (the centre of their hits, from the map's centre), milliseconds |
| `radar [seconds] [soft]` / `stop` | a sweep every 0.3 s, logging names as they appear |
| `soft on\|off` | `Minimap:SetUsingSoftCursor` |
| `ping [dx dy]` | `Minimap:PingLocation`, at the kept blip by default |
| `vignettes` | every vignette the client lists |
| `sound [kit]` | `PlaySound(kit, "Master")`, MAP_PING (3175) by default |
| `ring` | v1's ring on the minimap, and `GetFileIDFromPath` of its texture |
| `toggle [gcd]` | gathering tracking off and on, sweeping each time; what vanished (`gcd`: and the global cooldown of the restore) |
| `pairs` | names paired with the game-object IDs in range; `ClosestGameObjectPosition` for each |

## The `ids` procedure (round 3, #7)

A sweep reads every named blip, so this measures three ways to tell gathering nodes from the rest.

| Step | Measures |
|---|---|
| 1–2 | Find Herbs or Find Minerals on; a soft sweep: every blip's name, position and **line colour** |
| 3–4 | **the owner's idea:** `C_Minimap.SetTracking(i, false)`, sweep, `SetTracking(i, true)`, sweep. Check: something vanished while off, and tracking came back on |
| 5 | is tracking back on; did anything else happen (a cast, an error, a cooldown)? |
| 6 | a 2–3 min walk with the soft radar: every `OBJECT_ENTERED_AOI` / `OBJECT_LEFT_AOI`, with a game object's ID from its GUID; each name paired with the IDs in range every time it was seen; `UNIT_SPELLCAST_SENT`'s target when gathering |
| 7 | the pairs, the AOI events by kind, `ClosestGameObjectPosition` for each ID in range |

Rounds 1 (`blips`) and 2 (`soft`) are gone from the probe; their results are below.

The conventions (`NodeRadarProbe.lua`, `CONVENTIONS`), each from the cursor's pixels: **`screen`**
(as is: measured in round 2), `center` (offsets from the map's centre in its units, what
`PingLocation` takes), `ui` (÷ the map's effective scale), `uiparent`, `centerpx` (centre offsets in
pixels), `bottomleft`, `topleft`, `unit` and `unittop` (0-1 across the map), `radius` (-1..1 from
the centre).

## Measured

### Round 1: `blips`, 1.60.1.70450 (owner's run, 2026-10-17, Valley of Trials, Find Herbs)

The map: 198×198 in its own units at (1907.8, 912.5), effective scale 0.640 (UIParent's too),
zoom 0, not rotating, view radius 233 yd. Tracking: Find Herbs is index 1 of 24 (spell 2383).

| Question | Result |
|---|---|
| What the mouseover reads over a blip | `{ type = 21, lines = { { leftText = "Wilted Peacebloom", type = 0, leftColor } } }`, plain (twice, two blips) |
| A convention that reads the blip with the cursor **off** the map | **None of the ten.** The far point read nothing, the blip read `nil` at once and 0.1 s later (two runs) |
| A whole-map sweep, cursor off the map | 0 names in 625 points, each convention, 1.5–2.5 ms |
| Sweeps while the owner hovered a blip (convention `screen`, the first, since none had passed) | **Found 2 names**: the hovered Wilted Peacebloom, first at (17, 17), and **Thazz'ril's Pick** (a quest object) at (−31, 73). 34 sweeps in 10 s, 4.0 ms average, 12.1 ms max; the mouseover read the hovered blip after every sweep; no flicker seen (owner) |
| The ride (radar, cursor off the map) | 257 sweeps, 1.9 ms average, **0 names** |
| Mount | **No mounts on the beta** (owner): step skipped |
| Vignettes | 0 |
| `PlaySound(3175)`, `PlaySound(8332)` | both willPlay true, both heard |
| v1's ring | `ping4` exists (file ID 131009); **`SetFrameStrata("HIGHLIGHT")` throws** (a draw layer, not a strata), so v1's ring never showed. The probe's Retry then hit a half-built ring (probe bug, fixed in round 2) |

**So:** `UpdateMouseoverAtPoint` works, but only while the hardware cursor is on the minimap. A
radar needs it to work with the cursor in the world. Round 2 measures
`Minimap:SetUsingSoftCursor(true)` (the gamepad soft cursor's switch, never called by Blizzard's
UI), which conventions place the point right (with the cursor on an empty part of the map), and
`Minimap:PingLocation` to mark a found node.

**For the port:** no mounted-only default (no mounts); the ring needs a real strata.

### Round 2: `soft`, 1.60.1.70450 (owner's run, 2026-10-17, Valley of Trials, Find Herbs, grouped with a second character)

Same map (198×198, scale 0.640). The owner hovered a Wilted Peacebloom at (−17.9, 21.3) from the
map's centre.

| Question | Result |
|---|---|
| The convention, cursor on an **empty** part of the map | **`screen`**: `GetCursorPosition`'s space, as is. The far point read nothing, the blip read the herb at once (not 0.1 s later: the hardware cursor takes the mouseover back by then). The other nine read nothing |
| The convention, cursor **off** the map, **`SetUsingSoftCursor(true)`** | **`screen` again, and it reads the herb at once and still 0.1 s later.** The soft cursor is what makes the point count without the hardware cursor |
| A whole-map sweep, cursor on the map / soft cursor | Both: Wilted Peacebloom ×33 hits, Burning Blade Medallion ×4, in 3.0 / 5.3 ms. The "where it is" check FAILED, but the probe's fault: it averages every hit of a name, and several Wilted Peaceblooms were on the map (the screenshot shows them right of the player; the walk found another at (65, −47)), so the average (18, −1) sat between them. The port must cluster hits into separate nodes |
| The player's own hover after the soft cursor | works (step 8) |
| Soft sweeps 3 times a second for 10 s while hovering | 33 sweeps, 4.0 ms average, 7.2 ms max; the hover read right after every one; no flicker (owner) |
| `Minimap:PingLocation(-17.9, 21.3)` | the ping showed **on the blip**, with its sound (owner, twice). `GetPingPosition` → (−0.0906, 0.1075): the offset ÷ the map's width. **The grouped second character saw it too**: a ping is sent to the group |
| A 70 s walk with the soft radar | 236 sweeps, 4.3 ms average, 27.4 ms max; 6 names (see below) |
| v1's ring with the `HIGH` strata | shows (owner) |

**What a sweep finds is every minimap blip with a name, not just nodes.** The walk logged Burning
Blade Medallion and Thazz'ril's Pick (two quests ready for turn-in, in the quest tracker), Karuzo
Loco (the grouped second character) and Drakuza Memphisto (the player, at the centre) besides
Stunted Silverleaf and Wilted Peacebloom. Other addons' pins (RestedXP's step arrow, HereBeDragons
icons) are frames, not blips, and never appear. The port has to tell nodes from the rest.

**So (#2 answered):** with `Minimap:SetUsingSoftCursor(true)` around a sweep of
`Minimap:UpdateMouseoverAtPoint(x, y)` in screen pixels and `C_TooltipInfo.GetMinimapMouseover()`,
an addon reads the minimap's blips with the cursor anywhere, at about 4 ms a sweep, without
disturbing the player's own hover. **For the port (#3):** turn the soft cursor on only for the
sweep; cluster hits into nodes; keep only gathering nodes; never ping by default in a group (it
goes to the group), or mark the node with our own ring at its position instead.

### Round 3: `ids`, 1.60.1.70450 (owner's run, 2026-10-17, Valley of Trials to Sen'jin, Find Herbs) (#7)

| Way to tell nodes from other blips | Result |
|---|---|
| **Turning gathering tracking off and on** (the owner's idea) | **Works.** From addon code, out of combat: `C_Minimap.SetTracking(1, false)` turned Find Herbs off (`MINIMAP_UPDATE_TRACKING` at once); a sweep 1.5 s later had lost **exactly the two herbs** (Stunted Silverleaf, Wilted Peacebloom) and kept the three quest lines. `SetTracking(1, true)` **casts Find Herbs** (`UNIT_SPELLCAST_SENT` spell 2383) and tracking was back on 0.1 s later; the herbs were back in the next sweep. No blocked action; the owner noticed nothing else |
| **Line colour** | **Useless:** every blip is `#ffd200` (gold): herbs, quest lines, town NPCs |
| **Object IDs** (`OBJECT_ENTERED_AOI` / `OBJECT_LEFT_AOI`) | **Nothing:** 0 events in a 4-minute walk past herbs, NPCs and boars. Whether the registration was refused isn't known: the probe registered before its saved log was bound, so a refusal only reached the console. So no pairs, and `ClosestGameObjectPosition` had no ID to try |
| **Learning names from gathering** (`UNIT_SPELLCAST_SENT`) | **Works:** Herb Gathering (2366) reports the node as its target, as the client names it: "Silverleaf", "Wilted Peacebloom" |

What a sweep reads, besides nodes: quest titles **and their objective lines** ("Carry Your Weight",
"- 0/8 Canvas Scraps", "Report to Sen'jin Village"), and **town NPCs** shown by the town trackers
("Lar Prowltusk", "Xar'Ti", "Vel'rin Fang", "Master Vornal"). The walk: 768 sweeps over 4 minutes,
3.6 ms average, 12 ms max, **in and out of combat** (boars), with no blocked action. Several names
can share one spot (a quest and its objective line).

**So (#7 answered):** a node is a name that vanishes when its gathering tracking goes off. The port
learns names, per name and once each: from gathering casts for free, and by turning the tracking off
and on when a sweep sees a name it doesn't know yet, out of combat. A name is the client's own,
localized and exact ("Wilted Peacebloom" is its own name), so nothing is hard-coded.

### Release check, run 1: `release`, 1.60.1.70450 (owner's run, 2026-10-17, Durotar, Find Herbs; Glass MiniMap and Leatrix Maps)

| Check | Result |
|---|---|
| **The restore's global cooldown** | **Yes.** After `SetTracking(1, true)`: the tracking spell's cooldown went active, and action slots 2, 3 and 4 started a ≤ 1.6 s cooldown (220 samples); Retail's GCD spell (61304) never did. The owner saw the sweep. So **`learn` ships off**: learning is by gathering, and by toggle only for players who turn it on (`/nr learn`) |
| The toggle | Find Herbs off and back on, `UNIT_SPELLCAST_SENT` 2383 at the restore; Silverleaf vanished and came back, eight quest lines stayed |
| NodeRadar learning by itself; the walk's alerts | **Never ran: every sweep was skipped.** NodeRadar's gamepad guard read `GamePadEnable`, which is **true on this keyboard-and-mouse client** with "Enable Gamepad UI" off (the owner's options). Fixed: the guard reads the Gamepad UI the way Blizzard does, `InputUtil.IsGamepadUIEnabled()`. Re-run as `/fp steps nr walk` |
| Learning by gathering | works: Silverleaf, Peacebloom, Earthroot |
| `/nr test` | the ring and the sound (owner), under Glass MiniMap |
| A `/reload` with a restore pending | NodeRadar restored tracking 1.2 s after the login (`UNIT_SPELLCAST_SENT` 2383), nothing left pending |
| **A full client exit** | the cooldown set to 7 and 3 learned names both came back; no NodeRadar failure |

### Release check, the walk: `walk`, 1.60.1.70450 (owner's run, 2026-10-17, Durotar)

- **The radar runs** with the gamepad fix: Gamepad UI false, `GamePadEnable` true, gamepad cursor
  false.
- **Learning by itself:** within 1 s it learned "A Solvent Spirit" (a quest) as **not a node**.
- **Alerts:** Peacebloom twice in 2½ minutes, once per node, no repeats (owner: yes).
- **Names carry escape codes** (`NodeRadar.lua`'s learned names). A node above or below the player
  reads `|TInterface\Minimap\Minimap-PositionArrows:…|tPeacebloom`: the position arrow's texture
  comes first, so it was a different name and pinged only once the player reached its height (the
  owner's "too slow"). Quest lines carry colours (`For Honor|cffffffff`, `- 0/1 … slain|r`). Fixed:
  `Scan.Plain` strips textures, atlases, colours and links; names saved before are cleaned at
  login; the export tool cleans too.
- **The cadence follows the speed** (the owner): about 2 yards between sweeps (0.29 s at 100%,
  0.48 s at 60%, 0.71 s at 40%, 0.2 s at most), and 2 s standing still. Later 4 yards (#11, "Memory").
- **The ring:** `Interface\Cooldown\ping4` draws in a black square (no additive blend), and isn't
  Blizzard's ping animation (owner). Replaced by the sonar (the owner's pick): two rings ripple out
  from the node and a glow stays on it for 3 s, green for herbs, gold for ore, from our own art
  (`Tools/make_media.py`) drawn additively. Not yet seen in game.
- **Respawns** alert like any new node. A node gathered by the player no longer counts as one
  blinking at the edge, so the next of its name within 20 s alerts.

### Memory: `memory` and `blipsize`, 1.60.1.70450 (owner's runs, 2026-10-18, Tirisfal) (#11)

The owner saw NodeRadar at 54 to 82 MB in the game menu's addon memory, with the game degrading;
its CPU there was 0.1 to 0.3%.

| Measured | Result |
|---|---|
| NodeRadar's memory, then a full `collectgarbage("collect")` | 3021 KB, **84 KB after**; a minute of play later, 85 KB after another: **no leak** |
| `C_TooltipInfo.GetMinimapMouseover()` at an empty point | **a table**, not nil: `dataInstanceID, lines, type`, one line; **2.5 KB a read**, empty or not |
| `Minimap:UpdateMouseoverAtPoint` | allocates nothing |
| One sweep (625 reads, step 8) | **2830 KB of garbage**; moving at 3 to 5 sweeps a second, about 10 MB/s. The minute's samples swung between 15 and 78 MB |
| Blip hit areas, sampled every unit (zoom 5 and 4: the same) | a **square**: a quest object (Tomb Weed, opened with spell 22810) 15 x 15; an NPC 25 x 25; a quest's objective area larger than 49 x 49. Herbs read 3 x 3 hits at step 8 in earlier rounds (Wilted Peacebloom, Stunted Silverleaf x9), so a node is **at least 17 units wide**. No herb was in view for an exact measure |

So the cost is garbage for the shared collector, which the per-addon CPU figure doesn't show.
Fixed (#11): a step of 14 (196 reads on a 198-unit map, a third of 625; it never misses a 17-unit
square at any offset) and about 4 yards between sweeps moving (0.57 s at 100%, 0.95 s at 60%,
1.43 s at 40%, 0.5 s at most), 2 s standing still: about a sixth of the garbage while moving.
The wider grid bridges a gap narrower than 14 units, so two nodes of a name side by side (26 units
apart) read as one and the second never alerted (Codex, PR #12): a cluster of several cells of a
name known to be a node is read again at a step of 7 (as fine as the old 8) and grouped anew,
however wide (a chain of three is as wide as a quest's area). A node on one cell costs nothing
more; a pair a few reads; a quest's area, or any name not known as a node, isn't read again.

### Sounds (owner, 2026-10-18, 1.60.1.70450) (#13)

Played from the Options page with `PlaySoundFile`: FileDataID **569006** (`Spell_Uni_SonarPing_01`)
and **7466154** (`12.0_UI_Alert_Tonal_Radar_Ping`, a 12.0 file) both play, as does NodeRadar's own
`Media\Sonar.ogg`. They're the page's Sonar ping, Radar ping and NodeRadar's sonar, beside the
minimap ping (kit 3175).

Later the same day the owner replaced NodeRadar's own synthesised sonar with six Pixabay sounds
(README, "Sounds"): Sonar, Radar blip, Deep-sea sonar, Bell chime, Notification, Sci-fi HUD ping,
converted by `Tools/import_sounds.py`. The sound became a dropdown, `WowStyle1DropdownTemplate`
with radio items, as Blizzard's AddOns list on this build (`Blizzard_AddOnList/AddonList.xml:126`);
the radio group stays as the fallback.

### Skill and Cultivation: `skill` and `cultivation`, 1.60.1.70450 (owner's runs, 2026-10-18, Durotar) (#26)

`skill` on an Orc herbalist (Herbalism 24/75, then 25 in the Barrens' Razormane Grounds), `cultivation` on a Tauren
without Herbalism.

| What | Measured |
|---|---|
| `C_SkillInfo.GetSkillLineInfoByID(182)` | plain, every field: `rank=24, modifier=0, maxRank=75, tempPoints=0, skillID=182, skillLineCategoryID=11`, the name and description. **Nil** for a profession the character doesn't have (186, Mining) |
| A skill-up | `SKILL_LINES_CHANGED` fired and `rank` read 25 at once |
| A node's world tooltip (`C_TooltipInfo.GetWorldCursor()`, hovering Silverleaf in the world) | two lines: `Silverleaf` (gold, `ffd200`) and **`Herbalism` in orange (`ff8040`)**: the profession line carries the node's difficulty colour, as in Classic. Silverleaf needs 1, the skill was 24: orange, Classic's band below +25 |
| A node above the skill (Mageroyal, Razormane Grounds, Herbalism 25) | the tooltip's `Herbalism` line **red (`ff2020`)**; gathering **refused**: `UI_ERROR_MESSAGE` type **291**, "Requires Herbalism 50", Classic's requirement. Earthroot (15) read orange at 25, and gathering it raised the skill to 26 |
| A herb gathered without Herbalism (the Tauren) | refused: `UI_ERROR_MESSAGE` type **290**, "Requires Herbalism" |
| Cultivation | the Tauren knows **20552** (`C_SpellBook.IsSpellKnown` true); **1312643 is not known**. Neither is known to the Orc |
| Its cooldown, out of combat at the cast | only the global cooldown: `isActive=true, isOnGCD=true, duration=1.5` (category 133, shared by both IDs) |
| Its cooldown out of combat, 3.5 min later | plain: **`duration=900`** (15 min), `isActive=true`, `isOnGCD=false`, category 2578, `startTime` about 4 s after the button (its 3 s cast) |
| Its cooldown in combat, 11 s after the cast (and again 3.7 min after) | `startTime`, `duration`, `modRate`, `activeCategory` **secret**; **`isActive=true` and `isOnGCD=false` plain**: a cooldown longer than the global one runs, readable as a boolean in combat |

So Forever keeps Classic's per-node requirements (type 291 with the level; type 290 without the
profession), the skill filter can read the skill plainly, and Cultivation's state is readable everywhere as
"on cooldown" = `isActive` and not `isOnGCD` (both plain in combat, where the durations are secret).

### A blip's map coordinates: `coords`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar) (#27)

The conversion is HereBeDragons-Pins' minimap drawing inverted (`HereBeDragons-Pins-2.0.lua`): the
blip's offset in the map's own units x `C_Minimap.GetViewRadius()` / the map's half-width = yards,
up is north and right is east, the zone map's y grows southward, each axis over its own side of
`C_Map.GetMapWorldSize`.

| What | Measured |
|---|---|
| `GetViewRadius()` outdoors | zoom 0 **233.3**, 3 **133.3**, 5 **66.7** yards (HereBeDragons' table: 466.7, 266.7, 133.3 across) |
| indoors | zoom 0 **150**, 2 **90**, 5 **25** (HereBeDragons: 300, 180, 50 across) |
| The map's half-width | 99 units (a 198-unit map), at every zoom |
| North-up, Earthroot seen 60 yd away | predicted (46.76, 45.77), the player stood at (46.82, 45.96) to gather it: **7.5 yd** |
| North-up, Peacebloom seen 136 yd away | predicted (44.28, 45.33), stood at (44.34, 45.26): **4.0 yd** |
| Rotate Minimap | **Forever's Options have no such setting** (owner); `rotateMinimap` read `"0"` throughout. The rotating case wasn't measured |
| The map | Durotar (1411, 5287 x 3525 yd) outdoors and inside a building alike |

Within reach of the node both times (a gather is cast from about 5 yards), from a sweep whose grid
is 14 units (33 yards at zoom 0): the conversion is right.

### Blizzard's waypoint marker: `waypoint`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar) (#29)

Our user waypoint on the nearest node (NodeRadar's `Scan.MapPosition`), then super-tracked.

| What | Measured |
|---|---|
| Setting it from addon code | `C_Map.CanSetUserWaypointOnMap(1411)` true, `C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(...))` **true**, `C_SuperTrack.SetSuperTrackedUserWaypoint(true)` took; no `ADDON_ACTION_*` |
| The navigation frame | `C_Navigation.GetFrame()` present, `HasValidScreenPosition` true, `GetDistance` followed the player in (93, 66, 11 yd), `WasClampedToScreen` true when the node was behind |
| **The on-screen marker** | **not drawn as Retail draws it**: the screenshots and the owner see the waypoint's pin on the minimap and no marker with a distance. Yet `SuperTrackedFrame` (Blizzard_QuestNavigation, loaded) **is shown** while the waypoint is super-tracked (`waypointframe`, 3 s after Set, the node 11 yd ahead). The first run's reads all said hidden whatever the state (a Lua 5.1 `and` dropped `IsShown`'s value, Codex on #39). Nothing else on that screenshot (its one small square is Decursive's, the owner). Forever removes the In-Game Navigation option (`Blizzard_SettingsDefinitions_Frame/Camelot/InterfaceOverrides.lua`: `AdjustInGameNavigationSettings` is empty) |
| Arrival, standing on the node | nothing visible, no `NAVIGATION_DESTINATION_REACHED` |
| The events, ours | `USER_WAYPOINT_UPDATED` inside `SetUserWaypoint` (synchronous); `SUPER_TRACKING_CHANGED` **after** our setter returned, or not at all (it's a `UniqueEvent`) |
| The player's own waypoint (Ctrl-click on the world map) over ours | it replaced ours, `USER_WAYPOINT_UPDATED` and `SUPER_TRACKING_CHANGED`, and it was **not** super-tracked |
| Clearing: the waypoint first | the waypoint gone, but `IsSuperTrackingUserWaypoint` and `IsSuperTrackingAnything` still **true** (twice in this run, and again by the old final cleanup after the reload) |
| Clearing: the tracking first, then the waypoint | both false: the order to use |
| Across a `/reload` | the waypoint and its super-track both kept; right after the reload, no navigation frame yet (`GetFrame` nil), `HasValidScreenPosition` true, the distance from before |
| Across a logout | not measured |

`/console showInGameNavigation 1` (the hidden option's CVar) brought no marker back either (owner).

So on Forever the user waypoint works but draws no marker on screen: #29's first choice is out
unless Forever turns the navigation on.

### Item icons, first round: `icons`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar) (#28)

Glass MiniMap on, its map 198 x 198 units at an effective scale of 0.64, zoom 0 (233 yd radius).

| What | Measured |
|---|---|
| **A herb's hit area** (Earthroot x7, Peacebloom x1; every unit over ±30) | a **square of 25 x 25** sample points every time: 625 hits, the box full, all four corners. Never a disc, never another size. The 17 of #11 was a lower bound |
| Its centre against the drawn dot | **within about 2 units**. Our crosses (4 x 1 units) were too small to see in game: the owner saw only the boxes (note at the first: "it's a blue square not a red cross"), and the boxes sat around the dots (yes, three times). Zoomed in, the screenshots show a red + inside each dot, drawn over it, on the dot's centre for some and 1 to 2 units right and below for others (a fixed piece of the dot's art would sit the same in every dot). The dot is about 8 units across, a third of the box |
| Its centre against the sweep's grid | off by up to 5 units (+4 +2, +3 -5, +2 +3), about 12 yd at this zoom: the grid's centroid isn't a position to draw on |
| Overlapping hit areas | another blip's line (a quest's objective area, "Legging It") under the same point didn't change the herb's square: hits are by name |
| Two nodes of a name, a node at the rim | not met (one group every time, none at the rim) |
| A second zoom | **not measured**: the zoom read 4 when the step saw it, and 0 again by Measure. Glass MiniMap resets the zoom when the player moves (owner), so a measure has to follow the zoom at once. #11 found a quest object's square the same at zoom 5 and 4 |
| The cost | 3721 reads per blip; 2 blips in 97 ms, 3 in 154 ms: **about 13 µs a read** |
| **A node below the player** (the owner stood on top of it) | `\|TInterface\Minimap\Minimap-PositionArrows:0:0:0:0:16:32:0:16:16:32\|tEarthroot`: a 16 x 32 file, its **lower half** (texels 0-16 by 16-32). The minimap drew a small white **downward** triangle under that node's dot, inside its hit area. (The procedure's step asked for a node above; it takes any arrow) |
| A node above | not met (the step was done by hand); presumably the upper half (`0:16:0:16`), not seen |
| `C_Item.GetItemIconByID` for the 40 NODE_INFO items (enUS) | **all 40 answered, the 37 uncached too**, the same file IDs as `C_Item.GetItemInfoInstant`'s icon (Mageroyal 785: 133436; Copper Ore 2770: 134566) |

So a node's blip answers over a fixed 25-unit square around its dot: one edge per axis, found by
halving inside the grid's 14-unit bracket, places it within about 2 units; and the icon needs no
item cache. Whether the 1-2 units are the dot's own offset or our rounding waits for marks big
enough to see (the icons themselves).

### Item icons, second round: `iconcheck`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar) (#28)

NodeRadar's icons on (`Icons.lua` as committed), Glass MiniMap on, then the stock map for four steps.

| What | Measured |
|---|---|
| Icons over the dots, standing still | yes (owner); the screenshot shows each node's item icon where its dot was, no dot beside one |
| Hovering an icon | Blizzard's tooltip as without icons: `GameTooltip`'s first line read the node (`Earthroot`, with its arrow escape), the owner said yes. The icons are mouse-through |
| Standing on a node | the 12-unit icon covers the player's arrow; **acceptable** at this size (owner) |
| **A node above the player** | `\|TInterface\Minimap\Minimap-PositionArrows:0:0:0:0:16:32:0:16:0:16\|tSilverleaf`: the file's **upper half**, drawn as a small white **upward** triangle above the dot. With the icon on, it shows just above the icon's top edge: "barely but yes" (owner). No chevron of our own |
| Right after a zoom (to 4), running, turning while running | the icons on their dots (owner, three yes); the screenshots agree |
| Indoors | no nodes in view there, no icons: nothing to compare |
| **A gather** (Earthroot) | its record **2.6 yd** from `UnitPosition` at the cast (north +2.5, west +0.6), within gathering reach. A flipped axis would put it tens of yards off: the first value is north and the second west, as HereBeDragons-2.0 has it |
| **The cost**, the same loop for 60 s each | icons off: 105 sweeps, 30677 reads (292 a sweep), 67 MB allocated by all addons (640 KB a sweep), worst sweep 11.7 ms. Icons on: 86 sweeps, 25560 reads (297 a sweep), 56 MB (653 KB a sweep), worst sweep 9.0 ms. So **about 2% more per sweep**, within the noise of two rides (fewer sweeps the second time: a slower ride) |
| **The stock map** (Glass MiniMap off) | the map 198 x 198 units at the same scale and zoom: Silverleaf x2 and Earthroot, each **a 25 x 25 square**. The probe's red crosses (the measured centre) are visible here, on each icon's centre; the icons on their dots there too (owner's yes; note "blue square not red cross" for the boxes, as in round 1) |
| The setting put back | `icons` back to the player's default (nil) after the reloads |

So the icons sit on their nodes standing, zooming, running and turning, cost nothing noticeable, and
leave Blizzard's above and below arrows visible; the 25-unit square holds on the stock map, which is
also 198 units here, so whether it scales with a map's size is still unknown.

### Glass discs around the icons: `glass`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar) (#41)

LibGlass-1.0 minor 11 as Glass MiniMap loaded it. Each look is a disc built as Glass MiniMap's `Ring.AddDisc`
builds one (`disc_small`, the icon inset 18% and masked round), a child of NodeRadar's icon frame.

| Look | Owner |
|---|---|
| A: 18 units, clean (Glass MiniMap's), the icon 12 | yes |
| B: 22 units, clean, the icon 14 | yes |
| C: 15 units, clean, the icon 9 | yes; note: "i think we can have an optional size" |
| D: 18 units, pearl | yes |
| E: 18 units, clean, no shadow | yes |
| The best | note: "honestly at this size, it doesn't change much, I'd probably take the minimap setup by default" |
| Running with A | the discs stayed on their nodes (yes) |

The screenshots: every look builds and follows its icon; the glass reads as a thin ring round the
icon, and at these sizes the presets and the shadow are hard to tell apart. Blizzard's above and
below arrows still show at the disc's edge. Two observations, not explained yet:
- In the running screenshot the two Silverleaf showed as Blizzard's dots, not icons, 0.7 s after
  the step listed both as icons. The two were about 33 units apart, near the "crowded" distance (36).
- In the plain screenshot, two nodes that had just come into view were still dots: they hadn't been
  measured yet, which is expected.

### Bronze rings around the icons: `bronze`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar, Blizzard's minimap) (#41)

Glass MiniMap off. Each look is Blizzard's round minimap button as LibDBIcon lays it out (`MiniMap-TrackingBorder`
136430 and `UI-Minimap-Background` 136467, the icon masked round with `TempPortraitAlphaMask`), scaled to the icon.

| Look | Owner |
|---|---|
| F: the icon 12 (the ring about 22 units) | yes |
| G: the icon 10 (the ring about 18) | yes |
| H: the icon 14 (the ring about 26) | yes |
| The best | unsure; note: "same as the other, make it a choice" (a size setting) |
| Running with F | the rings stayed on their nodes (yes) |

The screenshots: every ring is centred on its node, the icon round inside it, the same bronze as the
minimap's own border. **The ring hides Blizzard's arrow for a node below the player**: the plain
screenshot shows the downward triangle under three nodes (Earthroot, two Peacebloom), and with any ring
on they're gone. The upward triangle above a node above stayed visible at F's size. So with a ring (or
a large icon) the height has to be drawn by us. No icon blinked in the running screenshot.

### NodeRadar's own icon frames: `styles`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar) (#41)

The #41 build: `iconStyle` and `iconSize`, Glass MiniMap on, then off for the last steps.

| What | Measured |
|---|---|
| Following the minimap, Glass MiniMap on | glass, medium (read back: `glass 12`); each disc on its node (yes) |
| Glass small and large; bronze small, medium and large; no frame | each read back as set (`glass 10`, `glass 14`, `bronze 10`/`12`/`14`, `plain 12`); right at every size (yes, yes) |
| Our arrow | shown for a node below (Peacebloom, bronze): the screenshot shows a small downward triangle under each ring of a node below, an upward one over a node above. The owner answered "unsure" so the screenshots would decide; asked after: "if it's the mini-arrows next to the nodes they are ok" |
| Hovering a framed icon | Blizzard's tooltip as without icons (`Peacebloom` with its arrow escape); yes |
| A dimmed node | none in view (skipped); Blizzard's minimap step later showed Mageroyal dimmed |
| The rim | the framed icon faded out at the edge (yes); the step was done by hand, its wait never saw an icon below 0.95 alpha |
| **The Options page** | **it overflows** (owner's note): from "Each icon's frame" down, the page draws past the Options window's bottom. Fixed after the run: the page scrolls (GlassPanel's `UIPanelScrollFrameTemplate` recipe); the owner checked it in game: fixed |
| The cost, 60 s each on one loop | off: 102 sweeps, 270 reads and 670 KB a sweep, worst 14.8 ms. Glass: 104 sweeps, 264 reads, 699 KB, worst 11.7 ms. Bronze: 97 sweeps, 253 reads, 682 KB, **worst 100.8 ms**: one spike, the rest as the others; the owner's computer was likely downloading something then: not NodeRadar's |
| Following the minimap, Glass MiniMap off | bronze, medium (`bronze 12`), on their nodes (yes) |
| Settings put back | `icons`, `iconStyle`, `iconSize` back to the player's (nil) |

### The compass, first round: `compass`, 1.60.1.70450 (owner's run, 2026-10-18, Durotar) (#29)

A draft ring under the screen's centre, its arrow at `bearing - GetPlayerFacing()` toward one of #28's
records, the bearing from `UnitPosition` as `atan2(-east, north)`.

| What | Measured |
|---|---|
| **`GetPlayerFacing()`**, the minimap's arrow pointed by the owner | north 6.215, west 1.658, south 3.244, east 4.736 rad: **counter-clockwise from north**, 0 to 2π, each within 0.1 of 0, π/2, π, 3π/2 |
| Across north | 6.238 → 0.420 between two polls: it wraps at 2π, as expected |
| The bearing to a record | Silverleaf at 3.05 rad (south), 72.7 yd; facing it (the node above the arrow on the minimap) read 3.04: **0.01 rad apart** |
| **The arrow, the node ahead** | at the ring's top (yes) |
| **The arrow, the node on the left** (off by +1.43 rad) | on the ring's left side, pointing left (yes; screenshot) |
| **The walk** to the node following the compass, then a gather | 72.7 yd at the start, 72.0 yd walked in a straight line (start to gather), the record 1.0 yd from the player at the cast: the distance and the record hold over 70 yards |
| Led to the node | yes (no note on the draft's look) |
| `UnitOnTaxi` on a flight | **not measured**: the flight was skipped, and the landing step read false at once (a flaw of the step: it didn't wait for a flight) |

So `atan2(-east, north) - GetPlayerFacing()` (counter-clockwise from straight ahead) points the compass
right, and #28's records are good to a yard or so at 70 yards. The flight stays to measure.

### The compass, second round: `compass2`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#29)

NodeRadar's own compass, the alerted-node design, with the icons off.

| What | Measured |
|---|---|
| The ring after an alert | up 0.0 s after it when the node was measured at once (146-186 yd off), 5.2 s once; it pointed at the node (yes) |
| **The ring vanishing** | gone 124, 135, 143 and 128 yd from its node, 1 to 18 s after the alert: right after a zoom in (the owner: "it vanished"; the node 143 yd off fell past the shrunk view, its record dropped at the rim, and the design dismissed the target), and among Peacebloom (likely a clump's merged centroid missing the record twice) |
| Riding to it by the ring | led there (yes); gone at 14.9 and 15.0 yd |
| The 60 s timeout | gone at 60.0 s, twice |
| A click on the ring | reached the world (yes) |
| Edit Mode, combat | nothing odd, no error (no, no) |
| A flight | not measured (Orgrimmar: no node in view) |
| The cost, the compass alone | 103 sweeps in 60 s, 262 reads a sweep, worst 12.4 ms: the icons-off cost |
| **The owner's verdict** | "it does not necessarily point to the closest herb and also vanishes with herbs on the minimap"; a skip for a node out of reach, later |

So the compass now points at the nearest gatherable record, chosen again every sweep (docs/PLAN.md).

### The compass, third round: `compass3`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#29)

The nearest-gatherable-node compass, the icons off. 18 target changes logged with every candidate's distance.

| What | Measured |
|---|---|
| **The nearest** | every change picked the nearest candidate (Silverleaf 78 over Peacebloom 79 and Silverleaf 143; Earthroot 105 over Peacebloom 112 and Silverleaf 133; Peacebloom 135 over Earthroot 146); the owner: it points at the nearest node (yes) |
| After a gather | on to the next nearest (yes) |
| Riding, gathering by the ring alone | no flicking between two, nothing odd (no) |
| **A zoom in** (to 4) | no node left in the shrunk view, so no record and no ring (the screenshot: no dot on the minimap either); the owner: the ring wasn't on a node in view (no, as there was none) |
| A clump of one herb | still useful (yes) |
| Within 15 yards | hidden at a Peacebloom, shown again walking away |
| The look | the screenshot: a green ring for a herb, "78 yd", the arrow on its side toward the node |
| A flight, the cost | skipped (round 2 measured the compass alone at the icons-off cost) |

So the compass points at the nearest gatherable node and moves on as the player gathers. A zoom in
leaves it nothing to point at until nodes are in the smaller view: it follows the minimap, as the
icons do. (The probe's shown/hidden lines read "-1.0 yd": a `t and bearing()` in its logging kept
one value; fixed after the run.)

### The compass's look, first round: `compasslook`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#29)

Glass drafts over NodeRadar's own target (LibGlass minor 11, as Glass MiniMap loaded it): a disc, the
node's item icon masked round in the middle, Blizzard's triangle on the rim, the distance in a small
glass pill under it.

| Look | Owner |
|---|---|
| Today's green ring (comparison) | the screenshot: the green ring, "115 yd" inside, the triangle on its edge |
| A: a glass disc 96, the icon, a pill | yes; note: "we could try to make the ring to the size of the icon and put the arrow outside the ring?" |
| B: A with Glass MiniMap's ring art (`ring_rim`, `ring_dark`) | yes; note: "that one looks nice" |
| C: a glass disc 72 | yes; note: "smaller is better, less clutter" |
| **The best** | **C** |
| Riding with A | readable (yes) |

The screenshots: all three read well over the ground; on C the triangle sits on the glass right
beside the icon. Next: a disc just around the icon, the arrow outside it, with and without Glass
MiniMap's ring art.

### The compass's look, second round: `compasslook2`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#29)

Glass discs just around the node's icon, the arrow orbiting outside, the distance pill under it; the
disc takes the mouse for the item's tooltip.

| Look | Owner |
|---|---|
| D: 44 units, the icon 30, Glass MiniMap's ring art | "i like it but the arrow is on the pill" (pointing behind, the arrow orbits down onto the pill: the screenshots); "a bit weird with the white around the outer of the ring" (that art's light edge at this size) |
| E: the same, the plain glass rim | yes |
| F: 36 units, the icon 24 | "the size should be an option"; "F seems to have rough edges" (the small disc textures below ~40 units) |
| The best | "D or E seemed fine" |
| The item's tooltip on hover (`GameTooltip:SetItemByID`, FrameXML's accessor) | the item's (yes) |
| A click on the disc | **didn't reach the world**: the disc takes the mouse for the tooltip (the owner clicked on it, not beside it). `Frame:SetMouseClickEnabled(false)` with `SetPropagateMouseClicks(true)` (both in the dump) should keep the hover and pass clicks through: to measure |
| Riding with D | readable (yes) |

So: E's rim, the disc just around the icon, the arrow outside it with the pill clear of its orbit, a
size option (not under ~44 units), the tooltip on hover with clicks passing through.

### The compass's look, NodeRadar's own: `compass4`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#29)

The built look: the item icon in a disc framed as the icons are, the arrow orbiting outside, the
distance in a pill below, the tooltip on hover with the disc taking mouse motion only.

| What | Measured |
|---|---|
| Glass at medium, small, large | each read back (`glass medium`, `small`, `large`); right (yes, yes). The screenshots: the icon in the glass disc, the arrow outside it, the pill below, all scaling together |
| Bronze, the icon alone | read back (`bronze medium`, `plain medium`); right (yes). **But their pills were empty** in the screenshots: the text is only written when the whole-yard distance changes, and a look switched to with the same distance never got it. Fixed after the run (a look switched to resets it; a regression test) |
| The item's tooltip on hover | "Silverleaf, Crafting Reagent, Sell Price 10" above the disc (the screenshot); the item's (yes) |
| **Left and right clicks on the disc** | reached the world (yes): `SetMouseClickEnabled(false)` with motion on |
| **A camera drag started on the disc** | the camera turned (yes) |
| Pointing behind (the node -3.0 rad) | the arrow at the bottom, clear of the pill (yes; the screenshot) |
| Edit Mode in and out, combat | no error, nothing odd (no, no) |
| Riding | readable at a glance (yes) |

### The compass refined: `compass5`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#29)

Our own art (a shadow, a dark lens, a greyscale rim tinted pearl or bronze, a 25-degree arc and a
white outlined triangle turning with the bearing, a fixed capsule), no LibGlass.

| What | Measured |
|---|---|
| Pearl at medium, small, large; bronze; no frame | each read back (`glass medium`, `small`, `large`, `bronze medium`, `plain medium`); liked, each right (yes, yes). The screenshots: the lens dark behind the icon, the pearl rim bright on top, bronze muted, no frame the lens alone; the capsule always filled |
| Four headings | ahead 0.01 rad, left 1.61, behind-right -2.36, behind -3.05: the arrow at the top pointing up, at 9 o'clock pointing left, at the bottom pointing down, its arc on the rim beneath it; arrow and arc together, clear of the capsule (yes). The diagonal's screenshot came after the turn on to behind (taken at the next step's completion) |
| **The triangle at a slant** | 44 px wide by 44 tall, near equilateral: around 0.5 rad its three corners look alike and it reads as pointing sideways (the pearl-medium screenshot). Straight up, left and down read right. A narrower triangle is the fix |
| Bright ground, a dark wall | readable on both (yes) |
| A far node (153-180 yd) | the three digits fit the capsule (yes) |
| The tooltip | "Earthroot" (the screenshot); the item's, the look unchanged (yes) |
| Clicks and a camera drag on the icon | reached the world (yes; "You need to be closer to interact" twice in the log, the right-clicks on the world) |
| Edit Mode in and out, combat | no error, nothing odd (no) |
| Riding | readable at a glance (yes) |

### A yellow frame: `yellow`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#50)

| What | Measured |
|---|---|
| **Blizzard's tracking dots' colour** | two Silverleaf dots, the icons off, a 4K JPEG at native resolution: the yellow pixels' median (173 of them) RGB (222, 178, 40), the brighter half's (234, 190, 28). Each dot is a lit yellow disc with a darker ring and a yellow rim. Taken as `{ 0.92, 0.75, 0.11 }`, the lit yellow |
| Our ring at the provisional `{ 1, 0.82, 0 }` | rendered (249, 211, 3) in the same spot: a touch brighter and greener than the dots; the owner found it a match at every size (yes). The measured value went in after the run (closer to the dots, a little more orange) |
| Yellow at small, medium, large | read back (`yellow 10`, `12`, `14`); each on its node, the ring around the icon, the dark edges holding on the orange map (the screenshots) |
| The height arrow on yellow | Silverleaf above: our arrow above the ring, clear of it |
| The compass's rim yellow | `yellow medium`; liked (yes): yellow on top, darker below, as pearl and bronze |
| **The narrower arrow** (30 px base) | at 0.52 rad (ahead-left) and -2.48 (behind-right) it points clearly along the slant; the owner: yes at the slants. Ahead-right and behind-left were passed by hand (their screenshots show the arrow straight ahead and straight behind, read right) |

### Choosing herbs and ores: `track`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar, Herbalism 38) (#47)

| What | Measured |
|---|---|
| The sub-pages | **Herbs and Ores under NodeRadar** with a +/− (the screenshots), each full on its first visit (yes, yes): `RegisterCanvasLayoutSubcategory` as measured by the siblings |
| The lists | 28 herb items and 12 ore items in enUS. Herb items share their node's name (Peacebloom gives Peacebloom), so the herbs' rows read the same named or not; the 12 ore rows all had the item's name (Copper Ore, ...) |
| What smart chose at 38 | Silverleaf, Peacebloom, Earthroot followed; the 25 above 38 skipped (Mageroyal 50 on); ores untouched (no Mining). The owner: right (yes) |
| A herb skipped (Silverleaf) | its icon dimmed and the compass left it (hidden, no other node) at once (yes); with Blizzard's dot, its record gone and only the dot (yes); tracked again, its icon back at the next sweep |
| The four presets | each set the list as computed at 38, waited for and logged; the checkboxes followed (yes) |
| **Smart off, then on** | off: logged. On: the step was passed by hand and answered no; its screenshot shows the list re-applied (skill-ups only) but the Smart box unticked, and smart read off: most likely clicked twice (on, then off, which keeps the list). Round 2 logs every toggle |
| A node's tooltip in the world | not seen: Next can't be pressed while hovering a node (the owner's note). Round 2 reads it itself |
| The owner's verdict | "looks perfect in the settings"; "do a few columns instead of a long list" (done: three columns, a tooltip per row); the full test of skipping needs the live game's node density |

### Choosing herbs and ores, round 2: `track2`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar, Herbalism 38) (#47)

| What | Measured |
|---|---|
| Herbs and Ores in three columns | every row one line, the skills coloured (red past 38, white on Ores without Mining); names fit (yes) but three cut short at 112: Khadgar's Whisker, Mountain Silversage, Lesser Bloodstone Ore (the screenshot). Widened to 140 after the run |
| A row's tooltip | Goldthorn: "Goldthorn 170" in red (the line read back); Thorium Ore's two veins at 245 and 275 (yes) |
| **Smart off, then on** | each click logged once: `SMART false (was true)`, `SMART true (was false)`; on, the box ticked and the list re-applied (yes). Round 1's "no" was two clicks |
| **A node's own tooltip** | Silverleaf (needs 1) at Herbalism 38: the name gold, then "Herbalism" in **yellow (1.00, 1.00, 0.00)**: 37 past its requirement, in the classic yellow band (+25 to +50). The tooltip colours by difficulty, as Classic; the grey line (+100) is still unseen |
| Icons and dots side by side after a layer change (the owner's screenshot, outside the procedure) | two dots about 23 map units apart by the player, under the 25-unit square a node is measured by: probably the known crowding limit (README), not the layer. `/fp nr icons` (new) dumps each blip with its nearest record, each record and each failed measure, for the next time. Its first runs (#219, the dots gone by then): every blip matched within 1.1 to 1.9 units, no failed measure; a Silverleaf that spawned between two dumps was measured by the second (1.9 units off its blip). The same load logged `RegisterEvent MINIMAP_PING` refused as unknown, never before (#217, #218 clean; the client unchanged since 10-16): unexplained, the probe's ping log only |

### Dots left unmeasured: `/fp nr icons`, 1.60.1.70450 (the owner, 2026-10-19, Durotar) (#28, #47)

The owner saw dots beside icons, some by the player's arrow, and a dot closer than the compass's
target. Two dumps:

| What | Measured |
|---|---|
| Run #219 (no reasons yet) | a Silverleaf blip at (-18.5, -8.0), 6 grid cells (matched nodes: 8 to 16), no record within 34.7 units, its measure failed 5 s before; another, 75 units out, failed too: not by the player's arrow, so not the arrow |
| **Run #220, re-measured with reasons** | two Silverleaf blips at (-25.5, -71.0) and (-29.0, -36.0), 35 apart on y: **"crowded: its name again past the top"** and **"... past the bottom"**. `edge` read one point 24 out: that lands inside the neighbour's 25-unit square (24 + 12.5 > 35), though a 10-unit gap lies between them |
| The fix | `edge` steps out by 4 to the first point that doesn't read the name, then halves (docs/PLAN.md, "Measuring a blip"; Codex to consensus): squares 30 and 35 apart measured offline on their exact centres. To check in game: such pairs get icons, and the compass points at them |

### The compass after a gather: `gather`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#29)

The owner's video (2 fps) before the fix: the ring showed the next node as the gather landed, hid half
a second later, came back about 3 s on, as the loot window closed (the herb's dot measured anew at
the player's feet, the nearest, within 15 yards). With its dot left out while it lingers:

| What | Measured |
|---|---|
| The ring every 0.25 s for 6 s after a gather | **0 of 24 samples hidden**: on the next node (an Earthroot) throughout, the loot window open from 0.50 s to the end; the owner: it stayed (yes). Offline before the fix, the same procedure read 19 of 21 hidden |

### Moving the compass: `compassmove`, 1.60.1.70450 (owner's run, 2026-10-19, Durotar) (#57)

First by hand ("alt-drag works in game"), then the round:

| What | Measured |
|---|---|
| Alt over the compass | the grip up, the icon's tooltip gone under it; "Drag to move" over the compass while Alt is held, gone when it's let go (yes) |
| A drag | dropped at (-341.1, 337.8): saved and anchored there |
| **After a `/reload`** | anchored at the same (-341.1, 337.8); where it was left (yes) |
| **Past the right edge** | the screen 2133.3 units wide here: saved at 1028.7, exactly 2133.3 / 2 - 38 (the footprint's half-width at medium): fully on screen (yes), "under the smart bars, but yes": Glass Action Bars' bars drew over it there (a higher strata than the compass's; left as is) |
| Alt let go mid-drag | it stopped following the mouse (yes) |
| Locked, Alt held | no grip |
| `/nr compass reset` | works (the owner, tried before the round; the round's step was passed before the command). The put-back, the same `place()` with the spot cleared, brought it home too: `anchored CENTER 0, -160` |
