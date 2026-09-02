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
    private var task: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Entry points

    /// On appear: if a scan has already run, refresh incrementally; otherwise
    /// leave the explainer up so the first scan stays opt-in. Surfaces the
    /// model-missing state up front.
    func onAppear(using service: PhotoLibraryService) {
        guard embedder.isAvailable else { phase = .unavailable; return }
        task = Task { [weak self] in
            guard let self else { return }
            if await hasFaces() {
                await run(using: service)
            }
        }
    }

    func onLibraryChange(using service: PhotoLibraryService) {
        guard embedder.isAvailable else { return }
        task = Task { [weak self] in
            guard let self, await hasFaces() else { return }
            await run(using: service)
        }
    }

    /// The explainer's "Scan library" button — the opt-in first pass.
    func startFirstScan(using service: PhotoLibraryService) {
        guard embedder.isAvailable else { phase = .unavailable; return }
        task = Task { [weak self] in await self?.run(using: service) }
    }

    func reload(using service: PhotoLibraryService) {
        task = Task { [weak self] in await self?.run(using: service) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        isRefreshing = false
        phase = clusters.isEmpty ? .idle : .results
    }

    // MARK: - Run

    private func run(using service: PhotoLibraryService) async {
        guard !isRunning else { return }
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
            try await indexService.scan(assets: assets, store: store, embedder: embedder) { done, tot in
                Task { @MainActor in
                    self.processed = done
                    self.total = tot
                }
            }
            if showProgress { phase = .clustering }
            await reclusterAll()
        } catch is CancellationError {
            phase = clusters.isEmpty ? .idle : .results
        } catch FaceScanError.modelUnavailable {
            phase = .unavailable
        } catch {
            phase = clusters.isEmpty ? .idle : .results
        }
    }

    /// Re-clusters every stored face from scratch at the current threshold (off
    /// the main actor), then publishes the result. Deterministic and
    /// order-independent for the configured threshold.
    private func reclusterAll() async {
        guard let faces = try? await store.allFaces() else {
            phase = clusters.isEmpty ? .empty : .results
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
        let computed = (try? await store.clusters().filter { !$0.isHidden }) ?? []
        clusters = computed
        phase = computed.isEmpty ? .empty : .results
    }

    private func hasFaces() async -> Bool {
        ((try? await store.faceCount()) ?? 0) > 0
    }
}
