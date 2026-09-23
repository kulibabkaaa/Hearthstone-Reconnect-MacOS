#!/bin/zsh
set -euo pipefail

archive_path="${1:?Usage: export-developer-id.sh ARCHIVE OUTPUT_APP}"
output_app="${2:?Usage: export-developer-id.sh ARCHIVE OUTPUT_APP}"
team_id="D8KUYWS8JN"
host_bundle_id="io.github.kulibabkaaa.HSReconnect"
extension_bundle_id="${host_bundle_id}.ProxyExtension"
application_group="${team_id}.${host_bundle_id}"
profile_dir="${PROVISIONING_PROFILE_DIR:-${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles}"
source_app="${archive_path}/Products/Applications/HS Reconnect.app"
extension_relative_path="Contents/Library/SystemExtensions/${extension_bundle_id}.systemextension"
watcher_relative_path="Contents/Library/LoginItems/HS Reconnect Watcher.app"
helper_relative_path="Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app"
hearth_mirror_relative_path="${helper_relative_path}/Contents/Frameworks/HearthMirror.framework"
coreclr_relative_path="${helper_relative_path}/Contents/Frameworks/libcoreclr.dylib"
system_native_relative_path="${helper_relative_path}/Contents/Frameworks/libSystem.Native.dylib"
sparkle_relative_path="Contents/Frameworks/Sparkle.framework"
temporary_dir="$(mktemp -d /tmp/hs-reconnect-developer-id.XXXXXX)"

cleanup() {
  rm -rf -- "${temporary_dir}"
}

trap cleanup EXIT

application_identity="${APPLICATION_SIGNING_IDENTITY:-$(
  security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1
)}"

[[ -n "${application_identity}" ]] || {
  echo "A Developer ID Application identity is required." >&2
  exit 1
}

[[ -d "${source_app}" ]] || {
  echo "The Xcode archive does not contain HS Reconnect.app." >&2
  exit 1
}

[[ -d "${profile_dir}" ]] || {
  echo "The Xcode provisioning-profile directory is missing." >&2
  exit 1
}

profile_has_required_entitlements() {
  local profile="$1"
  local bundle_id="$2"
  local decoded="$3"
  local profile_name application_identifier network_extensions application_groups

  security cms -D -i "${profile}" > "${decoded}" 2>/dev/null \
    || return 1

  profile_name="$(
    /usr/libexec/PlistBuddy -c "Print :Name" "${decoded}" 2>/dev/null \
      || true
  )"
  application_identifier="$(
    /usr/libexec/PlistBuddy \
      -c "Print :Entitlements:com.apple.application-identifier" \
      "${decoded}" 2>/dev/null \
      || true
  )"
  network_extensions="$(
    /usr/libexec/PlistBuddy \
      -c "Print :Entitlements:com.apple.developer.networking.networkextension" \
      "${decoded}" 2>/dev/null \
      || true
  )"
  application_groups="$(
    /usr/libexec/PlistBuddy \
      -c "Print :Entitlements:com.apple.security.application-groups" \
      "${decoded}" 2>/dev/null \
      || true
  )"

  local wildcard_application_group="${team_id}.*"

  [[ "${profile_name}" == *"Direct"* ]] \
    && [[ "${application_identifier}" == "${team_id}.${bundle_id}" ]] \
    && [[ "${network_extensions}" == *"app-proxy-provider-systemextension"* ]] \
    && {
      [[ "${application_groups}" == *"${application_group}"* ]] \
        || [[ "${application_groups}" == *"${wildcard_application_group}"* ]]
    }
}

