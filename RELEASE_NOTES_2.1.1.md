# HS Reconnect 2.1.1

- Fixed Reconnect turning off with "Reconnect status couldn't be checked",
  even after relaunching the app or the game. A slow or missing answer from
  macOS no longer turns Reconnect off on its own, and while Reconnect's
  network connection is running, Reconnect stays available.
- The app now checks the Reconnect extension's status less often, which puts
  less load on macOS.
- If the status check keeps failing, the app suggests restarting your Mac and
  sends one anonymous event saying whether macOS timed out or returned an error
  code. It includes nothing about you, your games, or your network traffic.
- Bug reports now need an email address, so every report can get a reply.

Requires macOS 13 or later and the native macOS version of Hearthstone. Supports
Apple silicon and Intel Macs. Version 2.0.0 and later can install this update
from the app. For earlier versions, run the new installer over the old app. The
app is unofficial and is not affiliated with Blizzard Entertainment.
