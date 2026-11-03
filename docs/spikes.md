# Phase 0 — Spike results

Answers to the Phase 0 questions in `docs/spec.md`, measured on the user's Mac (macOS 27.0.1, Xcode 27.2, Apple Silicon) and library. The spike app lives in `Spikes/`; raw reports land in `~/.photos-cleaner/spikes/`.

## How to run

```sh
Spikes/bundle.sh          # builds and ad-hoc signs Spikes/build/PhotosSpike.app
open Spikes/build/PhotosSpike.app
```

Grant full Photos access on first launch. Read-only spikes can run in any order. Write spikes ask before touching the library, and each one undoes its own changes.

## Answered from the macOS 27.2 SDK

- **Rating API.** `PHAsset.rating` is read-only and `PHAssetChangeRequest.rating` is read-write, both of type `PHAsset.Rating` with the cases `.unset`, `.one`, `.two`, `.three`, `.four` and `.five` (raw values 0–5), available from macOS 27. Whether `rating` works in a fetch predicate is measured below.
- **Resource metadata.** `PHAssetResource.filename` (macOS 27) replaces the deprecated `originalFilename`. `PHAssetResource.dataSize` exists from macOS 27, as `Int?` in Swift. Whether it's filled for iCloud-only assets is measured below.
- **Camera-origin signal.** There is none. No PhotoKit API exposes "captured by a camera". `PHAssetExtendedMetadata` has only caption, keywords and original filename, so the EXIF check is required.
- **Vision revisions.** In the Swift Vision API, `GenerateImageFeaturePrintRequest` offers only `revision2` and `CalculateImageAestheticsScoresRequest` only `revision1`. `ImageAestheticsScoresObservation` has `overallScore` and `isUtility`.
- **Hardened Runtime.** The spec asks for Hardened Runtime. With it on, accessing Photos needs the `com.apple.security.personal-information.photos-library` entitlement, so Phase 1 must add it. The throwaway spike is signed without Hardened Runtime.

## Measured on the library

Library at the time: 24,518 images (screenshots excluded) and 182 videos, with "Optimize Mac Storage" on. Every one of 600 probed photo originals and 172 of 182 video originals were iCloud-only.

| Question | Answer |
| --- | --- |
| `rating` in a fetch predicate | Accepted: `rating == 0`, `rating > 0` and `rating >= 3` run without an exception in 0.01 s. Every photo was unrated, so whether the predicate really filters is re-checked while the rating-writes spike has ratings set. Reading `rating` in memory for all 24,518 photos also takes 0.01 s, so in-memory filtering is a safe fallback. |
| `dataSize` for iCloud-only videos | Present for all 182 videos, including the 172 iCloud-only ones, and equal to the downloaded byte count. |
| Download progress | The progress handler fired 2–18 times per video download (2–4 MB files). |
| QuickTime creation date | iPhone `.MOV` files carry `quickTimeMetadataCreationDate` with an offset (`2026-02-20T14:40:04+0800`). The `.mp4` files from WeChat, Android and other apps (8 of the 10 sampled) have neither that key nor `AVAsset.creationDate`, so they fall back to `PHAsset.creationDate` in the system time zone. |
| EXIF read cost | Cancelling after the header saves nothing for iCloud-only originals: PhotoKit delivered the whole file before the first chunk (median 100% of the file size), and the header read took as long as a full download (median 1.1 s and 1.2 s, p90 3.1 s and 1.8 s). Checking a photo's camera EXIF therefore means downloading its original. 193 of 200 sampled originals had Make/Model (iPhones, plus Samsung, Olympus, Canon, Nikon, Sony and Nokia cameras from the 2000s). The sample was the oldest photos, which are small JPEGs; modern HEIC originals will take longer. |
| Vision aesthetics | Works under the user's account and region (`revision1`), about 10 ms per photo. Scores on 20 photos from 1999–2007 ranged 0.32–0.80 (median 0.47); one was flagged `isUtility`. Fetching the 1024 px derivative took under 0.1 s even for iCloud-only photos, because Photos keeps previews locally. With the default thresholds (−0.3 / 0.0 / 0.3 / 0.6) most of these would be 4★, so Phase 3 should expect to retune them. |
| Similarity threshold | Feature-print `revision2`. Of 2,000 oldest photos, 1,679 sat in 381 sequences of two or more within 30 s. Nearest-neighbour distance: median 0.15, p90 0.40. The user reviewed the sample pairs and chose **0.20** as the threshold; the chain guard then allows 0.30 to the group's medoid. |
| 30 s window catches retakes | Yes: 84% of photos in the sample had a neighbour within 30 s, and the user confirmed the pairs below 0.20 are retakes. |
| Rating write prompts | _pending: the first run crashed before writing (fixed)_ |
| Shared Library assets in a personal album | _pending_ |
| Album found by `localIdentifier` after rename | _pending_ |
| Ratings on Shared Library assets sync to other participants (informational) | _pending_ |

## Lessons for the app

- **Write blocks must not be main-actor isolated.** A `performChanges` block written inside `@MainActor` code is treated as main-actor only, and PhotoKit runs it on its own queue, so Swift 6 stops the app with `dispatch_assert_queue_fail`. The compiler doesn't catch it, because PhotoKit's callbacks aren't annotated `@Sendable`. Route every `performChanges` through a nonisolated helper that takes an `@Sendable` block, as `Library.change` does in the spike.
- **The EXIF check is the expensive step** for an iCloud-only library: about one original download per photo, roughly 1–3 s each, and Photos may keep the downloaded originals on disk until it evicts them.
