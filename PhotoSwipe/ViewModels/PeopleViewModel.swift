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
        case preparing     // opening the store or loading the face model
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
    /// Pairs of visible people who may be the same person, most similar
    /// first. Refreshed with the clusters; dismissed pairs never return.
    @Published private(set) var mergeSuggestions: [MergeSuggestion] = []

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }
    /// Cosine-similarity floor for grouping faces into the same person. Higher =
    /// stricter = more, smaller clusters. Kept in sync with the debug grouping
    /// view so the production People tab uses the validated setting.
    var similarityThreshold: Float = FaceClusterer.defaultThreshold

    private let indexService = FaceIndexService()
    private let clusterer = FaceClusterer()
    /// Set only by the Scan button. Existing face rows from an older build do
    /// not silently grant consent or trigger a library read.
    private static let scanEnabledKey = "PhotoSwipe.peopleScanEnabled"
    /// User-requested scans and regroups run strictly one at a time, so Cancel
    /// always reaches the real work and a later action waits for the current
    /// operation to unwind.
    private let queue = SerialTaskQueue()
    private var isRunning = false
    /// A user-requested run is waiting in the queue; repeated taps fold into it.
    private var isRunQueued = false
    /// A regroup is waiting; slider ticks fold into it and it reads the latest
    /// threshold when it starts, so the final value is never dropped and the
    /// store never sees two full re-clusters for one drag.
    private var isRegroupQueued = false
    /// Saved clusters are loaded at most once for this tab instance. This is
    /// deliberately separate from scanning: appearing never walks the library.
    private var didLoadSavedPeople = false

    // MARK: - Entry points

    /// Opening People never scans the photo library. Before opt-in it does no
    /// face-store or Core ML work at all; after opt-in it only restores the
    /// clusters already on disk.
    func onAppear() {
        guard UserDefaults.standard.bool(forKey: Self.scanEnabledKey),
              !didLoadSavedPeople
        else { return }
        didLoadSavedPeople = true
        phase = .preparing
        queue.enqueue { [weak self] in
            await self?.loadClusters()
        }
    }

    /// The explainer's "Scan library" button — the opt-in first pass.
    func startFirstScan(using service: PhotoLibraryService) {
        service.invalidateFetchCache()
        enqueueRun(using: service)
    }

    /// Manual reload: must see the library as it is now, so the shared fetch
    /// cache is dropped first — a photo taken while the app was suspended
    /// may never have produced a change notification.
    func reload(using service: PhotoLibraryService) {
        service.invalidateFetchCache()
        enqueueRun(using: service)
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

    private func enqueueRun(using service: PhotoLibraryService) {
        guard !isRunQueued else { return }
        isRunQueued = true
        phase = .preparing
        queue.enqueue { [weak self] in
            guard let self else { return }
            self.isRunQueued = false
            // Core ML model loading is synchronous and can take seconds on
            // device. Perform it only after consent and away from MainActor.
            let modelAvailable = await Task.detached(priority: .userInitiated) {
                FaceEmbedder.shared.isAvailable
            }.value
            guard modelAvailable else {
                self.phase = .unavailable
                return
            }
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(true, forKey: Self.scanEnabledKey)
            self.didLoadSavedPeople = true
            await self.run(using: service)
        }
    }

    // MARK: - Run

    private func run(using service: PhotoLibraryService) async {
        guard !isRunning, !Task.isCancelled else { return }
        isRunning = true
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
            let store = await FaceStore.shared()
            let embedder = FaceEmbedder.shared
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
        let store = await FaceStore.shared()
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
        let store = await FaceStore.shared()
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
        let store = await FaceStore.shared()
        let all = (try? await store.clusters()) ?? []
        clusters = all.filter { !$0.isHidden }
        hiddenClusters = all.filter { $0.isHidden }
        phase = (clusters.isEmpty && hiddenClusters.isEmpty) ? .empty : .results
        await refreshMergeSuggestions()
    }

    /// Centroid pairs near the merge floor, minus hidden people and pairs
    /// the user already declined. The pairwise pass is k² over centroids —
    /// cheap; the centroid read is one pass over the embeddings.
    private func refreshMergeSuggestions() async {
        let store = await FaceStore.shared()
        guard clusters.count > 1,
              let centroids = try? await store.personCentroids()
        else { mergeSuggestions = []; return }
        let dismissed = (try? await store.dismissedMergePairs()) ?? []
        let byID = Dictionary(clusters.map { ($0.personID, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = centroids.filter { byID[$0.key] != nil }
        let threshold = similarityThreshold
        let pairs = await Task.detached(priority: .utility) {
            FaceClusterer.mergeCandidates(centroids: visible, threshold: threshold)
        }.value
        mergeSuggestions = pairs.compactMap { pair in
            guard !dismissed.contains(MergeSuggestion.pairKey(pair.a, pair.b)),
                  let a = byID[pair.a], let b = byID[pair.b] else { return nil }
            return MergeSuggestion(a: a, b: b, similarity: pair.similarity)
        }
    }

    /// "Yes, same person": the smaller cluster joins the larger one (names
    /// and covers carry over where the larger has none).
    func acceptMerge(_ suggestion: MergeSuggestion) {
        let (source, dest) = suggestion.a.photoCount <= suggestion.b.photoCount
            ? (suggestion.a, suggestion.b) : (suggestion.b, suggestion.a)
        mergeSuggestions.removeAll { $0.id == suggestion.id }
        Task { [weak self] in
            guard let self else { return }
            let store = await FaceStore.shared()
            try? await store.merge(source.personID, into: dest.personID)
            await self.loadClusters()
        }
    }

    /// "No": remembered on both people so the pair is never asked again.
    func dismissMerge(_ suggestion: MergeSuggestion) {
        mergeSuggestions.removeAll { $0.id == suggestion.id }
        Task {
            let store = await FaceStore.shared()
            try? await store.dismissMerge(suggestion.a.personID, suggestion.b.personID)
        }
    }

    /// Restores a hidden person back into the main grid.
    func unhide(_ personID: String) {
        Task { [weak self] in
            guard let self else { return }
            let store = await FaceStore.shared()
            try? await store.setHidden(personID: personID, false)
            await self.loadClusters()
        }
    }
}
