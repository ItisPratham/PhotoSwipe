import Foundation
import Photos

/// Runs the opt-in duplicate scan and the grouping pass, both off the main
/// actor (this type is intentionally *not* `@MainActor`, so its `async` methods
/// hop to a background executor). Both are cancelable via structured
/// concurrency. The scan is incremental: only not-yet-indexed assets are
/// measured, and rows for deleted assets are purged.
///
/// Assets flow through a four-wide `ConcurrentScan`, with cancelable image
/// waits from `PhotoKitImages`. Vision has its own lower concurrency bound, so
/// image delivery can overlap analysis without flooding the Vision framework.
final class LibraryIndexService: @unchecked Sendable {

    /// Downscale target for the feature-print thumbnail. Small on purpose —
    /// similarity doesn't need full resolution, and it keeps the scan light.
    private let thumbnailSize: CGFloat = 256

    /// Four assets can be fetching or waiting for analysis at once. The Vision
    /// processor separately admits only two analyses, which is the safety
    /// boundary that the original v4 pipeline was missing.
    private let maxConcurrency = 4

    private let vision = IndexVisionProcessor.shared

    // MARK: - Scan

    /// Indexes every not-yet-scanned asset: loads a downscaled thumbnail, runs
    /// `VNGenerateImageFeaturePrintRequest`, and upserts the print's raw
    /// vector plus byte size in batches. Reports `(processed, total)` as it
    /// goes, in order. Throws `CancellationError` if the enclosing task is
    /// cancelled. An asset whose image couldn't be loaded is not indexed, so
    /// the next scan retries it.
    func scan(
        assets: [PhotoAsset],
        store: IndexStore,
        includeCategories: Bool = false,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        try await IndexScanCoordinator.shared.withPermit { [self] in
            try await scanWithPermit(
                assets: assets,
                store: store,
                includeCategories: includeCategories,
                onProgress: onProgress
            )
        }
    }

