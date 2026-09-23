# Privacy

HS Reconnect uses TelemetryDeck to measure active installations and whether the
reconnect and lobby-info features are used. This analytics collection is always
on. It sends app-session, successful-reconnect, and lobby-overlay-displayed
events together with a randomly generated installation identifier that is
hashed before transmission. TelemetryDeck also receives standard technical
details supplied by its macOS SDK, such as the app version, macOS version,
device model and architecture, display size, language, region, and time zone.

Analytics never includes player names, BattleTags, MMR, lobby identifiers,
Blizzard account details, game traffic, logs, file paths, or captured game
data. HS Reconnect has no advertising, remote crash reporting, accounts, or
project-operated analytics server. TelemetryDeck receives ordinary connection
metadata, including the public IP address, when events are submitted.

To identify the current Battlegrounds connection and lobby, the app reads
Hearthstone's local game state. Captured player names and identifiers stay on
this Mac. The last complete lobby roster is stored locally for up to three
hours so it can be restored if Hearthstone restarts during that match.

To show public ratings, the app requests the selected region's public
Battlegrounds leaderboard directly from Blizzard and keeps a short-lived local
cache. HS Reconnect does not add player names or captured identifiers to this
request. Like any direct internet request, it exposes ordinary connection
metadata, including the Mac's public IP address, to Blizzard.

The Network Extension passes native Hearthstone game traffic through unchanged
and does not inspect or store the traffic contents. App preferences remain on
the Mac in the standard macOS preferences store.

GitHub provides the public cumulative download count for the release DMG. That
count is maintained by GitHub and does not add tracking code to HS Reconnect.

Automatic and manual update checks request the public update feed from GitHub
Pages. Downloading an update uses GitHub Releases. GitHub receives ordinary
connection metadata such as the public IP address.

Bug reports are optional and sent only when the user selects **Submit**. The
report contains the typed description, app version, macOS version, an optional
reply email address, and up to five optional images chosen, dragged, or pasted
by the user. It does not automatically include logs, lobby names, Blizzard
account details, or other files. Reports and images are processed and stored
by Forminit so an email notification can be delivered to the project
maintainer. Forminit also
receives ordinary connection metadata, including the public IP address and
user agent used for the submission.
