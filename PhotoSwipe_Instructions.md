# PhotoSwipe — Build Instructions for Claude Code

You are building a native iOS app from scratch. Follow this document as the source of truth. Work like a seasoned developer: small, well-scoped commits, clean architecture, sensible naming, no dead code. Do not over-engineer — this is an MVP.

---

## 1. What we're building

A Tinder-style photo cleaner. The user swipes through their photo library one photo at a time to clear out junk and duplicates that accumulate over years.

- **Swipe left** → mark the photo for deletion.
- **Swipe right** → mark the photo as reviewed/kept (it never appears again).
- Deletions are **batched**: marking does not delete. The user taps a persistent **Delete (N)** button to review and confirm, which deletes everything in one operation.

Value prop: clear out the backlog of useless photos incrementally, and never re-review a photo you've already judged.

---

## 2. Hard constraints — read before writing code

These are non-negotiable platform realities. Do not design around them differently.

1. **iOS cannot silently delete photos.** `PHPhotoLibrary.shared().performChanges` with `PHAssetChangeRequest.deleteAssets(_:)` always triggers a **system confirmation dialog**. This is by design and cannot be bypassed. Therefore deletion MUST be batched: swiping only marks an asset; one system prompt confirms the whole batch. Never call delete per-swipe.

2. **Permissions.** Request **full** library access via `PHPhotoLibrary.requestAuthorization(for: .readWrite)`. If the user grants only `.limited` or denies, do **not** attempt the swipe flow — show a screen explaining the app needs full access and deep-link to Settings (`UIApplication.openSettingsURLString`).

3. **iCloud / "Optimize iPhone Storage."** Full-resolution assets may not be on-device. Always render the **thumbnail first** (fast, local) and never block the UI waiting on a full-res download. Use `PHImageManager` with `deliveryMode = .opportunistic` so a quick low-res image shows immediately and sharpens if/when better data arrives. Set `isNetworkAccessAllowed = true` on the request options so iCloud assets can still load, but never freeze the card on it.

4. **Asset identity & persistence.** Track state using each asset's `localIdentifier`. Reviewed/marked state is **local only** (UserDefaults or a small local store). Reinstall or new device = fresh start. This is acceptable for MVP — do not build sync.

---

## 3. Locked feature spec (MVP scope only)

