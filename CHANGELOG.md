# Changelog

## Unreleased

Rebuilt for WoW: Forever (#3). The first version, written for TBC Anniversary, never worked: it
looked for the minimap's blips where the game doesn't put them.

- **Detects herb and ore nodes on the minimap**, with Find Herbs or Find Minerals on: a ping and a
  ring on the node the moment it comes into range. It reads the minimap through the client's own
  mouseover (about 4 ms a look), under any minimap skin, without touching your hover tooltip.
- **Learns which names are nodes**, once per name, for the whole account: from what you gather, and
  optionally (`/nr learn`, off by default since it costs a global cooldown) by turning your
  gathering tracking off and back on for a moment when it sees a name it doesn't know (standing
  still, out of combat). Tracking always comes back, even across a reload, and your own tracking
  changes win.
- The radar stands down only for the Gamepad UI (Options), not for the `GamePadEnable` setting,
  which is on for keyboard players too.
- **Sweeps follow your speed**: about every 2 yards you move (0.29 s running, 0.71 s walking), every
  2 s standing still.
- A node above or below you is the same node: names lose the minimap's position arrow and colour
  codes (it used to ping only once you reached its height).
- **Ships with node names already learned**, and works in any language.
- Blizzard's minimap ping on the node, optional and solo only (`/nr ping`).
- `/nr known`, `/nr forget`, `/nr status` (names a build it wasn't measured on), `/nr failures`.
- Gone: mounted-only mode (there are no mounts on the beta).
- The repository is set up like the other Forever addons: tests, CI, deploy script (#1).
