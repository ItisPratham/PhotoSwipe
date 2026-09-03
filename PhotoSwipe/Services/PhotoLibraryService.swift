import AVFoundation
import Photos
import SwiftUI
import UIKit

/// One caching manager for every image request in the app. The deck's
/// prefetch calls warm it, and `imageStream` reads through it, so a card that
/// was prefetched is served from memory. Thread-safe by contract, hence a
/// file-level constant rather than a main-actor property.
private let cachingImageManager = PHCachingImageManager()

/// Owns photo-library authorization, asset fetching, image loading, and the
/// batched-delete bridge to PhotoKit. Also observes the library so features
/// (e.g. Duplicates) can auto-refresh when photos are added, deleted, edited,
/// or captured.
@MainActor
final class PhotoLibraryService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {

    /// App-level access state. We only proceed with the swipe flow on full
    /// access — `.limited` can't support bulk cleaning, so it is treated as
    /// blocked alongside `.denied`/`.restricted`.
    enum AccessState: Equatable {
        case undetermined
        case authorized   // full read/write access
        case blocked      // limited, denied, or restricted
    }

    @Published private(set) var accessState: AccessState
    /// Bumped on every library change. Observers watch this to know the library
    /// is out of date without diffing PhotoKit themselves.
    @Published private(set) var libraryVersion = 0

