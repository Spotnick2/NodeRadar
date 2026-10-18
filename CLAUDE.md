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

**Status:** the port (#3) is written: the soft sweep, learning which names are nodes, the alert,
the library and its export tool, as `docs/PLAN.md` "The port (#3)" (reviewed by Codex to
consensus). Release check run 1 (70450, docs/FOREVER-PROBE.md): the restore costs a global
cooldown, so `learn` ships off; reload restore and persistence pass; the walk is re-run as
`/fp steps nr walk` after the gamepad-guard fix. Done: the repo setup (#1), the probe rounds that decided detection (#2) and
classification (#7). Next after the port: the public API for minimap skins (#4), an options page.

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
`Options.lua` → `NodeRadar.lua`. One global namespace, `NodeRadar` (`local NR = NodeRadar`).

- `Compat.lua`: `NodeRadar.API`: `RegisterEvents` / `RegisterUnitEvent` (a throw or a `false` is a
  failure), `Fail` (the one failure recorder, `/nr failures`), secret-safe readers, the player's
  state (`Speed`, `Casting`, `Dead`, `Gamepad`); `MEASURED_ON_BUILD`.
- `Data/Nodes.lua`: the shipped library, `NodeRadar.LIBRARY[locale][name] = "herbs" | "ore"`.
  **Generated**: change it with `Tools/export_nodes.lua`, never by hand.
- `Scan.lua`: `Scan.Sweep()`, one read of the map's blips (soft cursor on, a grid in
  `GetCursorPosition`'s space, same-name hits grouped into separate blips; the soft cursor turned
  off on every path).
- `Learn.lua`: `Learn.Kind(name)`; learning from gathering casts and from the toggle experiment
  (every guard in PLAN.md: the experiment is voided by movement, zone, loading, death, the gamepad,
  a zoom, a failed sweep or the player's own tracking change; tracking is always restored, across a
  reload through `NodeRadarCharDB.pendingRestore`, and the player's own choice wins).
- `Alert.lua`: new nodes by a rise in a name's count; the sound (`Alert.SOUNDS`: the map ping, two of
  the client's files by FileDataID, three `Media\*.ogg` from Pixabay made by `Tools/import_sounds.py`,
  README "Sounds"), the sonar, chat line, solo-only ping.
- `Options.lua`: the page in Esc > Options > AddOns (GlassMail's recipe from the porting guide:
  hidden at creation, built on the first show, re-read on every show; radio groups). Refreshing only
  reads settings: a value it doesn't offer (`/nr cd 7`) shows and is kept.
- `NodeRadar.lua`: settings (`NodeRadarDB`: settings and `learned`), the radar loop (`NR.Step`),
  events, `/nr`.
- `Tools/export_nodes.lua` (+ `.ps1`): merges learned nodes from SavedVariables into the library;
  prints additions with their provenance for review, writes with `--write`.
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

- `C:\Projects\WoW\References\PORTING-TBC-TO-FOREVER.md`: measured, addon-agnostic field notes.
  Treat them as fact. New addon-agnostic findings go there, not into a copy here.
- `C:\Projects\WoW\References\forever-api-<version>.<build>.md`: the API dump; use the **highest
  build** there. This repo follows **1.60.1.70450** (the stubs and `tests\events-70450.txt`
  follow it). **Presence is not a contract.**
- `C:\Projects\WoW\References\PROBES.md` and `C:\Projects\WoW\ForeverProbe\docs\GUIDE.md`: probes.
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
- CurseForge builds releases from the tag webhook through `.pkgmeta`; the `release` job publishes
  a GitHub Release from the tag's `## vX.Y.Z` section of `CHANGELOG.md`.

## Conventions

- **Right-size for a single maintainer.** The simplest thing that works; no speculative abstraction.
- **Measured beats reasoned.** If a claim about the client can be checked in game, check it.
- Match the surrounding code's idiom. Keep pure refactors in their own commit.
