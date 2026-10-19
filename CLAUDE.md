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

**Status:** v1.0.1, after v1.0.0 (#23), the first release for Forever. Done:
- the repo setup (#1) and the probes that decided detection (#2) and classification (#7);
- the port (#3, `docs/PLAN.md`, reviewed by Codex to consensus), with the release check in game
  (70450, docs/FOREVER-PROBE.md);
- the sweep's garbage (#11);
- the Options page and sounds (#13);
- publishing to CurseForge and Wago (#15);
- the classic node names in 11 languages (#17, #19);
- v1.0.1: only nodes the player can gather alert (#26), and the chat line's map coordinates (#27).

Next: item icons for the minimap's nodes (#28); then the experimental in-world marker (#29) and the
public API for minimap skins (#4). On hold for the live game: fishing pools (#25), GatherMate2 (#30).

## The UI contract (non-negotiable)

- **Never move, reparent, resize or hide `Minimap` / `MinimapCluster`.** They're Edit Mode systems
  and a taint minefield (porting guide, "Edit Mode systems"). Our frames are unnamed children of
  `Minimap`.
- Never reassign a Blizzard global or method; `hooksecurefunc` and our own frames only.
- The sweep drives the minimap's mouseover and the soft cursor: the soft cursor is turned off after
  every sweep, on every path, and no sweep runs with the Gamepad UI on (`InputUtil.IsGamepadUIEnabled()`,
  never the `GamePadEnable` CVar: it's on for keyboard players too).
- **Gathering tracking is the player's.** The toggle turns it off only to learn, restores it always
  (across a reload too), and never overrides a change the player made.

## Layout

TOC load order: `Compat.lua` → `Data\Nodes.lua` → `Scan.lua` → `Learn.lua` → `Alert.lua` →
`Icons.lua` → `Options.lua` → `NodeRadar.lua`. One global namespace, `NodeRadar` (`local NR = NodeRadar`).

- `Compat.lua`: `NodeRadar.API`: `RegisterEvents` / `RegisterUnitEvent` (a throw or a `false` is a
  failure), `Fail` (the one failure recorder, `/nr failures`), secret-safe readers, the player's
  state (`Speed`, `Casting`, `Dead`, `Gamepad`); `MEASURED_ON_BUILD`.
- `Data/Nodes.lua`: the shipped library, `NodeRadar.LIBRARY[locale][name] = "herbs" | "ore"`, and
  `NodeRadar.NODE_INFO[locale][name] = { skill, item }` (#26). **Generated**: change it with
  `Tools/export_nodes.lua`, never by hand.
- `Scan.lua`: `Scan.Sweep()`, one read of the map's blips (soft cursor on, a grid of 14 in
  `GetCursorPosition`'s space, same-name hits grouped into separate blips, a cluster of a known
  node read again at 7 so nodes side by side stay apart, `Scan.Sweep(count)`; the soft cursor turned off on every path). Every read
  is a 2.5 KB table to collect (#11): keep them few. Each result carries `where` (`Scan.Where`: the
  player's zone map, position and size, the view radius; nil in an instance or rotating), and
  `Scan.MapPosition(result, blip)` gives a blip's `uiMapID, x, y` (#27, measured within reach).
  `Scan.Centre(blips)` measures a node's exact centre (its 25-unit square's edges, 29 reads, #28),
  with the sweep's soft-cursor guarantee.
- `Learn.lua`: `Learn.Kind(name)`; learning from gathering casts and from the toggle experiment
  (every guard in PLAN.md: the experiment is voided by movement, zone, loading, death, the gamepad,
  a zoom, a failed sweep or the player's own tracking change; tracking is always restored, across a
  reload through `NodeRadarCharDB.pendingRestore`, and the player's own choice wins).
- `Alert.lua`: new nodes by a rise in a name's count, only those the player can gather
  (`Alert.Gatherable`: `NODE_INFO`'s skill against `API.Skill`, Cultivation for herbs, #26); the sound (`Alert.SOUNDS`: the map ping, two of
  the client's files by FileDataID, six `Media\*.ogg` from Pixabay made by `Tools/import_sounds.py`,
  README "Sounds"), the sonar, chat line, solo-only ping.
- `Icons.lua` (#28, `icons`, off by default): records of measured nodes in world yards
  (`UnitPosition`: north, west), matched to each radar sweep's blips by name within 8 units,
  drawn every frame as unnamed mouse-through children of `Minimap`; `NR.Step` reconciles them
  before the alert and the learner. Off, nothing runs. docs/PLAN.md has every rule.
- `Options.lua`: the page in Esc > Options > AddOns (GlassMail's recipe from the porting guide:
  hidden at creation, built on the first show, re-read on every show; radio groups). Refreshing only
  reads settings: a value it doesn't offer (`/nr cd 7`) shows and is kept.
- `NodeRadar.lua`: settings (`NodeRadarDB`: settings and `learned`), the radar loop (`NR.Step`),
  events, `/nr`.
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
- **The owner merges and closes PRs and launches reviews.**
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

## Conventions

- **Right-size for a single maintainer.** The simplest thing that works; no speculative abstraction.
- **Measured beats reasoned.** If a claim about the client can be checked in game, check it.
- Match the surrounding code's idiom. Keep pure refactors in their own commit.
