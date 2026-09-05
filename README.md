# PhotoSwipe

**A Tinder-style photo cleaner for iOS.** Clear years of camera-roll clutter
one swipe at a time — swipe left to mark a photo for deletion, swipe right to
keep it. Nothing is deleted until you review and confirm, so you can move fast
without fear.

PhotoSwipe runs entirely on your device. There's no account, no upload, and no
tracking — your library never leaves your phone.

Current version: **6.1** (iOS 17+). The repository is named `PhotoTinder`;
the app, target, and bundle identifier are `PhotoSwipe`.

**V6.1 implementation is complete.** The final handoff includes the Search,
scrolling, widget, persistence, and model-installation fixes. Only optional
SigLIP 2 real-checkpoint and device validation remains deferred.

---

> **License notice:** This project is **not licensed for reuse** (all rights
> reserved). The bundled AdaFace IR-50 model is for **non-commercial research
> use only**, so the app is **not for sale or App Store distribution** while it
> ships. MobileCLIP S2, behind Search, is in the same position: its weights are
> licensed for research and exclude product development, which makes a locally
> converted Search build a research build rather than something you can hand
> out.
>
> Alternatives are documented. Faces can use OpenCV SFace
> (Apache-2.0 weights, `scripts/convert_sface.py`). Search has experimental
> SigLIP 2 support,
> whose checkpoint page puts the software under Apache 2.0 and everything else,
> weights included, under CC-BY 4.0. CC-BY allows commercial use as long as you
> credit the source and say the weights were changed, which a Core ML
> conversion is. Details for both live in `THIRD_PARTY_LICENSES.md`.

---

## How the app is organised

Four tabs, each with its own navigation stack, plus a settings gear in every
tab's toolbar.

| Tab | What it does |
| --- | --- |
| **Clean** | Lands straight in the default deck: every photo, oldest first, skipping anything you've already judged. |
| **Browse** | A day-grouped grid of the library. Tap a photo or day header to start swiping from there. Entry points at the top for **On this day**, **Albums**, browse-first grids for **Videos**, **Screenshots**, and **Biggest files**, plus **Duplicates** and the opt-in **Categories** (Receipts, Documents, Whiteboards, Food, Pets, Memes). |
| **Search** | Describe a photo ("dog on the beach") and get ranked matches, worked out on the phone. Person chips narrow the results to a face cluster. Tap a result to inspect it, or send the whole ranked list to the deck. Needs a search model installed (see below); without one the tab says so and nothing else changes. |
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
* Long photo grids get a drag-to-scrub scrollbar (DMScrollBar, pinned) that
  appears only while scrolling. Native scrolling and VoiceOver are untouched.

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

**On the home screen**
* A **widget** in small and medium sizes shows how much space you have freed
  this month and how many photos are waiting to be deleted. The medium one adds
  a seven-day activity strip and a Clean link. An extension can't read the app's
  own files, so the app writes a small summary to a shared App Group container
  and the widget reads that. If the summary isn't there yet it says "Open
  PhotoSwipe to update" instead of showing zeroes it can't stand behind.
* **Siri and Shortcuts**: "Start cleaning in PhotoSwipe" (Screenshots, Biggest
  files and Duplicates work as starting points too), "How much space have I
  freed with PhotoSwipe", "How many photos are marked in PhotoSwipe". The two
  questions answer straight from that summary, without opening the app or
  touching your library.
* **Deep links**: `photoswipe://clean`, with `?entry=screenshots`,
  `?entry=biggest` or `?entry=duplicates`. A link that arrives during
  onboarding or the launch splash waits until you are through them, then
  replaces whatever Clean was showing rather than piling up screens.

**Safe, batched deletion**
* Swiping only *marks* photos. A **Review** screen lets you spare anything before
  a single confirmed batch delete.
* After deleting, PhotoSwipe shows the space reclaimed and logs every batch in a
  read-only **Activity** history.

## Search

