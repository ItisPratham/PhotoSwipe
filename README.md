# PhotoSwipe

A Tinder-style photo cleaner for iOS.

PhotoSwipe lets you review your photo library one photo at a time using simple swipe gestures. Swipe left to mark a photo for deletion, swipe right to keep it. Instead of interrupting every swipe with a confirmation dialog, deletions are reviewed and performed in a single batch.

## Features

* Tinder-style swipe interface.
* Oldest-first chronological browsing (photos and screenshots by default).
* Persistent review history so photos you've already judged don't appear again.
* One-step undo.
* Batched deletion with a review screen before anything is removed.
* Fullscreen pinch-to-zoom photo viewer, with clamped, rubber-banded panning.
* Browse by album or jump into the deck from any day in the timeline.
* Activity log showing deletion history and estimated storage reclaimed.
* VoiceOver support.
* First-launch interactive onboarding and an animated launch splash.

### v3

* **Videos** — an opt-in Videos entry brings clips into the same deck: poster
  first, then muted, looping autoplay of the current card, with a duration
  badge, tap-to-play/pause, a scrubber to seek, and a per-card mute toggle
  (muted by default). Videos also get a playable long-press preview in the
  review grid. The default photo stream stays photos-only.
* **Biggest files** — sort the deck by on-device byte size (largest first,
  photos and videos together) to clear space hogs quickly. Sizes are read from
  `PHAssetResource` metadata (no download) and cached.
* **Duplicates** — an opt-in, on-device Vision scan groups camera bursts and
  near-identical shots. Determinate progress with cancel; the index is cached
  in SwiftData and re-scans incrementally. The screen auto-refreshes when the
  library changes (add / delete / capture) and offers a manual reload and a
  Sensitivity slider. Opening a group enters the deck scoped to it, with the
  highest-quality shot badged as the suggested keeper.

## Why deletion is batched

iOS does not allow apps to silently delete photos. Every deletion must be confirmed through the system Photos dialog.

Because of this limitation, swiping only marks photos for deletion. When you're ready, tap **Review**, optionally restore any marked photos, then confirm a single batch deletion through the system prompt.

After a successful delete, PhotoSwipe estimates the storage reclaimed and records the operation in the activity log.

## Requirements

* Xcode 16 or later
* iOS 17.0+ (raised from 16.0 in v3 — the duplicate index uses SwiftData)
* A physical iPhone or iPad for meaningful testing (the Simulator does not contain a real photo library)

## Building

Open the project:

```sh
open PhotoSwipe.xcodeproj
```

In Xcode:

1. Select the **PhotoSwipe** target.
2. Open **Signing & Capabilities**.
3. Choose your Apple Developer Team.
4. Build and run on a connected device.

The committed Xcode project is the source of truth.

## Tech Stack

* Swift
* SwiftUI
* PhotoKit
* AVFoundation / AVKit (video playback in the deck)
* Vision — `VNGenerateImageFeaturePrintRequest` for near-duplicate grouping
  (whole-image similarity, **not** face recognition)
* SwiftData — on-disk store for the duplicate feature-print index

Review decisions, onboarding/stats flags, and cached byte sizes live in
UserDefaults; only the (large) feature-print index lives in SwiftData.

## Known Limitations

* Review history and the duplicate index are stored locally. Reinstalling the app or moving to another device resets them.
* No iCloud sync.
* Duplicate detection is opt-in and heuristic (feature-print similarity within a time window); it isn't guaranteed to catch every near-duplicate, and sensitivity is user-tunable.
* Videos are opt-in (via the Videos / Biggest files entries); the default chronological stream stays photos-only.
* Person/face filtering is not supported because PhotoKit does not expose Apple's People album through a public API, and Vision offers no public face-identity embedding.

## Project Structure

```
PhotoSwipe/
├── PhotoSwipe.xcodeproj
├── PhotoSwipe/
├── Design/
└── project.yml
```

`project.yml` is retained from the original XcodeGen bootstrap but is no longer used for day-to-day development.
