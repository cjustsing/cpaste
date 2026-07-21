# CPaste

CPaste is a local, Apple Silicon native clipboard history app for macOS. It uses an original horizontal visual timeline with source-app badges, instant search, pinned items, keyboard navigation, drag out, preview, and quick paste.

![CPaste app icon](Resources/AppIcon/AppIcon-1024.png)

## Build

```sh
swift build -c release --arch arm64
./scripts/build_app.sh
```

Run the lightweight core checks:

```sh
swift run CPasteCoreChecks
```

Run the full quality gate:

```sh
./scripts/quality_gate.sh
```

The app bundle is created at:

```text
build/CPaste.app
```

The original 1024 px icon, complete iconset, and packaged `.icns` are stored under:

```text
Resources/AppIcon
```

Verify the architecture:

```sh
file build/CPaste.app/Contents/MacOS/CPaste
lipo -archs build/CPaste.app/Contents/MacOS/CPaste
```

## Run

```sh
open build/CPaste.app
```

The app lives in the menu bar. Press `Command+Shift+V` to open the history panel.

Full user manual:

```text
docs/CPaste-使用说明书.md
```

Generate current UI screenshots:

```sh
swift build -c release --arch arm64
mkdir -p docs/screenshots/timeline-refactor
.build/arm64-apple-macosx/release/CPaste --snapshot-dir docs/screenshots/timeline-refactor
```

For local UI smoke checks without touching your real history:

```sh
CPASTE_STORAGE_DIR="$(mktemp -d /tmp/cpaste-demo.XXXXXX)" build/CPaste.app/Contents/MacOS/CPaste --demo
```

## Permissions

CPaste can always write a selected history item back to the system clipboard. To paste automatically into the previous app, macOS requires Accessibility permission:

System Settings -> Privacy & Security -> Accessibility -> enable CPaste.

## Storage

History is stored locally under:

```text
~/Library/Application Support/CPaste
```

Clipboard entries marked as concealed, transient, auto-generated, or as coming from a supported password manager are ignored. The storage and blob directories are restricted to the current user, but history contents are not encrypted at the application level.

No network sync or upload is implemented.

## License

CPaste is an independently developed personal project owned by `cjustsing`.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
