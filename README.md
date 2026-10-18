# NodeRadar

A gathering-node alert for **World of Warcraft: Forever**: with Find Herbs or Find Minerals on, a
ping and a sonar on the minimap the moment a herb or ore node comes into range: two rings ripple
out from the node and a glow stays on it, green for herbs, gold for ore.

## How it works

- **It reads the minimap's blips.** About every 2 yards you move (every 2 s standing still) it
  samples the minimap through the client's own mouseover (the same data its tooltip shows), so it
  sees what you'd see by hovering every blip. Each look takes about 4 ms. It works under any minimap
  skin, and your own hover tooltip isn't affected.
- **It learns which names are nodes.** The minimap also shows quests, group members and town
  NPCs. NodeRadar knows a node by its name, learned once and remembered for your whole account:
  - when you **gather** a node, it learns that node's name;
  - optionally (`/nr learn`, off by default): when it sees a name it doesn't know, and you're
    standing still out of combat, it turns your gathering tracking off for a moment and back on, and
    sees what disappeared, since a herb is what vanishes when Find Herbs is off. Turning tracking
    back on costs a global cooldown, which is why it's off by default. If anything stops it from
    turning tracking back on, it says so in chat.
- **It ships with names already learned**, so most common nodes are known from the start. Names
  are your client's own, so it works in any language; other languages learn as they go.

**Limits:** names are what it goes by. A quest or NPC with exactly a node's name would be taken for
one. A node leaving the map's edge in the same half second another of its name comes in may not
alert.

## Commands

- `/nr`: radar on or off
- `/nr sound`, `/nr ring`, `/nr chat`: the ping sound, the sonar on the node, a chat line
- `/nr ping`: Blizzard's minimap ping on the node too, solo only (in a group it would show on
  everyone's minimap)
- `/nr learn`: learning by turning tracking off and on (off by default: it costs a global cooldown)
- `/nr cd <1-60>`: seconds between alerts
- `/nr test`, `/nr status`, `/nr known`, `/nr forget <name>`, `/nr failures`, `/nr reset`

## License

MIT
