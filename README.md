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
from the deleted assets' on-device file sizes, and appends a `DeleteRecord` to
the persistent activity log (see below).

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

## Features

### MVP (v1)

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

### v2.0

- **First-launch onboarding** — 3 slides that *teach the swipe by being one*:
  the tutorial card follows your finger, tilts, and only advances when you
  drag the correct direction (left for delete, right for keep), reinforced by
  the same red/green tint the real deck uses. Persisted seen-flag; re-openable
  from the toolbar menu at any time.
- **Toolbar menu** (`•••` top-right of the swipe deck) with:
  - **Activity** — cumulative bytes freed, running photo count, and a reverse
    chronological list of every successful batch delete (date, count, MB).
    Read-only; the system's Recently Deleted covers restore.
  - **Show tutorial** — re-plays the onboarding without touching the seen-flag.
  - **Contact support** — opens a `mailto:` draft to the support address with
    the app version and iOS version pre-filled in the subject line.
  - **Reset review history** — destructive, confirmation alert. Wipes the
    kept/marked sets so the whole library re-enters the deck as un-reviewed.
    The Photos library itself is not touched.
- **Light + dark app icon** — full-bleed 1024×1024 renders, wired into the
  asset catalog with `luminosity: dark` so iOS 18+ switches automatically.

### v2.1

- **DeckSource** — a value type that gates what feeds the swipe deck (scope +
  optional `startFrom` cutoff). The engine downstream is unchanged; scope
  changes just replace the fetch. The current source is persisted through
  UserDefaults so a chosen entry point survives relaunch. Reset review
  history explicitly clears the filter back to `.allPhotos`.
- **Browse** (menu → Browse) — a Photos.app-style day-grouped grid of the
  full library, newest-first, with sticky day headers and a visible scroll
  indicator. Tap a thumbnail to start the deck at that photo; tap a day
  header to start at the beginning of that day. Long-press any thumbnail
  for a full-photo preview.
- **Albums** (menu → Albums) — lists every user-created album that contains
  photos, with cover thumbnail and count. Tap an album to swipe scoped to
  it. All the review, undo, and batch-delete behaviour applies identically.
- **Pinch-to-zoom** — a two-finger pinch on the current card opens a
  fullscreen photo inspector with further pinch (1×–4×), pan when zoomed,
  double-tap toggle, and downward-drag-to-dismiss.

## App icon

The icon art is **owner-supplied**. Source SVGs live under `Design/`
(`AppIcon_Light.svg`, `AppIcon_Dark.svg`), and the shipped PNGs sit inside
`PhotoSwipe/Resources/Assets.xcassets/AppIcon.appiconset/`. To swap the art:

1. Edit the SVGs (or drop in new ones).
2. Re-render each to a **1024×1024 PNG, opaque, no alpha** (`qlmanage` + a
   short CoreGraphics flatten pass — see the icon commit for the recipe).
3. Overwrite the two PNGs in the appiconset with the same filenames. No
   Xcode wiring changes needed.

## Persistence

Everything is UserDefaults, keyed to be human-readable:

- `PhotoSwipe.reviewedIDs` / `PhotoSwipe.markedForDeletionIDs` — Sets of
  `PHAsset.localIdentifier`. Reviewed = kept ∪ marked-for-deletion; excluded
  from the fetched deck.
- `PhotoSwipe.hasSeenOnboarding` — Bool flag.
- `PhotoSwipe.stats.totalBytesFreed` / `PhotoSwipe.stats.deleteHistory` —
  cumulative bytes reclaimed + JSON-encoded array of `DeleteRecord` values.
- `PhotoSwipe.currentDeckSource` — JSON-encoded snapshot of the active
  DeckSource (scope + optional `startFrom`); albums travel via their
  `PHAssetCollection.localIdentifier` and are re-resolved on relaunch.

## Known limitations

- **Local only.** All state above is local; reinstall or new device = fresh
  start. No cloud sync.
- **No duplicate detection.** Chronological adjacency surfaces bursts and
  near-dupes naturally; we don't run perceptual hashing.
- **No videos.** Photos and screenshots only — videos are filtered at the
  fetch layer.
- **Person / face filtering is out of scope.** Apple's People album isn't
  exposed via public PhotoKit — there's no `PHPerson` — so implementing
  "photos of this person" would require running our own Vision-based face
  detection + clustering across the library. That's compute-heavy,
  privacy-sensitive, and not on the roadmap; see `PhotoSwipe_v2_Instructions.md`
  §7 for the parked spike.
