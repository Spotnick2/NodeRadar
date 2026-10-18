# Changelog

## v1.0.0

Released 2026-10-18. The first release for World of Warcraft: Forever, rebuilt from scratch: the
old TBC Anniversary version never worked, since it looked for the minimap's blips where the game
doesn't put them.

- **A ping and a sonar the moment a herb or ore node comes into range**, with Find Herbs or Find
  Minerals on: two rings ripple out from the node on your minimap and a glow stays on it, green for
  herbs, gold for ore.
- **It reads the minimap the way its tooltip does**, a few milliseconds a look, under any minimap
  skin, without touching your own hover tooltip. About every 4 yards you move, every 2 seconds
  standing still.
- **One alert per new node.** A node slipping off the map's edge and back doesn't ping again; a
  respawn does, and so does the next node of a kind you've just gathered. A node above or below
  you is the same node.
- **Knows every classic herb and ore node** in English, German, French, Spanish, Portuguese,
  Italian, Russian, Korean and Chinese. A node name it doesn't know yet it learns the first time
  you gather one, for your whole account. Optionally (`/nr learn`, off by default: it costs a
  global cooldown) it learns an unknown name by turning your gathering tracking off and on for a
  moment; your tracking always comes back, even across a reload.
- **Options page** (Esc > Options > AddOns > NodeRadar, or `/nr options`): how often it looks, the
  sound (the minimap ping, a sonar or radar ping from the game, or one of six shipped sounds), the
  sonar on the node, a chat line, Blizzard's ping on the node (solo only), the time between alerts,
  a test button.
- Commands: `/nr` (on or off), `/nr options`, `/nr test`, `/nr status`, `/nr known`,
  `/nr forget <name>`, `/nr failures`, `/nr reset`; `/nr help` lists them all.
- The radar stands down while the Gamepad UI is on.
