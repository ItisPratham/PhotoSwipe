# PhotoSwipe

**A Tinder-style photo cleaner for iOS.** Clear years of camera-roll clutter
one swipe at a time — swipe left to mark a photo for deletion, swipe right to
keep it. Nothing is deleted until you review and confirm, so you can move fast
without fear.

PhotoSwipe runs entirely on your device. There's no account, no upload, and no
tracking — your library never leaves your phone.

Current version: **5.2** (iOS 17+), the final v5 release. The repository is
named `PhotoTinder`; the app, target, and bundle identifier are `PhotoSwipe`.

---

> **License notice:** This project is **not licensed for reuse** (all rights
> reserved). The bundled AdaFace IR-50 model is for **non-commercial research
> use only** — see `THIRD_PARTY_LICENSES.md`. This app is therefore **not for
> sale or App Store distribution** while that model is bundled. To ship
> commercially, swap to the OpenCV SFace model (Apache-2.0 weights, documented
> in `THIRD_PARTY_LICENSES.md` and `scripts/convert_sface.py`).

---

## How the app is organised

Three tabs, each with its own navigation stack, plus a settings gear in every
tab's toolbar.

| Tab | What it does |
| --- | --- |
| **Clean** | Lands straight in the default deck: every photo, oldest first, skipping anything you've already judged. |
| **Browse** | A day-grouped grid of the library. Tap a photo or day header to start swiping from there. Entry points at the top for **On this day**, **Albums**, browse-first grids for **Videos**, **Screenshots**, and **Biggest files**, plus **Duplicates** and the opt-in **Categories** (Receipts, Documents, Whiteboards, Food, Pets, Memes). |
| **People** | Opt-in on-device face scan. A grid of people; open one to browse or swipe through their photos. “Also with…” lists only people who actually share a photo, then opens those shared photos as a grid. Rename, merge, hide, answer merge suggestions, and tune grouping strength. |

**Settings** (gear) holds the read-only **Activity** log, the **Swipe up
does…** choice (favorite, or add to a chosen album), a replay of the first-run
tutorial, **Contact support** (pre-fills app and iOS version), **Reset review
history**, and **Acknowledgements**.

Every entry point feeds the same deck engine through a `DeckSource` value, so
reviewed-skipping, undo, marks, and batch delete behave identically everywhere.

## Highlights

**The swipe deck**
* Fast Tinder-style review with direction tint, Keep/Delete stamps, drag-to-tilt,
  and multi-step undo (up to 50 swipes back).
* **Swipe up** keeps the photo and favorites it in Photos, or adds it to an
  album you pick once in Settings. No system prompt; undo reverts it.
* **More like this** on any photo card opens a deck of its nearest neighbours
  (from the Duplicates index), nearest first.
* Decisions persist, so a photo you've judged never comes back.
* Fullscreen pinch-to-zoom inspector with clamped, rubber-banded panning.
* Decks and grids keep your place across tab switches and refresh silently
  when the library changes underneath them.
* Fully VoiceOver-accessible, with an interactive first-launch tutorial and an
  animated launch screen.

**Ways in**
* The whole library, oldest first (the Clean tab).
* Any **album**, or jump into the timeline from a specific **day** or photo.
* **Screenshots** — browse every system screenshot before starting an
  oldest-first cleaning deck (metadata, no ML).
* **On this day** — photos taken on today's date in earlier years, when there
  are any.
* **Categories** — an opt-in on-device pass sorts photos into Receipts,
  Documents, Whiteboards, Food, Pets, and Memes. Each category is a
  Browse-style grid you can swipe from any photo. See *Categories* below.
* **Videos** — browse all videos first, then review them in the deck: poster first, then muted looping
  autoplay, a duration badge, tap to play/pause, a scrubber to seek, and a
  per-card mute toggle. Videos get a playable preview in the review grid too.
* **Biggest files** — browse photos and videos sorted by on-device size before
  starting the same largest-first deck, to reclaim the most space fastest.
