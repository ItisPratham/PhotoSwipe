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
    /// Progress of the largest-first size measurement while loading. Total is
    /// zero when nothing is being measured.
    @Published private(set) var measuredCount = 0
    @Published private(set) var measureTotal = 0

    var isMeasuring: Bool { measureTotal > 0 }

    private let store: ReviewStore
    private let stats: StatsStore
    private let sizes: SizeStore

    /// What's currently feeding the deck. Chosen at construction time by the
    /// parent screen (Browse) — every launch starts fresh on Browse, so no
    /// persistence is needed here.
    private(set) var source: DeckSource

    init(store: ReviewStore,
         stats: StatsStore,
         sizes: SizeStore,
         source: DeckSource) {
        self.store = store
        self.stats = stats
        self.sizes = sizes
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

    /// The next `limit` cards after the current one, for image prefetching.
    /// Empty at the end of the deck or while loading.
    func upcomingAssets(limit: Int) -> [PhotoAsset] {
        let start = currentIndex + 1
        let end = min(assets.count, start + limit)
        guard limit > 0, start < end else { return [] }
        return Array(assets[start..<end])
    }

    /// The `PhotoLibraryService.libraryVersion` the current deck was built
    /// from. Nil until the first load.
    private var loadedLibraryVersion: Int?
    /// The asset the last swipe decided, so undo can be validated after a
    /// silent refresh rebuilds the deck.
    private var lastDecidedID: String?
    private var isRefreshing = false
    /// The running size measurement, so Cancel can reach it.
    private var measureTask: Task<[String: Int64], Error>?

    /// Called on every appearance. Builds the deck on the first call; later
    /// calls (switching tabs, popping back) keep the deck and the user's place
    /// and only refresh silently if the library changed in the meantime.
    func loadIfNeeded(using service: PhotoLibraryService) async {
        if loadedLibraryVersion == nil {
            await load(using: service)
        } else {
            await refreshIfStale(using: service)
        }
    }

    /// Full (re)load behind the loading indicator: rebuilds the deck from
    /// scratch and resets the cursor and undo. A cancelled size measurement
    /// leaves the deck untouched (the screen is being dismissed).
    func load(using service: PhotoLibraryService) async {
        isLoading = true
        let version = service.libraryVersion
        guard let deck = await buildDeck(using: service, keeping: []) else { return }
        assets = deck
        currentIndex = 0
        canUndo = false
        lastDecidedID = nil
        loadedLibraryVersion = version
        isLoading = false
    }

    /// The library changed (our own batch delete, iCloud sync, a new photo):
    /// rebuild the deck without a loading flash and without losing the place.
    /// Cards already shown this session stay in the deck so the cursor and the
    /// single-step undo keep pointing at the right cards; assets that vanished
    /// from the library drop out; new unreviewed assets slot in.
    func refreshIfStale(using service: PhotoLibraryService) async {
        guard loadedLibraryVersion != nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        while let loaded = loadedLibraryVersion, loaded != service.libraryVersion {
            let version = service.libraryVersion
            let shownBefore = Set(assets.prefix(currentIndex).map(\.id))
            guard let fresh = await buildDeck(using: service, keeping: shownBefore) else { return }
            // The user may have swiped while we were fetching — re-read the place.
            let shown = Set(assets.prefix(currentIndex).map(\.id))
            let newIndex = fresh.firstIndex { !shown.contains($0.id) } ?? fresh.count
            assets = fresh
            currentIndex = newIndex
            if canUndo, !(newIndex > 0 && fresh[newIndex - 1].id == lastDecidedID) {
                canUndo = false
            }
            loadedLibraryVersion = version
        }
    }

    /// Fetches the source and filters out already-reviewed assets, except the
    /// ids in `keeping` (cards already shown this session). Nil only when a
    /// largest-first measurement was cancelled.
    private func buildDeck(using service: PhotoLibraryService,
                           keeping: Set<String>) async -> [PhotoAsset]? {
        let fetched = await service.fetchImages(source: source)
        let deck = fetched.filter { keeping.contains($0.id) || !store.isReviewed($0.id) }
        if source.order == .largestFirst {
            return await sortedByLargest(deck, using: service)
        }
        return deck
    }

    /// Sorts the deck by on-device byte size, descending. Sizes come from the
    /// cache, topped up from the duplicate index; anything still unmeasured
    /// is enumerated once (metadata only, no download) with progress and
    /// Cancel, and folded back into the cache for next time. Nil if cancelled.
    private func sortedByLargest(_ deck: [PhotoAsset],
                                 using service: PhotoLibraryService) async -> [PhotoAsset]? {
        var missing = deck.filter { sizes.size(for: $0.id) == nil }
        if !missing.isEmpty {
            await sizes.adoptIndexedSizes()
            missing = missing.filter { sizes.size(for: $0.id) == nil }
        }
        if !missing.isEmpty {
            measuredCount = 0
            measureTotal = missing.count
            defer { measureTotal = 0; measuredCount = 0; measureTask = nil }
            let task = Task { [weak self] in
                try await service.byteSizes(for: missing) { done, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        // Callbacks may land out of order; never step back.
                        self.measuredCount = max(self.measuredCount, done)
                    }
                }
            }
            measureTask = task
            guard let measured = try? await task.value else { return nil }
            sizes.merge(measured)
        }
        return deck.sorted {
            (sizes.size(for: $0.id) ?? 0) > (sizes.size(for: $1.id) ?? 0)
        }
    }

    /// Stops a running size measurement. The caller dismisses the deck, since
    /// a largest-first deck can't be built without the sizes.
    func cancelMeasuring() {
        measureTask?.cancel()
    }

    /// Right swipe — keep and never show again.
    func keep() {
        guard let asset = currentAsset else { return }
        store.markKept(asset.id)
        lastDecidedID = asset.id
        currentIndex += 1
        canUndo = true
    }

    /// Left swipe — mark for batch deletion (also counts as reviewed).
    func markForDeletion() {
        guard let asset = currentAsset else { return }
        store.markForDeletion(asset.id)
        lastDecidedID = asset.id
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