    private func scanWithPermit(
        assets: [PhotoAsset],
        store: IndexStore,
        includeCategories: Bool,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        let alreadyIndexed = try await store.indexedIdentifiers()
        let pending = assets.filter { !alreadyIndexed.contains($0.id) }
        let total = pending.count
        onProgress(0, total)
        PhotoKitDiag.log.info(
            "duplicate scan start: \(total) pending of \(assets.count), categories=\(includeCategories), assetLimit=\(self.maxConcurrency), visionLimit=\(IndexVisionProcessor.maxConcurrentAnalyses)"
        )

        var batch: [IndexedAsset] = []
        var processed = 0

        do {
            try await ConcurrentScan.run(pending, maxConcurrency: maxConcurrency) { [self] asset in
                await self.index(asset, includeCategories: includeCategories)
            } onResult: { _, indexed in
                if let indexed { batch.append(indexed) }
                processed += 1
                onProgress(processed, total)

                if batch.count >= 40 {
                    try await store.upsert(batch, scannedAt: Date())
                    batch.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            PhotoKitDiag.log.info("duplicate scan stopped after \(processed) of \(total): \(String(describing: error), privacy: .public)")
            throw error
        }

        if !batch.isEmpty {
            try await store.upsert(batch, scannedAt: Date())
        }
        // Keep the index in step with the library — drop stale rows.
        try await store.purge(keeping: Set(assets.map(\.id)))
        PhotoKitDiag.log.info("duplicate scan done: \(processed) of \(total)")
    }

    /// One asset: fetch, print, measure. Nil when the image couldn't be
    /// loaded or the print couldn't be produced. With `includeCategories` the
    /// category signals are measured on the same thumbnail, so a library
    /// whose duplicate index is current never needs a second walk.
    private func index(_ asset: PhotoAsset, includeCategories: Bool) async -> IndexedAsset? {
        guard let cgImage = await PhotoKitImages.workingImage(
            for: asset.phAsset, side: thumbnailSize, resizeMode: .fast
        ) else { return nil }
        return try? await vision.indexedAsset(
            localIdentifier: asset.id,
            image: cgImage,
            byteSize: resourceSize(for: asset.phAsset),
            includeCategories: includeCategories
        )
    }

    // MARK: - Categorize

    /// Fills the category columns for indexed assets that haven't been through
    /// this pass yet (rows written before 5.1, or by a scan that ran without
    /// categories). Same contract as `scan`: incremental, progress in order,
    /// cancelable, an asset whose image can't be loaded is retried next time.
    /// Only assets still in `assets` are visited; stale rows are left to the
    /// scan's purge.
    func categorize(
        assets: [PhotoAsset],
        store: IndexStore,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        try await IndexScanCoordinator.shared.withPermit { [self] in
            try await categorizeWithPermit(
                assets: assets,
                store: store,
                onProgress: onProgress
            )
        }
    }

    private func categorizeWithPermit(
        assets: [PhotoAsset],
        store: IndexStore,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        let pendingIDs = Set(try await store.uncategorizedIdentifiers())
        let pending = assets.filter { pendingIDs.contains($0.id) }
        let total = pending.count
        onProgress(0, total)

        var batch: [String: CategoryMeasurement] = [:]
        var processed = 0

        try await ConcurrentScan.run(pending, maxConcurrency: maxConcurrency) { [self] asset in
            await self.measureCategories(for: asset)
        } onResult: { asset, measurement in
            if let measurement { batch[asset.id] = measurement }
            processed += 1
            onProgress(processed, total)
            if batch.count >= 40 {
                try await store.applyCategories(batch, at: Date())
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await store.applyCategories(batch, at: Date())
        }
    }

    private func measureCategories(for asset: PhotoAsset) async -> CategoryMeasurement? {
        guard let cgImage = await PhotoKitImages.workingImage(
            for: asset.phAsset, side: thumbnailSize, resizeMode: .fast
        ) else { return nil }
        return try? await vision.categoryMeasurement(for: cgImage)
    }

    // MARK: - Grouping

    /// Buckets assets into near-duplicate groups. Camera bursts group cheaply by
    /// `burstIdentifier` (no ML). Everything else is matched **library-wide** —
    /// not just within a time window — so identical shots taken far apart (a
    /// re-download, a screenshot saved twice, the same meme) still group. The
    /// pairwise pass runs as blocked BLAS matrix products in
    /// `NearDuplicateMatcher`, so a 50k library takes seconds, not minutes.
    /// Only groups of two or more are returned; each names the member
    /// `KeeperScorer` ranks highest (sharpness, face quality, pixel count,
    /// aesthetics) as the suggested keeper. `faceQuality` is the best face
    /// capture quality per asset from the face index — pass an empty map when
    /// no face scan has run. `distanceThreshold` controls sensitivity —
    /// smaller = only near-identical. Cancelable between blocks.
    func groups(
        assets: [PhotoAsset],
        indexed: [IndexedAsset],
        faceQuality: [String: Float],
        distanceThreshold: Float
    ) async throws -> [DuplicateGroup] {
        let indexedByID = Dictionary(
            indexed.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let vectorByID = indexedByID.mapValues(\.vector)
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

        let hasFaceScan = !faceQuality.isEmpty
        return membersByRoot.values
            .filter { $0.count > 1 }
            .map { memberIDs -> DuplicateGroup in
                let candidates = memberIDs.map { id -> KeeperScorer.Candidate in
                    let asset = assetByID[id]
                    let row = indexedByID[id]
                    return KeeperScorer.Candidate(
                        id: id,
                        created: asset?.creationDate,
                        pixelArea: asset?.pixelArea ?? 0,
                        sharpness: row?.sharpness,
                        faceQuality: hasFaceScan ? (faceQuality[id] ?? 0) : nil,
                        aesthetic: row?.aestheticScore
                    )
                }
                let keeper = KeeperScorer.keeper(among: candidates) ?? memberIDs[0]
                let ordered = memberIDs.sorted {
                    (assetByID[$0]?.creationDate ?? .distantPast)
                        < (assetByID[$1]?.creationDate ?? .distantPast)
                }
                return DuplicateGroup(id: keeper, assetIDs: ordered, suggestedKeeperID: keeper)
            }
            // Biggest groups first, then by keeper id for stable ordering.
            .sorted { ($0.count, $0.id) > ($1.count, $1.id) }
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
