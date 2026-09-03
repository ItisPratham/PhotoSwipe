import Foundation
import SwiftUI

/// Backs a Browse-style grid over an explicit set of photo ids (a category,
/// for example): resolves the ids to assets and buckets them by calendar day,
/// newest first, the way the main Browse grid does. Deck entry points follow
/// Browse too: a photo starts the deck there and continues to newer photos.
@MainActor
final class PhotoSetViewModel: ObservableObject {
    struct DaySection: Identifiable {
        let id: Date
        let assets: [PhotoAsset]
    }

    @Published private(set) var sections: [DaySection] = []
    @Published private(set) var isLoading = true
    /// Every photo in the set, oldest first — the deck order.
    @Published private(set) var oldestFirstIDs: [String] = []

    let ids: [String]
    private var loadedLibraryVersion: Int?

    init(ids: [String]) {
        self.ids = ids
    }

    var count: Int { oldestFirstIDs.count }

    /// Resolves the ids on first appearance and again after a library change,
    /// keeping the grid in place otherwise.
    func loadIfNeeded(using service: PhotoLibraryService) async {
        guard loadedLibraryVersion != service.libraryVersion else { return }
        let version = service.libraryVersion
        if sections.isEmpty { isLoading = true }
        let assets = await service.fetchAssets(withIDs: Set(ids))   // oldest first
        let grouped = await Task.detached(priority: .userInitiated) {
            Self.group(assets: assets)
        }.value
        oldestFirstIDs = assets.map(\.id)
        sections = grouped
        loadedLibraryVersion = version
        isLoading = false
    }

    /// From `asset` onward in time, like tapping a photo in Browse.
    func idsFrom(_ asset: PhotoAsset) -> [String] {
        guard let index = oldestFirstIDs.firstIndex(of: asset.id) else { return oldestFirstIDs }
        return Array(oldestFirstIDs[index...])
    }

    /// From the oldest photo of `section`'s day onward, like a Browse header.
    func idsFrom(day section: DaySection) -> [String] {
        guard let first = section.assets.last else { return oldestFirstIDs }
        return idsFrom(first)
    }

    nonisolated private static func group(assets: [PhotoAsset]) -> [DaySection] {
        let calendar = Calendar.current
        var buckets: [Date: [PhotoAsset]] = [:]
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            buckets[calendar.startOfDay(for: date), default: []].append(asset)
        }
        return buckets.keys.sorted(by: >).map { day in
            let sorted = (buckets[day] ?? []).sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            return DaySection(id: day, assets: sorted)
        }
    }
}
