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

**Status:** v1.4.0, after v1.3.0, v1.2.0, v1.1.0, v1.0.1 and v1.0.0 (#23), the first release for Forever. Done:
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

- Unreleased: the marker in the world (#61), experimental; its first round on the beta (70450,
  2026-10-20): stepping aside, the reload and logout clears, no taint; the stars too small then, and
  a waypoint churn found and fixed. The rest waits for the live client after November 4.

Next: the public API for minimap skins (#4); #61's round in game; #63's grey names in caves (unmeasured: no node in a cave yet). On hold: fishing pools (#25) and GatherMate2 (#30) for the
live game, WoWInterface (#37).

## The UI contract (non-negotiable)

- **Never move, reparent, resize or hide `Minimap` / `MinimapCluster`.** They're Edit Mode systems
  and a taint minefield (porting guide, "Edit Mode systems"). Our frames are unnamed children of
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
`Track.lua` → `Icons.lua` → `Compass.lua` → `Marker.lua` → `Options.lua` → `TrackOptions.lua` → `Tooltip.lua` → `Minimap.lua` →
`NodeRadar.lua`. `Bindings.xml` is found by its name (the key binding). One global namespace, `NodeRadar` (`local NR = NodeRadar`).

- `Compat.lua`: `NodeRadar.API`: `RegisterEvents` / `RegisterUnitEvent` (a throw or a `false` is a
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
- `Compass.lua` (#29, `compass`, experimental, off by default): under the character, the nearest
  gatherable record's item icon on our own art (`Media/Compass*.tga` from `Tools/make_media.py`: a
  shadow, a dark lens, a rim tinted pearl, bronze or yellow as the icons' frame resolves, `Icons.Style()`;
  no LibGlass), the arrow and a rim highlight orbiting toward it (`atan2(-east, north) - GetPlayerFacing()`,
  measured), the distance in a pill, the item's tooltip on hover (mouse motion only, clicks
  through), `compassSize`; Alt-drag moves it (#57, as Apotheca: a grip over its footprint while Alt is
  held over it, from live input; `compassX, compassY` clamped on screen, `compassLock`); chosen again every sweep with a 5-yard hysteresis and after a gather,
  among the wanted records not snoozed (#46);
  hidden within 15 yards (the glow is Lueur's). Records are kept while icons, the compass or the marker
  is on (`Icons.Keeping`); the target is chosen while the compass or the marker is (`Compass.Choosing`,
  `Compass.Chosen`), the ring shown only with the compass. `Icons.On` alone draws icons. `NR.Step`:
  `Icons.Update` → `Compass.Reconcile` → `Marker.Update` → `Alert.Update` → `Learn.Consider`, then a
  learner experiment just started clears the records.
- `Marker.lua` (#61, `marker`, experimental, off by default): twinkling stars in the world on the
  compass's target (FFXIV's gathering sparkle: `Media/MarkerStar.tga` from `Tools/make_media.py` and
  `SonarGlow`, tinted teal, engine animation groups), on the navigation frame (`C_Navigation.GetFrame()`)
  of a user waypoint we set on the node and super-track. One reconciler (`Marker.Reconcile`: what
  should be against what is, read again each run) from the sweeps, the waypoint and super-track
  events, combat's end, the frame's life and the toggles. It **steps aside**: never the player's
  waypoint (ours is only a point read back right after our own set, `NodeRadarCharDB.marker`), never
  while anything else is super-tracked, a half-cleared state left alone; nothing written in combat or
  with the world map open; a clear checked again as it happens, the super-track first, retried
  every 0.5 s while it's held; the point dropped with the compass's target and stale without a sweep
  for the idle interval and 2 s. Cleared at logout; at login only the saved point is adopted. `showInGameNavigation` held at 1 while on
  (`NodeRadarDB.markerCVar` to put back; someone else's change cancels that). The stars wait 0.3 s
  after a new waypoint and need the navigation's distance within 10 yards of ours; hidden within 15
  yards, on a taxi, clamped at the screen's edge. Blizzard's own marker while ours covers the spot: its
  diamond hidden, its distance kept (the whole marker hidden with the compass on), a post-hook on
  `SuperTrackedFrame.UpdateAlpha`. docs/PLAN.md has every rule. Not yet in game.
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
- `tests/`: `wow_stubs.lua` (strict globals as an allowlist of APIs verified in the dump, secrets,
  event names checked against the dump or `events-70450.txt`, every widget method recorded, and a
  minimap whose mouseover reads blips), `harness.lua`, `test_*.lua`, `run.ps1`.

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
  build** there. This repo follows **1.60.1.70450** (the stubs and `tests\events-70450.txt`
  follow it). **Presence is not a contract.**
- `C:\Projects\WoW\References\Docs\PROBES.md` and `C:\Projects\WoW\ForeverProbe\docs\GUIDE.md`: probes.
- `C:\Projects\WoW\wow-ui-source`: the client's own FrameXML. `Blizzard_Minimap/Mainline/Minimap.lua`
  (the hover tooltip, the tracking menu) first; check its `version.txt` against the build.

## Toolchain and commands

Lua 5.1 at `C:\Program Files (x86)\Lua\5.1\` (`lua.exe`, `luac.exe`). No build step.

```powershell
pwsh tests\run.ps1                                                   # luac -p on the TOC files + probe, then every tests\test_*.lua (needs ..\ForeverProbe)
& 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_probe.lua     # one test, from the repo root
pwsh Tools\deploy.ps1 -Probe                                        # NodeRadar + ForeverProbe + NodeRadarProbe into AddOns
```

- Default AddOns path: `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns`
  (`-AddOnsPath` to change).
- In game: `/console scriptErrors 1` first, then `/reload` (a brand-new addon folder included).
- Shell heredocs in this environment can collapse `\\` to `\`: write files that contain Lua
  backslash escapes or Windows paths with the Write/Edit tools.

## Testing

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
