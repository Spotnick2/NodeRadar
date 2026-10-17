# NodeRadar plan

**Goal:** while you ride with Find Herbs or Find Minerals on, a ping and a flash on the minimap
the moment a gathering node comes into range, so you never ride past one you didn't notice.

## Why v1 never worked

v1 (`NodeRadar.lua`, written for TBC Anniversary, Interface 20504) looked for the blips as
children of the Minimap: small, unnamed frames with a "gather-ish" texture. The client doesn't
draw tracking blips that way. They're drawn by the engine inside the Minimap widget and never
appear in `Minimap:GetChildren()`. So v1 could only ever see other addons' pins (HereBeDragons
icons from Questie, RXPGuides, ...), and its "any numeric texture is a blip" rule made those false
alerts. Its vignette fallback (`info.type == 2`) doesn't mean "gathering node" either.

## The candidate on Forever (#2)

Forever runs Blizzard's Mainline code, and its API dump (1.60.1.70425, unchanged in 70450) has two calls that, put
together, would read the blips:

- **`Minimap:UpdateMouseoverAtPoint(pointX, pointY)`** (MinimapFrameAPI): moves the minimap's
  "what's under this point" to a point of our choosing. Nothing in Blizzard's UI calls it, so
  neither its coordinates nor whether it works from an addon are known.
- **`C_TooltipInfo.GetMinimapMouseover()`** returns that as TooltipData: what
  `GameTooltip:SetMinimapMouseover()` shows when you hover a blip ("Peacebloom"), which is how
  Blizzard's own minimap tooltip works (`Blizzard_Minimap/Mainline/Minimap.lua:269-272`).

Sampling a grid of points a few times a second would then give each node's name and where it is.

**Measured (70450, two rounds): it works.** The point is in `GetCursorPosition`'s space, and with
`Minimap:SetUsingSoftCursor(true)` around the sweep it counts with the cursor anywhere, at about
4 ms a sweep, without disturbing the player's own hover. A sweep reads every named blip (quests
ready for turn-in, group members, the player), so the port must keep only nodes.
`Minimap:PingLocation` marks a node but is sent to the group. Details: docs/FOREVER-PROBE.md.
`Tools/NodeRadarProbe` measures it (docs/FOREVER-PROBE.md has the procedure and the results):

1. what the mouseover reads while the player really hovers a blip;
2. which coordinate convention brings the same name back with the cursor elsewhere (a far point
   first, so a stale answer can't pass);
3. what a whole-map sweep costs and finds;
4. whether sweeping disturbs the player's own hover tooltip;
5. a ride with a live radar;
6. the smaller things: mount detection, tracking by spell ID, vignettes, the sound, the ring.

**If the mouseover can't be driven:** a known-spawn database instead. Record where you gather
(`UNIT_SPELLCAST_SUCCEEDED` for the gathering spell plus the player's position, which reads plainly
outdoors, porting guide, 70374) and alert near a known spawn. Weaker: it says where a node *can*
be, not that one is up.

## The port (#3)

What the three probe rounds measured (70450, docs/FOREVER-PROBE.md and PR #8) decides the design:
the soft sweep reads every named blip with the cursor anywhere, and a node is a name that vanishes
when its gathering tracking goes off. v1's code is replaced, not patched; its slash commands stay.

### Files (TOC order)

| File | What |
|---|---|
| `Compat.lua` | `NodeRadar.API`: `RegisterEvents` (reports a throw or a `false`), `IsSecret`, `Fail` (the one failure recorder, `/nr failures`), `MEASURED_ON_BUILD = "1.60.1.70450"` (and the same literal in a test) |
| `Data/Nodes.lua` | the shipped library: `NodeRadar.LIBRARY[locale][name] = "herbs" \| "ore"`. Starts with what's been measured (enUS: Wilted Peacebloom, Stunted Silverleaf, Silverleaf) |
| `Scan.lua` | the sweep |
| `Learn.lua` | which names are nodes |
| `Alert.lua` | new nodes, the alert |
| `NodeRadar.lua` | bootstrap, saved settings, `/nr` |

### The sweep (`Scan.lua`)

Every `interval` seconds (0.5 by default; round 3: 3.6 ms average, 12 ms worst):
- skipped when disabled, when no gathering tracking is on, when `Minimap` isn't visible, or when
  the geometry reads secret or missing;
- `Minimap:SetUsingSoftCursor(true)`, then `Minimap:UpdateMouseoverAtPoint(px, py)` over a grid 8
  of the map's units apart, in `GetCursorPosition`'s space (`(left + ox) * effectiveScale`), reading
  `C_TooltipInfo.GetMinimapMouseover()` at each point; then the point back on the cursor, and
  `SetUsingSoftCursor(false)`. The whole sweep is one function call inside a `pcall`; the soft cursor
  is turned off on every path, errors included;
- hits are grouped into **blips**: per name, grid cells that touch (8-neighbour) are one blip, at the
  centre of its cells, in the map's units from its centre (round 2: several nodes share a name; a
  blip covers 4–16 cells);
- with `rotateMinimap` on, offsets are turned to north-up with `GetPlayerFacing()` (plain outdoors,
  porting guide), so a blip's position doesn't jump when the player turns.

The sweep doesn't stop while the player hovers the map: round 2's soft sweeps 3 times a second
under the player's cursor never disturbed their tooltip.

### Which names are nodes (`Learn.lua`)

`kind(name)` answers `"herbs"`, `"ore"`, `false` (not a node) or `nil` (unknown), from, in order:
1. this account's learned names, `NodeRadarDB.learned[locale][name]` (`kind` or `false`, with the
   build and the source: `gather` or `toggle`);
