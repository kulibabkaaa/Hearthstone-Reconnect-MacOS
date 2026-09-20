#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h:h}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "${project_dir}/project.yml" ]] \
  || fail "project.yml is missing"
[[ -f "${project_dir}/Scripts/build-release.sh" ]] \
  || fail "the public release builder is missing"
[[ -f "${project_dir}/Scripts/export-developer-id.sh" ]] \
  || fail "the Developer ID system-extension exporter is missing"
[[ -f "${project_dir}/Scripts/create-release-dmg.sh" ]] \
  || fail "the signed GitHub Release DMG builder is missing"
[[ -f "${project_dir}/Scripts/verify-dmg-contents.sh" ]] \
  || fail "the release DMG content verifier is missing"
[[ -f "${project_dir}/Scripts/prepare-update-feed.sh" ]] \
  || fail "the Sparkle update-feed builder is missing"
[[ -x "${project_dir}/Scripts/patch-project-capabilities.sh" ]] \
  || fail "the Xcode App Groups capability patch is missing"
[[ -f "${project_dir}/Extension/ProxyExtension.entitlements" ]] \
  || fail "the transparent-proxy extension is missing"
[[ -f "${project_dir}/Scripts/Installer/postinstall" ]] \
  || fail "the installer postinstall script is missing"
[[ -f "${project_dir}/Scripts/Installer/preinstall" ]] \
  || fail "the installer preinstall script is missing"
[[ -f "${project_dir}/Documentation/Images/hs-reconnect-window.png" ]] \
  || fail "the public app screenshot is missing"
[[ -f "${project_dir}/RELEASE_NOTES_1.3.0.md" ]] \
  || fail "the 1.3.0 release notes are missing"
[[ -f "${project_dir}/SECURITY.md" ]] \
  || fail "the lobby helper security notes are missing"
[[ -f "${project_dir}/Vendor/HearthMirror/SHA256SUMS" ]] \
  || fail "the vendored HearthMirror checksums are missing"

version="$(
  /usr/bin/awk '
    /MARKETING_VERSION:/ {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' "${project_dir}/project.yml"
)"

[[ -n "${version}" ]] || fail "the release version is missing"
[[ "${version}" == "1.3.0" ]] || fail "the update release must use version 1.3.0"

bug_report_endpoint="$(
  /usr/bin/awk '
    /HSRBugReportEndpoint:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      gsub(/"/, "")
      print
      exit
    }
  ' "${project_dir}/project.yml"
)"
[[ "${bug_report_endpoint}" == https://forminit.com/f/* ]] \
  || fail "the production Forminit bug-report endpoint is not configured"

readme_download_url="releases/latest/download/HS-Reconnect-${version}.dmg"
/usr/bin/head -n 40 "${project_dir}/README.md" \
  | /usr/bin/grep -Fq "${readme_download_url}" \
  || fail "the README must put the current direct download near the top"

/usr/bin/grep -Fq \
  'Documentation/Images/hs-reconnect-window.png' \
  "${project_dir}/README.md" \
  || fail "the README does not show the public app screenshot"

/usr/bin/grep -Fq \
  'hsreconnect@gmail.com' \
  "${project_dir}/README.md" \
  || fail "public documentation does not use the current contact email"

/usr/bin/grep -q \
  'PRODUCT_BUNDLE_IDENTIFIER: io.github.kulibabkaaa.HSReconnect$' \
  "${project_dir}/project.yml" \
  || fail "the host bundle identifier is not final"

/usr/bin/grep -q \
  'PRODUCT_BUNDLE_IDENTIFIER: io.github.kulibabkaaa.HSReconnect.ProxyExtension$' \
  "${project_dir}/project.yml" \
  || fail "the extension bundle identifier is not final"

if /usr/bin/grep -R -n \
  --exclude-dir=.build \
  --exclude-dir=build \
  --exclude-dir=dist \
  --exclude-dir=.git \
  --exclude='run-tests.sh' \
  'HS Reconnect Proxy\|HSReconnectProxyPrototype' \
  "${project_dir}/App" \
  "${project_dir}/Extension" \
  "${project_dir}/Watcher" \
  "${project_dir}/README.md" \
  "${project_dir}/project.yml"; then
  fail "prototype branding remains in the public product"
fi

if /usr/bin/grep -q \
  'hsreconnect-helper\|sudoers' \
  "${project_dir}/README.md"; then
  fail "the public documentation still describes the retired helper"
fi

prepare_proxy_block="$(
  /usr/bin/awk '
    /private func prepareProxy\(\)/ { in_prepare = 1 }
    in_prepare && /private func activationFailureMessage\(\)/ { exit }
    in_prepare { print }
  ' "${project_dir}/App/AppDelegate.swift"
)"

if /usr/bin/grep -q \
  'beginUninstallCleanup' \
  <<< "${prepare_proxy_block}"; then
  fail "normal proxy activation can still start uninstall cleanup"
fi

/usr/bin/grep -q \
  'ProcessInfo.processInfo.processIdentifier' \
  "${project_dir}/App/AppUninstaller.swift" \
  || fail "self-removal does not wait for the uninstall process to exit"

/usr/bin/grep -q \
  'AppUninstallRecoveryPolicy.shouldRestoreRuntime' \
  "${project_dir}/App/AppDelegate.swift" \
  || fail "failed cleanup can still reactivate a removed extension"

/usr/bin/grep -q \
  'SMAppService.openSystemSettingsLoginItems' \
  "${project_dir}/App/AppDelegate.swift" \
  || fail "approval guidance cannot reopen the correct System Settings pane"

/usr/bin/grep -q \
  'setSystemExtensionApprovalRequired(true)' \
  "${project_dir}/App/AppDelegate.swift" \
  || fail "approval guidance is not kept available in the app window"

scheme_build_block="$(
  /usr/bin/awk '
    /^    build:$/ { in_build = 1 }
    in_build && /^    test:$/ { exit }
    in_build { print }
  ' "${project_dir}/project.yml"
)"