Search is opt-in and stays on the phone. The embedding pass rides along with
the scan that already runs for duplicates and categories, reusing the same
256 px thumbnail, so your library never gets walked twice. Each photo ends up
with one vector stored as another optional column on the duplicate index.
Typing runs the query through the text tower and ranks everything by cosine
similarity in a single Accelerate matrix-vector product, keeping the top 200
above a fixed cutoff.

Model weights are not in the repository. MobileCLIP is the established search
path; an experimental SigLIP 2 path has also been added:

* **MobileCLIP S2** (`scripts/convert_mobileclip.py`) is what the app was
  developed against. Its weights are research-only, so a build using it can't
  be distributed.
* **SigLIP 2** (`scripts/convert_siglip2.py`) is an experimental alternative
  with the license terms described in `THIRD_PARTY_LICENSES.md`. A real
  checkpoint conversion and device evaluation have not yet been recorded.
  Its packages, vocabulary, and provenance are included automatically when
  installed locally.

They are different models, not two names for the same thing: SigLIP 2 uses the
Gemma SentencePiece tokenizer instead of CLIP's byte-pair encoding, squares the
image off instead of cropping it, normalises pixels differently, and produces
wider vectors. `SearchModelSpec` holds everything that differs and resolves it
once from whichever packages are installed. Switching families changes the
stored model fingerprint, which clears the search columns and reindexes, so
vectors from two embedding spaces never get compared.

Install neither and the Search tab says the model isn't available. Everything
else in the app carries on as usual.

When both complete model families are installed, MobileCLIP takes precedence.
The optional compilation phase removes stale compiled models and metadata when
their source artifacts are removed, so a model switch does not retain the old
family in the app bundle.

## Final V6 handoff

The previously documented limitations are resolved: streaks expire from the last
swipe, summaries wait for successful review persistence, Search shows failures
over existing results, Settings names the installed search model, and optional
model resources are compiled and cleaned up consistently.

The final simulator build passed with all 49 regression tests.

Validated on device: signed App Group access from both the app and the widget,
widget rendering from the shared summary, and all three intents through
Shortcuts and Siri.

Search performance, measured with `PhotoSwipeTests/SearchPerformanceTests`
against a 30,000-vector index. Run the class on a phone to reproduce it;
Simulator timings mean nothing here, as the Mac has no Neural Engine.

| Measurement | iPhone 14 Plus (A15) | iPhone 14 Pro (A16) |
| --- | --- | --- |
| Warm query, end to end | 35.9 ms | 15.6 ms |
| Text query | 6.5 ms | 3.1 ms |
| Ranking 30,000 vectors | 2.4 ms | 1.5 ms |
| Image embedding, per photo | 26.1 ms | 11.7 ms |
| Inference for 30,000 photos | ~13 min | ~6 min |
| Cold load and first query | 8.3 s | 3.1 s |
| Process footprint, index and both towers resident | 169.2 MB | 169.6 MB |

The 300 ms warm-query bar is asserted by the test, not just printed, so a
regression fails the suite. Ranking is negligible; a query is almost entirely
text inference. The resident index itself is 58.6 MB for 30,000 photos.

What Search adds to the app:

| Artifact | Size |
| --- | --- |
| Image tower | 68 MB |
| Text tower | 121 MB |
| Tokenizer resources | 4.2 MB |

The one soft spot is cold start: the text tower takes about 8.3 seconds on the
A15 to load and compile for the Neural Engine. Opening the Search tab now
starts that load in the background, so it overlaps whatever the user types
instead of blocking the first query.

Still open: **SigLIP 2** has no converted checkpoint, so its tokenizer and
embedding parity, relevance, and performance are unproven and it stays
experimental. The long scrollbar endurance run and the accessibility sweep are
also unrecorded.

V6 is closed. Nothing follows it.

## Version history

