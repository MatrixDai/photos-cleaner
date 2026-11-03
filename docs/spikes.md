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

| Question | Spike button | Answer |
| --- | --- | --- |
| Rating write prompts: per `performChanges` or per asset? | Rating writes | _pending_ |
| Shared Library assets in a personal album | Albums | _pending_ |
| EXIF read cost: header-only read vs full download; iCloud-only share; share without Make/Model | EXIF read cost | _pending_ |
| Vision aesthetics works in the user's region; score range | Aesthetics | _pending_ |
| Similarity threshold and feature-print revision; 30 s window catches retakes | Similarity calibration | _pending_ |
| `dataSize` for iCloud-only videos; `requestData` progress fires | Videos: dataSize & dates | _pending_ |
| `rating` usable in a fetch predicate | Rating API | _pending_ |
| Album found by `localIdentifier` after rename | Albums, then Check album rename | _pending_ |
| Ratings on Shared Library assets sync to other participants (informational) | Rating writes, pause step | _pending_ |
| QuickTime creation date carries a UTC offset | Videos: dataSize & dates | _pending_ |
