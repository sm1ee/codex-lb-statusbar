#!/usr/bin/env bash
# Renders the cask for the DMG built by build-dmg.sh. Usage: packaging/homebrew/render-cask.sh [output.rb]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
DMG="${ROOT}/dist/CodexLBStatusBar-${VERSION}.dmg"
[[ -f "${DMG}" ]] || { echo "Missing ${DMG}; run ./build-dmg.sh first" >&2; exit 1; }
SHA="$(shasum -a 256 "${DMG}" | cut -d' ' -f1)"
OUT="${1:-/dev/stdout}"
sed -e "s/__VERSION__/${VERSION}/" -e "s/__SHA256__/${SHA}/" "${ROOT}/packaging/homebrew/codex-lb-statusbar.rb" > "${OUT}"