| Version | Added |
| --- | --- |
| 1.0 | Swipe deck, undo, one confirmed batch delete |
| 2.0 | Onboarding you swipe through, app icons |
| 2.1 | `DeckSource`, Browse as home, albums, zoom inspector |
| 3.0 | Video in the deck |
| 3.1 | Largest-first order |
| 3.2 | Duplicate grouping, SwiftData, iOS 17 |
| 4.0 | Tab bar, People face clustering |
| 5.0 | Screenshots, 50-step undo, swipe up to favourite or file |
| 5.1 | More like this, keeper scoring |
| 5.2 | Categories, On this day, merge suggestions, Also with |
| 6.0 | Search, fast scrollbar |
| 6.1 | Widget, App Intents, deep links, streaks |

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

Leave `FaceEmbedding.mlpackage` in `PhotoSwipe/Resources/`; the optional-model
build phase compiles it automatically. Do not add it to Sources again. Without it
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
your Apple Developer Team, then build and run on a connected device. The widget
needs the **App Groups** capability with `group.com.phototinder.PhotoSwipe` on
both the app and the `PhotoSwipeWidget` target. Without it the app still runs;
the widget and the two read-only intents just have nothing to read.

Every Core ML package is git-ignored and optional at build time. A build phase
compiles whichever ones it finds, so a fresh clone builds with no models at all
and the features they back stay switched off. The committed Xcode project is
the source of truth. The marketing version is set once at the project level
(`MARKETING_VERSION`) and `Info.plist` reads it from there, so a release bump
is one edit.

## Tech Stack

* Swift + SwiftUI (MVVM, async/await — no Combine). One third-party Swift
  package: DMScrollBar, pinned to a reviewed revision.
* WidgetKit + App Intents — home-screen widget, Siri phrases, and Shortcuts
* PhotoKit — fetch, thumbnail-first loading, library-change observation, and
  batched delete
* AVFoundation / AVKit — video playback in the deck
* Vision — face detection/landmarks (People) and feature prints (Duplicates)
* Core ML — AdaFace IR-50 face embedding and, when installed, MobileCLIP S2 or
  SigLIP 2 image/text embedding (fp16, on-device)
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
| Swipe-up choice (favorite / album id + title), categories, People, and Search scan opt-ins | `UserDefaults` |
| Per-asset byte-size cache (Biggest files) | `UserDefaults` |
| Duplicate index (feature prints, sizes, sharpness, aesthetics, category signals, search embeddings and model fingerprint) | SwiftData, `Application Support/duplicates.store` |
| Face index (embeddings, people, names, hides, declined merges) | SwiftData, `Application Support/faces.store` |
| Per-day swipe activity and the last session time (streaks) | inside `review.json` |
| Recent search queries | `UserDefaults` |
| Widget/intent summary (marks, freed space, streak, 7-day activity) | JSON file in the `group.com.phototinder.PhotoSwipe` App Group container |

The App Group file is the only thing extensions can read. The app writes it as
one complete snapshot, never a partial update, and neither the widget nor the
intents fall back to the app's private container.

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
│   └── Resources/           # Assets, Info.plist, .mlpackages (ignored)
├── PhotoSwipeWidget/        # WidgetKit extension (reads the App Group summary)
├── PhotoSwipeTests/         # Tokenizer, retrieval, streak, summary, link tests
├── scripts/                 # convert_adaface.py, convert_sface.py, convert_mobileclip.py, convert_siglip2.py
├── Design/                  # Owner-supplied app-icon source SVGs
├── THIRD_PARTY_LICENSES.md  # Model and DMScrollBar license notes
└── project.yml              # Documentation of the target layout; see below
```

`PhotoSwipe.xcodeproj` is hand-managed and authoritative. `project.yml` describes
the same optional-model build phase. Do not regenerate the project in place.
Converter fixtures stay local.

Of the Markdown documentation, only `README.md` and `THIRD_PARTY_LICENSES.md`
are tracked. The build briefs, engineering notes under `docs/`, and personal
scratch notes stay local.