2. the shipped library, `NodeRadar.LIBRARY[GetLocale()]` (nodes only).

Learning:
- **From gathering:** `UNIT_SPELLCAST_SENT` for the player whose spell is a gathering spell: Herb
  Gathering (2366) → herbs, Mining (2575) → ore, matched by ID and, for other ranks, by the name
  `C_Spell.GetSpellInfo(2366/2575)` returns. The target is the node's name (round 3).
- **From the toggle**, for an unknown name a sweep sees. Out of combat, not casting or channelling
  (`UnitCastingInfo` / `UnitChannelInfo`), not dead, at most one every 10 s, and only when the
  gathering tracking's spell isn't on cooldown (`C_Spell.GetSpellCooldown`). It turns that tracking
  off (`C_Minimap.SetTracking(i, false)`), sweeps 1.5 s later, turns it back on (a cast of the
  spell, round 3), sweeps 2.5 s later. A name is that kind only when it was there before, gone with
  the tracking confirmed off, and back after (Codex on #8); it's `false` when it stayed while off;
  anything else stays unknown, to try again later. A failed sweep makes the whole run inconclusive.
  With both Find Herbs and Find Minerals on, a name is `false` only once it survived both toggles.
- **Tracking must come back.** If it isn't on 2.5 s after re-enabling (a cast that failed, combat
  that started), retry once out of combat; if it's still off, **say so in chat**: "NodeRadar turned
  Find Herbs off to learn a node and couldn't turn it back on: turn it on again." Never silent.
- `/nr learn on|off` (on by default) turns the toggle off for players who'd rather learn only by
  gathering.

### New nodes and the alert (`Alert.lua`)

- Each sweep's node blips are matched to the previous sweep's (same name, within 10 units); an
  unmatched one is new. A new blip within 15 units of one that disappeared less than 20 s ago is the
  same node coming back (the map's edge), not new.
- A new node, at most one alert per `cooldown` seconds (5): `PlaySound(3175, "Master")` (MAP_PING,
  checked `willPlay`), a ring on the map at the node's position (our unnamed frame on `Minimap`,
  `HIGH` strata, `Interface\Cooldown\ping4`), and an optional chat line.
- Blizzard's ping (`Minimap:PingLocation`, centre offsets in the map's units) is optional and
  **solo only**: it's sent to the group (round 2). Off by default.
- No mounted-only mode: there are no mounts on the beta.

### The library (`Tools/export_nodes.lua`)

`lua5.1 Tools/export_nodes.lua <SavedVariables/NodeRadar.lua>` merges every account's learned nodes
(`kind`, never `false`) into `Data/Nodes.lua`, sorted by locale and name, keeping what's there; a
name learned as two kinds is reported and left out. `pwsh Tools/export_nodes.ps1` finds the
SavedVariables files. A test pins the merge and the data file's shape.

### Commands

`/nr` (on/off), `/nr sound|ring|chat|ping|learn`, `/nr cd <1-60>`, `/nr test`, `/nr status`,
`/nr known` (the learned names), `/nr forget <name>`, `/nr failures`, `/nr reset`. An options page
is a follow-up issue.

### Tests

The probe's stubbed minimap (screen-space points, soft cursor, tracking that hides its blips,
`SetTracking`) moves into the shared stubs. Offline: grouping into blips, matching and the "came
back" rule, learning from gathering and from the toggle (each Codex case: a name that never comes
back, a failed sweep, tracking that stays on or won't come back), the soft cursor off on every path,
the alert's cooldown, the export's merge.

### Risks to check in game (a short procedure in the probe, after the port)

- Does re-enabling tracking cost a global cooldown, or interrupt a cast? (Guarded: never while
  casting; measured here.)
- Does a sweep every 0.5 s show in the frame time with a large map or a high zoom?
- A gamepad player using the soft cursor: we turn it off after every sweep. Skip sweeps while
  `GetCVarBool("GamePadEnable")`, until measured.

## A public API (#4), after #3

NodeRadar stays standalone: it reads Blizzard's `Minimap`, so it works under any skin (the stock
map, SexyMap, ElvUI, Glass MiniMap). It exposes `PUBLIC_API_VERSION` and a callback (name, kind,
position on the map); a skin that draws the alert itself (Glass MiniMap, as it does with Glass
MiniMap Bar) turns NodeRadar's own ring off.
