# Project Sync

Project Sync is a private, native macOS app for scheduled one-way file syncs between:

- folders on your Mac;
- mounted NAS or network drives (for example, `/Volumes/My NAS`);
- remote machines reachable with SSH.

It is inspired by the lightweight native feel of [Syncthing for macOS](https://github.com/syncthing/syncthing-macos), but it has its own job dashboard and uses the tools already included with macOS. Files and job metadata stay local.

## What works

- Native SwiftUI dashboard and menu-bar controls
- Custom Project Sync app icon
- Mac → NAS, NAS → Mac, Mac → Mac, and local ↔ SSH jobs
- Backup mode (copy/update without deleting old destination files)
- Mirror mode (destination exactly follows source, including deletions)
- Manual, hourly, daily, and weekly schedules
- Preview/dry runs before changing files
- Job cancellation, persisted history, and plain-text logs
- Exclusion patterns and macOS extended-attribute preservation
- Optional launch at login for unattended schedules

Project Sync deliberately does not implement remote-to-remote transfers or automatic NAS mounting. Mount SMB/AFP/NFS shares in Finder first. SSH jobs use your existing key-based SSH setup and do not display password prompts.

## Run from source

Requirements: macOS 14 or newer and Xcode 15 or newer.

```sh
swift run ProjectSync
```

You can also open `Package.swift` in Xcode and run the `ProjectSync` scheme.

## Build a personal app bundle

```sh
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open "build/Project Sync.app"
```

The script creates an ad-hoc signed app at `build/Project Sync.app`. Move it to `/Applications` before enabling **Launch at login**. For distribution to other Macs, replace ad-hoc signing with your Apple Developer ID and notarize the app.

## Safety notes

1. Start with **Backup** mode.
2. Use **Preview Changes** and read the log.
3. Switch to **Mirror** only when destination deletions are desired.
4. Keep a separate backup of important data; synchronization is not versioned archival storage.

Jobs and history are stored under `~/Library/Application Support/Project Sync`. Each run writes a log in the `Logs` subfolder.

## Transfer behavior

Project Sync invokes `/usr/bin/rsync` directly with an argument array—never through a local shell. Remote jobs add SSH transport with batch mode and a connection timeout. Source paths use trailing-slash semantics, so the contents of the chosen source folder are copied into the chosen destination folder.

## Tests

```sh
swift test
```
