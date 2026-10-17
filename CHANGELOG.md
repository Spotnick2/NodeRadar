# Changelog

## Unreleased

Rebuilt for WoW: Forever (#3). The first version, written for TBC Anniversary, never worked: it
looked for the minimap's blips where the game doesn't put them.

- **Detects herb and ore nodes on the minimap**, with Find Herbs or Find Minerals on: a ping and a
  ring on the node the moment it comes into range. It reads the minimap through the client's own
  mouseover twice a second (about 4 ms), under any minimap skin, without touching your hover tooltip.
- **Learns which names are nodes**, once per name, for the whole account: from what you gather, and
  by turning your gathering tracking off and back on for a moment when it sees a name it doesn't
  know (standing still, out of combat; `/nr learn` to turn off). Tracking always comes back, even
  across a reload, and your own tracking changes win.
- **Ships with node names already learned**, and works in any language.
- Blizzard's minimap ping on the node, optional and solo only (`/nr ping`).
- `/nr known`, `/nr forget`, `/nr status` (names a build it wasn't measured on), `/nr failures`.
- Gone: mounted-only mode (there are no mounts on the beta).
- The repository is set up like the other Forever addons: tests, CI, deploy script (#1).
