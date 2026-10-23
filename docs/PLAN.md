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

   **Then covered** (the owner's two Silverleafs, 2026-10-19: about 32 units apart, they were icons,
   then dots, then icons again as the player moved): two same-name nodes a few units apart can come
   out of one sweep as **one** blip, its centroid between them (`/fp nr icons`: 21 cells, about two
   nodes' worth; refining at 7 units doesn't always find a gap that narrow). Neither record is
   within 8 units of that centroid, so both missed and dropped; the merged blip couldn't be
   measured either ("crowded"); a later sweep from elsewhere split them and they came back. So
   each blip keeps its sampled cells (`b.points`: the sweep's own cell list, no new table), and a
   record left unmatched is **covered** when a blip of its name has a cell inside the record's
   square (`|cell - record| <= Scan.NODE / 2` on both axes, the cell's map coordinates minus half
   the map's width and height, as the record's are from the centre: no yards conversion): its
   misses go back to 0 (so a record hidden by one miss shows again), its height left as it was. Only
   the filtered blips count (the gathered dots and, with Blizzard's dot, #47's skipped names left
   out), and covering works in the rim band too; the drop past the rim stays unconditional. A blip
   that covers any record is not measured (merged, or near a known node: a separate position error
   would need its own rule): no `Scan.Centre` reads every 5 s on it. One blip can cover several
   records; the one-to-one match still comes first. `b.points` is the sweep's list, kept only as
   long as the sweep's result (never on records, tries or frames) (Codex).

   The limit, accepted: a record stays while a same-name neighbour's square overlaps its own (within
   25 units **on each axis**, so up to about 35 units on a diagonal: Codex), so a node gathered by
   someone else beside another of its name keeps its icon, and can stay the compass's target,
   until that neighbour goes too. The player's own gather drops its record (step 5).
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
- Records covered (the merged pair), on real sweeps of 25-unit squares (`b.points` in the map's
  coordinates): two records, then one blip between them: both kept (no miss), the blip not
  measured, over sweeps past RETRY (no reads); split again: matched one to one, the same record
  objects; a record with one miss recovered by covering (shown, its height kept); one record
  matched and another covered by the same blip; covered in the rim band, dropped past it; a
  record whose square no cell covers still missed; another name's cells, a lingering gathered dot,
  and #47's skipped names with Blizzard's dot cover nothing; the compass keeps its target through
  a merge (the hysteresis on the same record); the accepted diagonal neighbour keeping a stale
  record. The existing "one blip matches one record" test is revised: its twin is now covered,
  and the one-to-one match is checked apart (Codex).
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

### Never a yellow dot (#67)

The owner (2026-10-19), after #66: "reloading and not moving that is. We really want to never see
yellow dots." #66 keeps icons measured before two same-name nodes merged in a sweep; after a reload,
standing still, the pair is one blip from the start and can't be measured ("crowded"), so it stays
two dots. Nothing on 70450 hides only the gathering dots (no blip-texture API; `Minimap:SetIconScale`
resizes every minimap dot, quests and party included, and minimap skins may set it: not used). So
every node's dot gets an icon over it. Other addons doing the same split merged groups (a fine grid
and the outline) and place an icon per node; none hides the dots.

**Only herbs and ore** (the owner): everything here is about blips whose name NodeRadar knows as a
node (`Learn.Kind`: the shipped library and the names it learned). Every other dot on the minimap,
treasure from Find Treasure, other trackings, quests, party, keeps Blizzard's dot; so does a herb or
ore NodeRadar doesn't know yet, until it's learned.

**Overlap counts, measured: none** (`/fp nr twice`, the owner, 2026-10-19: every point of the map,
step 4: "Silverleaf at most x1", "Peacebloom at most x1"). The tooltip lists a name once at a point
however many of its dots cover it (or no overlap was in view; both other addons read the outline
instead, which they'd hardly do if a count were there). So a heavily overlapping pair (centres under
about 13 units apart) isn't reliably separated by this bounded sampling and peeling (targeted
outline reads could tell some apart: not attempted): **the stated limit**, one icon over both,
covering them only in part (Codex's (2.75, 2.75) and (10.95, 10.95)).

**The principle: explain every cell.** A blip's sampled cells (`b.points`, #66) are where its name
reads. A cell is **explained** when it lies inside a known node's square of its name, with a
tolerance: `|cell - centre| <= Scan.NODE / 2 + Scan.EXPLAIN_TOL` (1.5 units: the measure's 0.25 and
the projection's drift, Codex's boundary column) on both axes, the cell in the map's coordinates
minus half its size, as the record's from the centre. One predicate serves the covering (#66, now
"fully explained"), the measuring and the provisional icons. Matching one to one stays first.

**1. A blip with unexplained cells is measured, a node at a time** (`Scan.Centre`, Icons' budget of
four blips a sweep and the 5 s retry kept):
- **Peel from the outside.** Of the unexplained cells, take the outermost one along each of the
  four directions in turn (least x, most x, least y, most y; the median of the others' coordinate
  among ties). That cell lies in a node whose edge on that side is the union's there. From it,
  `edge` walks outward to that edge (`xL`), and 3 units inside it (`xL + 3`) the walk across finds
  the node's other two edges, which must span `Scan.NODE` within `NODE_SLACK` (else that row or
  column crosses two nodes: this direction fails, the next is tried). The centre: `xL + NODE / 2`
  on the walked axis, the middle of the two edges on the other. The new square must contain its
  starting cell. **Pairs** are exact when their centres are at least `NODE / 2` apart on the axis
  peeled (the walk across 3 units in then stays in one node), at every phase of the grid; closer,
  the stated limit above.
- **Then the rest:** the new node explains its cells; with unexplained cells left, peel again, up to
  `Icons.PEEL = 4` nodes a blip. A centre within `Icons.MATCH` of a record of the name is that
  record (no duplicate). The single measure from the centroid stays the first try for a lone blip
  (cheap, exact), and its result is accepted only if it leaves no unexplained cells; else peeling
  goes on from what it left (Codex's lopsided diagonal: the single measure finds the upper node,
  peeling the lower).
- **Progress:** a candidate counts only if, placed (or matched to the record within `MATCH` it
  dedupes to, at that record's position), it explains a cell that wasn't. One that doesn't is a
  failed direction. A pass tries the four directions in turn, starting along the longer axis of
  what's left (bottom and top first for a pair one above the other) and going on round after each
  node found (restarting the order cost a vertical pair 170 reads), and ends when four in a row
  fail or `PEEL` nodes are found.
- **Not forever** (Codex): a blip whose pass ended with cells still unexplained is **suspended** by
  its **spot** (its name and the world position of its unexplained cells' centroid, within
  `Icons.MATCH` units converted to yards), with a backoff: retried after 5 s, then 10, 20, 40, then
  every 60 s at most, while seen; a record added or dropped among those explaining it, a change of
  the view's radius, or a clear re-arms it at 5 s; unseen for `FORGET`, it's forgotten. Being a
  world spot, the player riding past doesn't re-arm it (Codex's 7-unit back-and-forth); a new phase
  of the grid still gets its retries, fewer over time. Provisional icons stay meanwhile.
