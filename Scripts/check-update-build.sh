#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_number="${1:?Provide the proposed build number.}"
package="${2:?Provide the final update package.}"
appcast="${3:-${project_dir}/docs/appcast.xml}"

[[ "${build_number}" == <-> ]] || {
  echo "The proposed build number is invalid: ${build_number}" >&2
  exit 1
}
[[ -f "${appcast}" ]] || exit 0

xmllint --noout "${appcast}"
existing_build="$(
  xmllint --xpath \
    "string((//*[local-name()='item'])[1]/*[local-name()='version'][1])" \
    "${appcast}"
)"
[[ "${existing_build}" == <-> ]] || {
  echo "The existing appcast build number is missing or invalid." >&2
  exit 1
}

if (( existing_build > build_number )); then
  echo "Build ${build_number} is older than published appcast build ${existing_build}." >&2
  exit 1
fi

if (( existing_build == build_number )); then
  if ! "${script_dir}/verify-update-feed.sh" "${package}" "${appcast}"; then
    echo "Build ${build_number} is already used by a different update package." >&2
    exit 1
  fi
fi
