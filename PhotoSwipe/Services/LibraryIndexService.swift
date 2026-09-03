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
    /// `VNGenerateImageFeaturePrintRequest`, and upserts the print's raw
    /// vector plus byte size in batches. Reports `(processed, total)` as it goes. Throws
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
                if let vector = featurePrintVector(for: asset.phAsset) {
                    batch.append(
                        IndexedAsset(localIdentifier: asset.id,
                                     vector: vector,
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
    /// re-download, a screenshot saved twice, the same meme) still group. The
    /// pairwise pass runs as blocked BLAS matrix products in
    /// `NearDuplicateMatcher`, so a 50k library takes seconds, not minutes.
    /// Only groups of two or more are returned; each names its
    /// highest-quality member as the suggested keeper. `distanceThreshold`
    /// controls sensitivity — smaller = only near-identical. Cancelable
    /// between blocks.
    func groups(
        assets: [PhotoAsset],
        indexed: [IndexedAsset],
        distanceThreshold: Float
    ) async throws -> [DuplicateGroup] {
        let vectorByID = Dictionary(
            indexed.map { ($0.localIdentifier, $0.vector) },
            uniquingKeysWith: { first, _ in first }
        )
        // Only consider assets we actually have a print for, oldest-first.
        let candidates = assets
            .filter { vectorByID[$0.id] != nil }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        let ids = candidates.map(\.id)

        // 1) Bursts — everything sharing a burstIdentifier is joined up front.
        var burstBuckets: [String: [Int]] = [:]
        for (index, asset) in candidates.enumerated() {
            if let burst = asset.burstIdentifier {
                burstBuckets[burst, default: []].append(index)
            }
        }
        var seeds: [(Int, Int)] = []
        for members in burstBuckets.values where members.count > 1 {
            for member in members.dropFirst() {
                seeds.append((members[0], member))
            }
        }

        // 2) Near-duplicates — the blocked pairwise pass.
        let vectors = ids.map { vectorByID[$0] ?? [] }
        var uf = try NearDuplicateMatcher.partition(
            vectors: vectors,
            distanceThreshold: distanceThreshold,
            seedUnions: seeds
        )

        // 3) Materialise groups of 2+.
        let assetByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var membersByRoot: [Int: [String]] = [:]
        for (index, id) in ids.enumerated() {
            membersByRoot[uf.find(index), default: []].append(id)
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

    /// Quality proxy for keeper selection: more pixels wins.
    private func quality(_ asset: PhotoAsset?) -> Int {
        asset?.pixelArea ?? 0
    }

    // MARK: - Vision / metadata helpers

    /// The asset's feature print as a raw vector, or nil when the image can't
    /// be loaded, Vision fails, or the print has an element type we can't
    /// decode (so the asset isn't marked indexed and gets retried).
    private func featurePrintVector(for asset: PHAsset) -> [Float]? {
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
        let vector = FeaturePrintCodec.vector(from: observation)
        return vector.isEmpty ? nil : vector
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
