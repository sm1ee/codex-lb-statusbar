# Codex LB Status Bar

Current version: **v0.1.0**

Status bar for the [Codex LB](https://github.com/Soju06/codex-lb) dashboard project.

![Codex LB Status Bar demo](assets/demo.png)

This is a tiny macOS menu-bar utility that shows quota/health status from the
Codex LB dashboard and keeps a quick refresh action right on the accounts panel.

## Prerequisites

- macOS 13+
- Xcode command line tools (`xcode-select --install`)

## Build and create DMG

```bash
swiftc -O -parse-as-library -o build/CodexLBStatusBar.app/Contents/MacOS/CodexLBStatusBar CodexLBStatusBar.swift -framework Cocoa -framework Foundation
./build-dmg.sh
```

The script reads `VERSION` and writes that into the app metadata:

- `0.1.0` currently for `v0.1.0`
- `build-dmg.sh` creates `dist/CodexLBStatusBar-<version>.dmg`

The script builds:

- `build/CodexLBStatusBar.app` – local app bundle
- `dist/CodexLBStatusBar-<version>.dmg` – distributable installer image

## Runtime behavior

- Shows an icon in the menu bar with current quota summary in the title.
- Polls dashboard summary every 60 seconds.
- Supports admin login, guest login, dashboard URL change, and forced refresh.
- Keeps the refresh action available inline next to the Accounts heading in the menu panel.

## Notes

- The server URL is stored in local `UserDefaults` under the app user session.
- Error and empty states are shown in English only (no Korean UI strings).

## Project files

- `CodexLBStatusBar.swift`: Swift source for the status bar app UI and API client.
- `build-dmg.sh`: Packaging script for building the `.dmg`.
