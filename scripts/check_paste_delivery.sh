#!/usr/bin/env bash
set -euo pipefail
DELIVERY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DELIVERY_ROOT"
swift build --target CPasteCore
DELIVERY_BIN="$(swift build --show-bin-path)"
DELIVERY_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/cpaste-delivery.XXXXXX")"
trap 'rm -rf "$DELIVERY_TEMP"' EXIT
python3 - "$DELIVERY_ROOT" "$DELIVERY_TEMP/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/CPaste/AppDelegate.swift').read_text()
marker = '    private func completePaste('
if source.count(marker) != 1:
    raise SystemExit('Expected one production completePaste method')
start = source.index(marker)
opening = source.index('{', start)
depth = 1
end = opening + 1
while depth and end < len(source):
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
if depth:
    raise SystemExit('Production paste method was not complete')
method = source[start:end]
template = (root / 'Sources/CPasteDeliveryChecks/main.swift').read_text()
coordinator = (root / 'Sources/CPasteCore/PasteDeliveryCoordinator.swift').exists()
property_code = ('let pasteDelivery = PasteDeliveryCoordinator(schedule: { delay, work in DeliveryScheduler.work.append(work) })'
                 if coordinator else '')
cancel_code = 'pasteDelivery.cancel()' if coordinator else ''
for marker, value in [('PASTE_COORDINATOR_PROPERTY', property_code),
                      ('PASTE_COORDINATOR_CANCEL', cancel_code),
                      ('PASTE_DELEGATE_METHOD', method)]:
    placeholder = '// {{' + marker + '}}'
    if template.count(placeholder) != 1:
        raise SystemExit('Expected one test insertion marker: ' + marker)
    template = template.replace(placeholder, value)
Path(sys.argv[2]).write_text(template)
PY
shopt -s nullglob
DELIVERY_OBJECTS=("$DELIVERY_BIN/CPasteCore.build/"*.swift.o)
if [[ ${#DELIVERY_OBJECTS[@]} -eq 0 ]]; then
    echo "Compiled CPasteCore objects were not found" >&2
    exit 1
fi
swiftc -I "$DELIVERY_BIN/Modules" "${DELIVERY_OBJECTS[@]}" "$DELIVERY_TEMP/main.swift" -o "$DELIVERY_TEMP/checks"
"$DELIVERY_TEMP/checks"
