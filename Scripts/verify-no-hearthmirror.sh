#!/bin/zsh
# Fails if a release tree contains any file from HearthSim's closed HearthMirror runtime.
#
# HearthSim asked us (Oct and Nov 2026) to stop distributing HearthMirror, so no
# release app, installer payload, DMG or update archive may carry it. This checks
# file NAMES anywhere under the given folder, not whether the lobby helper app exists:
# our own reader will live in an app with the same name.
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
done

if [[ "${found}" == "true" ]]; then
  echo "HearthSim asked us to stop distributing HearthMirror. A release must never contain these files." >&2
  exit 1
fi

echo "No HearthMirror files found."