* **Duplicates** — an on-device scan groups camera bursts and near-identical
  shots; open a group to review just those, with the keeper suggested by a
  weighted score (sharpness, face quality, pixel count, and on iOS 18 Vision's
  aesthetics) rather than pixel count alone.
* **People** — an opt-in on-device face scan clusters your photos by the people
  in them. Open a person to swipe through only their photos — the whole set,
  a single day, or from a chosen photo onward. “Also with…” filters out people
  with no shared photos and opens the shared set as a Browse-style grid. A
  grouping-strength slider tunes how tightly faces group, and you can rename,
  merge, or hide people.

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

## Categories

The Categories screen (from Browse) is opt-in and runs entirely on-device. For
each photo it uses the same 256 px index thumbnail and runs
Vision's built-in scene classifier (`VNClassifyImageRequest`), the cat/dog
detector, and text-rectangle detection, and measures sharpness (Laplacian
variance) and, on iOS 18, aesthetics. The results are stored as optional
columns on the duplicate index, with no bundled model or new license. Rules
over those signals bucket each photo into its first
matching category (receipt before document, never a meme if it's a system
screenshot). Rules lean toward precision: a label needs a clear confidence
and text coverage alone never makes a document. Once opted in, the Categories
screen refreshes new photos incrementally.

## Duplicate detection

The Duplicates finder is opt-in and runs entirely on-device. It warns before
starting, shows cancelable progress, and caches its work so re-scans are
incremental. It uses PhotoKit burst grouping plus Vision image feature prints
(`VNGenerateImageFeaturePrintRequest`) — whole-image similarity, **not** face
recognition. Matching is library-wide, so the same shot saved twice years apart
still groups. A Sensitivity control tunes how aggressively shots are grouped
(re-grouping only, no rescan), and the screen auto-refreshes as your library
changes.

## People / face clustering

The People feature uses an on-device face-embedding pipeline:

1. **Detect** — Vision's `VNDetectFaceLandmarksRequest` finds faces and their
   5 landmark points.
2. **Align** — a similarity transform (the canonical ArcFace/AdaFace template)
   warps each face to a 112×112 crop, eyes-level.
3. **Embed** — AdaFace IR-50 (bundled CoreML model) produces a 512-d vector
   for each face.
4. **Cluster** — cosine-distance greedy clustering + centroid-merge groups
   faces by identity.

All processing is **on-device**. Nothing about your faces is sent anywhere.
Opening the People tab performs no scan, photo fetch, model load, or face-index
read before you opt in. A scan starts only from the explicit Scan/Rescan
button, shows determinate progress, can be cancelled, and is incremental (only
new photos are scanned on re-runs; a photo whose image could not be loaded is
retried next time rather than remembered as "no faces"). Returning to the tab
after opting in loads saved clusters but never starts a scan automatically.

Grouping is tunable: a strength slider re-groups from the cached embeddings with
no re-scan, so you can dial in how tightly the same person collapses across
poses and lighting. Because tuning re-partitions everyone, do it before you
start renaming. For the everyday case of one person split in two, the People
screen lists **possible matches** (cluster centroids just under the merge
floor) and asks "Same person?" — Yes merges, No is remembered per pair. Once you're happy, rename people, merge two clusters, or hide
ones you don't care about — normal navigation and incremental re-scans keep
those edits (only the slider resets them). Hidden people stay reachable from a
row above the grid so they can be restored. Each person's cover crops to their
detected face, chosen by a capture-quality score.

### Producing the face model (one-time, owner action)

The bundled CoreML model is produced from the AdaFace IR-50 PyTorch checkpoint:

```sh
# Clone the AdaFace repo for net.py
git clone https://github.com/mk-minchul/AdaFace ../AdaFace

# Download adaface_ir50_ms1mv2.ckpt from the AdaFace model zoo (Google Drive)
# and place it at the repo root.

# Set up a Python env and convert
python3 -m venv .venv && source .venv/bin/activate
pip install torch coremltools numpy

python scripts/convert_adaface.py \
    --adaface-repo ../AdaFace \
    --ckpt adaface_ir50_ms1mv2.ckpt \
    --out PhotoSwipe/Resources/FaceEmbedding.mlpackage
```

