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
Reviewed by Codex (round 1: revise first; the changes are marked "Codex").

### Files (TOC order)

| File | What |
|---|---|
| `Compat.lua` | `NodeRadar.API`: `RegisterEvents` (reports a throw or a `false`), `IsSecret`, `Fail` (the one failure recorder, `/nr failures`), `MEASURED_ON_BUILD = "1.60.1.70450"` (and the same literal in a test) |
| `Data/Nodes.lua` | the shipped library: `NodeRadar.LIBRARY[locale][name] = "herbs" \| "ore"`. Starts with what's been measured (enUS: Wilted Peacebloom, Stunted Silverleaf, Silverleaf) |
| `Scan.lua` | the sweep |
| `Learn.lua` | which names are nodes |
| `Alert.lua` | new nodes, the alert |
| `NodeRadar.lua` | bootstrap, saved settings (`NodeRadarDB`, account-wide: settings and learned names; `NodeRadarCharDB`, per character: a pending tracking restore), `/nr` |

### The sweep (`Scan.lua`)

`Scan.Sweep()` reads the map once and returns its **blips**, or nil and why:
- `Minimap:SetUsingSoftCursor(true)`, then `Minimap:UpdateMouseoverAtPoint(px, py)` over a grid 8 of
  the map's units apart, in `GetCursorPosition`'s space (`(left + ox) * effectiveScale`), reading
  `C_TooltipInfo.GetMinimapMouseover()` at each point. The grid runs inside a `pcall`; **after it,
  unconditionally**, the point goes back on the cursor (or off the map) and
  `SetUsingSoftCursor(false)` runs, so an error inside can't leave the soft cursor on (Codex);
- hits are grouped into blips: per name, grid cells that touch (8-neighbour) are one blip, at the
  centre of its cells, in the map's units from its centre, as drawn (round 2: several nodes share a
  name; a blip covers 4–16 cells). A secret or missing geometry, or a secret line, fails the sweep.

The **radar** calls it every `interval` seconds (0.5 by default; round 3: 3.6 ms average, 12 ms
worst) when enabled, a gathering tracking is on, `Minimap` is visible and the Gamepad UI is off
(`InputUtil.IsGamepadUIEnabled()`: a gamepad player's own soft cursor isn't ours to turn off; the
`GamePadEnable` CVar the plan first named is on for keyboard players too, release check). The
**toggle** calls it directly, without those conditions: its middle sweep runs with the tracking off
on purpose, and its sweeps never reach the alerts (Codex). The sweep doesn't stop while the player
hovers the map: round 2's soft sweeps under the player's cursor never disturbed their tooltip.

### Which names are nodes (`Learn.lua`)

