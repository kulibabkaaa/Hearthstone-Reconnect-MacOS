#!/bin/zsh
set -euo pipefail

expanded_package="${1:?expanded package path is required}"
package_info="${expanded_package}/PackageInfo"
payload_app="${expanded_package}/Payload/Applications/HS Reconnect.app"
installer_scripts="${expanded_package}/Scripts"

[[ -f "${package_info}" ]] || {
  echo "Installer PackageInfo is missing." >&2
  exit 1
}

[[ -d "${payload_app}" ]] || {
  echo "Installer does not place HS Reconnect in Applications." >&2
  exit 1
}

if /usr/bin/find "${expanded_package}/Payload" -name '._*' -print -quit \
  | /usr/bin/grep -q .; then
  echo "Installer payload contains AppleDouble metadata files." >&2
  exit 1
fi

if /usr/bin/grep -q "<relocate>" "${package_info}"; then
  echo "Installer still permits app relocation." >&2
  exit 1
fi

/usr/bin/grep -q \
  'path="./Applications/HS Reconnect.app"' \
  "${package_info}" || {
    echo "Installer app path is incorrect." >&2
    exit 1
  }

[[ -x "${installer_scripts}/postinstall" ]] || {
  echo "Installer postinstall script is missing." >&2
  exit 1
}

[[ -x "${installer_scripts}/preinstall" ]] || {
  echo "Installer preinstall script is missing." >&2
  exit 1
}

[[ -x "${installer_scripts}/create-desktop-shortcut.sh" ]] || {
  echo "Desktop shortcut script is missing." >&2
  exit 1
}

echo "Installer layout verified."
