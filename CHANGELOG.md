# Changelog

## 1.0.4-beta — 2026-10-27
- New: ingredient reserve. A station stops refilling when that would leave fewer than
  `Reserve` (default 10) of an ingredient in the nearby chests, so you keep some on hand for
  building and crafting. It resumes by itself when the chests are restocked.
  Per-item values with `ReserveByItem`; `Reserve = 0` uses everything (old behaviour).
- AutoStation now learns each recipe's ingredients from what leaves the chests too (not only the
  backpack), so the reserve works from the very first refills.
- The log says when and why a station pauses and resumes.

## 1.0.3-beta — 2026-10-24
- Finished items now go STRAIGHT into the chest (never through the backpack): the item is created
  in the chest, checked, and only then removed from the station; any mismatch is undone and the
  item stays in the station (retry after 60 s).
- Finished items are stored even while a station is waiting for ingredients.
- Built-in profiling: slow ticks (> 8 ms) and a 5-minute summary are written to the log.
- First 3 stores per session are audited in the log (inventory totals before/after).

## 1.0.2-beta — 2026-10-24
- Fix: stations stopped after one refill when you carried the ingredient. The game spends
  backpack items before chest items; AutoStation now gives the same amount back to your backpack
  from a nearby chest, so the chest pays and your backpack is unchanged.
- Learns how much each recipe uses and waits (instead of refilling) when nearby chests no longer
  hold a full batch.

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
