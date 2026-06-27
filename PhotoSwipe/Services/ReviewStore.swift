import Foundation
import SwiftUI

/// Persists swipe decisions keyed by `PHAsset.localIdentifier`. Two sets:
///
/// - `reviewedIDs`: every asset the user has judged (kept OR marked for
///   deletion). Excluded from future fetches so the deck never re-shows them.
/// - `markedForDeletionIDs`: subset awaiting batch deletion. Drives the
///   Delete(N) button and the review sheet.
///
/// Storage is UserDefaults — small, simple, fits MVP scope. Reinstall or new
/// device = fresh start; that trade-off is documented in the README.
@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var reviewedIDs: Set<String>
    @Published private(set) var markedForDeletionIDs: Set<String>

    private let defaults: UserDefaults
    private let reviewedKey = "PhotoSwipe.reviewedIDs"
    private let deletionKey = "PhotoSwipe.markedForDeletionIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reviewedIDs = Set(defaults.stringArray(forKey: reviewedKey) ?? [])
        self.markedForDeletionIDs = Set(defaults.stringArray(forKey: deletionKey) ?? [])
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
    func forget(ids: Set<String>) {
        reviewedIDs.subtract(ids)
        markedForDeletionIDs.subtract(ids)
        persist()
    }

    private func persist() {
        defaults.set(Array(reviewedIDs), forKey: reviewedKey)
        defaults.set(Array(markedForDeletionIDs), forKey: deletionKey)
    }
}