if /usr/bin/grep -q \
  'ProxyCoreTests\|ProxyCore: test' \
  <<< "${scheme_build_block}"; then
  fail "the archive build action still includes unit-test products"
fi

if /usr/bin/grep -q \
  'xcodebuild -exportArchive' \
  "${project_dir}/Scripts/build-release.sh"; then
  fail "Xcode 26 cannot directly export this Developer ID system extension"
fi

/usr/bin/grep -q \
  'app-proxy-provider-systemextension' \
  "${project_dir}/Scripts/export-developer-id.sh" \
  || fail "the Developer ID exporter does not apply direct-distribution entitlements"

/usr/bin/grep -q \
  'embedded.provisionprofile' \
  "${project_dir}/Scripts/export-developer-id.sh" \
  || fail "the Developer ID exporter does not embed distribution profiles"

/usr/bin/grep -q \
  'signed-extension-entitlements.plist' \
  "${project_dir}/Scripts/export-developer-id.sh" \
  || fail "the Developer ID exporter does not verify final signed App Group entitlements"

/usr/bin/grep -q \
  'Entitlements:com.apple.security.application-groups' \
  "${project_dir}/Scripts/export-developer-id.sh" \
  || fail "the Developer ID exporter does not inspect profile App Groups"

/usr/bin/grep -Fq \
  'wildcard_application_group="${team_id}.*"' \
  "${project_dir}/Scripts/export-developer-id.sh" \
  || fail "the Developer ID exporter does not accept Apple's team-wide App Group authorization"

/usr/bin/grep -q \
  'profile_has_required_entitlements' \
  "${project_dir}/Scripts/export-developer-id.sh" \
  || fail "the Developer ID exporter does not validate selected and embedded profiles"

/usr/bin/grep -q \
  'Embedded profile for.*does not authorize' \
  "${project_dir}/Scripts/export-developer-id.sh" \
  || fail "the Developer ID exporter does not reject an invalid embedded profile"

/usr/bin/grep -q \
  '/private/tmp/hs-reconnect-release' \
  "${project_dir}/Scripts/build-release.sh" \
  || fail "release signing still runs inside file-provider managed storage"

/usr/bin/grep -q \
  'create-release-dmg.sh' \
  "${project_dir}/Scripts/build-release.sh" \
  || fail "the release build does not create the downloadable DMG"

/usr/bin/grep -q \
  'hdiutil create' \
  "${project_dir}/Scripts/create-release-dmg.sh" \
  || fail "the DMG builder does not create a disk image"

/usr/bin/grep -q \
  -- '-format UDZO' \
  "${project_dir}/Scripts/create-release-dmg.sh" \
  || fail "the release DMG must use Apple's read-only UDZO format"

/usr/bin/grep -q \
  'io.github.kulibabkaaa.HSReconnect.dmg' \
  "${project_dir}/Scripts/create-release-dmg.sh" \
  || fail "the release DMG does not have a unique signing identifier"

/usr/bin/grep -q \
  'verify-dmg-contents.sh' \
  "${project_dir}/Scripts/build-release.sh" \
  || fail "the release build does not inspect the completed DMG"

/usr/bin/grep -q \
  'HS Reconnect Lobby Capture Probe.app/Contents/MacOS/HS Reconnect Lobby Capture Probe' \
  "${project_dir}/Scripts/build-release.sh" \
  || fail "the release build does not verify the lobby helper architectures"

/usr/bin/grep -q \
  'Release lobby helper contains debug file logging' \
  "${project_dir}/Scripts/build-release.sh" \
  || fail "the release build does not reject lobby debug logging"

