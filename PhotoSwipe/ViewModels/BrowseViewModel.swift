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
    /// How many of the fetched photos are screenshots, for the Browse entry's
    /// subtitle. Counted during the grouping pass — no extra fetch.
    @Published private(set) var screenshotCount = 0
    /// Photos taken on today's month/day in earlier years, and how many years
    /// they span, for the On This Day entry. Counted in the grouping pass.
    @Published private(set) var onThisDayCount = 0
    @Published private(set) var onThisDayYears = 0

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
        let (grouped, screenshots, onThisDay) = await Task.detached(priority: .userInitiated) {
            (Self.group(assets: fetched),
             fetched.reduce(0) { $0 + ($1.isScreenshot ? 1 : 0) },
             Self.onThisDay(assets: fetched))
        }.value
        sections = grouped
        screenshotCount = screenshots
        onThisDayCount = onThisDay.count
        onThisDayYears = onThisDay.years
        flatAssets = grouped.flatMap(\.assets)
        generation &+= 1
        loadedLibraryVersion = version
        isLoading = false
    }

    /// How many photos fall on today's month/day in an earlier year, and how
    /// many distinct years they cover.
    nonisolated private static func onThisDay(assets: [PhotoAsset],
                                              now: Date = Date()) -> (count: Int, years: Int) {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var count = 0
        var years = Set<Int>()
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard parts.month == today.month, parts.day == today.day,
                  let year = parts.year, let thisYear = today.year, year < thisYear
            else { continue }
            count += 1
            years.insert(year)
        }
        return (count, years.count)
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
