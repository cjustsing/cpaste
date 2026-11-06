#!/usr/bin/env bash
set -euo pipefail

INPUT_ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INPUT_ROOT_DIR"
swift build --target CPasteCore
INPUT_BIN_DIR="$(swift build --show-bin-path)"
INPUT_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cpaste-input-checks.XXXXXX")"
trap 'rm -rf "$INPUT_CHECK_DIR"' EXIT

# Compile the actual common bootstrap, so preview and normal launch cannot
# accidentally diverge from the native editing regression check.
python3 - "$INPUT_ROOT_DIR" "$INPUT_CHECK_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "Sources/CPaste/main.swift").read_text()
marker = "if let snapshotDirectory"
if marker not in source:
    raise SystemExit("Shared app bootstrap marker was not found")
bootstrap = source.split(marker, 1)[0]
checks = (root / "Sources/CPasteInputChecks/main.swift").read_text()
Path(sys.argv[2]).write_text(bootstrap + "\n" + checks)
PY

shopt -s nullglob
INPUT_CORE_OBJECTS=("$INPUT_BIN_DIR/CPasteCore.build/"*.swift.o)
if [[ ${#INPUT_CORE_OBJECTS[@]} -eq 0 ]]; then
    echo "Compiled CPasteCore objects were not found" >&2
    exit 1
fi
INPUT_APP_SOURCES=(
    Sources/CPaste/AppEnvironment.swift
    Sources/CPaste/Localization.swift
    Sources/CPaste/HistoryKeyboardMonitor.swift
)
if [[ -f Sources/CPaste/NativeAppMenu.swift ]]; then
    INPUT_APP_SOURCES+=(Sources/CPaste/NativeAppMenu.swift)
fi
swiftc -I "$INPUT_BIN_DIR/Modules" \
    "${INPUT_CORE_OBJECTS[@]}" "${INPUT_APP_SOURCES[@]}" \
    "$INPUT_CHECK_DIR/main.swift" -o "$INPUT_CHECK_DIR/CPasteInputChecks"
"$INPUT_CHECK_DIR/CPasteInputChecks" "$@"