- **Cost, bounded:** a node found costs about 25 reads (an outward walk, a read, two walks across),
  a pair about 50; a failed direction about as much. A sweep stops measuring at
  `Icons.MEASURE_READS = 200` reads (the blip being peeled finishes its current direction, the
  rest wait for the next sweep), on top of the grid's.
- **Whole** (Codex): a blip is measured only when the centroid of what it leaves unexplained is
  `INSIDE` the rim (#28's rule, on those cells: a node entering at the edge isn't peeled four ways
  on every sweep), and a peel is refused when its square would extend past the round map less 2
  units (`Scan.RIM_MARGIN`, the square's corners): near the rim the edge read may be the map's, not
  the node's. What's refused gets provisional icons, under the rim exception.
- **What it can't tell** (stated, Codex): a node whose square lies wholly inside the union of others'
  (three in a row, 12 apart) leaves no cell unexplained and gets no icon; **a compact triple can
  leave its middle node unpeelable** at some phases of the sweep's grid (every walk across from its
  exposed edges crosses an outer node, which still reads: (1, 1), (14, 14), (27, 27)), so the
  middle gets a provisional icon, not an exact one; a same-name area that isn't a node, shaped like
  squares, would be peeled as nodes. Pairs, the owner's case, are exact at every phase **when their
  centres are at least `NODE / 2` apart on the peeled axis**; closer, partial cover (above).

**2. Provisional icons for cells still unexplained** after the sweep's measuring, whatever matched or
covered the rest of the blip (Codex): the unexplained cells, grouped (8-neighbour, at the sweep's
step), each group gets one provisional icon at its centroid, or two when it spreads more than
`NODE` along its wider axis (the halves' centroids). No error bound for those (a group of three
can put one between two dots: Codex): an approximation until measured. Provisional icons:
- are drawn like records (the look, the size, the dim from `Alert.Wanted`, the height from the
  blip), their world spot fixed at the sweep, following the player between sweeps;
- are **rebuilt at every sweep**: their frames go back to the pool first, then new ones are taken,
  so frames plateau; only their spot, name, icon, dim and height are kept, never the cells;
