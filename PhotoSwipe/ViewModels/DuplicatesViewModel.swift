import Foundation
import SwiftUI

/// Drives the Duplicates screen: runs the opt-in scan (with progress + cancel),
/// then the grouping pass, and exposes the resulting groups. The heavy work
/// lives in `LibraryIndexService` (off the main actor); this just orchestrates
/// and publishes state. The index persists in SwiftData via `IndexStore`, so a
/// re-scan is incremental.
///
/// Auto-refresh: once an index exists, opening the screen (or any library
/// change — add / delete / capture) re-runs the incremental scan. The first
/// scan stays opt-in. Sensitivity changes only re-group (no rescan), so they're
/// cheap.
@MainActor
final class DuplicatesViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle        // never scanned — show the explainer
        case scanning    // first / full scan with progress
        case grouping    // comparing prints into groups
        case results     // groups found
        case empty       // scan complete, nothing similar
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var assetsByID: [String: PhotoAsset] = [:]
    /// True while re-running in the background with results already on screen.
    @Published private(set) var isRefreshing = false

    /// Feature-print distance ceiling for grouping. Set from the sensitivity
    /// slider; changing it only re-groups (no rescan).
    var distanceThreshold: Double = 0.3

    var progress: Double {
        total > 0 ? Double(processed) / Double(total) : 0
    }

    private let indexService = LibraryIndexService()
    private let store = IndexStore.shared
    /// Scans and regroups run strictly one at a time through this queue, so a
    /// library change mid-scan queues a follow-up instead of replacing the
    /// handle to the running scan, Cancel always reaches the real work, and a
    /// run requested right after Cancel waits for the old one to unwind.
    private let queue = SerialTaskQueue()
    private var isRunning = false
    /// A run is waiting in the queue; further requests fold into it. The
    /// queued run is conditional (only if an index exists) unless *any*
    /// requester asked for it unconditionally.
    private var isRunQueued = false
    private var queuedRunIsConditional = true
    /// The `libraryVersion` the last run started from. Re-appearing with an
    /// unchanged library (popping back from a deck, switching tabs) is then a
    /// no-op instead of another fetch + incremental scan + regroup.
    private var lastRunLibraryVersion: Int?
    /// A regroup is waiting; slider ticks fold into it and it reads the latest
    /// threshold when it starts, so the final value is never dropped.
    private var isRegroupQueued = false
    /// Last fetched asset list, reused by regroup so the sensitivity slider
    /// doesn't re-enumerate the whole library on every tick.
    private var lastAssets: [PhotoAsset] = []
    /// The index snapshot the last run grouped from, and the library version
    /// it belongs to. A regroup at the same version reuses it instead of
    /// re-reading every vector from SwiftData, so slider ticks cost only the
    /// pairwise pass. Released with the view model when the screen pops.
    private var lastIndexed: [IndexedAsset] = []
    private var lastIndexedVersion: Int?

    func asset(for id: String) -> PhotoAsset? { assetsByID[id] }

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

    /// On first appearance: auto-refresh if we've scanned before, otherwise
    /// leave the explainer up so the first scan stays opt-in.
    func onAppear(using service: PhotoLibraryService) {
        guard lastRunLibraryVersion != service.libraryVersion else { return }
        enqueueRun(using: service, onlyIfIndexed: true)
    }

    /// The library changed while the screen is alive — refresh if already scanned.
    func onLibraryChange(using service: PhotoLibraryService) {
        enqueueRun(using: service, onlyIfIndexed: true)
    }

    /// The explainer's "Scan library" button — the opt-in first pass.
    func startFirstScan(using service: PhotoLibraryService) {
        service.invalidateFetchCache()
        enqueueRun(using: service, onlyIfIndexed: false)
    }

    /// Manual reload button on the results/empty screen. Drops the shared
    /// fetch cache first so the run sees the library as it is now.
    func reload(using service: PhotoLibraryService) {
        service.invalidateFetchCache()
        enqueueRun(using: service, onlyIfIndexed: false)
    }

    /// Sensitivity changed — regroup from the existing index (no rescan).
    func updateThreshold(_ threshold: Double, using service: PhotoLibraryService) {
        distanceThreshold = threshold
        guard phase == .results || phase == .empty, !isRegroupQueued else { return }
        isRegroupQueued = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            self.isRegroupQueued = false
            await self.regroup(using: service)
        }
    }

    /// Stops the running scan/regroup and drops anything queued behind it.
    /// `isRunning` is left to the run's own `defer` so a follow-up request
    /// can't overlap the cancelled run while it unwinds.
    func cancel() {
        PhotoKitDiag.log.info("duplicates: cancel (running=\(self.isRunning), visible=\(self.isVisible))")
        queue.cancelAll()
        isRunQueued = false
        isRegroupQueued = false
        isRefreshing = false
        lastRunLibraryVersion = nil
        phase = groups.isEmpty ? .idle : .results
    }

    private func enqueueRun(using service: PhotoLibraryService, onlyIfIndexed: Bool) {
        queuedRunIsConditional = isRunQueued
            ? (queuedRunIsConditional && onlyIfIndexed)
            : onlyIfIndexed
        guard !isRunQueued else { return }
        isRunQueued = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            let conditional = self.queuedRunIsConditional
            self.isRunQueued = false
            if conditional, !(await self.hasIndex()) { return }
            await self.run(using: service)
        }
    }

    // MARK: - Run

    private func run(using service: PhotoLibraryService) async {
        guard !isRunning, !Task.isCancelled else { return }
        isRunning = true
        lastRunLibraryVersion = service.libraryVersion
        defer { isRunning = false; isRefreshing = false }

        // Keep results visible during a background refresh; show full progress
        // only when there's nothing on screen yet.
        let showProgress = groups.isEmpty
        if showProgress {
            phase = .scanning
            processed = 0
            total = 0
        } else {
            isRefreshing = true
        }

        let version = service.libraryVersion
        let assets = await service.fetchImages(source: .allPhotos)
        lastAssets = assets
        do {
            // Keep the duplicate pass lightweight and predictable. Category
            // enrichment owns its additional Vision models and runs from the
            // Categories screen rather than multiplying this scan's work.
            // Search embeddings are different: they ride the thumbnail this
            // walk already loads, so once the user has opted in, doing them
            // here saves Search a second walk of the same library.
            try await indexService.scan(assets: assets, store: store,
                                        includeCategories: false,
                                        includeSearch: SearchViewModel.isEnabled) { done, tot in
                Task { @MainActor in
                    // Hops can land out of order; the counter never steps back.
                    self.processed = max(self.processed, done)
                    self.total = tot
                }
            }
            if showProgress { phase = .grouping }
            let indexed = try await store.allIndexed()
            lastIndexed = indexed
            lastIndexedVersion = version
            let computed = try await group(assets: assets, indexed: indexed)
            apply(groups: computed, from: assets)
        } catch is CancellationError {
            if showProgress { phase = .idle }
        } catch {
            if showProgress { phase = .idle }
        }
    }

    private func regroup(using service: PhotoLibraryService) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; isRefreshing = false }
        isRefreshing = true

        let assets = lastAssets.isEmpty
            ? await service.fetchImages(source: .allPhotos)
            : lastAssets
        lastAssets = assets
        let indexed: [IndexedAsset]
        if lastIndexedVersion == service.libraryVersion, !lastIndexed.isEmpty {
            indexed = lastIndexed
        } else {
            indexed = (try? await store.allIndexed()) ?? []
            lastIndexed = indexed
            lastIndexedVersion = service.libraryVersion
        }
        // Don't clobber the current results if this regroup is cancelled.
        if let computed = try? await group(assets: assets, indexed: indexed) {
            apply(groups: computed, from: assets)
        }
    }

    /// Runs the (cancelable, off-main) grouping pass at the current sensitivity.
    private func group(assets: [PhotoAsset], indexed: [IndexedAsset]) async throws -> [DuplicateGroup] {
        let faceStore = await FaceStore.shared()
        let faceQuality = (try? await faceStore.bestFaceQualityByAsset()) ?? [:]
        return try await indexService.groups(
            assets: assets,
            indexed: indexed,
            faceQuality: faceQuality,
            distanceThreshold: Float(distanceThreshold)
        )
    }

    private func hasIndex() async -> Bool {
        ((try? await store.count()) ?? 0) > 0
    }

    private func apply(groups computed: [DuplicateGroup], from assets: [PhotoAsset]) {
        let memberIDs = Set(computed.flatMap(\.assetIDs))
        assetsByID = Dictionary(
            assets.filter { memberIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        groups = computed
        phase = computed.isEmpty ? .empty : .results
    }
}
