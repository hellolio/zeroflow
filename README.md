# Zeroflow

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

A native, lightweight macOS utility set: screenshot annotation, window switching, Dock enhancements, clipboard history, and a Dynamic Island — all behind a single menu bar icon.

no pop-ups, no third-party dependencies. Small download, fast launch, low idle memory.

Compared to AltTab (a window switcher) and Maccy (a clipboard manager), ZeroFlow offers several times more functionality while using significantly less memory. This holds true both right after launch and after extended use. Feel free to download all three and see the difference for yourself.

[![Sponsor][SponsorBadge]][SponsorUrl]
[![Latest release](https://img.shields.io/github/v/release/hellolio/zeroflow)](https://github.com/hellolio/zeroflow/releases/latest)
[![License: AGPL-3.0](https://img.shields.io/github/license/hellolio/zeroflow)](LICENSE)
[![macOS: 14.0+](https://img.shields.io/badge/macOS-14.0%2B-black?logo=apple&logoColor=white)](https://github.com/hellolio/zeroflow)

[SponsorUrl]: https://github.com/sponsors/hellolio
[SponsorBadge]: https://img.shields.io/github/sponsors/hellolio?style=flat&logo=github&logoColor=white

## Features

| Module | What it does |
|---|---|
| Screenshot annotation | `⌘⇧S` to capture anytime, then draw lines, rectangles, circles, text bubbles or mosaic. Undo and redo included; the shortcut is configurable |
| Window switcher | `⌘⇥` (configurable) switches windows by thumbnail — minimized and off-screen windows included |
| Dock enhancements | Click the Dock icon to minimize a window; hover it to preview window contents |
| Clipboard history | `⌘⇧C` (configurable) opens history — search, pick with the arrow keys, paste with Return |
| Dynamic Island | Hover or click the notch to expand: calendar, system resources (CPU / memory / GPU / disk / network), now playing |
| Finder context menu | Custom right-click commands in Finder |
| Scroll direction | Reverses wheel scrolling without affecting trackpad gestures |

## Installation

Download the latest `Zeroflow-x.x.x.dmg` from [Releases](https://github.com/hellolio/zeroflow/releases), open it, and drag Zeroflow into Applications.

> The app is not signed or notarized, so Gatekeeper may block the first launch. Either:
>
> - Run `xattr -cr /Applications/Zeroflow.app` in Terminal, then open it again;
> - Or open System Settings → Privacy & Security, find the Zeroflow notice, and click "Open Anyway".

## Build

Requires macOS 14.0+ and Xcode 16+.

```bash
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -configuration Debug -derivedDataPath build -allowProvisioningUpdates build
open build/Build/Products/Debug/Zeroflow.app
```

- Source files added under `Zeroflow/` are compiled automatically — no `project.pbxproj` edits needed.
- `-allowProvisioningUpdates` lets Xcode generate the App Group provisioning profile required by the FinderSync extension.

CI lives in `.github/workflows/build.yml`: pushes and PRs to `main` run a compile check and upload an app artifact; a `v*` tag builds in Release configuration, packages a DMG, and publishes it to GitHub Releases.

## Tech stack

| Area | Choice |
|---|---|
| Language / UI | Swift 5 + SwiftUI + AppKit |
| Screen capture | ScreenCaptureKit (`SCScreenshotManager`) |
| Global hotkeys | Carbon `RegisterEventHotKey` (screenshot / clipboard) |
| Event interception | CGEventTap (`⌘⇥` switcher, scroll reversal, Dock and notch hotspots) |
| Window thumbnails | SkyLight private API `CGSHWCaptureWindowList` (bridged via `dlsym`; captures minimized and off-screen windows) |
| System integration | EventKit (calendar), MediaRemote (now playing), Accessibility API |
| Dependencies | None — single Xcode project |
| Minimum OS | macOS 14.0 Sonoma |

## Project layout

```
zeroflow/
├── Zeroflow.xcodeproj/      # Xcode project
├── Zeroflow/
│   ├── ZeroflowApp.swift    # App entry point
│   ├── MenuBar/             # Menu bar controller
│   ├── Models/              # Settings, shortcuts, edit document, clipboard models
│   ├── Views/               # Settings, selection overlay, editor, feature panels
│   ├── Services/            # Capture, hotkeys, windows, Dock, clipboard, notch panel, Finder
│   └── Resources/           # Localization strings (Translations.json)
├── FinderSyncExtension/     # Finder context-menu extension (sandboxed, talks to the app via App Group)
├── scripts/                 # Extension registration script
└── .github/workflows/       # CI: compile check and release
```

## Roadmap
- [ ] Ongoing performance improvements, with a focus on reducing memory usage and refining interaction logic and overall usability.

## License

[AGPL-3.0-only](LICENSE)

The copyright holder reserves the right to license this software under other terms (including a commercial license).

