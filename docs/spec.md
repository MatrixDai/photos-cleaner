# Apple Photos Cleaner — Design & Development Spec

Nov 2, 2026 · @Matrix Dai

## Overview

Apple Photos Cleaner is a single-window macOS app with two independent modes, run one at a time. It marks items for cleanup in Photos and never deletes anything itself; the user reviews the marked albums in Photos and deletes there.

| Mode | Scope | What it does | Albums |
| --- | --- | --- | --- |
| **Videos: export & cleanup** | Videos older than N days (default 90) | Exports the original and any edited version to a local folder, verifies by hash read-back, skips copies that already exist locally, marks the video. The app never rates videos; a video the user rated 3★ or higher is left alone. | `video-to-delete` |
| **Photos: rating & similar shots** | Every photo without stars, newest first, until none are left; or, with Re-rate, every photo taken within a date range | Rates each photo 1★–5★ as soon as it's analyzed, with one set of star thresholds (low-rated photos are found in Photos by filtering on stars), groups similar shots and marks them (Phase 4). Re-rate overwrites existing stars in its range. Photos are never exported. | `photo-duplicated` |

Everything goes through public PhotoKit and Vision APIs against the Mac's System Photo Library. There is no Apple ID login, no private iCloud API, no network traffic of its own, and no LLM.

Every step is a button the user presses, and nothing runs in the background:

1. **Videos:** Scan (read-only) finds the candidates; Export & Mark exports and marks them.
2. **Photos:** Rate Photos analyzes each photo and writes its stars as it goes. There is no separate scan or in-app review.
3. **Review in Photos**: open the album, filter by rating if useful, and delete what you don't want. Photos asks for confirmation, and deleted items sit in Recently Deleted for 30 days.

There is no Revert. To retune photo stars, adjust the thresholds and Re-rate a date range; to undo marks, remove items from the app's albums in Photos.

**Library context.** The user organizes the family Shared Library, so items in both the Personal and Shared Library count against the user's iCloud quota. Processing both libraries the same way is intended.

## Scope and non-goals

Version 1 ships the two modes above, each on a single page, plus a Settings page, persisted settings and an activity log.

Explicit non-goals:

- **Running both modes at once.** The app runs one job at a time. While one mode is working, the other mode's run buttons are disabled.
- **Deleting from the Photos library.** The app never deletes. The user deletes in Photos.
- **Exporting photos, or rating videos.** Photos are only rated and marked; videos are only exported and marked.
- **Rating screenshots.** Screenshots are always skipped. Every other image, camera or not, is rated.
- **Scheduling or background work.** No launchd, menu-bar agent, timers or login items. The app runs only while its window is open.
- **Cloud sync.** A separate cron job on the Raspberry Pi pushes the export folder to Aliyun.
- **Volume probing.** The export folder can be local, NFS or anything else. The app only checks that it is writable.
- **Non-system libraries.** PhotoKit only sees the System Photo Library.
- **LLMs.** Apple Foundation Models isn't available in the user's region, and a local Ollama model is unnecessary (see Photos mode).
- **Emptying Recently Deleted.** There is no public API. The app tells the user how to do it in Photos.
- **Telling Personal and Shared Library apart.** There is no public API, and the user doesn't need it.
- **App Store distribution.** It's a personal tool: no sandbox, signed to run locally.
- **Exact duplicates.** Photos' built-in Utilities › Duplicates and Merge already handle these; this app targets similar shots.

## Platform, stack and structure

The target is macOS 27 or later on Apple Silicon, built with Xcode 27 in Swift 6 language mode with strict concurrency. macOS 27 is required for `PHAsset.rating`, `PHAssetResource.dataSize` and `PHAssetResource.filename`.

| Area | Choice |
| --- | --- |
| App shell | SwiftUI lifecycle with a single `Window` scene (not `WindowGroup`), so only one window can exist |
| Apple frameworks | Photos (PhotoKit), Vision, AVFoundation (QuickTime metadata), ImageIO (EXIF), CryptoKit (SHA-256) |
| Persistence | Settings in a JSON file and the run log in a JSONL file, both through `Codable`; no third-party dependencies |
| Signing | Not sandboxed, Hardened Runtime on with the `com.apple.security.personal-information.photos-library` entitlement (without it Hardened Runtime blocks Photos), signed ad hoc to run locally |
| Info.plist | `NSPhotoLibraryUsageDescription`; request `PHAccessLevel.readWrite` |

**Startup checks.** The macOS 27 and Apple Silicon requirements are enforced by the build itself: the deployment target is macOS 27 and the binary is arm64-only, so macOS refuses to launch the app anywhere else. Every rating, resource and Vision API used is therefore present at runtime, and Phase 0 confirmed the Vision requests work on the user's Mac. The one thing that can change between launches is Photos access, which the user can revoke in System Settings at any time. On each launch the app checks that `PHPhotoLibrary.authorizationStatus(for: .readWrite)` is `.authorized`, requesting it on first launch. Otherwise it shows only a blocking screen that explains why full access is needed, with Open System Settings › Privacy › Photos and Check Again buttons.

