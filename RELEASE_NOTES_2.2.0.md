# HS Reconnect 2.2.0

- New: Keep HSTracker working. HSTracker stops tracking a Battlegrounds match
  when Hearthstone reconnects: its panels disappear and Bob's Buddy stops. With
  the new switch on, HSTracker picks the match back up within a second or two of
  each reconnect. The switch is in the Reconnect card and is off by default.
- How it works: right after a reconnect, the app adds one line to Hearthstone's
  loading log on your Mac. HSTracker reads that log and starts tracking again.
  The app first checks HSTracker's own log on your Mac; if HSTracker has already
  recovered by itself, the app adds nothing.
- What it can't do: opponent boards HSTracker saved before a reconnect stay
  lost, and HSTracker's match timer restarts.
- The app does this only while the switch is on and HSTracker is running.
  Nothing from either log is stored by the app or leaves your Mac.
- A What's New card explains the option once, in the app window when Reconnect
  is ready.
- Fixed: lobby info and the Reconnect button could stay hidden for a whole
  session when Hearthstone was opened while HS Reconnect was already running.
  The app now waits until Hearthstone has signed in before it reads the game.
- Fixed: Open with Hearthstone could stop working while Settings still showed
  it as on. The app now checks that its helper is really running and sets it up
  again if it isn't.

Requires macOS 13 or later and the native macOS version of Hearthstone. Supports
Apple silicon and Intel Macs. Version 2.0.0 and later can install this update
from the app. For earlier versions, run the new installer over the old app. The
app is unofficial and is not affiliated with Blizzard Entertainment.
