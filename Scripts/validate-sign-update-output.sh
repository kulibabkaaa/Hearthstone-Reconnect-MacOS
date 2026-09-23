#!/bin/zsh
set -euo pipefail

package="${1:?Provide the signed update package.}"
attributes="${2:?Provide the sign_update attributes.}"

[[ -f "${package}" ]] || {
  echo "Update package not found: ${package}" >&2
  exit 1
}

temporary_xml="$(mktemp /tmp/hs-reconnect-signature-attributes.XXXXXX)"
cleanup() {
  rm -f -- "${temporary_xml}"
}
trap cleanup EXIT

print -r -- \
  "<enclosure xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\" ${attributes} />" \
  > "${temporary_xml}"
xmllint --noout "${temporary_xml}" 2>/dev/null || {
  echo "Sparkle returned malformed signing attributes." >&2
  exit 1
}

attribute_count="$(xmllint --xpath 'count(/*/@*)' "${temporary_xml}")"
signature="$(
  xmllint --xpath \
    "string(/*/@*[local-name()='edSignature'])" \
    "${temporary_xml}"
)"
signed_length="$(xmllint --xpath 'string(/*/@length)' "${temporary_xml}")"
[[ "${attribute_count}" == 2 && -n "${signature}" && "${signed_length}" == <-> ]] || {
  echo "Sparkle must return one EdDSA signature and one package length." >&2
  exit 1
}

actual_length="$(/usr/bin/stat -f %z "${package}")"
[[ "${signed_length}" == "${actual_length}" ]] || {
  echo "Sparkle signed length ${signed_length} does not match ${actual_length}." >&2
  exit 1
}

print -r -- "sparkle:edSignature=\"${signature}\" length=\"${signed_length}\""
