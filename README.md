<p align="center">
  <img src="Support/AppIconSource.png" width="136" alt="HS Reconnect app icon">
</p>

<h1 align="center">HS Reconnect for Mac</h1>

<p align="center">
  Source code, releases, and issue tracking for <strong>HS Reconnect</strong>.
</p>

<p align="center">
  <a href="https://github.com/kulibabkaaa/hearthstone-reconnect-macos/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/kulibabkaaa/hearthstone-reconnect-macos?style=flat-square"></a>
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Mac-Apple%20silicon%20%2B%20Intel-111111?style=flat-square">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square"></a>
</p>

<h3 align="center">
  <a href="https://github.com/kulibabkaaa/hearthstone-reconnect-macos/releases/latest/download/HS-Reconnect-2.0.0.dmg">Download HS Reconnect 2.0.0</a>
  ·
  <a href="PRIVACY.md">Privacy and permissions</a>
</h3>

<p align="center">
  Free, open source, signed with Apple Developer ID, and notarized by Apple.
</p>

<p align="center">
  <img src="Documentation/Images/hs-reconnect-window.png" width="760" alt="HS Reconnect window showing reconnect and Lobby info controls">
</p>

## What it does

HS Reconnect is a native Hearthstone reconnect tool for Mac. Press one global
shortcut to reconnect your current Hearthstone Battlegrounds game without
closing and reopening the game. The default is **Command-Shift-W**, and you can
change it inside the app.

HS Reconnect can open quietly with Hearthstone, stay available in the menu bar,
and show or hide its Dock icon whenever you choose.

For Solo Battlegrounds, it also shows a local overlay with the eight player
names, public leaderboard ranks and ratings, and the estimated lobby average.
Use **Command-Shift-L** to move and proportionally resize the overlay. Its
opacity is adjustable from 10% to 100%.

## Requirements

- macOS 13 or later
- Apple silicon or Intel Mac
- The native macOS version of Hearthstone

## Install

1. [Download HS Reconnect 2.0.0](https://github.com/kulibabkaaa/hearthstone-reconnect-macos/releases/latest/download/HS-Reconnect-2.0.0.dmg).
2. Open the disk image, then open **Install HS Reconnect.pkg**.
3. Complete the installer and open HS Reconnect from Applications or its
   Desktop shortcut.
4. In HS Reconnect, choose **Set Up Reconnect**. macOS may show its own extension
   approval alert. The app then opens Network Extension Settings when approval
   is needed. Turn on HS Reconnect there, then approve the proxy configuration
   when macOS asks.
5. For optional lobby info, open native Hearthstone. Approve the macOS
   authentication requests when the app attaches to the game.

If you cancel an approval, the app shows the missing step and a button to retry.

The lobby reader runs only on this Mac. Quit HSTracker while using HS
Reconnect's lobby overlay; both apps cannot attach to Hearthstone at the same
time.

Leave **Open HS Reconnect with Hearthstone** checked to start the app quietly
with the game. The menu bar and Dock icons are visible by default; turn off
**Show HS Reconnect in Dock** if you prefer menu-bar-only operation.

## Update

HS Reconnect checks for signed updates automatically. Turn
**Automatically check for updates** off if you prefer manual checks. The
**Check for Updates…** button always remains available.

When automatic updating is enabled, a downloaded update installs and relaunches
HS Reconnect automatically. Manual checks still show the update details before
installation. Updates preserve shortcuts, overlay layout, and startup
preferences. The first installer may request an administrator password; later
in-app updates do not.

## How it works

HS Reconnect uses a local macOS Network Extension that passes native
Hearthstone game traffic through unchanged. When you reconnect, it closes only
the current Hearthstone game connection so the game reconnects immediately.

No root helper or sudo rule is installed. No HS Reconnect account or separate
online service is required.

Lobby names are read from the running game by a narrowly scoped helper. That
helper asks macOS for administrator approval when it attaches. Public rating
pages are then requested directly from Blizzard and cached locally.

## Uninstall

1. Open HS Reconnect and select the red **Uninstall** button.
2. Confirm removal and enter your Mac administrator password.

The uninstaller removes HS Reconnect, its Network Extension, local settings,
Desktop shortcut, and installer receipt.

## Privacy

HS Reconnect uses always-on, privacy-focused TelemetryDeck analytics to count
active installations and successful reconnect/lobby-info use. It never sends
player names, BattleTags, MMR, lobby data, game traffic, or logs. Captured lobby
data stays on the Mac. Public leaderboard requests go directly to Blizzard,
which receives ordinary connection metadata such as the public IP address.
Read the full [privacy statement](PRIVACY.md).

GitHub records the cumulative `download_count` for the signed DMG attached to
each release. This measures release-asset downloads. Active installations are
measured separately through TelemetryDeck using its random hashed installation
identifier.

## FAQ

### Is there a Hearthstone reconnect tool for Mac?

Yes. HS Reconnect is built specifically for the native macOS version of
Hearthstone. It supports Apple silicon and Intel Macs running macOS 13 or later.

### How do I reconnect Hearthstone Battlegrounds on macOS?

Keep HS Reconnect open while playing, then press **Command-Shift-W** during a
match. The app closes the current Hearthstone game connection so Hearthstone
can reconnect immediately. You can change the shortcut in the app.

### Does it support Apple silicon and Intel Macs?

Yes. The signed installer supports both Apple silicon and Intel Macs.

### Why does macOS ask for Network Extension permission?

The one-time approval lets HS Reconnect handle the native Hearthstone game
connection locally and close it when you request a reconnect.

### Does it work with Windows or CrossOver?

No. Version 2.0.0 supports only the native macOS version of Hearthstone.

### Do I need to uninstall the old version before updating?

No. Run the new installer over the existing version. Your saved shortcut and
startup preferences remain in place.

### Does it inspect or save my game traffic?

No. The Network Extension passes Hearthstone traffic through unchanged and
does not inspect or store its contents.

### Why does lobby info ask for an administrator password?

The local lobby helper needs macOS permission to read the running Hearthstone
process. It requests approval when you open Hearthstone. It does not install a
root service. If you cancel, select **Retry Lobby Setup** in the app to try again.

### Can I use the lobby overlay with HSTracker?

No. Quit HSTracker before using this overlay because only one tracker can attach
to Hearthstone reliably at a time. Reconnect remains available.

## Build from source

The project requires Xcode 16 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test
Scripts/build-local.sh
```

Public builds require Developer ID Application and Developer ID Installer
certificates, Network Extension provisioning, and Apple notarization.
See [SECURITY.md](SECURITY.md) for the lobby helper's scoped entitlements and
[Vendor/HearthMirror/NOTICE.md](Vendor/HearthMirror/NOTICE.md) for vendored
runtime provenance.

## Bug reports and support

Select **Report a Bug…** in the app to send a description, an optional reply
email, and up to five optional images. Images can be selected, dragged into
the form, or pasted from the clipboard. The app adds its version and the
macOS version. It does not attach logs, lobby names, or account data
automatically.

Found a problem? [Open an issue](https://github.com/kulibabkaaa/hearthstone-reconnect-macos/issues)
or email `hsreconnect@gmail.com`.

## Disclaimer

HS Reconnect is unofficial and is not affiliated with, endorsed by, or
sponsored by Blizzard Entertainment. Use it at your own risk. Game behavior
and policies may change.

HS Reconnect is free software released under the [MIT License](LICENSE).
