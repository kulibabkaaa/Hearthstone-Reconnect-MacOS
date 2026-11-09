# HSTracker reconnect recovery

## Failure and evidence

HSTracker 3.7.3 repeatedly logs `Game.reset`, `Game.handleGameReconnect`, a
`gameplay` to `gameplay` transition, and heroes waiting for `playerEntity` after
a reconnect. Match overlays and combat simulation results then disappear.

Public source mirrors of
[3.6.13](https://github.com/ffkiyo7/HSTracker/blob/41f89c04f2b1bda13f60e08822a6fb2e1602f561/HSTracker/Logging/Handlers/LoadingScreenHandler.swift)
and [3.7.1](https://github.com/Archer222arc/HSTracker/blob/782c881c26e0ee7e105bfa130562c2f36950bf80/HSTracker/Logging/Handlers/LoadingScreenHandler.swift)
explain that sequence: `Gameplay.Start` clears player identities, but the
`gameStart` initializer only runs when the previous scene differs from
`GAMEPLAY`. The exact source for the installed 3.7.3 binary was unavailable;
these mirrors support the diagnosis, rather than prove binary compatibility.

## Compatibility workaround

HS Reconnect captures the current log offsets before requesting a reconnect.
Recovery starts only when the extension confirms the selected flow closed and
the running tracker reports version 3.7.3. It waits for new `Gameplay.Start`,
`IsPastBeginPhase()=True`, and a `GAMEPLAY` to `GAMEPLAY` scene-loaded event.
Menu transitions, new matches, superseding reloads, app termination, uninstall,
and subsequent reconnect attempts cancel recovery.

After at least 5.5 seconds, to avoid HSTracker's five-second gameStart guard,
it appends one clearly labelled synthetic event to `LoadingScreen.log`:

```text
D HH:mm:ss.SSSSSSS LoadingScreen.OnSceneLoaded() - prevMode=INVALID currMode=GAMEPLAY source=HSReconnect.HSTrackerRecovery
```

The prefix passes the tracker log filter. Its scene parser invokes the existing
match initializer without another `Gameplay.Start`/reset. New tracker log
records with two positive player IDs confirm that initialization resumed. The
UI reports a failure to verify recovery if that evidence does not arrive.

Writes use `O_APPEND`, preserve existing entries, and reject symlinks,
nonregular or replaced files, truncation, incomplete lines, and excessive
output. No tracker binaries or preferences are edited and no tracker process
is stopped or relaunched. Logs and player IDs remain local.

This restores current match data. It cannot recreate discarded opponent
history and may cause HSTracker statistics to treat the resumed segment as
another match. A native upstream tracker fix would avoid those limitations.
The workaround is restricted to 3.7.3 so it does not affect future fixes.

## Validation

- Live test with installed HSTracker 3.7.3: the same recovery controller was
  compiled into a temporary companion to the existing signed HS Reconnect app.
  After the user clicked Reconnect, the helper appended its event, detected
  restored player IDs, and the user confirmed that the missing data was back.
  Neither installed app bundle changed. This validates the recovery mechanism;
  the complete unsigned app build validates its integration into the app.
- `swift test` covers reload sequencing/cancellation, tracker version targeting,
  parser/filter compatibility, verification offsets, incremental records,
  preserving game log bytes, and changed/nonregular-file rejection.
- The complete app can be compiled with `xcodegen generate` followed by
  `xcodebuild build -project HSReconnect.xcodeproj -scheme HSReconnect
  -configuration Debug -destination 'generic/platform=macOS'
  CODE_SIGNING_ALLOWED=NO`. Installing the full app requires normal Network
  Extension signing and provisioning.
