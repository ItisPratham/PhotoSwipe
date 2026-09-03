import Foundation
import SwiftUI

/// Backs the person-detail screen: resolves the cluster's photos, groups them
/// by calendar day for display, and performs cluster management (rename / hide /
/// merge).
@MainActor
final class PersonDetailViewModel: ObservableObject {

    struct DateGroup: Identifiable {
        let date: Date          // calendar start-of-day — used for sorting
        let dateLabel: String   // formatted for display, e.g. "3 September 2026"
        let assets: [PhotoAsset]
        var id: String { dateLabel }
    }

    @Published private(set) var assets: [PhotoAsset] = []
    /// Pre-sorted date groups — updated once on load and whenever the sort
    /// direction flips, avoiding repeated sorting during view renders.
    @Published private(set) var groupedByDate: [DateGroup] = []
    @Published private(set) var isLoading = true
    @Published var name: String?
    /// Newest-first by default; toggled by the sort button in the toolbar.
    @Published var sortAscending = false {
        didSet { guard oldValue != sortAscending else { return }; recomputeGroups() }
    }

    let personID: String
    let photoIDs: [String]

    private let store: FaceStore
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMMM yyyy"; return f
    }()

    init(cluster: PersonCluster) {
        self.personID = cluster.personID
        self.photoIDs = cluster.photoIDs
        self.name = cluster.name
        self.store = FaceStore(modelContainer: FaceContainer.shared)
    }

    // MARK: - Navigation helpers

    /// All photo IDs in current sort order — used by the "Clean all" entry.
    var allSortedIDs: [String] { groupedByDate.flatMap { $0.assets.map(\.id) } }

    /// All of `group`'s photos newest→oldest — tapping a date header swipes only
    /// that day's photos from the newest one down to the oldest.
    func idsForDay(_ group: DateGroup) -> [String] {
        group.assets
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .map(\.id)
    }

    /// From `asset` backward through the rest of that day — tapping a photo
    /// starts the deck at that photo and goes older within the same day only.
    func idsFrom(asset: PhotoAsset, backwardIn group: DateGroup) -> [String] {
        let newestFirst = group.assets
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        guard let idx = newestFirst.firstIndex(where: { $0.id == asset.id }) else {
            return newestFirst.map(\.id)
        }
        return Array(newestFirst[idx...]).map(\.id)
    }

    // MARK: - Loading

    func load(using service: PhotoLibraryService) async {
        assets = await service.fetchAssets(withIDs: Set(photoIDs))
        recomputeGroups()
        isLoading = false
    }

    // MARK: - Cluster management

    func rename(to newName: String?) async {
        try? await store.rename(personID: personID, to: newName)
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func hidePerson() async {
        try? await store.setHidden(personID: personID, true)
    }

    func mergeCandidates() async -> [PersonCluster] {
        let all = (try? await store.clusters()) ?? []
        return all.filter { $0.personID != personID && !$0.isHidden }
    }

    func merge(into destID: String) async {
        try? await store.merge(personID, into: destID)
    }

    // MARK: - Private

    private func recomputeGroups() {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: assets) { asset -> Date in
            cal.startOfDay(for: asset.creationDate ?? .distantPast)
        }
        groupedByDate = grouped
            .sorted { sortAscending ? $0.key < $1.key : $0.key > $1.key }
            .map { dayStart, dayAssets in
                let sorted = dayAssets.sorted {
                    let a = $0.creationDate ?? .distantPast
                    let b = $1.creationDate ?? .distantPast
                    return sortAscending ? a < b : a > b
                }
                return DateGroup(date: dayStart,
                                 dateLabel: dateFormatter.string(from: dayStart),
                                 assets: sorted)
            }
    }
}
