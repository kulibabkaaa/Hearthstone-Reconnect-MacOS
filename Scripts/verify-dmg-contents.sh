#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
dmg="${1:?Usage: verify-dmg-contents.sh DMG}"
inspection_dir="$(mktemp -d /private/tmp/hs-reconnect-dmg-verify.XXXXXX)"
mountpoint="${inspection_dir}/mounted"
expanded_package="${inspection_dir}/package"
mounted=false

cleanup() {
  if [[ "${mounted}" == "true" ]]; then
    hdiutil detach "${mountpoint}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${inspection_dir}"
}

trap cleanup EXIT

[[ -f "${dmg}" ]] || {
  echo "Disk image not found: ${dmg}" >&2
  exit 1
}

hdiutil verify "${dmg}"
codesign --verify --verbose=2 "${dmg}"
codesign -dv --verbose=4 "${dmg}" 2>&1 \
  | grep "Authority=Developer ID Application:" >/dev/null

mkdir -p "${mountpoint}"
hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "${mountpoint}" \
  "${dmg}" >/dev/null
mounted=true

package="${mountpoint}/Install HS Reconnect.pkg"
[[ -f "${package}" ]] || {
  echo "The release DMG does not contain the installer." >&2
  exit 1
}

pkgutil --check-signature "${package}"
pkgutil --expand-full "${package}" "${expanded_package}"
"${script_dir}/verify-expanded-installer.sh" "${expanded_package}"

app="${expanded_package}/Payload/Applications/HS Reconnect.app"
codesign --verify --deep --strict --verbose=2 "${app}"
codesign -dv --verbose=4 "${app}" 2>&1 \
  | grep "Authority=Developer ID Application:" >/dev/null

lipo "${app}/Contents/MacOS/HS Reconnect" \
  -verify_arch arm64 x86_64
lipo \
  "${app}/Contents/Library/LoginItems/HS Reconnect Watcher.app/Contents/MacOS/HS Reconnect Watcher" \
  -verify_arch arm64 x86_64
lipo \
  "${app}/Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app/Contents/MacOS/HS Reconnect Lobby Capture Probe" \
  -verify_arch arm64 x86_64
lipo \
  "${app}/Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app/Contents/Frameworks/HearthMirror.framework/Versions/A/HearthMirror" \
  -verify_arch arm64 x86_64
lipo \
  "${app}/Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app/Contents/Frameworks/libcoreclr.dylib" \
  -verify_arch arm64 x86_64
lipo \
  "${app}/Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app/Contents/Frameworks/libSystem.Native.dylib" \
  -verify_arch arm64 x86_64
lipo \
  "${app}/Contents/Library/SystemExtensions/io.github.kulibabkaaa.HSReconnect.ProxyExtension.systemextension/Contents/MacOS/io.github.kulibabkaaa.HSReconnect.ProxyExtension" \
  -verify_arch arm64 x86_64

hdiutil detach "${mountpoint}" >/dev/null
mounted=false

echo "Release DMG contents verified."