```
photos-cleaner/
├─ Package.swift                   // one SwiftPM package; Xcode opens it directly
├─ App/          Info.plist, PhotosCleaner.entitlements
├─ scripts/      bundle.sh         // builds, assembles and signs build/PhotosCleaner.app
├─ Sources/
│  ├─ PhotosCleaner/               // SwiftUI app target
│  │  ├─ PhotosCleanerApp.swift    // Window scene, dependency injection
│  │  ├─ RootView.swift            // NavigationSplitView, status bar, access screen
│  │  └─ Features/                 // VideoPage, PhotoPage, SettingsPage, ActivityView
│  └─ CleanerCore/                 // library target, no SwiftUI imports
│     ├─ AppState/     AppModel.swift (@MainActor @Observable)
│     ├─ Library/      PhotoLibraryService.swift (protocol, AlbumService), LivePhotoLibrary.swift
│     ├─ Videos/       VideoScanner.swift, Exporter.swift, NamingEngine.swift,
│     │                CaptureDateResolver.swift, LocalFileIndex.swift, Verifier.swift, WritableCheck.swift
│     ├─ Photos/       PhotoRatingRun.swift, RatingScope.swift, LivePhotoAnalyzer.swift,
│     │                StarRater.swift, PhotoModel.swift, SequenceGrouper.swift, Clusterer.swift
│     ├─ Jobs/         JobRunner.swift (actor), JobCenter.swift, KeepAwake.swift
│     └─ Persistence/  RunLog.swift, AppSettings.swift, SettingsStore.swift
├─ Tests/CleanerCoreTests/
├─ Spikes/                         // Phase 0 spike app, its own package
└─ README.md
```

A SwiftPM package with `scripts/bundle.sh` replaces an `.xcodeproj`: `swift test` runs the tests, and the script builds an arm64 release, adds `Info.plist`, and signs the bundle ad hoc with Hardened Runtime and the Photos entitlement. With no signing identity installed, each rebuilt bundle counts as a new app to macOS, so Photos access is asked again after every rebuild.

Concurrency model:

- **Identifiers, not objects.** PhotoKit objects aren't `Sendable`, so only `localIdentifier` strings cross actor boundaries. Assets are re-fetched where they're used.
- **Write blocks are nonisolated.** PhotoKit runs a `performChanges` block on its own queue. A block written in `@MainActor` code inherits main-actor isolation, and Swift 6 stops the app when PhotoKit calls it; the compiler doesn't catch this, because PhotoKit's callbacks aren't annotated `@Sendable`. Every write goes through one nonisolated `PhotoLibraryService` method that takes an `@Sendable` block.
- **One job at a time, across both modes.** A single `JobRunner` actor runs one job (video scan, export, photo rating) and rejects a second. The UI disables every run button except Cancel while a job is active, and shows which mode is busy.
- **Progress and cancellation.** Jobs publish `AsyncStream<JobEvent>` for progress, item results and errors. They check `Task.isCancelled` between assets, and Cancel finishes the current file cleanly before stopping. While any job runs, the app holds a ProcessInfo.beginActivity token with the userInitiated and idleSystemSleepDisabled options, so the Mac doesn't idle-sleep and App Nap doesn't throttle a multi-hour export.
- **UI.** Models are `@MainActor @Observable`.
- **Testability.** `PhotoLibraryService` wraps all PhotoKit calls behind a protocol and has no delete method. `CleanerCore` logic (naming, dedupe, rating scope, star bands, write batching, clustering) is unit-tested with fakes.

## Safety invariants

These rules hold regardless of settings, and each one has a unit test.

1. **The app never deletes from Photos.** `PhotoLibraryService` has no delete method, and no code calls `PHAssetChangeRequest.deleteAssets`.
2. **One job at a time.** No two jobs run concurrently, in the same mode or across modes.
3. **A Videos scan is read-only.** It writes nothing: not to the Photos library, not to the export folder, and not to the app's own files.
4. **Writes need a button.** The Photos library is written only when the user presses Export & Mark or Rate Photos (confirmed again for Re-rate). The one exception is setup: at launch the app creates either of its two albums that is missing, empty. Each button label shows the count, e.g. "Export & Mark 38 videos".
5. **Only verified videos are marked.** A video is added to `video-to-delete` only after its export is verified by hash read-back.
6. **Never overwrite, never write outside the export folder.** Temporary files live in `<exportDir>/.photoscleaner-tmp/` and are renamed into place.
7. **No duplicate local copies.** If a just-downloaded video has the same size and SHA-256 as any file already in the export folder, the new copy is discarded and the existing file counts as its export.
8. **Existing ratings are kept unless the user re-rates.** A normal run selects only unrated photos and re-reads each rating just before writing, so a photo rated by hand during the run keeps its stars. Re-rate overwrites every photo in its range; the page says so beside the date fields, and Rate Photos asks for confirmation first. The app doesn't track who set a rating: app-set and user-set stars are treated the same.
9. **The app touches only its own albums.** It adds to and removes from `video-to-delete` and `photo-duplicated`, and nothing else. Removing an item from one of them by hand isn't remembered; to keep a photo or video, the user rates it 3★ or higher.
10. **Every run is logged.** Each run records what it changed (counts of files written, items added to and removed from each album, ratings written) and shows it in Activity.

