import Foundation
import SwiftUI

/// Caches on-device byte sizes per `PHAsset.localIdentifier`, so the
/// largest-files-first deck doesn't re-enumerate `PHAssetResource` metadata on
/// every visit. Populated incrementally — only assets missing from the cache
/// are measured — and persisted to UserDefaults alongside the other small
/// local stores. Sizes are read from metadata (no asset download).
///
/// The cache is decoded off the main thread at construction; the one reader
/// that needs it complete (`SwipeViewModel.sortedByLargest`) calls
/// `waitUntilLoaded()` first. The duplicate scan measures the same number for
/// every asset it indexes; `adoptIndexedSizes()` folds those in so an asset is
/// never measured twice. Persisting encodes the whole dictionary, so it
/// happens on a serial background queue, never before the load has finished.
@MainActor
final class SizeStore: ObservableObject {
    @Published private(set) var sizes: [String: Int64] = [:]

    private let defaults: UserDefaults
    private let key = "PhotoSwipe.assetSizes"
    private let writeQueue = DispatchQueue(label: "PhotoSwipe.SizeStore.write", qos: .utility)
    private var loading: Task<Void, Never>?
    private(set) var isLoaded = false
    private var writeAfterLoad = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: key)
        let read = Task.detached(priority: .userInitiated) { () -> [String: Int64] in
            guard let data else { return [:] }
            return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
        }
        loading = Task { [weak self] in
            let stored = await read.value
            self?.finishLoading(stored)
        }
    }

    /// Resolves once the persisted sizes have been applied.
    func waitUntilLoaded() async {
        await loading?.value
    }

    /// Anything measured before the load finished wins over the stored value.
    private func finishLoading(_ stored: [String: Int64]) {
        sizes.merge(stored) { current, _ in current }
        isLoaded = true
        if writeAfterLoad { persist() }
    }

    func size(for id: String) -> Int64? {
        sizes[id]
    }

    /// Folds freshly measured sizes into the cache and persists.
    func merge(_ newSizes: [String: Int64]) {
        guard !newSizes.isEmpty else { return }
        sizes.merge(newSizes) { _, new in new }
        persist()
    }

    /// Pulls in sizes the duplicate index already recorded for assets this
    /// cache hasn't seen. Cheap: two columns, no feature prints.
    func adoptIndexedSizes() async {
        let index = IndexStore.shared
        guard let indexed = try? await index.byteSizes() else { return }
        merge(indexed.filter { sizes[$0.key] == nil })
    }

    /// The encode (the expensive part) runs on the serial queue; the resulting
    /// blob is handed back to the main actor for the `UserDefaults` write,
    /// which is a cheap dictionary set that the framework syncs on its own.
    private func persist() {
        guard isLoaded else { writeAfterLoad = true; return }
        let snapshot = sizes
        let key = key
        writeQueue.async { [weak self] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            Task { @MainActor in
                self?.defaults.set(data, forKey: key)
            }
        }
    }
}
