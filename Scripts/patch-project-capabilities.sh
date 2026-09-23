#!/bin/zsh
set -euo pipefail

project_file="${1:-HSReconnect.xcodeproj/project.pbxproj}"

/usr/bin/python3 - "${project_file}" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
text = project.read_text()
malformed = 'SystemCapabilities = "[\\"com.apple.ApplicationGroups.iOS\\": [\\"enabled\\": 1]]";'
replacement = '''SystemCapabilities = {
\t\t\t\t\t\t\tcom.apple.ApplicationGroups.iOS = {
\t\t\t\t\t\t\t\tenabled = 1;
\t\t\t\t\t\t\t};
\t\t\t\t\t\t};'''

malformed_count = text.count(malformed)
if malformed_count == 2:
    project.write_text(text.replace(malformed, replacement))
elif malformed_count == 0 and text.count("com.apple.ApplicationGroups.iOS = {") == 2:
    pass
else:
    raise SystemExit(
        "Unexpected App Groups capability shape in generated Xcode project."
    )
PY