## UI layout and settings

The window is a `NavigationSplitView` with four pages: Videos, Photos, Activity and Settings. Each mode lives on one page: only its scope at the top, results in the middle, and an action bar (Scan, Run, progress, Cancel) at the bottom. Every other setting, for both modes, is on the Settings page. Review happens in Photos itself, so there are no in-app review pages. The status bar sits below the split view, never over a page.

```
┌──────────────────┬───────────────────────────────────────────────────────────┐
│ VIDEOS           │ Photos · Rating & Similar Shots                           │
│   Export &       │ [ ] Re-rate photos taken from [2026-10-04] to [2026-11-04]│
│   Cleanup        │ ⓘ Rates every photo without stars, newest first           │
│ PHOTOS           ├───────────────────────────────────────────────────────────┤
│ ▸ Rating &       │       ★     ★★    ★★★    ★★★★   ★★★★★                     │
│   Similar Shots  │      120    340   1,210   2,050    400                    │
│ APP              │   4,120 rated · 410 screenshots skipped · 6 failed        │
│   Activity       │   4,536 of 24,518 photos · now at Mar 2024 · 0:41:12      │
│   Settings       │                                                           │
│                  ├───────────────────────────────────────────────────────────┤
│                  │ [Rate Photos]               ███░░ 4,536/24,518 [Cancel]   │
├──────────────────┴───────────────────────────────────────────────────────────┤
│ Photos: full access ✓ │ Busy: Photos rate │ 4,120 rated · 1★ 120 2★ 340 …    │
└──────────────────────────────────────────────────────────────────────────────┘
```

Pages:

