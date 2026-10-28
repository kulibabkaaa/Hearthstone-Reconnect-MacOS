# Privacy

HS Reconnect uses TelemetryDeck to measure active installations and whether the
reconnect and lobby-info features are used. This analytics collection is always
on. It sends app-session, successful-reconnect, and lobby-overlay-displayed
events together with a randomly generated installation identifier that is
hashed before transmission. TelemetryDeck also receives standard technical
details supplied by its macOS SDK, such as the app version, macOS version,
device model and architecture, display size, language, region, and time zone.
The successful-reconnect event also records which control started the
reconnect: the shortcut, the Reconnect button, the main window, or the menu bar
menu.

Analytics never includes player names, BattleTags, MMR, lobby identifiers,
Blizzard account details, game traffic, logs, file paths, or captured game
data. HS Reconnect has no advertising, remote crash reporting, accounts, or
project-operated analytics server. TelemetryDeck receives ordinary connection
metadata, including the public IP address, when events are submitted.

To identify the current Battlegrounds connection and lobby, the app reads
Hearthstone's local game state. Captured player names and identifiers stay on
this Mac. The last complete lobby roster is stored locally for up to three
hours so it can be restored if Hearthstone restarts during that match.

When lobby info is off but the Reconnect button is on, the app still reads
Hearthstone's local game state while Hearthstone runs, in the same way as lobby
info, to tell whether a Battlegrounds match is in progress so it can show the
button. The app uses only whether a match is in progress and discards the rest
of the captured lobby: it shows no lobby overlay, requests no ratings, stores no
lobby roster, and sends no lobby analytics. It reads the game only when macOS
already allows it without a new prompt; otherwise the button shows whenever
Hearthstone is in front. Turning off the Reconnect button stops this reading.

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
