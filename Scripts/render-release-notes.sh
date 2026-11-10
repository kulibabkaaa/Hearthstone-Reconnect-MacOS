#!/bin/zsh
# Turns RELEASE_NOTES_<version>.md into the HTML shown in Sparkle's update window.
#
# Sparkle renders an appcast item's <description> as HTML in a web view (JavaScript off). A full document with its
# own styles works in every Sparkle 2 version, unlike sparkle:format="markdown", which needs 2.9+ in the app that is
# doing the updating. So the notes stay one Markdown file and this makes the HTML from it.
#
# Understands what the notes use: one "# Title", "- " bullets (wrapped lines indented), paragraphs, **bold** and
# `code`. A bullet's short lead-in ("New:", "Fixed:", "How it works:") is set in bold. The last paragraph is the
# small print. Everything else is escaped, so the notes can never inject markup.
#
# Usage: render-release-notes.sh RELEASE_NOTES_<version>.md > notes.html
set -euo pipefail

notes="${1:?usage: render-release-notes.sh <release notes .md>}"
[[ -f "${notes}" ]] || {
  echo "Release notes not found: ${notes}" >&2
  exit 1
}

cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light dark">
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; padding: 14px 18px 16px;
    font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
    color: #1d1d1f; -webkit-font-smoothing: antialiased;
  }
  h1 { margin: 0 0 10px; font-size: 15px; font-weight: 600; letter-spacing: -0.01em; }
  ul { margin: 0; padding: 0; list-style: none; }
  li { position: relative; margin: 0 0 9px; padding-left: 16px; }
  li::before {
    content: ""; position: absolute; left: 3px; top: 0.62em;
    width: 5px; height: 5px; border-radius: 50%; background: #0a84ff;
  }
  p { margin: 0 0 9px; }
  strong { font-weight: 600; }
  code {
    font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
    padding: 1px 4px; border-radius: 4px; background: rgba(0, 0, 0, 0.06);
  }
  .small-print {
    margin: 14px 0 0; padding-top: 10px; border-top: 1px solid rgba(0, 0, 0, 0.10);
    font-size: 11px; line-height: 1.4; color: #6e6e73;
  }
  @media (prefers-color-scheme: dark) {
    body { color: #f5f5f7; }
    code { background: rgba(255, 255, 255, 0.10); }
    .small-print { border-top-color: rgba(255, 255, 255, 0.14); color: #98989d; }
  }
</style>
</head>
<body>
EOF

/usr/bin/awk '
  function escape(text) {
    gsub(/&/, "\\&amp;", text); gsub(/</, "\\&lt;", text); gsub(/>/, "\\&gt;", text)
    return text
  }
  # **bold** and `code`, applied after escaping.
  function inline(text,    out, start, rest) {
    out = ""
    while (match(text, /\*\*[^*]+\*\*/)) {
      out = out substr(text, 1, RSTART - 1) "<strong>" substr(text, RSTART + 2, RLENGTH - 4) "</strong>"
      text = substr(text, RSTART + RLENGTH)
    }
    text = out text
    out = ""
    while (match(text, /`[^`]+`/)) {
      out = out substr(text, 1, RSTART - 1) "<code>" substr(text, RSTART + 1, RLENGTH - 2) "</code>"
      text = substr(text, RSTART + RLENGTH)
    }
    return out text
  }
  # "New: ..." / "Fixed: ..." / "How it works: ..." -> the lead-in in bold. Only a short, plain lead-in counts.
  function lead(text) {
    if (match(text, /^[A-Z][A-Za-z\047 ]{1,24}:/) && text !~ /^<strong>/) {
      return "<strong>" substr(text, 1, RLENGTH) "</strong>" substr(text, RLENGTH + 1)
    }
    return text
  }
  function flush() {
    if (kind == "item") items[++itemCount] = lead(inline(escape(buffer)))
    else if (kind == "para") { closeList(); paragraphs[++blockCount] = inline(escape(buffer)); order[blockCount] = "p" }
    kind = ""; buffer = ""
  }
  function closeList(    i, html) {
    if (itemCount == 0) return
    html = "<ul>\n"
    for (i = 1; i <= itemCount; i++) html = html "  <li>" items[i] "</li>\n"
    html = html "</ul>"
    paragraphs[++blockCount] = html; order[blockCount] = "ul"
    itemCount = 0
  }
  /^# / { flush(); closeList(); title = escape(substr($0, 3)); next }
  /^- / { flush(); kind = "item"; buffer = substr($0, 3); next }
  /^[ \t]*$/ { flush(); next }
  {
    line = $0; sub(/^[ \t]+/, "", line)
    if (kind == "") { kind = "para"; buffer = line } else buffer = buffer " " line
  }
  END {
    flush(); closeList()
    if (title != "") print "<h1>" title "</h1>"
    for (i = 1; i <= blockCount; i++) {
      if (order[i] == "ul") print paragraphs[i]
      else if (i == blockCount && blockCount > 1) print "<p class=\"small-print\">" paragraphs[i] "</p>"
      else print "<p>" paragraphs[i] "</p>"
    }
  }
' "${notes}"

cat <<'EOF'
</body>
</html>
EOF
