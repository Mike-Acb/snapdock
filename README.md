# SnapDock

English | [简体中文](README.zh-CN.md)

**Launch and switch macOS apps with keyboard shortcuts that follow your Dock.**

A menu bar utility for Apple Silicon Macs, built as a replacement for [Snap](https://apps.apple.com/us/app/snap/id418073146?mt=12). Pinned Dock apps get `Option+1`…`Option+0`; other apps can have custom shortcuts. Press a shortcut to launch or switch to its app, and press it again to hide the app.

<p align="center">
  <img src="docs/screenshot-settings.png" alt="SnapDock settings window listing pinned Dock apps and their shortcuts" width="560">
  <img src="docs/screenshot-menu.png" alt="SnapDock menu bar menu with automatic and manual shortcuts" width="240">
</p>

## Features

- **Dock shortcuts:** the first ten pinned Dock apps, in Dock order. Finder, folders, and recent apps are skipped.
- **Custom shortcuts:** record a key combination for any app. These win over Dock shortcuts that use the same keys.
- **Per-app switches:** turn a shortcut off without losing it.
- **Import:** bring shortcuts over from Snap or Apptivate, with a preview first.
- **English and Simplified Chinese:** change the language in **Settings → App language**.

## Build

Requires an Apple Silicon Mac running macOS 13 or later, and Command Line Tools with Swift 6.1+ and the macOS 26 SDK.

```bash
./Scripts/build-app.sh          # release build → dist/SnapDock.app
./Scripts/package-release.sh    # also builds a disk image → dist/SnapDock-<version>.dmg
```

Copy `dist/SnapDock.app` to Applications to install. The build compiles against the macOS 26 SDK to keep the current look; set `SNAPDOCK_SDK` to use another SDK. The app is ad-hoc signed, not notarized.

## Usage

### 1. Install and first launch

Download `SnapDock-<version>.dmg` from [Releases](https://github.com/Mike-Acb/snapdock/releases), or [build it yourself](#build), and drag SnapDock to Applications. The app is not notarized, so macOS blocks the first launch. Click **Open Anyway** in **System Settings → Privacy & Security**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/SnapDock.app
```

Settings open on first launch. SnapDock runs in the menu bar with no Dock icon. Closing the settings window keeps it running; choose **Settings…** from the menu bar icon, or open the app again, to get back.

### 2. Dock shortcuts: Automatic tab

1. Pin the apps you use most to the Dock and drag them into the order you want.
2. Press `Option+1` for the first pinned app, `Option+2` for the second, and so on. `Option+0` is the tenth. Finder, folders, and recent apps are skipped and don't take a number.
3. To use other modifiers, tick any of **Control**, **Option**, **Shift**, and **Command**. At least one stays on.

The list follows Dock changes on its own; click **Refresh** if it looks stale. Each row shows the shortcut and its status. Use the switch to turn one off and **Open** to try it.

### 3. Custom shortcuts: Manual tab

1. Click **Add…**, then **Choose Application…**, and pick an app.
2. Click the **Shortcut** field and press a key combination with at least one of ⌘, ⌥, ⌃, or ⇧.
3. Click **Save**.

Manual shortcuts win over Dock shortcuts that use the same keys. One app can have several manual shortcuts. Use **Edit…** and **Remove** to change them, or the switch to turn one off and keep it.

### 4. What a shortcut does

- **App not running:** launches it.
- **App in the background:** switches to it and opens a window if it has none.
- **App already in front:** hides it, if **Press a shortcut again to hide the frontmost app** is on (the default).

The menu bar icon lists every shortcut with its status; click an entry to switch to that app. It also has **Add Manual Shortcut…**, **Import from Apptivate…**, and **Quit SnapDock**.

### 5. Settings tab

- **App language:** Follow System, 简体中文, or English.
- **Press a shortcut again to hide the frontmost app:** see above.
- **Show SnapDock in the menu bar:** when off, open the app again to reach settings.
- **Launch SnapDock at login:** macOS may ask you to approve it in **System Settings → General → Login Items**.

### Import from Snap or Apptivate

- **Snap:** **Settings → Import from Snap…** reads Snap's preferences without changing Snap or the Dock. The preview lists the shortcuts and the settings that will change (current → imported). Existing manual shortcuts are kept, conflicts are skipped, and launch at login is left alone. A backup is saved first; **Restore Pre-import Configuration…** undoes the import. Quit Snap before using the same shortcuts in SnapDock.
- **Apptivate:** **Manual → Import from Apptivate…** lets you pick which shortcuts to bring over. Apps already in SnapDock and conflicting keys are skipped. Key sequences keep only their first combination, and files or scripts are not supported.

## Troubleshooting

- **A shortcut does nothing:** check that it is switched on and look at its status in settings. Snap or a macOS shortcut may be using the same keys.
- **Dock order is out of date:** click **Refresh** in **Automatic**.
- **Launch at login is pending:** approve it in **System Settings → General → Login Items**.

Stream diagnostic logs with:

```bash
/usr/bin/log stream --style compact --predicate 'subsystem == "local.snapdock.app"'
```

## License

[MIT](LICENSE)
