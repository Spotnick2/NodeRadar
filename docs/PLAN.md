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
1. `c` itself must read the name; then on each axis and each side, **stepping out by 4 units**
   (`Scan.STRIDE`) finds the first point that doesn't read it, up to 24 (`Scan.FAR`); reading it all
   the way to 24 is "crowded" (one merged with another);
2. four halvings between the last point that read it and that one find the edge to 0.25 units
   (its midpoint within 0.125): opposite edges sum to 25, so their steps sum to 7 or 8, and an
   isolated node costs 31 to 33 reads (29 before); a refused 40-unit shape up to 41 (Codex).

   **Until #47's dumps** step 1 read only the point 24 out, and a same-name neighbour within about
   36 units (24 + its half square) failed the blip: two Silverleafs 35 apart, with a 10-unit gap
   between their squares, each read "crowded: its name again past" the side facing the other
   (docs/FOREVER-PROBE.md). They stayed dots, and the compass, which only knows records, never
   pointed at them. Stepping out stops in the gap. A gap narrower than a step **may** be stepped
   over, by where the centroid falls (Codex: squares at 0 and 26, a centroid at 1 steps into the
   gap at 13 and measures; one at 0 steps over it): then the walk reads on through the neighbour's
   25 units, past 24 ("crowded"). Measured right or refused, never measured off-centre;
3. both widths must be within 2 units of **one node's square**, `Scan.NODE = 25` (measured; the
   bracket's 0.25 and the sampled 24-26 inside it); else "not one node". Two same-name nodes merged
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

Steady riding: no extra reads (records matched, nothing measured), but a crowded blip: up to 37
reads every 5 s (#47's walk; 5 before it). A new node: 31 to 33 reads once (29 before the walk; about
0.4 ms, 72 KB of garbage), and one more per `Scan.Centre` call to put the mouseover back. A shape
refused as "not one node": up to 41. Entering a dense area: at most 4 a sweep, about 132 reads on
top of the grid's 196 (Codex's counts, #47).
Per frame: three API calls and one `SetPoint` per shown icon, no allocation. Round 2 measures it
against today on the same route: reads per second, garbage per second, the worst sweep.

### Tests

The stubs' blips get centres the stub knows exactly, `UnitPosition`, and a player who moves. Offline:
- `Scan.Centre`: a square measured to 0.4 units from any centroid offset up to 5.5; a same-name
  neighbour (crowded); **two same-name nodes 35 and 30 apart on each axis both measured** (#47's
  dumps); 26 apart (a gap under a step): measured from a centroid 1 off (it steps into the gap),
  refused from one on the centre (it steps over it), never off-centre; a quest area's non-square or too-big box; a secret read (fails, soft cursor
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

## A yellow frame (#50)

The owner, after the refined compass (2026-10-19): "for the icon frame, you have glass, bronze, let's
add the yellow from the original minimap tracker dots too". A third frame for the item icons and the
compass's rim, the colour of the minimap's own herb and ore tracking dots.

- **The setting:** `iconStyle` gains `"yellow"`: Options' "Each icon's frame" gets "Yellow" after
  Bronze, `/nr iconstyle yellow`, the help line and the status line's value. **Auto doesn't change**
  (glass with Glass MiniMap, else bronze): yellow is only ever chosen. It needs nothing loaded, so it
  never falls back, and the glass latch doesn't touch it.
