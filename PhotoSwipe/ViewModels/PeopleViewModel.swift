import Foundation
import SwiftUI

/// Drives the People tab: runs the opt-in face scan (progress + cancel), folds
/// new faces into clusters, and exposes the resulting people. The heavy work
/// lives off the main actor (`FaceIndexService` detect+embed, `FaceClusterer`);
/// this just orchestrates and publishes state. Faces + clusters persist in
/// SwiftData via `FaceStore`, so a re-scan is incremental and user names /
/// merges / hides survive.
@MainActor
final class PeopleViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle          // never scanned — show the explainer
        case scanning      // detecting + embedding, with progress
        case clustering    // grouping embeddings into people
        case results       // clusters found
        case empty         // scan complete, no faces
        case unavailable   // the AdaFace model isn't bundled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var clusters: [PersonCluster] = []
    /// Hidden people — kept out of the main grid but reachable so they can be
    /// unhidden. Without this the hide action would be a one-way trip.
    @Published private(set) var hiddenClusters: [PersonCluster] = []
    /// True while re-running in the background with results already on screen.
    @Published private(set) var isRefreshing = false

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }
    var isModelAvailable: Bool { embedder.isAvailable }

    /// Cosine-similarity floor for grouping faces into the same person. Higher =
    /// stricter = more, smaller clusters. Kept in sync with the debug grouping
    /// view so the production People tab uses the validated setting.
    var similarityThreshold: Float = FaceClusterer.defaultThreshold

    private let indexService = FaceIndexService()
    private let clusterer = FaceClusterer()
    private let embedder = FaceEmbedder.shared
    private let store = FaceStore(modelContainer: FaceContainer.shared)
    /// Scans and regroups run strictly one at a time through this queue, so a
    /// library change mid-scan queues a follow-up instead of replacing the
    /// handle to the running scan, Cancel always reaches the real work, and a
    /// run requested right after Cancel waits for the old one to unwind.
    private let queue = SerialTaskQueue()
    private var isRunning = false
    /// A run is waiting in the queue; further requests fold into it. The
    /// queued run is conditional (only if faces exist) unless *any* requester
    /// asked for it unconditionally.
    private var isRunQueued = false
    private var queuedRunIsConditional = true
    /// A regroup is waiting; slider ticks fold into it and it reads the latest
    /// threshold when it starts, so the final value is never dropped and the
    /// store never sees two full re-clusters for one drag.
    private var isRegroupQueued = false
    /// The `libraryVersion` the last run started from. Re-appearing with an
    /// unchanged library (popping back from a deck, switching tabs) is then a
    /// no-op instead of another fetch + incremental scan + regroup.
    private var lastRunLibraryVersion: Int?

    // MARK: - Entry points

    /// On appear: if a scan has already run, refresh incrementally; otherwise
    /// leave the explainer up so the first scan stays opt-in. Surfaces the
    /// model-missing state up front.
    func onAppear(using service: PhotoLibraryService) {
        guard embedder.isAvailable else { phase = .unavailable; return }
        guard lastRunLibraryVersion != service.libraryVersion else { return }
        enqueueRun(using: service, onlyIfScanned: true)
    }

    func onLibraryChange(using service: PhotoLibraryService) {
        guard embedder.isAvailable else { return }
        enqueueRun(using: service, onlyIfScanned: true)
    }

    /// The explainer's "Scan library" button — the opt-in first pass.
    func startFirstScan(using service: PhotoLibraryService) {
        guard embedder.isAvailable else { phase = .unavailable; return }
        enqueueRun(using: service, onlyIfScanned: false)
    }

    func reload(using service: PhotoLibraryService) {
        enqueueRun(using: service, onlyIfScanned: false)
    }

    /// Stops the running scan and drops anything queued behind it. `isRunning`
    /// is left to the run's own `defer` so a follow-up request can't overlap
    /// the cancelled run while it unwinds.
    func cancel() {
        queue.cancelAll()
        isRunQueued = false
        isRegroupQueued = false
        isRefreshing = false
        phase = clusters.isEmpty ? .idle : .results
    }

    private func enqueueRun(using service: PhotoLibraryService, onlyIfScanned: Bool) {
        queuedRunIsConditional = isRunQueued
            ? (queuedRunIsConditional && onlyIfScanned)
            : onlyIfScanned
        guard !isRunQueued else { return }
        isRunQueued = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            let conditional = self.queuedRunIsConditional
            self.isRunQueued = false
            if conditional, !(await self.hasFaces()) { return }
            await self.run(using: service)
        }
    }

    // MARK: - Run

    private func run(using service: PhotoLibraryService) async {
        guard !isRunning, !Task.isCancelled else { return }
        isRunning = true
        lastRunLibraryVersion = service.libraryVersion
        defer { isRunning = false; isRefreshing = false }

        let showProgress = clusters.isEmpty
        if showProgress {
            phase = .scanning
            processed = 0
            total = 0
        } else {
            isRefreshing = true
        }

        let assets = await service.fetchImages(source: DeckSource(scope: .allPhotos, media: .photos))
        do {
            try await indexService.scan(assets: assets, store: store, embedder: embedder) { done, tot in
                Task { @MainActor in
                    // Hops can land out of order; the counter never steps back.
                    self.processed = max(self.processed, done)
                    self.total = tot
                }
            }
            if showProgress { phase = .clustering }
            await reclusterIncremental()
        } catch is CancellationError {
            phase = clusters.isEmpty ? .idle : .results
        } catch FaceScanError.modelUnavailable {
            phase = .unavailable
        } catch {
            phase = clusters.isEmpty ? .idle : .results
        }
    }

    /// Normal incremental path: only assigns faces that have no cluster yet.
    /// Existing clusters (and their names, merges, hides, and covers) are
    /// untouched. O(1) when nothing new has been scanned since the last run.
    private func reclusterIncremental() async {
        let unclustered = (try? await store.unclusteredFaces()) ?? []
        guard !unclustered.isEmpty else {
            await loadClusters()
            return
        }
        let existing = (try? await store.clusteredFaces()) ?? []
        let clusterer = self.clusterer
        let threshold = similarityThreshold
        let result = await Task.detached(priority: .utility) {
            clusterer.assign(newFaces: unclustered, existingFaces: existing, threshold: threshold)
        }.value
        try? await store.applyClustering(
            newPersons: result.newPersons,
            assignments: result.assignments,
            at: Date()
        )
        await loadClusters()
    }

    /// Hard re-cluster: wipes all person assignments and clusters from scratch.
    /// Destroys user names, merges, hides, and covers — only call when the user
    /// explicitly requests it (e.g., a "Re-cluster" debug button).
    func reclusterFull() async {
        guard let faces = try? await store.allFaces(), !faces.isEmpty else {
            await loadClusters()
            return
        }
        let clusterer = self.clusterer
        let threshold = similarityThreshold
        let result = await Task.detached(priority: .utility) {
            clusterer.cluster(newFaces: faces, existing: [], threshold: threshold)
        }.value
        try? await store.resetAssignments()
        try? await store.applyClustering(
            newPersons: result.newPersons,
            assignments: result.assignments,
            at: Date()
        )
        await loadClusters()
    }

    /// Sensitivity-slider entry point: re-group everyone at a new threshold from
    /// the already-cached embeddings (no re-scan — seconds, not minutes). This is
    /// a full re-cluster, so it clears names/merges/hides; tuning is meant as a
    /// pre-naming step. Queued behind any running scan rather than racing it.
    func regroup(threshold: Float) {
        similarityThreshold = threshold
        guard !isRegroupQueued else { return }
        isRegroupQueued = true
        queue.enqueue { [weak self] in
            guard let self else { return }
            self.isRegroupQueued = false
            self.isRefreshing = true
            await self.reclusterFull()
            self.isRefreshing = false
        }
    }

    private func loadClusters() async {
        let all = (try? await store.clusters()) ?? []
        clusters = all.filter { !$0.isHidden }
        hiddenClusters = all.filter { $0.isHidden }
        phase = (clusters.isEmpty && hiddenClusters.isEmpty) ? .empty : .results
    }

    /// Restores a hidden person back into the main grid.
    func unhide(_ personID: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.store.setHidden(personID: personID, false)
            await self.loadClusters()
        }
    }

    private func hasFaces() async -> Bool {
        ((try? await store.faceCount()) ?? 0) > 0
    }
}
