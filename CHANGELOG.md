# Changelog

## Unreleased

- **Experimental: a compass toward the nearest node** (#29), off by default (`/nr compass`, or
  Options): under your character, the nearest node you can gather as its item's icon in a small
  disc framed like the minimap icons, an arrow circling it toward the node, the distance below, the
  item's tooltip on hover. Small, medium or large. It moves on as you gather and hides within 15
  yards. It follows your character's facing, not the camera's.

## v1.1.0

Released 2026-10-18.

- **Item icons on the minimap** (#28), off by default: each herb and ore node
  shows the icon of what it gives over Blizzard's dot, dimmed when your skill can't gather it yet.
  `/nr icons`, or Options. With icons on, the sonar plays on the node's measured centre.
- **Frames for the icons** (#41): a glass disc with Glass MiniMap, a bronze ring like Blizzard's
  minimap buttons on any other minimap, or none (`/nr iconstyle`); small, medium or large
  (`/nr iconsize`). A small arrow marks a node above or below you, as Blizzard's dot does.
- **WowUp can install NodeRadar from GitHub** (#35): every release now carries `release.json`, the
  file WowUp reads to find the Forever download (v1.0.0 and v1.0.1 have it too).

## v1.0.1

Released 2026-10-18.

- **Only nodes you can gather alert** (#26): NodeRadar knows each classic node's required skill and
  reads yours, bonuses included, so a node above your Herbalism or Mining no longer pings. A Tauren
  herbalist still hears herbs above their skill while Cultivation is ready. On by default; `/nr skill`
  or the Options page turns it off. A node it can't place, or a skill it can't read, alerts as before.
- **The chat line gives each node's map coordinates** (#27): `Peacebloom (45.2, 61.8)`, approximate
  (within a few yards of the node in game), for every node of an alerted name. Not inside instances,
  nor with a rotating minimap (`/console rotateMinimap 1`; Forever's Options don't offer it).

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
