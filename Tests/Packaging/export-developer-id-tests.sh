#!/bin/zsh
# Contract tests for Scripts/export-developer-id.sh using stand-in `codesign` and `security`
# tools, so nothing is really signed. Run from Tests/Packaging/run-tests.sh.
#
# Covered: the lobby helper is optional (absent, or present with only our own reader); a helper
# that carries HearthMirror, links it, or lacks the debugger entitlement is refused.
set -euo pipefail

project_dir="${0:A:h:h:h}"
fixture_dir="$(mktemp -d /tmp/hs-reconnect-export-tests.XXXXXX)"
trap 'rm -rf -- "${fixture_dir}"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

team="D8KUYWS8JN"
host_id="io.github.kulibabkaaa.HSReconnect"
group="${team}.${host_id}"
helper_rel="Contents/Library/LoginItems/HS Reconnect Lobby Capture Probe.app"

# --- stand-in tools -----------------------------------------------------------------------
shim="${fixture_dir}/shim"
mkdir -p "${shim}"
cat > "${shim}/security" <<'SECURITY'
#!/bin/zsh
case "${1:-}" in
  find-identity) print -r -- '  1) ABCDEF "Developer ID Application: Test (D8KUYWS8JN)"' ;;
  cms) cat "${4:?}" ;;   # security cms -D -i PROFILE: the fixture profiles are already plain plists
  *) exit 1 ;;
esac
SECURITY
cat > "${shim}/codesign" <<'CODESIGN'
#!/bin/zsh
set -euo pipefail
group="D8KUYWS8JN.io.github.kulibabkaaa.HSReconnect"
entitlement_xml() {  # $1 = path of the signed thing
  print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
  print -r -- '<key>com.apple.developer.networking.networkextension</key><array><string>app-proxy-provider-systemextension</string></array>'
  print -r -- "<key>com.apple.security.application-groups</key><array><string>${group}</string></array>"
  print -r -- '<key>com.apple.security.get-task-allow</key><true/>'
  if [[ "$1" == *"Lobby Capture Probe"* && -z "${FAKE_NO_DEBUGGER:-}" ]]; then
    print -r -- '<key>com.apple.security.cs.debugger</key><true/>'
  fi
  print -r -- '</dict></plist>'
}
# Like the real tool, refuse a target that does not exist.
[[ -e "${@[-1]}" ]] || { echo "codesign: ${@[-1]}: No such file or directory" >&2; exit 1; }
case "${1:-}" in
  --verify) exit 0 ;;
  -dv)
    print -r -- "VERIFY ${@[-1]}" >> "${FAKE_CODESIGN_LOG:?}"
    echo "Authority=Developer ID Application: Test (D8KUYWS8JN)" >&2 ;;
  -d)
    [[ "${2:-}" == "--entitlements" ]] || exit 1
    if [[ "${3:-}" == "-" ]]; then
      # Show what was embedded if the target was signed with --entitlements, as the real tool does.
      embedded="${FAKE_CODESIGN_LOG:?}.state/$(print -r -- "${4:?}" | /usr/bin/shasum | /usr/bin/cut -c1-16)"
      if [[ -f "${embedded}" ]]; then
        /usr/bin/tr '<>' '\n\n' < "${embedded}"
      else
        entitlement_xml "${4:?}" | /usr/bin/tr '<>' '\n\n'
      fi
    else
      entitlement_xml "${@[-1]}" > "${3:?}"
    fi ;;
  --force)
    # Record the entitlements file the way the real tool would embed it.
    task_allow=n/a
    if (( ${@[(Ie)--entitlements]} )); then
      entitlements_file="${@[$(( ${@[(Ie)--entitlements]} + 1 ))]}"
      [[ -f "${entitlements_file}" ]] || exit 1
      task_allow="$(/usr/bin/grep -c 'get-task-allow' "${entitlements_file}" || true)"
      mkdir -p "${FAKE_CODESIGN_LOG:?}.state"
      cp "${entitlements_file}" "${FAKE_CODESIGN_LOG}.state/$(print -r -- "${@[-1]}" | /usr/bin/shasum | /usr/bin/cut -c1-16)"
    fi
    print -r -- "SIGN ${*} [task-allow=${task_allow}]" >> "${FAKE_CODESIGN_LOG:?}" ;;
  *) exit 1 ;;
esac
CODESIGN
chmod 755 "${shim}/security" "${shim}/codesign"

# --- fixture archive ----------------------------------------------------------------------
profiles="${fixture_dir}/profiles"
mkdir -p "${profiles}"
write_profile() {
  cat > "${profiles}/$1.provisionprofile" <<PROFILE
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Name</key><string>Direct $1</string>
<key>Entitlements</key><dict>
<key>com.apple.application-identifier</key><string>${team}.$2</string>
<key>com.apple.developer.networking.networkextension</key><array><string>app-proxy-provider-systemextension</string></array>
<key>com.apple.security.application-groups</key><array><string>${group}</string></array>
</dict></dict></plist>
PROFILE
}
write_profile host "${host_id}"
write_profile extension "${host_id}.ProxyExtension"

# A real Mach-O that links a library named like HearthMirror (library deleted afterwards).
cc_dir="${fixture_dir}/cc"
mkdir -p "${cc_dir}"
print -r -- 'int hm(void){return 1;}' > "${cc_dir}/hm.c"
print -r -- 'int hm(void);int main(void){return hm();}' > "${cc_dir}/main.c"
/usr/bin/clang -dynamiclib "${cc_dir}/hm.c" -o "${cc_dir}/libfake.dylib" \
  -install_name '@rpath/HearthMirror.framework/Versions/A/HearthMirror'
