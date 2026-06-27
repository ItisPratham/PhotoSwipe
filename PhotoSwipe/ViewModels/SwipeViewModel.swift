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

    private let store: ReviewStore

    init(store: ReviewStore) {
        self.store = store
    }

    var currentAsset: PhotoAsset? {
        guard currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    var isFinished: Bool {
        !isLoading && currentIndex >= assets.count
    }

    /// Loads the library and filters out already-reviewed assets. Safe to call
    /// repeatedly — the next call rebuilds the deck from scratch.
    func load(using service: PhotoLibraryService) async {
        isLoading = true
        let fetched = await service.fetchAllImages()
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

}
