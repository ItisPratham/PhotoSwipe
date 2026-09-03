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
    /// Decisions made this session, most recent last. Undo pops from here;
    /// see `undo()` for how entries are validated against the live deck.
    @Published private(set) var undoStack: [UndoEntry] = []
    /// How many decisions Undo can walk back.
    static let undoLimit = 50

    var canUndo: Bool { !undoStack.isEmpty }
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
        undoStack.removeAll()
        loadedLibraryVersion = version
        isLoading = false
    }

    /// The library changed (our own batch delete, iCloud sync, a new photo):
    /// rebuild the deck without a loading flash and without losing the place.
    /// Cards already shown this session stay in the deck so the cursor and the
    /// undo stack keep pointing at real cards; assets that vanished from the
    /// library drop out (and leave the stack); new unreviewed assets slot in.
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
            let live = Set(fresh.prefix(newIndex).map(\.id))
            undoStack.removeAll { !live.contains($0.assetID) }
            loadedLibraryVersion = version
        }
    }

    /// Fetches the source and filters out already-reviewed assets, except the
    /// ids in `keeping` (cards already shown this session). Nil only when a
    /// largest-first measurement was cancelled.
    private func buildDeck(using service: PhotoLibraryService,
                           keeping: Set<String>) async -> [PhotoAsset]? {
        async let fetch = service.fetchImages(source: source)
        // The decision file is read in the background at launch; the deck
        // can't be filtered until it's in.
        await store.waitUntilLoaded()
        let fetched = await fetch
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
        await sizes.waitUntilLoaded()
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
        advance(recording: UndoEntry(assetID: asset.id))
    }

    /// Left swipe — mark for batch deletion (also counts as reviewed).
    func markForDeletion() {
        guard let asset = currentAsset else { return }
        store.markForDeletion(asset.id)
        advance(recording: UndoEntry(assetID: asset.id))
    }

    /// Swipe up — a keep plus a library write chosen in Settings (favorite by
    /// default). The write runs after the card has advanced so it never delays
    /// the fly-off; Undo reverts it. A photo that is already a favorite gets
    /// no write and no reversal.
    func swipeUp(action: SwipeUpAction, using service: PhotoLibraryService) {
        guard let asset = currentAsset else { return }
        store.markKept(asset.id)
        var effect: UndoEntry.SideEffect?
        switch action {
        case .favorite:
            effect = asset.isFavorite ? nil : .favorited
        }
        advance(recording: UndoEntry(assetID: asset.id, sideEffect: effect))
        if effect != nil {
            let id = asset.id
            Task { await Self.apply(effect, to: id, using: service) }
        }
    }

    private static func apply(_ effect: UndoEntry.SideEffect?, to id: String,
                              using service: PhotoLibraryService) async {
        switch effect {
        case .favorited: await service.setFavorite(id: id, true)
        case nil: break
        }
    }

    private static func revert(_ effect: UndoEntry.SideEffect?, on id: String,
                               using service: PhotoLibraryService) async {
        switch effect {
        case .favorited: await service.setFavorite(id: id, false)
        case nil: break
        }
    }

    /// Moves past the current card and records the decision for Undo, keeping
    /// the stack within `undoLimit`.
    private func advance(recording entry: UndoEntry) {
        currentIndex += 1
        undoStack.append(entry)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
    }

    /// Walks back to the most recent decision whose card is still in the deck
    /// behind the cursor, clears that decision, and makes it the current card.
    /// Cards between it and the cursor (unreviewed ones a silent refresh may
    /// have slotted in) are simply shown again. Entries whose card is gone —
    /// batch-deleted, or removed by a refresh — are dropped, never replayed.
    func undo(using service: PhotoLibraryService) {
        while let entry = undoStack.popLast() {
            guard let index = assets.prefix(currentIndex).lastIndex(where: { $0.id == entry.assetID })
            else { continue }
            currentIndex = index
            store.clearDecision(for: entry.assetID)
            if let effect = entry.sideEffect {
                Task { await Self.revert(effect, on: entry.assetID, using: service) }
            }
            return
        }
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
            // Undo can't reach across a confirmed delete — the photos are gone
            // and the surviving decisions were reviewed on the way to it.
            undoStack.removeAll()
            lastFreedBytes = bytes
        }
        return success
    }
}
