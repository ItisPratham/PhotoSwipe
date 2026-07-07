# PhotoSwipe

**A Tinder-style photo cleaner for iOS.** Clear years of camera-roll clutter
one swipe at a time — swipe left to mark a photo for deletion, swipe right to
keep it. Nothing is deleted until you review and confirm, so you can move fast
without fear.

PhotoSwipe runs entirely on your device. There's no account, no upload, and no
tracking — your library never leaves your phone.

## Highlights

**The swipe deck**
* Fast Tinder-style review with direction tint, Keep/Delete stamps, drag-to-tilt,
  and one-step undo.
* Decisions persist, so a photo you've judged never comes back.
* Fullscreen pinch-to-zoom inspector with clamped, rubber-banded panning.
* Fully VoiceOver-accessible, with an interactive first-launch tutorial and an
  animated launch screen.

**Ways in**
* The whole library, oldest first.
* Any **album**, or jump into the timeline from a specific **day**.
* **Videos** — reviewed right in the deck: poster first, then muted looping
  autoplay, a duration badge, tap to play/pause, a scrubber to seek, and a
  per-card mute toggle. Videos get a playable preview in the review grid too.
* **Biggest files** — sort by on-device size (photos and videos together) to
  reclaim the most space fastest.
* **Duplicates** — an on-device scan groups camera bursts and near-identical
  shots; open a group to review just those, with the best shot suggested as the
  keeper.

**Safe, batched deletion**
* Swiping only *marks* photos. A **Review** screen lets you spare anything before
  a single confirmed batch delete.
* After deleting, PhotoSwipe shows the space reclaimed and logs every batch in a
  read-only **Activity** history.

## Why deletion is batched

iOS never lets an app silently delete photos — every deletion is confirmed
through the system Photos dialog, by design. So PhotoSwipe marks as you swipe,
then deletes the whole batch behind **one** system prompt. Deleted photos go to
the system's *Recently Deleted*, recoverable for ~30 days.

## Duplicate detection

The Duplicates finder is opt-in and runs entirely on-device. It warns before
starting, shows cancelable progress, and caches its work so re-scans are
incremental. It uses PhotoKit burst grouping plus Vision image feature prints
(`VNGenerateImageFeaturePrintRequest`) — whole-image similarity, **not** face
recognition. A Sensitivity control tunes how aggressively shots are grouped, and
the screen auto-refreshes as your library changes (photos added, deleted, or
captured).

## Requirements

* Xcode 16 or later
* iOS 17.0 or later
* A physical iPhone or iPad — the Simulator has no real photo library

## Building

```sh
open PhotoSwipe.xcodeproj
```

In Xcode: select the **PhotoSwipe** target → **Signing & Capabilities** → choose
your Apple Developer Team, then build and run on a connected device. The
committed Xcode project is the source of truth.

## Tech Stack

* Swift + SwiftUI (MVVM, async/await — no Combine, no third-party dependencies)
* PhotoKit — fetch, thumbnail-first loading, and batched delete
* AVFoundation / AVKit — video playback in the deck
* Vision — image feature prints for near-duplicate grouping (not face recognition)
* SwiftData — on-disk store for the duplicate feature-print index

Review decisions, onboarding/activity state, and cached byte sizes live in
UserDefaults; only the large feature-print index lives in SwiftData.

## Privacy & data

* **Everything is on-device.** No sync, no accounts, no analytics, no network
  calls beyond iCloud photo downloads handled by PhotoKit itself.
* Because state is local, reinstalling the app or moving to a new device starts
  the review history fresh — a deliberate trade-off for zero-server privacy.

## Not included

* **Person / face filtering.** Public PhotoKit doesn't expose Apple's People
  album (`PHPerson`), and Vision has no public face-identity embedding, so
  "photos of a person" can't be done accurately without a bundled model. It's
  intentionally out of scope.

## Project Structure

```
PhotoSwipe/
├── PhotoSwipe.xcodeproj
├── PhotoSwipe/          # App, Models, Services, ViewModels, Views, Resources
├── Design/             # Owner-supplied app-icon source SVGs
└── project.yml
```

`project.yml` is retained from the original XcodeGen bootstrap; day-to-day
development happens in the committed Xcode project.
