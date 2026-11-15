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

archive="${fixture_dir}/HS-Reconnect-${version}.zip"
appcast="${fixture_dir}/appcast.xml"
fake_sign_update="${fixture_dir}/sign_update"
fake_generate_keys="${fixture_dir}/generate_keys"
archive_root="${fixture_dir}/archive-root"
app="${archive_root}/HS Reconnect.app"
mkdir -p "${app}/Contents/MacOS"
cat > "${app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>HS Reconnect</string>
  <key>CFBundleIdentifier</key><string>io.github.kulibabkaaa.HSReconnect</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build_number}</string>
  <key>SUPublicEDKey</key><string>${public_key}</string>
</dict></plist>
PLIST
cat > "${app}/Contents/MacOS/HS Reconnect" <<'APP_EXECUTABLE'
#!/bin/zsh
exit 0
APP_EXECUTABLE
chmod 755 "${app}/Contents/MacOS/HS Reconnect"
codesign --force --sign - "${app}" >/dev/null 2>&1
ditto -c -k --keepParent "${app}" "${archive}"

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
    <enclosure url="https://github.com/kulibabkaaa/Hearthstone-Reconnect-MacOS/releases/download/v${version}/HS-Reconnect-${version}.zip" length="${length}" sparkle:edSignature="${signature}" />
  </item></channel>
</rss>
EOF
}

archive_length="$(/usr/bin/stat -f %z "${archive}")"
archive_signature="$(/usr/bin/shasum -a 256 "${archive}" | /usr/bin/awk '{ print $1 }')"
combined_attributes="sparkle:edSignature=\"${archive_signature}\" length=\"${archive_length}\""
normalized_attributes="$(
  "${project_dir}/Scripts/validate-sign-update-output.sh" \
    "${archive}" \
    "${combined_attributes}"
)"
[[ "${normalized_attributes}" == "${combined_attributes}" ]] \
  || fail "valid Sparkle signing attributes were not preserved"
