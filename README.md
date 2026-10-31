# Clean Desk

A macOS menu bar app that opens your selected apps and quits the rest with one click. It can also move desktop files to Trash. Everything runs locally, without an account or internet connection.

Building requires macOS 14 or later and Xcode or Command Line Tools with Swift 6 or later. Run the commands below from the project directory.

```sh
./scripts/build.sh
```
Builds and locally signs the app at `/Applications/Clean Desk.app`.

```sh
open "/Applications/Clean Desk.app"
```
Launches the built app. Each build updates this single copy in Applications.

```sh
./scripts/build-dmg.sh
```
Rebuilds the app and creates a verified installer image at `dist/Clean-Desk.dmg`, replacing any previous image.

```sh
./scripts/test.sh
```
Runs the test suite without quitting real apps or modifying your Desktop files.
