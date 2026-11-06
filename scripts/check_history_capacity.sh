#!/usr/bin/env bash
set -euo pipefail

CAPACITY_ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$CAPACITY_ROOT_DIR"
swift build --target CPasteCore
CAPACITY_BIN_DIR="$(swift build --show-bin-path)"
CAPACITY_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cpaste-capacity-checks.XXXXXX")"
trap 'rm -rf "$CAPACITY_CHECK_DIR"' EXIT

python3 - "$CAPACITY_ROOT_DIR" "$CAPACITY_CHECK_DIR/main.swift" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = (root / "Sources/CPaste/CPasteSettingsView.swift").read_text()
template = (root / "Sources/CPasteCapacityChecks/main.swift").read_text()

def declaration(marker, required=False):
    start = source.find(marker)
    if start < 0:
        if required:
            raise SystemExit("Production capacity binding was not found")
        return None
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while end < len(source) and depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    if depth:
        raise SystemExit("Unbalanced production capacity declaration")
    return source[start:end]

parts = [declaration("private var historyLimitBinding:", required=True)]
for name in ["requestHistoryLimit", "confirmHistoryLimitChange", "cancelHistoryLimitChange"]:
    method = declaration("private func " + name + "(")
    if method:
        parts.append(method)
    elif name != "requestHistoryLimit":
        # The baseline has no confirmation methods. These no-op bridges keep
        # the same harness compilable; its real Binding must first fail before
        # any bridge is reached. After the fix the actual methods are extracted.
        parts.append("private func " + name + "() {}")

Path(sys.argv[2]).write_text(template.replace("// __PRODUCTION_CAPACITY_BINDING__", "\n\n".join(parts)))
PY

shopt -s nullglob
CAPACITY_CORE_OBJECTS=("$CAPACITY_BIN_DIR/CPasteCore.build/"*.swift.o)
if [[ ${#CAPACITY_CORE_OBJECTS[@]} -eq 0 ]]; then
    echo "Compiled CPasteCore objects were not found" >&2
    exit 1
fi
swiftc -I "$CAPACITY_BIN_DIR/Modules" "${CAPACITY_CORE_OBJECTS[@]}" \
    "$CAPACITY_CHECK_DIR/main.swift" -o "$CAPACITY_CHECK_DIR/CPasteCapacityChecks"
if [[ "${1:-}" == "--compile-only" ]]; then
    echo "History capacity binding checks compiled"
    exit 0
fi
"$CAPACITY_CHECK_DIR/CPasteCapacityChecks"
