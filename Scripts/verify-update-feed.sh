#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
version="$(
  awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
build_number="$(
  awk '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
package="${1:-${project_dir}/dist/HS-Reconnect-${version}.pkg}"
appcast="${2:-${project_dir}/docs/appcast.xml}"

[[ -f "${package}" ]] || {
  echo "Update package not found: ${package}" >&2
  exit 1
}
[[ -f "${appcast}" ]] || {
  echo "Update appcast not found: ${appcast}" >&2
  exit 1
}

xmllint --noout "${appcast}"

xml_value() {
  xmllint --xpath "string($1)" "${appcast}"
}

feed_build="$(xml_value "(//*[local-name()='item'])[1]/*[local-name()='version'][1]")"
feed_version="$(xml_value "(//*[local-name()='item'])[1]/*[local-name()='shortVersionString'][1]")"
feed_url="$(xml_value "(//*[local-name()='item'])[1]/*[local-name()='enclosure'][1]/@url")"
feed_length="$(xml_value "(//*[local-name()='item'])[1]/*[local-name()='enclosure'][1]/@length")"
feed_signature="$(xml_value "(//*[local-name()='item'])[1]/*[local-name()='enclosure'][1]/@*[local-name()='edSignature']")"

[[ "${feed_build}" == "${build_number}" ]] || {
  echo "Appcast build ${feed_build:-<missing>} does not match project build ${build_number}." >&2
  exit 1
}
[[ "${feed_version}" == "${version}" ]] || {
  echo "Appcast version ${feed_version:-<missing>} does not match project version ${version}." >&2
  exit 1
}
expected_url="https://github.com/kulibabkaaa/Hearthstone-Reconnect-MacOS/releases/download/v${version}/HS-Reconnect-${version}.pkg"
[[ "${feed_url}" == "${expected_url}" ]] || {
  echo "Appcast package URL does not match the final package." >&2
  exit 1
}
[[ "${feed_length}" == <-> ]] || {
  echo "Appcast package length is missing or invalid." >&2
  exit 1
}
actual_length="$(/usr/bin/stat -f %z "${package}")"
[[ "${feed_length}" == "${actual_length}" ]] || {
  echo "Appcast package length ${feed_length} does not match ${actual_length}." >&2
  exit 1
}
[[ -n "${feed_signature}" ]] || {
  echo "Appcast EdDSA signature is missing." >&2
  exit 1
}

temporary_dir="$(mktemp -d /tmp/hs-reconnect-update-check.XXXXXX)"
cleanup() {
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT
expanded_package="${temporary_dir}/expanded"
pkgutil --expand-full "${package}" "${expanded_package}"
app_info=(
  "${(@f)$(/usr/bin/find "${expanded_package}" \
    -path '*/HS Reconnect.app/Contents/Info.plist' -type f -print)}"
)
[[ "${#app_info[@]}" == 1 ]] || {
  echo "Update package must contain exactly one HS Reconnect app." >&2
  exit 1
}
package_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app_info[1]}")"
package_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_info[1]}")"
package_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${app_info[1]}")"
[[ "${package_build}" == "${build_number}" ]] || {
  echo "Package build ${package_build:-<missing>} does not match project build ${build_number}." >&2
  exit 1
}
[[ "${package_version}" == "${version}" ]] || {
  echo "Package version ${package_version:-<missing>} does not match project version ${version}." >&2
  exit 1
}

sign_update="${SPARKLE_SIGN_UPDATE:-$(
  find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
    -type f -perm -111 -print -quit
)}"
[[ -x "${sign_update}" ]] || {
  echo "Sparkle sign_update was not found. Build the app once first." >&2
  exit 1
}
generate_keys="${SPARKLE_GENERATE_KEYS:-${sign_update:h}/generate_keys}"
[[ -x "${generate_keys}" ]] || {
  echo "Sparkle generate_keys was not found next to sign_update." >&2
  exit 1
}
configured_public_key="$(
  awk '/SUPublicEDKey:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
keychain_public_key="$("${generate_keys}" -p | tail -n 1 | tr -d '\r\n')"
[[ -n "${configured_public_key}" ]] || {
  echo "The configured Sparkle public key is missing." >&2
  exit 1
}
[[ "${keychain_public_key}" == "${configured_public_key}" ]] || {
  echo "The Sparkle verification key does not match SUPublicEDKey." >&2
  exit 1
}
[[ "${package_public_key}" == "${configured_public_key}" ]] || {
  echo "The packaged Sparkle public key does not match SUPublicEDKey." >&2
  exit 1
}
"${sign_update}" --verify "${package}" "${feed_signature}"

echo "Sparkle appcast matches the final update package."
