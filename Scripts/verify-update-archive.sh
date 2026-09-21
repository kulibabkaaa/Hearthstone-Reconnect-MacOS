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
archive="${1:-${project_dir}/dist/HS-Reconnect-${version}.zip}"
require_notarization="${2:-}"

[[ -f "${archive}" ]] || {
  echo "Sparkle update archive not found: ${archive}" >&2
  exit 1
}

temporary_dir="$(mktemp -d /private/tmp/hs-reconnect-update-archive.XXXXXX)"
cleanup() {
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT

ditto -x -k "${archive}" "${temporary_dir}"
apps=("${temporary_dir}"/*.app(N))
[[ "${#apps[@]}" == 1 ]] || {
  echo "Sparkle archive must contain exactly one top-level app." >&2
  exit 1
}
app="${apps[1]}"
info="${app}/Contents/Info.plist"
[[ -f "${info}" ]] || {
  echo "Sparkle archive app Info.plist is missing." >&2
  exit 1
}

archive_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info}")"
archive_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info}")"
[[ "${archive_build}" == "${build_number}" ]] || {
  echo "Archive build ${archive_build} does not match project build ${build_number}." >&2
  exit 1
}
[[ "${archive_version}" == "${version}" ]] || {
  echo "Archive version ${archive_version} does not match project version ${version}." >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "${app}"
if [[ "${require_notarization}" == "--require-notarization" ]]; then
  spctl --assess --type execute --verbose=2 "${app}"
fi

echo "Sparkle update archive verified."