/usr/bin/clang "${cc_dir}/main.c" -o "${cc_dir}/linked-reader" -L"${cc_dir}" -lfake
/usr/bin/clang "${cc_dir}/main.c" "${cc_dir}/hm.c" -o "${cc_dir}/own-reader"

make_archive() {  # $1 = archive dir, $2 = helper kind: none | own | hearthmirror | linked
  local archive="$1" kind="$2"
  local app="${archive}/Products/Applications/HS Reconnect.app"
  local sparkle="${app}/Contents/Frameworks/Sparkle.framework/Versions/B"
  mkdir -p \
    "${app}/Contents/Library/SystemExtensions/${host_id}.ProxyExtension.systemextension/Contents/MacOS" \
    "${app}/Contents/Library/LoginItems/HS Reconnect Watcher.app/Contents/MacOS" \
    "${sparkle}/Updater.app" "${sparkle}/XPCServices/Downloader.xpc" "${sparkle}/XPCServices/Installer.xpc"
  print -r -- x > "${sparkle}/Autoupdate"
  case "${kind}" in
    none) ;;
    own|hearthmirror|linked)
      mkdir -p "${app}/${helper_rel}/Contents/MacOS"
      cp "${cc_dir}/own-reader" "${app}/${helper_rel}/Contents/MacOS/HS Reconnect Lobby Capture Probe"
      ;;
  esac
  if [[ "${kind}" == "hearthmirror" ]]; then
    mkdir -p "${app}/${helper_rel}/Contents/Frameworks/HearthMirror.framework/Versions/A"
    print -r -- closed > "${app}/${helper_rel}/Contents/Frameworks/HearthMirror.framework/Versions/A/HearthMirror"
  fi
  if [[ "${kind}" == "linked" ]]; then
    # Renamed binary: only its linked-library list gives it away.
    cp "${cc_dir}/linked-reader" "${app}/${helper_rel}/Contents/MacOS/HS Reconnect Lobby Capture Probe"
  fi
}

run_export() {  # $1 = case name; extra environment assignments follow. Sets export_output/export_status.
  local name="$1"
  shift
  export_log="${fixture_dir}/${name}-codesign.log"
  : > "${export_log}"
  export_status=0
  export_output="$(
    env "$@" \
      PATH="${shim}:${PATH}" \
      FAKE_CODESIGN_LOG="${export_log}" \
      APPLICATION_SIGNING_IDENTITY="Developer ID Application: Test (D8KUYWS8JN)" \
      PROVISIONING_PROFILE_DIR="${profiles}" \
      /bin/zsh "${project_dir}/Scripts/export-developer-id.sh" \
        "${fixture_dir}/${name}.xcarchive" "${fixture_dir}/${name}-out/HS Reconnect.app" 2>&1
  )" || export_status=$?
}

# 1. No helper at all: the export succeeds and never touches a helper.
make_archive "${fixture_dir}/absent.xcarchive" none
run_export absent
[[ "${export_status}" == 0 ]] \
  || fail "the exporter failed when the lobby helper is absent: ${export_output}"
[[ "$(<"${export_log}")" != *"Lobby Capture Probe"* ]] \
  || fail "the exporter signed a lobby helper that does not exist"

# 2. Helper present with only our own reader: signed with its debugger entitlement.
make_archive "${fixture_dir}/own.xcarchive" own
run_export own
[[ "${export_status}" == 0 ]] \
  || fail "the exporter rejected a helper that has no HearthMirror files: ${export_output}"
/usr/bin/grep -F 'SIGN' "${export_log}" | /usr/bin/grep -F 'Lobby Capture Probe.app' \
  | /usr/bin/grep -Fq -- '--entitlements' \
  || fail "the exporter did not sign the present helper with its entitlements"
/usr/bin/grep -F 'SIGN' "${export_log}" | /usr/bin/grep -F 'Lobby Capture Probe.app' \
  | /usr/bin/grep -Fq '[task-allow=0]' \
  || fail "the exporter left get-task-allow in the helper's entitlements"
/usr/bin/grep -Eq '^VERIFY .*Lobby Capture Probe\.app$' "${export_log}" \
  || fail "the exporter did not check the present helper's signature"

# 3. Helper present but missing the debugger entitlement: refused.
make_archive "${fixture_dir}/nodebugger.xcarchive" own
run_export nodebugger FAKE_NO_DEBUGGER=1
[[ "${export_status}" != 0 && "${export_output}" == *"lost its debugger entitlement"* ]] \
  || fail "the exporter accepted a helper without the debugger entitlement"

# 4. Helper carrying HearthMirror.framework: refused before anything is signed.
make_archive "${fixture_dir}/hearthmirror.xcarchive" hearthmirror
run_export hearthmirror
[[ "${export_status}" != 0 && "${export_output}" == *FORBIDDEN*HearthMirror* ]] \
  || fail "the exporter accepted a helper containing HearthMirror.framework"
[[ ! -s "${export_log}" ]] \
  || fail "the exporter signed an app that contains HearthMirror"

# 5. A renamed binary that links HearthMirror is refused too.
make_archive "${fixture_dir}/linked.xcarchive" linked
run_export linked
[[ "${export_status}" != 0 && "${export_output}" == *"link HearthMirror"* ]] \
  || fail "the exporter accepted a binary that links HearthMirror"

# 6. The exporter no longer names any HearthMirror/CoreCLR file as a requirement.
if /usr/bin/grep -Eiq 'libcoreclr|libSystem\.Native|HearthMirror\.framework|hearth_mirror_path' \
  "${project_dir}/Scripts/export-developer-id.sh"; then
  fail "export-developer-id.sh still refers to HearthMirror/CoreCLR files"
fi

echo "Developer ID export tests passed."
