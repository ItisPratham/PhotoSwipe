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
    }

    @Published private(set) var sections: [DaySection] = []
    @Published private(set) var isLoading: Bool = true

    func load(using service: PhotoLibraryService) async {
        isLoading = true
        let fetched = await service.fetchImages(source: .allPhotos)
        sections = Self.group(assets: fetched)
        isLoading = false
    }

    /// Buckets by start-of-day and returns newest-first sections with
    /// newest-first assets inside — matches Photos.app browsing.
    private static func group(assets: [PhotoAsset]) -> [DaySection] {
        let calendar = Calendar.current
        var buckets: [Date: [PhotoAsset]] = [:]
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            let day = calendar.startOfDay(for: date)
            buckets[day, default: []].append(asset)
        }
        return buckets.keys.sorted(by: >).map { day in
            let sorted = (buckets[day] ?? []).sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            return DaySection(id: day, assets: sorted)
        }
    }
}
