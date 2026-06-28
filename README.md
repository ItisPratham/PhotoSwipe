# PhotoSwipe

A Tinder-style photo cleaner for iOS. Swipe through your photo library one photo
at a time to clear out the junk and duplicates that pile up over the years.

- **Swipe left** → mark the photo for deletion.
- **Swipe right** → keep it (marked reviewed; it never appears again).

## Why deletion is batched

iOS **cannot** silently delete photos. `PHAssetChangeRequest.deleteAssets(_:)`
always shows a system confirmation dialog — by design, and it can't be bypassed.
So swiping only *marks* assets. A persistent **Review (N)** pill opens a grid
where you can spare any photo, then **one** system prompt confirms the whole
batch delete. Deletion is never per-swipe.

After a successful batch delete the app surfaces a "Freed ~X MB" banner sized
from the deleted assets' on-device file sizes.

## Requirements

- Xcode 16+ (developed against Xcode 26)
- iOS 16.0+ deployment target
- A **real device** to test meaningfully — the Simulator has no real photo library.

## Setup

The Xcode project is committed and Xcode-managed — just open it:

```sh
open PhotoSwipe.xcodeproj
```

Then in Xcode: select the **PhotoSwipe** target → **Signing & Capabilities** →
set your **Team**, and run on a connected device.

> The Xcode project is the source of truth. A `project.yml` is still in the
> repo for historical reference (the project was originally seeded by
> [XcodeGen](https://github.com/yonik/XcodeGen)), but day-to-day you just edit
> in Xcode — new Swift files added to the project are picked up automatically.

## What's in the MVP

- Permission flow with a Settings deep-link when access is limited or blocked.
- Oldest-first chronological deck, photos and screenshots only (no videos).
- Tinder-style swipe deck with direction tint, Keep/Delete stamps, drag-to-tilt,
  and a spring-back when the gesture is interrupted (e.g. a second finger).
- Decisions persisted locally — judged photos never re-enter the deck across
  sessions.
- Single-step undo that re-mounts the last card and clears its decision.
- Batched delete: **Review (N)** pill → grid sheet with tap-to-toggle and
  long-press preview → "Delete permanently (N)" → one system prompt → one
  batched PhotoKit delete → "Freed ~X MB" banner.
- "All caught up" state at the end of the deck.
- VoiceOver-friendly: photo card carries a date label and `Keep` /
  `Mark for deletion` actions so the deck is usable without the drag gesture.

## Known limitations (MVP)

- Reviewed / marked state is **local only** (UserDefaults, keyed by asset
  `localIdentifier`). Reinstall or new device = fresh start. No sync.
- **No duplicate detection** — chronological order surfaces bursts naturally.
- **No videos** — photos and screenshots only.
