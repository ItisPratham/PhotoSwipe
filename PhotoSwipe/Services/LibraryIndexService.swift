import Foundation
import Photos
import UIKit
import Vision

/// Runs the opt-in duplicate scan and the grouping pass, both off the main
/// actor (this type is intentionally *not* `@MainActor`, so its `async` methods
/// hop to a background executor). The scan is cancelable via structured
/// concurrency — `Task.checkCancellation()` between assets — and incremental:
/// only not-yet-indexed assets are measured, and rows for deleted assets are
/// purged at the end.
final class LibraryIndexService {

    /// Downscale target for the feature-print thumbnail. Small on purpose —
    /// similarity doesn't need full resolution, and it keeps the scan light.
    private let thumbnailSize: CGFloat = 256

    /// Grouping only compares shots taken close together (seconds) and within a
    /// small neighbour window, so the pass stays near-linear on large libraries.
    private let timeWindow: TimeInterval = 15
    private let neighbourWindow = 12

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
    /// `burstIdentifier` (no ML); everything else is compared by feature-print
    /// distance within a sliding time/neighbour window and unioned under the
    /// threshold. Only groups of two or more are returned; each names its
    /// highest-quality member as the suggested keeper. `distanceThreshold`
    /// controls sensitivity — smaller = only near-identical.
    func groups(
        assets: [PhotoAsset],
        indexed: [IndexedAsset],
        distanceThreshold: Float
    ) -> [DuplicateGroup] {
        let indexedIDs = Set(indexed.map(\.localIdentifier))
        // Only consider assets we actually have a print for, oldest-first.
        let candidates = assets
            .filter { indexedIDs.contains($0.id) }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

        var uf = UnionFind(ids: candidates.map(\.id))

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

        // 2) Near-duplicates — compare feature prints within a sliding window.
        let printByID = Dictionary(
            indexed.map { ($0.localIdentifier, $0.featurePrint) },
            uniquingKeysWith: { first, _ in first }
        )
        var observationCache: [String: VNFeaturePrintObservation] = [:]
        func observation(for id: String) -> VNFeaturePrintObservation? {
            if let cached = observationCache[id] { return cached }
            guard let data = printByID[id],
                  let obs = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: VNFeaturePrintObservation.self, from: data)
            else { return nil }
            observationCache[id] = obs
            return obs
        }

        for i in candidates.indices {
            let a = candidates[i]
            guard let aDate = a.creationDate, let aObs = observation(for: a.id) else { continue }
            var j = i + 1
            var compared = 0
            while j < candidates.count, compared < neighbourWindow {
                let b = candidates[j]
                let bDate = b.creationDate ?? .distantFuture
                if bDate.timeIntervalSince(aDate) > timeWindow { break }
                if uf.find(a.id) != uf.find(b.id), let bObs = observation(for: b.id) {
                    var distance = Float.greatestFiniteMagnitude
                    try? aObs.computeDistance(&distance, to: bObs)
                    if distance < distanceThreshold {
                        uf.union(a.id, b.id)
                    }
                }
                compared += 1
                j += 1
            }
        }

        // 3) Materialise groups of 2+.
        let assetByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var membersByRoot: [String: [String]] = [:]
        for asset in candidates {
            membersByRoot[uf.find(asset.id), default: []].append(asset.id)
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
