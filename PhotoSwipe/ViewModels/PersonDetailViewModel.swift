import Foundation
import SwiftUI

/// Backs the person-detail screen: resolves the cluster's photos, tracks the
/// multi-select set, and performs a batched delete (one system confirm) plus
/// cluster management (rename / hide). Cluster membership itself lives in
/// `FaceStore`; this holds only the transient screen state.
@MainActor
final class PersonDetailViewModel: ObservableObject {
    @Published private(set) var assets: [PhotoAsset] = []
    @Published var selection: Set<String> = []
    @Published private(set) var isLoading = true
    @Published var name: String?
    /// Bytes reclaimed by the most recent delete — drives the "Freed ~X MB" note.
    @Published var lastFreedBytes: Int64?

    let personID: String
    /// The person's photo identifiers, oldest-first — also the scoped deck source.
    let photoIDs: [String]

    private let store: FaceStore
    private let stats: StatsStore

    init(cluster: PersonCluster, stats: StatsStore) {
        self.personID = cluster.personID
        self.photoIDs = cluster.photoIDs
        self.name = cluster.name
        self.stats = stats
        self.store = FaceStore(modelContainer: FaceContainer.shared)
    }

    var deckSource: DeckSource { .person(assets.map(\.id)) }
    var hasSelection: Bool { !selection.isEmpty }

    func load(using service: PhotoLibraryService) async {
        assets = await service.fetchAssets(withIDs: Set(photoIDs))
        isLoading = false
    }

    func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func clearSelection() { selection.removeAll() }

    func selectAll() { selection = Set(assets.map(\.id)) }

    /// Batched delete of the selected photos — one PhotoKit request, one system
    /// prompt. On success, drops them from the grid and logs the freed space.
    @discardableResult
    func deleteSelected(using service: PhotoLibraryService) async -> Bool {
        let ids = selection
        guard !ids.isEmpty else { return false }
        let bytes = await service.totalSize(forIDs: ids)
        let success = await service.deleteAssets(ids: ids)
        if success {
            stats.recordDelete(count: ids.count, bytesFreed: bytes)
            assets.removeAll { ids.contains($0.id) }
            selection.removeAll()
            lastFreedBytes = bytes
        }
        return success
    }

    func rename(to newName: String?) async {
        try? await store.rename(personID: personID, to: newName)
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func hidePerson() async {
        try? await store.setHidden(personID: personID, true)
    }
}