| Area | Decision |
|---|---|
| Asset types | Photos + screenshots. **No videos** (filter them out of the fetch). |
| Order | Single chronological stream, **oldest-first**. |
| Card content | The photo + a date label (e.g. "12 March 2019"). |
| Right swipe | Mark as **reviewed/kept**; persisted; never shown again. |
| Left swipe | Mark for **deletion** (also counts as reviewed — won't reappear if un-deleted later). |
| Undo | **Single-step** only. Brings back the last card and clears whatever mark it got. |
| Delete button | **Persistent**, shows pending count: `Delete (N)`. Tapping opens a review sheet. |
| Review sheet | Grid of marked-for-deletion photos. User can **untick** any to spare it. Then **"Confirm delete all"** → one system confirmation → batch delete. |
| Post-delete | Show **"Freed ~X MB"** (sum of deleted assets' file sizes). |
| End of stream | **"All caught up 🎉"** screen. Photos taken later enter the stream in a future session automatically. |
| Duplicate detection | **None.** Chronological adjacency surfaces bursts/dupes naturally. Do not build perceptual hashing or Vision-based grouping. |

**Out of scope for MVP (do not build):** albums/filtering, videos, cloud sync, real duplicate detection, infinite rewind, onboarding tutorials, analytics, settings screen beyond the permission re-prompt.

---

## 4. Tech stack

- **Language:** Swift (latest stable).
- **UI:** SwiftUI.
- **Photos:** PhotoKit (`Photos` / `PhotosUI` frameworks).
- **Min deployment target:** iOS 16.0 (gives modern SwiftUI + stable PhotoKit APIs). State your assumption in the README if you deviate.
- **Persistence:** UserDefaults keyed by `localIdentifier` for MVP (a `Set<String>` of reviewed IDs and a `Set<String>` of marked-for-deletion IDs). If this grows awkward, a tiny Core Data / SwiftData store is acceptable — but default to the simpler option first.
- **No third-party dependencies** unless one is genuinely required; justify any in the commit message and README.

---

## 5. Suggested architecture

Keep it MVVM, thin and readable. Indicative structure — adapt names sensibly:

```
PhotoSwipe/
├── App/
│   └── PhotoSwipeApp.swift          # @main entry
├── Models/
│   └── PhotoAsset.swift             # wrapper around PHAsset + date, size helpers
├── Services/
│   ├── PhotoLibraryService.swift    # auth, fetch (oldest-first, no video), image loading, batch delete
│   └── ReviewStore.swift            # persistence of reviewed + marked-for-deletion IDs
├── ViewModels/
│   └── SwipeViewModel.swift         # current deck, swipe handling, undo, pending-delete state
├── Views/
│   ├── RootView.swift               # routes between permission / swipe / caught-up states
│   ├── PermissionView.swift         # full-access explainer + Settings deep link
│   ├── SwipeView.swift              # the card stack + gestures + Delete(N) button
│   ├── CardView.swift               # single photo card + date label
│   ├── DeleteReviewSheet.swift      # grid of marked photos, untick, confirm
│   └── CaughtUpView.swift           # "All caught up 🎉"
└── Resources/
    └── Info.plist                   # NSPhotoLibraryUsageDescription
```

Don't forget **`NSPhotoLibraryUsageDescription`** in Info.plist — the app crashes on access without it. Write a clear, honest usage string.

---

## 6. Implementation plan → commit milestones

Build in this order. **Each milestone is at least one commit**; split further when a commit would otherwise mix concerns. Every milestone should leave the app in a compiling, runnable state.

1. **Project scaffold** — Xcode project, folder structure, Info.plist with usage string, README skeleton. App launches to a placeholder.
2. **Permissions flow** — `PhotoLibraryService` auth handling; `PermissionView` with Settings deep link; `RootView` routing on auth status.
3. **Fetch & display** — fetch assets oldest-first excluding videos; `PhotoAsset` model; `CardView` rendering thumbnail-first via `PHImageManager`. Static single card, no gestures yet.
4. **Swipe mechanics** — drag gesture, left/right thresholds, card animation, advance to next. Wire to in-memory marks (no persistence yet).
5. **Persistence** — `ReviewStore`; reviewed photos excluded from the fetched deck; marks survive app restart.
6. **Undo** — single-step rewind that restores the last card and clears its mark.
7. **Delete flow** — persistent `Delete (N)` button → `DeleteReviewSheet` grid with untick → batch `deleteAssets` → handle the system confirmation result (success/cancel) gracefully.
8. **Freed-space feedback** — sum deleted assets' file sizes; show "Freed ~X MB".
9. **Caught-up state** — `CaughtUpView` when the deck is empty.
10. **Polish pass** — empty/error states, loading states for iCloud assets, gesture feel, accessibility labels, README finalization.

---

## 7. Git conventions — work like a professional

**Repo setup**
- `git init` at project root. Add a Swift/Xcode `.gitignore` (ignore `xcuserdata/`, `*.xcuserstate`, `DerivedData/`, `.DS_Store`, build artifacts). Use the standard GitHub Swift gitignore as a base.
- First commit is the scaffold, not a dump of the whole finished app.

**Branching**
- `main` stays green (always compiles).
- Do real work on short-lived feature branches: `feat/permission-flow`, `feat/swipe-mechanics`, etc. Merge to `main` when the milestone is complete and compiling. (Solo MVP — no PR ceremony required, but keep the discipline.)

**Commit style — Conventional Commits**
- Format: `type(scope): summary` in the imperative mood, ≤ 72 chars on the subject line.
- Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `style`, `test`, `perf`, `build`.
- Add a body when the *why* isn't obvious from the subject. Explain reasoning and any non-obvious trade-off, not just the what.
- **One logical change per commit.** Do not mix a refactor with a feature. Do not commit commented-out code or debug prints.

Examples:
```
feat(permissions): route to explainer screen on limited access

PHAuthorizationStatus .limited can't support bulk cleaning, so we
block the swipe flow and deep-link to Settings instead.

feat(swipe): add single-step undo for the last card
fix(delete): handle user cancelling the system delete confirmation
chore(git): add Xcode/Swift gitignore
docs(readme): document PhotoKit batch-delete constraint
```

**Hygiene**
- Commit at milestone boundaries, not in giant end-of-day blobs.
- Each commit must build. Never commit a broken `main`.
- Keep the README current as features land (setup steps, min iOS version, known limitations).

---

## 8. README must cover

- One-line description and the swipe-left/right model.
- **The batch-delete constraint** (so future-you / any contributor understands why deletion isn't per-swipe).
- Setup: clone, open in Xcode, set signing team, run on a **real device** (the simulator has no real photo library — note this).
- Min iOS version and any assumptions.
- Known MVP limitations (local-only state, no dupe detection, no videos).

---

## 9. Definition of done (MVP)

- Fresh install → permission request → full access → swipe through oldest-first photos.
- Left/right swipes persist; reviewed photos never reappear after relaunch.
- Undo restores the last card once.
- `Delete (N)` → review sheet → untick → confirm → single system prompt → photos deleted → "Freed ~X MB".
- Empty deck shows "All caught up 🎉".
- `main` compiles, history is a clean sequence of conventional commits, README is accurate.

Build it tight. Ask for clarification only if something here genuinely conflicts; otherwise proceed milestone by milestone.
