import Accelerate
import Foundation

/// "More like this": nearest neighbours of a photo in the duplicate index's
/// feature-print space. Reuses the vectors the Duplicates scan already stores,
/// so it costs nothing extra to build and is available for every photo that
/// has been through that scan.
///
/// The index snapshot is loaded once per library version and kept while this
/// object lives (the deck's view model owns one), so repeated taps pay only
/// the distance pass — one `vDSP_distancesq` per indexed photo.
@MainActor
final class SimilarPhotosFinder {
    /// How many neighbours a "More like this" deck holds at most.
    static let neighbourLimit = 30
    /// Squared-L2 ceiling in feature-print space. Looser than the duplicate
    /// default (0.30): these should be *similar* shots, not copies.
    static let maxDistance: Float = 0.8

    private let store = IndexStore(modelContainer: IndexContainer.shared)
    private var indexedIDs: Set<String> = []
    private var indexed: [IndexedAsset] = []
    private var loadedVersion: Int?
    private var loadedCount = 0

    /// Whether `id` has a feature print, i.e. whether "More like this" can run
    /// for it. Reads only the identifier column, once per library version.
    func isIndexed(_ id: String, libraryVersion: Int) async -> Bool {
        if loadedVersion != libraryVersion || indexedIDs.isEmpty {
            indexedIDs = (try? await store.indexedIdentifiers()) ?? []
            if loadedVersion != libraryVersion {
                indexed = []
                loadedVersion = libraryVersion
            }
        }
        return indexedIDs.contains(id)
    }

    /// Neighbour ids of `seedID`, nearest first, excluding the seed. Nil when
    /// the seed has no print. Empty when nothing is within `maxDistance`.
    func neighbours(of seedID: String, libraryVersion: Int) async -> [String]? {
        guard await isIndexed(seedID, libraryVersion: libraryVersion) else { return nil }
        if indexed.isEmpty || !indexed.contains(where: { $0.localIdentifier == seedID }) {
            indexed = (try? await store.allIndexed()) ?? []
        }
        let snapshot = indexed
        let limit = Self.neighbourLimit
        let maxDistance = Self.maxDistance
        return await Task.detached(priority: .userInitiated) {
            Self.rank(seedID: seedID, in: snapshot, limit: limit, maxDistance: maxDistance)
        }.value
    }

    /// Squared-L2 distance from the seed to every same-dimension vector,
    /// then the closest `limit` under the ceiling.
    nonisolated static func rank(seedID: String, in indexed: [IndexedAsset],
                                 limit: Int, maxDistance: Float) -> [String]? {
        guard let seed = indexed.first(where: { $0.localIdentifier == seedID })?.vector,
              !seed.isEmpty else { return nil }
        let threshold2 = maxDistance * maxDistance
        let count = vDSP_Length(seed.count)
        var hits: [(id: String, distance2: Float)] = []
        for item in indexed where item.vector.count == seed.count && item.localIdentifier != seedID {
            var d2: Float = 0
            vDSP_distancesq(seed, 1, item.vector, 1, &d2, count)
            if d2 < threshold2 { hits.append((item.localIdentifier, d2)) }
        }
        hits.sort { $0.distance2 < $1.distance2 }
        return hits.prefix(limit).map(\.id)
    }
}
