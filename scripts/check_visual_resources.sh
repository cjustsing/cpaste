#!/usr/bin/env bash
set -euo pipefail

RESOURCE_ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RESOURCE_ROOT_DIR"
swift build --target CPasteCore
RESOURCE_BIN_DIR="$(swift build --show-bin-path)"
RESOURCE_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cpaste-resource-checks.XXXXXX")"
trap 'rm -rf "$RESOURCE_CHECK_DIR"' EXIT

python3 - "$RESOURCE_ROOT_DIR" "$RESOURCE_CHECK_DIR/main.swift" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
card = (root / "Sources/CPaste/TimelineCardView.swift").read_text()
thumbnail = (root / "Sources/CPaste/TimelineThumbnailView.swift").read_text()
template = (root / "Sources/CPasteResourceChecks/main.swift").read_text()

def declaration(source, marker):
    start = source.find(marker)
    if start < 0:
        raise SystemExit("Production resource declaration was not found: " + marker)
    end = source.index("{", start) + 1
    depth = 1
    while end < len(source) and depth:
        if source[end] == "{": depth += 1
        elif source[end] == "}": depth -= 1
        end += 1
    if depth: raise SystemExit("Unbalanced resource declaration")
    return source[start:end]

drag_path = root / "Sources/CPaste/ClipboardDragExport.swift"
core_drag_path = root / "Sources/CPasteCore/ClipboardDragExport.swift"
if core_drag_path.exists():
    drag = "\nprivate func resourceDragProviders(item: ClipboardItem, imageURL: URL?) -> [NSItemProvider] { ClipboardDragExport.providers(for: item, imageURL: imageURL) }\n"
elif drag_path.exists():
    drag = drag_path.read_text() + "\nprivate func resourceDragProviders(item: ClipboardItem, imageURL: URL?) -> [NSItemProvider] { ClipboardDragExport.providers(for: item, imageURL: imageURL) }\n"
else:
    drag = "\nprivate struct ResourceDragHarness { let item: ClipboardItem; let imageURL: URL?\n" + declaration(card, "private func dragProvider()") + "\nfunc providers() -> [NSItemProvider] { [dragProvider()] }\n}\nprivate func resourceDragProviders(item: ClipboardItem, imageURL: URL?) -> [NSItemProvider] { ResourceDragHarness(item: item, imageURL: imageURL).providers() }\n"

thumbnail_code = thumbnail.split("struct TimelineThumbnailView", 1)[0]
pipeline_path = root / "Sources/CPaste/ImageRequestPipeline.swift"
pipeline = pipeline_path.read_text() if pipeline_path.exists() else ""
icon_path = root / "Sources/CPaste/SourceApplicationIcon.swift"
icon = icon_path.read_text() if icon_path.exists() else declaration(card, "private final class SourceApplicationIconCache")
icon = icon.replace("NSWorkspace.shared", "ResourceIconWorkspace.shared").replace("FileManager.default", "ResourceIconFileSystem.shared")
Path(sys.argv[2]).write_text(template.replace("// __PRODUCTION_RESOURCE_CODE__", drag + "\n" + pipeline + "\n" + thumbnail_code + "\n" + icon))
PY

shopt -s nullglob
RESOURCE_CORE_OBJECTS=("$RESOURCE_BIN_DIR/CPasteCore.build/"*.swift.o)
swiftc -I "$RESOURCE_BIN_DIR/Modules" "${RESOURCE_CORE_OBJECTS[@]}" \
    Sources/CPaste/AppEnvironment.swift Sources/CPaste/Localization.swift \
    "$RESOURCE_CHECK_DIR/main.swift" -o "$RESOURCE_CHECK_DIR/CPasteResourceChecks"
"$RESOURCE_CHECK_DIR/CPasteResourceChecks" "${1:-all}"
