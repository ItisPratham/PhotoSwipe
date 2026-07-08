import Accelerate
import Foundation
import Photos
import UIKit
import Vision

/// Runs the opt-in duplicate scan and the grouping pass, both off the main
/// actor (this type is intentionally *not* `@MainActor`, so its `async` methods
/// hop to a background executor). Both are cancelable via structured
/// concurrency (`Task.checkCancellation()`). The scan is incremental: only
/// not-yet-indexed assets are measured, and rows for deleted assets are purged.
final class LibraryIndexService {

    /// Downscale target for the feature-print thumbnail. Small on purpose —
    /// similarity doesn't need full resolution, and it keeps the scan light.
    private let thumbnailSize: CGFloat = 256

    // MARK: - Scan

    /// Indexes every not-yet-scanned asset: loads a downscaled thumbnail, runs
    /// `VNGenerateImageFeaturePrintRequest`, and upserts the archived print plus
    /// byte size in batches. Reports `(processed, total)` as it goes. Throws
    /// `CancellationError` if the enclosing task is cancelled.
    func scan(
        assets: [PhotoAsset],
        store: IndexStore,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        let alreadyIndexed = try await store.indexedIdentifiers()
        let pending = assets.filter { !alreadyIndexed.contains($0.id) }
        let total = pending.count
        onProgress(0, total)

        var batch: [IndexedAsset] = []
        var processed = 0

        for asset in pending {
            try Task.checkCancellation()

            autoreleasepool {
                if let print = featurePrintData(for: asset.phAsset) {
                    batch.append(
                        IndexedAsset(localIdentifier: asset.id,
                                     featurePrint: print,
                                     byteSize: resourceSize(for: asset.phAsset))
                    )
                }
            }

            processed += 1
            onProgress(processed, total)

            if batch.count >= 40 {
                try await store.upsert(batch, scannedAt: Date())
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            try await store.upsert(batch, scannedAt: Date())
        }
        // Keep the index in step with the library — drop stale rows.
        try await store.purge(keeping: Set(assets.map(\.id)))
    }

    // MARK: - Grouping

    /// Buckets assets into near-duplicate groups. Camera bursts group cheaply by
    /// `burstIdentifier` (no ML). Everything else is matched **library-wide** —
    /// not just within a time window — so identical shots taken far apart (a
    /// re-download, a screenshot saved twice, the same meme) still group. Each
    /// feature print is decoded to its raw float vector once and compared with a
    /// SIMD L2 distance (vDSP), so the full pairwise pass stays fast. Only
    /// groups of two or more are returned; each names its highest-quality member
    /// as the suggested keeper. `distanceThreshold` controls sensitivity —
    /// smaller = only near-identical. Cancelable between rows.
    func groups(
        assets: [PhotoAsset],
        indexed: [IndexedAsset],
        distanceThreshold: Float
    ) async throws -> [DuplicateGroup] {
        let indexedIDs = Set(indexed.map(\.localIdentifier))
        // Only consider assets we actually have a print for, oldest-first.
        let candidates = assets
            .filter { indexedIDs.contains($0.id) }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        let ids = candidates.map(\.id)

        var uf = UnionFind(ids: ids)

        // 1) Bursts — union everything sharing a burstIdentifier.
        var burstBuckets: [String: [String]] = [:]
        for asset in candidates {
            if let burst = asset.burstIdentifier {
                burstBuckets[burst, default: []].append(asset.id)
            }
        }
        for members in burstBuckets.values where members.count > 1 {
            for member in members.dropFirst() {
                uf.union(members[0], member)
            }
        }

        // 2) Near-duplicates — decode every print to a float vector once, then
        //    compare all pairs with a SIMD squared-L2 distance. Comparing the
        //    squared distance to the squared threshold avoids a sqrt per pair.
        let printByID = Dictionary(
            indexed.map { ($0.localIdentifier, $0.featurePrint) },
            uniquingKeysWith: { first, _ in first }
        )
        let vectors: [[Float]] = ids.map { Self.vector(from: printByID[$0]) }
        let threshold2 = distanceThreshold * distanceThreshold
        let n = candidates.count

        for i in 0..<n {
            if i % 64 == 0 { try Task.checkCancellation() }
            let vi = vectors[i]
            if vi.isEmpty { continue }
            let count = vDSP_Length(vi.count)
            let rootI = uf.find(ids[i])
            for j in (i + 1)..<n {
                let vj = vectors[j]
                if vj.count != vi.count { continue }
                // Skip the distance math if they're already in the same set.
                if uf.find(ids[j]) == rootI { continue }
                var d2: Float = 0
                vDSP_distancesq(vi, 1, vj, 1, &d2, count)
                if d2 < threshold2 { uf.union(ids[i], ids[j]) }
            }
        }

        // 3) Materialise groups of 2+.
        let assetByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var membersByRoot: [String: [String]] = [:]
        for id in ids {
            membersByRoot[uf.find(id), default: []].append(id)
        }

        return membersByRoot.values
            .filter { $0.count > 1 }
            .map { memberIDs -> DuplicateGroup in
                let keeper = memberIDs.max { lhs, rhs in
                    quality(assetByID[lhs]) < quality(assetByID[rhs])
                } ?? memberIDs[0]
                let ordered = memberIDs.sorted {
                    (assetByID[$0]?.creationDate ?? .distantPast)
                        < (assetByID[$1]?.creationDate ?? .distantPast)
                }
                return DuplicateGroup(id: keeper, assetIDs: ordered, suggestedKeeperID: keeper)
            }
            // Biggest groups first, then by keeper id for stable ordering.
            .sorted { ($0.count, $0.id) > ($1.count, $1.id) }
    }

    /// Decodes an archived `VNFeaturePrintObservation` to its raw float vector.
    /// Returns an empty array if the data is missing or an unexpected element
    /// type (grouping then skips it).
    private static func vector(from data: Data?) -> [Float] {
        guard let data,
              let obs = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: data)
        else { return [] }
        let count = obs.elementCount
        switch obs.elementType {
        case .float:
            return obs.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        case .double:
            return obs.data.withUnsafeBytes { raw in
                let doubles = raw.bindMemory(to: Double.self)
                return (0..<count).map { Float(doubles[$0]) }
            }
        @unknown default:
            return []
        }
    }

    /// Quality proxy for keeper selection: more pixels wins.
    private func quality(_ asset: PhotoAsset?) -> Int {
        asset?.pixelArea ?? 0
    }

    // MARK: - Vision / metadata helpers

    private func featurePrintData(for asset: PHAsset) -> Data? {
        guard let cgImage = thumbnail(for: asset) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: observation, requiringSecureCoding: true
        )
    }

    /// Synchronous, downscaled thumbnail for Vision. Runs inside the scan's
    /// background task, so blocking here is fine.
    private func thumbnail(for asset: PHAsset) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        var result: CGImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: thumbnailSize, height: thumbnailSize),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            result = image?.cgImage
        }
        return result
    }

    private func resourceSize(for asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for resource in PHAssetResource.assetResources(for: asset) {
            if let size = resource.value(forKey: "fileSize") as? Int64 {
                total += size
            } else if let size = resource.value(forKey: "fileSize") as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

/// Minimal union-find over string ids for grouping.
private struct UnionFind {
    private var parent: [String: String]

    init(ids: [String]) {
        parent = Dictionary(ids.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func find(_ id: String) -> String {
        var root = id
        while let p = parent[root], p != root { root = p }
        // Path-compress.
        var cursor = id
        while let p = parent[cursor], p != root {
            parent[cursor] = root
            cursor = p
        }
        return root
    }

    mutating func union(_ a: String, _ b: String) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}
