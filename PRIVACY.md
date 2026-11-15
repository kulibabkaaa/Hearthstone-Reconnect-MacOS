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

While the Reconnect button is on and Hearthstone runs, the app checks about once
a second whether a Battlegrounds match is in progress, so it can show the button.
For this it reads only the newest lines of Hearthstone's own log files on this
Mac and the list of addresses Hearthstone is connected to (what `lsof` shows,
never any traffic). While it checks, it keeps in memory only whether a match is
in progress and the game server addresses Hearthstone's logs named. The
addresses are never saved to disk or sent anywhere. Whether a match is in
progress, with the check's state and counts, is written to the app's local
diagnostics log described under bug reports below, never with addresses. This
needs no permission and doesn't read Hearthstone's memory. If the connections
can't be read, the button shows whenever Hearthstone is in front. Turning off
the Reconnect button stops this checking.

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
- the region code Hearthstone logs at login (for example `EU`; any code it
  doesn't know is sent as `other`), and nothing else from that line. When the
  newest log has no login yet, it is taken from the newest older folder that
  has one, and the file names that folder (a date);
- the Battle.net region host name, when Hearthstone's Battle.net log names one
  (for example `eu.actual.battle.net`), and nothing else from that log. When
  the newest log folder has no Battle.net log, it is taken from the newest
  older folder that has one, and the file names that folder (a date);
- from Hearthstone's `GameNetLogger.log` and `Hearthstone.log`, only the lines
  about connecting to and disconnecting from a game server and about looking
  for a game (at most the newest 150 of each). They include the game server's
  address. Game, client, and spectator keys in those lines are removed;
- HS Reconnect's own log messages about choosing the reconnect target and how
  each reconnect press ended (for example "reconnected", "no game found", or
  "refused during the cooldown", with which control was used; no addresses),
  whether reconnect setup failed (an error code only),
  whether a match is in progress for the Reconnect button (states and counts
  only, no addresses), Keep HSTracker working, the Open with Hearthstone
  helper, and analytics setup,
  from at most the last three days (newest 200).

So these messages survive a restart of the app or the Mac, HS Reconnect also
writes them to a small log file on this Mac, in `~/Library/Logs/HS Reconnect/`
(two files of at most 256 KB each; lines older than three days are deleted
when the app starts and are never read).
Only those message types are written there, and they are cleaned the same way
before they are saved. The file never leaves the Mac on its own: it is read only
to build the diagnostic file above, and only when the switch is on. Uninstalling
HS Reconnect from the app removes it.

Before attaching, the app also removes anything in those lines that looks like
a BattleTag, email address, Blizzard account ID, or the Mac's user folder name.
It never attaches other Hearthstone logs (such as `Power.log`, `Zone.log`, or
`LoadingScreen.log`), lobby or opponent names, HSTracker's log, or other files.
With the switch off, no logs are included.

Reports, images, and diagnostic files are processed and stored by Forminit so
an email notification can be delivered to the project maintainer. If Forminit
answers a report that has the diagnostic file with any HTTP 4xx error other
than a timeout (408) or rate limit (429), whatever the reason, the app sends the
same report once more without the file, with a note that the file was left out.
Server errors (5xx), timeouts, and rate limits are not retried this way. Forminit also receives ordinary connection metadata,
including the public IP address and user agent used for the submission.
