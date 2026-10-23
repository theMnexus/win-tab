# win-tab

A keyboard-first window switcher for macOS, with its own Dock and a notch island.

win-tab replaces ⌘-Tab with a picker that shows every window, not just every app. It can also
draw a Dock of its own on any screen edge and turn the notch into a small control center:
music, files, clipboard, notifications, system stats, text recognition and translation.

It is based on [Switch](https://github.com/Sanyam-G/switch) by Sanyam Garg and is released under
the same license, [FSL-1.1-MIT](#license).

## Requirements

- macOS 14 Sonoma or later (some features need macOS 15 or 26, noted below)
- Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build

## Features

### Window picker (⌘-Tab)

- ⌘-Tab steps through all windows, ⌥-\` through the windows of the current app.
- Type to filter. Matching ignores accents, so `tieng viet` finds "Tiếng Việt".
- 1 to 9 picks a tile. Arrow keys, or H J K L, move the selection.
- ⌘W closes the window, ⌘Q quits the app, ⌘H hides it, Return switches, Esc cancels.
- Windows on other Spaces and displays are listed. Picking one brings it to you.
- Apps with no open windows show as a compact strip.
- Hover buttons on a tile: close every window of the app, or send it to the background.
- The picker opens on the display you are working on.
- Animation speed from Off to 10×, and a Liquid Glass background on macOS 26.
- Can be switched off in Settings › Picker, which hands ⌘-Tab back to macOS.

### Dock

- A hover card over Apple's Dock with the app name, unread badge and window previews.
- win-tab's own Dock on any edge of any display, with magnification, badges and running dots.
- Your own layout: apps, groups, folders, spacers, dividers, widgets and Smart Stacks.
- Can hide the macOS Dock while it runs and restores it on quit.

### Notch

On a Mac with a notch the island sits on it. Other displays get a small pill at the top.

| Tab | What it does |
|---|---|
| Home | Now Playing for any app, including a video in the browser: artwork, seek, play controls, volume |
| Notifications | Recent notifications grouped by sender, with a quick on/off switch |
| Shelf | Drop files on the notch to keep them at hand |
| Clipboard | Clipboard history with pins and search |
| Timer | Countdowns with a chime |
| Battery | Health, power use, capacity, the apps using energy, connected devices |
| System | CPU, memory, GPU, disk and network, the busiest apps with Quit, an Optimize page, public IP and VPN state |
| Ports | Servers you started from a terminal, with the port, folder, branch and a Stop button |
| Files | Convert, compress and rename images, video, audio and PDFs |
| Translate | Translate the selected text (⌃⌥C) |

### Text from screen (⌘⇧2)

Drag over any part of the screen. The text in it is copied to the clipboard.

- Detects the language: Vietnamese, English, Chinese, Japanese, Korean, Thai, Russian and more.
- Keeps line order across columns. Tables keep a Tab between cells.
- Runs on device with Apple's Vision framework. A read takes about 0.2 s.

All hotkeys can be changed or turned off in Settings.

## Permissions

| Permission | Used for |
|---|---|
| Accessibility | Reading and raising windows, the global hotkeys |
| Screen Recording | Window thumbnails and Text from screen |
| Full Disk Access | Reading notifications for the Notifications tab (optional) |
| Automation | Asking Finder, Music, Spotify and browsers for the selection or what is playing (optional) |
| Microphone, Speech Recognition | Pronunciation practice in the Translate tab (optional) |

## Privacy

win-tab has no analytics and no auto-update. Everything stays on your Mac, except:

- **Public IP lookup**: the Network page of the System tab asks ipinfo.io for your public address
  and country. Turn it off in Settings › Notch › System.
- **Translate**: text you translate is sent to Google Translate.

Text from screen, notifications, the clipboard history and window thumbnails never leave the Mac.

## Build

win-tab is signed with a local, self-signed identity, so you don't need an Apple Developer account
and the permissions you grant survive rebuilds. Create the identity once:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Switch Local Signing" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout key.pem -out cert.pem
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "Switch Local Signing" -out id.p12 -passout pass:tmp
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
rm key.pem cert.pem id.p12
```

Then build and install:

```sh
xcodegen generate
xcodebuild -project WinTab.xcodeproj -scheme WinTab -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/win-tab.app /Applications/win-tab.app
```

## Development

Debug and Release builds share one bundle ID, so permissions are granted once. The Debug build
also listens for test commands (window and Dock dumps, frame timing, screenshots). See
`Sources/Switch/DebugFocusHarness.swift`.

```sh
xcodebuild -project WinTab.xcodeproj -scheme WinTab -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/win-tab.app
swift tools/focus-test.swift
```

## Credits

- [Switch](https://github.com/Sanyam-G/switch) by Sanyam Garg, the window switcher win-tab grew from.
- [MediaRemoteAdapter](Vendor/MediaRemoteAdapter/README.md) (BSD-3-Clause), which reads the system
  media session for Now Playing on macOS 15.4 and later.

## License

[FSL-1.1-MIT](LICENSE.md): free to use, change and share for any purpose except offering a
competing product. Each version becomes MIT licensed two years after its release.

win-tab © 2026 MN. Switch © 2026 Sanyam Garg.
