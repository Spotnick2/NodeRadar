# NodeRadar on Forever: what the probe measures

`Tools/NodeRadarProbe` is a ForeverProbe module (`..\ForeverProbe\docs\GUIDE.md`). Its lines go to
the `/fp` console and `NodeRadarProbeDB.log`, never to chat.

## Running it

```powershell
pwsh Tools\deploy.ps1 -ProbeOnly     # ForeverProbe, then NodeRadarProbe (not v1, until #3)
```

In game: `/console scriptErrors 1`, `/reload`, then **`/fp steps nr soft`** (round 2) and follow
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

## The `soft` procedure (round 2 of #2)

| Step | Measures |
|---|---|
| 1–2 | Find Herbs or Find Minerals on (by spell ID); the map's geometry |
| 3 | the owner hovers a blip: its names, the cursor, its offset; a screenshot |
| 4 | cursor on an **empty** part of the map: each convention, after a far point that must read nothing (check: one reads the blip) |
| 5 | still there: a whole-map sweep (check: it finds the blip **where it is**, within 12 units) |
| 6 | cursor off the map, **soft cursor on**: each convention again (check) |
| 7 | a whole-map sweep with the soft cursor (check: the blip where it is) |
| 8 | does the owner's own hover still work after the soft cursor? (20 s, else FAIL) |
| 9–10 | soft sweeps for 10 s while the owner hovers (check: the mouseover reads the blip after each); flicker? |
| 11–13 | `Minimap:PingLocation` at the blip: screenshot, `MINIMAP_PING`; seen on the blip? seen by a grouped second character? |
| 14–16 | a walk with the soft radar (no mounts on the beta): names as they appear; did they match? |
| 17–18 | v1's ring with a real strata: seen? |

Round 1's procedure (`blips`) is gone from the probe; its results are below.

The conventions (`NodeRadarProbe.lua`, `CONVENTIONS`), each from the cursor's pixels: `center`
(offsets from the map's centre in its units, what Blizzard hands `PingLocation`), `screen` (as is),
`ui` (÷ the map's effective scale), `uiparent`, `centerpx` (centre offsets in pixels),
`bottomleft`, `topleft`, `unit` and `unittop` (0-1 across the map), `radius` (-1..1 from the centre).

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
