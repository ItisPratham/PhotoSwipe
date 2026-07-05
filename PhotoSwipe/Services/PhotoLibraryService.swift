import Photos
import SwiftUI
import UIKit

/// Owns photo-library authorization, asset fetching, image loading, and the
/// batched-delete bridge to PhotoKit.
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

    /// Fetches image assets (photos + screenshots) in chronological order,
    /// oldest first, honouring the supplied `DeckSource` — scope (all photos
    /// or a specific album) and an optional `startFrom` cutoff. Videos are
    /// excluded at the predicate layer so they never enter the deck. Runs off
    /// the main actor because enumerating a large library can take a beat.
    nonisolated func fetchImages(source: DeckSource) async -> [PhotoAsset] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]

            var predicates: [NSPredicate] = [
                NSPredicate(format: "mediaType = %d",
                            PHAssetMediaType.image.rawValue)
            ]
            if let startFrom = source.startFrom {
                predicates.append(NSPredicate(format: "creationDate >= %@",
                                              startFrom as NSDate))
            }
            options.predicate = predicates.count == 1
                ? predicates[0]
                : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let result: PHFetchResult<PHAsset>
            switch source.scope {
            case .allPhotos:
                result = PHAsset.fetchAssets(with: options)
            case .album(let collection):
                result = PHAsset.fetchAssets(in: collection, options: options)
            }

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

    // MARK: - Batch operations

    /// Resolves a set of local identifiers to `PhotoAsset`s, sorted by
    /// creation date (oldest first). IDs that no longer exist on device are
    /// silently dropped.
    nonisolated func fetchAssets(withIDs ids: Set<String>) async -> [PhotoAsset] {
        guard !ids.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: Array(ids),
                options: options
            )
            var assets: [PhotoAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(PhotoAsset(phAsset: asset))
            }
            return assets
        }.value
    }

    /// Sums on-device file sizes for the given assets. Uses
    /// PHAssetResource.fileSize via KVC — the only practical way to read size
    /// metadata without downloading the asset data itself. Some assets carry
    /// multiple resources (RAW + JPEG, edits); they're all counted because
    /// they all reclaim space on delete.
    nonisolated func totalSize(forIDs ids: Set<String>) async -> Int64 {
        guard !ids.isEmpty else { return 0 }
        return await Task.detached(priority: .utility) {
            let fetch = PHAsset.fetchAssets(
                withLocalIdentifiers: Array(ids),
                options: nil
            )
            var total: Int64 = 0
            fetch.enumerateObjects { asset, _, _ in
                for resource in PHAssetResource.assetResources(for: asset) {
                    if let size = resource.value(forKey: "fileSize") as? Int64 {
                        total += size
                    } else if let size = resource.value(forKey: "fileSize") as? NSNumber {
                        total += size.int64Value
                    }
                }
            }
            return total
        }.value
    }

    /// Deletes the supplied assets via a single batched PhotoKit request. iOS
    /// always shows a system confirmation dialog — there's no silent path.
    /// Returns `true` only when the user confirmed and the delete succeeded.
    nonisolated func deleteAssets(ids: Set<String>) async -> Bool {
        guard !ids.isEmpty else { return false }
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(ids),
            options: nil
        )
        guard fetchResult.count > 0 else { return false }

        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
