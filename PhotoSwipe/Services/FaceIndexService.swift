import Foundation
import Photos
import UIKit
import Vision

enum FaceScanError: Error {
    /// The AdaFace IR-50 Core ML model isn't bundled — nothing to embed with.
    case modelUnavailable
}

/// Runs the opt-in face scan off the main actor (this type is intentionally not
/// `@MainActor`, so its `async` methods hop to a background executor). For each
/// not-yet-scanned photo it fetches a working-size image, detects faces +
/// landmarks (Vision), aligns and embeds each face (`FaceAligner` →
/// `FaceEmbedder`), and upserts the results in batches. Cancelable via
/// `Task.checkCancellation()`; incremental — only new assets are processed, and
/// rows for deleted assets are purged.
///
/// Up to `maxConcurrency` assets are in-flight at once. Bridging
/// `PHImageManager.requestImage` to an async continuation frees cooperative
/// threads while iCloud photos download, so the next fetch starts immediately
/// instead of waiting for the previous one to finish.
final class FaceIndexService: @unchecked Sendable {

    /// Working resolution for detection + alignment. Big enough for accurate
    /// landmarks, small enough to keep the scan light. Faces are re-sampled to
    /// 112 from here.
    private let workingImageSize: CGFloat = 1024

    /// Ignore faces smaller than this fraction of the image — too small to embed
    /// reliably, and they only pollute clusters.
    private let minFaceFraction: CGFloat = 0.05

    /// How many assets to fetch + detect + embed simultaneously. Bounded to keep
    /// memory pressure reasonable; 4 is enough to saturate a typical iCloud
    /// fetch pipeline without overwhelming the Neural Engine.
    private let maxConcurrency = 4

    /// Detects and embeds faces for every not-yet-scanned photo, reporting
    /// `(processed, total)`. Throws `FaceScanError.modelUnavailable` if the
    /// AdaFace model isn't bundled, or `CancellationError` if cancelled.
    func scan(
        assets: [PhotoAsset],
        store: FaceStore,
        embedder: FaceEmbedder,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        guard embedder.isAvailable else { throw FaceScanError.modelUnavailable }

        let alreadyScanned = try await store.scannedAssetIdentifiers()
        // Faces live in photos; skip videos and already-scanned assets.
        let pending = assets.filter { !$0.isVideo && !alreadyScanned.contains($0.id) }
        let total = pending.count
        onProgress(0, total)

        var faceBatch: [FaceObservation] = []
        var scannedBatch: [String] = []
        var processed = 0

        try await withThrowingTaskGroup(of: (String, [FaceObservation]).self) { group in
            var iter = pending.makeIterator()

            // Enqueues the next pending asset as a child task, if any remain.
            func enqueueNext() {
                guard let asset = iter.next() else { return }
                group.addTask { [self] in
                    let faces = await self.detectAndEmbed(asset: asset, embedder: embedder)
                    return (asset.id, faces)
                }
            }

            // Seed with up to maxConcurrency concurrent tasks.
            for _ in 0..<min(maxConcurrency, total) { enqueueNext() }

            // As each task finishes, batch the result and top up the pool.
            for try await (assetID, faces) in group {
                try Task.checkCancellation()
                faceBatch.append(contentsOf: faces)
                scannedBatch.append(assetID)
                processed += 1
                onProgress(processed, total)

                if scannedBatch.count >= 40 {
                    try await store.insert(faces: faceBatch, scannedAssetIDs: scannedBatch, at: Date())
                    faceBatch.removeAll(keepingCapacity: true)
                    scannedBatch.removeAll(keepingCapacity: true)
                }
                enqueueNext()
            }
        }

        if !scannedBatch.isEmpty {
            try await store.insert(faces: faceBatch, scannedAssetIDs: scannedBatch, at: Date())
        }
        // Keep the index in step with the library — drop stale rows.
        try await store.purge(keepingAssetIDs: Set(assets.map(\.id)))
    }

    // MARK: - Detection + embedding

    private func detectAndEmbed(asset: PhotoAsset, embedder: FaceEmbedder) async -> [FaceObservation] {
        guard let cgImage = await thumbnail(for: asset.phAsset) else { return [] }
        // Vision detect + CoreML embed are synchronous CPU work; wrap in an
        // autoreleasepool so CGImages from PHImageManager don't linger on the
        // cooperative thread between assets.
        return autoreleasepool {
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let landmarkReq = VNDetectFaceLandmarksRequest()
            let qualityReq = VNDetectFaceCaptureQualityRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([landmarkReq, qualityReq]) } catch { return [] }
            guard let results = landmarkReq.results, !results.isEmpty else { return [] }

            // Both requests share the same face detector under the hood.
            // Match each landmark obs to the nearest quality obs by bbox center
            // (robust to any ordering differences) then fall back to bbox area.
            let qualityObs = qualityReq.results ?? []

            var faces: [FaceObservation] = []
            var index = 0
            for observation in results
            where observation.boundingBox.width >= minFaceFraction
                && observation.boundingBox.height >= minFaceFraction {
                guard let input = FaceAligner.alignedMultiArray(
                        cgImage: cgImage, imageSize: imageSize, observation: observation),
                      let embedding = embedder.embed(input)
                else { continue }

                let cx = observation.boundingBox.midX
                let cy = observation.boundingBox.midY
                let matched = qualityObs.min {
                    hypot($0.boundingBox.midX - cx, $0.boundingBox.midY - cy) <
                    hypot($1.boundingBox.midX - cx, $1.boundingBox.midY - cy)
                }
                let quality = matched?.faceCaptureQuality
                    ?? Float(observation.boundingBox.width * observation.boundingBox.height)

                faces.append(FaceObservation(
                    localIdentifier: asset.id,
                    faceIndex: index,
                    embedding: embedding,
                    quality: quality,
                    boundingBox: observation.boundingBox,
                    personID: nil
                ))
                index += 1
            }
            return faces
        }
    }

    /// Async image fetch: `isSynchronous: false` frees the cooperative thread
    /// while PhotoKit downloads the asset from iCloud, enabling concurrent fetches.
    /// With `highQualityFormat`, Photos may call back twice — once with a degraded
    /// placeholder (skipped) and once with the final full-quality image.
    private func thumbnail(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: workingImageSize, height: workingImageSize),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}
