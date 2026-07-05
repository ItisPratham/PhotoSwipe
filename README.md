# PhotoSwipe

A Tinder-style photo cleaner for iOS.

PhotoSwipe lets you review your photo library one photo at a time using simple swipe gestures. Swipe left to mark a photo for deletion, swipe right to keep it. Instead of interrupting every swipe with a confirmation dialog, deletions are reviewed and performed in a single batch.

## Features

* Tinder-style swipe interface.
* Oldest-first chronological browsing.
* Photos and screenshots only (videos excluded).
* Persistent review history so photos you've already judged don't appear again.
* One-step undo.
* Batched deletion with a review screen before anything is removed.
* Fullscreen pinch-to-zoom photo viewer.
* Browse by album or jump into the deck from any day in the timeline.
* Activity log showing deletion history and estimated storage reclaimed.
* VoiceOver support.
* First-launch interactive onboarding.

## Why deletion is batched

iOS does not allow apps to silently delete photos. Every deletion must be confirmed through the system Photos dialog.

Because of this limitation, swiping only marks photos for deletion. When you're ready, tap **Review**, optionally restore any marked photos, then confirm a single batch deletion through the system prompt.

After a successful delete, PhotoSwipe estimates the storage reclaimed and records the operation in the activity log.

## Requirements

* Xcode 16 or later
* iOS 16.0+
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
* Vision (used only for image-related functionality; not face recognition)

## Known Limitations

* Review history is stored locally. Reinstalling the app or moving to another device resets it.
* No iCloud sync.
* No duplicate detection or perceptual hashing.
* Videos are intentionally excluded.
* Person/face filtering is not supported because PhotoKit does not expose Apple's People album through a public API.

## Project Structure

```
PhotoSwipe/
├── PhotoSwipe.xcodeproj
├── PhotoSwipe/
├── Design/
└── project.yml
```

`project.yml` is retained from the original XcodeGen bootstrap but is no longer used for day-to-day development.
