# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NodeRadar is a **gathering-node alert for World of Warcraft: Forever 1.60.1** (Interface `16001`),
written in **Lua 5.1**: a ping and a flash on the minimap when a herb or ore node comes into range
while you ride. It has a single owner (Spotnick) and uses the same stack and conventions as the
sibling Forever addons, above all `..\GlassMail` (the template for this repo's tooling, tests and
CI). When this file doesn't cover something, check how those handle it before you invent a new idiom.

The plan is [docs/PLAN.md](docs/PLAN.md); measured client facts go in
[docs/FOREVER-PROBE.md](docs/FOREVER-PROBE.md).

**Status:** v1.8.0, after v1.7.1, v1.7.0, v1.6.0, v1.5.0, v1.4.0, v1.3.0, v1.2.0, v1.1.0, v1.0.1 and v1.0.0 (#23), the first release for Forever. Done:
- the repo setup (#1) and the probes that decided detection (#2) and classification (#7);
- the port (#3, `docs/PLAN.md`, reviewed by Codex to consensus), with the release check in game
  (70450, docs/FOREVER-PROBE.md);
- the sweep's garbage (#11);
- the Options page and sounds (#13);
- publishing to CurseForge and Wago (#15);
- the classic node names in 11 languages (#17, #19);
- v1.0.1: only nodes the player can gather alert (#26), and the chat line's map coordinates (#27);
- v1.1.0: `release.json` for WowUp (#35); item icons on the minimap's nodes, off by default (#28);
  their frames following the minimap (glass with Glass MiniMap, else bronze), three sizes and a
  height arrow (#41). Checked in game on 70450;
- v1.2.0: choosing which herbs and ores, with presets and smart following the skill, per character
  (#47); a yellow icon frame, the tracking dots' colour (#50); the experimental compass, off by
  default (#29: Forever draws no waypoint marker, so it became a compass). Checked in game on 70450;
- v1.3.0: a minimap button with a context menu, and snoozing the compass's node (#46); moving the
  compass with Alt-drag (#57); merged pairs keeping their icons (#66), peeled into two from a
  standing start, with provisional icons for what's left unexplained (#67). Checked in game on
  70450 (#67's merged pair offline only).
- v1.4.0: the skill a node needs in the minimap's tooltip (#62), checked in game on 70450 (a node
  above the skill, red, seen in game too on 2026-10-20); nodes alerting on the way out of a cave or a tunnel
  (#63): the swap indoors or out no longer resets the alert, only a `Minimap:SetZoom` call does
  (measured on 70450; the fix offline only, no node was in view at a swap).

- v1.5.0: the marker in the world, experimental: #78's exact nearby stars plus a distant
  beacon using #61's measured waypoint anchor. The beacon is explicitly approximate in height,
  with independently animated stars and drifting teal vapor, node label, and above/below hint. It scales with distance
  and fades out between 45 and 60 yards; no duplicate distance text. Offline checked; the owner
  accepted the scaling and final vapor-and-sparkle appearance in game (docs/PLAN.md, "Combined marker").

- v1.6.0: party nodes, step 1 (#83, PR #84): `shareNodes` sends the measured wanted nodes over
  `PARTY` / `RAID`, `partyNodes` draws a group member's on the minimap with a blue pip, no profession or
  tracking needed. Measured on 70790 (two accounts: delivery, the throttle, the 255-byte cut) and
  checked in game (`partylook`).

- v1.7.0: party nodes, step 2 (#83, PR #86): the compass, the beacon, the stars and the sonar on a
  group member's nodes (`Share.Live`), own nodes first. Checked in game on 70790 (`partyguide`,
  `partybeacon`): the compass, stars and sonar; the beacon yields to a levelling guide's
  super-tracked quest (docs/FOREVER-PROBE.md), so a free-slot beacon on a party node is unseen.

- v1.7.1: client build 70862 made `Minimap:UpdateMouseoverAtPoint` do nothing, on purpose
  (Stanzilla/WoWUIBugs#894), so every sweep read nothing (measured, docs/FOREVER-PROBE.md). From
  70862 NodeRadar stops sweeping and says why (#90, PR #92); what the toggle learned while blind is
  dropped (#95, PR #96); the marker's login read waits out combat (#93, PR #94). Offline tested.

- v1.8.0: the minimap scan mode (#91, opt-in, from 70862): step 1, presence alerts (PR #101), and
  step 2, locating the nodes for the icons, sonar, compass, beacon and sharing (PR #102: eight Codex
  rounds on the record lifecycle, then the in-game speed work: per-burst diagnostics, a rise
  restarting the search, quick bursts as a rolling allowance, the first look retried, no burst over
  a sonar). Glass MiniMap's side shipped in its v1.1.0 (GlassMiniMap#56). `/nr` help's separators
  (#98, PR #105). Checked in game on 70862 (the owner's herbalist, 2026-11-09): foreground located
  in 0.4-2.5 s; the background frame cap (30) and mouse steering are the limits.

Next: the scan's remaining steps (#91; Codex's plan in the PR #102 discussion): the gathered-spot
suppression bound to one node, names interleaved in a search, no beacon on a coarse record, then
refining the compass's target (5-yard windows, measured first) and keeping records across a reload;
the probe of reads right after mouse steering; the background frame rate per character (#104,
with the follower and party session); Glass MiniMap's stand-in face (#103); the public API for minimap
skins (#4); #78's round in game (`softmark`); #63's grey names in caves (unmeasured: no node in a cave yet). On hold: fishing pools (#25) and GatherMate2 (#30) for the
live game, WoWInterface (#37).

## The UI contract (non-negotiable)

- **Never move, resize, reparent, rescale or hide `MinimapCluster` or its container. Never reparent,
  rescale, or call `Hide()` on `Minimap`.** The cluster is an Edit Mode system and a taint minefield
  (porting guide, "Edit Mode systems"). **The one exception is the minimap scan** (#91, `MoveScan.lua`,
  opt-in, from build 70862): it may temporarily change an unprotected `Minimap`'s anchors, width and
  height, own alpha, icon scale, screen-clamp flag, mouse-click and mouse-wheel states, give
  Blizzard's player coordinates and LFG eye alpha 0 and mouse off, and turn the minimap's quest-area
  tracking (`QuestPOIs`, always on in Blizzard's menu) off for the borrow: the one tracking it touches,
  owed back in `NodeRadarDB.questOff` until it reads on (the owner, 2026-11-09: the areas ignore the
  map's alpha and flashed across the screen at a locate window's size); never its mouse motion, strata,
  level, parent or scripts, nor another addon's frames. Only out of combat, Edit Mode, loading and the
  gamepad UI, with the cursor resting over the world. Everything saved first and restored on every
  exit, geometry before visibility and input; a restore that fails stays pending (the map invisible
  and click-off), is retried, never dropped, and turns the scan off. Only the scan's own minimap
  tooltip is hidden (a post-hook). An unread scan is never "nothing there". docs/PLAN.md, "The minimap
  scan mode", has every rule. Our frames are unnamed children of
  `Minimap`, except the compass's ring (#29), an unnamed child of `UIParent` whose disc takes mouse
  motion only (its tooltip; clicks go through): the rule is about never touching the minimap, and
  the ring isn't on it. And NodeRadar's minimap button (#46): LibDBIcon's, a **named** child of
  `Minimap` (`LibDBIcon10_NodeRadar`) as every LibDBIcon addon's is, placed by the library.
- Never reassign a Blizzard global or method; `hooksecurefunc` and our own frames only.
- The sweep drives the minimap's mouseover and the soft cursor: the soft cursor is turned off after
  every sweep, on every path, and no sweep runs with the Gamepad UI on (`InputUtil.IsGamepadUIEnabled()`,
  never the `GamePadEnable` CVar: it's on for keyboard players too).
- **Gathering tracking is the player's.** The toggle turns it off only to learn, restores it always
  (across a reload too), and never overrides a change the player made.

## Layout

TOC load order: the libraries (`Libs\`: LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0,
committed as GuildSpy ships them, #46) → `Compat.lua` → `Data\Nodes.lua` → `Scan.lua` → `Learn.lua` → `Alert.lua` →
`Track.lua` → `Icons.lua` → `Share.lua` → `Compass.lua` → `Marker.lua` → `FarMarker.lua` → `Options.lua` → `TrackOptions.lua` → `Tooltip.lua` → `Minimap.lua` →
`Locate.lua` → `ScanFace.lua` → `MoveScan.lua` → `NodeRadar.lua`. `Bindings.xml` is found by its name (the key binding). One global namespace, `NodeRadar` (`local NR = NodeRadar`).

- `Compat.lua`: `NodeRadar.API`: `API.Blind()` (#90: from build 70862, `NR.BLIND_FROM`, a sweep reads
  nothing, so `NR.Step` stops before it and `NR.BlindNotice` says why once per build); `RegisterEvents` / `RegisterUnitEvent` (a throw or a `false` is a
  failure), `Fail` (the one failure recorder, `/nr failures`), secret-safe readers, the player's
  state (`Speed`, `Casting`, `Dead`, `Gamepad`); `API.Skill(line, base)`: a rank, or nil and
  `"absent"` (no profession) or `"unreadable"` (#62); `MEASURED_ON_BUILD`.
- `Data/Nodes.lua`: the shipped library, `NodeRadar.LIBRARY[locale][name] = "herbs" | "ore"`, and
  `NodeRadar.NODE_INFO[locale][name] = { skill, item }` (#26). **Generated**: change it with
  `Tools/export_nodes.lua`, never by hand.
- `Scan.lua`: `Scan.Sweep()`, one read of the map's blips (soft cursor on, a grid of 14 in
  `GetCursorPosition`'s space, same-name hits grouped into separate blips, a cluster of a known
  node read again at 7 so nodes side by side stay apart, `Scan.Sweep(count)`; the soft cursor turned off on every path). Every read
  is a 2.5 KB table to collect (#11): keep them few. Each result carries `where` (`Scan.Where`: the
  player's zone map, position and size, the view radius; nil in an instance or rotating), and
  `Scan.MapPosition(result, blip)` gives a blip's `uiMapID, x, y` (#27, measured within reach).
  `Scan.Centre(blips, budget, match)` measures nodes: a lone blip's centre from its centroid (its
  25-unit square's edges, 29 reads, #28), then a merged one peeled a node at a time from its
  outermost unexplained cell (#67: about 30 reads a node, `Scan.Explains` / `Scan.Unexplained`),
  with the sweep's soft-cursor guarantee.
- `Learn.lua`: `Learn.Kind(name)`; learning from gathering casts and from the toggle experiment
  (every guard in PLAN.md: the experiment is voided by movement, zone, loading, death, the gamepad,
  a zoom, a failed sweep or the player's own tracking change; tracking is always restored, across a
  reload through `NodeRadarCharDB.pendingRestore`, and the player's own choice wins).
- `Alert.lua`: new nodes by a rise in a name's count, only those the player can gather
  (`Alert.Gatherable`: `NODE_INFO`'s skill against `API.Skill`, Cultivation for herbs, #26); the sound (`Alert.SOUNDS`: the map ping, two of
  the client's files by FileDataID, six `Media\*.ogg` from Pixabay made by `Tools/import_sounds.py`,
  README "Sounds"), the sonar, chat line, solo-only ping. `Alert.Wanted` = gatherable and not
  skipped (#47): what the alert, the compass and the icons' dim all use.
- `Track.lua` (#47): which herbs and ores, per character (`NodeRadarCharDB.track`: `ignored` by item
  ID, `smart`, `last`), one row per item from `NODE_INFO` (several nodes give one item, each keeping
  its skill); the items' states from the **base rank** (`API.Skill(line, true)`: gear moves only the
  modifier); the presets; smart (`Track.Follow`, before `Icons.Update` in `NR.Step` and at
  `SKILL_LINES_CHANGED`) edits the list only when the rank crosses a line. A change refilters the
  icons (`Icons.Refilter`: skipped records dropped unless shown dimmed, `ignoredIcon`) and the
  compass at once.
- `Icons.lua` (#28, `icons`, off by default): records of measured nodes in world yards
  (`UnitPosition`: north, west), matched to each radar sweep's blips by name within 8 units,
  drawn every frame as unnamed mouse-through children of `Minimap`; `NR.Step` reconciles them
  before the alert and the learner. A record left unmatched stays while a blip of its name has a
  cell in its square (#66: two merged into one blip). A blip's cells no record explains are measured
  (four blips, 200 reads a sweep at most; a shape left unexplained retried at 5 s doubling to 60),
  and what stays unexplained gets provisional icons, rebuilt each sweep, never records (#67). A
  gathered node's spot (`gone`, its dot lingering while the loot window is open) explains cells
  too, so it's never measured back (PR #68). Dimmed: not `Alert.Wanted`, or snoozed (#46). Off,
  nothing runs. docs/PLAN.md has every rule.
  The look (#41, `iconStyle`, `iconSize`): plain, a glass disc (LibGlass borrowed from Glass
  MiniMap, nothing embedded; any failure latches to bronze) or a bronze ring (Blizzard's
  `MiniMap-TrackingBorder` as LibDBIcon lays it out) or a yellow ring (#50, our `Media/IconRing.tga`
  tinted `Icons.YELLOW`, the tracking dots' colour; never auto's); auto follows the minimap. One `bind` sets a
  frame's look, icon, dim and height arrow (`Scan.Height`, folded per cell and blip).
- `Share.lua` (#83, `shareNodes` / `partyNodes`, both off): party nodes. The sender (`Share.Send` in
  `NR.Step` after `Icons.Update`, `Share.Gathered` after `Icons.Gathered`) sends a snapshot of its wanted
  records with an item over `PARTY` / `RAID` (prefix `NodeRadar`, `1|session|seq|instance|item,north,west,name;...`,
  whole entries within 255 bytes, never closer than 1 s, again every 10 s unchanged, a refusal changing
  nothing; `Icons.Keeping` includes `shareNodes`). The receiver (`Share.OnMessage`) keeps each roster
  member's newest snapshot (by session, then seq) until 25 s without one (its own 1 s ticker), the same
  node's table reused; the roster by `GetUnitName(unit, false)`, the player never in it (the echo).
  `Icons.SetShared` draws them: a third list, never records, never dimmed, a blue pip, its own
  eligibility (no local sweep needed; the driver kept while one is kept), hidden while a drawn local icon
  of its item is within 8 yards. Measured: docs/FOREVER-PROBE.md, "Party addon messages".
  Step 2: `Share.Live(e)` is a party node's one freshness rule (showing, kept, heard within `EXPIRE`
  read now, the player's instance), used by the compass's `choose` and `frame`, the beacon's `fresh`
  and `Share.Near` (the stars: a plate named as a live party node within 15 yards of the player).
  Own nodes first: `choose` takes party nodes only with no local candidate (the owner, two gatherers).
  The compass chooses again after each rebuild and on the 1 s ticker (`Compass.Refresh`, which also
  places a party target's beacon from `Scan.Where()` read then); `Icons.Clear` keeps a party target
  (`Compass.LocalCleared`). The sonar on a node arriving, best effort: `e.pending` set past a sender's
  `QUIET` baseline (each session its own) for a node not `seen` within `SEEN`, played on its first draw within `PENDING`.
- `Compass.lua` (#29, `compass`, experimental, off by default): under the character, the nearest
  gatherable record's item icon on our own art (`Media/Compass*.tga` from `Tools/make_media.py`: a
  shadow, a dark lens, a rim tinted pearl, bronze or yellow as the icons' frame resolves, `Icons.Style()`;
  no LibGlass), the arrow and a rim highlight orbiting toward it (`atan2(-east, north) - GetPlayerFacing()`,
  measured), the distance in a pill, the item's tooltip on hover (mouse motion only, clicks
  through), `compassSize`; Alt-drag moves it (#57, as Apotheca: a grip over its footprint while Alt is
  held over it, from live input; `compassX, compassY` clamped on screen, `compassLock`); chosen again every sweep with a 5-yard hysteresis and after a gather,
  among the wanted records not snoozed (#46);
  hidden within 15 yards (the marker's stars take over, #78). Records are kept while icons or the compass
  is on (`Icons.Keeping`); the target is chosen while the compass is (`Compass.Choosing`,
  `Compass.Chosen`). `Icons.On` alone draws icons. `NR.Step`:
  `Icons.Update` → `Compass.Reconcile` → `Alert.Update` → `Learn.Consider`, then a
  learner experiment just started clears the records.
- `Marker.lua` (#78, `marker`, experimental, off by default; replaced #61's waypoint marker, whose spot
  is at the player's height): twinkling stars (FFXIV's gathering sparkle: `Media/MarkerStar.tga` from
  `Tools/make_media.py`, faint teal `SonarGlow`, engine animation groups) on the **nameplate the game
  gives its soft-interact target**, on the object at its real height, one at a time, within about 15
  yards (measured): a child of `UIParent` anchored to the plate's `BOTTOM`, when the target is a game
  object, a node known and `Alert.Wanted`. `Marker.Reconcile` at `NAME_PLATE_UNIT_ADDED` and on a
  0.5 s ticker; the bound unit's `NAME_PLATE_UNIT_REMOVED` hides at once. The three interact CVars
  it needs (`Marker.CVARS`, the ablation round) are the player's: claimed only when the marker is
  turned on (`NodeRadarDB.softCVars = { [name] = { old, ours } }`), put back when it or NodeRadar goes
  off (only if still ours), someone else's change cancels a claim for good (until off and on);
  nothing written in combat, **nothing judged inside the gamepad UI** (Blizzard's temporary values);
  put back at logout, best effort, the claims kept and read again at login. docs/PLAN.md has every rule.
- `FarMarker.lua`: the combined marker's distant beacon, driven by `Compass.Chosen()` and the
  scan's map geometry. Records are kept and a target chosen with `marker` alone. The waypoint
  and navigation CVar use separate saved ownership (`farMarker`, `farNavigation`), conservative
  readbacks, deferred cleanup in combat/map/gamepad, and the marker's login settling guard.
  Any exact nearby stars suppress it. No occlusion inference or terrain-height estimate.
  State transitions go through the marker decision log. `test_farmarker` covers the handoff,
  ownership races, failed cleanup, CVar cancellation, and reload/logout.
- `Options.lua`: the page in Esc > Options > AddOns (GlassMail's recipe from the porting guide:
  hidden at creation, built on the first show, re-read on every show; radio groups). Refreshing only
  reads settings: a value it doesn't offer (`/nr cd 7`) shows and is kept.
- `TrackOptions.lua` (#47): the Herbs and Ores sub-pages (`Settings.RegisterCanvasLayoutSubcategory`
  right after the main page, from `Options.Register`), one builder; item names asked for with
  `RequestLoadItemDataByID` and filled on `ITEM_DATA_LOAD_RESULT`.
- `Tooltip.lua` (#62, `tooltipSkill`, on): "Requires Herbalism (15)" in the minimap's hover
  tooltip, one line per distinct known node (`Learn.Info`'s skill), coloured by
  `TrackOptions.colour` at the **effective** rank (no profession: red; unreadable: no line). A
  `TooltipDataProcessor` post-call on the MinimapMouseover type (21), registered at login: it only
  adds lines to `GameTooltip`, so `C_TooltipInfo.GetMinimapMouseover` (what `Scan` reads) never
  sees them. Any secret in what it reads: no line; its body in a `pcall`, a failure recorded once.
- `Minimap.lua` (#46): NodeRadar's minimap button (GuildSpy's recipe: a LibDataBroker launcher shown
  by LibDBIcon, `NodeRadarDB.minimap` its table, `minimapButton`), its context menu
  (`MenuUtil.CreateContextMenu`: the radar, icons and compass toggles, which close it; the snooze
  of the node it showed when it opened; clearing), the right-click to Options, the AddOns
  compartment (`NodeRadar_OnAddonCompartment*`), the key binding (`BINDING_NAME_NODERADAR_SNOOZE`,
  `snoozeFor`). Snoozes themselves are the compass's (`Compass.Snooze`, `Snoozed`: in memory, by name,
  instance and spot within 8 yards; a reload clears them). Tests never load `Libs\`: the stubs fake
  LibDataBroker, LibDBIcon and `MenuUtil`.
- `MoveScan.lua` (#91, `moveScan`, off; `scanEvery`, 2): the minimap scan from build 70862. A burst on
  its own driver: borrow and prepare (admission: `MS.Refusal`; Glass MiniMap v1's `ScanBegin`; the home
  saved), place the map's centre under the resting cursor and `UpdateBlips`, a settle frame, read and
  restore, a settle frame (the tooltip post-hook still hiding, everything read back). Every 2 s moving,
  6 s still (`MS.Every`). A valid read (lines, `Minimap` the top focus, in place) is a **presence**
  observation, `NR.Observe("presence", { counts })` → `Alert.Counts` (the sound and the chat line).
  The rest of a burst (up to `MS.PLACEMENTS`, within the 250 ms budget) is Locate's windows. Followers (another
  addon's frame anchored into the map) and a Glass MiniMap without version 1 refuse the scan, named
  once. The login prompt (`moveScanAsked`), `/nr scan`, Options. Tests: `test_movescan` on the stubs'
  move model (`WoW.moveModel`).
- `Locate.lua` (#91, step 2): where the scan's nodes are. Windows in world yards (`M = 2R·9/W` px: the
  16 px hit square less twice its 3.5 px offset), the map's sixteenths split while positive down to
  `FINE` (16 yards), deepest then nearest first; each read paired with the player's move since its
  placement; a window's empty answer is no node there (nil is unread), and a failed presence read ends
  the burst. A burst's positive leaves settle at its end, grouped per axis within a leaf's reach
  (complete-link, in a fixed order), never more new records than the count leaves room for. Records
  live on evidence (a presence count of 0, a re-check at the spot every `RECHECK` s, out of range by
  more than `SLACK`, a gather), never time; each keeps its uncertainty `err`. A re-check window covers
  it when the record is isolated (its negative drops it), or half the gap to the nearest record of its
  name in a cluster (its negative proves nothing). Identity errors (an ambiguous or narrow re-check, a
  group beyond the count) trigger a **rebuild**: the name's records become priors (drawn, not counted),
  a fresh search finds every node again, a node found where a prior was keeps that record silently,
  the priors left go once the count is met; one per name per `BACKOFF`. A gathered spot (`gone`, `GONE`
  s) is the same node. Tests: `test_locate`, `test_locate2` (Codex's review rounds on PR #102). Published once a burst with the map
  home (`NR.Located`): `Icons.SetRecords`, `Share.Send`, `Compass.Reconcile`, `FarMarker.Update`, then
  `Alert.Located` for the new ones (owed by a count's rise: its sonar; there at the first look after a
  reset: silent; else the full alert: a node replaced another between reads). The consumers'
  freshness is `API.LocalFresh` (the sweep's interval before 70862, the scan being on after). The
  trace (`/nr scan log`) is saved at logout while the scan is on: `NodeRadarDB.scanLog`
  (`scanLogPrevious` the session before).
- `ScanFace.lua` (#103): the scan's stand-in at the minimap's home while a burst borrows it: a
  dark radar face with a turning sweep (`Media/Scan*.tga`) under a copy of Blizzard's frame ring
  (`MinimapCompassTexture`'s atlas, read at the borrow), an unnamed mouse-off frame on `UIParent`.
  `ScanFace.Begin` in the borrow before the map moves, `ScanFace.End` at the restore: held 0.4 s,
  faded 0.2 s (Glass MiniMap's timing). Ours only without Glass MiniMap, or when its
  `ScanStandIn()` answers false; its 1.1.0 (no `ScanStandIn`) gets none. Tests: `test_scanface`.
- `NodeRadar.lua`: settings (`NodeRadarDB`: settings and `learned`), the radar loop (`NR.Step`),
  events, `/nr`; the zoom (#63): a `Minimap:SetZoom` hook resets the alert when the zoom changes,
  `MINIMAP_UPDATE_ZOOM` alone (the swap indoors or out) keeps it and voids the learner's experiment.
- `Tools/export_nodes.lua` (+ `.ps1`): merges learned nodes from SavedVariables into the library;
  prints additions with their provenance for review, writes with `--write`.
- `Tools/Reference/classic-enUS.lua`: the classic herb and ore names (English, not measured: a
  reference list, #17), an input to the export in the SavedVariables shape. Tests run on a small
  fixed library (`TEST_LIBRARY`, harness), whatever `Data/Nodes.lua` ships; `test_export` pins
  the real one.
- `Tools/extract_gathermate.lua <GatherMate2 folder> [--write]` → `Tools/Reference/gathermate2.lua`:
  the classic nodes' names in every language, with GatherMate2's node ID, from its node table and
  locale files (`..\References\Addons\MapMinimap\GatherMate2`), run in a sandbox that only records names (#19).
  `Tools/Reference/node-info.lua`: the Classic skill and item per node ID (#26). The export reads
  every `Tools/Reference` file on each run and rebuilds `NODE_INFO` whole:
  `lua5.1 Tools/export_nodes.lua <SavedVariables>... --write` (or `pwsh Tools/export_nodes.ps1`).
- `Tools/NodeRadarProbe/`: the throwaway measurement addon, a ForeverProbe module
  (`..\ForeverProbe`, its `docs/GUIDE.md`): `/fp nr` for its commands, `/fp steps nr release` for the release check (#3).
  `/fp nr icons` dumps every blip against the icons' records, what a measure finds now and why it
  stops, the provisional icons and the backoffs (#67); `/fp nr twice [step]` reads the whole map
  for a name listed twice at a point (none so far: no overlap counts). Each feature has its round
  (`/fp steps nr <name>`, e.g. `nodots`, `snooze`).
  Its lines go to the `/fp` console, never to chat. Its tests run locally only (CI skips them).
- `tests/`: `wow_stubs.lua` (WowTestKit's core, then this addon's own client APIs and a minimap
  whose mouseover reads blips), `harness.lua` (the loaders; `checkMethods`; the kit's `done`
  unwrapped since #98), `test_*.lua` (`test_methods`: every widget method the addon calls exists on the pinned
  build), `kit.pin` and the kit's bootstrap copies, `run.ps1`.

## Forever basics (shared with the siblings)

- One plain `NodeRadar.toc`, `## Interface: 16001` (**`11601` is a transposed-digit bug**). Never
  commit a literal version over `@project-version@`; the deploy script writes `dev` into its copy.
- **Secret values:** test with `issecretvalue(v)` **before** any other use; never save one.
  Positions and visibility can be secret on this client (Glass MiniMap's probe, 70374).
- **`RegisterEvent` throws on unknown names and returns `false` for refusals.**
- SavedVariables persist as of 70009; read them at `ADDON_LOADED`, cope when they're absent, and
  **verify persistence only with a full client exit**.
- **IDs, never names**: never compare against or save an English display string. Tracking is
  matched by spell ID (2383/8387 Find Herbs, 2580/8388 Find Minerals).
- `PlaySound` refuses newer-expansion kits: check `willPlay`. `SOUNDKIT.MAP_PING` is 3175.

## References: read these before touching an unfamiliar API

- `C:\Projects\WoW\References\Docs\PORTING-TBC-TO-FOREVER.md`: measured, addon-agnostic field notes.
  Treat them as fact. New addon-agnostic findings go there, not into a copy here.
- `C:\Projects\WoW\References\Forever\api\forever-api-<version>.<build>.md`: the API dump; use the **highest
  build** there. This repo follows **1.60.1.70450** (the kit's data for 70450, `tests\kit.pin`,
  follows it). **Presence is not a contract.**
- `C:\Projects\WoW\References\Docs\PROBES.md` and `C:\Projects\WoW\ForeverProbe\docs\GUIDE.md`: probes.
- `C:\Projects\WoW\wow-ui-source`: the client's own FrameXML. `Blizzard_Minimap/Mainline/Minimap.lua`
  (the hover tooltip, the tracking menu) first; check its `version.txt` against the build.

## Toolchain and commands

Lua 5.1 at `C:\Program Files (x86)\Lua\5.1\` (`lua.exe`, `luac.exe`). No build step.

```powershell
pwsh tests\run.ps1                                                   # luac -p on the TOC files + probe, then every tests\test_*.lua (needs ..\ForeverProbe; -KitDev: the ..\WowTestKit copy)
& 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_probe.lua     # one test, from the repo root
pwsh Tools\deploy.ps1 -Probe                                        # NodeRadar + ForeverProbe + NodeRadarProbe into AddOns
```

- Default AddOns path: `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns`
  (`-AddOnsPath` to change).
- In game: `/console scriptErrors 1` first, then `/reload` (a brand-new addon folder included).
- Shell heredocs in this environment can collapse `\\` to `\`: write files that contain Lua
  backslash escapes or Windows paths with the Write/Edit tools.

## Testing

The test scaffolding is WowTestKit (`C:\Projects\WoW\WowTestKit`; its README is the reference)
at the commit and client build `tests\kit.pin` names. `tests\run.ps1` puts that commit in
`%LOCALAPPDATA%\WowTestKit\<sha>` and hands off to the kit's runner; CI fetches it with
`tests\fetch_kit.sh`. `tests\kit.lua`, `kit.ps1` and `fetch_kit.sh` are the kit's bootstrap
copies: never edit them here. A kit need is an issue on the kit, worked around in
`tests\wow_stubs.lua` with a `-- WowTestKit #N:` comment meanwhile. `tests\run.ps1 -KitDev`
runs against the `..\WowTestKit` working copy instead of the pin.

**Mutation-test every new test**: break the behaviour, confirm it goes red. Offline tests can't
cover taint, real secrets, rendering, or what the engine does with the minimap's mouseover; that's
the probe.

## Workflow and releasing

- Issue → branch off `main` → PR with `Closes #N`. A milestone that spans several PRs uses
  `Part of #N` until the last one, which says `Closes #N`. Never commit to `main`; commit or push
  only when asked. `luac -p` clean and tests green before committing; check the PR's
  `package-check` run after pushing.
- **The owner decides merges and launches reviews.** Merge a PR only on their explicit "merge N"
  (`gh pr merge N --merge`, after its check passes), never otherwise. Their Codex reviews land on
  the PR ("Codex: found ... on PR #N"): read them with `gh api repos/Spotnick2/NodeRadar/pulls/N/comments`,
  fix each finding with a regression test (mutation-tested), push, and check the run again.
- **Plans** get an adversarial review before coding: Codex via the `codex-consult` skill,
  `gpt-6-astra` at high effort, looping until consensus. Verify its claims; push back on complexity.
- **Code reviews are manual** (by the owner) unless the owner asks for one.
- CurseForge (project 1751109) builds releases from the tag webhook through `.pkgmeta`; the
  `release` job publishes a GitHub Release from the tag's `## vX.Y.Z` section of `CHANGELOG.md`,
  with `release.json` for WowUp (#35); the `wago` job uploads the same checked zip to Wago (project
  `mNwwoLNo`, the TOC's `X-Wago-ID`) with the `WAGO_API_TOKEN` secret (#15). Both publish what
  `check` built: the zip, and the notes and `release.json` from `tests/release_files.sh`. Both files
  are the shared templates (`..\References\Docs\release\`, RELEASING.md §2), the workflow with
  `ADDON: NodeRadar` and our own test and allowlist steps; update them from there.
  Re-publish a tag with `workflow_dispatch` from `main` (`publish: both | github | wago`).
- **A release:** a `release-X.Y.Z` branch turns `## Unreleased` into `## vX.Y.Z` with its date and
  updates this file's status; once the owner merges it, tag `vX.Y.Z` on `main` and push the tag
  (that's what publishes); then check the run's `release` and `wago` jobs.

## Conventions

- **Right-size for a single maintainer.** The simplest thing that works; no speculative abstraction.
- **Measured beats reasoned.** If a claim about the client can be checked in game, check it.
- Match the surrounding code's idiom. Keep pure refactors in their own commit.
- **Never name a competing addon** in tracked files, issues, PRs or commits (the owner, 2026-10-19).
  Notes on how others do things go in `.local/` (gitignored); the owner's own sibling addons and
  the libraries we use are fine to name.

## Consulting Codex

The shared `codex-consult` skill (user level) has the invocation and the gotchas. For this repo:

For NodeRadar, good things to hand Codex:
- anything that drives the minimap's mouseover (`Minimap:UpdateMouseoverAtPoint`): what it does
  to the player's own hover tooltip, its cost per frame, taint;
- what counts as a "new" node (a blip that scrolls back into view, two overlapping blips, a
  zone change), and the cooldown between alerts;
- anything that touches Blizzard's `Minimap` or `MinimapCluster` (an Edit Mode system: never moved,
  reparented or resized);
- the public API a minimap skin consumes (#4).

**Always hand it `CLAUDE.md` and `docs/PLAN.md` alongside the diff or plan**, plus
`C:/Projects/WoW/References/Docs/PORTING-TBC-TO-FOREVER.md` and `docs/FOREVER-PROBE.md`. Those findings
were measured on the live client. Without them, a cold reviewer argues from Classic-era or Retail
behaviour that doesn't hold here (that tracking blips are frames, that the old global tracking
functions exist).
The newest `C:/Projects/WoW/References/Forever/api/forever-api-1.60.1.<build>.md` is the full API surface when a
question turns on whether something exists, and `C:/Projects/WoW/wow-ui-source` is the client's own
FrameXML (`Blizzard_Minimap`).
