import Foundation
import SwiftUI

/// Persists swipe decisions keyed by `PHAsset.localIdentifier`. Two sets:
///
/// - `reviewedIDs`: every asset the user has judged (kept OR marked for
///   deletion). Excluded from future fetches so the deck never re-shows them.
/// - `markedForDeletionIDs`: subset awaiting batch deletion. Drives the
///   Delete(N) button and the review sheet.
///
/// Storage is a JSON file in Application Support (`review.json`). Writes are
/// debounced and happen on a serial background queue, so a swipe never pays
/// for serialising tens of thousands of IDs on the main thread. `flush()`
/// writes synchronously and is called when the app leaves the foreground, and
/// after the rare, important changes (batch delete, reset). Reinstall or new
/// device = fresh start; that trade-off is documented in the README.
///
/// Up to 4.1 the sets lived in UserDefaults. The first launch after the
/// upgrade migrates them into the file and clears the old keys.
@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var reviewedIDs: Set<String>
    @Published private(set) var markedForDeletionIDs: Set<String>

    private struct Snapshot: Codable {
        var reviewed: [String]
        var marked: [String]
    }

    private let fileURL: URL
    /// All disk writes go through this queue in order, so a debounced write
    /// still in flight can never land after a later `flush()`.
    private let writeQueue = DispatchQueue(label: "PhotoSwipe.ReviewStore.write", qos: .utility)
    private var pendingWrite: Task<Void, Never>?
    private static let writeDelay: Duration = .milliseconds(300)

    private static let legacyReviewedKey = "PhotoSwipe.reviewedIDs"
    private static let legacyDeletionKey = "PhotoSwipe.markedForDeletionIDs"

    nonisolated static var defaultFileURL: URL { LocalStores.fileURL(named: "review.json") }

    init(defaults: UserDefaults = .standard, fileURL: URL = ReviewStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            reviewedIDs = Set(snapshot.reviewed)
            markedForDeletionIDs = Set(snapshot.marked)
        } else {
            // One-time migration from the UserDefaults layout used up to 4.1.
            reviewedIDs = Set(defaults.stringArray(forKey: Self.legacyReviewedKey) ?? [])
            markedForDeletionIDs = Set(defaults.stringArray(forKey: Self.legacyDeletionKey) ?? [])
            if !reviewedIDs.isEmpty || !markedForDeletionIDs.isEmpty {
                flush()
                defaults.removeObject(forKey: Self.legacyReviewedKey)
                defaults.removeObject(forKey: Self.legacyDeletionKey)
            }
        }
    }

    func isReviewed(_ id: String) -> Bool {
        reviewedIDs.contains(id)
    }

    /// Right-swipe: keep and never show again.
    func markKept(_ id: String) {
        reviewedIDs.insert(id)
        persist()
    }

    /// Left-swipe: keep out of the deck and queue for batch deletion.
    func markForDeletion(_ id: String) {
        reviewedIDs.insert(id)
        markedForDeletionIDs.insert(id)
        persist()
    }

    /// Untick from the review sheet — still counts as reviewed (the user has
    /// judged it), just no longer queued for deletion.
    func spare(_ id: String) {
        markedForDeletionIDs.remove(id)
        persist()
    }

    /// Clear any decision about an asset. Used by undo so the card can re-enter
    /// the deck cleanly.
    func clearDecision(for id: String) {
        reviewedIDs.remove(id)
        markedForDeletionIDs.remove(id)
        persist()
    }

    /// Drop IDs after a successful batch delete — the assets no longer exist.
    /// Also used to prune decisions for photos deleted outside the app.
    func forget(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        reviewedIDs.subtract(ids)
        markedForDeletionIDs.subtract(ids)
        persist(immediately: true)
    }

    /// Wipes every kept/marked decision so the whole library re-enters the
    /// deck as un-reviewed. Photos themselves are untouched — this only
    /// clears the app's tracking.
    func resetAll() {
        reviewedIDs.removeAll()
        markedForDeletionIDs.removeAll()
        persist(immediately: true)
    }

    /// Drops decisions for assets that no longer exist in the library, so the
    /// Review pill and the delete count stop over-reporting after photos are
    /// deleted in Photos.app. The lookup runs off the main actor; only the
    /// IDs confirmed missing are removed, so decisions made meanwhile survive.
    func pruneMissing(using service: PhotoLibraryService) async {
        let candidates = reviewedIDs
        guard !candidates.isEmpty else { return }
        let existing = await service.existingIdentifiers(among: candidates)
        forget(ids: candidates.subtracting(existing))
    }

    // MARK: - Persistence

    /// Writes the current state to disk now, in order behind any write that
    /// is already queued. Call before the app leaves the foreground.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        let snapshot = currentSnapshot()
        let url = fileURL
        writeQueue.sync { Self.write(snapshot, to: url) }
    }

    /// Debounced by default: a run of swipes produces one write, a short
    /// moment after the last one. In-memory state is always current, so
    /// readers never see the delay.
    private func persist(immediately: Bool = false) {
        pendingWrite?.cancel()
        if immediately {
            flush()
            return
        }
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.currentSnapshot()
            let url = self.fileURL
            self.writeQueue.async { Self.write(snapshot, to: url) }
        }
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(reviewed: Array(reviewedIDs), marked: Array(markedForDeletionIDs))
    }

    nonisolated private static func write(_ snapshot: Snapshot, to url: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