    override init() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        accessState = Self.map(status)
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    /// PHPhotoLibraryChangeObserver — fires on an arbitrary queue, so hop to the
    /// main actor to bump the version.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.libraryVersion &+= 1
        }
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

    /// Fetches assets in chronological order, oldest first, honouring the
    /// supplied `DeckSource` — scope (all photos or a specific album), media
    /// kind (photos / videos / both), and an optional `startFrom` cutoff. The
    /// media filter is applied at the predicate layer, so the default `.photos`
    /// source never surfaces a video. Runs off the main actor because
    /// enumerating a large library can take a beat.
    nonisolated func fetchImages(source: DeckSource) async -> [PhotoAsset] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: true)
            ]

            var predicates: [NSPredicate] = []
            switch source.media {
            case .photos:
                predicates.append(NSPredicate(format: "mediaType = %d",
                                              PHAssetMediaType.image.rawValue))
            case .videos:
                predicates.append(NSPredicate(format: "mediaType = %d",
                                              PHAssetMediaType.video.rawValue))
            case .all:
                break // no media-type restriction
            }
            if let startFrom = source.startFrom {
                predicates.append(NSPredicate(format: "creationDate >= %@",
                                              startFrom as NSDate))
            }
            options.predicate = predicates.isEmpty
                ? nil
                : predicates.count == 1
                    ? predicates[0]
                    : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let result: PHFetchResult<PHAsset>
            switch source.scope {
            case .allPhotos:
                result = PHAsset.fetchAssets(with: options)
            case .album(let collection):
                result = PHAsset.fetchAssets(in: collection, options: options)
            case .duplicateGroup(let ids):
                // A specific, already-chosen set — media/date filters don't
                // apply; just resolve the identifiers (still oldest-first).
                options.predicate = nil
                result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
            case .person(let ids, let preservesOrder):
                // Media/date filters don't apply to an explicit id set. When
                // the caller's order is authoritative we re-order after the
                // fetch; otherwise keep PhotoKit's oldest-first sort.
                options.predicate = nil
                if preservesOrder { options.sortDescriptors = nil }
                result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
            }

            var assets: [PhotoAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(PhotoAsset(phAsset: asset))
            }

            // PHAsset.fetchAssets(withLocalIdentifiers:) ignores the input order
            // and sorts by options.sortDescriptors. For person scope we re-order
            // the result to match the caller's sequence exactly (e.g. newest→oldest
            // per day, or from a tapped photo backward through the rest of that day).
            if case .person(let ids, true) = source.scope {
                let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
                assets = ids.compactMap { byID[$0] }
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
    ///
    /// `contentMode` defaults to aspect-fill, which lets PhotoKit hand back a
    /// crop for thumbnails. Pass `.aspectFit` when the caller does its own
    /// geometry on the result (the face-crop cover) and needs the full frame.
    nonisolated func imageStream(
        for asset: PhotoAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let requestID = cachingImageManager.requestImage(
                for: asset.phAsset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: Self.streamOptions()
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
                cachingImageManager.cancelImageRequest(requestID)
            }
        }
    }

    /// Options shared by `imageStream` and the prefetch calls. They must match
    /// exactly: the caching manager keys prepared images on asset, size,
    /// content mode, and options, so a mismatch turns a prefetch into wasted
    /// work and a second fetch.
    nonisolated private static func streamOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return options
    }

    // MARK: - Prefetch

    /// Warms the cache for upcoming deck cards at the exact size the card will
    /// request, so advancing the deck lands on a ready image instead of a
    /// thumbnail-then-full transition. Safe to call with assets already
    /// cached; PhotoKit de-duplicates.
    nonisolated func startCaching(_ assets: [PhotoAsset], targetSize: CGSize) {
        guard !assets.isEmpty, targetSize.width > 0, targetSize.height > 0 else { return }
        cachingImageManager.startCachingImages(
            for: assets.map(\.phAsset),
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: Self.streamOptions()
        )
    }

    /// Releases cards that left the prefetch window, at the size they were
    /// cached with.
    nonisolated func stopCaching(_ assets: [PhotoAsset], targetSize: CGSize) {
        guard !assets.isEmpty, targetSize.width > 0, targetSize.height > 0 else { return }
        cachingImageManager.stopCachingImages(
            for: assets.map(\.phAsset),
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: Self.streamOptions()
        )
    }

    /// Resolves an `AVPlayerItem` for a video asset. `isNetworkAccessAllowed`
    /// lets an iCloud original stream in; the caller shows the poster thumbnail
    /// first and never blocks on this. Returns nil if PhotoKit can't provide a
    /// playable item.
    nonisolated func playerItem(for asset: PhotoAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(
                forVideo: asset.phAsset,
                options: options
            ) { item, _ in
                continuation.resume(returning: item)
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

    /// Which of `ids` still resolve to an asset. Used to prune decisions for
    /// photos deleted outside the app. Fetched in chunks so the identifier
    /// predicate stays a sane size for very large sets, at utility priority
    /// off the main actor.
    nonisolated func existingIdentifiers(among ids: Set<String>) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let all = Array(ids)
            var found = Set<String>()
            found.reserveCapacity(all.count)
            var start = 0
            while start < all.count {
                let end = min(all.count, start + 500)
                let result = PHAsset.fetchAssets(
                    withLocalIdentifiers: Array(all[start..<end]),
                    options: nil
                )
                result.enumerateObjects { asset, _, _ in
                    found.insert(asset.localIdentifier)
                }
                start = end
            }
            return found
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

    /// Measures on-device byte size per asset from `PHAssetResource` metadata
    /// (no download), returning a map keyed by `localIdentifier`. Callers pass
    /// only the assets they don't already have cached. Assets with multiple
    /// resources (RAW + JPEG, edits) sum them all, since they all reclaim
    /// space on delete.
    ///
    /// Runs on the generic executor (nonisolated async), not detached, so the
    /// caller's cancellation reaches it: it checks between chunks and throws
    /// `CancellationError`. `onProgress` reports `(measured, total)` after
    /// each chunk, from a background thread.
    nonisolated func byteSizes(
        for assets: [PhotoAsset],
        chunkSize: Int = 250,
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [String: Int64] {
        guard !assets.isEmpty else { return [:] }
        var result: [String: Int64] = [:]
        result.reserveCapacity(assets.count)
        var start = 0
        while start < assets.count {
            try Task.checkCancellation()
            let end = min(assets.count, start + max(1, chunkSize))
            for asset in assets[start..<end] {
                result[asset.id] = Self.resourceSize(of: asset.phAsset)
            }
            start = end
            onProgress(start, assets.count)
        }
        return result
    }

    nonisolated private static func resourceSize(of asset: PHAsset) -> Int64 {
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

    /// Lightweight summary of a user album — enough for a list row without
    /// forcing the caller to touch PhotoKit directly. Holds the collection
    /// itself so we can build a DeckSource without re-resolving.
    struct AlbumSummary: Identifiable {
        let id: String
        let title: String
        let count: Int
        let cover: PhotoAsset?
        let collection: PHAssetCollection
    }

    /// Fetches every user-created album that has at least one image asset,
    /// sorted alphabetically. Videos are excluded from the count so it
    /// matches what the user will actually see in the swipe deck.
    nonisolated func fetchUserAlbums() async -> [AlbumSummary] {
        await Task.detached(priority: .userInitiated) {
            let albumOptions = PHFetchOptions()
            albumOptions.sortDescriptors = [
                NSSortDescriptor(key: "localizedTitle", ascending: true)
            ]
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .any,
                options: albumOptions
            )

            let assetOptions = PHFetchOptions()
            assetOptions.predicate = NSPredicate(
                format: "mediaType = %d",
                PHAssetMediaType.image.rawValue
            )
            assetOptions.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: false)
            ]

            var summaries: [AlbumSummary] = []
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: assetOptions)
                guard assets.count > 0 else { return }
                let title = collection.localizedTitle ?? "Untitled"
                let cover = assets.firstObject.map(PhotoAsset.init(phAsset:))
                summaries.append(AlbumSummary(
                    id: collection.localIdentifier,
                    title: title,
                    count: assets.count,
                    cover: cover,
                    collection: collection
                ))
            }
            return summaries
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
