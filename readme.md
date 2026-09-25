# photoshare

An application which has one job: to let users rapidly review photos living on a remote Linux server with SFTP and one-click-import the good ones straight into a Photos.app library on a Mac (which already syncs to iCloud). 
It was designed entirely by Claude so that my girlfriend can import photos on her (disk-limited) Macbook that I already backed up for her on my (not-so-disk-limited) server.

## Layout

- `App/` — SwiftUI app (setup screen, gallery, preview, import button).
- `Packages/PhotoSyncCore/` — all logic, unit-tested without a server or Photos:
  SFTP client (Citadel) with separate channels for scanning, browsing and importing;
  EXIF/JPEG/CR3 header parsers; file fingerprints; GRDB index; RAW+JPEG pairing;
  thumbnail/preview cache; import queue (PhotoKit `.photo` + `.alternatePhoto`).
- `project.yml` — XcodeGen spec for `PhotoSync.xcodeproj`.
- `spikes/` — throwaway Phase 0 experiments (PhotoKit pair import, Citadel benchmarks).

## Build & run

```sh
xcodegen generate                      # after adding/removing files
open PhotoSync.xcodeproj               # then Run (⌘R)
cd Packages/PhotoSyncCore && swift test
```

Build from Xcode or with xcodebuild's default DerivedData: building into a folder
under `~/Documents` makes codesign fail ("resource fork … detritus not allowed").

First launch shows a one-time setup: server address, port, username, folders
(`.` = everything), and a key (pick the existing `~/.ssh/id_ed25519`, or create a new
one and add the shown line to the server's `authorized_keys`). The server's host key
is pinned on that first connect.

**Debug builds** import at most 5 photos per launch and log every created asset;
*Debug → Revert Test Imports…* deletes them (then empty them from Recently Deleted).
Build **Release** for everyday use.

## Developer CLI

`swift run -c release photosync-cli` in `Packages/PhotoSyncCore`:
`scan <host> <user> <root>…`, `thumbs <host> <user> <outdir> <photoId>…`,
`meta <files>…`, `stats`. Uses `~/.ssh/id_ed25519` and the `known_hosts` entry,
and its own index under `~/Library/Application Support/PhotoSync-cli`.
