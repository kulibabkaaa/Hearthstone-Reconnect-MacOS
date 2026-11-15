# HS Reconnect 2.2.1

- Lobby info now runs on HS Reconnect's own code. The app reads player names
  and ratings from Hearthstone on your Mac with its own read-only reader, which
  never changes the game.
- The Reconnect button now tells that you're in a Battlegrounds match from
  Hearthstone's log files and its open connections on your Mac. It no longer
  reads the game's memory and needs no permission. With lobby info off, the app
  doesn't read Hearthstone's memory at all.
- Lobby info and the Reconnect button now share one rule for telling a
  Battlegrounds game, so a new Battlegrounds mode from a Hearthstone update
  should still count.
- Fixed: Reconnect could say "No game found" when Hearthstone hadn't logged the
  new match. The app now checks which game Hearthstone is actually connected to.
- Fixed: the lobby overlay could blink off and on during a reconnect in a match.
- Lower CPU use: with Hearthstone in the menus, the app now uses less than half
  the CPU it used before.
- Bug reports can now include diagnostic logs, so you don't have to send log
  files separately. The switch is on each time the form opens, and you can turn
  it off. **Show What's Included…** shows the exact text before you send.
  BattleTags, email addresses and account IDs are removed first. The app keeps
  the last three days of these log lines on your Mac, so they survive a restart.
- Bug reports now show the right Battle.net region, and a spinner while
  sending.

Requires macOS 13 or later and the native macOS version of Hearthstone. Supports
Apple silicon and Intel Macs. Version 2.0.0 and later can install this update
from the app. For earlier versions, run the new installer over the old app. The
app is unofficial and is not affiliated with Blizzard Entertainment.