- **Videos · Export & Cleanup:** older than N days, a results table (date, name, size, status, file) and the action bar: Scan, Export & Mark N, progress, Cancel.
- **Photos · Rating & Similar Shots:** a Re-rate checkbox with a from–to date range and a hint line; a progress panel (see Photos mode); and the action bar: Rate Photos, progress, Cancel. Phase 4 adds the De-dup checkbox and the similar-shot counts.
- **Activity:** the run log, an album summary (each app album's current size and the change since the last run, e.g. "video-to-delete: 12 videos, 38 fewer than after the last run").
- **Settings:** a Videos section (export folder with Choose…, Reveal in Finder and writable badge; file name template with live preview; parallel exports; album name), a Photos section (star thresholds, the similar-shots album name) and a Data section (the data folder with Reveal in Finder, and Reset all settings).

**Busy state.** While a job runs, the status bar shows the busy mode and progress on every page. Scan, Export and Rate buttons in both modes are disabled until it finishes or is cancelled. Switching pages during a job is allowed.

**Re-rate hint.** With Re-rate checked, the line under the options reads "Every photo in this range is rated again, overwriting its existing stars. Use a short range to try new thresholds." Rate Photos then asks for confirmation before it starts.

**Status bar,** from left: Photos authorization, busy state (with "Keeping Mac awake" while a job runs), then mode-specific detail. On Videos pages that's the export folder's writable state and free space (from `volumeAvailableCapacityForImportantUsageKey`, falling back to `volumeAvailableCapacityKey`, hidden if neither is available). On Photos pages it's the latest run's photos rated and the count at each star. Export & Mark warns when the planned size exceeds free space.

**Writable check.** It runs at launch, when the export folder changes and before each export job. A folder that doesn't exist yet, such as the default `~/Downloads/PhotosCleaner/Videos`, isn't an error: the page shows "Created on first export", and Export & Mark creates it just before its own check. It creates `.photoscleaner-write-test-<uuid>` in the folder, writes 1 byte, reads it back and deletes it. It doesn't inspect the filesystem type.

Persistence:

- `AppSettings` is one `Codable` struct with a `schemaVersion` and a section per mode, saved as `~/.photos-cleaner/settings.json`. Saves are debounced by 500 ms after any change, and the file is written atomically.
- Decoding uses `decodeIfPresent` with defaults for every field, so adding a field never loses the rest. If the file is corrupt, it is renamed to `settings.corrupt-<date>.json` and defaults are loaded.
- The export folder is stored as both a path and bookmark data. The bookmark keeps working if the folder is renamed; the path covers volumes that are remounted.
- Window state uses `@SceneStorage` for the selected sidebar page, plus window frame autosave.

## Videos mode: export & cleanup

Videos mode exports every video older than N days (default 90) to `<exportDir>/<yyyy>/<yyyy-MM-dd> <original name>`, verifies each file, keeps only one local copy of identical content, then adds the video to `video-to-delete`. The app never rates videos; it only respects stars the user set, where 3★ or higher means keep.

**Settings:** older than N days on the Export & Cleanup page; export folder, file name template, parallel exports (1–4, default 2) and album name on the Settings page.

**Fixed behavior:** favorites are included, hidden videos are excluded, videos the user rated 3★ or higher are skipped entirely (not exported, not marked, and removed from video-to-delete if already there), edited versions are always exported alongside the original, and the file date is always the capture date.

**Scan.** Fetch with `PHFetchOptions` using the predicate `mediaType == video AND creationDate < now − N days`, with `includeHiddenAssets = false`, sorted by `creationDate` ascending. Take sizes from `PHAssetResource.dataSize`. Videos already in `video-to-delete` show `marked` and are skipped: only verified videos are ever added there, so membership is the record that a video is exported. Nothing else is stored about exports. Adding a video to the album by hand, or removing its exported file, is outside what the app guards against.

**Local file index** (`LocalFileIndex`). At the start of each export job, enumerate the export folder recursively (skipping `.photoscleaner-tmp`) into a map of file size → paths. An existing file is hashed only when its size matches a new download, so a 4 TB folder is never hashed in full; hashes aren't stored. Files from earlier tools, such as old icloudpd downloads, take part like any other file.

**Export pipeline**, per asset:

1. **Pick resources.** Always `.video` (the original). If `.fullSizeVideo` exists, also export it under the same template with ` (edited)` before the extension, e.g. `2026-02-28 IMG_0001 (edited).MOV`. Its name tokens come from the original `.video` resource, since the edited resource's own filename is usually `FullSizeRender.mov`. Each resource goes through steps 2–8.
2. **Stream to a temp file.** Call `PHAssetResourceManager.requestData` with `isNetworkAccessAllowed = true`. Write each chunk to `<exportDir>/.photoscleaner-tmp/<uuid>.<ext>` and update a running SHA-256 (CryptoKit). Report progress for iCloud downloads. Close the file and call `synchronize()` at the end.
3. **Skip if already local.** Look up the new file's size in the index. For any existing file of the same size, compare SHA-256. On a match, delete the temp file and count the existing file as this resource's export; the video shows `already local`. Bytes must be downloaded to be compared, but no second copy is kept.
4. **Resolve the capture date** (`CaptureDateResolver`). iPhone `.MOV` files carry the date below; `.mp4` files from chat and Android apps usually carry neither it nor `AVAsset.creationDate`, so they take the last fallback. Read `AVMetadataIdentifier.quickTimeMetadataCreationDate` from the temp file. It's an ISO 8601 string with a UTC offset (e.g. `2026-02-28T23:14:05+0800`). Format `yyyy-MM-dd` in that offset's time zone, so the date is the local date where the video was recorded. Fallbacks, in order: `AVAsset.creationDate`, then `PHAsset.creationDate` in the system time zone. Record which source was used.
5. **Build the name** (`NamingEngine`). The default template is `{yyyy}/{yyyy}-{MM}-{dd} {filename}`. Tokens: `{yyyy} {MM} {dd} {filename} {basename} {ext}`. The filename comes from `PHAssetResource.filename`. Replace `/` and `:` with `_`, normalize to Unicode NFC (the files will be read on Linux) and trim whitespace.
6. **Handle name collisions.** If the target path exists, its content is different (identical content was caught in step 3), so try ` (2)`, ` (3)` and so on before the extension, e.g. `2026-02-28 IMG_0001 (2).MOV`. Never overwrite.
7. **Move into place.** If the export folder itself has vanished, stop: recreating it would write onto the boot disk when an external volume was unmounted. Otherwise create the year folder if needed, then `FileManager.moveItem` from temp to the final path. Both are on the same volume, so the rename is atomic. Add the file to the index.
8. **Verify.** Re-read the final file, compute SHA-256 and compare it with the write-time hash. Also check the size against `dataSize` when that's available. On mismatch, delete the final file and mark the video `failed`.

**Mark.** A video is marked once all its resources are verified, whether written or already local. Marks are written during the job in batches of 10 videos, and the pending batch is written before Cancel stops, so a crash leaves at most 10 verified videos unmarked. The next run downloads those again, finds them already local, and marks them without a second copy.

Every Export & Mark also removes from `video-to-delete` each video the user has since rated 3★ or higher, even when there is nothing new to export. Rating a video 3★+ in Photos is how to keep it.

**Throughput.** Exports run in parallel per the setting; iCloud downloads are the bottleneck. iCloud errors retry 3 times with backoff of 5 s, 30 s and 120 s, then mark the video `failed` and move on. A failed video isn't marked, so the next run retries it. Live Photo motion clips are image assets, so the `mediaType == video` predicate already excludes them.

**Deleting.** Deleting happens in Photos: open the album, select all, press ⌘⌫, then empty Recently Deleted to free the space right away.

## Photos mode: rating & similar shots

Photos mode rates photos 1★–5★ with one rule — four star thresholds — and writes each photo's stars as soon as it's analyzed. There is no review step in the app and no album for low-rated photos: Photos already filters by star, so the user reviews and deletes 1★–2★ photos there. Phase 4 adds grouping of similar shots taken close together, which adds them, whatever their stars, only to `photo-duplicated`. It never exports or deletes photos, and no LLM is involved.

**Options,** on the Rating & Similar Shots page, held in memory and reset at each launch:

- **Re-rate photos taken from … to …:** off by default; the range defaults to the last month, both days inclusive.
- **De-dup** (Phase 4): on by default, with the tip that suspected similar shots go to `photo-duplicated`.

On the Settings page: **Star thresholds** and the similar-shots album name.

**What a run selects** (`RatingScope`). Image assets only; hidden photos excluded, favorites included, screenshots (`mediaSubtypes` contains `.photoScreenshot`) skipped without reading any image.

| | **Normal** | **Re-rate** |
| --- | --- | --- |
| Fetch | `rating == 0`, the whole library | 00:00 on the first day to 24:00 on the last, system time zone; Rate Photos is disabled if the end is before the start |
| Order | Newest first | Newest first |
| Writes | Only photos still unrated just before the write | Every photo in the range, overwriting existing stars, after a confirmation |
| Nothing found | "Every photo already has stars." | "No photos were taken in this range." |

**No progress record.** The rating itself records progress: a rated photo drops out of the next normal run's fetch, and PhotoKit applies `rating == 0` itself, so rated photos cost nothing to skip. Nothing is stored per photo or per run. The user can cancel or quit at any time; the next run continues with whatever is still unrated, newest first. The photos that stay unrated are screenshots, which are skipped from metadata alone, and failed analyses, which every run retries. Old photos imported later are unrated, so the next run picks them up. Every image is rated, camera or not: no original is downloaded for an EXIF check (Phase 0 measured 1–3 s per iCloud-only original), so the only per-photo cost is the local preview the analysis reads.

**Analysis.** One pass per photo computes everything this mode needs, and nothing from it is stored:

- **Aesthetics:** Vision `CalculateImageAestheticsScoresRequest` (macOS 15+) returns `overallScore`, from −1 (poor) to 1 (excellent). It already penalizes blur, bad exposure and poor framing. Input is a 1024×1024 aspect-fit derivative from `PHImageManager.requestImage` (`deliveryMode = .highQualityFormat`, `resizeMode = .fast`, `isNetworkAccessAllowed = true`), not the full original.
- **Feature print** (Phase 4, De-dup on), in memory only and never written to disk, for photos that have another photo within 30 s (see Similar shots). It is computed from the same derivative, scaled to 512 px, so no second download is needed. The request revision is pinned to the one calibrated in Phase 0, because distances and thresholds from different revisions aren't comparable.

**Streaming and writes** (`PhotoRatingRun`). Up to 4 analyses run at once. Each photo's stars join a pending batch, which is written with `PHAssetChangeRequest.rating` in one `performChanges` call once it holds 20 photos or 5 s have passed since the last write, and once more when the run ends or is cancelled. Use the `PHAsset.Rating` case names from the SDK (unset plus 1–5 stars). Before each write the current ratings are re-read: a photo deleted meanwhile is skipped, in a normal run a photo rated by hand meanwhile keeps its stars, and a photo already at its target stars isn't written again. Cancel stops before the next group of analyses: the photos being analyzed when it was pressed are dropped and stay unrated, and the pending stars are written before the job ends. A run whose first 8 analyses all fail, with nothing rated, aborts and shows the error.

**Star rating** (`StarRater`). Starting thresholds are −0.3, 0.0, 0.3 and 0.6: below −0.3 is 1★, −0.3 to 0.0 is 2★, 0.0 to 0.3 is 3★, 0.3 to 0.6 is 4★, and 0.6 or above is 5★. This is the app's only rating rule; similar shots get no special treatment, so a group can be all 4–5★ or all 1–2★. There is no preview, so calibrate before the first full run: in Phase 0, 20 photos from 1999–2007 scored 0.32–0.80, which the starting values would mostly rate 4★. Re-rate a short range, check the stars in Photos, adjust the thresholds on the Settings page and re-rate again; then rate the whole library. A normal run rates only unrated photos, so new thresholds reach photos rated earlier only through Re-rate.

**Progress panel.** The middle of the page shows, live: the count at each star, 1★ to 5★; photos rated; existing stars overwritten (Re-rate); screenshots skipped; analyses failed; photos done of the run's total; the capture date of the latest photo analyzed; and the elapsed time. The numbers stay after the run until the next one starts. With De-dup on it also shows "Similar shots: N groups · P photos · A added to photo-duplicated", plus how many were removed when any were. Each run logs one line in `runs.jsonl` with the same counts (`groups`, `grouped`, `addedDuplicated`, `removedDuplicated` for similar shots).

**Similar shots** (Phase 4; `SequenceGrouper`, `Clusterer`). Vision feature prints reliably catch near-identical frames: the same scene seconds apart, with slight movement or exposure change. They're weaker across different crops or zoom levels, and can over-group visually similar but distinct moments. Grouping covers only the photos the current run selects — unrated ones, or every photo in the Re-rate range — and nothing about it is saved. A photo the user already rated is not grouped by a normal run. With De-dup off, no feature print is computed and the album is left alone.

- **Sequences:** similar shots are retakes seconds apart, so a photo is only ever compared with photos taken within 30 s of it; two similar photos years apart are not a goal. The run walks photos newest first, and consecutive photos at most 30 s apart form a sequence; a sequence is complete when the next photo is more than 30 s older. A photo with no other photo within 30 s gets no feature print. Bursts aren't expanded (`includeAllBurstAssets = false`); Photos already manages burst picks.
- **Comparison per sequence:** the run analyzes whole sequences at a time, still 4 photos at once. Within a sequence, each photo's print is compared with the prints of the photos taken up to 30 s before it, and union-find joins pairs at or below the distance threshold. Prints live in memory only until their sequence is grouped, then are discarded. A photo whose analysis fails has no print and joins no group.
- **Group cap:** a group holds at most 100 photos. Once a group reaches 100, it is closed and later photos in the sequence start a new group.
- **Chain guard:** when a sequence is complete, drop any member whose distance to its group's medoid exceeds the threshold × 1.5, then re-run on what was dropped. Keep groups of 2 or more.
- **One fixed threshold:** the distance threshold is an internal constant chosen in Phase 0 from the user's library. There is no Similarity setting; changing the constant affects only later runs.
- **Writes per sequence:** pending stars are written only between sequences, together with the album changes, so a cancelled run never splits a sequence between runs. A sequence longer than 20 photos is written as one batch.
- **Album sync:** add the members of the sequence's groups to `photo-duplicated`; with Re-rate, also remove the range's analyzed photos that are in no group. A normal run never removes on grouping, because it doesn't see the rated photos a group may still hold. At the end of every run with De-dup on, cancelled or not, remove any album member that no longer has another member within 30 s, such as the one shot left after the user deleted the rest of its group. This check uses only creation dates, so earlier groups don't need to be stored.

**User review in Photos.** In the library, filter by 1★ or 2★ to see the low-rated photos, or open `photo-duplicated`, where similar shots sit next to each other because the album sorts by date. Delete what you don't want. If the stars feel wrong, adjust the thresholds on the Settings page, then Re-rate that date range.

**Keeping a photo.** Raise it to 3★ or higher in Photos; normal runs never change existing stars. Re-rate does, so after one, re-check the photos you meant to keep. In `photo-duplicated`, a shot drops out of the album once the rest of its group is deleted. Removing an item from an album by hand isn't remembered, so the next run may add it back.

**Why no Ollama.** Vision's aesthetics model is built for this, runs on the Neural Engine and gives consistent scores. A local vision LLM would be far slower per image, use a lot of RAM, and produce scores that are hard to calibrate across tens of thousands of photos. Vision aesthetics is a Vision framework feature, not Apple Intelligence, and Phase 0 confirmed it works in the user's region.

## Data model

All state lives in `~/.photos-cleaner/`, which the app creates at launch if it's missing:

```
~/.photos-cleaner/
├─ settings.json   settings of each mode
└─ runs.jsonl      one line per finished run
```

`settings.json`:

```json
{
  "schemaVersion": 1,
  "videos": {
    "exportDir": { "path": "~/Downloads/PhotosCleaner/Videos", "bookmark": "<base64>" },
    "olderThanDays": 90,
    "nameTemplate": "{yyyy}/{yyyy}-{MM}-{dd} {filename}",
    "parallelExports": 2,
    "album": { "name": "video-to-delete", "id": null }
  },
  "photos": {
    "starThresholds": [-0.3, 0.0, 0.3, 0.6],
    "albums": {
      "duplicated": { "name": "photo-duplicated", "id": null }
    }
  }
}
```

The Photos page's options (Re-rate and its range, De-dup) aren't saved. Keys from earlier versions, such as `scope`, `cameraPhotosPerRun` and `resumeAfter`, are ignored. The albums are top-level albums in Photos. Each album's `id` stores its `localIdentifier`, so the app still finds it after the user renames it. If an id no longer resolves, the app looks the album up by name, and creates it if it's missing.

`runs.jsonl` is the activity log: one JSON object per finished run, appended and flushed when the run ends. A line that doesn't parse, such as one cut off by a crash, is skipped. Missing fields get defaults, so adding a field needs no migration.

```jsonl
{"run":12,"mode":"photos","task":"rate","scope":"unrated","start":"2026-11-04T11:39:58Z","end":"2026-11-04T12:21:10Z","outcome":"completed","counts":{"photos":4536,"processed":4536,"rated":4120,"overwritten":0,"screenshots":410,"failed":6,"stars1":120,"stars2":340,"stars3":1210,"stars4":2050,"stars5":400},"albums":{"photoDuplicated":0,"videoToDelete":12}}
```

Nothing is stored per photo or per video. Album membership isn't stored: the albums in Photos are the source of truth, and the app re-fetches them when it needs them.

**Album summary.** Each run's line in `runs.jsonl` includes the size of every app album when it ended, keyed by role (`videoToDelete`, `photoDuplicated`) so renaming an album doesn't break the comparison. Activity compares that with the albums' current sizes, so it can say how many items the user deleted in Photos since the last run without tracking individual assets.


## Edge cases and error handling

The rule throughout: a failure skips the affected item and is logged; only conditions that make every further item fail abort the job.

| Mode | Situation | Behavior |
| --- | --- | --- |
| Both | Photos access denied or limited | Startup check shows the blocking screen with Open System Settings › Privacy › Photos and Check Again |
| Both | User starts a job while another runs | Not possible: run buttons are disabled; the status bar shows the busy mode |
| Both | User cancels | Finish or discard the current item, then stop; nothing partial is marked `verified` or rated |
| Both | Asset deleted in Photos mid-job | Skip it |
| Both | App album renamed or deleted in Photos | Find by stored id, then by name, else recreate |
| Both | User removes an app-marked item from its album in Photos | Not remembered; the next run may add it back. To keep a photo or video, rate it 3★ or higher |
| Videos | Export folder not writable at job start | Block the job; show a ✗ badge with the error text |
| Videos | Folder disappears mid-job (unmount, network drop) | Abort after writing the pending mark batch, without recreating the folder; the current temp file is left for cleanup |
| Videos | Export folder doesn't exist yet | Shown as "Created on first export"; Export & Mark creates it |
| Videos | Disk full during write | Abort, delete the current temp file, show the free-space figure |
| Videos | iCloud download fails or times out | Retry 3× (5 s, 30 s, 120 s), then mark `failed` and continue |
| Videos | Downloaded video identical to an existing local file | Discard the new copy, count the existing file, show `already local` |
| Videos | Same name and date, different content | Suffix ` (2)`, ` (3)`… before the extension — never overwrite |
| Videos | Two library assets with identical content | Both point to the same local file; both are marked |
| Videos | Crash mid-job | At most one batch of 10 verified videos is unmarked; the next run re-downloads them, finds them already local and marks them |
| Videos | Stale temp files from a crash | At launch, delete files in `.photoscleaner-tmp/` older than 24 h |
| Videos | QuickTime date missing or unparseable | Fall back to `AVAsset.creationDate`, then `PHAsset.creationDate` in system time; the results table shows which source was used |
| Videos | Filename contains `/`, `:` or odd Unicode | Sanitize to `_`, normalize NFC |
| Videos | Files over 4 GB | No special case: streaming handles them |
| Photos | Re-rate end date before start | Rate Photos disabled, inline error |
| Photos | Every photo already has stars | The run reports "Every photo already has stars." |
| Photos | Analysis of a photo fails | Skipped; it stays unrated and the next run retries it |
| Photos | Photo rated by hand during a normal run | Its stars are kept: ratings are re-read before each write |
| Photos | Re-rate would overwrite existing stars | The hint beside the dates says so, and Rate Photos asks for confirmation |
| Photos | User cancels or the app quits mid-run | Stars already written stay; at most one pending batch of 20 is lost and redone by the next run |
| Photos | More than 100 similar shots in a row | The group closes at 100; later shots start a new group |
| Photos | A Vision request fails on every photo (e.g. after an OS update) | Abort after 8 failures with nothing rated and show the Vision error, per the rule above |
| Photos | Very large library (50k+ photos) | One fetch of identifiers, 4 concurrent analyses, writes of 20 |

## Phase 0: API spikes and open risks

Before building features, a throwaway spike target answers these questions on the user's Mac and library. Each answer is recorded in `docs/spikes.md`, and the spec is updated where the answer changes the design.

All answered in `docs/spikes.md` (Phase 0, 2026-11-03):

- [x] **Rating write prompts.** No system prompt when writing ratings, in one batch or per photo; a write takes about 0.02 s.
- [x] **Shared Library in albums.** Shared Library photos can be added to and removed from a personal album.
- [x] **EXIF read cost.** A full original download per iCloud-only photo, about 1–3 s; this is why there is no camera check.
- [x] **Vision aesthetics availability.** Works in the user's region, about 10 ms per photo.
- [x] **Similarity calibration.** Threshold 0.20 with feature-print `revision2`; 30 s catches retakes.
- [x] **dataSize and progress.** `dataSize` is present for iCloud-only videos; the progress handler fires.
- [x] **Rating API details.** `PHAsset.Rating` is `.unset`, `.one` … `.five`; `rating` works in fetch predicates (`rating == 0`, `rating >= 3`).
- [x] **Album ids.** The album was found by `localIdentifier`; the rename itself didn't reach PhotoKit before the check, so the by-name fallback stays.
- [ ] **Shared metadata (informational).** Not checked: no other participant's device was available.
- [x] **QuickTime dates.** iPhone `.MOV` files carry the offset (`+0800`); app-made `.mp4` files have no embedded date.

## Implementation phases

Build in six phases. Each ends with its acceptance criteria passing and the app usable for what exists so far. Videos mode — the user's main goal — is complete at the end of Phase 2.

1. **Phase 0 — Spikes.** Answer every Phase 0 question.
   - *Done when:* `docs/spikes.md` has an answer for each item, and the spec is amended where needed.
2. **Phase 1 — Skeleton.** App shell, sidebar with Videos and Photos sections, status bar with busy state, Photos authorization, `SettingsStore` with per-mode sections, `RunLog`, `JobRunner` enforcing one job at a time and keeping the Mac awake while it runs, Activity page, creation of the app's albums. Until real jobs exist, a temporary Run Test Job button on each mode page exercises the busy state; Phase 2 and 3 replace it.
   - *Done when:* a missing `~/.photos-cleaner/` is created at launch; with Photos access denied, the app shows only the blocking screen; settings of each mode survive a relaunch independently; a corrupt `settings.json` falls back to defaults without a crash; a `runs.jsonl` whose last line was cut off loads without that line; starting a fake job in one mode disables run buttons in both; the app's albums appear in Photos.
3. **Phase 2 — Videos mode.** Settings group, writable check, scan, `LocalFileIndex`, export pipeline with edited versions, `CaptureDateResolver`, `NamingEngine`, verify, mark in batches, album summary.
   - *Done when:* exporting 20 test videos produces `<dir>/<yyyy>/<yyyy-MM-dd> <name>` files whose SHA-256 matches the originals; an edited video also produces its `(edited)` file; a video recorded at 23:30 UTC+8 is named with its local date; a video already present under another name is not copied again; a same-name, different-content video gets ` (2)` before its extension; rerunning exports nothing new; pulling the network mid-run leaves no video in `video-to-delete` without its verified file; every verified video is in `video-to-delete`; killing the app mid-run and rerunning creates no second copy; videos deleted in Photos show in the Activity album summary; a video rated 3★ in Photos is not exported and leaves video-to-delete on the next run.
   - Unit tests cover the naming engine (tokens, sanitizing, NFC, collisions), the date resolver (offsets, missing metadata, fallback order) and dedupe (size prefilter, hash match).
4. **Phase 3 — Photos mode: rating.** `RatingScope` (normal and Re-rate), `PhotoRatingRun` streaming analysis with batched writes, the progress panel.
   - *Done when:* screenshots are never rated; a run rates every unrated photo, newest first, writing stars in batches as it goes; cancelling keeps the stars already written, and the next run continues with the photos still unrated; a photo rated by hand during a run keeps its stars; a run with nothing left says so; failed analyses stay unrated and the next run retries them; Re-rate overwrites stars only inside its range, after a confirmation; new thresholds apply from the next run; the panel's per-star counts match the stars written; nothing touches an album until Phase 4.
   - Unit tests cover range boundaries (first and last day, time zone), the star rater (scores exactly on each threshold), write batching, cancellation and the hand-rated guard.
5. **Phase 4 — Photos mode: similar shots.** De-dup checkbox, sequences over the streaming run, feature prints, grouping with group cap and chain guard, writes per sequence, `photo-duplicated` sync, similar-shot counts in the panel.
   - *Done when:* with De-dup off, no feature print is computed and the album is untouched; on a hand-labeled set of 50 similar-shot groups and 50 distinct photos at the calibrated threshold, at least 90% of the groups are found and no more than 5% of distinct photos are wrongly grouped; group members get exactly the stars the thresholds give them; a group member leaves photo-duplicated once its group dissolves.
   - Unit tests cover the clusterer (synthetic distance matrices, chain guard), sequence splitting (30 s gaps), the 100-photo group cap, writes that never split a sequence, Re-rate removals and lonely-member removal.
6. **Phase 5 — Polish.** Activity filtering, error copy, keyboard shortcuts (⌘R scan, ⌘. cancel), empty states, README with setup and permissions.

## Defaults

Each mode has its own settings, persisted in `settings.json`. Everything else is fixed behavior or an internal constant, not exposed in the UI.

**Videos mode settings:**

| Setting | Default | Range / notes |
| --- | --- | --- |
| Export folder | `~/Downloads/PhotosCleaner/Videos` | Any writable folder |
| Older than | 90 days | 1–3650 |
| File name template | `{yyyy}/{yyyy}-{MM}-{dd} {filename}` | Tokens: `{yyyy} {MM} {dd} {filename} {basename} {ext}` |
| Parallel exports | 2 | 1–4 |
| Album name | `video-to-delete` | — |

**Photos mode settings:**

| Setting | Default | Range / notes |
| --- | --- | --- |
| Re-rate | Off; range is the last month | Not saved; both days inclusive; overwrites existing stars in the range |
| De-dup (Phase 4) | On | Not saved |
| Star thresholds | −0.3 / 0.0 / 0.3 / 0.6 | −1 to 1; set on the Settings page |
| Album name | `photo-duplicated` | — |

**Fixed behavior:**

| Behavior | Rule |
| --- | --- |
| Jobs | One at a time, across both modes |
| Deleting from Photos | Never done by the app |
| Photos | Rated and marked only; never exported |
| Videos | Exported and marked only; never rated by the app. A video the user rated 3★ or higher is skipped, and so is one already in `video-to-delete` |
| File date | Capture date from file metadata; fallback in the system time zone |
| Favorites | Included in both modes |
| Hidden items | Excluded in both modes |
| Edited videos | Edited version always exported alongside the original |
| Screenshots | Always skipped; every other image is rated, camera or not |
| Photo order | Newest first |
| Local duplicates | An identical file already in the export folder is reused, never copied again |
| Rating rule | One rule for every photo: the four star thresholds |
| Low-rated photos | No album: filter by 1★ or 2★ in Photos to review and delete them |

**Internal constants** (in code, adjusted by the developer only):

| Constant | Value |
| --- | --- |
| Similar-shot distance threshold | 0.20 (feature-print `revision2`), set in Phase 0 from calibration |
| Chain guard | Member distance to group medoid ≤ threshold × 1.5 (0.30) |
| Similar-shot window | 30 s; a photo is compared only with photos taken within 30 s of it |
| Similar-shot group cap | 100 photos |
| Video mark batch | 10 videos per `performChanges` |
| Rating write batch | 20 photos or 5 s, whichever comes first, per `performChanges`; writes raise no system prompt |
| Rating abort | 8 failed analyses with nothing rated |
| Concurrent analyses | 4 |
| iCloud retry backoff | 5 s, 30 s, 120 s |
| Stale temp file age | 24 h |
