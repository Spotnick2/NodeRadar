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

**Status:** `NodeRadar.lua` is v1, an abandoned TBC Anniversary draft. **Its detection can't work**
(it looks for blips as Minimap child frames; the engine draws them), and it reads globals Forever
no longer has, so don't deploy it: `Tools\deploy.ps1 -ProbeOnly`. The repo setup is #1, the probe
that decides how detection can work is #2, the port is #3 (after #2), the public API for minimap
skins is #4 (after #3).

## The UI contract (non-negotiable)

- **Never move, reparent, resize or hide `Minimap` / `MinimapCluster`.** They're Edit Mode systems
  and a taint minefield (porting guide, "Edit Mode systems"). Our frames are unnamed children of
  `Minimap`.
- Never reassign a Blizzard global or method; `hooksecurefunc` and our own frames only.
- Reading the minimap's mouseover moves it: don't sweep while the player's cursor is on the map,
  unless #2 measured that it doesn't matter.

## Layout

- `NodeRadar.lua`: v1 (see Status).
- `Tools/NodeRadarProbe/`: the throwaway measurement addon, a ForeverProbe module
  (`..\ForeverProbe`, its `docs/GUIDE.md`): `/fp nr` for its commands, `/fp steps nr blips` for #2.
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
pwsh Tools\deploy.ps1 -ProbeOnly                                     # ForeverProbe + NodeRadarProbe into AddOns
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
