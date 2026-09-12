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
  <a href="https://github.com/kulibabkaaa/hearthstone-reconnect-macos/releases/latest/download/HS-Reconnect-1.1.0.dmg">Download HS Reconnect 1.1.0</a>
  ·
  <a href="https://kulibabkaaa.github.io/Hearthstone-Reconnect-MacOS/">HS Reconnect for Mac — website and install guide</a>
</h3>

<p align="center">
  Free, open source, signed with Apple Developer ID, and notarized by Apple.
</p>

<p align="center">
  <img src="Documentation/Images/hs-reconnect-window.png" width="760" alt="HS Reconnect window showing the global shortcut, launch options, reconnect button, and uninstall button">
</p>

## What it does

HS Reconnect is a native Hearthstone reconnect tool for Mac. Press one global
shortcut to reconnect your current Hearthstone Battlegrounds game without
closing and reopening the game. The default is **Command-Shift-W**, and you can
change it inside the app.

HS Reconnect can open quietly with Hearthstone, stay available in the menu bar,
and show or hide its Dock icon whenever you choose.

## Requirements

- macOS 13 or later
- Apple silicon or Intel Mac
- The native macOS version of Hearthstone

## Install

1. [Download HS Reconnect 1.1.0](https://github.com/kulibabkaaa/hearthstone-reconnect-macos/releases/latest/download/HS-Reconnect-1.1.0.dmg).
2. Open the disk image, then open **Install HS Reconnect.pkg**.
3. Complete the installer and open HS Reconnect from Applications or its
   Desktop shortcut.
4. Approve the Network Extension and network configuration when macOS asks.

If you dismiss the first approval message, reopen HS Reconnect and select
**Open System Settings** beside the setup message. The app keeps that guidance
available until setup is complete.

Leave **Open HS Reconnect with Hearthstone** checked to start the app quietly
with the game. The menu bar and Dock icons are visible by default; turn off
**Show HS Reconnect in Dock** if you prefer menu-bar-only operation.

## Update

If HS Reconnect is already installed, do not uninstall it first. Download the
new disk image and run **Install HS Reconnect.pkg** over the existing version.
The installer closes the old app, replaces it in Applications, refreshes the
Desktop shortcut, and keeps your shortcut and startup preferences.

Reopen HS Reconnect after the installer finishes. macOS normally replaces the
existing Network Extension automatically. Approve it or restart your Mac only
if macOS asks. Use the built-in uninstaller only as a troubleshooting fallback,
because uninstalling removes your saved settings.

## How it works

HS Reconnect uses a local macOS Network Extension that passes native
Hearthstone game traffic through unchanged. When you reconnect, it closes only
the current Hearthstone game connection so the game reconnects immediately.

No root helper or sudo rule is installed. No HS Reconnect account or separate
online service is required.

## Uninstall

1. Open HS Reconnect and select the red **Uninstall** button.
2. Confirm removal and enter your Mac administrator password.

The uninstaller removes HS Reconnect, its Network Extension, local settings,
Desktop shortcut, and installer receipt.

## Privacy

HS Reconnect has no analytics, telemetry, advertising, remote crash reporting,
accounts, or project-server connection. It does not collect or transmit personal
data. Read the full [privacy statement](PRIVACY.md).

GitHub records the cumulative `download_count` for the signed DMG attached to
each release. This measures release-asset downloads, not installations or active
users. GitHub maintains this count; the app contains no download tracking.

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

No. Version 1.1.0 supports only the native macOS version of Hearthstone.

### Do I need to uninstall the old version before updating?

No. Run the new installer over the existing version. Your saved shortcut and
startup preferences remain in place.

### Does it inspect or save my game traffic?

No. The Network Extension passes Hearthstone traffic through unchanged and
does not inspect or store its contents.

## Build from source

The project requires Xcode 16 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
swift test
Scripts/build-local.sh
```

Public builds require Developer ID Application and Developer ID Installer
certificates, Network Extension provisioning, and Apple notarization.

## Support

Found a problem? [Open an issue](https://github.com/kulibabkaaa/hearthstone-reconnect-macos/issues)
or email `hsreconnect@gmail.com`.

## Disclaimer

HS Reconnect is unofficial and is not affiliated with, endorsed by, or
sponsored by Blizzard Entertainment. Use it at your own risk. Game behavior
and policies may change.

HS Reconnect is free software released under the [MIT License](LICENSE).
