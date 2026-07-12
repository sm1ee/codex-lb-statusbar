# Codex LB Status Bar

Current version: **v0.2.0**

Native macOS menu bar app for checking [Codex LB](https://github.com/Soju06/codex-lb) account availability and quota without opening the dashboard.

![Codex LB Status Bar](assets/demo.png)

## Features

- Shows average remaining 5-hour and weekly quota across active accounts in the menu bar.
- Displays account status, routing policy, quota, reset timing, and reset-credit expiry.
- Uses green, amber, and red quota/status warning levels matching the dashboard.
- Lets administrators toggle `Active`/`Paused` and cycle `Normal`, `Burn first`, and `Preserve` routing policies from account badges.
- Refreshes every 60 seconds and supports immediate manual refresh.
- Supports admin/guest login, configurable server URL, dashboard access, and Launch at Login.
- Shows the connected Codex LB server version.

Account controls are read-only for guest sessions and accounts requiring re-authentication or deactivation recovery.

## Install

1. Download `CodexLBStatusBar-0.2.0.dmg` from the [v0.2.0 release](https://github.com/sm1ee/codex-lb-statusbar/releases/tag/v0.2.0).
2. Open the DMG and drag `CodexLBStatusBar.app` to `Applications`.
3. Start Codex LB, then open the status bar app. The default server URL is `http://127.0.0.1:2455`.
4. Use `Admin Login...` or `Guest Login...` when authentication is required.

Requires macOS 13 or later and a running Codex LB server.

## Build

Install Xcode command line tools, then run:

```bash
./build-dmg.sh
```

Outputs:

- `build/CodexLBStatusBar.app`
- `dist/CodexLBStatusBar-0.2.0.dmg`

Run the focused logic checks with:

```bash
swiftc StatusBarLogic.swift StatusBarLogicTests.swift -o /tmp/statusbar-logic-tests
/tmp/statusbar-logic-tests
```

## Runtime Notes

- The server URL is stored in `UserDefaults` for the current macOS user.
- `Launch at Login` uses the native macOS login-item service.
- Error and empty states are shown in English.

## Project Files

- `CodexLBStatusBar.swift`: menu bar UI, API client, authentication, and login-item integration
- `StatusBarLogic.swift`: quota aggregation, colors, routing labels, and formatting logic
- `StatusBarLogicTests.swift`: focused logic checks
- `build-dmg.sh`: versioned app bundle and DMG packaging
