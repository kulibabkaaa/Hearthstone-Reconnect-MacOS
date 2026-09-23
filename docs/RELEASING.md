# Releasing HS Reconnect

The public update system uses Sparkle 2 and a signed, notarized app ZIP from a
GitHub Release. The PKG and DMG remain the first-install path. Keep the Sparkle
private EdDSA key out of this repository.

## Before building

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Add `RELEASE_NOTES_<version>.md`.
3. Confirm `HSRBugReportEndpoint` contains the production Forminit endpoint.
4. Run `xcodegen generate`.

## Build and notarize

```sh
Scripts/build-release.sh
Scripts/notarize-release.sh submit dist/HS-Reconnect-<version>.pkg
Scripts/notarize-release.sh finish dist/HS-Reconnect-<version>.pkg <submission-id>
Scripts/notarize-release.sh submit dist/HS-Reconnect-<version>.zip
Scripts/notarize-release.sh finish dist/HS-Reconnect-<version>.zip <submission-id>
Scripts/notarize-release.sh submit dist/HS-Reconnect-<version>.dmg
Scripts/notarize-release.sh finish dist/HS-Reconnect-<version>.dmg <submission-id>
Scripts/prepare-update-feed.sh
```

The ZIP finish step staples the notarized app and repacks the ZIP. Publish that
final ZIP, not the earlier submission file. Keep the build root until this step
finishes; set `HS_RECONNECT_BUILD_ROOT` for both build and ZIP finish if using a
custom build location.

`prepare-update-feed.sh` refuses an update ZIP whose app does not pass Apple's
notarization assessment. It signs the ZIP with the Sparkle private key in the
login Keychain and writes `docs/appcast.xml`.

## Publish the GitHub Release

Upload the release assets first:

```sh
gh release create v<version> \
  dist/HS-Reconnect-<version>.dmg \
  dist/HS-Reconnect-<version>.pkg \
  dist/HS-Reconnect-<version>.zip \
  dist/SHA256SUMS-<version>.txt \
  --title "HS Reconnect <version>" \
  --notes-file RELEASE_NOTES_<version>.md
```

Verify that the release and all downloads work before changing GitHub Pages.

## Publish the website and update feed

This is a separate step. Merge or commit the prepared `docs/` changes to the
branch served by GitHub Pages only when the website and automatic update feed
should go live. GitHub Pages must serve the new appcast only after the ZIP URL
works. This prevents users from being offered a missing update archive.

Verify:

```sh
curl --fail https://kulibabkaaa.github.io/Hearthstone-Reconnect-MacOS/appcast.xml
curl --fail --head \
  https://github.com/kulibabkaaa/Hearthstone-Reconnect-MacOS/releases/download/v<version>/HS-Reconnect-<version>.pkg
curl --fail --head \
  https://github.com/kulibabkaaa/Hearthstone-Reconnect-MacOS/releases/download/v<version>/HS-Reconnect-<version>.zip
curl --fail --head \
  https://github.com/kulibabkaaa/Hearthstone-Reconnect-MacOS/releases/download/v<version>/HS-Reconnect-<version>.dmg
```

Back up the Sparkle private key separately from the source repository. Losing
it prevents existing installations from trusting future updates.
