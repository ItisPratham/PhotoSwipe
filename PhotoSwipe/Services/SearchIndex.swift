import Accelerate
import Foundation
import UIKit

/// Memory-resident cosine-search matrix. It reads only the two search columns
/// from SwiftData and rebuilds when either the library or in-process search
/// revision changes.
actor SearchIndex {
    static let shared: SearchIndex = {
        SearchIndexMemoryPressure.start()
        return SearchIndex()
    }()
    /// Cosine floor for a result, taken from the installed model: the two
    /// families score on different scales, and a CLIP-calibrated floor filters
    /// out every SigLIP result. The former two-tier "Show more" was dropped;
    /// everything above the floor shows at once.
    static var defaultCutoff: Float { SearchEmbedder.spec.cutoff }
    static let resultLimit = 200

    private var identifiers: [String] = []
    private var matrix: [Float] = []
    private var loadedLibraryVersion: Int?
    private var loadedRevision: Int?
    func search(
        query: [Float],
        store: IndexStore,
        libraryVersion: Int,
        eligibleIdentifiers: Set<String>? = nil,
        cutoff: Float = SearchIndex.defaultCutoff
    ) async throws -> [SearchResult] {
        try Task.checkCancellation()
        try await loadIfNeeded(store: store, libraryVersion: libraryVersion)
        guard !identifiers.isEmpty, let query = Self.normalized(query) else { return [] }

        let scores = Self.scores(query: query, matrix: matrix, rows: identifiers.count)
        try Task.checkCancellation()

        return Self.rank(
            identifiers: identifiers,
            scores: scores,
            eligibleIdentifiers: eligibleIdentifiers,
            cutoff: cutoff
        )
    }

    /// One matrix-vector product against the whole library. Separate so the
    /// performance tests can time the shipping path rather than a copy of it.
    static func scores(query: [Float], matrix: [Float], rows: Int,
                       dimension: Int = SearchEmbedder.dimension) -> [Float] {
        var scores = [Float](repeating: 0, count: rows)
        cblas_sgemv(
            CblasRowMajor, CblasNoTrans,
            Int32(rows), Int32(dimension),
            1, matrix, Int32(dimension), query, 1, 0, &scores, 1
        )
        return scores
    }

    static func rank(
        identifiers: [String],
        scores: [Float],
        eligibleIdentifiers: Set<String>? = nil,
        cutoff: Float
    ) -> [SearchResult] {
        let restrictToEligible = eligibleIdentifiers != nil
        return zip(identifiers, scores)
            .filter { id, score in
                score.isFinite && score >= cutoff && (!restrictToEligible || eligibleIdentifiers!.contains(id))
            }
            .sorted {
                $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
            }
            .prefix(Self.resultLimit)
            .map { SearchResult(assetID: $0.0, score: $0.1) }
    }

    func releaseMemory() {
        identifiers.removeAll(keepingCapacity: false)
        matrix.removeAll(keepingCapacity: false)
        loadedLibraryVersion = nil
        loadedRevision = nil
    }

    private func loadIfNeeded(store: IndexStore, libraryVersion: Int) async throws {
        let revision = SearchIndexRevision.current
        guard loadedLibraryVersion != libraryVersion || loadedRevision != revision else { return }
        let snapshots = try await store.searchEmbeddingSnapshots()
        var nextIDs: [String] = []
        var nextMatrix: [Float] = []
        nextIDs.reserveCapacity(snapshots.count)
        nextMatrix.reserveCapacity(snapshots.count * SearchEmbedder.dimension)
        for snapshot in snapshots {
            try Task.checkCancellation()
            guard let vector = SearchEmbedder.decodeFloat16(snapshot.embedding),
                  let normalized = Self.normalized(vector) else { continue }
            nextIDs.append(snapshot.localIdentifier)
            nextMatrix.append(contentsOf: normalized)
        }
        identifiers = nextIDs
        matrix = nextMatrix
        loadedLibraryVersion = libraryVersion
        loadedRevision = revision
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == SearchEmbedder.dimension, vector.allSatisfy(\.isFinite) else { return nil }
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
        let norm = sqrt(sum)
        guard norm.isFinite, norm > 0 else { return nil }
        var divisor = norm
        var output = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &output, 1, vDSP_Length(vector.count))
        return output
    }
}

private enum SearchIndexMemoryPressure {
    private static let observer = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: nil
    ) { _ in
        Task { await SearchIndex.shared.releaseMemory() }
    }

    static func start() { _ = observer }
}
