# Security notes

HS Reconnect uses Hardened Runtime and Developer ID signing for the host app,
Network Extension, watcher, lobby helper, frameworks, and native libraries.

The lobby helper alone has `com.apple.security.cs.debugger` so it can request
task access to the running native Hearthstone process. It also has
`com.apple.security.cs.disable-library-validation` because HearthMirror loads
its bundled CoreCLR runtime. These entitlements are not present on the host app,
watcher, or Network Extension. The helper runs as the signed-in user, accepts no
incoming network connections, installs no privileged service, and exits with
the app.

The app requests public leaderboard pages directly from Blizzard. Captured
lobby names and account identifiers are not included in those requests.

Please report security issues privately to `hsreconnect@gmail.com`.
