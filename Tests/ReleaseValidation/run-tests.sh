#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h:h}"
fixture_dir="$(mktemp -d /tmp/hs-reconnect-release-validation.XXXXXX)"

cleanup() {
  rm -rf -- "${fixture_dir}"
}

trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

version="$(
  /usr/bin/awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
build_number="$(
  /usr/bin/awk '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
public_key="$(
  /usr/bin/awk '/SUPublicEDKey:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
[[ "${build_number}" == <-> && "${build_number}" -gt 1 ]] \
  || fail "the project build number must be an integer greater than one"
[[ -n "${version}" && -n "${public_key}" ]] \
  || fail "the project release identity is incomplete"
previous_build="$(( build_number - 1 ))"
next_build="$(( build_number + 1 ))"

vendor="${fixture_dir}/vendor"
mkdir -p \
  "${vendor}/HearthMirror.framework/Versions/A" \
  "${vendor}/Managed/arm64" \
  "${vendor}/Managed/x64"
for file in \
  HearthMirror.framework/Versions/A/HearthMirror \
  libcoreclr.dylib \
  libSystem.Native.dylib \
  Managed/arm64/Test.dll \
  Managed/x64/Test.dll; do
  print -rn -- "trusted-${file}" > "${vendor}/${file}"
done
for notice in \
  NOTICE.md \
  HSTracker-LICENSE.txt \
  CoreCLR-LICENSE.txt \
  CoreCLR-THIRD-PARTY-NOTICES.txt; do
  print -r -- "notice" > "${vendor}/${notice}"
done
(
  cd "${vendor}"
  /usr/bin/shasum -a 256 \
    HearthMirror.framework/Versions/A/HearthMirror \
    libcoreclr.dylib \
    libSystem.Native.dylib \
    Managed/arm64/Test.dll \
    Managed/x64/Test.dll > SHA256SUMS
)

HS_RECONNECT_VENDOR_DIR="${vendor}" \
  "${project_dir}/Scripts/verify-vendor.sh" >/dev/null

print -r -- "unexpected" > "${vendor}/Managed/arm64/Extra.dll"
if HS_RECONNECT_VENDOR_DIR="${vendor}" \
  "${project_dir}/Scripts/verify-vendor.sh" >/dev/null 2>&1; then
  fail "vendor verification accepted an unlisted managed file"
fi
rm "${vendor}/Managed/arm64/Extra.dll"

ln -s Test.dll "${vendor}/Managed/arm64/Linked.dll"
if HS_RECONNECT_VENDOR_DIR="${vendor}" \
  "${project_dir}/Scripts/verify-vendor.sh" >/dev/null 2>&1; then
  fail "vendor verification accepted a managed DLL symlink"
fi
rm "${vendor}/Managed/arm64/Linked.dll"

print -r -- "tampered" > "${vendor}/Managed/arm64/Test.dll"
if HS_RECONNECT_VENDOR_DIR="${vendor}" \
  "${project_dir}/Scripts/verify-vendor.sh" >/dev/null 2>&1; then
  fail "vendor verification accepted a modified managed DLL"
fi

package="${fixture_dir}/HS-Reconnect-${version}.pkg"
appcast="${fixture_dir}/appcast.xml"
fake_sign_update="${fixture_dir}/sign_update"
fake_generate_keys="${fixture_dir}/generate_keys"
package_root="${fixture_dir}/package-root"
mkdir -p "${package_root}/Applications/HS Reconnect.app/Contents"
cat > "${package_root}/Applications/HS Reconnect.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.kulibabkaaa.HSReconnect</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build_number}</string>
  <key>SUPublicEDKey</key><string>${public_key}</string>
</dict></plist>
PLIST
pkgbuild \
  --root "${package_root}" \
  --identifier io.github.kulibabkaaa.HSReconnect.tests \
  --version "${version}" \
  "${package}" >/dev/null 2>&1

cat > "${fake_sign_update}" <<'SIGN_UPDATE'
#!/bin/zsh
set -euo pipefail
[[ "${1:-}" == "--verify" && $# == 3 ]] || exit 2
actual="$(/usr/bin/shasum -a 256 "${2}" | /usr/bin/awk '{ print $1 }')"
[[ "${actual}" == "${3}" ]]
SIGN_UPDATE
chmod 755 "${fake_sign_update}"
cat > "${fake_generate_keys}" <<'GENERATE_KEYS'
#!/bin/zsh
[[ "${1:-}" == "-p" ]] || exit 2
print -r -- "${HS_RECONNECT_TEST_PUBLIC_KEY:?}"
GENERATE_KEYS
chmod 755 "${fake_generate_keys}"

write_appcast() {
  local build="$1"
  local length="$2"
  local signature="$3"
  cat > "${appcast}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>${build}</sparkle:version>
    <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
    <enclosure url="https://github.com/kulibabkaaa/Hearthstone-Reconnect-MacOS/releases/download/v${version}/HS-Reconnect-${version}.pkg" length="${length}" sparkle:edSignature="${signature}" />
  </item></channel>
</rss>
EOF
}

package_length="$(/usr/bin/stat -f %z "${package}")"
package_signature="$(/usr/bin/shasum -a 256 "${package}" | /usr/bin/awk '{ print $1 }')"
combined_attributes="sparkle:edSignature=\"${package_signature}\" length=\"${package_length}\""
normalized_attributes="$(
  "${project_dir}/Scripts/validate-sign-update-output.sh" \
    "${package}" \
    "${combined_attributes}"
)"
[[ "${normalized_attributes}" == "${combined_attributes}" ]] \
  || fail "valid Sparkle signing attributes were not preserved"
[[ "$(print -r -- "${normalized_attributes}" | /usr/bin/grep -o ' length=' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 ]] \
  || fail "Sparkle signing attributes contain more than one length"
if "${project_dir}/Scripts/validate-sign-update-output.sh" \
  "${package}" \
  "${combined_attributes} length=\"${package_length}\"" >/dev/null 2>&1; then
  fail "duplicate Sparkle length attributes were accepted"
fi
write_appcast "${build_number}" "${package_length}" "${package_signature}"

HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/verify-update-feed.sh" \
  "${package}" "${appcast}" >/dev/null
HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${package}" "${appcast}" >/dev/null

write_appcast "${build_number}" "${package_length}" "${package_signature}0"
if HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/verify-update-feed.sh" \
  "${package}" "${appcast}" >/dev/null 2>&1; then
  fail "appcast verification accepted an invalid package signature"
fi
if HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${package}" "${appcast}" >/dev/null 2>&1; then
  fail "the build guard accepted a reused build for a different package"
fi

write_appcast "${next_build}" "${package_length}" "${package_signature}"
if HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${package}" "${appcast}" >/dev/null 2>&1; then
  fail "the build guard accepted a build older than the appcast"
fi

write_appcast "${previous_build}" "${package_length}" "${package_signature}"
HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${package}" "${appcast}" >/dev/null

echo "Release validation tests passed."
