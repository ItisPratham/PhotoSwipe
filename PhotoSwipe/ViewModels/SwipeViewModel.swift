import Foundation
import SwiftUI

/// Owns the deck of fetched assets and the cursor through it. Decisions are
/// delegated to `ReviewStore` so they survive relaunch; the fetched deck is
/// filtered to exclude any asset the user has already judged.
@MainActor
final class SwipeViewModel: ObservableObject {
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isLoading: Bool = true
    /// True after a swipe that hasn't been undone. Single-step only — undoing
    /// flips this off until the next swipe.
    @Published private(set) var canUndo: Bool = false
    /// Bytes reclaimed by the most recent successful delete. Surfaced to the
    /// UI as a "Freed ~X MB" banner and cleared after the user sees it.
    @Published var lastFreedBytes: Int64? = nil

    private let store: ReviewStore
    private let stats: StatsStore

    /// What's currently feeding the deck. Chosen at construction time by the
    /// parent screen (Browse) — every launch starts fresh on Browse, so no
    /// persistence is needed here.
    private(set) var source: DeckSource

    init(store: ReviewStore,
         stats: StatsStore,
         source: DeckSource) {
        self.store = store
        self.stats = stats
        self.source = source
    }

    var currentAsset: PhotoAsset? {
        guard currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    var isFinished: Bool {
        !isLoading && currentIndex >= assets.count
    }

    var pendingDeletionCount: Int {
        store.markedForDeletionIDs.count
    }

    /// Loads the deck for the configured source and filters out already-reviewed
    /// assets. Safe to call repeatedly — the next call rebuilds the deck from
    /// scratch.
    func load(using service: PhotoLibraryService) async {
        isLoading = true
        let fetched = await service.fetchImages(source: self.source)
        assets = fetched.filter { !store.isReviewed($0.id) }
        currentIndex = 0
        canUndo = false
        isLoading = false
    }

    /// Right swipe — keep and never show again.
    func keep() {
        guard let asset = currentAsset else { return }
        store.markKept(asset.id)
        currentIndex += 1
        canUndo = true
    }

    /// Left swipe — mark for batch deletion (also counts as reviewed).
    func markForDeletion() {
        guard let asset = currentAsset else { return }
        store.markForDeletion(asset.id)
        currentIndex += 1
        canUndo = true
    }

    /// Restore the previous card and clear whatever mark it received. Single
    /// step only: the user can't chain undos.
    func undo() {
        guard canUndo, currentIndex > 0 else { return }
        currentIndex -= 1
        if let asset = currentAsset {
            store.clearDecision(for: asset.id)
        }
        canUndo = false
    }

    /// Performs a batched delete of every asset currently marked for deletion.
    /// PhotoKit always prompts the user — returning `true` here means they
    /// confirmed and the delete succeeded; on success we drop those IDs from
    /// the store entirely. On cancel/failure the marks stay so the user can
    /// retry or untick more.
    @discardableResult
    func confirmDelete(using service: PhotoLibraryService) async -> Bool {
        let ids = store.markedForDeletionIDs
        guard !ids.isEmpty else { return false }
        // Compute size before delete — once the assets are gone PhotoKit can't
        // tell us how big they were.
        let bytes = await service.totalSize(forIDs: ids)
        let success = await service.deleteAssets(ids: ids)
        if success {
            store.forget(ids: ids)
            stats.recordDelete(count: ids.count, bytesFreed: bytes)
            // Undo can't reach across a confirmed delete — the photo is gone.
            canUndo = false
            lastFreedBytes = bytes
        }
        return success
    }
}
