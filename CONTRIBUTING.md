# Contributing to CPaste

Thanks for considering a contribution. CPaste is a personal, local-first macOS project, and focused fixes or improvements are welcome.

## Before you start

- Search existing issues before opening a new one.
- Use a private security advisory for vulnerabilities; do not post them publicly.
- Never include real clipboard contents, credentials, personal information, or proprietary material in issues, tests, screenshots, or commits.
- For a substantial feature or interface change, open an issue first so scope and direction can be agreed before implementation.

## Development setup

CPaste requires Apple Silicon, macOS 13 or later, Xcode Command Line Tools, and Swift 5.9 or later.

```sh
git clone https://github.com/cjustsing/cpaste.git
cd cpaste
swift build
swift run CPasteCoreChecks
```

Build the application bundle and run the full quality gate with:

```sh
./scripts/quality_gate.sh
```

The resulting application is written to `build/CPaste.app`.

## Pull requests

1. Create a focused branch from the latest `main`.
2. Keep commits and the pull request limited to one coherent change.
3. Add or update checks for behavior changes when practical.
4. Run the full quality gate before submitting.
5. Explain the user-visible impact and include privacy-safe screenshots for interface changes.

By contributing, you agree that your contribution is licensed under the repository's [Apache License 2.0](LICENSE).
