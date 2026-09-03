import Foundation
import SwiftUI

/// Backs the Browse screen: fetches every image, buckets it by day, and hands
/// SwiftUI a newest-first array of day sections. The heavy grouping runs off
/// the main actor so large libraries don't stall the UI.
@MainActor
final class BrowseViewModel: ObservableObject {
    struct DaySection: Identifiable {
        /// Start-of-day; also serves as identity and the `startFrom` cutoff
        /// M3 will feed into DeckSource.
        let id: Date
        let assets: [PhotoAsset]
        /// Offset of this section's first asset in `flatAssets`, so a cell
        /// can report its flat index to the grid prefetcher.
        let startIndex: Int
    }

    @Published private(set) var sections: [DaySection] = []
    /// Every asset in display order (sections newest-first, newest-first
    /// inside), the list the grid prefetcher windows over.
    @Published private(set) var flatAssets: [PhotoAsset] = []
    /// Bumped whenever `sections` are rebuilt, so observers can react to a
    /// refresh that happens to keep the same counts.
    @Published private(set) var generation = 0
    @Published private(set) var isLoading: Bool = true

    /// The `libraryVersion` the grid was built from; nil until the first load.
    private var loadedLibraryVersion: Int?

    /// Called on every appearance and on library changes. Fetches only when
    /// the library changed since the last build, and shows the loading state
    /// only for the very first load, so switching tabs or popping back from a
    /// deck neither flashes the spinner nor resets the scroll position.
    func loadIfNeeded(using service: PhotoLibraryService) async {
        guard loadedLibraryVersion != service.libraryVersion else { return }
        let version = service.libraryVersion
        if sections.isEmpty { isLoading = true }
        let fetched = await service.fetchImages(source: .allPhotos)
        let grouped = await Task.detached(priority: .userInitiated) {
            Self.group(assets: fetched)
        }.value
        sections = grouped
        flatAssets = grouped.flatMap(\.assets)
        generation &+= 1
        loadedLibraryVersion = version
        isLoading = false
    }

    /// Buckets by start-of-day and returns newest-first sections with
    /// newest-first assets inside — matches Photos.app browsing.
    nonisolated private static func group(assets: [PhotoAsset]) -> [DaySection] {
        let calendar = Calendar.current
        var buckets: [Date: [PhotoAsset]] = [:]
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            let day = calendar.startOfDay(for: date)
            buckets[day, default: []].append(asset)
        }
        var offset = 0
        return buckets.keys.sorted(by: >).map { day in
            let sorted = (buckets[day] ?? []).sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            defer { offset += sorted.count }
            return DaySection(id: day, assets: sorted, startIndex: offset)
        }
    }
}