find_direct_profile() {
  local bundle_id="$1"
  local candidate decoded

  for candidate in \
    "${profile_dir}"/*.provisionprofile(N) \
    "${profile_dir}"/*.mobileprovision(N); do
    decoded="${temporary_dir}/profile-$RANDOM.plist"
    if profile_has_required_entitlements \
      "${candidate}" \
      "${bundle_id}" \
      "${decoded}"; then
      print -r -- "${candidate}"
      return 0
    fi
  done

  echo "No Developer ID profile for ${bundle_id} authorizes the Network Extension and ${application_group}." >&2
  return 1
}

host_profile="$(find_direct_profile "${host_bundle_id}")"
extension_profile="$(find_direct_profile "${extension_bundle_id}")"

rm -rf -- "${output_app}"
mkdir -p "${output_app:h}"
ditto --norsrc --noextattr "${source_app}" "${output_app}"
xattr -cr "${output_app}"

extension_path="${output_app}/${extension_relative_path}"
watcher_path="${output_app}/${watcher_relative_path}"
helper_path="${output_app}/${helper_relative_path}"
hearth_mirror_path="${output_app}/${hearth_mirror_relative_path}"
coreclr_path="${output_app}/${coreclr_relative_path}"
system_native_path="${output_app}/${system_native_relative_path}"
sparkle_path="${output_app}/${sparkle_relative_path}"
sparkle_autoupdate_path="${sparkle_path}/Versions/B/Autoupdate"
sparkle_updater_path="${sparkle_path}/Versions/B/Updater.app"
sparkle_downloader_path="${sparkle_path}/Versions/B/XPCServices/Downloader.xpc"
sparkle_installer_path="${sparkle_path}/Versions/B/XPCServices/Installer.xpc"
host_entitlements="${temporary_dir}/host-entitlements.plist"
extension_entitlements="${temporary_dir}/extension-entitlements.plist"
helper_entitlements="${temporary_dir}/helper-entitlements.plist"

[[ -d "${extension_path}" ]] || {
  echo "The archived Network Extension is missing." >&2
  exit 1
}
[[ -d "${watcher_path}" ]] || {
  echo "The archived Hearthstone watcher is missing." >&2
  exit 1
}
[[ -d "${helper_path}" ]] || {
  echo "The archived lobby capture helper is missing." >&2
  exit 1
}
[[ -d "${hearth_mirror_path}" ]] || {
  echo "The archived HearthMirror framework is missing." >&2
  exit 1
}
[[ -d "${sparkle_path}" ]] || {
  echo "The archived Sparkle framework is missing." >&2
  exit 1
}
for sparkle_component in \
  "${sparkle_autoupdate_path}" \
  "${sparkle_updater_path}" \
  "${sparkle_downloader_path}" \
  "${sparkle_installer_path}"; do
  [[ -e "${sparkle_component}" ]] || {
    echo "The archived Sparkle component is missing: ${sparkle_component}" >&2
    exit 1
  }
done
for runtime_path in "${coreclr_path}" "${system_native_path}"; do
  [[ -f "${runtime_path}" ]] || {
    echo "The archived runtime is missing: ${runtime_path}" >&2
    exit 1
  }
done

codesign -d --entitlements "${host_entitlements}" --xml \
  "${output_app}" 2>/dev/null
codesign -d --entitlements "${extension_entitlements}" --xml \
  "${extension_path}" 2>/dev/null
codesign -d --entitlements "${helper_entitlements}" --xml \
  "${helper_path}" 2>/dev/null

/usr/libexec/PlistBuddy \
  -c "Set :com.apple.developer.networking.networkextension:0 app-proxy-provider-systemextension" \
  "${host_entitlements}"
/usr/libexec/PlistBuddy \
  -c "Set :com.apple.developer.networking.networkextension:0 app-proxy-provider-systemextension" \
  "${extension_entitlements}"
/usr/libexec/PlistBuddy \
  -c "Delete :com.apple.security.get-task-allow" \
  "${host_entitlements}" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Delete :com.apple.security.get-task-allow" \
  "${extension_entitlements}" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Delete :com.apple.security.get-task-allow" \
  "${helper_entitlements}" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Delete :com.apple.security.cs.debugger" \
  "${host_entitlements}" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Delete :com.apple.security.cs.disable-library-validation" \
  "${host_entitlements}" 2>/dev/null || true

ditto --norsrc --noextattr \
  "${host_profile}" \
  "${output_app}/Contents/embedded.provisionprofile"
ditto --norsrc --noextattr \
  "${extension_profile}" \
  "${extension_path}/Contents/embedded.provisionprofile"

for embedded_profile_and_bundle in \
  "${output_app}/Contents/embedded.provisionprofile|${host_bundle_id}" \
  "${extension_path}/Contents/embedded.provisionprofile|${extension_bundle_id}"; do
  embedded_profile="${embedded_profile_and_bundle%%|*}"
  embedded_bundle_id="${embedded_profile_and_bundle#*|}"
  decoded_embedded_profile="${temporary_dir}/embedded-${embedded_bundle_id}.plist"
  if ! profile_has_required_entitlements \
    "${embedded_profile}" \
    "${embedded_bundle_id}" \
    "${decoded_embedded_profile}"; then
    echo "Embedded profile for ${embedded_bundle_id} does not authorize ${application_group}." >&2
    exit 1
  fi
done

for runtime_path in "${coreclr_path}" "${system_native_path}"; do
  codesign --force \
    --sign "${application_identity}" \
    --options runtime \
    --timestamp \
    "${runtime_path}"
done
for sparkle_component in \
  "${sparkle_autoupdate_path}" \
  "${sparkle_updater_path}" \
  "${sparkle_downloader_path}" \
  "${sparkle_installer_path}"; do
  codesign --force \
    --sign "${application_identity}" \
    --options runtime \
    --timestamp \
    "${sparkle_component}"
done
codesign --force \
  --sign "${application_identity}" \
  --options runtime \
  --timestamp \
  "${sparkle_path}"
codesign --force \
  --sign "${application_identity}" \
  --options runtime \
  --timestamp \
  "${hearth_mirror_path}"
codesign --force \
  --sign "${application_identity}" \
  --options runtime \
  --timestamp \
  --entitlements "${helper_entitlements}" \
  "${helper_path}"
codesign --force \
  --sign "${application_identity}" \
  --options runtime \
  --timestamp \
  "${watcher_path}"
codesign --force \
  --sign "${application_identity}" \
  --options runtime \
  --timestamp \
  --entitlements "${extension_entitlements}" \
  "${extension_path}"
codesign --force \
  --sign "${application_identity}" \
  --options runtime \
  --timestamp \
  --entitlements "${host_entitlements}" \
  "${output_app}"

codesign --verify --deep --strict --verbose=2 "${output_app}"

signed_host_entitlements="${temporary_dir}/signed-host-entitlements.plist"
signed_extension_entitlements="${temporary_dir}/signed-extension-entitlements.plist"
codesign -d --entitlements "${signed_host_entitlements}" --xml \
  "${output_app}" 2>/dev/null
codesign -d --entitlements "${signed_extension_entitlements}" --xml \
  "${extension_path}" 2>/dev/null
for signed_entitlements in "${signed_host_entitlements}" "${signed_extension_entitlements}"; do
  signed_group="$(
    /usr/libexec/PlistBuddy \
      -c "Print :com.apple.security.application-groups:0" \
      "${signed_entitlements}" 2>/dev/null \
      || true
  )"
  [[ "${signed_group}" == "${application_group}" ]] || {
    echo "Final signature is missing the required App Group: ${signed_entitlements}" >&2
    exit 1
  }
done

for signed_path in \
  "${coreclr_path}" \
  "${system_native_path}" \
  "${hearth_mirror_path}" \
  "${sparkle_autoupdate_path}" \
  "${sparkle_updater_path}" \
  "${sparkle_downloader_path}" \
  "${sparkle_installer_path}" \
  "${sparkle_path}" \
  "${helper_path}" \
  "${watcher_path}" \
  "${extension_path}" \
  "${output_app}"; do
  codesign -dv --verbose=4 "${signed_path}" 2>&1 \
    | grep "Authority=Developer ID Application:" >/dev/null
done

codesign -d --entitlements - "${helper_path}" 2>&1 \
  | grep "com.apple.security.cs.debugger" >/dev/null
if codesign -d --entitlements - "${output_app}" 2>&1 \
  | grep "com.apple.security.cs.debugger" >/dev/null; then
  echo "The host app must not carry the lobby helper's debugger entitlement." >&2
  exit 1
fi

for signed_path in "${extension_path}" "${output_app}"; do
  codesign -d --entitlements - "${signed_path}" 2>&1 \
    | grep "app-proxy-provider-systemextension" >/dev/null
  codesign -d --entitlements - "${signed_path}" 2>&1 \
    | grep "${application_group}" >/dev/null
done

echo "${output_app}"
