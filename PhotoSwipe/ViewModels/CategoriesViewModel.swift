import Foundation
import SwiftUI

/// Drives the Browse "Categories" section. The first run is opt-in: it runs
/// the duplicate index scan with category measurement on (so new photos get
/// a print and their signals in one pass), then the categorize pass for rows
/// that predate it, then derives the per-category photo lists. Later
/// appearances and library changes refresh incrementally. Everything runs
/// through a `SerialTaskQueue` like the other scans.
@MainActor
final class CategoriesViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle          // never categorized — show the explainer
        case indexing      // scan pass (prints + signals for new photos)
        case categorizing  // filling rows that predate the pass
        case results
    }

    /// Records that the user opted into on-device category analysis, allowing
    /// later visits and library changes to refresh it incrementally.
    static let enabledKey = "PhotoSwipe.categoriesEnabled"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var idsByCategory: [AssetCategory: [String]] = [:]

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }
    func count(for category: AssetCategory) -> Int { idsByCategory[category]?.count ?? 0 }
    var hasAnyResults: Bool { idsByCategory.values.contains { !$0.isEmpty } }

    private let indexService = LibraryIndexService()
    private let store = IndexStore.shared
    private let queue = SerialTaskQueue()
    private var isRunning = false
    private var isRunQueued = false
    private var queuedRunIsConditional = true
    private var lastRunLibraryVersion: Int?

    // MARK: - Screen lifecycle

    /// Whether the screen is on screen. A scan started from this screen
    /// stops when the screen is popped; a short grace period tells a pop
    /// apart from being covered by a pushed deck, which also fires
    /// onDisappear.
    private var isVisible = false
    private var disappearGrace: Task<Void, Never>?

    func viewAppeared() {
        isVisible = true
        disappearGrace?.cancel()
        disappearGrace = nil
    }

    func viewDisappeared() {
        isVisible = false
        disappearGrace?.cancel()
        disappearGrace = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            self.cancel()
        }
    }

    // MARK: - Entry points

    func onAppear(using service: PhotoLibraryService) {
        guard lastRunLibraryVersion != service.libraryVersion else { return }
        enqueueRun(using: service, onlyIfStarted: true)
    }

    func onLibraryChange(using service: PhotoLibraryService) {
        enqueueRun(using: service, onlyIfStarted: true)
    }

    /// The explainer's button — the opt-in first pass.
    func start(using service: PhotoLibraryService) {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        service.invalidateFetchCache()
        enqueueRun(using: service, onlyIfStarted: false)
    }

    func cancel() {
        queue.cancelAll()
        isRunQueued = false
        isRefreshing = false
        lastRunLibraryVersion = nil
        phase = hasAnyResults ? .results : .idle
    }

    private func enqueueRun(using service: PhotoLibraryService, onlyIfStarted: Bool) {
        queuedRunIsConditional = isRunQueued
            ? (queuedRunIsConditional && onlyIfStarted)
            : onlyIfStarted
        guard !isRunQueued else { return }
        isRunQueued = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            let conditional = self.queuedRunIsConditional
            self.isRunQueued = false
            if conditional, !UserDefaults.standard.bool(forKey: Self.enabledKey) { return }
            await self.run(using: service)
        }
    }

    // MARK: - Run

    private func run(using service: PhotoLibraryService) async {
        guard !isRunning, !Task.isCancelled else { return }
        isRunning = true
        lastRunLibraryVersion = service.libraryVersion
        defer { isRunning = false; isRefreshing = false }

        let showProgress = !hasAnyResults
        if showProgress {
            phase = .indexing
            processed = 0
            total = 0
        } else {
            isRefreshing = true
        }

        let assets = await service.fetchImages(source: .allPhotos)
        do {
            try await indexService.scan(assets: assets, store: store, includeCategories: true) { done, tot in
                Task { @MainActor in
                    self.processed = max(self.processed, done)
                    self.total = tot
                }
            }
            if showProgress { phase = .categorizing; processed = 0; total = 0 }
            try await indexService.categorize(assets: assets, store: store) { done, tot in
                Task { @MainActor in
                    self.processed = max(self.processed, done)
                    self.total = tot
                }
            }
            try await loadResults(assets: assets)
        } catch {
            // Cancelled or failed: keep whatever was on screen.
            phase = hasAnyResults ? .results : .idle
        }
    }

    /// Reads the signals (no vectors) and buckets each photo into its first
    /// matching category.
    private func loadResults(assets: [PhotoAsset]) async throws {
        let screenshotIDs = Set(assets.filter(\.isScreenshot).map(\.id))
        let signals = try await store.categorySignals(screenshotIDs: screenshotIDs)
        let order = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($1.id, $0) })
        let bucketed = await Task.detached(priority: .userInitiated) {
            var buckets: [AssetCategory: [String]] = [:]
            for signal in signals {
                guard order[signal.localIdentifier] != nil,
                      let category = AssetCategory.primary(for: signal)
                else { continue }
                buckets[category, default: []].append(signal.localIdentifier)
            }
            // Oldest first, matching every other deck.
            for key in buckets.keys {
                buckets[key]!.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
            }
            return buckets
        }.value
        idsByCategory = bucketed
        phase = .results
    }
}