`kind(name)` answers `"herbs"`, `"ore"`, `false` (not a node) or `nil` (unknown), from, in order:
1. this account's learned names, `NodeRadarDB.learned[locale][name] = { kind = …, source =
   "gather" | "toggle", build = … }` (`kind` is a string or `false`);
2. the shipped library, `NodeRadar.LIBRARY[GetLocale()]` (nodes only).

**From gathering:** `UNIT_SPELLCAST_SENT` for the player, when the spell is Herb Gathering (2366) →
herbs or Mining (2575) → ore, matched by ID and, for other ranks, by `C_Spell.GetSpellInfo(id).name`
(a plain string, else ignored). The target is the node's name (round 3). Gathering is the strongest
evidence: it overrides a toggle's `false`, and a toggle never overrides it (Codex).

**From the toggle**, for an unknown name a radar sweep sees. One experiment at a time:
1. **Start** only when: out of combat, not casting or channelling (`UnitCastingInfo` /
   `UnitChannelInfo`), alive (`UnitIsDeadOrGhost`), standing still (`GetUnitSpeed("player") == 0`),
   not in a loading screen, the gamepad off, the last experiment ≥ 10 s ago, and the tracking's
   spell not on cooldown. Then: a sweep (**before**), `C_Minimap.SetTracking(i, false)`, and
   `NodeRadarCharDB.pendingRestore = spellID` (per character, Codex) **saved before the call**.
2. **Middle**, 1.5 s later: tracking must read off; a sweep.
3. **Restore:** `SetTracking(i, true)` only when out of combat, not casting or channelling, alive
   and not in a loading screen (Codex: round 3 measured the restore's cast out of combat only); else
   retry every 0.5 s, and at `PLAYER_REGEN_ENABLED`.
4. **After**, 2.5 s after tracking reads on again: a sweep; then `pendingRestore` is cleared.

Every diagnostic sweep (before, middle, after) first rechecks the gamepad guard (Codex); a gamepad
turned on mid-experiment voids it (the restore still runs).

**The experiment is void** (nothing learned, the restore still runs) when: the player moved at any
moment (`GetUnitSpeed("player") > 0`, latched every frame from start to after, Codex), the zone
changed, a loading screen came, the player died, the gamepad came on, the minimap's zoom or size
changed, a sweep failed, tracking didn't read off in the middle, or tracking changed in a way we
didn't cause (Codex). **A tracking change by the player wins:** if they turned it back on
themselves, we're done; if they turned off another tracking, we don't touch it.

**The verdict**, on a valid experiment, per name: that kind when it was there before, gone in the
middle and back after; `false` when **every** blip of that name stayed through the middle, **and**
it also stayed through the other gathering tracking's toggle when both are on; anything mixed
(one blip of the name gone, another stayed, or gone and never back) stays unknown (Codex).

**Tracking must come back, even across a reload.** At login and after every loading screen, this
character's `pendingRestore` whose tracking is off is restored (with step 3's conditions), then
cleared. If
tracking is still off 10 s after the first restore attempt, **say so in chat**: "NodeRadar turned
Find Herbs off to learn a node and couldn't turn it back on: please turn it on." Never silent.

**On by default only if the in-game check passes:** whether the restore's cast costs a global
cooldown or interrupts anything hasn't been measured (Codex). The release check (below) measures
it; if it costs, `/nr learn` ships off and learning is by gathering only. **Measured: it costs a
global cooldown (release check, 70450), so `learn` ships off.** Settings save only what the player
set, so a later default reaches everyone who never chose.

**Limits, said in the README:** names are the unit. A quest or NPC with a node's exact name would be
taken for a node, and a node whose name was learned `false` wouldn't alert. Round 3 saw no such
collision.

### New nodes and the alert (`Alert.lua`)

Matching blips across sweeps by their position fails while the player moves: the offsets are the
player's, not the world's (Codex). So v1 counts instead, which no movement or turn changes:
- per node name, the number of its blips now vs the last successful radar sweep. A **rise** is a
  new node. Which blip is new can't be told after the player moved (Codex), so the ring goes on
  **every** blip of that name: one ring when the name was absent before, all of them otherwise;
- a rise right after a drop of that name (within 20 s) is the same node blinking at the map's edge,
  not new;
- a failed or skipped sweep changes nothing: no alert, the history kept (Codex). The history
  resets, and the next successful sweep is a **silent** baseline, when: the zoom or the map's size
  changes, tracking changes (so after every toggle experiment, during which the radar pauses), the
  radar is turned on, or 5 s pass without a successful sweep. After a zone change the history starts
  from zero instead, so a new area's nodes alert;
- at most one alert per `cooldown` seconds (5): `PlaySound(3175, "Master")` (MAP_PING, `willPlay`
  checked), a ring on the map at the blip's drawn position (our unnamed frame on `Minimap`, `HIGH`
  strata, `Interface\Cooldown\ping4`), an optional chat line.

Only nodes the player can gather alert (#26): a rise of a name whose known requirement
(`NODE_INFO`, generated) is above the player's skill (`rank + modifier`, read when a name rises)
neither alerts nor spends the cooldown; it's still counted, so a skill-up doesn't make a node already
on the map new. Herbs above the skill alert while the Tauren's Cultivation (20552) is ready, its state
read only on `SPELL_UPDATE_COOLDOWN` (the client's docs: `isOnGCD` is trustworthy only there).
Anything unknown or unreadable alerts.

Known misses, accepted for v1: a node leaving one edge in the same half second another of that name
enters the other. World positions (`UnitPosition`) would fix it once their axes are measured.

Blizzard's ping (`Minimap:PingLocation`) is optional, solo only (it's sent to the group, round 2),
and off by default. No mounted-only mode: there are no mounts on the beta.

### The library (`Tools/export_nodes.lua`)

`lua5.1 Tools/export_nodes.lua <SavedVariables/NodeRadar.lua>...` merges the learned nodes (`kind`,
never `false`) into `Data/Nodes.lua`:
- every new name is printed with its source and build, for review before committing (Codex: the
  source says how it was learned, not that it's right);
- a conflict, across the inputs **and** the existing library (one name, two kinds), is reported and
  left out; an existing entry is never silently replaced;
- locales must be one of the client's `GetLocale()` values; names are written with `%q`; the
  output is sorted, so a re-run changes nothing.

`pwsh Tools/export_nodes.ps1` finds the SavedVariables files. A test pins the merge, the conflicts
and the file's shape.

### Commands

`/nr` (on/off), `/nr sound|ring|chat|ping|learn`, `/nr cd <1-60>`, `/nr test`, `/nr status`,
`/nr known` (the learned names), `/nr forget <name>`, `/nr failures`, `/nr reset`. An options page
is a follow-up issue.

### Tests

The probe's stubbed minimap (screen-space points, soft cursor, tracking that hides its blips,
`SetTracking`) moves into the shared stubs, with `GetUnitSpeed`, casting, death and loading screens.
Offline:
- the sweep: grouping into blips; the soft cursor off after an error inside the grid;
- learning from gathering (by ID, by rank name), and its precedence over the toggle;
- the toggle: each Codex case (a name that never comes back, a failed sweep, tracking that stays on);
  a cast, combat, death, movement, a zone change or a loading screen between off and on; the player
  changing tracking mid-test; moving and stopping between steps; the gamepad turned on mid-test; a
  `/reload` between off and on (`pendingRestore`, another character not touching it); a restore that
  never succeeds (the chat line); the middle sweep with the only tracking off;
- the alerts: a rise, a blink at the edge, a reset on zoom, the cooldown;
- the export: merge, conflicts with inputs and the library, a re-run that changes nothing.

### Release check, in game (a short procedure in the probe)

- Does the restore's cast cost a global cooldown, or interrupt a cast? Decides `learn`'s default.
- Learning end to end: an unknown herb learned by the toggle, then one by gathering.
- Alerts while walking: a new node pings once; nothing spams.
- A `/reload` during an experiment restores tracking; **settings and learned names survive a full
  client exit** (CLAUDE.md: persistence needs a full exit).
- With Glass MiniMap, and with the stock map: the sweep and the ring behave the same.

## Item icons on the minimap's nodes (#28)

Each herb and ore blip gets the icon of what it gives (Peacebloom, Copper Ore) over Blizzard's
yellow dot; a node the player can't gather gets a dimmed one. A setting, `icons`, **off by
default** (Blizzard's dots) until the owner decides after the second probe round: `/nr icons`, and
in Options "Minimap nodes: Blizzard's dots | item icons". Off, nothing of this runs: no records, no
extra reads, no per-frame update, the sweep exactly as today.

### What it rests on (docs/FOREVER-PROBE.md, "Item icons, first round", 70450)

- A herb's blip answers the mouse over **a square of 25 x 25 units** (eight of eight), around its
  drawn dot (about 8 units across). A mark at the square's measured centre landed on the dot, 0 to
  2 units off its centre.
- The sweep's blip (the centroid of its grid hits) is up to 5.5 units off that centre (a 25-unit
  square holds one or two samples of a 14-unit grid per axis), about 12 yd at zoom 0: not a
  position to draw on.
- `C_Item.GetItemIconByID` answers every `NODE_INFO` item, uncached ones too.
- A mouseover read costs about 13 µs and 2.5 KB of garbage (#11).
- `UnitPosition("player")` reads plainly outdoors (porting guide, 70374). Its first value grows
  north and its second west (HereBeDragons-2.0: `x = left - width * mapX` on the second,
  `y = top - height * mapY` on the first). The second probe round checks this against a gather.
- Glass MiniMap resets the zoom when the player moves (owner): zoom changes are frequent.

### Measuring a blip: `Scan.Centre(blips)`

A new function beside `Scan.Sweep`, with the same guarantee: the soft cursor on inside a `pcall`,
then `putBack` and the soft cursor off on every path; a secret read fails it (`API.Fail`). For each
blip asked for, from its centroid `c` (inside the square: 5.5 < 12.5):
1. `c` itself must read the name; then on each axis and each side, the point 24 units out must
   **not** (a same-name neighbour within about 36 units fails the blip: "crowded");
2. six halvings between `c` and that point find the edge to 0.4 units: 4 edges, 29 reads in all;
3. both widths must be within 2 units of **one node's square**, `Scan.NODE = 25` (measured; the
   bracket's 0.4 and the sampled 24-26 inside it); else "not one node". Two same-name nodes merged
   into one cluster measure as their union, wider on at least one axis (Codex: two nodes at
   (-7, -7) and (7, 7) pass a 10-40 range as a 39 x 39 "square" between them); a union narrower
   than 27 is two dots within 2 units, where one icon between them is still on both.

It sets `b.cx, b.cy` (the edges' midpoints) or `b.why`. `Scan.NODE` is Glass MiniMap's (a
198-unit map); round 2 measures the stock map. If it differs there, nothing is recorded on it and
the dots show, until the constant follows the map.

### Records (`Icons.lua`, new, after `Alert.lua` in the TOC)

A record is a node's name, kind, world position (north and west yards in `UnitPosition`'s frame,
and its instance), its misses, its icon. Only the radar's sweep (`NR.Step`) touches records; the
learner's sweeps don't, and `Alert`'s count-based detection is unchanged.

After each successful radar sweep, in the same frame (the player hasn't moved):
1. **Where:** `UnitPosition("player")` (four plain numbers, else clear everything), the view
   radius and the map's half-width give `k`, yards per unit (#27's conversion). Not in an
   instance (`IsInInstance`), and not with `rotateMinimap` on (Forever has no such option; any
   other value: clear).
2. **Match:** each record is projected to the map (`x = -(west - pw) / k`, `y = (north - pn) / k`)
   and matched to a node blip (`Learn.Kind`) of the same name within 8 units (the centroid's 5.5
   plus the measure's 2), one to one, nearest pairs first. A record's position never changes: a node
   doesn't move.
3. **New:** an unmatched blip fully inside the round map (its centroid plus 18 units within the
   half-width) is measured (`Scan.Centre`), four at most per sweep, nearest the centre first;
   measured, it becomes a record. Not measured (crowded, not one node): no record, Blizzard's dot
   shows, and its name, world position and the time are remembered (a blip of that name within 8
   units is the same try). **Which four:** blips never tried first, nearest the centre first; then
   those tried at least 5 s ago, the longest ago first. So a node never tried is measured at the
   next sweep whatever crowds nearer the centre (Codex: four crowded nodes starved a fifth, and a
   5 s skip alone didn't help at a 5 s idle interval), and a crowded one costs its reads once per
   5 s at most. A try not seen again for 30 s is forgotten; clears forget all.
4. **Missed:** a record with no blip is hidden at once; two misses in a row in valid sweeps drop
   it. A record whose icon has faded out past the rim (half-width minus half the icon) is dropped;
   between the rim band and there it's still matched, so the icon fades rather than pops off.
5. **Gathered:** the player's successful gather of a name (the cast `Alert.Gathered` already
   hears) drops that name's records within 15 yd of the player, so a node of that name appearing
   beside it gets measured, not matched to the gone one.

Matching is by name and distance, not identity: a node gone and another of its name within 8
units (14 yd at zoom 0) by the next sweep, gathered by someone else, keeps the old icon until the
new one leaves (Codex). Accepted: a respawn that close that fast is rare, and the icon is still a
node of that name, one dot-width off.

**Order in `NR.Step`:** the icons reconcile after the sweep and **before** `Alert.Update` (so the
sonar finds an alerted blip's record) and `Learn.Consider` (which can turn tracking off at once,
clearing them).

**Cleared** (records gone, icons hidden): the setting or the radar off; a loading screen,
`PLAYER_ENTERING_WORLD`, a new instance (`UnitPosition`'s fourth value), death; tracking changed
(`MINIMAP_UPDATE_TRACKING`, the learner's toggle among them); a position that reads nil or secret;
an instance or rotation. A zone change in the same world isn't one: positions carry over.
**Hidden, kept:** while no radar sweep succeeded for the idle interval plus 2 s (`db.interval`, up
to 5 s in Options: a fixed 4 s blinked them off between idle sweeps, Codex), so the learner's
pause, the Gamepad UI, the minimap hidden, every sweep failing; shown again after the next one
reconciles.

### Drawing

- One unnamed child of `Minimap` per shown record, `EnableMouse(false)` (the player's own hover
  tooltip keeps working: the round-2 probe checks it). Frames are reused from a free list, as the
  sonar's are: records come and go all ride long, and a hidden frame is never freed. Never `Minimap:SetBlipTexture` or anything
  that changes Blizzard's blips for everyone.
- **Each frame while an icon shows** (an `OnUpdate` on our frame, unset when none show): one
  `UnitPosition("player")`, `C_Minimap.GetViewRadius()` and `Minimap:GetWidth()` (numbers, no
  table: not `C_Map.GetPlayerMapPosition`), then each icon's `SetPoint` from its record. A record
  keeps its world position, made with the radius at its sweep; drawing uses the current one, so a
  zoom, indoors/outdoors or a resize between sweeps is picked up the next frame. Any of them secret or
  nil: hide all until the next sweep.
- **The icon:** `C_Item.GetItemIconByID(NODE_INFO.item)`, its border trimmed (`SetTexCoord`
  0.08-0.92); no item: the profession's tracking icon (Find Herbs or Find Minerals). 12 units
  square by default (the dot is 8; the measure's 2), settled on round 2's screenshots.
- **Dimmed** (`SetDesaturated`, alpha 0.6) when `Alert.Gatherable(name)` says no (#26's rule, so
  the same as what alerts), re-read each sweep (Cultivation changes it).
- **The rim:** full alpha to 10 units inside the half-width, fading to none at 6 (the icon's
  half), hidden beyond. Round maps only (the stock map, Glass MiniMap); square skins with #4.
- **Above and below:** the engine draws a small triangle under the dot of a node below the player,
  inside the hit square (round 1). Round 2 shows whether a 12-unit icon leaves it visible. If it
  hides it, `Scan` keeps the arrow's texture rows before `Scan.Plain` strips them (lower half =
  below, measured; upper half = above, to confirm) and the icon gets a small chevron. Else nothing.
- **The sonar** plays at an alerted blip's record when it has one (`Icons.At(blip)`), else at the
  blip as today.

### Cost

Steady riding: no extra reads (records matched, nothing measured), but a crowded blip: up to 5
reads (the centre and a far point or four) every 5 s. A new node: 29 reads once (0.4 ms, 72 KB of
garbage). Entering a dense area: at most 4 a sweep, 116 reads on top of the grid's 196.
Per frame: three API calls and one `SetPoint` per shown icon, no allocation. Round 2 measures it
against today on the same route: reads per second, garbage per second, the worst sweep.

### Tests

The stubs' blips get centres the stub knows exactly, `UnitPosition`, and a player who moves. Offline:
- `Scan.Centre`: a square measured to 0.4 units from any centroid offset up to 5.5; a same-name
  neighbour (crowded); a quest area's non-square or too-big box; a secret read (fails, soft cursor
  off); the far point beside a different name (still measured).
- Records: match one to one with two of a name side by side; a new blip measured once, then
  matched without reads (reads counted); misses hide then drop; the rim band; a gather drops the
  near record; the tries' order (four crowded and an isolated fifth, over repeated sweeps at a
  5 s idle interval: the fifth is measured at the second);
  every clear and hide trigger, the hide limit with a 5 s idle interval; frames reused; the order
  in `NR.Step`; the learner's sweeps never touch records; dots: no records, no `OnUpdate`, no extra
  reads.
- `Scan.Centre` also: two same-name nodes merged diagonally (Codex's (-7, -7), (7, 7)) and along
  one axis, both refused.
- Drawing: position per frame as the player moves (the stub's `UnitPosition`), a zoom between
  sweeps, the rim fade, dimmed by the skill rule, the fallback icon, `EnableMouse(false)`.
- The sonar at the record.

### Probe round 2 (`/fp steps nr icons`, the feature on)

Icons over the dots standing still, riding and turning (screenshots, notes read); right after a
zoom, and across an indoors/outdoors change; hovering an icon (Blizzard's tooltip unchanged); standing on a node (the player arrow); a node
above the player (the arrow's raw text); a gathered node's record against `UnitPosition` at the
cast (the axes); the cost, icons off then on along the same route; the stock map (Glass MiniMap
off): the square's size there. Defaults (the setting, the icon's size) are the owner's call after it.

**Done** (docs/FOREVER-PROBE.md, "Item icons, second round"): the icons on their dots standing,
zoomed, running and turning, on Glass MiniMap and the stock map; the hover tooltip unchanged; the
12-unit icon over the player's arrow acceptable; Blizzard's arrow for a node above still shows
(upper half, measured): no chevron; a gather put the record 2.6 yd from the player, so the axes
hold; about 2% more reads and garbage per sweep. The stock map's square is 25 too.

### Not in this issue

The compass (#29) reuses the records later. Alternating tracking for dual gatherers, nodes beyond
the tracking range (GatherMate2), replacing the count-based alert with records.

## Icon styles and sizes (#41)

The owner's choices after three probe rounds (docs/FOREVER-PROBE.md, "Glass discs" and "Bronze
rings", 70450):
- The icon's frame **follows the minimap**: a glass disc with Glass MiniMap, a bronze ring like
  Blizzard's round minimap buttons on any other minimap.
- A size choice: "same as the other, make it a choice".
- Icons stay off by default (#28).

### What it rests on

- **Glass:** LibGlass-1.0's `Disc` (r2) built as Glass MiniMap's `Ring.AddDisc`: `disc_small` on a
  square host, the icon inset 18% and masked with `disc_mask_small`. All five looks were liked; at
  these sizes the presets and the shadow barely differ, so clean with its shadow it is, Glass
  MiniMap's own preset. Minor 11 was loaded.
- **Bronze:** Blizzard's round button as LibDBIcon lays it out on a 31-unit button:
  `MiniMap-TrackingBorder` (136430) 53 at its top left, `UI-Minimap-Background` (136467) 20 at
  (7, -5), the icon 17 at (7, -6), masked round (`TempPortraitAlphaMask`). Scaled to the icon, it
  sat centred on every node.
- **The ring hides Blizzard's arrow for a node below the player** (three of three). The arrow for
  a node above stayed visible at the medium size, and only "barely" with plain icons (#28). The
  arrow is in the line's text: `|TInterface\Minimap\Minimap-PositionArrows:0:0:0:0:16:32:0:16:T:B|t`,
  with `0:16` (the upper half) for above and `16:32` for below (both measured).
- LibGlass is loaded whenever Glass MiniMap is (it embeds it); `C_AddOns.IsAddOnLoaded` is in the
  70450 dump.

### Settings

- `iconStyle`: `"auto"` (the default), `"plain"`, `"glass"` or `"bronze"`. Auto is glass when
  Glass MiniMap is loaded and LibGlass can make a clean disc (below), else bronze. A glass choice
  without a usable LibGlass draws bronze; Options says why under the choice.
- `iconSize`: `"small"`, `"medium"` (the default) or `"large"`: the icon exactly 10, 12 or 14 units
  (G, F and H in the bronze round; C's 9 rounded up). The glass disc is 1.5 times the icon (15, 18,
  21) with the icon inset a quarter of its size, not the probe's rounded 18% (which drew 9, 12 and
  13: Codex). The bronze button is 31/17 times the icon (18, 22, 26).
- An unknown saved value (`/nr iconstyle` refuses one, but a file can hold anything) draws as the
  default and is kept as saved, for Options to show.
- Options, under "Nodes on the minimap": "Icon style: Follow the minimap | Plain | Glass | Bronze"
  and "Icon size: Small | Medium | Large", which apply once icons are on. `/nr iconstyle <name>` and
  `/nr iconsize <name>`. A value Options doesn't offer shows and is kept (the page's rule).

### LibGlass, borrowed

No copy is embedded: NodeRadar only draws glass where Glass MiniMap is, and Glass MiniMap embeds
LibGlass. So there's no `.pkgmeta` external, no `Libs\` folder, and nothing new in the package.
- At the first draw that needs it: `rawget(_G, "LibStub")`, then `LibStub("LibGlass-1.0", true)`.
  The minor must be at least 6 (`preset = "clean"`, r6; `Disc` is r2). Then one instance,
  `lib:New({ preset = "clean" })`, in a `pcall`. Any failure (missing, older, a throw): no glass
  this session (`API.Fail("glass", why)`, `/nr failures`), and bronze is drawn.
- Built per frame inside one `pcall` (the host, `Disc`, the icon and its mask). The host is
  created **hidden** and shown only once all of it succeeded: `Disc` isn't transactional (it makes
  the shadow, mask and body, then `g.top`, one after another), so a throw part-way would leave glass
  over the bronze (Codex). A failed host stays hidden for good; the session latch means no glass is
  built or selected again, those already built included, and bronze is drawn.
- Nothing past r6 is used (no `SetWash`, no `SetSurfaceAlpha`): the shadow stays, as liked.
- **Tint:** the instance's clear default. Glass MiniMap's smoked and class themes aren't followed:
  it has no public API for its theme, and its `GlassMiniMap.Theme` is internal. Accepted for now;
  the way to follow it is a Glass MiniMap public API, or #4's API run the other way, the skin
  styling our icons. Its own issue if the owner wants it.

### Drawing

- **The effective look** is resolved once from the settings and LibGlass's state: `style` in plain,
  glass, bronze (auto and a glass that can't be built resolved) and `size` in 10, 12, 14 (an
  unknown value is the default). Only resolved values reach the frames.
- An icon frame keeps its plain texture (`f.tex`) and gains at most **two hosts**, built once each
  when first needed: `f.glass` and `f.bronze`, children centred on `f`, built at the medium size
  and resized with `SetScale(size / 12)` (LibGlass's rule for discs; Codex's simpler shape). A
  child follows the frame's position, its fade (frame alpha) and the dim. Frames are pooled and
  never freed, so that's at most two hosts per pooled frame. For plain, `f:SetSize(size)`.
- **One function binds a frame to its record** (Codex): it selects and builds the effective look,
  hides the others (`f.tex` too, unless plain), and sets the shown look's icon, its desaturation and
  the arrow from the record, **before** showing it. It runs when a frame is acquired, at every sweep
  for each shown record (as `f.tex` is set today), and for every shown record when the style or size
  changes (`NR.Set` calls `Icons.Restyle()`): so a cached look switched to between sweeps never
  shows another record's icon, dim or arrow.
- **The glass latch tripping is a restyle too** (Codex, round 2): a bind that trips it (a later
  record's `Disc` throws after an earlier one's glass was shown) marks a restyle pending; when the
  pass that tripped it ends (a sweep's binding loop, or `Icons.Restyle` itself), every shown record
  is bound again, now to bronze. One deferred pass, no recursion: the latch trips only once.
- **The rim** uses the effective look's half-extent instead of `SIZE / 2`, both for the fade and
  for the drop, so a record is still dropped only once its drawn look has faded out (#28's rim fix):
  plain, the icon's half; glass, the disc's; bronze, the button's (about 0.91 × the icon). The
  arrow and the glass's shadow stick out past it but fade with the frame. `INSIDE` (the hit square)
  and `MATCH` (the position's uncertainty) don't depend on the look.
- **Our own height arrow**, for every style (Blizzard's is covered by a ring, and barely visible by
  a plain icon):
  - `Scan`'s `names()` looks at each row for the `Minimap-PositionArrows` escape (one plain `find`)
    and reads its last two numbers: `0`/`16` is above, `16`/`32` below; no escape is level. It's a
    numeric texture coordinate, not a display string. The row then goes through `Scan.Plain`
    unchanged, so the names Alert and Learn see don't change. No table per row: the height is a
    scalar beside the name.
  - **Heights fold** (Codex): a cell's height for a name is the one observation if all agree
    (rows of that name in the same read included), else `"mixed"`. A blip's height folds its cells
    the same way, through the coarse grid and the refinement. A blip's `height` is `"above"` or
    `"below"` only when every observation agrees; level, mixed or none is nil. So a cluster holding
    two nodes of a name at different heights shows no arrow rather than a wrong one.
  - `Icons.Update` sets the matched record's height from its blip each sweep, nil included, so an
    arrow never outlives its height.
  - Drawn as Blizzard's own texture (`Interface\Minimap\Minimap-PositionArrows`, `SetTexCoord(0,
    1, 0, 0.5)` above, `(0, 1, 0.5, 1)` below), on a child frame above the look (its frame level
    over the glass's top), just outside the look's top or bottom edge. About 6 units wide; the
    round below settles it against Blizzard's.
- The arrow's frame level is above the shown look's top: the glass's `g.top` is the host's level + 10.
- Nothing takes the mouse: looks and arrows are plain frames and textures (never `Ring.AddDisc`'s
  clickable `Button`), and every frame made, `g.top` included, gets `EnableMouse(false)` explicitly.

### Cost

No extra reads. Per new record, one look built once per frame ever (a disc: about 8 textures; a
ring: 3 and a mask). Per frame, still one `SetPoint` and `SetAlpha` per icon: children move with
it. Per sweep, a `find` per mouseover row for the arrow.

### Tests

- The style rule: auto with Glass MiniMap loaded and LibGlass minor 6 or more is glass; without
  either it's bronze; minor 5, a `New` that throws, or a `Disc` that throws is bronze plus a
  failure. A glass choice without LibGlass is bronze. Plain is the #28 icon, unchanged. An unknown
  saved style or size draws the default and stays saved.
- **A `Disc` that throws part-way** (the fake makes a texture and a top child, then throws): only
  bronze shows, the failed host stays hidden, the glass hosts already built stop being shown, and
  later draws build nothing more (Codex). Two records in one sweep, the first's glass built, the
  second's throwing: both are bronze when the sweep returns, with no further sweep or setting change.
- The geometry per style and size: disc 15/18/21 with the icon exactly 10/12/14; the button 31/17
  scaled, the icon at (7, -6), its centre on the node; `SetScale` for a size change, not a rebuild.
- **Binding** (Codex): a frame released and reused for another item and a dimmed node, then a
  switch to its cached other look **without a sweep**: that look shows the new icon, the new dim and
  no stale arrow (above, then level). A size or style change shows the new look only, `f.tex` back
  for plain.
- The rim fade and drop at each look's extent.
- The arrow: `Scan` reads above, below and level from the measured raw rows; opposite heights in one
  cluster give none; two rows of a name at one cell fold; two separate blips of a name keep their
  own; a matched record's arrow goes when its next sweep reads level. **A sweep's `byName` and
  `blips`** are the same with and without arrows in the rows, every field but the new `height` (the
  names, counts, positions, cell counts), and `height` is asserted on its own (Codex: Scan.Plain's
  own tests can't catch the metadata changing names). A row with an arrow and a quest's lines: only
  the node's row carries it.
- Mouse: every frame under an icon frame, `g.top` included, takes no mouse; the arrow's level is
  above `g.top`.
- Options and `/nr`: both settings, an unoffered value kept.
- Every new test mutation-tested; the stubs' fake LibGlass is the probe test's, the methods
  checked against the dump.

### Probe round (`/fp steps nr styles`, the feature on)

- Each style at each size, with a screenshot, Glass MiniMap on and then off (auto switching after
  the reload).
- Our arrow beside a node above and a node below, against Blizzard's.
- Hovering through a disc and through a ring (Blizzard's tooltip).
- A dimmed node in each style.
- The rim fade.
- The cost again (icons off, then on in each style, the same loop), with quest rows in view: the
  arrow's parsing is on every read.

### Not in this issue

Following Glass MiniMap's theme tint. Square minimap skins (#4). Mouse interaction with the icons.

## The compass, experimental (#29)

When a node alerts, a small ring under the character shows which way to turn and how far it is, so
the player can ride to it without watching the minimap. **Experimental**: a setting, `compass`,
off by default, labelled experimental in Options ("Experimental: show which way to the node") and
`/nr compass`. It may never ship on by default: the owner decides after testing. Off, nothing of
it runs.

Within about 15 yards it stops: the glow on the node itself is Lueur's (the soft target, which
Forever loses at 15 yards), and NodeRadar never touches the soft-targeting settings (owner,
2026-10-18). Blizzard's ping and waypoint marker were ruled out (#29: the ping is secure and needs
a GUID; Forever draws no waypoint marker).

### What it rests on (docs/FOREVER-PROBE.md, "The compass, first round", 70450)

- `GetPlayerFacing()`: radians counter-clockwise from north, 0 to 2π, wrapping across north.
- A point's bearing from `UnitPosition` (north, west): `atan2(-east, north)`, east = -west. Facing
  a node read 0.01 rad from its bearing; an arrow at `bearing - facing` (counter-clockwise from
  straight ahead) pointed true ahead and to the left.
- #28's records are good to about a yard at 70 yards (72.7 yd at the start, 72.0 walked, the record
  1.0 yd off at the gather).
- `GetPlayerFacing()` is the character's facing, not the camera's (the camera's yaw isn't readable).
  While the player turns the camera alone (the left mouse button), the arrow follows the character.
  Said in the README and on the Options page.
- `UnitOnTaxi("player")` is in the dump; its value on a flight isn't measured yet (round 2).

### Records without icons

The compass aims at #28's records, so they're kept when icons **or** the compass is on:
`Icons.Keeping()` (radar on, and `icons` or `compass`) gates `Icons.Update`, `Icons.Gathered` and
the measuring; `Icons.On()` (radar and `icons`) still alone decides whether anything is drawn (no
frames acquired, no `OnUpdate` for the icons). So with the compass on and icons off, a new node
still costs its 29 reads once, and nothing changes on the minimap. `NR.Set` clears the records when
`compass` changes too.

### The target

An alert fires when a node enters at the map's edge, where it isn't measured yet (#28 measures a
blip only once it's whole: 18 units inside). So the target starts at the alert's blip and is
refined by its record:
1. **Chosen at the alert** (`Alert.Fire`, after the cooldown and the skill filter): of the alerted
   names' blips, those without a record (an unmeasured node) or with a record made this sweep (a new
   one measured at once), the nearest the player. None: no target for this alert. A target is
   `{ name, kind, north, west, record, at, misses }`, its world position from the record if it has
   one, else from the blip (the centroid, within 5.5 units: about 13 yd at zoom 0).
2. **Refined each radar sweep:** while it has no record, a record of its name within `Icons.MATCH`
   (in yards, at this sweep's scale) becomes its record, and its position the record's. Once
   bound, it follows the record (records don't move).
3. **Seen or missed each sweep:** a blip of its name within `MATCH` of it (projected) is a sighting;
   two missed sweeps in a row dismiss it (as #28 drops a record). A bound record dropped (two misses,
   the rim) dismisses it too.
4. **One at a time:** a later alert's target replaces it.

### The ring

- An unnamed child of **`UIParent`**, centred 160 units below the screen's centre, 120 units across
  (the probe's draft, which the owner followed). Not movable in this issue. **This amends the UI
  contract** in CLAUDE.md ("our frames are unnamed children of `Minimap`"): that rule is about never
  touching the minimap, and the ring isn't on it. It takes no mouse.
- The ring (`Media\SonarRing.tga`, tinted as the sonar: green for herbs, gold for ore), an arrow on
  it (Blizzard's upward triangle, `Minimap-PositionArrows`' upper half, 28 units: its zero is up,
  measured) at `a = wrap(bearing - facing)`, placed at `(-48 sin a, 48 cos a)` and turned by
  `SetRotation(a)`, and the distance in the middle (`"73 yd"`, updated when the whole number
  changes).
- **Per frame while shown** (an `OnUpdate` unset when hidden): one `UnitPosition`, one
  `GetPlayerFacing`, a `SetPoint` and a `SetRotation`. Nothing allocated.

### Dismissed, hidden

- **Dismissed** (target gone, ring hidden): arrival, within 15 yards horizontally **unless** its
  record has a height (#41: above or below, so a node on a ledge over the player isn't "arrived");
  a successful gather of its name within 15 yards of the target (`Icons.Gathered`'s cast; an
  interrupted cast doesn't count); missed twice or its record dropped; 60 s after the alert (not
  restarted by sightings); a later alert's target; the setting or the radar off; a loading screen,
  `PLAYER_ENTERING_WORLD`, a new instance (`UnitPosition`'s fourth value), death; tracking changed
  (the records are cleared); `UnitOnTaxi("player")`.
- **Hidden, kept,** while the position or facing reads nil or secret, or no radar sweep succeeded
  for the idle interval plus 2 s (as #28's icons: the learner's pause, the Gamepad UI, every sweep
  failing); shown again when both read and a sweep has run. The 60 s still counts.
- The distance is horizontal: the minimap gives no node height.

### Tests

- The target: chosen at an alert from an unmeasured blip (the centroid's position) and from a
  record made this sweep; none when every alerted blip has an older record; the nearest of several;
  bound to the record that appears later within `MATCH`, not to one of another name or farther;
  missed twice, dismissed; its record dropped, dismissed; replaced by a later alert.
- Records with the compass on and icons off: measured and kept, no frame, no icon `OnUpdate`; the
  icons then turned on show them.
- The ring: the arrow's point and rotation for a node ahead, left, right and behind, across the
  0/2π wrap, at the measured convention; the distance text; tinted by kind; no mouse; a child of
  `UIParent`.
- Every dismissal and hide trigger, one by one (arrival with and without a height, the gather near
  and far and of another name, the timeout, taxi, death, loading, instance, tracking, the setting,
  the radar, unreadable position or facing, no sweep), and shown again after a hide.
- Off: no target, no frame shown, no `OnUpdate`, no extra reads (icons off too).
- Options and `/nr compass`.
- Every new test mutation-tested.

### Probe round 2 (`/fp steps nr compass2`, the feature on)

An alert's ring appearing, with a screenshot; riding to the node by the ring alone; arrival
dismissing it at 15 yards; a node above (no early arrival); the timeout; a flight (`UnitOnTaxi`);
the camera turned alone (the stated limit); readability over bright and dark ground; the cost of
the records with icons off.

### Not in this issue

A glow on the node within 15 yards (Lueur's). Moving the ring. A target chosen by the player
(clicking an icon). Several targets.

## A public API (#4), after #3

NodeRadar stays standalone: it reads Blizzard's `Minimap`, so it works under any skin (the stock
map, SexyMap, ElvUI, Glass MiniMap). It exposes `PUBLIC_API_VERSION` and a callback (name, kind,
position on the map); a skin that draws the alert itself (Glass MiniMap, as it does with Glass
MiniMap Bar) turns NodeRadar's own ring off.
