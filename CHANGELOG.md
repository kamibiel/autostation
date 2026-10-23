# Changelog

## 1.0.1-beta — 2026-10-23
- Fix: crash/stutter risk — no more delayed callbacks; finished items move to the chest on the
  next tick instead.
- Fix: stations were wrongly stopped ("used backpack") while a finished item was in transit.
- Stations without ingredients now rest for 30 s instead of retrying every tick.
- Round-robin: at most 3 stations handled per tick. Verbose log off by default.

## 1.0.0-beta — 2026-10-23
- First beta: tracks stations from the player's own queued recipe, tops the queue up from nearby
  chests (game's native crafting), stores finished items in a nearby chest that already holds them.
- Stops a station if a refill would use the backpack, or when the player cancels a queued item.
- `Ctrl+F5` toggle nearest station, `Ctrl+F11` list tracked stations.
