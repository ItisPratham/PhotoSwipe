# PhotoSwipe

A Tinder-style photo cleaner for iOS. Swipe through your photo library one photo
at a time to clear out the junk and duplicates that pile up over the years.

- **Swipe left** → mark the photo for deletion.
- **Swipe right** → keep it (marked reviewed; it never appears again).

## Why deletion is batched

iOS **cannot** silently delete photos. `PHAssetChangeRequest.deleteAssets(_:)`
always shows a system confirmation dialog — by design, and it can't be bypassed.
So swiping only *marks* assets. A persistent **Delete (N)** button opens a review
sheet where you can spare any photo, then **one** system prompt confirms the whole
batch delete. Deletion is never per-swipe.

## Requirements

- Xcode 16+ (developed against Xcode 26)
- iOS 16.0+ deployment target
- A **real device** to test meaningfully — the Simulator has no real photo library.

## Setup

This project uses [XcodeGen](https://github.com/yonik/XcodeGen) so the `.xcodeproj`
is generated from `project.yml` (and is git-ignored).

```sh
brew install xcodegen      # one-time
xcodegen generate          # produces PhotoSwipe.xcodeproj
open PhotoSwipe.xcodeproj
```

Then in Xcode: select the **PhotoSwipe** target → **Signing & Capabilities** →
set your **Team**, and run on a connected device.

## Status

Scaffold in place; features land milestone by milestone (see
`PhotoSwipe_Instructions.md`).

## Known limitations (MVP)

- Reviewed / marked state is **local only** (UserDefaults, keyed by asset
  `localIdentifier`). Reinstall or new device = fresh start. No sync.
- **No duplicate detection** — chronological order surfaces bursts naturally.
- **No videos** — photos and screenshots only.
