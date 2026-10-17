# NodeRadar on Forever: what the probe measures

`Tools/NodeRadarProbe` is a ForeverProbe module (`..\ForeverProbe\docs\GUIDE.md`). Its lines go to
the `/fp` console and `NodeRadarProbeDB.log`, never to chat.

## Running it

```powershell
pwsh Tools\deploy.ps1 -ProbeOnly     # ForeverProbe, then NodeRadarProbe (not v1, until #3)
```

In game: `/console scriptErrors 1`, `/reload`, then **`/fp steps nr blips`** and follow the panel.
It needs a character with Herbalism or Mining, outdoors near nodes, and a mount. End with `/reload`;
the session reads the results from `SavedVariables\NodeRadarProbe.lua` and `ForeverProbe.lua`.

The commands, for one-offs (`/fp nr` lists them):

| Command | What |
|---|---|
| `state` | build, the map's rect and scales, zoom, rotation, gathering tracking, mounted, vignettes |
| `under` | what `GetMinimapMouseover()` reads now, and its data's shape |
| `hover` | keep the blip under the cursor (names, cursor pixels, geometry) |
| `point` | each coordinate convention at the kept blip: far point, at once, 0.1 s later |
| `sweep [conv] [step]` | sample the whole map; names, points, milliseconds |
| `radar [seconds]` / `stop` | a sweep every 0.3 s, logging names as they appear |
| `vignettes` | every vignette the client lists |
| `sound [kit]` | `PlaySound(kit, "Master")`, MAP_PING (3175) by default |
| `ring` | v1's ring on the minimap, and `GetFileIDFromPath` of its texture |

## The `blips` procedure (#2)

| Step | Measures |
|---|---|
| 2 | waits for Find Herbs or Find Minerals, by spell ID |
| 3 | the map's geometry, tracking, vignettes |
| 4 | the owner hovers a blip: the mouseover's names and data, the cursor; a screenshot |
| 5 | cursor away: each convention, after a far point that must read nothing (check: one reads the blip) |
| 6–7 | a whole-map sweep (check: it finds the hovered blip); did anything flicker? |
| 8–9 | sweeps for 10 s while the owner hovers (check: the mouseover still reads the blip after each) ; did the tooltip flicker? |
| 10 | mount (`PLAYER_MOUNT_DISPLAY_CHANGED`, `IsMounted`) |
| 11–13 | a ride with the radar: names as they appear, time, cost; did they match the minimap? |
| 14–17 | `PlaySound` 3175 and 8332: willPlay, and heard? |
| 18–19 | v1's ring (`Interface\Cooldown\ping4`): file ID, screenshot, seen? |

The conventions (`NodeRadarProbe.lua`, `CONVENTIONS`), each from the cursor's pixels:
`screen` (as is), `ui` (÷ the map's effective scale), `uiparent`, `center` and `centerpx`
(offsets from the map's centre, in its units or pixels), `bottomleft`, `topleft`, `unit` and
`unittop` (0-1 across the map), `radius` (-1..1 from the centre).

## Measured

Nothing yet: the first run is #2.
