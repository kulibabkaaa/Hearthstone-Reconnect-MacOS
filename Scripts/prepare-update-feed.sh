#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
version="$(
  awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
build_number="$(
  awk '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
archive="${1:-${project_dir}/dist/HS-Reconnect-${version}.zip}"
notes="${2:-${project_dir}/RELEASE_NOTES_${version}.md}"
appcast="${project_dir}/docs/appcast.xml"
release_url="https://github.com/kulibabkaaa/Hearthstone-Reconnect-MacOS/releases/download/v${version}/HS-Reconnect-${version}.zip"

[[ -f "${archive}" ]] || {
  echo "Update archive not found: ${archive}" >&2
  exit 1
}
[[ -f "${notes}" ]] || {
  echo "Release notes not found: ${notes}" >&2
  exit 1
}

"${script_dir}/check-update-build.sh" \
  "${build_number}" \
  "${archive}" \
  "${appcast}"

"${script_dir}/verify-update-archive.sh" \
  "${archive}" \
  --require-notarization

sign_update="${SPARKLE_SIGN_UPDATE:-$(
  find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
    -type f -perm -111 -print -quit
)}"
[[ -x "${sign_update}" ]] || {
  echo "Sparkle sign_update was not found. Build the app once first." >&2
  exit 1
}

generate_keys="${SPARKLE_GENERATE_KEYS:-${sign_update:h}/generate_keys}"
[[ -x "${generate_keys}" ]] || {
  echo "Sparkle generate_keys was not found next to sign_update." >&2
  exit 1
}
configured_public_key="$(
  awk '/SUPublicEDKey:/ { gsub(/"/, "", $2); print $2; exit }' \
    "${project_dir}/project.yml"
)"
keychain_public_key="$("${generate_keys}" -p | tail -n 1 | tr -d '\r\n')"
[[ -n "${configured_public_key}" ]] || {
  echo "The configured Sparkle public key is missing." >&2
  exit 1
}
[[ "${keychain_public_key}" == "${configured_public_key}" ]] || {
  echo "The Sparkle Keychain key does not match SUPublicEDKey." >&2
  exit 1
}

raw_signature_attributes="$("${sign_update}" "${archive}")"
signature_attributes="$(
  "${script_dir}/validate-sign-update-output.sh" \
    "${archive}" \
    "${raw_signature_attributes}"
)"

escaped_notes="$(
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    "${notes}"
)"
publication_date="$(LC_ALL=C date -R)"
temporary_appcast="$(mktemp /tmp/hs-reconnect-appcast.XXXXXX)"
trap 'rm -f -- "${temporary_appcast}"' EXIT

cat > "${temporary_appcast}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>HS Reconnect Updates</title>
    <link>https://kulibabkaaa.github.io/Hearthstone-Reconnect-MacOS/</link>
    <description>Signed updates for HS Reconnect.</description>
    <language>en</language>
    <item>
      <title>Version ${version}</title>
      <pubDate>${publication_date}</pubDate>
      <sparkle:version>${build_number}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre>${escaped_notes}</pre>]]></description>
      <enclosure url="${release_url}" type="application/octet-stream" ${signature_attributes} />
    </item>
  </channel>
</rss>
EOF

xmllint --noout "${temporary_appcast}"
SPARKLE_SIGN_UPDATE="${sign_update}" \
  "${script_dir}/verify-update-feed.sh" "${archive}" "${temporary_appcast}"
ditto "${temporary_appcast}" "${appcast}"

echo "${appcast}"
