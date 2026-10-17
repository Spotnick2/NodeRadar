# NodeRadar

A gathering-node alert for **World of Warcraft: Forever**: with Find Herbs or Find Minerals on, a
ping and a ring on the minimap the moment a herb or ore node comes into range.

## How it works

- **It reads the minimap's blips.** Twice a second it samples the minimap through the client's own
  mouseover (the same data its tooltip shows), so it sees what you'd see by hovering every blip.
  That takes about 4 ms. It works under any minimap skin, and your own hover tooltip isn't affected.
- **It learns which names are nodes.** The minimap also shows quests, group members and town
  NPCs. NodeRadar tells nodes apart the way you would: a herb is something that disappears when
  Find Herbs is off. It learns each name once and remembers it for your whole account:
  - when you **gather** a node, it learns that node's name;
  - when it sees a name it doesn't know, and you're standing still out of combat, it turns your
    gathering tracking off for a moment and back on, and sees what disappeared. If anything stops it
    from turning it back on, it says so in chat. `/nr learn` turns this off if you'd rather learn by
    gathering only.
- **It ships with names already learned**, so most common nodes are known from the start. Names
  are your client's own, so it works in any language; other languages learn as they go.

**Limits:** names are what it goes by. A quest or NPC with exactly a node's name would be taken for
one. A node leaving the map's edge in the same half second another of its name comes in may not
alert.

## Commands

- `/nr`: radar on or off
- `/nr sound`, `/nr ring`, `/nr chat`: the ping sound, the ring on the node, a chat line
- `/nr ping`: Blizzard's minimap ping on the node too, solo only (in a group it would show on
  everyone's minimap)
- `/nr learn`: learning by turning tracking off and on
- `/nr cd <1-60>`: seconds between alerts
- `/nr test`, `/nr status`, `/nr known`, `/nr forget <name>`, `/nr failures`, `/nr reset`

## License

MIT
