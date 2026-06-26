import Photos
import SwiftUI
import UIKit

/// Owns photo-library authorization, asset fetching, and image loading.
/// Batch delete arrives in a later milestone.
@MainActor
final class PhotoLibraryService: ObservableObject {

    /// App-level access state. We only proceed with the swipe flow on full
    /// access — `.limited` can't support bulk cleaning, so it is treated as
    /// blocked alongside `.denied`/`.restricted`.
    enum AccessState: Equatable {
        case undetermined
        case authorized   // full read/write access
        case blocked      // limited, denied, or restricted
    }

    @Published private(set) var accessState: AccessState

    init() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        accessState = Self.map(status)
    }

    /// Prompts for full access if undetermined. On already-resolved statuses
    /// this just refreshes our cached state.
    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        accessState = Self.map(status)
    }

    /// Re-reads the current status — call when returning from Settings.
    func refreshAccessState() {
        accessState = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> AccessState {
        switch status {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .undetermined
        case .limited, .denied, .restricted:
            return .blocked
        @unknown default:
            return .blocked
        }
    }

    // MARK: - Fetch

    /// Fetches every image asset (photos + screenshots) in chronological order,
    /// oldest first. Videos are excluded at the fetch layer so they never enter
    /// the swipe deck. Runs off the main actor since enumerating a large library
    /// can take a noticeable beat.
    nonisolated func fetchAllImages() async -> [PhotoAsset] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]
            options.predicate = NSPredicate(
                format: "mediaType = %d",
                PHAssetMediaType.image.rawValue
            )

            let result = PHAsset.fetchAssets(with: options)
            var assets: [PhotoAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(PhotoAsset(phAsset: asset))
            }
            return assets
        }.value
    }

    // MARK: - Image loading

    /// Streams images for a single asset using `.opportunistic` delivery: a
    /// quick degraded thumbnail arrives almost immediately, followed by the
    /// full-quality image when ready. `isNetworkAccessAllowed` lets iCloud
    /// originals download, but the UI never blocks waiting on them — the
    /// thumbnail keeps the card responsive.
    ///
    /// The underlying PhotoKit request is cancelled when the consuming task is
    /// cancelled (e.g. when the user swipes to the next card).
    nonisolated func imageStream(
        for asset: PhotoAsset,
        targetSize: CGSize
    ) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast

            let requestID = PHImageManager.default().requestImage(
                for: asset.phAsset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let image {
                    continuation.yield(image)
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }
}