- **The colour** (`Icons.YELLOW`, one constant both use): measured from the dots in game, from the
  look round's screenshot of a dot with the icons off (several pixels of the yellow interior of more than one dot, at native resolution, away from the
  highlight, the outline and the antialiased edge: an estimate, JPEG mixing a small feature's colour,
  so the round's side-by-side of the dots and the yellow icons is what accepts it; Codex). A provisional
  `{ 1, 0.82, 0 }` (the client's gold text colour) until the round; measured there,
  `{ 0.92, 0.75, 0.11 }` (docs/FOREVER-PROBE.md, "A yellow frame").
- **The icons' look: our own ring.** `Media/IconRing.tga` (`Tools/make_media.py`, 64 × 64): a white
  band from radius 24.5 to 31.5 px with a 1.5 px dark edge on both sides inside those bounds, tinted by vertex colour (the
  white takes the yellow, the dark edges stay dark, so it holds over a bright map). A third host per
  pooled frame, `f.ring`, built once when first needed like `f.bronze`: the icon masked round
  (`TempPortraitAlphaMask`, texcoords 0.08 to 0.92) at the medium size, the ring 1.3 times the icon
  around it (its inner edge at the icon's edge, 24.5 / 32 × 0.65 ≈ 0.5), `SetScale(size / 12)`.
  `bind` selects, hides and fills it as the other two. `Icons.EXTENT.yellow = s * 0.65` (the ring's
  half), for the rim's fade and drop and the height arrow's offset.
- **The compass:** `Compass.TINTS.yellow = Icons.YELLOW`: the greyscale rim tinted yellow (bright
  on top, darker below, as pearl and bronze), the arc, arrow, lens and capsule unchanged.
- **The arrow, narrower** (compass5's finding: 44 px wide by 44 tall reads sideways at a slant): the
  base 30 px wide (from (17, 52) to (47, 52)), the apex and the base line where they were, so the
  orbit, the reach and the capsule don't move.
- **Tests:** `"yellow"` stored by Options and the slash command, shown as chosen; the ring host built
  once and reused, its file `IconRing.tga`, tinted `Icons.YELLOW`, the icon masked and set, the dim
  on it; switching yellow ↔ glass ↔ bronze ↔ plain hides the others; sizes scale it; the extent used
  for the fade, the drop and the arrow; auto never yellow; a glass latch leaves yellow alone; the
  compass's rim yellow; the arrow art's base corners.
- **Look round** (`yellow`): a dot with the icons off (the colour's screenshot); the icons yellow at
  small, medium and large over bright and dark map; next to the dots of nodes not yet measured; dim
  and the height arrow on yellow; the compass yellow; the narrower arrow at the four diagonals.

## Choosing which herbs and ores (#47)

The owner (2026-10-19): "we will have to do exactly what gathermate has done and have a full setting
of which ore/herb we want to track, because I sure don't want to see this for Peacebloom when I'm
level 300 herbalism", and that it covers "our typical minimap sonar" too. Then: "those will be their
own setting sub-sections like GRF" (Glass Raid Frames' Indicators page under it in the AddOns list).
The owner's choices: one row per item, each node keeping its own required skill; skipping grey nodes;
what a skipped node shows on the minimap a setting, the icon dimmed by default. Then: "select all/none
should also have 'select all that gives skill-up' or 'select all i can gather', and I would seriously
consider a 'smart' mode that autochecks new one you can gather as you level".

### What it rests on

- **GatherMate2** (`..\References\Addons\MapMinimap\GatherMate2\GatherMate2\Config.lua`): a
  Filters page per profession, one checkbox per node ID, every node on by default (`filter["*"]["*"]
  = true`), "Select All" / "Select None"; an unchecked node is still recorded, only not shown. No rule
  by skill. We follow its shape (every node on, buttons per group) by item instead of by node.
- **`NODE_INFO[locale][name] = { skill, item }`** (#26) has every classic node's required skill and
  item: 26 herb items and 13 ore items in enUS. Several nodes give one item (Small, Rich and the two
  Ooze Covered Thorium Veins give Thorium Ore, at 245 and 275), and German has two spellings of
  Mountain Silversage. **Keyed by the item ID**, a choice is an ID (the repo's rule: never save a
  display string), survives a client language change, and needs no export change.
- **Sub-pages:** the porting guide's recipe ("An Options page with sub-pages and an About page"):
  `Settings.RegisterCanvasLayoutSubcategory(category, page, name)` right after the main page from
  the same `PLAYER_LOGIN`, in order; the page hidden at creation, built on its first `OnShow`,
  re-read on every `OnShow`. Measured on 70205 (Glass Raid Frames' Click-casting, Gnomesweeper's
  About) and used by Glass Raid Frames' Indicators (`IndicatorOptions.lua`, `IO.Register`, with
  `API.Fail` when the API is missing or throws).
- **Grey:** the classic gathering colours, by how far the skill is past the node's requirement:
  orange, yellow from +25, green from +50, **grey from +100** (no skill-up). Not measured on Forever:
  Wowhead's Forever tooltips give only "Requires Mining (1)". The look round asks for a node's
  colour where it can (below).
- `C_Item.GetItemNameByID`, `C_Item.GetItemIconByID`, `C_Item.RequestLoadItemDataByID` and
  `ITEM_DATA_LOAD_RESULT` are in the 70450 dump (the client's own `Item.lua` pairs the last two for an
  uncached item); the icons already use `GetItemIconByID`. `SKILL_LINES_CHANGED` is logged by the
  probe.

### An item's state at a skill

For an item of a kind (its nodes in `NODE_INFO[GetLocale()]`, the kind from `LIBRARY`), with the
player's **base rank** in that kind's line (`API.Skill(line, true)`: the rank without the
modifier). Gear and buffs move the modifier: taking off a +5 tool must not read as a skill going down
and reset the list (Codex). #26's `Alert.Gatherable` keeps the effective skill (rank + modifier):
that is what lets a node be gathered.
- **gatherable** when the skill is at least its **lowest** node's requirement (some node of it can
  be gathered);
- **grey** when the skill is at least its **highest** node's requirement + `Track.GREY` (100): every
  node of it is grey. Thorium Ore: gatherable from 245, grey from 375 (Small at 345 still alerts while
  Rich gives skill-ups: the row is per item, the owner's choice; the row shows each node's skill);
- **gives skill-ups** when gatherable and not grey.
No skill line (none learned, unreadable): no state; the presets and smart leave that kind alone.
Cultivation (#26's way in for herbs) doesn't count: these are about the skill.

### Settings

- **Per character** (`NodeRadarCharDB.track`): the choices follow a character's skill (smart, the
  presets), so a 300 main skipping Peacebloom doesn't skip it for a new alt.
  - `ignored = { [itemID] = true }`: the unchecked items. Empty by default: every node tracked (as
    GatherMate2), and an item added to `NODE_INFO` later starts tracked. Non-number keys and
    non-`true` values are dropped at load.
  - `smart = true` (by default: the owner's Peacebloom-at-300 case with no setup): the list follows
    the skill, below.
  - `last = { herbs = n, ore = n }`: the skill smart last applied, per kind.
- **Per account** (`NodeRadarDB`): `ignoredIcon = "dim"`, what a skipped node shows when the icons
  are on: `"dim"`, its icon dimmed as a node the skill can't gather yet; `"dot"`, Blizzard's dot only
  (no record, nothing measured, as if NodeRadar weren't there for it). A look, so account-wide like
  the icons' frame.

### Smart: the list follows the skill

The checkboxes are the one truth (what's checked is what's tracked); smart only edits them when the
skill crosses a line, so the player's own clicks stand in between.
- Checked at `SKILL_LINES_CHANGED` and at the start of each sweep, **before** `Icons.Update` (`NR.Step`:
  `Track.Follow` → `Icons.Update` → `Compass.Reconcile` → `Alert.Update` → `Learn.Consider`), so a
  sweep that crosses a line measures, targets, dims and alerts by the new list (Codex). Per kind with a
  base rank:
  - no `last` for the kind (smart just turned on, a first login, or the skill went down: unlearned
    and learned again): **Skill-ups only** applied for that kind (below), `last` set;
  - the skill went up since `last`: each item that **became gatherable** in `(last, now]` is checked,
    then each that **became grey** in `(last, now]` is unchecked (both in one rise: unchecked);
    `last` set. Nothing else is touched.
  - The base rank going down means the profession was unlearned and learned again (the modifier is
    out of it): start over.
- **Its first run unchecks both the grey items and those not gatherable yet** (Skill-ups only):
  smart checks the latter as the skill reaches them. So with smart on, turning off "Only nodes I can
  gather" (#26) doesn't bring back nodes above the skill; the smart checkbox's note and the
  changelog say so (Codex). For an existing player, the first login after the upgrade does this.
- Turning smart on clears `last`, so it starts from Skill-ups only; turning it off leaves the list as
  it is.
- An item checked by smart that the player unchecks stays unchecked until its next line (grey, or
  never if it's already past both); one the player checks while grey stays checked.

### The presets (each page, that kind only)

"All" (every item checked), "None" (every item unchecked), "All I can gather" (gatherable checked,
the rest unchecked), "Skill-ups only" (skill-ups checked, the rest unchecked). The last two need the
skill: with none, they say so on the page and change nothing. A preset is a set of clicks: smart
carries on from it.

### The rule

In `Alert.lua`, beside `Alert.Gatherable`:
- `Alert.Ignored(name)`: false for a name without `NODE_INFO` (learned on Forever, unknown: it can't
  be listed, so it can't be skipped); true when its item is in `ignored`.
- `Alert.Wanted(name) = Alert.Gatherable(name) and not Alert.Ignored(name)`.

Where it applies, everything NodeRadar does for a node:
- **The alert** (sound, sonar, chat line, ping): `Alert.Update` fires only for `Wanted` names. A
  skipped name still updates its count history, so tracking it again doesn't alert for nodes already
  in view.
- **The compass:** `choose` takes only `Wanted` records, the incumbent too (a skipped incumbent is
  dropped; the hysteresis doesn't keep it).
- **The icons:** with `ignoredIcon = "dim"`, `r.dim = not Wanted`. With `"dot"`, or with the icons
  off (the compass alone keeps records), a skipped name's blips are left out of the match and the
  measuring (`Icons.Update`'s `blips`), so its records miss and drop as any missed record, and no new
  one is measured: no `Scan.Centre` reads spent on it.
- **A change applies at once** (`NR.Track.Set(item, on)`, a preset, smart, `NR.Set("ignoredIcon")`):
  `Icons.Refilter()` releases the records of skipped names when they shouldn't be kept, and re-binds
  the rest (`Icons.Show`, so a dim follows); `Compass.Refresh()` chooses again. A preset or a `Follow`
  pass changes all its items first, then refilters and refreshes the page once.

`Track.lua` (after `Alert.lua` in the TOC) holds the per-character table, the item list per kind
(built once per session from `NODE_INFO`/`LIBRARY` for the locale, sorted by the lowest
requirement, then item ID), the states, the presets, `Follow` and `Set`.

### Options

- **The main page**, under "Only nodes I can gather": a note "Choose which herbs and ores on the
  Herbs and Ores pages, under NodeRadar in the list." Under the icon size: "A node you skip" with
  "Its icon, dimmed" | "Blizzard's dot" (`ignoredIcon`).
- **Two sub-pages, "Herbs" and "Ores"**, registered right after the main page, in that order
  (`Options.Register` calls `TrackOptions.Register(category)`; one builder for both,
  `TrackOptions.lua`, after `Options.lua` in the TOC). Each, top to bottom:
  - a title and a note: "Unchecked: no alert, no chat line, never the compass's target; on the
    minimap as the main page says. For this character. Names NodeRadar learned on Forever aren't
    listed and always count.";
  - the smart checkbox, the same setting on both pages: "Smart: follow my skill (check a node when I
    can gather it, uncheck it when it turns grey)";
  - the four preset buttons;
  - one row per item of the kind, **in three columns filled top to bottom** (the owner, after the first
    round: "a few columns instead of a long list"), each one line: a checkbox (checked = tracked),
    the item's icon, the item's name (clicking it clicks the box), its skill coloured ("15", or
    "245-275" when its nodes differ); **hovering it shows each node with its own skill** in a
    tooltip. What follows was the first round's single column, kept for its details: the item's name
    (`GetItemNameByID`; until the client has it, the first node's name: the page asks for each missing
    one, `RequestLoadItemDataByID`, keeps the asked IDs, and re-reads its rows on `ITEM_DATA_LOAD_RESULT`
    for one of them while shown: Codex), and under it each node with its own skill, lowest first
    ("Small Thorium Vein 245, Ooze Covered Thorium Vein 245, Rich Thorium Vein 275, ..."), each
    number in its gathering colour at the current skill (orange, yellow, green, grey; red-grey when
    it can't be gathered yet);
  - in a scroll frame, as the main page (the herbs run past the window).
- A locale without `NODE_INFO`: the pages say so and list nothing.
- Smart changing a checkbox while a page is open re-reads it.

### Commands

- `/nr ignore <node or item>` and `/nr track <node or item>`: a node's name in the client's language
  or an item's (case-insensitive; the item's name only once the client has it), or an item ID; the
  item is set and named back ("Thorium Ore: skipped (Small Thorium Vein, ...)"). Unknown: says so.
- `/nr ignore` alone lists the skipped items; `/nr smart` toggles smart. The help and status lines say
  both.

### Tests

- The states: gatherable at the lowest node's requirement, grey at the highest + 100 (99 not), per
  item with nodes at two requirements; no skill: none; from the base rank, a modifier not counting.
- Smart: first run applies Skill-ups only per kind; a rise crossing a requirement checks that item
  and nothing else; a rise crossing grey unchecks it; a player's uncheck stands until its next line;
  a base rank going down starts over, a modifier going down changes nothing (the player's clicks
  stand); one rise crossing both lines unchecks; smart off touches nothing; a kind without a skill
  untouched; `SKILL_LINES_CHANGED` and the sweep both run it, the sweep before the icons.
- The presets: each, per kind only; without a skill, the two skill presets change nothing.
- The rule: a skipped item silences every node of it (sound, sonar, chat, ping) and only those; a name
  with no `NODE_INFO` is never skipped; tracked again, nodes already in view don't alert.
- The compass: a skipped nearest passed over for a farther one; a skipped incumbent replaced at once,
  the hysteresis not keeping it; all skipped: hidden.
- The icons: `"dim"` dims a skipped node and undims it when tracked again, at once; `"dot"` drops its
  record at once and measures none (no `Scan.Centre` for its blips), tracked again it's measured at
  the next sweep; the compass alone measures none of it.
- The settings: the per-character table made and cleaned at load; `/nr ignore` and `/nr track` by node
  name, item name, item ID, unknown; the list; `/nr smart`.
- The pages: registered after the main page, Herbs then Ores, under it (the stub records the order),
  a missing API recorded by `API.Fail`; built on the first show, not before; one row per item,
  sorted, every node with its skill and colour; a checkbox click skips and tracks; each button; the
  smart checkbox; re-read on show (a slash change shows); a missing item name asked for once and
  filled when its `ITEM_DATA_LOAD_RESULT` comes, another item's event ignored.

### Look round (`/fp steps nr track`)

The sub-pages under NodeRadar with a +/−, both rendering on the first visit; the rows (icons, names,
skills in colour) and scrolling; smart on: what it chose at the current skill; a node near you
unchecked: no alert, the compass skips it, its icon dimmed, then Blizzard's dot with the other choice;
tracked again; each preset; item names on a cold cache (a fresh client start); and, where the client
colours a node's skill in its tooltip, that colour for a check of the +25/+50 lines and, on a
character whose skill is 100 past a node near it, the grey line (Codex).

## The compass, experimental (#29)

A small ring under the character shows which way to turn and how far it is to **the nearest node
the player can gather** that NodeRadar has measured, so the player can ride from node to node
without watching the minimap. **Experimental**: a setting, `compass`,
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
- `UnitOnTaxi("player")` is in the dump; its value on a flight isn't measured yet (round 2: the
  owner was in Orgrimmar, with no node in view).
- **Round 2 (the alerted-node design, `compass2`):** the ring led to its node and went at 14.9 and
  15.0 yards; the 60 s timeout held; clicks went through it; Edit Mode and combat were clean; the cost
  was the icons-off cost (262 reads a sweep). But following the *alerted* node fell short (owner): it
  "does not necessarily point to the closest herb and also vanishes with herbs on the minimap" (its
  record dropped past the rim after a zoom in, or missed in a clump). So the target became the
  nearest gatherable record, chosen again every sweep (owner, 2026-10-19). A skip ("not that one,
  it's out of reach") waits for the final version (owner).

### Records without icons

The compass aims at #28's records, so they're kept while icons **or** the compass is on, and each
setting does only its own part (Codex, #29):
- `Icons.Keeping()` (radar on, and `icons` or `compass`) gates `Icons.Update`'s matching and
  measuring and `Icons.Gathered`.
- `Icons.On()` (radar on and `icons`) alone gates **every minimap icon drawn**: in `Icons.Update`'s
  last part, acquiring frames, `bindAll` (so no icon look is built for the compass alone) and the
  driver's `OnUpdate`. Not just `draw()`: by then the frames would exist. The compass's own ring
  resolves the style itself (`Icons.Style()`, below).
- **Settings:** the radar off, or both off: records cleared. `icons` off with the compass on: the
  icon frames released and the driver stopped, the records kept. `icons` on: the records kept are
  bound and drawn at once. `compass` off: the ring hidden, the records kept while icons are on.
  `compass` on: nothing to do until the next sweep.

With the compass on and icons off, a new node still costs its 31 to 33 reads once, and nothing changes
on the minimap.

### The target

**The nearest gatherable record**, chosen again at every radar sweep, in `NR.Step` right after
`Icons.Update` (`Compass.Reconcile`): of the records kept (#28's, every one, a record missed once
included: a miss means not matched this sweep, not a wrong position, and leaving it out would make
the ring vanish in clumps again: Codex), those `Alert.Gatherable` allows (#26's filter as the alert
uses it, read fresh, never `r.dim`, which only the icons refresh: so unknown requirements, an
unreadable skill and `skillOnly` off all count as gatherable), the nearest the player horizontally. None: no target, the ring hidden. Nothing ties it to an alert: no pending
target, no timeout. It moves on by itself: a gathered node's record goes (`Icons.Gathered`), one
past the rim is dropped, and the next nearest is the target at the next sweep.
- **Hysteresis:** the current target stays unless another is at least 5 yards nearer, so two nodes
  about as far don't make the arrow flick between them; but only while that very record is still in
  `Icons.Records()` and still gatherable. Gone or no longer gatherable, the nearest wins outright
  (Codex).
- **A gather** (`Icons.Gathered`, the successful cast) chooses again at once, **after** the gathered
  records are out of the list (one call once `records` is the filtered list, not one per drop), so
  the ring moves on without waiting for a sweep. It doesn't count as a sweep: the ring's freshness
  (a sweep within the interval plus 2 s) isn't renewed by it.
- **A gathered node's dot lingers** (the owner's video, 2026-10-19: the ring showed the next node as
  the gather landed, hid half a second later, and came back about 3 s on). The node stays on the
  minimap while its loot window is open: the next sweep saw a dot of its name with no record beside
  the player, measured it, and the ring took it as the nearest, within 15 yards: hidden. So
  `Icons.Gathered` remembers each gathered node, `gone = { name, north, west, near, seen }`: at the
  record's position (`near = Icons.MATCH` units) when one was dropped, else at the player's
  (`near = Icons.GATHERED` yards, a node gathered before it was measured). At each sweep a blip of
  that name within `near` of an entry is **left out** (not matched, not measured, no record), and
  marks it seen; an entry not seen at a sweep is forgotten (the dot is gone: the node despawned),
  and none outlives `Icons.LINGER = 30` s (loot left open, or a node partly looted that stays). A
  respawn there comes minutes later, after the entry is forgotten, and is measured as any new
  node. The alert is untouched: it counts names (`Alert.Gathered` already covers the drop).
  Accepted limit (Codex): every dot of the name within the radius is left out, and a second one
  there keeps the entry seen after the gathered dot is gone, so it stays a dot until `LINGER`
  (within 8 units its square overlaps the gathered one's and couldn't be measured anyway; within
  the 15-yard fallback, only for a node gathered before it was measured).
- **Records cleared** (any reason: `Icons.Clear`) drop the target at once, and the gone entries
  with them.
- Each frame draws toward the target's world position (the record's): records don't move.
- A node of a name in a clump can lose its record (a merged cluster's centroid misses it, #28's
  stated limit: the dot shows there too); the compass then points at the nearest record left. That's
  the icons' limit, not the compass's: measured, not chased here.

### The ring

The owner's choices after two look rounds (docs/FOREVER-PROBE.md, "The compass's look", first and
second rounds): **the node's item icon in a disc just around it, the arrow orbiting outside the
disc, the distance in a pill under it, the item's tooltip on hover**; the disc's frame **follows the
icons' frame setting** (#41), and a **size option**.

- **Where:** an unnamed child of **`UIParent`**, centred 160 units below the screen's centre. Not
  movable in this issue. **This amends the UI contract** in CLAUDE.md ("our frames are unnamed
  children of `Minimap`"): that rule is about never touching the minimap, and the ring isn't on it.
- **The frame** is #41's effective style, resolved by `Icons` (one rule, one LibGlass latch):
  - **glass**: a LibGlass disc (`disc_small`; the plain glass rim, round 2's E: Glass MiniMap's
    `ring_rim` art left a light edge at this size, D), the icon round in it;
  - **bronze**: the icon in Blizzard's round button (#41's `MiniMap-TrackingBorder` layout);
  - **plain**: the icon alone, masked round.
  `Icons` exposes the resolution without drawing icons (`Icons.Style()`: the style, resolving and
  latching glass as `resolve()` does). So with the compass on and the icons off, the compass may build
  glass (it draws it); the icons still build no **minimap icon** frame, host or driver.
- **One latch for both** (Codex): a glass failure in either consumer (an icon's `Disc`; the
  compass's `Disc`, pill `Apply`, mask or font) trips `Icons`' latch, and when the pass that tripped it
  ends, **both** rebind to bronze: `bindAll` for the icons, `Compass.Restyle()` for the compass. No
  recursion; cached glass is never selected again. `NR.Set` calls `Compass.Restyle()` on `iconStyle`
  and `compassSize` too (with the icons off, `Icons.Restyle()` does nothing).
- **Sizes**, `compassSize`: `"small"`, `"medium"` (the default) or `"large"`: the **outer
  diameter** 44, 52 or 60 units in every style, built at medium and resized with `SetScale`
  (LibGlass's rule for discs), so the icon and the arrow scale with it (about 30/36/42 and
  12/14/16). Nothing under 44: F's 36 had rough edges (the small disc textures). One host per style,
  built when first needed.
  - Glass: the icon about 0.69 of the disc.
  - Bronze: LibDBIcon's proportions at that outer size (the button 31 = the diameter, the icon 17/31
    of it, about 0.55: smaller than glass's), not #41's icon-first scaling (Codex: 36 by 31/17 would
    be 66 across).
  - Plain: the icon fills the diameter, masked round.
- **The arrow:** Blizzard's upward triangle (`Minimap-PositionArrows`' upper half; its zero is up,
  measured), at `a = wrap(bearing - facing)`, on an orbit just outside the disc (radius = half the
  disc + 0.7 × the arrow), turned by `SetRotation(a)`, on a frame above the glass's top (host + 10).
- **The distance pill:** under the disc, **below the arrow's orbit** (its top half the disc + 1.5 ×
  the arrow under the centre: D put the arrow on the pill when pointing behind; Codex's bound: 3 to 4
  units clear at every angle and size, the glass pill's soft shadow aside). Glass: a LibGlass
  `small` surface with the instance's font (Glass MiniMap's coordinates pill). Bronze and plain: the
  same text on a dark rounded backdrop. `"73 yd"`, updated when the whole number changes.
- **The tooltip:** on hover over the disc, `GameTooltip:SetItemByID(item)` (FrameXML's secure
  accessor; the item from `NODE_INFO` through `API.Num`), anchored above; the accessor shows it, and
  on a refusal or no data it hides it (no unconditional `Show`). No item: no tooltip. **When the
  target changes under a still cursor** the owned tooltip is set again, or hidden if the new target
  has no item (Codex). Leaving, hiding or restyling hides it **only if the compass owns it**. The
  disc takes **mouse motion only**: `SetMouseMotionEnabled(true)`, `SetMouseClickEnabled(false)`
  (both in the 70450 dump; Blizzard's cooldown viewer uses this split), set after the handlers, so a
  click on the disc reaches the world (round 2: with the mouse on, it didn't). The pill, the arrow
  and every glass `top` frame take none.
- **Per frame while shown** (an `OnUpdate` unset when hidden): one `UnitPosition`, one
  `GetPlayerFacing`, the 15-yard and hide checks, a `SetPoint` and a `SetRotation`. Nothing
  allocated. Hidden, it shows again at the next usable sweep. The icon, the style and the size are
  set when the target, the style or the size changes, not per frame.
- The green ring of the first rounds (`Media\SonarRing.tga`) goes.

### The ring, refined (a critique the owner shared, 2026-10-19)

GPT's critique of the shipped look, with a mockup: the bezel dominates the small widget, the
direction marker is too small, the distance label feels detached. The refinement keeps the footprint
(44/52/60), the target, the bearing, the hysteresis, the hide rules, the tooltip and the settings;
only the drawing changes.

- **Our own textures, no LibGlass for the compass.** The look is layers NodeRadar ships
  (`Tools/make_media.py`, plain Python, 32-bit TGA with RGB and 8-bit alpha, power-of-two sides,
  committed), so **the compass uses our own art for every effective style** (the style is still
  `Icons.Style()`'s: auto checks Glass MiniMap, glass checks LibGlass, else bronze), and the compass's
  half of the shared glass latch goes (`Icons.GlassFailed`, the
  compass's `buildGlass`). The style still follows the icons' frame (`Icons.Style()`):
  **glass → a pearl rim, bronze → a muted bronze rim, plain → no rim** (the lens and the icon only).
  The owner may replace any texture with painted art at the same size and layout (the specs are in
  `Tools/make_media.py`'s header).
- **The layers**, bottom to top, all centred on the disc:
  1. `CompassShadow`: a soft black disc a little larger than the rim, nudged down 2 units: separates
     the widget from the terrain.
  2. `CompassLens`: a dark translucent disc (near black, about 0.62 alpha at the centre to 0.75 at
     the edge) with a faint inner boundary at the icon's edge: readable over bright ground and dark
     interiors (there's no live blur).
  3. The item icon, masked round, **about 0.58 of the diameter** (was 0.69: more breathing room),
     upright.
  4. `CompassRim`: a thin ring (about 1/16 of the diameter), greyscale, bright along the top and
     darker along the bottom (the glass reads from that variation, not from an even outline), tinted
     pearl or bronze by vertex colour.
  5. `CompassArc`: a 25° highlight on the rim, centred at the top of the texture, turned with the
     arrow (`SetRotation(a)`, the texture's centre the disc's): the bearing's accent, not a gauge.
  6. `CompassArrow`: a solid white triangle with a fine dark outline, flat base toward the centre, no
     stem; 16 units at medium (was 14), turned by `SetRotation(a)`. White in every style. **Its art,
     64 px:** the apex 24 px above the centre (0.375 × the arrow), the base 20 px below (0.3125), 30 px
     wide (0.47; 44 until #50: near equilateral, it read sideways at a slant), the 3 px outline inside
     those bounds. So its centre on an orbit of half the disc + 1
     + 0.3125 × the arrow puts the base 1 unit outside the rim, and its farthest point (the apex) is
     the orbit + 0.375 × the arrow: 38 units at medium (the base corners reach less, 27.3).
- **The capsule:** `CompassPill`, a dark translucent capsule with a thin subdued outline, **fixed
  width** (56 × 18 units at medium: no width change as the number changes), crisp white text
  (`GameFontHighlightSmall`), its top 3 units below the arrow's farthest reach (41 under the centre
  at medium, from the art's 38: closer than 47).
- The earlier subsection's LibGlass disc and glass pill for the compass are superseded by this one.
- **Tests** (replacing the compass's glass cases): with the icons off, the compass calls no
  LibGlass `Disc`, `Apply`, `Mask` or `Font` and makes no icon frame; an icon's glass failure still
  turns a pearl rim bronze at once (the icons turned on between sweeps too); each style's layers
  (plain without a rim); the icon 0.58 of the diameter; the capsule 56 × 18 whatever the text; the arc
  and the arrow share the angle, the arc the disc's centre, the icon unturned; the orbit and the
  capsule from the art's numbers; a style switched at the same distance fills the capsule.
- **Look round** (`compass5`): bright ground and a dark interior; a full rotation with the
  diagonals and the wrap; a herb and an ore if the character mines; every effective style at every
  size, with and without Glass MiniMap; the rim and arc in register, the outline, the capsule's
  clearance and its text at the largest distance, small-size edges; the hover, clicks, camera drag,
  combat, Edit Mode and a ride kept.
- **Motion:** only the arrow and the arc move; the icon and the text stay put. No smoothing (there is
  none today), no pulse, no shine.
- **Hover** shows the tooltip and changes nothing drawn.

### Moving it (#57)

The owner (2026-10-19): "we should be able to move it with alt-click like apotheca". Apotheca's
recipe (`..\Apotheca\Apotheca.lua`, "DRAG ANCHOR"): while Alt is held over the bar, an overlay that
takes clicks and says "Drag to move"; its state read from live input, never one key event.

- **The hit area:** `hit`, a frame on `body` (so it scales with the size) covering the compass's
  footprint: `2 * REACH` wide, from `REACH` above the disc's centre to the capsule's bottom
  (`PILL_TOP + PILL[2]`) below it: 76 by 97 at medium, its centre 10.5 below the disc's, so anchored
  by its top to `REACH` above the body's centre, not centred on it (Codex). It takes no mouse; it
  exists to ask `hit:IsMouseOver()` (a geometry query, mouse enabled or not).
- **The overlay:** `grip`, over `hit` (same rect), at `over:GetFrameLevel() + 1` (above the arrow's
  explicit level; the compass's strata, no `DIALOG`: Codex), hidden
  until wanted: `EnableMouse(true)`, `RegisterForDrag("LeftButton")`, a translucent dark fill and
  "Drag to move" (`GameFontNormalSmall`). Shown exactly while **Alt is down
  (`IsAltKeyDown()`), the position isn't locked, the compass is shown and the mouse is over `hit`**,
  or a drag is under way. Read live: on `MODIFIER_STATE_CHANGED` (LALT, RALT) and every frame the
  compass draws (its `OnUpdate` already runs while shown; `IsAltKeyDown` and `IsMouseOver` are
  cheap), after the frame's own show-or-hide decision, so a missed key-up (alt-tab, a popup) can't
  leave it stuck on. **A drag under way ends when Alt is released or the lock is set** (stopped,
  placed, saved, the grip hidden: Apotheca's rule, Codex); the mouse leaving the hit area doesn't
  end it. The stop is idempotent: the grip's `OnHide` calls it too. Without Alt nothing changes:
  the disc takes motion only and clicks reach the world.
- **Dragging:** `root:SetMovable(true)`; `OnDragStart` → `root:StartMoving()`; `OnDragStop` (and
  the grip's `OnHide`, so a compass hidden mid-drag never leaves the root on the cursor) →
  `root:StopMovingOrSizing()`, then **placed and saved**: the root's centre minus `UIParent`'s, in
  `UIParent` units (the root is its child at scale 1). The compass has no secure children, so
  Apotheca's combat handling isn't needed; a drag in combat is allowed.
- **Placed** (`place()`, at the first show, on a size change, after a drop, on a reset, and on
  `UI_SCALE_CHANGED` / `DISPLAY_SIZE_CHANGED`, a drag under way ended first: Codex): the
  saved `compassX, compassY` (account-wide, like `compassSize`; nil: the default `0, -160`),
  **clamped** so the whole footprint (at the current size) stays on `UIParent`. Done on the numbers
  rather than with `SetClampedToScreen`: the root is a 1-unit frame, and the footprint is drawn by
  its scaled child. With `s = size / 52` and `UIParent`'s `W, H`: `-W/2 + 38s <= x <= W/2 - 38s`,
  `-H/2 + 59s <= y <= H/2 - 38s` (the offset is the root's centre minus `UIParent`'s, both in
  `UIParent`'s units: not divided by its scale again). A position saved on a larger screen or UI
  scale comes back on screen. After `StopMovingOrSizing`, the centre is read, the points cleared and
  the one `CENTER` anchor set again.
- **Locked:** `compassLock` (false by default): no grip at all. Options, under "Compass size": a
  checkbox "Lock its position", and a note "Hold Alt and drag the compass to move it." Commands:
  `/nr compass lock`, `/nr compass unlock`, `/nr compass reset` (the default place); `/nr compass`
  alone still turns it on or off. **`/nr reset` clears `compassX, compassY` too** (they're nil
  defaults, outside `DEFAULTS`' keys: Codex). Both resets work with the compass hidden or off.
- **The tooltip:** the grip over the disc takes the hover; the disc's `OnLeave` hides its tooltip.
- **Tests:** the grip hidden without Alt, shown with Alt over the compass, not with Alt elsewhere,
  not when locked, not when the compass is hidden; gone when Alt is released (the live read, no key
  event); a drag start moves the root, the drop saves its offset and re-anchors it; a drop past an
  edge clamped (each of the four bounds); a saved position off screen clamped at the first show;
  the size changing re-clamps; `UI_SCALE_CHANGED` re-clamps; **Alt released mid-drag, the lock set
  mid-drag, hidden mid-drag: each stopped, placed and saved, once**; `/nr compass reset` and
  `/nr reset` with the compass off; lock; the commands; Options' checkbox; clicks still pass through
  without Alt (`SetMouseClickEnabled(false)` untouched).
- **Look round** (`/fp steps nr compassmove`): Alt over the compass shows the grip, without Alt the
  world gets the clicks; the tooltip handed over under a still cursor; drag it somewhere, `/reload`,
  it's there (and after a full client exit, once); drag it past the screen's edge, it comes back
  fully on; Alt released mid-drag; the UI scale changed with it near an edge; lock, Alt shows
  nothing; reset while it's hidden.

### Snoozing the compass's node (#46)

The owner (2026-10-19): a way to say "not that one" when the compass's node is out of reach (above
the player, or guarded by mobs too strong), so it moves on to the next. Not permanent: "a 'snooze'
button like Outlook". Their choices: a **NodeRadar minimap button** (left-click: a context menu,
right-click: the settings) and a **key binding**; the snooze asks for how long (15 minutes, 30
minutes, 1 hour, this session); a way to clear them, a reload doing it too. And: "left-click on the
minimap button will probably lead to more actions in the future, so maybe we should add a menu to
toggle icons/compass and the snooze there (contextual menu, not a full panel)".

- **A snooze** is `{ name, north, west, instance, untilT }` in memory only (`math.huge` for "this
  session"): never saved, so a `/reload` or a logout clears every one. It covers the record the
  compass points at **and that node measured again later** (the record is dropped when it leaves
  the minimap, and a new one is made when it comes back): a record of the same name, the same
  instance, within `Compass.SNOOZE_NEAR = 8` **world yards** of the snoozed spot (a re-measured
  node lands within about 2 yards: #28's measure is to 0.25 units, about 0.4 yards at the default
  zoom; not `Icons.MATCH`, which is in map units). The instance is `UnitPosition`'s fourth value:
  records hold none (Icons clears them on an instance change), so a snooze stamps the player's at
  the time and is compared with the player's now. Same-name nodes within 8 yards count as one spot
  (Codex: accepted). Expired snoozes are dropped as they're met: the next sweep's `Icons.Show` and
  `Compass.Reconcile` redraw and re-choose, so no timer runs.
- **Kept apart from the clears:** `Compass.Reset` and `Icons.Clear` (loading screens, death,
  tracking changed, the settings) leave snoozes alone; only a reload, a logout or a clear ends them.
- **The compass:** `choose` skips records under an active snooze, the incumbent too (the
  hysteresis can't keep a snoozed target). A snooze chooses again at once (`refresh`): the next
  nearest wins outright, as the issue asked. With every node snoozed, no target: hidden.
- **The icons:** a snoozed node's icon is dimmed (`r.dim` also when `Compass.Snoozed(r)`), so the
  player sees which one they put aside. **At once:** a snooze and a clear call `Icons.Show()` (which
  recomputes `r.dim` and binds), not only the compass's refresh: `Icons.draw` reads the cached dim
  (Codex). The alert is untouched (it's about nodes coming into range); #47's `Alert.Wanted` and
  the gathered-dot rule stay as they are, a snooze an extra filter on top of them.
- **Snoozing** (`Compass.Snooze(seconds | "session", record)`): a given record, by default the
  compass's current target; nothing without one. `lastSweep` is kept (an immediate re-choice, not a
  sweep). **Clearing** (`Compass.ClearSnoozes()`): every snooze, the compass chooses again, the
  icons re-dim.
- **The minimap button** (the owner's sibling addons' recipe, GuildSpy's `Minimap.lua` after
  Gnomesweeper's): a LibDataBroker launcher shown by LibDBIcon-1.0, so it drags around the ring, and
  minimap skins and button collectors (Glass MiniMap Bar) take it like any other. Its position and
  whether it's shown are LibDBIcon's table, `NodeRadarDB.minimap`, made once at `ADDON_LOADED` and
  never replaced; shown by default, a checkbox in Options ("A NodeRadar button on the minimap").
  Registered at `PLAYER_LOGIN` inside a `pcall`: no libraries, or the name taken, means no button
  and nothing else breaks.
  - **Left-click: NodeRadar's context menu** (`MenuUtil.CreateContextMenu`, Blizzard_Menu,
    70450), the place for quick actions, more later (the owner):
    - checkboxes: "Radar on", "Item icons on the minimap", "The compass (experimental)" (`NR.Set`,
      so the page and `/nr` agree);
    - a divider; "Snooze <item's name>, <yards> yd" opening a submenu: "15 minutes", "30 minutes",
      "1 hour", "This session". No target: a disabled line saying why ("The compass has no node
      now", or "The compass is off"). **The node is captured when the menu opens** and the choice
      snoozes that one, even if the compass moved on meanwhile (sweeps go on while it's open:
      Codex);
    - "Clear snoozes (N)" when there are some.
  - **Right-click:** NodeRadar's Options page.
  - **Its tooltip:** "NodeRadar"; the compass's node and distance, or none; how many are snoozed;
    the hints (left-click, right-click, drag).
  - **The AddOns compartment** (the TOC's `AddonCompartmentFunc*`) clicks the same way, for players
    who hide minimap buttons. Its callback gets `(addonName, mouseButton)`, not a frame
    (Blizzard's AddonCompartment.lua), so the menu's owner is the minimap button only when the
    first argument is that shown button, else `nil` (the cursor: `CreateContextMenu`'s default)
    (Codex). The TOC gets `## IconTexture` (Find Herbs' icon).
- **The key binding** (Esc > Options > Key Bindings > NodeRadar, `Bindings.xml`, its own
  category): "Snooze the compass's node", for `snoozeFor` (Options: 15 minutes, 30 minutes, 1 hour,
  this session; "this session" by default), with a line in chat saying what and for how long.
- **Commands:** `/nr snooze` (for `snoozeFor`), `/nr snooze 15 | 30 | 60 | session`,
  `/nr snooze clear`.
- **The libraries:** LibStub, CallbackHandler-1.0, LibDataBroker-1.1 and LibDBIcon-1.0, committed
  in `Libs\` with their licence files, as GuildSpy ships them (the same versions: LibDBIcon minor
  56), loaded first in the TOC (LibStub, CallbackHandler, LibDataBroker, LibDBIcon). CI's package
  check allows exactly those files: the TOC's Lua, **`Bindings.xml`** (found by its name, not in the
  TOC: porting guide), and the licences that exist (`Libs/LibStub/LICENSE.txt`,
  `Libs/CallbackHandler-1.0/LICENSE.txt`, `Libs/LibDBIcon-1.0/LICENSE.txt`; LibDataBroker has none)
  (Codex).
- **Tests and the libraries** (GuildSpy's recipe, Codex): the harness's `tocFiles()` leaves `Libs\`
  out of the files behaviour tests load (`tocFiles(true)` lists them for the inventory; `luac -p`
  checks every one); the stubs answer `LibStub("LibDataBroker-1.1")` and `("LibDBIcon-1.0")` with
  recording fakes (objects, registrations, the button, Show/Hide), and a test's own `LibStub` (the
  LibGlass fakes) can still be set.
- **The UI contract** gains one exception: LibDBIcon's button is a **named** child of `Minimap`
  (`LibDBIcon10_NodeRadar`, the library's), as every LibDBIcon addon's is; NodeRadar still never
  moves, resizes or hides `Minimap` itself.
- **Tests:** a snooze skips the target and the next wins outright (even within 5 yards); the same
  node re-measured (a new record within 8 yards) still skipped, one 12 yards off not; another name
  at the spot not; another instance not; each duration expires at its time, "session" never; clear;
  no target: nothing; a loading screen or death (records cleared) keeps the snoozes; the dim on the
  icon **at once, without a sweep**, and gone at the sweep after it expires; the menu's entries
  (the toggles, the snooze with and without a target, the compass off, the clear) and its
  toggles doing `NR.Set`; **the target changing between opening and choosing: the shown node
  snoozed**; the clicks (left, right, the compartment, with the button hidden and with no
  libraries); the key binding's duration from the setting; the commands; the button shown and
  hidden by the setting (the saved `hide`); no libraries: no button, no error.
- **Look round** (`/fp steps nr snooze`): the button around the minimap (and dragged), its
  tooltip; left-click: the menu, its toggles; snooze 15 minutes: the compass on the next node, the
  snoozed icon dimmed; the key binding; clear; right-click opens Options; the compartment entry;
  Glass MiniMap Bar collecting it, if loaded; `/reload` clears.

### Shown, hidden

- **Shown** while there's a target and the position and facing read, a radar sweep ran within the
  idle interval plus 2 s, the player isn't dead or on a taxi (`UnitOnTaxi`).
- **Hidden within 15 yards** of the target (horizontal, the record has no above/below height): the
  glow there is Lueur's. Not dismissed: it's still the nearest, so walking away without gathering
  shows the ring again. A node above or below keeps the ring within 15 yards.
- **Hidden** otherwise: no target; the compass or the radar off; the position or facing nil or
  secret; no recent sweep (the learner's pause, the Gamepad UI, every sweep failing); dead; on a taxi.
  Records cleared (a loading screen, death, tracking changed, an instance, the learner starting) leave
  no target until the next sweep's records.
- The distance is horizontal: the minimap gives no node height.

### Tests

- The target: the nearest gatherable record; one the skill can't gather never (and with `skillOnly`
  off, it can); none: hidden; chosen again each sweep as the player moves; a record missed once
  still chosen, recovered still, dropped at the second miss; hysteresis (3 yards nearer doesn't take
  over, exactly 5 does, two at equal distance stay put); the incumbent gone or no longer gatherable
  with a replacement under 5 yards farther: replaced; a record dropped past the rim (a zoom in)
  moves it on, or hides it when none is left; records cleared: hidden at once; chosen on the
  alert's silent baseline, in its cooldown, and past 60 s (no timeout).
- The gather: several records of the name gone at once, an unrelated gather (hysteresis kept), and a
  gather never reviving a stale ring. **Its dot lingering** two sweeps: no record of it, the ring
  on the next node and shown throughout; the dot gone: the entry forgotten, and a node of the name
  appearing there after is measured; another of its name 20 units off measured meanwhile; a node
  gathered unmeasured (no record) left out by the player's position; LINGER caps an entry seen
  for good; `Icons.Clear` forgets them.
- Shown and hidden: within 15 yards hidden (the target kept, the `OnUpdate` gone), shown again
  walking away at the next usable sweep; a node above not hidden within 15 yards, then level again
  (its height nil) hidden; the position or facing unreadable; no recent sweep; dead; a taxi; the compass off; the
  radar off; the learner starting in the same step.
- The settings split (kept from the reviewed plan): icons off with the compass on keeps the records
  and draws no **minimap icon** (no icon frame, no icon host, no icon `OnUpdate`; the compass's own
  glass is its own); icons on shows them; compass off hides the ring and keeps the records for the
  icons; both off clears them.
- The ring: the arrow's point and rotation ahead, left, right, behind, north-east, across the 0/2π
  wrap, on its orbit outside the disc at each size; the pill below the orbit; the distance text; the
  target's icon; each style (glass with Glass MiniMap, bronze, plain; a glass that fails: bronze, the
  icons' latch); the size by `SetScale`, not a rebuild; a child of `UIParent`.
- The tooltip: the target's item on hover, anchored above, hidden on leave (only if owned); no
  item, no tooltip; the target changing under a still cursor: set again, or hidden; mouse motion on,
  clicks off; the pill, the arrow and the glass tops take no mouse.
- The latch both ways: the compass glass, then an icon's `Disc` failing: the compass bronze too; the
  icons glass, then the compass's pill `Apply` failing after its `Disc` built: both bronze; a style
  or size change with the icons off reaches the compass.
- The compass alone with glass resolves the style and builds the compass's glass, and still no icon
  frame.
- Off: nothing measured, no ring, no `OnUpdate`.
- Options and `/nr compass`.
- Every new test mutation-tested.

### Probe round 4 (`/fp steps nr compass4`, the compass's look)

- Each style (glass with Glass MiniMap; bronze and plain chosen) at each size, screenshots.
- The tooltip on hover; **left and right clicks on the disc reaching the world**, and a camera drag
  started on it (motion only).
- Combat and Edit Mode, in and out, with the hover on.
- The arrow pointing behind: clear of the pill.
- Riding: readable.

### Probe round 3 (`/fp steps nr compass3`, the nearest-node compass)

- Riding among nodes: the ring on the nearest (screenshots, the candidates' distances, the chosen
  record, its misses and height logged), moving on after each gather, no flicking between two at
  about the same distance.
- A zoom in with the ring up: it stays on a measured node still in view (a dot without a record
  doesn't count: the rim and the clumps).
- A clump of one herb: does the ring stay useful (the icons' limit)?
- Hidden within 15 yards, back when walking away; a node above.
- A flight: `UnitOnTaxi` true then false, and the ring hidden on the way if a node is in view.
- The old `compass2` procedure and its watcher go: they read the alert design's state.
- The cost, the compass alone.

### Not in this issue

A glow on the node within 15 yards (Lueur's). Moving the ring. **A skip** ("not that one"),
for the final version (owner). A target chosen by the player (clicking an icon). Several targets.

## A public API (#4), after #3

NodeRadar stays standalone: it reads Blizzard's `Minimap`, so it works under any skin (the stock
map, SexyMap, ElvUI, Glass MiniMap). It exposes `PUBLIC_API_VERSION` and a callback (name, kind,
position on the map); a skin that draws the alert itself (Glass MiniMap, as it does with Glass
MiniMap Bar) turns NodeRadar's own ring off.
