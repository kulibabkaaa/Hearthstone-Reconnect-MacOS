#!/bin/zsh
# Fails if a release tree contains anything from HearthSim's closed HearthMirror runtime.
#
# HearthSim asked us (Oct and Nov 2026) to stop distributing HearthMirror, so no
# release app, installer payload, DMG or update archive may carry it. Two checks:
#   1. File NAMES anywhere under the folder (HearthMirror*, CoreCLR files, .NET .dll files).
#   2. Mach-O LINKS: any binary whose linked-library list (otool -L) names HearthMirror
#      or coreclr, even if the file was renamed.
# It checks files, not whether the lobby helper app exists: our own reader will live in an
# app with the same name.
#
# Usage: verify-no-hearthmirror.sh PATH [PATH...]   (an .app, an expanded package, any folder)
set -euo pipefail

(( $# >= 1 )) || {
  echo "Usage: verify-no-hearthmirror.sh PATH [PATH...]" >&2
  exit 2
}

# Case-insensitive name patterns (shell globs, as understood by find -iname).
forbidden_patterns=(
  'HearthMirror*'
  'libcoreclr*'
  'libSystem.Native*'
  'CoreCLR-*'
  'HSTracker-LICENSE*'
  'mono-version*'
  '*.dll'
)

find_args=()
for pattern in "${forbidden_patterns[@]}"; do
  (( ${#find_args} )) && find_args+=(-o)
  find_args+=(-iname "${pattern}")
done

# Prints "<file> -> <library>" for every Mach-O under $1 that links HearthMirror or CoreCLR.
linked_forbidden_libraries() {
  local root="$1" file kind libraries library
  for file in "${root}"/**/*(.ND); do
    kind="$(/usr/bin/file -b "${file}" 2>/dev/null || true)"
    [[ "${kind}" == *Mach-O* ]] || continue
    # A Mach-O that otool cannot read must not slip through as clean.
    # Read through stdin: otool treats a path ending in "(...)" as archive(member) and fails.
    libraries="$(/usr/bin/otool -L /dev/stdin < "${file}" 2>&1)" || {
      print -r -- "${file} -> (otool could not read this Mach-O)"
      continue
    }
    # otool exits 0 on a damaged Mach-O and prints an error line instead of the library list
    # (a library line is indented; an architecture header ends in ':'). Treat that as unreadable.
    if print -r -- "${libraries}" | /usr/bin/tail -n +2 \
      | /usr/bin/grep -v ':$' | /usr/bin/grep -v '^Archive :' | /usr/bin/grep -q '^[^[:space:]]'; then
      print -r -- "${file} -> (otool could not read this Mach-O)"
      continue
    fi
    # Line 1 of `otool -L` is the file's own path; the rest are install names (the file's own
    # id first for a dylib, then each linked library). Universal binaries repeat a header ending in ':'.
    print -r -- "${libraries}" \
      | /usr/bin/tail -n +2 \
      | { /usr/bin/grep -v ':$' | /usr/bin/grep -v '^Archive :' || true; } \
      | { /usr/bin/grep -iE 'hearthmirror|coreclr' || true; } \
      | /usr/bin/sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//' \
      | while IFS= read -r library; do
          print -r -- "${file} -> ${library}"
        done
  done
}

found=false
for root in "$@"; do
  [[ -d "${root}" ]] || {
    echo "verify-no-hearthmirror: not a folder: ${root}" >&2
    exit 2
  }
  matches="$(/usr/bin/find "${root}" \( "${find_args[@]}" \) -print)"
  if [[ -n "${matches}" ]]; then
    found=true
    total="$(print -r -- "${matches}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    echo "FORBIDDEN: ${total} HearthSim HearthMirror runtime file(s) found in ${root}:" >&2
    print -r -- "${matches}" | /usr/bin/sed -n '1,15p' | /usr/bin/sed 's/^/  /' >&2
    (( total > 15 )) && echo "  ... and $(( total - 15 )) more" >&2
  fi

  links="$(linked_forbidden_libraries "${root}")"
  if [[ -n "${links}" ]]; then
    found=true
    echo "FORBIDDEN: binaries in ${root} link HearthMirror or CoreCLR libraries:" >&2
    print -r -- "${links}" | /usr/bin/sed -n '1,15p' | /usr/bin/sed 's/^/  /' >&2
    link_total="$(print -r -- "${links}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    (( link_total > 15 )) && echo "  ... and $(( link_total - 15 )) more" >&2
  fi
done

if [[ "${found}" == "true" ]]; then
  echo "HearthSim asked us to stop distributing HearthMirror. A release must never contain these files." >&2
  exit 1
fi

echo "No HearthMirror files found."
