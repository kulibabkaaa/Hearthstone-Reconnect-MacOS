#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
version="$(
  awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
target="${2:-${project_dir}/dist/HS-Reconnect-${version}.dmg}"
profile="${NOTARY_PROFILE:-HSReconnect-Notary}"
mode="${1:-}"

case "${mode}" in
  submit)
    [[ -f "${target}" ]] || {
      echo "Release artifact not found: ${target}" >&2
      exit 1
    }
    xcrun notarytool submit "${target}" \
      --keychain-profile "${profile}" \
      --output-format json
    ;;
  finish)
    submission_id="${3:-}"
    [[ -n "${submission_id}" ]] || {
      echo "Provide the notarization submission ID." >&2
      exit 1
    }
    info="$(
      xcrun notarytool info "${submission_id}" \
        --keychain-profile "${profile}" \
        --output-format json
    )"
    print -r -- "${info}"
    submission_status="$(
      print -r -- "${info}" \
        | plutil -extract status raw -o - -
    )"
    [[ "${submission_status}" == "Accepted" ]] || {
      [[ "${submission_status}" == "In Progress" ]] \
        && echo "Apple is still processing the disk image." >&2
      [[ "${submission_status}" != "In Progress" ]] \
        && xcrun notarytool log "${submission_id}" \
          --keychain-profile "${profile}" \
        || true
      exit 1
    }
    case "${target:e}" in
      pkg)
        xcrun stapler staple "${target}"
        xcrun stapler validate "${target}"
        pkgutil --check-signature "${target}"
        spctl --assess --type install --verbose=2 "${target}"
        ;;
      dmg)
        xcrun stapler staple "${target}"
        xcrun stapler validate "${target}"
        spctl --assess \
          --type open \
          --context context:primary-signature \
          --verbose=2 \
          "${target}"
        ;;
      zip)
        "${project_dir}/Scripts/verify-update-archive.sh" \
          "${target}" \
          --require-notarization
        ;;
      *)
        echo "Unsupported release artifact: ${target}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Usage: $0 submit [PKG_ZIP_OR_DMG]" >&2
    echo "       $0 finish [PKG_ZIP_OR_DMG] SUBMISSION_ID" >&2
    exit 1
    ;;
esac