Then add `FaceEmbedding.mlpackage` to the Xcode target (drag into the
Resources group, "Copy items if needed", target = PhotoSwipe). Without it
the People scan shows a "face model not installed" state — all other features
work normally. The checkpoint, the ONNX alternative, and the converted package
are all git-ignored.

### Attribution

The AdaFace code is MIT. The pretrained weights are non-commercial research
only. Full terms in `THIRD_PARTY_LICENSES.md` and in-app under
**Settings ▸ Acknowledgements**.

## Requirements

* Xcode 16 or later (developed against Xcode 26)
* iOS 17.0 or later
* A physical iPhone or iPad — the Simulator has no real photo library

## Building

```sh
open PhotoSwipe.xcodeproj
```

In Xcode: select the **PhotoSwipe** target → **Signing & Capabilities** → choose
your Apple Developer Team, then build and run on a connected device. The
committed Xcode project is the source of truth. The marketing version is set
once at the project level (`MARKETING_VERSION`) and `Info.plist` reads it from
there, so a release bump is a single edit.

## Tech Stack

* Swift + SwiftUI (MVVM, async/await — no Combine, no third-party dependencies)
* PhotoKit — fetch, thumbnail-first loading, library-change observation, and
  batched delete
* AVFoundation / AVKit — video playback in the deck
* Vision — face detection/landmarks (People) and feature prints (Duplicates)
* Core ML — AdaFace IR-50 face embedding (fp16, on-device)
* Accelerate / vDSP — feature-print distances and cosine-similarity clustering
* SwiftData — on-disk stores for the duplicate index and the face/people index

## Privacy & data

* **Everything is on-device.** No sync, no accounts, no analytics, no network
  calls beyond iCloud photo downloads handled by PhotoKit itself.
* Because state is local, reinstalling the app or moving to a new device starts
  the review history and indexes fresh — a deliberate trade-off for
  zero-server privacy.

Where each piece of state lives:

| State | Storage |
| --- | --- |
| Reviewed and marked-for-deletion photo IDs | JSON file, `Application Support/review.json` (debounced writes; migrated from `UserDefaults` on first launch after 4.1) |
| Activity log and total space freed | `UserDefaults` |
| Swipe-up choice (favorite / album id + title), categories and People scan opt-ins | `UserDefaults` |
| Per-asset byte-size cache (Biggest files) | `UserDefaults` |
| Duplicate index (feature prints, sizes, sharpness, aesthetics, category signals) | SwiftData, `Application Support/duplicates.store` |
| Face index (embeddings, people, names, hides, declined merges) | SwiftData, `Application Support/faces.store` |

The two SwiftData indexes deliberately use separate files: a shared default
store would let each container migrate the other's tables away on open.

## Project Structure

```
PhotoTinder/
├── PhotoSwipe.xcodeproj
├── PhotoSwipe/
│   ├── App/                 # @main entry
│   ├── DesignSystem/        # Theme tokens
│   ├── Models/              # DeckSource, PhotoAsset, SwiftData rows, UI aggregates
│   ├── Services/            # PhotoKit, stores, scan + grouping pipelines
│   ├── ViewModels/          # Per-screen state, serialized scan queue
│   ├── Views/               # SwiftUI screens and components
│   └── Resources/           # Assets, Info.plist, FaceEmbedding.mlpackage (ignored)
├── scripts/                 # convert_adaface.py, convert_sface.py
├── Design/                  # Owner-supplied app-icon source SVGs
├── THIRD_PARTY_LICENSES.md  # AdaFace attribution (required)
└── project.yml              # Original XcodeGen seed, kept in sync for reference
```

The final v5/v6 build briefs and the engineering notes under `docs/` are
tracked with `README.md` and `THIRD_PARTY_LICENSES.md`. Older version briefs
and personal scratch notes remain local.
