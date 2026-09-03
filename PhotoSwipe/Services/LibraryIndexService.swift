import Foundation
import Photos
import UIKit
import Vision

/// Runs the opt-in duplicate scan and the grouping pass, both off the main
/// actor (this type is intentionally *not* `@MainActor`, so its `async` methods
/// hop to a background executor). Both are cancelable via structured
/// concurrency. The scan is incremental: only not-yet-indexed assets are
/// measured, and rows for deleted assets are purged.
///
/// Up to `maxConcurrency` assets are in flight at once through
/// `ConcurrentScan`, with cancelable image fetches from `PhotoKitImages`, so
/// iCloud downloads overlap instead of serialising the whole scan.
final class LibraryIndexService: @unchecked Sendable {

    /// Downscale target for the feature-print thumbnail. Small on purpose —
    /// similarity doesn't need full resolution, and it keeps the scan light.
    private let thumbnailSize: CGFloat = 256

    /// How many assets to fetch + print simultaneously. Same bound as the
    /// face scan: enough to keep an iCloud pipeline busy without piling up
    /// decoded images.
    private let maxConcurrency = 4

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
        let alreadyIndexed = try await store.indexedIdentifiers()
        let pending = assets.filter { !alreadyIndexed.contains($0.id) }
        let total = pending.count
        onProgress(0, total)

        var batch: [IndexedAsset] = []
        var processed = 0

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

        if !batch.isEmpty {
            try await store.upsert(batch, scannedAt: Date())
        }
        // Keep the index in step with the library — drop stale rows.
        try await store.purge(keeping: Set(assets.map(\.id)))
    }

    /// One asset: fetch, print, measure. Nil when the image couldn't be
    /// loaded or the print couldn't be produced. With `includeCategories` the
    /// category signals are measured on the same thumbnail, so a library
    /// whose duplicate index is current never needs a second walk.
    private func index(_ asset: PhotoAsset, includeCategories: Bool) async -> IndexedAsset? {
        guard let cgImage = await PhotoKitImages.workingImage(
            for: asset.phAsset, side: thumbnailSize, resizeMode: .fast
        ) else { return nil }
        // Vision is synchronous CPU work; the pool keeps the CGImage from
        // lingering on the cooperative thread between assets.
        return autoreleasepool {
            guard let vector = featurePrintVector(from: cgImage) else { return nil }
            // Quality signals for the keeper score ride on the same thumbnail.
            let aesthetics = ImageQuality.aesthetics(of: cgImage)
            let sharpness = ImageQuality.sharpness(of: cgImage)
            var indexed = IndexedAsset(localIdentifier: asset.id,
                                       vector: vector,
                                       byteSize: resourceSize(for: asset.phAsset),
                                       sharpness: sharpness,
                                       aestheticScore: aesthetics?.score)
            if includeCategories {
                indexed.categories = measureCategories(from: cgImage,
                                                       sharpness: sharpness,
                                                       aesthetics: aesthetics)
            }
            return indexed
        }
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

    /// The library's "blurry" cut: the 5th percentile of sharpness over the
    /// categorized photos. Nil until enough rows carry a sharpness value.
    static func blurThreshold(from signals: [CategorySignals]) -> Float? {
        let values = signals.compactMap(\.sharpness).sorted()
        guard values.count >= 40 else { return nil }
        return values[values.count / 20]
    }

    private func measureCategories(for asset: PhotoAsset) async -> CategoryMeasurement? {
        guard let cgImage = await PhotoKitImages.workingImage(
            for: asset.phAsset, side: thumbnailSize, resizeMode: .fast
        ) else { return nil }
        return autoreleasepool {
            measureCategories(from: cgImage,
                              sharpness: ImageQuality.sharpness(of: cgImage),
                              aesthetics: ImageQuality.aesthetics(of: cgImage))
        }
    }

    /// Scene labels, cat/dog presence, and text coverage from one handler
    /// pass over the thumbnail, plus the quality signals already measured.
    private func measureCategories(from cgImage: CGImage,
                                   sharpness: Float?,
                                   aesthetics: (score: Float, isUtility: Bool)?) -> CategoryMeasurement {
        let classify = VNClassifyImageRequest()
        let animals = VNRecognizeAnimalsRequest()
        let text = VNDetectTextRectanglesRequest()
        text.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([classify, animals, text])

        // Keep labels Vision is confident about: either they pass the
        // precision gate at a small recall, or they are simply strong.
        let labels = (classify.results ?? [])
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) || $0.confidence >= 0.5 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(8)
            .map { ($0.identifier, $0.confidence) }

        // A clear cat/dog only; the detector fires weakly on toys and fur.
        let hasAnimal = (animals.results ?? []).contains { observation in
            observation.labels.contains { $0.confidence >= 0.75 }
        }

        // Ignore speck-sized boxes, which come from texture rather than text.
        let coverage = (text.results ?? []).reduce(Float(0)) { sum, observation in
            let area = Float(observation.boundingBox.width * observation.boundingBox.height)
            return area >= 0.002 ? sum + area : sum
        }

        return CategoryMeasurement(labels: CategorySignals.encode(labels: Array(labels)),
                                   textCoverage: min(1, coverage),
                                   isUtility: aesthetics?.isUtility,
                                   hasAnimal: hasAnimal,
                                   sharpness: sharpness,
                                   aestheticScore: aesthetics?.score)
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

    // MARK: - Vision / metadata helpers

    /// The image's feature print as a raw vector, or nil when Vision fails or
    /// the print has an element type we can't decode.
    private func featurePrintVector(from cgImage: CGImage) -> [Float]? {
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
