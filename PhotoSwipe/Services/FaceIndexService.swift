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
/// not-yet-scanned photo it detects faces + landmarks (Vision), aligns and
/// embeds each face (`FaceAligner` → `FaceEmbedder`), and upserts the results in
/// batches. Cancelable via `Task.checkCancellation()`; incremental — only new
/// assets are processed, and rows for deleted assets are purged.
final class FaceIndexService {

    /// Working resolution for detection + alignment. Big enough for accurate
    /// landmarks, small enough to keep the scan light. Faces are re-sampled to
    /// 112 from here.
    private let workingImageSize: CGFloat = 1024

    /// Ignore faces smaller than this fraction of the image — too small to embed
    /// reliably, and they only pollute clusters.
    private let minFaceFraction: CGFloat = 0.05

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

        for asset in pending {
            try Task.checkCancellation()
            autoreleasepool {
                faceBatch.append(contentsOf: detectAndEmbed(asset: asset, embedder: embedder))
                scannedBatch.append(asset.id)
            }
            processed += 1
            onProgress(processed, total)

            if scannedBatch.count >= 40 {
                try await store.insert(faces: faceBatch, scannedAssetIDs: scannedBatch, at: Date())
                faceBatch.removeAll(keepingCapacity: true)
                scannedBatch.removeAll(keepingCapacity: true)
            }
        }
        if !scannedBatch.isEmpty {
            try await store.insert(faces: faceBatch, scannedAssetIDs: scannedBatch, at: Date())
        }
        // Keep the index in step with the library — drop stale rows.
        try await store.purge(keepingAssetIDs: Set(assets.map(\.id)))
    }

    // MARK: - Detection + embedding

    private func detectAndEmbed(asset: PhotoAsset, embedder: FaceEmbedder) -> [FaceObservation] {
        guard let cgImage = thumbnail(for: asset.phAsset) else { return [] }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results, !results.isEmpty else { return [] }

        var faces: [FaceObservation] = []
        var index = 0
        for observation in results
        where observation.boundingBox.width >= minFaceFraction
            && observation.boundingBox.height >= minFaceFraction {
            guard let input = FaceAligner.alignedMultiArray(
                    cgImage: cgImage, imageSize: imageSize, observation: observation),
                  let embedding = embedder.embed(input)
            else { continue }

            faces.append(
                FaceObservation(
                    localIdentifier: asset.id,
                    faceIndex: index,
                    embedding: embedding,
                    quality: Float(observation.boundingBox.width * observation.boundingBox.height),
                    boundingBox: observation.boundingBox,
                    personID: nil
                )
            )
            index += 1
        }
        return faces
    }

    /// Synchronous, downscaled image for Vision + alignment. Runs inside the
    /// scan's background task, so blocking here is fine.
    private func thumbnail(for asset: PHAsset) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        var result: CGImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: workingImageSize, height: workingImageSize),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            result = image?.cgImage
        }
        return result
    }
}
