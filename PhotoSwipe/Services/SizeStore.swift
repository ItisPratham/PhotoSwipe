import Foundation
import SwiftUI

/// Caches on-device byte sizes per `PHAsset.localIdentifier`, so the
/// largest-files-first deck doesn't re-enumerate `PHAssetResource` metadata on
/// every visit. Populated incrementally — only assets missing from the cache
/// are measured — and persisted to UserDefaults alongside the other small
/// local stores. Sizes are read from metadata (no asset download).
@MainActor
final class SizeStore: ObservableObject {
    @Published private(set) var sizes: [String: Int64]

    private let defaults: UserDefaults
    private let key = "PhotoSwipe.assetSizes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            self.sizes = decoded
        } else {
            self.sizes = [:]
        }
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

    private func persist() {
        if let data = try? JSONEncoder().encode(sizes) {
            defaults.set(data, forKey: key)
        }
    }
}
