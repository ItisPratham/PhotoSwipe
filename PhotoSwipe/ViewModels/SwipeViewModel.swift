import Foundation
import SwiftUI

/// Owns the deck of fetched assets, the cursor through it, and the in-memory
/// kept / marked-for-deletion sets. Persistence and undo arrive in later
/// milestones; this layer stays a pure in-memory state machine for now.
@MainActor
final class SwipeViewModel: ObservableObject {
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isLoading: Bool = true

    /// IDs the user right-swiped (keep).
    @Published private(set) var keptIDs: Set<String> = []
    /// IDs the user left-swiped (mark for deletion).
    @Published private(set) var markedForDeletionIDs: Set<String> = []

    var currentAsset: PhotoAsset? {
        guard currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    var isFinished: Bool {
        !isLoading && currentIndex >= assets.count
    }

    func load(using service: PhotoLibraryService) async {
        isLoading = true
        assets = await service.fetchAllImages()
        currentIndex = 0
        isLoading = false
    }

    /// Right swipe — keep and never show again.
    func keep() {
        guard let asset = currentAsset else { return }
        keptIDs.insert(asset.id)
        currentIndex += 1
    }

    /// Left swipe — mark for batch deletion (also counts as reviewed).
    func markForDeletion() {
        guard let asset = currentAsset else { return }
        markedForDeletionIDs.insert(asset.id)
        currentIndex += 1
    }
}
