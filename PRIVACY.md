# Privacy

HS Reconnect uses TelemetryDeck to measure active installations and whether the
reconnect and lobby-info features are used. This analytics collection is always
on. It sends app-session, successful-reconnect, lobby-overlay-displayed, and
extension-check-failed events together with a randomly generated installation
identifier that is hashed before transmission. TelemetryDeck also receives standard technical
details supplied by its macOS SDK, such as the app version, macOS version,
device model and architecture, display size, language, region, and time zone.
The successful-reconnect event also records which control started the
reconnect: the shortcut, the Reconnect button, the main window, or the menu bar
menu. If macOS repeatedly fails to report whether the network extension is on,
the extension-check-failed event is sent once for that run of failures. It
records only whether the check timed out or failed, and for a failure the
general error source and Apple's numeric error code.

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

When Keep HSTracker working is on and HSTracker is running, the app reads the
newest part of HSTracker's log file and of Hearthstone's loading log on this
Mac for a few seconds after each reconnect, and adds one line to Hearthstone's
loading log so that HSTracker resumes tracking the match. Nothing from either
log is stored by the app or sent anywhere. The option is off by default, and
turning it off stops this.

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
report contains the typed description, app version, macOS version, a required
reply email address, and up to five optional images chosen, dragged, or pasted
by the user.

The bug report form also has an **Include diagnostic logs** switch. It is on
each time the form opens, the user can turn it off for that report, and **Show
What's Included** displays the exact text that will be attached before anything
is sent. When it is on, the report carries one small text file (at most about
200 KB) with:

- the app version and build, Mac architecture, macOS version, whether the
  network extension and proxy are on, whether Keep HSTracker working is on,
  whether Hearthstone is running, and the name of Hearthstone's newest log
  folder (a date);
- the Battle.net region host name only (for example `eu.actual.battle.net`),
  and nothing else from Hearthstone's Battle.net log;
- from Hearthstone's `GameNetLogger.log` and `Hearthstone.log`, only the lines
  about connecting to and disconnecting from a game server and about looking
  for a game (at most the newest 150 of each). They include the game server's
  address. Game, client, and spectator keys in those lines are removed;
- HS Reconnect's own log messages about choosing the reconnect target, Keep
  HSTracker working, the Open with Hearthstone helper, and analytics setup,
  from the current run of the app and at most the last three hours.

Before attaching, the app also removes anything in those lines that looks like
a BattleTag, email address, Blizzard account ID, or the Mac's user folder name.
It never attaches other Hearthstone logs (such as `Power.log`, `Zone.log`, or
`LoadingScreen.log`), lobby or opponent names, HSTracker's log, or other files.
With the switch off, no logs are included.

Reports, images, and diagnostic files are processed and stored by Forminit so
an email notification can be delivered to the project maintainer. If Forminit
refuses a report that has the diagnostic file because of what the request
contains (an HTTP 4xx answer other than a timeout or rate limit), the app sends
the same report once more without the file, with a note that the file was left
out. Server errors and rate limits are not retried this way. Forminit also receives ordinary connection metadata,
including the public IP address and user agent used for the submission.
