# CPaste

CPaste is a local, Apple Silicon native clipboard history app for macOS. It uses an original horizontal visual timeline with source-app badges, instant search, pinned items, keyboard navigation, drag out, preview, and quick paste. The interface supports English and Simplified Chinese.

![CPaste app icon](Resources/AppIcon/AppIcon-1024.png)

![CPaste Liquid Glass timeline](docs/screenshots/timeline-refactor/01-timeline-overview.png)

## Download

Download the latest Apple Silicon build from [GitHub Releases](https://github.com/cjustsing/cpaste/releases/latest). CPaste requires macOS 13 or later.

The current release is signed ad hoc and is not Apple-notarized. On first launch, macOS may require you to right-click `CPaste.app`, choose **Open**, and confirm. You can verify the download with the SHA-256 checksum published alongside the release asset.

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

The production 1024 px icon, complete iconset, and packaged `.icns` are stored under:

```text
Resources/AppIcon
```

The approved solid double-card artwork and design record are in [docs/design/app-icon](docs/design/app-icon/README.md). Regenerate the production assets directly from that original with `swift scripts/generate_app_icon.swift`; the script cleans the outer edge with an antialiased mask and generates all icon sizes without repainting the artwork.

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

CPaste follows the macOS language by default. You can also choose `System`, `简体中文`, or `English` in Settings > General > Interface Language; the change takes effect immediately.

User manuals:

- [简体中文使用说明书](docs/CPaste-使用说明书.md)
- [English User Guide](docs/CPaste-User-Guide.md)

Generate current UI screenshots:

```sh
swift build -c release --arch arm64
mkdir -p docs/screenshots/timeline-refactor
.build/arm64-apple-macosx/release/CPaste --snapshot-dir docs/screenshots/timeline-refactor
```

Open an isolated 8 MB text fixture to check search focus and long-text preview responsiveness:

```sh
.build/arm64-apple-macosx/release/CPaste --snapshot-preview 09-large-text
```

Liquid Glass screenshots require macOS 26 or later. Screen Recording permission must be available to the process that runs the snapshot command because native glass is captured from an onscreen WindowServer composition.

For corner and shadow checks, set `CPASTE_SNAPSHOT_SHADOWS=1` to include the native window shadow at its original capture size. `CPASTE_SNAPSHOT_SCALE=1` or `2` places the snapshot window on a connected display with that backing scale (otherwise it uses the default display). Use `CPASTE_SNAPSHOT_THEME=standard` to compare the standard theme. In an interactive preview, closing the panel simulates a new presentation while keeping the fixture window visible, so reopening state can be checked without the global hotkey.

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

## Support CPaste

If CPaste is useful to you, you can voluntarily support its independent development. Support is entirely optional and does not unlock features or affect app usage or future updates.

如果 CPaste 帮到了你，可以自愿支持这个独立开发的个人项目。赞赏不会解锁任何功能，也不会影响软件使用或后续更新。

<details>
<summary>View Alipay and WeChat Pay codes / 查看支付宝与微信收款码</summary>

Only the QR modules are published; personal avatars and display names are intentionally omitted. / 仓库仅展示二维码图形，个人头像与昵称已移除。

| Alipay / 支付宝 | WeChat Pay / 微信支付 |
| --- | --- |
| <img src="Resources/Support/alipay-support-qr.png" alt="Privacy-safe Alipay support QR code" width="220"> | <img src="Resources/Support/wechat-support-qr.png" alt="Privacy-safe WeChat Pay support QR code" width="220"> |

</details>

## License

CPaste is an independently developed personal project owned by `cjustsing`.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
