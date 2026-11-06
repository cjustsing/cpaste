#!/usr/bin/env bash
set -euo pipefail
SHUTDOWN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SHUTDOWN_ROOT"
SHUTDOWN_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/cpaste-shutdown.XXXXXX")"
trap 'rm -rf "$SHUTDOWN_TEMP"' EXIT
python3 - "$SHUTDOWN_ROOT" "$SHUTDOWN_TEMP/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/CPaste/AppDelegate.swift').read_text()

def method(marker, required=False):
    start = source.find(marker)
    if start < 0:
        if required:
            raise SystemExit('Missing production lifecycle method: ' + marker)
        return None
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth and end < len(source):
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    if depth:
        raise SystemExit('Unbalanced production lifecycle method')
    return source[start:end]

parts = [method('func applicationShouldTerminate(', required=True)]
for name in ['finishTermination', 'retryStorage']:
    parts.append(method('private func ' + name + '(') or ('private func ' + name + '() {}'))
template = (root / 'Sources/CPasteShutdownChecks/main.swift').read_text()
placeholder = '// {{LIFECYCLE_METHODS}}'
if template.count(placeholder) != 1:
    raise SystemExit('Expected one lifecycle test insertion marker')
Path(sys.argv[2]).write_text(template.replace(placeholder, '\n\n'.join(parts)))
PY
swiftc "$SHUTDOWN_TEMP/main.swift" -o "$SHUTDOWN_TEMP/checks"
"$SHUTDOWN_TEMP/checks"
