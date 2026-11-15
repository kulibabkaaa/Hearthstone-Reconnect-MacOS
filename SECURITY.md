# Security notes

HS Reconnect uses Hardened Runtime and Developer ID signing for the host app,
Network Extension, watcher, lobby helper, frameworks, and native libraries.

The lobby helper reads a few values from the running Hearthstone's memory with
HS Reconnect's own reader (`Shared/MonoReader`): your BattleTag and account id,
the selected Battlegrounds mode, your Battlegrounds ratings, the game type, and,
during a Battlegrounds match, the match id and each player's name, account id and
hero. It only reads: it never writes to the game's memory or changes how the game
runs. It attaches only to a Hearthstone signed by Blizzard.

Reading another app's memory needs a task port from macOS. Under Hardened Runtime
that takes the `com.apple.security.cs.debugger` entitlement, which the lobby helper
alone has (not the host app, watcher, or Network Extension), and macOS's
"Developer Tools access" right, which is why macOS asks for your password the
first time. The helper runs as the signed-in user, accepts no incoming network
connections, installs no privileged service, sends what it reads only to the
HS Reconnect app, and exits with the app.

The app requests public leaderboard pages directly from Blizzard. Captured
lobby names and account identifiers are not included in those requests.

Please report security issues privately to `hsreconnect@gmail.com`.
