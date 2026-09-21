#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h:h}"
fixture_dir="$(mktemp -d /tmp/hs-reconnect-proxy-packaging-tests.XXXXXX)"

cleanup() {
  rm -rf -- "${fixture_dir}"
}

trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

component_plist="${fixture_dir}/components.plist"

[[ -f "${project_dir}/Scripts/Installer/preinstall" ]] \
  || fail "the installer must stop a running copy before upgrading"
/usr/bin/grep -q \
  '/Applications/HS Reconnect.app/Contents/MacOS/HS Reconnect' \
  "${project_dir}/Scripts/Installer/preinstall" \
  || fail "the preinstall script must target only HS Reconnect"
/usr/bin/grep -q \
  -- '-o args=' \
  "${project_dir}/Scripts/Installer/preinstall" \
  || fail "the preinstall script must inspect the complete executable path"
/usr/bin/grep -Fq \
  'HS Reconnect Watcher.app/Contents/MacOS/HS Reconnect Watcher' \
  "${project_dir}/Scripts/Installer/preinstall" \
  || fail "the preinstall script must stop the installed watcher"
/usr/bin/grep -Fq \
  'HS Reconnect Lobby Capture Probe.app/Contents/MacOS/HS Reconnect Lobby Capture Probe' \
  "${project_dir}/Scripts/Installer/preinstall" \
  || fail "the preinstall script must stop the installed lobby helper"
/usr/bin/grep -Fq \
  '/usr/sbin/chown -RH' \
  "${project_dir}/Scripts/Installer/postinstall" \
  || fail "the installer must leave the app replaceable by Sparkle"
/usr/bin/grep -Fq \
  '${console_user}:${console_group}' \
  "${project_dir}/Scripts/Installer/postinstall" \
  || fail "the installer must assign the app to the logged-in user"

cat > "${component_plist}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>BundleHasStrictIdentifier</key>
		<true/>
		<key>BundleIsRelocatable</key>
		<true/>
		<key>BundleIsVersionChecked</key>
		<true/>
		<key>BundleOverwriteAction</key>
		<string>upgrade</string>
		<key>RootRelativeBundlePath</key>
		<string>Applications/HS Reconnect.app</string>
	</dict>
</array>
</plist>
PLIST

"${project_dir}/Scripts/prepare-component-plist.sh" "${component_plist}"

relocatable="$(
  /usr/libexec/PlistBuddy \
    -c "Print :0:BundleIsRelocatable" \
    "${component_plist}"
)"
[[ "${relocatable}" == "false" ]] \
  || fail "the app component must be non-relocatable"

fake_home="${fixture_dir}/home"
fake_app="${fixture_dir}/Applications/HS Reconnect.app"
mkdir -p "${fake_home}/Desktop" "${fake_app}"

"${project_dir}/Scripts/Installer/create-desktop-shortcut.sh" \
  "${fake_home}" \
  "$(id -un)" \
  "${fake_app}"

shortcut="${fake_home}/Desktop/HS Reconnect.app"
[[ -L "${shortcut}" ]] || fail "the installer must create a desktop shortcut"
[[ "$(readlink "${shortcut}")" == "${fake_app}" ]] \
  || fail "the desktop shortcut must target the installed app"

replacement_target="${fixture_dir}/Do Not Replace.app"
ln -s "${replacement_target}" "${fake_home}/Desktop/Existing Shortcut.app"
"${project_dir}/Scripts/Installer/create-desktop-shortcut.sh" \
  "${fake_home}" \
  "$(id -un)" \
  "${fake_app}"
[[ "$(readlink "${shortcut}")" == "${fake_app}" ]] \
  || fail "reinstalling must leave the correct shortcut intact"

expanded_package="${fixture_dir}/expanded"
mkdir -p \
  "${expanded_package}/Payload/Applications/HS Reconnect.app" \
  "${expanded_package}/Scripts"
cp "${project_dir}/Scripts/Installer/postinstall" \
  "${project_dir}/Scripts/Installer/preinstall" \
  "${project_dir}/Scripts/Installer/create-desktop-shortcut.sh" \
  "${expanded_package}/Scripts/"
cat > "${expanded_package}/PackageInfo" <<'PACKAGE_INFO'
<?xml version="1.0" encoding="utf-8"?>
<pkg-info relocatable="false" identifier="io.github.kulibabkaaa.HSReconnect.installer">
  <payload numberOfFiles="1" installKBytes="1"/>
  <bundle path="./Applications/HS Reconnect.app" id="io.github.kulibabkaaa.HSReconnect"/>
</pkg-info>
PACKAGE_INFO

"${project_dir}/Scripts/verify-expanded-installer.sh" "${expanded_package}"

perl -0pi -e \
  's#</pkg-info>#<relocate><bundle id="io.github.kulibabkaaa.HSReconnect"/></relocate></pkg-info>#' \
  "${expanded_package}/PackageInfo"

if "${project_dir}/Scripts/verify-expanded-installer.sh" "${expanded_package}"; then
  fail "the package verifier must reject a relocatable app"
fi

echo "Packaging tests passed."
