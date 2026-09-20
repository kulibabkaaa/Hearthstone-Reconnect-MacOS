#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
vendor_dir="${HS_RECONNECT_VENDOR_DIR:-${script_dir:h}/Vendor/HearthMirror}"
manifest="${vendor_dir}/SHA256SUMS"
temporary_dir="$(mktemp -d /tmp/hs-reconnect-vendor-check.XXXXXX)"

cleanup() {
  rm -rf -- "${temporary_dir}"
}

trap cleanup EXIT

[[ -f "${manifest}" ]] || {
  echo "Missing vendored runtime checksum manifest: ${manifest}" >&2
  exit 1
}

if ! /usr/bin/awk '
  NF != 2 || $1 !~ /^[0-9a-f]{64}$/ || $2 ~ /^\// || $2 ~ /(^|\/)\.\.($|\/)/ {
    exit 1
  }
' "${manifest}"; then
  echo "Vendored runtime checksum manifest is malformed." >&2
  exit 1
fi

/usr/bin/awk '{ print $2 }' "${manifest}" \
  | LC_ALL=C /usr/bin/sort > "${temporary_dir}/manifest-inventory"

if [[ "$(/usr/bin/uniq -d "${temporary_dir}/manifest-inventory" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" != 0 ]]; then
  echo "Vendored runtime checksum manifest contains duplicate paths." >&2
  exit 1
fi

if /usr/bin/find "${vendor_dir}/Managed" -type l -print -quit \
  | /usr/bin/grep -q .; then
  echo "Vendored managed runtime must not contain symbolic links." >&2
  exit 1
fi

{
  print -r -- "HearthMirror.framework/Versions/A/HearthMirror"
  print -r -- "libcoreclr.dylib"
  print -r -- "libSystem.Native.dylib"
  (
    cd "${vendor_dir}"
    /usr/bin/find Managed -type f -print
  )
} | LC_ALL=C /usr/bin/sort > "${temporary_dir}/actual-inventory"

if ! /usr/bin/cmp -s \
  "${temporary_dir}/manifest-inventory" \
  "${temporary_dir}/actual-inventory"; then
  echo "Vendored runtime inventory does not exactly match SHA256SUMS." >&2
  /usr/bin/diff -u \
    "${temporary_dir}/manifest-inventory" \
    "${temporary_dir}/actual-inventory" >&2 || true
  exit 1
fi

(
  cd "${vendor_dir}"
  /usr/bin/shasum -a 256 -c SHA256SUMS
)

/usr/bin/find "${vendor_dir}/Managed/arm64" -type f -name '*.dll' -exec basename {} \; \
  | LC_ALL=C /usr/bin/sort > "${temporary_dir}/arm64-inventory"
/usr/bin/find "${vendor_dir}/Managed/x64" -type f -name '*.dll' -exec basename {} \; \
  | LC_ALL=C /usr/bin/sort > "${temporary_dir}/x64-inventory"
[[ -s "${temporary_dir}/arm64-inventory" ]] \
  && /usr/bin/cmp -s \
    "${temporary_dir}/arm64-inventory" \
    "${temporary_dir}/x64-inventory" || {
  echo "Vendored managed runtimes are incomplete or do not match by architecture." >&2
  exit 1
}

for required_file in NOTICE.md HSTracker-LICENSE.txt CoreCLR-LICENSE.txt CoreCLR-THIRD-PARTY-NOTICES.txt; do
  [[ -s "${vendor_dir}/${required_file}" ]] || {
    echo "Missing vendored runtime notice: ${required_file}" >&2
    exit 1
  }
done

echo "Vendored HearthMirror runtime verified."
