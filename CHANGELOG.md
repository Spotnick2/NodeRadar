# Changelog

## Unreleased

- **Experimental: a marker in the world** (#61): the compass's node marked out on its spot with
  twinkling stars, seen through the scenery, with Blizzard's distance under them (or the
  compass's, when it's on). It puts your map
  waypoint on the node and tracks it, and steps aside whenever you have a waypoint of your own or
  track a quest. Off by default: `/nr marker`, or Options.
  The sparkle follows the FFXIV reference: diagonal white flares with mint and blue halos,
  staggered sizes and timing, gentle drift, and a faint background haze.
  The stars show only in the last stretch, within 40 yards by default (a slider in Options, or
  `/nr marker <yards>`), and grow as you close in; the compass points the way from farther off.
  A node the minimap marks above or below you gets none: the stars would sit on the ground under it.

## v1.4.0

Released 2026-10-20.

- **The skill a node needs, in the minimap's tooltip** (#62): hover a herb or ore on the minimap and
  it reads "Requires Herbalism (15)" under the name, coloured by difficulty as in the world: red
  while it's beyond your skill, then orange, yellow, green and grey. On by default; `/nr tooltip`
  or Options turns it off.
- **Nodes in view when you come out of a cave, a mine or a tunnel now alert** (#63). The minimap's
  switch indoors or out restarted NodeRadar's count without a sound, so whatever was in view on
  the way out stayed silent. Only your own zoom does that now.

## v1.3.0

Released 2026-10-19.

- **A minimap button** (#46): left-click for quick settings (the radar, the icons, the compass) and
  the snooze; right-click for the Options page. Drag it around the minimap; hide it in Options. Also
  in the AddOns compartment.
- **Snooze the compass's node** (#46): a node out of reach (on a ledge, guarded by mobs too strong)
  can be put aside for 15 minutes, 30 minutes, an hour or the session, and the compass moves on to
  the next. Its icon is dimmed meanwhile. From the minimap button's menu, a key binding (Key
  Bindings > NodeRadar), or `/nr snooze`. A reload clears them, and so does `/nr snooze clear`.
- **No more yellow dots between the icons** (#66, #67): two herbs or ores of one name side by side
  now each get their own icon, even right after a reload, and keep them as you move; a node not
  measured yet gets an icon near its dot until it is. Blizzard's dot still shows near the minimap's
  edge and where nodes of one name pile up (three or more, or two almost on top of each other).
- **Move the compass** (#57): hold Alt over it and drag it where you like, as with Apotheca's bar.
  Without Alt, clicks still go through it to the world. Lock it in Options or with
  `/nr compass lock`; `/nr compass reset` puts it back under your character.

## v1.2.0

Released 2026-10-19.

- **Choose which herbs and ores** (#47): NodeRadar's new Herbs and Ores pages (under it in Esc >
  Options > AddOns) list each herb and ore with its nodes and the skill each needs. Uncheck one and
  it makes no alert or chat line, and the compass never points at it; on the minimap its icon is
  dimmed, or Blizzard's dot if you prefer. All, None, All I can gather and Skill-ups only set a page
  at once. `/nr ignore`, `/nr track`.
- **Smart** (on by default): the lists follow your skill, checking a node when you can gather it
  and unchecking it once it's grey (no more skill-ups). On your first login with this version it
  keeps only what gives skill-ups, so a 300 herbalist no longer hears Peacebloom. Turn it off on
  either page or with `/nr smart`. The choices are per character.
- **A yellow frame for the icons** (#50): a ring the colour of the minimap's own tracking dots,
  beside glass and bronze (`/nr iconstyle yellow`, or Options). The compass's rim follows it.
- **Experimental: a compass toward the nearest node** (#29), off by default (`/nr compass`, or
  Options): under your character, the nearest node you can gather as its item's icon on a small
  dark lens with a thin pearl or bronze rim (as the minimap icons' frame), a white arrow circling it
  toward the node with a highlight on the rim beneath, the distance below, the item's tooltip on
  hover. Small, medium or large. It moves on as you gather and hides within 15
  yards. It follows your character's facing, not the camera's.
- **Nodes of one name a little apart now get their icons** (#28's measuring): two Silverleafs about
  50 yards apart stayed Blizzard's dots, and the compass, which only knows measured nodes, never
  pointed at them. Each is now measured on its own.
- **The compass moves on at once after a gather** (#29): it showed the next node, then hid for a
  few seconds while the loot window was open, taking the herb still on the minimap for the nearest.
  That herb is now left alone until it vanishes.

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
