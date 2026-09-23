#!/bin/zsh
set -euo pipefail

component_plist="${1:?component plist path is required}"
expected_path="Applications/HS Reconnect.app"

actual_path="$(
  /usr/libexec/PlistBuddy \
    -c "Print :0:RootRelativeBundlePath" \
    "${component_plist}"
)"

if [[ "${actual_path}" != "${expected_path}" ]]; then
  echo "Unexpected package component: ${actual_path}" >&2
  exit 1
fi

/usr/libexec/PlistBuddy \
  -c "Set :0:BundleIsRelocatable false" \
  "${component_plist}" 2>/dev/null \
  || /usr/libexec/PlistBuddy \
    -c "Add :0:BundleIsRelocatable bool false" \
    "${component_plist}"
