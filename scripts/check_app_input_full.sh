#!/usr/bin/env bash
set -euo pipefail

INPUT_FULL_ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INPUT_FULL_ROOT_DIR"
swift build --target CPasteCore
INPUT_FULL_BIN_DIR="$(swift build --show-bin-path)"
INPUT_FULL_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cpaste-input-full.XXXXXX")"
trap 'rm -rf "$INPUT_FULL_CHECK_DIR"' EXIT
INPUT_FULL_APP_DIR="$INPUT_FULL_CHECK_DIR/CPasteInputChecks.app"
mkdir -p "$INPUT_FULL_APP_DIR/Contents/MacOS"
python3 - "$INPUT_FULL_APP_DIR/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib
import sys
import uuid
with Path(sys.argv[1]).open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "local.cpaste.inputchecks." + uuid.uuid4().hex,
        "CFBundleExecutable": "CPasteInputChecks",
        "CFBundleName": "CPaste Input Checks",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }, output)
PY

python3 - "$INPUT_FULL_ROOT_DIR" "$INPUT_FULL_CHECK_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "Sources/CPaste/main.swift").read_text()
bootstrap_marker = "if let snapshotDirectory"
if bootstrap_marker not in source:
    raise SystemExit("Shared app bootstrap marker was not found")
bootstrap = source.split(bootstrap_marker, 1)[0]
checks = (root / "Sources/CPasteInputChecks/main.swift").read_text()
cleanup_marker = "inputCheckCleanup?()\ninputCheckCleanup = nil\n"
if checks.count(cleanup_marker) != 1:
    raise SystemExit("Native input check cleanup marker was not found")
checks = checks.replace(cleanup_marker, "runFullNativeInputChecks(app: app, window: inputWindow, field: inputField)\n" + cleanup_marker)
Path(sys.argv[2]).write_text(bootstrap + "\n" + checks)
PY

shopt -s nullglob
INPUT_FULL_CORE_OBJECTS=("$INPUT_FULL_BIN_DIR/CPasteCore.build/"*.swift.o)
if [[ ${#INPUT_FULL_CORE_OBJECTS[@]} -eq 0 ]]; then
    echo "Compiled CPasteCore objects were not found" >&2
    exit 1
fi
swiftc -I "$INPUT_FULL_BIN_DIR/Modules" \
    "${INPUT_FULL_CORE_OBJECTS[@]}" \
    Sources/CPaste/AppEnvironment.swift \
    Sources/CPaste/Localization.swift \
    Sources/CPaste/HistoryKeyboardMonitor.swift \
    Sources/CPaste/NativeAppMenu.swift \
    Sources/CPasteInputChecks/EditingRegressionChecks.swift \
    "$INPUT_FULL_CHECK_DIR/main.swift" -o "$INPUT_FULL_APP_DIR/Contents/MacOS/CPasteInputChecks"
"$INPUT_FULL_APP_DIR/Contents/MacOS/CPasteInputChecks" "$@"