if /usr/bin/grep -Fq \
  'does not collect or transmit personal data' \
  "${project_dir}/PRIVACY.md" "${project_dir}/README.md" "${project_dir}/docs/index.html"; then
  fail "privacy copy overstates what a direct Blizzard request transmits"
fi

/usr/bin/grep -q \
  'HS-Reconnect-${version}.dmg' \
  "${project_dir}/Scripts/notarize-release.sh" \
  || fail "notarization does not target the outer release DMG"

/usr/bin/grep -q \
  'spctl --assess --type install' \
  "${project_dir}/Scripts/notarize-release.sh" \
  || fail "the signed update package is not verified after notarization"

/usr/bin/grep -q \
  'exactVersion: 2.10.0' \
  "${project_dir}/project.yml" \
  || fail "Sparkle is not pinned to the reviewed release"

/usr/bin/grep -q \
  'exactVersion: 2.14.2' \
  "${project_dir}/project.yml" \
  || fail "TelemetryDeck is not pinned to the reviewed release"

/usr/bin/grep -q \
  'HSRTelemetryDeckAppID: 9A07D574-467A-4B61-88A9-B50A46A87470' \
  "${project_dir}/project.yml" \
  || fail "the production TelemetryDeck app ID is missing"

/usr/bin/grep -q \
  'TelemetryDeck.signal(event.rawValue)' \
  "${project_dir}/App/AnalyticsController.swift" \
  || fail "feature analytics are not connected"

/usr/bin/grep -qi \
  'This analytics collection is always' \
  "${project_dir}/PRIVACY.md" \
  || fail "the always-on analytics disclosure is missing"

/usr/bin/grep -q \
  'SUFeedURL: https://kulibabkaaa.github.io/Hearthstone-Reconnect-MacOS/appcast.xml' \
  "${project_dir}/project.yml" \
  || fail "the public Sparkle feed URL is missing"

/usr/bin/grep -q \
  'Automatically check for updates' \
  "${project_dir}/App/SettingsWindowController.swift" \
  || fail "the automatic update toggle is missing"

/usr/bin/grep -q \
  'Check for Updates' \
  "${project_dir}/App/SettingsWindowController.swift" \
  || fail "the manual update button is missing"

/usr/bin/grep -q \
  'Report a Bug' \
  "${project_dir}/App/SettingsWindowController.swift" \
  || fail "the in-app bug report button is missing"

/usr/bin/grep -q \
  'func windowWillClose' \
  "${project_dir}/App/BugReportWindowController.swift" \
  || fail "closing the bug report does not clean up its temporary image"

/usr/bin/grep -q \
  'removeTemporaryAttachments()' \
  "${project_dir}/App/BugReportWindowController.swift" \
  || fail "the bug report does not remove its temporary images"

/usr/bin/grep -q \
  'CGImageSourceCreateThumbnailAtIndex' \
  "${project_dir}/App/BugReportWindowController.swift" \
  || fail "bug-report images are not safely downsampled before use"

/usr/bin/grep -q \
  'URLSessionConfiguration.ephemeral' \
  "${project_dir}/App/BugReportClient.swift" \
  || fail "bug reports do not use an ephemeral network session"

/usr/bin/grep -q \
  'BugReportContent.allowsRedirect' \
  "${project_dir}/App/BugReportClient.swift" \
  || fail "bug-report redirects are not constrained to the configured origin"

/usr/bin/grep -q \
  '#if DEBUG' \
  "${project_dir}/Tools/LobbyCaptureProbe/main.swift" \
  || fail "the lobby helper's file logging is not debug-only"

/usr/bin/grep -q \
  'process.environment = ' \
  "${project_dir}/App/LobbyReader.swift" \
  || fail "the privileged lobby helper inherits the full app environment"

/usr/bin/grep -q \
  'maximumEventBytes' \
  "${project_dir}/App/LobbyReader.swift" \
  || fail "lobby helper output is not bounded"

/usr/bin/grep -q \
  'sparkle:installationType="package"' \
  "${project_dir}/Scripts/prepare-update-feed.sh" \
  || fail "the appcast does not install the signed package"

/usr/bin/grep -q \
  'keychain_public_key.*configured_public_key' \
  "${project_dir}/Scripts/prepare-update-feed.sh" \
  || fail "the appcast builder does not match the signing key to SUPublicEDKey"

/usr/bin/grep -q \
  'download_count' \
  "${project_dir}/README.md" \
  || fail "the privacy-preserving GitHub download count is not documented"

if /usr/bin/grep -Eq \
  '^[[:space:]]*status=' \
  "${project_dir}/Scripts/notarize-release.sh"; then
  fail "the notarization script assigns zsh's read-only status variable"
fi

echo "Release identity tests passed."
