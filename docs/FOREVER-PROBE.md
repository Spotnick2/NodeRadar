# NodeRadar on Forever: what the probe measures

`Tools/NodeRadarProbe` is a ForeverProbe module (`..\ForeverProbe\docs\GUIDE.md`). Its lines go to
the `/fp` console and `NodeRadarProbeDB.log`, never to chat.

## Running it

```powershell
pwsh Tools\deploy.ps1 -ProbeOnly     # ForeverProbe, then NodeRadarProbe (not v1, until #3)
```

In game: `/console scriptErrors 1`, `/reload`, then **`/fp steps nr ids`** (round 3, #7) and follow
the panel. It needs a character with Herbalism or Mining, outdoors near nodes. End with `/reload`;
the session reads the results from `SavedVariables\NodeRadarProbe.lua` and `ForeverProbe.lua`.

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
| `toggle` | gathering tracking off and on, sweeping each time; what vanished |
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
