# PhotoSwipe

**A Tinder-style photo cleaner for iOS.** Clear years of camera-roll clutter
one swipe at a time — swipe left to mark a photo for deletion, swipe right to
keep it. Nothing is deleted until you review and confirm, so you can move fast
without fear.

PhotoSwipe runs entirely on your device. There's no account, no upload, and no
tracking — your library never leaves your phone.

---

> **License notice:** This project is **not licensed for reuse** (all rights
> reserved). The bundled AdaFace IR-50 model is for **non-commercial research
> use only** — see `THIRD_PARTY_LICENSES.md`. This app is therefore **not for
> sale or App Store distribution** while that model is bundled. To ship
> commercially, swap to the OpenCV SFace model (Apache-2.0 weights, documented
> in `THIRD_PARTY_LICENSES.md` and `scripts/convert_sface.py`).

---

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
* **People** — an opt-in on-device face scan clusters your photos by the people
  in them. Open a person to swipe through only their photos — the whole set,
  a single day, or from a chosen photo onward. A grouping-strength slider tunes
  how tightly faces group, and you can rename, merge, or hide people.

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
The scan is opt-in, warns you before it runs, shows determinate progress, can
be cancelled, and is incremental (only new photos are scanned on re-runs).

Grouping is tunable: a strength slider re-groups from the cached embeddings with
no re-scan, so you can dial in how tightly the same person collapses across
poses and lighting. Because tuning re-partitions everyone, do it before you
start renaming. Once you're happy, rename people, merge two clusters, or hide
ones you don't care about — normal navigation keeps those edits (only the slider
resets them). Each person's cover crops to their detected face, chosen by a
capture-quality score.

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
work normally.

### Attribution

The AdaFace code is MIT. The pretrained weights are non-commercial research
only. Full terms in `THIRD_PARTY_LICENSES.md` and in-app under
**Settings ▸ Acknowledgements**.

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
* Vision — face detection/landmarks (People) and feature prints (Duplicates)
* Core ML — AdaFace IR-50 face embedding (fp16, on-device)
* Accelerate / vDSP — cosine-similarity clustering
* SwiftData — on-disk store for the duplicate index and the face/people index

## Privacy & data

* **Everything is on-device.** No sync, no accounts, no analytics, no network
  calls beyond iCloud photo downloads handled by PhotoKit itself.
* Face embeddings and cluster assignments are stored in a local SwiftData
  database on the device and are never transmitted anywhere.
* Because state is local, reinstalling the app or moving to a new device starts
  the review history and face index fresh — a deliberate trade-off for
  zero-server privacy.

## Project Structure

```
PhotoSwipe/
├── PhotoSwipe.xcodeproj
├── PhotoSwipe/              # App, Models, Services, ViewModels, Views, Resources
├── scripts/                 # convert_adaface.py, convert_sface.py
├── Design/                  # Owner-supplied app-icon source SVGs
├── THIRD_PARTY_LICENSES.md  # AdaFace attribution (required)
└── project.yml
```

`project.yml` is retained from the original XcodeGen bootstrap; day-to-day
development happens in the committed Xcode project.