[[ "$(print -r -- "${normalized_attributes}" | /usr/bin/grep -o ' length=' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 ]] \
  || fail "Sparkle signing attributes contain more than one length"
if "${project_dir}/Scripts/validate-sign-update-output.sh" \
  "${archive}" \
  "${combined_attributes} length=\"${archive_length}\"" >/dev/null 2>&1; then
  fail "duplicate Sparkle length attributes were accepted"
fi
write_appcast "${build_number}" "${archive_length}" "${archive_signature}"

HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/verify-update-feed.sh" \
  "${archive}" "${appcast}" >/dev/null
HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${archive}" "${appcast}" >/dev/null

write_appcast "${build_number}" "${archive_length}" "${archive_signature}0"
if HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/verify-update-feed.sh" \
  "${archive}" "${appcast}" >/dev/null 2>&1; then
  fail "appcast verification accepted an invalid archive signature"
fi
if HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${archive}" "${appcast}" >/dev/null 2>&1; then
  fail "the build guard accepted a reused build for a different archive"
fi

write_appcast "${next_build}" "${archive_length}" "${archive_signature}"
if HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${archive}" "${appcast}" >/dev/null 2>&1; then
  fail "the build guard accepted a build older than the appcast"
fi

write_appcast "${previous_build}" "${archive_length}" "${archive_signature}"
HS_RECONNECT_TEST_PUBLIC_KEY="${public_key}" \
  SPARKLE_SIGN_UPDATE="${fake_sign_update}" \
  "${project_dir}/Scripts/check-update-build.sh" \
  "${build_number}" "${archive}" "${appcast}" >/dev/null

# --- HearthMirror must never ship -------------------------------------------------------------
# HearthSim asked us to stop distributing HearthMirror. These tests pin every guard: the file
# scanner, the archive check, the release/local build switches and the vendor check in CI.
hm_checker="${project_dir}/Scripts/verify-no-hearthmirror.sh"

expect_forbidden() {
  local label="$1"
  local folder="$2"
  local output
  if output="$("${hm_checker}" "${folder}" 2>&1)"; then
    fail "the HearthMirror check accepted ${label}"
  fi
  [[ "${output}" == *FORBIDDEN* ]] \
    || fail "the HearthMirror check failed for ${label} without a clear message"
}

make_clean_helper_app() {
  local root="$1"
  mkdir -p "${root}/HS Reconnect.app/Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app/Contents/MacOS"
  print -r -- "own reader" > "${root}/HS Reconnect.app/Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app/Contents/MacOS/HS Reconnect Lobby Capture Probe"
}

clean_tree="${fixture_dir}/hm-clean"
make_clean_helper_app "${clean_tree}"
"${hm_checker}" "${clean_tree}" >/dev/null \
  || fail "the HearthMirror check rejected a helper app that has only its own binary"
[[ "$("${hm_checker}" 2>&1 >/dev/null; print -r -- $?)" == *2 ]] \
  || fail "the HearthMirror check must refuse to run without a path"
if "${hm_checker}" "${fixture_dir}/does-not-exist" >/dev/null 2>&1; then
  fail "the HearthMirror check accepted a path that does not exist"
fi

helper_rel="HS Reconnect.app/Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app"
forbidden_paths=(
  "Contents/Frameworks/HearthMirror.framework/Versions/A/HearthMirror"
  "Contents/Frameworks/hearthmirror.framework/Versions/A/Resources/Info.plist"
  "Contents/Frameworks/libcoreclr.dylib"
  "Contents/Frameworks/libSystem.Native.dylib"
  "Contents/Resources/HearthMirror-version.txt"
  "Contents/Resources/mono-version.txt"
  "Contents/Resources/CoreCLR-LICENSE.txt"
  "Contents/Resources/CoreCLR-THIRD-PARTY-NOTICES.txt"
  "Contents/Resources/HSTracker-LICENSE.txt"
  "Contents/Resources/Resources/Managed/arm64/System.Private.CoreLib.dll"
  "Contents/Resources/Resources/Managed/x64/Other.DLL"
  "Contents/MacOS/anything.dll"
)
for forbidden_path in "${forbidden_paths[@]}"; do
  tainted="${fixture_dir}/hm-tainted"
  rm -rf -- "${tainted}"
  make_clean_helper_app "${tainted}"
  mkdir -p "${tainted}/${helper_rel}/${forbidden_path:h}"
  print -r -- "x" > "${tainted}/${helper_rel}/${forbidden_path}"
  expect_forbidden "${forbidden_path}" "${tainted}"
done

# A symlink or folder with a forbidden name counts too, anywhere in the tree.
tainted="${fixture_dir}/hm-tainted-link"
rm -rf -- "${tainted}"
make_clean_helper_app "${tainted}"
ln -s /nonexistent "${tainted}/HS Reconnect.app/Contents/libcoreclr.dylib"
expect_forbidden "a symlink named libcoreclr.dylib" "${tainted}"

# A binary is rejected when it LINKS HearthMirror or CoreCLR, even under an innocent name.
link_dir="${fixture_dir}/hm-link"
mkdir -p "${link_dir}/src" "${link_dir}/tree"
print -r -- 'int hm(void){return 1;}' > "${link_dir}/src/hm.c"
print -r -- 'int hm(void);int main(void){return hm();}' > "${link_dir}/src/main.c"
/usr/bin/clang -dynamiclib "${link_dir}/src/hm.c" -o "${link_dir}/src/libfake.dylib" \
  -install_name '@rpath/HearthMirror.framework/Versions/A/HearthMirror'
/usr/bin/clang "${link_dir}/src/main.c" -o "${link_dir}/src/linked" \
  -L"${link_dir}/src" -lfake
/usr/bin/clang "${link_dir}/src/main.c" "${link_dir}/src/hm.c" -o "${link_dir}/src/plain"
cp "${link_dir}/src/plain" "${link_dir}/tree/Own Reader"
"${hm_checker}" "${link_dir}/tree" >/dev/null \
  || fail "the HearthMirror check rejected a plain binary that links nothing forbidden"
cp "${link_dir}/src/linked" "${link_dir}/tree/Innocent Name"
if link_output="$("${hm_checker}" "${link_dir}/tree" 2>&1)"; then
  fail "the HearthMirror check accepted a binary that links HearthMirror"
fi
[[ "${link_output}" == *"Innocent Name -> @rpath/HearthMirror.framework/Versions/A/HearthMirror"* ]] \
  || fail "the HearthMirror check rejected a linking binary without naming the library"
rm "${link_dir}/tree/Innocent Name"
# A renamed copy of a CoreCLR dylib is caught by its own install name.
/usr/bin/clang -dynamiclib "${link_dir}/src/hm.c" -o "${link_dir}/tree/renamed.dylib" \
  -install_name '@rpath/libcoreclr.dylib'
expect_forbidden "a renamed dylib whose install name is libcoreclr" "${link_dir}/tree"

# A zipped app that contains HearthMirror.framework is rejected by the archive verifier,
# while the same app without it passes (so the rejection is the new check, not the fixture).
clean_zip_root="${fixture_dir}/zip-clean"
mkdir -p "${clean_zip_root}"
ditto "${app}" "${clean_zip_root}/HS Reconnect.app"
clean_zip="${fixture_dir}/clean-with-helper.zip"
ditto -c -k --keepParent "${clean_zip_root}/HS Reconnect.app" "${clean_zip}"
"${project_dir}/Scripts/verify-update-archive.sh" "${clean_zip}" >/dev/null 2>&1 \
  || fail "the update archive verifier rejected the clean fixture app"

tainted_zip_root="${fixture_dir}/zip-tainted"
mkdir -p "${tainted_zip_root}"
ditto "${app}" "${tainted_zip_root}/HS Reconnect.app"
tainted_helper="${tainted_zip_root}/${helper_rel}"
mkdir -p \
  "${tainted_helper}/Contents/Frameworks/HearthMirror.framework/Versions/A" \
  "${tainted_helper}/Contents/MacOS"
print -r -- "closed binary" > "${tainted_helper}/Contents/Frameworks/HearthMirror.framework/Versions/A/HearthMirror"
print -r -- "own reader" > "${tainted_helper}/Contents/MacOS/HS Reconnect Lobby Capture Probe"
tainted_zip="${fixture_dir}/tainted-with-hearthmirror.zip"
ditto -c -k --keepParent "${tainted_zip_root}/HS Reconnect.app" "${tainted_zip}"
if archive_output="$("${project_dir}/Scripts/verify-update-archive.sh" "${tainted_zip}" 2>&1)"; then
  fail "the update archive verifier accepted an app containing HearthMirror.framework"
fi
[[ "${archive_output}" == *FORBIDDEN* && "${archive_output}" == *HearthMirror.framework* ]] \
  || fail "the update archive verifier rejected HearthMirror without naming it"

# build-release.sh refuses to start when either HearthMirror switch is set. It must stop
# at the very first step; with a bare PATH any later step would fail differently, so the
# message proves the guard (not some other failure) did the stopping.
for hm_switch in HS_RECONNECT_HEARTHMIRROR HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL; do
  if release_output="$(env -i PATH=/var/empty "${hm_switch}=YES" \
    /bin/zsh "${project_dir}/Scripts/build-release.sh" 2>&1)"; then
    fail "build-release.sh ran with ${hm_switch} set"
  fi
  [[ "${release_output}" == *"Refusing to build a release: ${hm_switch} is set"* ]] \
    || fail "build-release.sh did not refuse ${hm_switch} with a clear message"
done

# The release script never turns HearthMirror on, and scans the app and the installer.
release_script="${project_dir}/Scripts/build-release.sh"
if /usr/bin/grep -Eq '^[[:space:]]*export[[:space:]]+HS_RECONNECT_HEARTHMIRROR' "${release_script}"; then
  fail "build-release.sh exports HS_RECONNECT_HEARTHMIRROR"
fi
if /usr/bin/grep -q 'Vendor/HearthMirror' "${release_script}"; then
  fail "build-release.sh depends on a local Vendor/HearthMirror copy"
fi
/usr/bin/grep -Fq 'unset HS_RECONNECT_HEARTHMIRROR' "${release_script}" \
  || fail "build-release.sh does not clear HS_RECONNECT_HEARTHMIRROR before generating the project"
/usr/bin/grep -Fq 'verify-no-hearthmirror.sh" "${exported_app}"' "${release_script}" \
  || fail "build-release.sh does not scan the exported app for HearthMirror"
/usr/bin/grep -Fq 'verify-expanded-installer.sh' "${release_script}" \
  || fail "build-release.sh does not verify the expanded installer"
/usr/bin/grep -Fq 'verify-no-hearthmirror.sh' "${project_dir}/Scripts/verify-expanded-installer.sh" \
  || fail "the installer check does not scan for HearthMirror (it also covers the DMG)"
/usr/bin/grep -Fq 'verify-expanded-installer.sh' "${project_dir}/Scripts/verify-dmg-contents.sh" \
  || fail "the DMG check does not run the installer check that scans for HearthMirror"
/usr/bin/grep -Fq 'verify-no-hearthmirror.sh' "${project_dir}/Scripts/verify-update-archive.sh" \
  || fail "the update archive check does not scan for HearthMirror"
for release_check in verify-dmg-contents.sh verify-update-archive.sh; do
  /usr/bin/grep -Fq "${release_check}" "${project_dir}/Scripts/verify-release.sh" \
    || fail "verify-release.sh does not run ${release_check}"
done

# build-local.sh: HearthMirror is off unless HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL=YES.
local_script="${project_dir}/Scripts/build-local.sh"
/usr/bin/grep -Fq 'hearthmirror-local-optin.sh' "${local_script}" \
  || fail "build-local.sh does not use the HearthMirror opt-in"
# Any assignment of the switch (export, typeset, plain) outside the opt-in helper is a bypass.
for switch_script in "${local_script}" "${release_script}"; do
  if /usr/bin/grep -Eq 'HS_RECONNECT_HEARTHMIRROR[[:space:]]*=' "${switch_script}"; then
    fail "${switch_script:t} assigns HS_RECONNECT_HEARTHMIRROR itself"
  fi
done
/usr/bin/grep -Fq 'LOCAL-HEARTHMIRROR-DO-NOT-SHARE' "${local_script}" \
  || fail "build-local.sh does not rename a HearthMirror build so it cannot pass for a release file"
/usr/bin/grep -Fq -- '-n "${installer_identity}" && "${hearthmirror_local_build}" != "true"' "${local_script}" \
  || fail "build-local.sh may package a HearthMirror build as an installer"

fake_project="${fixture_dir}/fake-project"
mkdir -p "${fake_project}/Vendor/HearthMirror" "${fixture_dir}/empty-project"
optin="${project_dir}/Scripts/hearthmirror-local-optin.sh"
run_optin() {
  # $1 project dir; the rest are environment assignments for the child shell.
  local dir="$1"
  shift
  env -i PATH=/usr/bin:/bin "$@" /bin/zsh -c '
    source "$1"
    configure_hearthmirror_for_local_build "$2" || { print -r -- "STATUS=failed"; exit 0; }
    print -r -- "STATUS=ok MODE=${hearthmirror_local_build} SWITCH=${HS_RECONNECT_HEARTHMIRROR:-unset}"
  ' _ "${optin}" "${dir}" 2>&1
}

[[ "$(run_optin "${fake_project}")" == "STATUS=ok MODE=false SWITCH=unset" ]] \
  || fail "HearthMirror is not off by default when Vendor/HearthMirror exists"
[[ "$(run_optin "${fake_project}" HS_RECONNECT_HEARTHMIRROR=YES)" == "STATUS=ok MODE=false SWITCH=unset" ]] \
  || fail "an inherited HS_RECONNECT_HEARTHMIRROR leaked into a local build"
for not_optin in yes 1 true NO ""; do
  [[ "$(run_optin "${fake_project}" "HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL=${not_optin}")" == "STATUS=ok MODE=false SWITCH=unset" ]] \
    || fail "HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL=${not_optin} turned HearthMirror on"
done
optin_output="$(run_optin "${fake_project}" HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL=YES)"
[[ "${optin_output}" == *"STATUS=ok MODE=true SWITCH=YES"* ]] \
  || fail "the explicit opt-in did not turn HearthMirror on"
[[ "${optin_output}" == *WARNING* && "${optin_output}" == *"NEVER share"* ]] \
  || fail "the opt-in did not print the never-share warning"
[[ "$(run_optin "${fixture_dir}/empty-project" HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL=YES)" == *"STATUS=failed" ]] \
  || fail "the opt-in without a local HearthMirror copy must fail"

# CI runs the vendor check with --if-present; it must pass when HearthMirror is absent
# (the normal state of a checkout) and still fail when a required copy is incomplete.
HS_RECONNECT_VENDOR_DIR="${fixture_dir}/no-such-vendor" \
  "${project_dir}/Scripts/verify-vendor.sh" --if-present >/dev/null \
  || fail "verify-vendor.sh --if-present failed although HearthMirror is absent"
if HS_RECONNECT_VENDOR_DIR="${fixture_dir}/no-such-vendor" \
  "${project_dir}/Scripts/verify-vendor.sh" >/dev/null 2>&1; then
  fail "verify-vendor.sh without --if-present accepted a missing vendor folder"
fi
/usr/bin/grep -Fq 'verify-vendor.sh" --if-present' "${project_dir}/Scripts/verify-release.sh" \
  || fail "verify-release.sh must not require a local HearthMirror copy"
if /usr/bin/grep -Eq 'verify-vendor\.sh"?$' "${release_script}"; then
  fail "build-release.sh requires a local HearthMirror copy"
fi

echo "Release validation tests passed."
