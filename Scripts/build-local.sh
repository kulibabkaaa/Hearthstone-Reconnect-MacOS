#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
derived_data="${HOME}/Library/Developer/Xcode/DerivedData/HSReconnectLocal"
staged_app="${HOME}/Downloads/HS Reconnect.app"
prototype_version="$(
  awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
staged_zip="${HOME}/Downloads/HS-Reconnect-${prototype_version}.zip"
staged_pkg="${HOME}/Downloads/HS-Reconnect-${prototype_version}.pkg"
built_app="${derived_data}/Build/Products/Debug/HS Reconnect.app"
verification_dir="$(mktemp -d /tmp/hs-reconnect-build.XXXXXX)"

cleanup() {
  rm -rf -- "${verification_dir}"
}

trap cleanup EXIT

cd "${project_dir}"

if [[ -d "${project_dir}/Vendor/HearthMirror" ]]; then
  # HearthMirror is not in the repository; build the lobby helper only from a local copy.
  export HS_RECONNECT_HEARTHMIRROR=YES
fi
xcodegen generate
"${script_dir}/verify-system-extension-config.sh"
swift test
"${project_dir}/Tests/Packaging/run-tests.sh"

xcodebuild \
  -project HSReconnect.xcodeproj \
  -scheme HSReconnect \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "${derived_data}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  clean build

rm -rf "${staged_app}"
ditto --norsrc --noextattr "${built_app}" "${staged_app}"
xattr -cr "${staged_app}"
codesign --verify --deep --strict --verbose=2 "${staged_app}"

rm -f "${staged_zip}"
ditto -c -k --norsrc --noextattr --keepParent \
  "${staged_app}" \
  "${staged_zip}"
mkdir -p "${verification_dir}/archive"
ditto -x -k "${staged_zip}" "${verification_dir}/archive"
codesign --verify --deep --strict --verbose=2 \
  "${verification_dir}/archive/HS Reconnect.app"

installer_identity="$(
  security find-identity -v \
    | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' \
    | head -n 1
)"

if [[ -n "${installer_identity}" ]]; then
  rm -f "${staged_pkg}"
  mkdir -p \
    "${verification_dir}/payload/Applications" \
    "${verification_dir}/installer-scripts"
  ditto --norsrc --noextattr \
    "${staged_app}" \
    "${verification_dir}/payload/Applications/HS Reconnect.app"
  ditto --norsrc --noextattr \
    "${script_dir}/Installer/preinstall" \
    "${verification_dir}/installer-scripts/preinstall"
  ditto --norsrc --noextattr \
    "${script_dir}/Installer/postinstall" \
    "${verification_dir}/installer-scripts/postinstall"
  ditto --norsrc --noextattr \
    "${script_dir}/Installer/create-desktop-shortcut.sh" \
    "${verification_dir}/installer-scripts/create-desktop-shortcut.sh"
  chmod 755 \
    "${verification_dir}/installer-scripts/preinstall" \
    "${verification_dir}/installer-scripts/postinstall" \
    "${verification_dir}/installer-scripts/create-desktop-shortcut.sh"
  pkgbuild \
    --analyze \
    --root "${verification_dir}/payload" \
    "${verification_dir}/components.plist"
  "${script_dir}/prepare-component-plist.sh" \
    "${verification_dir}/components.plist"
  pkgbuild \
    --root "${verification_dir}/payload" \
    --component-plist "${verification_dir}/components.plist" \
    --scripts "${verification_dir}/installer-scripts" \
    --install-location / \
    --identifier io.github.kulibabkaaa.HSReconnect.installer \
    --version "${prototype_version}" \
    --sign "${installer_identity}" \
    "${staged_pkg}"
  pkgutil --check-signature "${staged_pkg}"
  pkgutil --expand-full "${staged_pkg}" "${verification_dir}/package"
  "${script_dir}/verify-expanded-installer.sh" \
    "${verification_dir}/package"
  codesign --verify --deep --strict --verbose=2 \
    "${verification_dir}/package/Payload/Applications/HS Reconnect.app"
fi

echo "Built app: ${staged_app}"
echo "Built archive: ${staged_zip}"
if [[ -n "${installer_identity}" ]]; then
  echo "Built installer: ${staged_pkg}"
fi
