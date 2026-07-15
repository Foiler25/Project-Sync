# Project Sync

Project Sync is a private, native macOS app for scheduled one-way file syncs between:

- folders on your Mac;
- mounted NAS or network drives (for example, `/Volumes/My NAS`);
- remote machines reachable with SSH.

It is inspired by the lightweight native feel of [Syncthing for macOS](https://github.com/syncthing/syncthing-macos), but it has its own job dashboard and uses the tools already included with macOS. Files and job metadata stay local.

## What works

- Native SwiftUI dashboard and menu-bar controls
- Custom Project Sync app icon
- Sparkle-powered automatic update checks
- Mac → NAS, NAS → Mac, Mac → Mac, and local ↔ SSH jobs
- Backup mode (copy/update without deleting old destination files)
- Mirror mode (destination exactly follows source, including deletions)
- Real-time file watching for Mac folders and mounted NAS sources, plus manual, hourly, daily, and weekly schedules
- Preview/dry runs before changing files
- Configurable concurrent run limits, exponential retry backoff, and run-on-volume-mount jobs
- Pause/resume controls for individual real-time watchers
- Job cancellation, live transfer output, searchable persisted history, transfer summaries, and plain-text logs
- Configurable history retention with per-entry, per-job, and full cleanup controls
- Optional checksum verification after syncs or on demand
- Optional versioned copies of replaced/deleted files with retention and item-level restore
- Exclusion presets, custom exclusion patterns, job duplication, and per-job notes
- Configurable macOS notifications, stale-backup reminders, and privacy-redacted diagnostic export
- macOS extended-attribute preservation
- Optional launch at login for unattended schedules

Project Sync deliberately does not implement remote-to-remote transfers or automatic NAS mounting. Mount SMB/AFP/NFS shares in Finder first. SSH jobs use your existing key-based SSH setup and do not display password prompts.

Real-time jobs use macOS FSEvents, run once when watching starts to catch up, and then start a sync after file activity has been quiet for two seconds. If more changes arrive during a sync, one follow-up run is queued. Like timed schedules, real-time watching operates while Project Sync is running; enable launch at login for unattended use. Remote SSH sources cannot be watched without software running on the remote machine, but local and mounted-NAS sources can sync to remote destinations in real time.

The **Developer projects** exclusion preset applies common generated-dependency, cache, and build-output patterns at every folder depth. It intentionally keeps source-control history, lockfiles, and local environment files; those have separate optional presets so a complete private backup remains the default.

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

Sparkle 2.9.4 is embedded in the app bundle. The Settings window, app menu, and menu-bar menu all provide **Check for Updates…** controls.


## Safety notes

1. Start with **Backup** mode.
2. Use **Preview Changes** and read the log.
3. Switch to **Mirror** only when destination deletions are desired.
4. Optional versioned copies can help recover replaced or deleted destination items, but they are not full snapshots. Keep a separate backup of important data.

Jobs and history are stored under `~/Library/Application Support/Project Sync`. Each run writes a log in the `Logs` subfolder.

## Transfer behavior

Project Sync invokes `/usr/bin/rsync` directly with an argument array—never through a local shell. Remote jobs add SSH transport with batch mode and a connection timeout. Source paths use trailing-slash semantics, so the contents of the chosen source folder are copied into the chosen destination folder.

## Tests

```sh
swift test
```
