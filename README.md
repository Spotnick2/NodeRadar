# NodeRadar

A gathering-node alert for **World of Warcraft: Forever**: while you ride with Find Herbs or Find
Minerals on, a ping and a flash on the minimap the moment a node comes into range.

**Status: being rebuilt for Forever.** The first version was written for TBC Anniversary and
never worked: it looked for the minimap's blips in a place the game doesn't put them. Forever's
client has a way to read them; whether it works from an addon is being measured
([#2](https://github.com/Spotnick2/NodeRadar/issues/2)), and the port follows
([#3](https://github.com/Spotnick2/NodeRadar/issues/3)).

## Commands (v1; they'll carry over)

- `/nr`: on or off
- `/nr sound`, `/nr ping`, `/nr chat`, `/nr mount`: toggle the sound, the minimap ring, a chat line,
  and mounted-only
- `/nr cd <1-60>`: seconds between alerts
- `/nr test`, `/nr status`, `/nr reset`

## License

MIT
