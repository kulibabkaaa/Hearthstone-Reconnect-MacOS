#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
version="$(
  awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
dmg="${1:-${project_dir}/dist/HS-Reconnect-${version}.dmg}"
package="${2:-${project_dir}/dist/HS-Reconnect-${version}.pkg}"

"${project_dir}/Scripts/verify-vendor.sh"
swift test --package-path "${project_dir}"
"${project_dir}/Tests/Packaging/run-tests.sh"
"${project_dir}/Tests/ReleaseContract/run-tests.sh"
"${project_dir}/Tests/ReleaseValidation/run-tests.sh"

zsh -n \
  "${project_dir}"/Scripts/*.sh \
  "${project_dir}"/Scripts/Installer/*

"${project_dir}/Scripts/verify-dmg-contents.sh" "${dmg}"
"${project_dir}/Scripts/verify-update-feed.sh" \
  "${package}" \
  "${project_dir}/docs/appcast.xml"

xcrun stapler validate "${dmg}"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=2 \
  "${dmg}"

echo "Release verification passed."
