# HS Reconnect 2.1.0

- Reconnect with one click. A Reconnect button now floats near the top right of
  the Battlegrounds board during Solo and Duos matches. It works like the
  shortcut and leaves the keyboard with the game. It shows Reconnecting…,
  Reconnected, or a short countdown. The button is on by default; turn it off
  under Overlays in the app.
- Layout mode (Command-Shift-L) now moves and resizes both the lobby overlay
  and the Reconnect button. Enter saves, Esc cancels. Reset Layout and Opacity
  apply to both.
- The new Overlays card in the app holds the Lobby info and Reconnect button
  switches, the position shortcut, opacity, and Reset Layout.
- A reconnect that gets no answer now stops after 12 seconds and offers Try
  again.
- With Lobby info off and the button on, the app still reads Hearthstone's game
  state on this Mac to tell whether you are in a match. It uses nothing else,
  shows no lobby overlay, downloads no ratings, and asks for no new permissions.
  Turn off the Reconnect button to stop this.
- While the app is still connecting to the game, the button stays hidden. If it
  can't read the game at all, for example because lobby access isn't allowed,
  the button shows whenever Hearthstone is in front.
- A short What's New card introduces the button once, in the app window when
  Reconnect is ready. It never appears over the game.
- Successful reconnects now record which control started them: the shortcut,
  the button, the app window, or the menu bar menu. No other analytics change.

Requires macOS 13 or later and the native macOS version of Hearthstone. Supports
Apple silicon and Intel Macs. Version 2.0.0 and later can install this update
from the app. For earlier versions, run the new installer over the old app. The
app is unofficial and is not affiliated with Blizzard Entertainment.
