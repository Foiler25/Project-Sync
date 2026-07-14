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

Sparkle 2.9.4 is embedded in the app bundle. The Settings window, app menu, and menu-bar menu all provide **Check for Updates…** controls.

## Updates and releases

Development happens on `dev`. The release script intentionally refuses to publish from that branch.

When a version is ready:

1. On `dev`, increase `CFBundleShortVersionString` and the monotonically increasing integer `CFBundleVersion` in `Support/Info.plist`.
2. Commit and test the release candidate on `dev`.
3. Merge `dev` into `main`, then push the exact release commit to `origin/main`.
4. From `main`, build and Sparkle-sign the DMG using the same version and build numbers:

   ```sh
   ./build-dmg.sh
   ```

   Use `--local-build` when the repository is stored on a slow or network-mounted volume.

5. Install and smoke-test the generated `Project-Sync-VERSION.dmg`.
6. Generate the release-notes handoff:

   ```sh
   ./release-github.sh
   ```

7. Review `.release-notes-draft.md`, write `RELEASE_NOTES.md`, and explicitly publish:

   ```sh
   ./release-github.sh --publish
   ```

The publish phase rechecks the DMG checksum and size, requires a clean `main` at the exact commit recorded during the build, asks for confirmation, creates the tag and GitHub release, then atomically appends the signed release to `appcast.xml`.

The Sparkle EdDSA private key is stored in the login Keychain under account `project-sync`. Its committed public key is safe to distribute. Back up the private key somewhere secure and outside Git:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account project-sync \
  -x /secure/location/project-sync-sparkle-private-key.txt
```

`keyfile.txt` is gitignored and can be used as a portable signing-key fallback by `build-dmg.sh`. Losing the private key means existing Sparkle-enabled installations cannot trust future updates.

For Developer ID signing, set `PROJECT_SYNC_CODE_SIGN_IDENTITY` when building:

```sh
PROJECT_SYNC_CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./build-dmg.sh
```

The first Sparkle-enabled build must be installed manually. Releases after that can update it through the appcast hosted on `main`.

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
