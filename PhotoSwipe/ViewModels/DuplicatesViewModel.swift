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
    private let store = IndexStore(modelContainer: IndexContainer.shared)
    private var task: Task<Void, Never>?
    private var isRunning = false
    /// Last fetched asset list, reused by regroup so the sensitivity slider
    /// doesn't re-enumerate the whole library on every tick.
    private var lastAssets: [PhotoAsset] = []

    func asset(for id: String) -> PhotoAsset? { assetsByID[id] }

    // MARK: - Entry points

    /// On first appearance: auto-refresh if we've scanned before, otherwise
    /// leave the explainer up so the first scan stays opt-in.
    func onAppear(using service: PhotoLibraryService) {
        task = Task { [weak self] in
            guard let self, await hasIndex() else { return }
            await run(using: service)
        }
    }

    /// The library changed while the screen is alive — refresh if already scanned.
    func onLibraryChange(using service: PhotoLibraryService) {
        task = Task { [weak self] in
            guard let self, await hasIndex() else { return }
            await run(using: service)
        }
    }

    /// The explainer's "Scan library" button — the opt-in first pass.
    func startFirstScan(using service: PhotoLibraryService) {
        task = Task { [weak self] in await self?.run(using: service) }
    }

    /// Manual reload button on the results/empty screen.
    func reload(using service: PhotoLibraryService) {
        task = Task { [weak self] in await self?.run(using: service) }
    }

    /// Sensitivity changed — regroup from the existing index (no rescan).
    func updateThreshold(_ threshold: Double, using service: PhotoLibraryService) {
        distanceThreshold = threshold
        guard phase == .results || phase == .empty else { return }
        task = Task { [weak self] in await self?.regroup(using: service) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        isRefreshing = false
        phase = groups.isEmpty ? .idle : .results
    }

    // MARK: - Run

    private func run(using service: PhotoLibraryService) async {
        guard !isRunning else { return }
        isRunning = true
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

        let assets = await service.fetchImages(source: .allPhotos)
        lastAssets = assets
        do {
            try await indexService.scan(assets: assets, store: store) { done, tot in
                Task { @MainActor in
                    self.processed = done
                    self.total = tot
                }
            }
            if showProgress { phase = .grouping }
            let indexed = try await store.allIndexed()
            let computed = await group(assets: assets, indexed: indexed)
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
        let indexed = (try? await store.allIndexed()) ?? []
        let computed = await group(assets: assets, indexed: indexed)
        apply(groups: computed, from: assets)
    }

    private func group(assets: [PhotoAsset], indexed: [IndexedAsset]) async -> [DuplicateGroup] {
        let threshold = Float(distanceThreshold)
        return await Task.detached(priority: .utility) { [indexService] in
            indexService.groups(assets: assets, indexed: indexed, distanceThreshold: threshold)
        }.value
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