- take part in everything a record's frame does: `Icons.Show`, `draw`, `Restyle`, `Refilter`,
  `Release`, `Clear` (the learner's same-frame clear included), hidden with the icons off;
- are not records: `Icons.Records()` (the compass) and the alert never see them;
- skip what the filters skip (a lingering gathered dot, #47's skipped names with Blizzard's dot).
- **A gather in a merged pair** (Codex, PR #68): a gathered record's spot (`gone`, still lingering)
  explains cells like a record, so its dot, merged into a live neighbour's blip, is neither peeled
  back into a record nor drawn provisionally; the entry stays while a cell of that blip is in its
  square, `LINGER` at most, and the compass stays on the neighbour.

**3. The rim, an explicit exception:** within `half - extent` of the map's edge (the band where an
icon fades out, about 11 units with the medium bronze ring) a dot can still show: a record fades
there, and a provisional icon at a clipped blip's centroid would be faded out too (Codex). Icons
aren't drawn past the round map's edge (they'd hang over the frame), so the outermost band keeps
Blizzard's dots, as the README already says.

**Tests** (25-unit squares, `WoW.BLIP_HALF = 12.5`; `test_scan`'s separations use 17): pairs merged
on x, on y and on the diagonal, measured from a standing start into two exact records; Codex's
lopsided diagonal ((-19, -16) and (-6, 11)): both; **pairs at several phases of the grid** (the
same pair shifted by 1, 3 and 5 units): always both exact; a pair with one record already: the
other peeled, no duplicate; the boundary column ((-10, -5) and (16, -5)): explained, no retry past
RETRY, no stray provisional; a compact triple ((0, 0), (13, 13), (26, 26)) and shifted
((1, 1), (14, 14), (27, 27)): the outer two exact, the middle exact or provisional icons that may
cover it only in part (the shifted one leaves (8, 22) and (22, 8) unexplained, two provisional icons
beside the middle dot: Codex; accepted, partial cover); a close pair ((2.75, 2.75), (10.95, 10.95)):
one icon, partial cover (the stated limit); three in a row 12 apart: the middle one not found (the
stated limit); **suspension**: a shape left unexplained is retried at 5, 10, 20, 40, then 60 s
(no measuring reads between), re-armed at 5 s when a record is dropped, backing off to 60 s otherwise, **not** re-armed by the
player moving back and forth (the spot in world terms; Codex), **the read ceiling** (a sweep with many
merged blips stops at 200 measuring reads); **a merged blip reaching the rim**: its inner node
peeled, the clipped one refused (provisional, under the rim exception); a lone unmeasured blip: one provisional, a
wide one: two, a matched partial blip: provisional for its unexplained cells; provisional frames
reused (the frame count plateaus over sweeps), gone when measured, none for filtered blips, not
in `Icons.Records()`, cleared by `Icons.Clear` and the learner, hidden with the icons off and the
compass on; the rim: a clipped blip's provisional faded, as records (the exception); a secret read
or a failure inside a peel: no record, the soft cursor off; the reads (about 25 a node).

**Look round** (`/fp steps nr nodots`): at the owner's pair after a reload, standing still: two icons
at once; elsewhere, moving: no dot without an icon but in the outer band and the stated cases (close
pairs, compact triples, a node inside others); `/fp nr icons` lists the provisional ones and the
peels.

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

Within about 15 yards it stops: a nearby glow can use the soft target, which
Forever loses at 15 yards, and NodeRadar never touches the soft-targeting settings (owner,
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
      so the page and `/nr` agree). **A checkbox closes the menu** (its responder returns
      `MenuResponse.CloseAll`): on 70450 the default `Refresh` reruns the entries' initializers but
      not the generator, so a menu left open would keep a snooze line for a compass just turned off,
      or the "off" line for one just turned on (Codex). Reopening builds the right menu;
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
  toggles doing `NR.Set` and closing the menu (the compass or the radar toggled, then reopened:
  the snooze line follows); **the target changing between opening and choosing: the shown node
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
  glow there belongs to the nearby marker. Not dismissed: it's still the nearest, so walking away without gathering
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

A glow on the node within 15 yards. Moving the ring. **A skip** ("not that one"),
for the final version (owner). A target chosen by the player (clicking an icon). Several targets.

## The skill in the minimap's tooltip (#62)

Hovering a herb or ore on the minimap shows its name only. A node's own tooltip in the world adds its
profession, coloured by difficulty (docs/FOREVER-PROBE.md: "Herbalism" orange, yellow, red). The
minimap's will too, with the skill it needs: **"Requires Herbalism (15)"**, coloured.

**How the client draws it** (FrameXML, 70450): while the cursor is on the minimap, `Minimap_OnUpdate`
calls `GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")` and `GameTooltip:SetMinimapMouseover()` every
frame. That goes through `TooltipDataHandlerMixin:ProcessInfo`: `C_TooltipInfo.GetMinimapMouseover()`,
`ClearLines`, the lines, then **`TooltipDataProcessor`'s post-calls** for the data's type
(`MinimapMouseover`, 21, as measured: `{ type = 21, lines = ... }`), then `Show`.
- **The hook:** `TooltipDataProcessor.AddTooltipPostCall(type, fn)`, registered once at load
  (`Enum.TooltipDataType.MinimapMouseover`, else 21). Registered from an addon it's stored as an
  insecure call and run through `securecallfunction` with `forceinsecure`: the client's way for
  addons; nothing of Blizzard's is replaced. No `hooksecurefunc` needed.
- **No stacking:** each frame's rebuild clears the lines first, so ours is added once a build.
- **The sweep never sees it:** post-calls change the `GameTooltip` only, never the data
  `C_TooltipInfo.GetMinimapMouseover` returns, which is what `Scan` reads. A test pins it.
- **Only `GameTooltip`:** the post-call gets the tooltip it runs for; anything that isn't
  `GameTooltip` (another addon calling `SetMinimapMouseover` on its own tooltip) is left alone.

**The line:** from the data the post-call gets (`data.lines`, each `leftText` split on newlines,
each row through `Scan.Plain`, as the sweep reads them):
- one line per **distinct** known node name in the tooltip, in its order, deduplicated after
  `Scan.Plain` (two Peacebloom rows, or one with a height arrow, are one name); its skill from
  `Learn.Info` (so a learned "not a node" or a changed kind overrides the shipped `NODE_INFO`): a
  learned name without one, or any other name, gets nothing;
- its kind's skill line (`Alert.SKILL_LINES`); its name from `C_SkillInfo.GetSkillLineInfoByID`'s
  `name` (localized), else the English one (`Herbalism`, `Mining`: for display only, never
  compared);
- the text from the client's `ITEM_MIN_SKILL` ("Requires %s (%d)", localized) when it's a string
  with `%s` and `%d`, else `"%s %d"`; with two or more node names, each line starts with the node's
  name ("Peacebloom: Requires Herbalism (1)") so they can be told apart;
- coloured by `TrackOptions.colour(skill, rank)`: red below, orange, yellow from +25 (those three
  measured on the world tooltip), green from +50 and grey from +100 (the classic bands, the existing
  convention, not yet seen); the rank the **effective** one (`API.Skill(line)`, gear included: the
  requirement the character can meet, not a claim about skill-ups); **no such profession: red**
  (an explicit case: `colour(skill, nil)` is white). The Herbs and Ores pages keep the base rank,
  which smart follows; the two differ only with a skill bonus from gear (unmeasured).
  `Alert.Gatherable` doesn't decide the colour (it lets unknowns through, and Cultivation).
- **The skill, readable or not** (Codex): `API.Skill` gains a second answer, `nil, "absent"` (no
  such line: `GetSkillLineInfoByID` gives nil) against `nil, "unreadable"` (the call failed, or the
  info, its rank or its modifier is secret); its modifier is tested for a secret **before** it's
  compared (today's `info.modifier ~= nil` after the read would throw on one). Absent: red;
  unreadable: no line for that kind. The alert and Track read only the first answer, as now.
- **Secrets everywhere it reads** (a tooltip must never break): `data` before any field, `lines`
  before iterating, each line before indexing it, `leftText` before splitting or using it as a key,
  the skill info as above, its `name` before formatting (unreadable: the English name). Any secret
  in the tooltip's own lines: no line at all. Nothing in the post-call raises: its body runs in a
  `pcall`, a failure recorded once (`API.Fail("tooltip", ...)`), never repeated per frame.
- **Observational:** besides `AddLine`, the post-call calls nothing that moves the mouseover or reads
  the tooltip again (no `SetMinimapMouseover`, `UpdateMouseoverAtPoint`, no change to `data`), and
  returns at once until `NR.db` is loaded.

**The setting:** `tooltipSkill`, on by default, a checkbox in Options ("Show the skill a node needs
in the minimap's tooltip"), `/nr tooltip`. Off, the post-call returns at once (it can't be
unregistered). With the radar off it still works: it reads no blip and costs a few string ops per
frame while hovering a node.

**Tests** (Codex's additions in): the stubs grow `TooltipDataProcessor` (post-calls by type, run by a fake
`GameTooltip:SetMinimapMouseover` that reads `C_TooltipInfo.GetMinimapMouseover` as the client's
handler does: clear, lines, post-calls, show). Cases: one node: the line, its text and colour at
ranks below, at, +25, +50, +100; no skill: red; two names: one line each, with the names; two of
one name: one line; another name (a quest's): no line; a learned name without a skill: no line;
a height arrow's row: read as its name; `ITEM_MIN_SKILL` missing: the fallback; the skill-line
name unreadable: English; secret lines: no line, no error; the setting off: no line; another
tooltip than GameTooltip: untouched; two builds in a row: no stacking; the data the post-call gets
unchanged by it (compared before and after our call alone: Blizzard's own processing writes
`lineIndex`), and a sweep while the tooltip shows still reads only node names; secrets: the data,
lines, a line, its text, a readable node then a secret row, the skill info, its rank, its
modifier, its name; a gear bonus crossing a band (effective rank); a learned override (not a node,
another kind); the setting: default on, saved off, `/nr tooltip`, the Options checkbox, the radar
off.

**Probe round** (`/fp steps nr tooltip`): hover a herb you can gather (the line read back from
`GameTooltip`'s lines, with its colour; a screenshot), an ore without Mining (red), two nodes
together if one is in view; log `ITEM_MIN_SKILL`, the skill lines' names (Mining unknown to the
character: does `GetSkillLineInfoByID(186)` answer, and with what?); the hovered node and its line
still right after the radar's sweeps run while hovering (Codex); a short hover in combat and a
normal minimap click and zoom, with any error or blocked action logged. A gear bonus and the green
and grey bands stay pending until a character and nodes allow them.

## Caves (#63)

Two questions, one round. Measure first; what NodeRadar does follows from what the round shows.

**1. A grey name.** The claim (another addon's audit, `.local/`): a node in a cave reads grey in the
minimap's tooltip, as the line's `leftColor` or an inline `|c` code (it takes r, g and b within 0.1
of each other and under 0.9 as grey). What's measured: `leftColor` is `#ffd200` for every blip in
the open, herbs and NPCs alike (round 3, #7). Inline codes on a node's row were never logged:
`Scan.Plain` strips them, and the probe logged plain names. NodeRadar reads neither, so a grey cave
node is treated as any other today.

**2. A ping missed on leaving a cave** (a tester, 2026-10-19: "when you get out of a cave or tunnel
it does not always ping the new nodes"). What in our code could do it:
- **a. The zoom's silent baseline** (the likeliest): `MINIMAP_UPDATE_ZOOM` calls `Alert.Reset()`, so
  the next sweep counts every node in view without alerting. Indoors the minimap has its own zoom
  and a smaller view (150 yd against 233 at zoom 0, measured, #27). If the client fires
  `MINIMAP_UPDATE_ZOOM` when it swaps them, every node that comes into view on the way out is
  counted silently. Offline it's certain; whether the client fires the event there isn't measured.
- **b. No sweep for 5 s** (`Alert.STALE` + the interval): the next is a silent baseline. Only if
  sweeps fail or stop indoors.
- **c. The blink** (by design): a name that dropped on the way in (the smaller view) and rises
  within 20 s on the way out is taken for the same node at the edge. Mostly it is, but a different
  node of that name is held too.
- **d. The cooldown** (Codex): the counts move on before the 5 s cooldown is checked, so a rise
  within 5 s of another alert is counted and never alerted later.
- **e. No rise** (Codex): a new node needn't raise its name's count (one went out of view as it came
  in, or two of a name merged into one blip); and only known (`Learn.Kind`), wanted names alert.
- **f. Sweeps held** (Codex): `NR.Step` returns before the alert when NodeRadar is off, the learner
  is busy (a voided experiment still runs its restore), loading, the Gamepad UI, the minimap hidden,
  or a sweep fails. A gap past 5 s + the interval (7 s by default) is (b).
- An alert isn't a sound heard: the sound setting, and `PlaySound`'s refusal (Codex).
- Not the geometry's reset: it compares the frame's size and scale, which a cave doesn't change.

**The round** (`/fp steps nr cave`), anywhere the minimap goes indoors (a cave, a mine, a
building such as the Undercity), best with nodes, herbs or ores, in view outside. The swap's
reset (a) needs no node: NodeRadar's updates run with tracking on, nodes or none. Passive while it runs, all restored at the end; every
line numbered (several share a `GetTime()`) and carrying `IsIndoors()`, the zoom and the view radius:
- each change of `IsIndoors()` (polled every frame: it brackets the engine's change, no more); each
  `MINIMAP_UPDATE_ZOOM`, with `IsIndoors()` read in it; each `Minimap:SetZoom` call (a secure hook:
  the player's, or Glass MiniMap's reset on moving);
- NodeRadar's functions wrapped to observe only (Alert's state is private): `Alert.Reset` (its
  call site from `debugstack`: the first frame past the probe's own, the first path on its line,
  since each line names the call site and then the definition; porting guide), `Alert.NewArea`,
  `Alert.Gathered`, `Alert.Fire` (with the sound setting), `Alert.Update`, `Scan.Sweep` (a
  failure's reason) and `NR.Step`. A mirror of Alert's history follows its rules: gone after a
  reset or a stale gap (that update a silent baseline), empty after a new area, a drop forgotten
  after a gather; what came before the probe is marked unknown (drops for 20 s, the cooldown until
  a fire). Every update leaves a brief line (indoors, zoom, radius); near a change, or with a
  baseline, a rise or a fire, the full one: every cause of a baseline (several at once), the
  counts, each rise with its drop's age (a blink or not) and wanted or not, the last fire, what
  alerted. A step that didn't reach the alert says what held it (the gates, tracking among them)
  or why its sweep failed;
- `Scan.Plain` wrapped: every node row read, counted by its raw form, its line's `leftColor` and
  `IsIndoors()`, so ordinary rows show coverage. The colour comes from a second
  `GetMinimapMouseover()` read at the sweep's own point (never moving the mouseover), six a sweep
  at most (each read is 2.5 KB), matched to the row by its raw text (two lines with it and two
  colours: both said). A row with an inline code or a colour other than gold is logged when first
  seen. A reload mid-round reinstalls at the next step, timed from then and said inconclusive. Hovers read `GameTooltip`'s line raw (`GetText`) with `GetTextColor`, and the
  data's `leftColor`. A round with no node in a cave says nothing about grey (Codex).

Steps: outdoors near the mouth, a node hovered (a screenshot); a zoom in and out outdoors; walk in
until the minimap turns indoors; a node inside hovered if there is one (screenshot); 30 s inside
with a zoom in and out; walk out, 5 updates after; "Did NodeRadar ping the nodes outside?"; a short
visit (in and straight out), 5 updates after, the same question; from outside, a node in the cave
hovered if one shows (screenshot); "Did any node's name look grey?"; the summary.

**Measured** (docs/FOREVER-PROBE.md, "Indoors and out"): (a). The swap fires `MINIMAP_UPDATE_ZOOM`
with no `Minimap:SetZoom` call, 4 of 4; the player's zooms all came through `SetZoom` (31 of 31),
and a `SetZoom` to the zoom already set fires no event. `IsIndoors()` turns before the event (once
0.1 s before it), so comparing it at the event or the next update can misread (Codex); the call
doesn't.

**The fix:** the player's zoom is told by its call. A secure hook on `Minimap:SetZoom` (our only
hook on the minimap; it changes nothing) resets the alert when the zoom it leaves differs from the
one before (`GetZoom()` remembered at each call and each event; a call to the same zoom resets
nothing, as it fires no event). `MINIMAP_UPDATE_ZOOM` no longer resets the alert: a swap keeps the
history, so a node that rises on the way out alerts unless the blink holds it (a name that dropped
within 20 s). The event still voids a learner's experiment (the view changed, whoever changed it).
These stay: a node seen before going in and back after more than 20 s alerts again; a rise inside
the cooldown is lost (d); a different node of a name that blinked is held (c). An unknown zoom
(`GetZoom()` not a number) resets, as now. Accepted (Codex): a merged pair of one name can split
into two blips when the view shrinks on the way in (nodes farther apart on the map), a rise that
alerts although both were in view; telling nodes apart isn't worth it for this. Grey: unmeasured (no node in a cave yet); if real, what
a grey node gets is the owner's choice.

## A marker in the world (#61), experimental

**Superseded by #78** (the owner, 2026-10-21): the waypoint's spot is at the player's height, short
of a node up any slope. What follows is kept as the record of #61.

The node the compass would point at, marked out in the world: twinkling stars on its spot, seen
through the scenery at any distance, as gathering points sparkle in Final Fantasy XIV (the owner's
reference video). Off by default, labelled experimental, its own setting (`marker`, `/nr marker`,
Options); off, nothing of it runs and nothing is touched.

**Measured** (docs/FOREVER-PROBE.md, "Blizzard's waypoint marker" and "The navigation frame as an
anchor", 70450): the user waypoint can be set from addon code and super-tracked; with
`showInGameNavigation` at 1, `C_Navigation.GetFrame()` sits at the waypoint's spot on screen, our own
art anchored to it follows the camera and is held at the screen's edge when the node is behind
(`WasClampedToScreen`), and Blizzard draws its distance ("22 yds") there with no icon. The spot has
no height: projected at the player's, so on a slope it sits above or below the node. Clearing:
the super-track first, then the waypoint (the other order leaves the super-track reading true). A
waypoint and its super-track survive a reload. `USER_WAYPOINT_UPDATED` fires inside
`SetUserWaypoint`; `SUPER_TRACKING_CHANGED` after it, or not at all.

**The owner's choices** (2026-10-20):
- **Step aside, never borrow.** The marker shows only while the player has no waypoint of their own
  and nothing else is super-tracked. NodeRadar never clears, moves or replaces theirs.
- **Blizzard's distance text stays**: a free readout under the stars. Revised after the world
  round (Blizzard also draws a gold diamond there): the diamond hidden while ours is on the spot,
  its distance kept while the compass is off and hidden with it on (one distance on screen; Codex's
  choice, the owner's leave). Behind the player, Blizzard's marker and edge arrow are left alone. A
  post-hook on `SuperTrackedFrame.UpdateAlpha`: the frame's alpha 0 with the compass on, its `Icon`'s
  alpha 0 (put back once when ours stops covering it).
- **The look: FFXIV's sparkle**, its own toggle using the compass's choice of node.

**Which node:** the compass's target (`choose()`: the nearest wanted record not snoozed, the 5-yard
hysteresis), chosen while the compass **or** the marker is on (`Compass.Choosing()`); records kept
while either is on (`Icons.Keeping` gains `marker`). The compass's ring still shows only with
`compass`. Hidden within 15 yards (`Compass.NEAR`, where a nearby glow takes over), on a taxi, in an
instance where `Scan.Where` is nil, and while the spot is clamped to the screen's edge (behind or
off screen: the compass covers direction).

**The waypoint, ours** (`Marker.lua`): one reconciler, not queued commands (Codex).
- **Desired state:** the target's map point, or none. `Marker.Reconcile()` compares it with what's
  installed and writes only when they differ and the gates pass. It runs after each successful
  sweep (so within the idle interval of the world map closing), on `USER_WAYPOINT_UPDATED`,
  `SUPER_TRACKING_CHANGED`, `PLAYER_REGEN_ENABLED`, `NAVIGATION_FRAME_CREATED`, and when the setting or NodeRadar is turned on or off (a
  cleanup path of its own: `NR.Step`'s early returns and a disabled radar must not strand our
  waypoint). Each run reads everything again: combat, the map, the target, ownership. A target that
  stays the same is picked up when the slot frees (the player removes their pin, a quest stops
  being super-tracked). While ours is installed but not wanted (a clear held by combat or the map,
  the marker or the radar off meanwhile), a retry runs every 0.5 s until it's done, sweeps or none;
  the compass's target cleared (`Compass.Reset`: tracking off, a loading screen) drops the point at
  once, and a point no sweep has confirmed for the idle interval and 2 s is stale; `/nr reset` tears
  down as turning it off does (Codex, PR #74).
- **The map point:** kept while the target is the same record, moved less than a yard (the world
  round: computed again from a moving player, it differed by a hair and the waypoint was set anew
  every sweep, the stars blinking). Otherwise computed at the sweep from a paired sample, the sweep's `where` (the zone map,
  the player's spot on it, its size in yards) and the player's world position read in the same frame
  (`Icons.Update`'s), with the record's offset in yards, as `Scan.MapPosition` does for a blip (#27,
  measured within reach): `x = where.x + (pw - r.west) / where.w`, `y = where.y - (r.north - pn) /
  where.h`. Kept with the target until the next sweep; a gather's new target waits for it. Off the
  map (0..1), or no `where` (an instance): none. `C_Map.GetMapPosFromWorldPos` (in the dump) is
  checked against it in the probe, not used before.
- **Free:** `C_Map.HasUserWaypoint()` false and `IsSuperTrackingAnything()` false, or both only ours.
- **Set:** `C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(map, x, y))` must return true and
  `C_Map.GetUserWaypoint()`, read back at once, must be our point (map equal, x and y within 1e-6);
  only then `C_SuperTrack.SetSuperTrackedUserWaypoint(true)`. Anything else (another addon answering
  our synchronous `USER_WAYPOINT_UPDATED` with its own point, inside our call) is contested: not
  ours, we don't super-track it, and we wait. Ours is then that read-back point, kept in memory and
  in `NodeRadarCharDB.marker` (map, x, y, as read back).
- **Theirs:** a `USER_WAYPOINT_UPDATED` outside our call, or a waypoint that no longer equals ours,
  is the player's or another addon's: we forget ours, take nothing back, and wait until the slot is
  free. Anything else super-tracked (`IsSuperTrackingAnything()` and not
  `IsSuperTrackingUserWaypoint()`: a quest, a pin, a corpse): if the waypoint is still ours we clear
  the waypoint only (the super-track isn't ours), and wait.
- **Clear** (the target gone, the setting or NodeRadar off): revalidated at that moment, never from
  an earlier decision: only if `GetUserWaypoint()` still equals ours; the super-track first, if it's
  the user waypoint's, then the waypoint. The ownership is kept until the second call is done.
- **A dead end, left alone:** `HasUserWaypoint()` false with `IsSuperTrackingUserWaypoint()` still
  true (measured after a waypoint cleared before its super-track) and not ours: someone else's
  half-cleared state. We don't repair it; the marker stays blocked until it clears.
- **Never in combat or with the world map open:** the map's waypoint provider rebuilds its pin
  frame on `USER_WAYPOINT_UPDATED` while shown (`WaypointLocationDataProvider`, taint). The
  reconciler just doesn't write; its next run after `PLAYER_REGEN_ENABLED` or the next sweep does.
  The stars hide while the installed waypoint isn't the target's. A precaution, not proof: the
  probe tries set, super-track and clear, then opens and uses the map.
- **Across a reload or a logout:** our waypoint is cleared at `PLAYER_LOGOUT` (out of combat; the
  marker sets it again after a reload), and `NodeRadarCharDB.marker` records whether that clear
  happened. At login, a waypoint is never assumed ours, except one equal to a saved point (within
  1e-6, as saved: SavedVariables may round) whose clear didn't happen (a crash, a disconnect):
  adopted, so it's ours to clean up: cleared while no target is known (the next sweep sets it again),
  with the marker on or off; no hold until a first sweep, which with tracking off never comes
  (Codex, PR #74). A matching point isn't proof of authorship; a
  match that close on a node's computed spot is accepted as ours. Whether a clear at logout sticks
  is probed.
- **What we can't help:** the client super-tracks a newly accepted quest only while nothing is
  super-tracked (`QuestUtil.AllowAutoSuperTrackQuest`, FrameXML 70450), so while the marker shows,
  a quest accepted isn't auto super-tracked (if Forever does that at all: unmeasured). Said in the
  option's tooltip; the probe accepts a quest with the marker off and on.
- **Drawn only for our waypoint:** `IsSuperTrackingUserWaypoint()` true and no other
  `IsSuperTracking*` (quest, corpse, content, map pin, vignette) true, since the navigation frame is
  shared.
- **No occlusion or height gate (measured 2026-10-21, `/fp steps nr sight`):**
  `C_Navigation.GetTargetState()` reads `Occluded` in a clear view and behind a rock alike (all on
  sloping ground, the marker's point under the hillside), so the trial gate hid the stars everywhere; `UnitPosition` gives no height, and a waypoint's z doesn't
  move the navigation's marker. Nothing tells whether the node is in sight or raised above the
  ground under it (docs/FOREVER-PROBE.md).
- **The navigation frame's life:** `C_Navigation.GetFrame()` taken at `NAVIGATION_FRAME_CREATED`
  and dropped (anchors cleared) at `NAVIGATION_FRAME_DESTROYED`, as Blizzard's `SuperTrackedFrame`
  does; nil right after a reload (measured). After a new waypoint, the stars hide for a settling
  interval (0.3 s to start with, Blizzard's `SuperTrackedFrame` hides 0.2 s on a tracking change;
  the probe tunes it), then wait until `HasValidScreenPosition()` and `GetDistance()` within 10
  yards of our own distance to the record (the first read after setting was stale, 644 yards). The
  distance alone can't prove the move (a new node as far as the old, in another direction), hence
  the interval; the probe switches between two such nodes.
- **`showInGameNavigation`:** set to 1 when the marker turns on if it was 0 (the setter's result
  checked), the old value saved in `NodeRadarDB.markerCVar` across reloads; put back when the marker
  turns off, or at login when it's off and a restore is pending. A change by anyone else
  (`CVAR_UPDATE` for it outside our call) cancels the restore: theirs stands.

**The stars** (art and animation, possibly handed to Codex): a frame of ours on `UIParent`,
`CENTER` on the navigation frame, no mouse. Following the owner's FFXIV video (2026-10-18): four
diagonal stars, their lower-left/upper-right rays longer, white cores with mint halos fading to
blue, over a faint teal haze. Each flares in 0.12 s and shrinks and fades over 0.54 s, drifting a
few units up and left. Random spots, sizes (0.7 to 1.2 times 48 units), and pauses (0.08 to 0.3 s)
per flare; staggered again whenever shown. Art from `Tools/make_media.py` (`Media/MarkerStar.tga`;
the haze is `SonarGlow`, 96 units, alpha 0.06 to 0.14), engine animation groups (scale, alpha and
translation), no per-frame Lua for the twinkle. The world round (70450): 22-unit stars were a
speck at 140 yards. The scale stays 60 / yards between 0.7 and 1.3. This animation revision needs
an in-game comparison; the navigation anchor still has no terrain height. Blizzard also draws a
small gold diamond on the spot, above its distance. A per-frame `OnUpdate` only while shown: the
distance, the clamp, the valid position.

**Cost:** nothing while off or with no waypoint of ours on the target; armed but hidden (behind,
settling, near), the animations stopped and a check ten times a second (the camera turning can
show them again); a waypoint call only when the desired point changes.

**Tests:** the waypoint calls through the stubs (set, read back, super-track, clear order); a
contested set (another addon's point inside our call); stepping aside for the player's waypoint and
their super-tracked quest, and taking the slot back when it frees with the target unchanged; the
half-cleared dead end; a clear revalidated (the player's waypoint by then: untouched); combat and the
map deferring; logout's clear and login's adoption; the frame's create and destroy; a switch to a
node as far as the old one, hidden through the settling interval; the CVar set,
put back, and left after someone else's change; hidden near, on a taxi, clamped; the choice shared
with the compass off. Mutation-tested.

**Probe** (after November 4, on the live client while levelling; a new build, so the client-update
skill first): the far case facing the node (round 1's 102-yard read had it off screen); uneven
ground; how often something is super-tracked while levelling (if Forever super-tracks quests by
itself, the marker would rarely show), and a quest accepted with the marker off and on; the
player's own pin and quest; combat, and the map opened and used after our calls; a reload and a
logout (does the clear at logout stick); the CVar from 0; `GetMapPosFromWorldPos` against our
point.

## The marker on the node's soft-interact plate (#78), experimental

**Replaces #61's waypoint marker** (the owner, 2026-10-21). That marker's spot is drawn at the
player's height, so on any slope it lands short of the node, at any distance (PR #77's sight
round). Nothing an addon can read gives the node's height or line of sight. The new marker puts
#61's stars (the art and animation the owner accepted) on the nameplate the game itself gives
its soft-interact target. That plate sits on the object, at its real height. Still `marker`,
experimental, off by default; off, nothing of it runs and nothing is touched.

**Measured** (docs/FOREVER-PROBE.md, "Soft-interact nameplates", 70450, 2026-10-22):
- With `softTargetInteract` 3, `SoftTargetIconGameObject` 1, `SoftTargetNameplateInteract` 1,
  `SoftTargetInteractArc` 2, `SoftTargetInteractRange` 60 and `nameplateGameObjectMaxDistance` 60,
  all read back and kept across a reload, the soft target gets a nameplate.
- **One object plate at a time**, the soft target's, within **about 15 yards** (15.3-15.7, whatever
  the range CVars). Other interactables compete for it (a cactus's Prickly Pear Fruit did).
- `UnitName(unit)` reads the node's name, `UnitIsGameObject` and
  `UnitIsUnit(unit, "softinteract")` are true, and `UnitExists("softinteract")` is false for an object.
- `NAME_PLATE_UNIT_ADDED` / `_REMOVED` fire as the target comes and goes;
  `PLAYER_SOFT_INTERACT_CHANGED` never did.
- A frame of ours, a child of `UIParent` anchored `CENTER` to the plate's `BOTTOM`, sat on a
  Silverleaf up a slope. No `ADDON_ACTION_*`.
- **Unmeasured:** a plate behind scenery (fades? hides?), a `SetCVar` in combat, the gamepad UI.

**So it covers the last 15 yards**, where the compass hides (`Compass.NEAR`). The compass guides
from farther off; nothing is drawn in the world beyond the plate's reach.

**Which plate:** one reconciler, `Marker.Reconcile()`. It runs at `NAME_PLATE_UNIT_ADDED` and on a
0.5 s ticker while the marker is on (Codex: what `Alert.Wanted` reads changes from many paths,
`/nr skill`, a skip, Cultivation's cooldown, a forgotten name, a skill-up, and the radar step can
be absent; a ticker reading a few plates costs less than wiring each path). The stars go on the
one plate where:
- the unit is a game object and the soft-interact target (`UnitIsGameObject`, `UnitIsUnit`);
- its name is a node NodeRadar knows (`Learn.Kind`) and the player wants (`Alert.Wanted`: gatherable
  and not skipped);
- every read passes the secret test first, and a secret, an error or no plate means no stars.

Each pass checks again that the bound plate is shown and still carries the qualifying unit: a plate
frame is reused for another unit. **The bound unit's `NAME_PLATE_UNIT_REMOVED` hides the stars at
once** (animations stopped, the point cleared, the unit dropped) before anything else, since
Blizzard clears the plate's unit in its own handler and the order isn't ours (Codex); the next pass
or add finds the new one.

No record, sweep or compass target is involved, so `Icons.Keeping` and `Compass.Choosing` drop
`marker`.

**The stars:** #61's (`Media/MarkerStar.tga`, the `SonarGlow` haze, the engine animation groups),
one frame, a child of `UIParent`, never of Blizzard's plate, no mouse, anchored `CENTER` to the
plate's `BOTTOM`. Hidden and the animations stopped when the plate goes or stops qualifying. One
fixed scale (the plate only exists within 15 yards). Blizzard's own icon on the plate is left as it
is: the owner accepts the game's icons on interactables while the marker is on (2026-10-22).

**The CVars are the player's** (the same rule as gathering tracking):
- **Only the CVars the plate needs** (Codex: the probe changed six together, and the arc and range
  change the player's interact targeting too). The ablation round (`/fp steps nr ablate`, 70450,
  2026-10-22, a Peacebloom at 14.3 yards) kept three: `softTargetInteract` 3,
  `SoftTargetIconGameObject` 1 and `SoftTargetInteractRange` 60 (the default 10 loses it at 14.3).
  Each put back alone lost the plate. `SoftTargetNameplateInteract`, `SoftTargetInteractArc` and
  `nameplateGameObjectMaxDistance` (30 already reaches 15) didn't matter: left as they are.
- **Claimed only when the marker is turned on** (the setting, `/nr marker`, NodeRadar enabled with
  it on, or a login with it on and no `softCVars` ever: on since #61, the owner's first run, #79),
  each one only if it differs; never by the ticker or the reconciler. The old value is saved
  per CVar in `NodeRadarDB.softCVars = { [name] = { old, ours } }`, and only once the game accepts
  the new one (read back). A claim is kept until the marker or NodeRadar goes off.
- **Put back** when the marker or NodeRadar goes off and at `/nr reset`; a CVar is put back only
  if it still reads `ours`. A change by anyone else (`CVAR_UPDATE` to a value that isn't ours: the
  player, another addon) cancels that CVar's claim, and theirs stands. **A cancelled claim stays
  cancelled** (`{ cancelled = true }` in `softCVars`) while the marker stays on, across reloads and
  logins: nothing claims that CVar again until the player turns the marker off and on (Codex). The
  marker may then lack a CVar it needs: no plate, no stars, nothing forced.
- **Across a session end, best effort:** put back at `PLAYER_LOGOUT` and applied again at
  `PLAYER_LOGIN`, so that removing NodeRadar shouldn't leave the player's interact targeting
  changed. A read-back at logout doesn't prove the value reached the saved configuration (Codex),
  so `softCVars` is kept, never cleared at logout: it goes only when the marker or NodeRadar is
  turned off and each CVar is put back. **At login, each claimed entry is read first** (Codex: a
  value changed while NodeRadar wasn't loaded raises no `CVAR_UPDATE` for us): still `old` (the
  logout restore stuck), `ours` set again; already `ours` (it didn't), kept; anything else, someone
  else's newer choice: that entry is cancelled (and stays so) and the value left alone. A cancelled
  entry is never read nor set at login. The probe round checks a full client exit. A player who
  removes NodeRadar after a logout restore that didn't stick keeps our values: said in the README.
- **The login waits for the client's synced CVars** (the owner's first run, #79): set at
  `PLAYER_LOGIN`, all three were overwritten a moment later by the client's own values, and the
  `CVAR_UPDATE` cancelled every claim. From `PLAYER_LOGIN` until `Marker.SETTLE` (5) seconds after
  the first `PLAYER_ENTERING_WORLD`, nothing is written or judged (a `CVAR_UPDATE`, the ticker's
  claims and restores); then the login's read runs, polled only with something to read (the marker
  on, or a claim left). **A toggle inside that window waits too** (Codex, PR #79): on, a claim the
  ticker makes once it's over; off, the stars hidden at once and the claims put back by the ticker
  then, after the client's values are in.
- **Nothing written in combat:** a set or restore that falls in `InCombatLockdown()` waits for
  `PLAYER_REGEN_ENABLED`.
- **A restore that has to wait runs later, the marker off or not** (Codex): the marker turned off in
  combat or in the gamepad UI leaves its claims pending in `softCVars`. The 0.5 s ticker runs while
  the marker is on **or** a claim is left in `softCVars`, and puts each pending one back as soon as
  it's out of combat and out of the gamepad UI (still `ours`: put back; else someone else's: dropped),
  then stops. At login with the marker off, claims left from an earlier session are put back the
  same way.
- **The gamepad UI:** soft targeting is the gamepad's own. On entering it, Blizzard sets temporary
  values on these same CVars (`Blizzard_Gamepad/Core.lua`, `C_CVar.SetTempCVar`: the interact
  plate off among them) and removes them on leaving. While `API.Gamepad()` is on (seen by the
  ticker): the stars hidden, nothing set or put back, and a `CVAR_UPDATE` is never taken as
  someone else's change. On leaving, each claimed CVar is read again: still ours, kept; otherwise
  someone else's, its claim cancelled (Codex). **The general rule: ownership is never judged while
  the gamepad UI is on.** Every check that could cancel, reclaim or put back (a `CVAR_UPDATE`, the
  login read, the turn-on claim, a pending restore) waits while it's on and runs once it's off; a
  login inside the gamepad UI defers its read to that moment (Codex).

**Removed with #61's waypoint marker:**
- the user waypoint and its super-track (`NodeRadarCharDB.marker`), the reconciler and its retry;
- `showInGameNavigation` and `NodeRadarDB.markerCVar`;
- the `SuperTrackedFrame.UpdateAlpha` post-hook, `Compass.lua`'s `Marker.TargetGone`;
- the probe's world and sight rounds (git history keeps them).

**Migration** (only the owner ran #61, never released): at `ADDON_LOADED`,
- a `markerCVar` left saved puts `showInGameNavigation` back if it still reads 1 (a change of
  someone else's already cancelled it under #61's rule), then the key goes;
- a `NodeRadarCharDB.marker` left saved is only dropped: a matching point isn't proof the waypoint
  is ours (Codex), so a stale one is the player's to clear.
- The user-facing text goes with it: the Options note, `/nr help`, CLAUDE.md's `Marker.lua` entry,
  the CHANGELOG's #61 entry rewritten for #78.

**Tests:** the plate chosen (an object, the soft target, known, wanted; each failing alone: no
stars); a secret name or unit; plates added and removed (the bound one's removal hiding the stars
before any search), a plate reused for another unit; a skip, `/nr skill` and a skill-up turning the
stars on or off within a tick; the CVars set and read back, put back, a change of someone else's
kept, in combat deferred; the gamepad UI in and out (its temporary values never cancelling a
restore), the marker turned off in combat or in the gamepad UI and put back once out; logout and login, `softCVars` kept across them, a value changed while unloaded left
alone at login, a login inside the gamepad UI keeping every claim and after the reconciler's next passes; a cancelled claim never taken again until
the marker is turned off and on; `/nr reset`; the migration; off: nothing runs and nothing is set.
Every widget method checked against the dump.

**Probe round** (`/fp steps nr softmark`), in game:
- **before the code**, the ablation (done, above);
- the marker on: the stars on a herb within 15 yards, up a slope, behind a rock (does the plate fade
  or hide), a skipped herb (none), a competing interactable, combat (the stars and a deferred set),
  the gamepad UI in and out if it can be tried;
- a reload, then a full client exit with the marker on, the CVars checked in both;
- the marker off, everything put back.

**Not in this issue:** hiding Blizzard's icon on other interactables; following the plate's alpha
(waits for the rock measurement); more than the one soft target (the game gives one).

## Combined marker: distant beacon and exact nearby stars (owner, 2026-10-22)

The owner found the 15-yard-only sparkle insufficient and requested a best-effort
distant cue. This adds to #78; the previous #61 trials above remain the evidence
for the waypoint anchor's limits. The adversarial design pass reached consensus
on a single-node beacon with the following safeguards.

- The existing `marker` toggle enables both. `Icons.Keeping` and
  `Compass.Choosing` include the marker; the compass ring can remain off.
- `FarMarker.Update` receives each successful sweep after target selection.
  It keeps a stable waypoint for the same record, expires after the idle scan
  interval plus two seconds, and drops immediately when the target is reset,
  gathered, filtered, or snoozed. A replacement waits for a fresh sweep.
- The native navigation frame supplies the camera-following screen anchor.
  After the owner's first screenshot (90 yards: too large and static), four
  independent twinkles flash, shrink, drift, and respawn at random positions.
  The art scales with distance (24 / yards, bounded 0.35–1.2), fades between
  45 and 60 yards, and is hidden outside 60 yards. The name and height hint remain;
  the compass provides distance. The owner's FFXIV video refinement puts those
  twinkles in a compact ellipse with three staggered wisps of teal vapor that
  expand, rise, and dissolve (also used on the nearby marker). The minimap height hint biases the cluster
  upward/downward. This is not recovered terrain height; it can show through
  scenery. No occlusion gate or camera calibration is claimed.
- A qualifying nearby plate suppresses the beacon and releases its waypoint,
  even if the soft target differs from the compass choice. Without a plate,
  the beacon remains available down to six yards, avoiding a blind 15-yard cutoff.
  Beyond 60 yards the waypoint is released; while combat/map prevents cleanup,
  its native marker is also suppressed so a distance label cannot leak through.
- The player's waypoint and any tracked objective take priority. Every write
  rechecks ownership and combat/map/gamepad gates, including after synchronous
  handlers. Failed untracking prevents clearing the point; failed clears retain
  ownership and retry. Unreadable slot/ownership state never permits a claim.
- `NodeRadarCharDB.farMarker` saves a pending owned waypoint for reload cleanup,
  using the previous documented matching-point assumption. `farNavigation`
  holds the navigation CVar claim separately from the nearby interact claims.
  Both wait for the marker's startup settling window. Logout restores them when
  possible; a failed cleanup remains saved. External CVar changes cancel until
  an explicit marker off/on. The native marker is covered only while our own
  beacon is actually visible; a tracked quest's display remains untouched.
- Occupying supertracking can prevent newly accepted quests from auto-tracking;
  the option and README disclose this existing #61 limitation.
- Suppression/state transitions are recorded in the existing marker decision
  log. No guided probe is required to use the beacon.

**Offline:** scanner/selector integration, marker with compass off, decreasing
scale at 20/35/50/59 yards, outer fade and 60/90-yard cutoff, independent animation
groups and respawn, above/below hints, plate handoff including a different node,
near-without-plate fallback, competing pins/quests, unreadable availability,
combat/map/gamepad deferral, failed untrack/clear, synchronous races, stale and
snoozed targets, CVar cancellation, and reload/logout cleanup. Twelve deliberate
mutations were caught; the restored code passes.

**Live:** the owner accepted the distance scaling and final vapor-and-sparkle
appearance on 2026-10-22 and approved committing it. The detailed acceptance
criteria remain useful for regression checks: appropriately scaled at roughly 20, 40, and 55 yards,
invisible beyond 60, with visible independent twinkling and no distance label; useful
while approaching uphill/downhill and turning the camera; smooth handoff to
nearby stars. The test is whether the beacon helps find the node despite its
approximate elevation. Offline tests cannot establish that visual result.

## A public API (#4), after #3

NodeRadar stays standalone: it reads Blizzard's `Minimap`, so it works under any skin (the stock
map, SexyMap, ElvUI, Glass MiniMap). It exposes `PUBLIC_API_VERSION` and a callback (name, kind,
position on the map); a skin that draws the alert itself (Glass MiniMap, as it does with Glass
MiniMap Bar) turns NodeRadar's own ring off.
