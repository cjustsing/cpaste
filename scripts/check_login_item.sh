#!/usr/bin/env bash
set -euo pipefail

LOGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LOGIN_ROOT"
LOGIN_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/cpaste-login-checks.XXXXXX")"
trap 'rm -rf "$LOGIN_TEMP"' EXIT

# Compile the production controller against an isolated service. These checks
# never add or remove real login items and need no logout or reboot.
swiftc Sources/CPaste/LoginItemController.swift Sources/CPasteLoginItemChecks/main.swift \
    -o "$LOGIN_TEMP/CPasteLoginItemChecks"
"$LOGIN_TEMP/CPasteLoginItemChecks"
