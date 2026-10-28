# Clean Desk

A local macOS menu bar app with an English interface. One button opens your selected apps if they are not running and quits the rest. No account, server, analytics, or network connection required.

## Getting started

Building requires macOS 14 or later and Xcode or Command Line Tools with Swift 6 or later.

```sh
./scripts/build.sh
open "dist/Clean Desk.app"
```

Move the built app to `~/Applications` or `/Applications`. Its icon appears in the menu bar, without a Dock icon. Xcode is not required to run the built app.

To build a DMG for sharing:

```sh
./scripts/build-dmg.sh
```

This rebuilds the app and creates `dist/Clean-Desk.dmg` with the app and an Applications shortcut. It replaces any previous DMG at that path, verifies the image, and removes temporary staging files. Build outputs in `dist/` are ignored by Git.

Only one instance of Clean Desk runs per user. Opening another copy, including one in `dist` or a DMG, shows the existing app's panel. The instance lock is released automatically when the process exits, including after a crash. Opening the app again does not create a second icon or reset your settings.

## Usage

1. On first launch, complete two setup steps: Desktop access and app selection. **Allow desktop access** opens the system folder picker. **Not now** lets you continue without Desktop cleanup. Cancelling the dialog returns you to the permission step.
2. In **Will be open**, review up to two suggested running apps. Any remaining places are filled with Safari and Notes if they are installed. Deselect suggestions or use **Search** to choose other installed apps. **Get started** saves your choices and completes onboarding without starting cleanup. Subsequent launches open the main panel.
3. Review the two lists: green for apps to keep open and red for running apps to quit. Click anywhere in a row to change its selection. **+ Add** opens the app catalog, and **Back** returns to the lists.
4. Click **Clean desk** above the lists. Selected apps stay open or are launched, while the other apps receive a normal quit request.

The upper list shows all saved selections, including apps that are currently closed. Adding an app does not launch it; **Clean desk** does that. The catalog is for choosing apps, and cleanup launches only your selections. Search is available during onboarding and in **Choose apps**. The catalog opens inside the same menu bar panel.

Finder appears in search and in the lists as a normal app row. When selected in **Will be open**, it stays visible; if it was hidden, **Clean desk** shows it again. When unselected, Finder appears in **Will be closed** if it has visible windows, and cleanup hides it. Its selection is saved like any other app's. Finder is not automatically added to your saved selections.

The **Settings** gear in the upper-right corner, beside **Clean desk**, opens a settings page with the same **Back** navigation as **Choose apps**. **Move desktop files to trash** optionally moves Desktop files to Trash during cleanup. It is off by default, and your choice is saved. Files move only when you click **Clean desk** or use the context menu action. Cleanup includes only visible, regular files directly on Desktop. It skips dotfiles, files marked hidden, folders, app bundles, aliases, and symbolic links. It does not scan subfolders or empty Trash.

The first time you enable Desktop cleanup, the app opens the system folder picker for Desktop. Confirming access enables the option and starts checking for eligible files; cancelling leaves it off. Saved access is restored on subsequent launches. If access is denied or moving a file fails, the app shows an error. **Grant Desktop access…** lets you select only the Desktop folder and saves that permission locally. Granting access does not start cleanup. Error messages disappear after 6 seconds and can be dismissed earlier with **×**. The same error does not reappear on every refresh.

When Desktop cleanup is enabled, the app checks the number of eligible files while its panel or context menu is open. Opening either refreshes the app list and file count; closing both stops periodic checks. App notifications are coalesced, and app icons are cached between refreshes. **Clean desk** is disabled when there are no apps to open or quit, no Finder windows to show or hide, and no files to move. The checkbox alone, hidden files, and folders do not enable the button.

Right-click the menu bar icon or the panel to access **Clean desktop**, a separator, and **Quit**. **Quit** exits the app.

The interface is in English. App names use the English names available in their bundles, falling back to the bundle's base name when no English localization is available.

There is no fixed default selection of Codex, WebStorm, or browsers. Onboarding suggests at most two distinct apps: running apps in alphabetical order first, then installed copies of Safari and Notes. Finder, Clean Desk, and background processes are not suggested automatically. If no suggestions are available, use search to choose apps yourself.

Onboarding appears until you complete it with **Get started**, including when upgrading from a version without onboarding. Existing app selections are not replaced until you confirm. Cleanup remains disabled during setup, including in the context menu. Your confirmed selection, including an empty list, and onboarding completion are stored locally in the `pl.local.cleandesk` preferences. Apps are identified by their bundle identifier or, when unavailable, by their path.

If a saved selection is unreadable or missing after setup, cleanup stays disabled. **Restore app selection** lets you choose apps again and confirm with **Save selection**. The original saved data remains untouched until that confirmation. An intentionally saved empty selection remains valid. Losing Desktop access also preserves your cleanup preference; access must be granted again before files can move.

Clean Desk sends normal quit requests. An app with unsaved changes may show a save dialog or refuse to quit. Successful cleanup finishes silently. Notifications appear only for problems, such as an app waiting to quit or a selected app failing to launch. Clean Desk never force-quits processes.

Unselected Finder is hidden at the end of cleanup if it has a visible window; its process keeps running. The desktop and its icons do not count as windows to hide. Minimized windows and windows on other Spaces do not enable the hide action. Clean Desk and apps running only in the background are not quit.

Enable **Settings → Launch app on start** to launch Clean Desk when you log in to your Mac. The checkbox reflects the system's login item registration. If macOS requires approval, **Open Login Items…** takes you to System Settings to allow it. Turning the checkbox off removes the login item.

## Building and testing

The project uses Swift Package Manager and the system AppKit and SwiftUI frameworks, with no external packages. The build script creates a release build, generates the icon, packages the `.app`, and signs it locally with an ad hoc signature. The build is intended for local use, rather than App Store distribution.

The app icon, menu bar icon, and action button share the [Lucide brush-cleaning icon](https://lucide.dev/icons/brush-cleaning), licensed under ISC. The original SVG and license are included in `Resources` and in the built app bundle.

```sh
./scripts/test.sh
```

The store manages UI state, while separate modules handle validated settings, refresh scheduling, AppKit requests, Desktop file access, and cleanup orchestration. Tests cover the full cleanup flow with fake processes and a controlled clock: quit refusals, delayed and late launches, process replacement, Finder visibility, cancellation, partial failures, and lost Desktop access. They also cover corrupted settings and recovery, visible-only refresh scheduling, app discovery, Desktop file filtering, onboarding, and the single-instance lock.

Tests do not quit real apps. File tests use temporary directories and a substitute trash operation without accessing the real Desktop or Trash. Preference tests use isolated, temporary suites. The build script stores intermediate files in `.build` and the finished app in `dist/Clean Desk.app`.
