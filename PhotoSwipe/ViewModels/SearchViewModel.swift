import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    enum Phase: Equatable {
        case missingModel(SearchEmbedder.Availability)
        case consent
        case indexing
        case partial
        case ready
        case failed
    }

    static let enabledKey = "PhotoSwipe.searchEnabled"
    /// Read by the other scan screens so one shared walk fills in search
    /// embeddings too, instead of leaving Search a second pass to run.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    private static let recentsKey = "PhotoSwipe.recentSearches"

    @Published var query = ""
    @Published private(set) var phase: Phase
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var processed = 0
    @Published private(set) var total = 0
    @Published private(set) var recentQueries: [String]
    @Published private(set) var people: [PersonCluster] = []
    @Published private(set) var selectedPeople: [PersonCluster] = []
    /// True from the keystroke (through the debounce) until the newest search
    /// lands, so the empty state reads "searching" rather than "no matches".
    @Published private(set) var isSearching = false
    /// Set when a query itself fails (model load, inference, store read). An
    /// empty result set and a broken query are different answers, and only one
    /// of them is fixed by trying again.
    @Published private(set) var queryFailed = false
    /// A refresh running underneath results that are already on screen. The
    /// first index takes over the screen; later ones never do.
    @Published private(set) var isIndexing = false

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }

    private let embedder = SearchEmbedder()
    private let indexService = LibraryIndexService()
    private let indexStore = IndexStore.shared
    private let queue = SerialTaskQueue()
    private var debounce: Task<Void, Never>?
    private var generation = 0
    private var loadedLibraryVersion: Int?
    /// Once an index exists, refreshes are silent — the same "load once,
    /// refresh silently" rule the decks and grids follow.
    private var hasIndexedBefore: Bool
    private var isVisible = false
    private var disappearGrace: Task<Void, Never>?

    init() {
        recentQueries = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        hasIndexedBefore = UserDefaults.standard.bool(forKey: Self.enabledKey)
        phase = Self.initialPhase(for: SearchEmbedder().availability)
    }

    deinit {
        debounce?.cancel()
        disappearGrace?.cancel()
    }

    func viewAppeared(using service: PhotoLibraryService) {
        isVisible = true
        disappearGrace?.cancel()
        refreshPeople(using: service)
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        enqueueIndex(using: service, onlyIfNeeded: true)
    }

    /// Leaving the tab stops the scan, like the other scan screens. The grace
    /// period keeps a quick tab bounce from restarting the walk.
    func viewDisappeared() {
        isVisible = false
        disappearGrace?.cancel()
        disappearGrace = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            self.cancel()
        }
    }

    func startIndex(using service: PhotoLibraryService) {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        enqueueIndex(using: service, onlyIfNeeded: false)
    }

    /// Re-runs the whole pass, including rows an earlier run left behind.
    func rescan(using service: PhotoLibraryService) {
        loadedLibraryVersion = nil
        enqueueIndex(using: service, onlyIfNeeded: false)
    }

    func retry(using service: PhotoLibraryService) {
        enqueueIndex(using: service, onlyIfNeeded: false)
    }

    func libraryChanged(using service: PhotoLibraryService) {
        refreshPeople(using: service)
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        enqueueIndex(using: service, onlyIfNeeded: true)
    }

    func cancel() {
        queue.cancelAll()
        // Leaving the tab while nothing is running must not move the screen
        // off the consent or missing-model state it was showing.
        guard isIndexing || phase == .indexing else { return }
        phase = hasIndexedBefore ? (results.isEmpty ? .partial : .ready) : .consent
    }

    func queryChanged(_ value: String, using service: PhotoLibraryService) {
        query = value
        generation &+= 1
        debounce?.cancel()
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            assets = []
            isSearching = false
            return
        }
        isSearching = true
        let generation = generation
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            await self.runSearch(using: service, generation: generation, remember: false)
        }
    }

    func submit(using service: PhotoLibraryService) {
        debounce?.cancel()
        generation &+= 1
        let generation = generation
        Task { [weak self] in
            await self?.runSearch(using: service, generation: generation, remember: true)
        }
    }

    func useRecent(_ query: String, using service: PhotoLibraryService) {
        self.query = query
        submit(using: service)
    }

    func togglePerson(_ person: PersonCluster, using service: PhotoLibraryService) {
        if let index = selectedPeople.firstIndex(where: { $0.personID == person.personID }) {
            selectedPeople.remove(at: index)
        } else {
            selectedPeople.append(person)
        }
        generation &+= 1
        let generation = generation
        Task { [weak self] in
            await self?.runSearch(using: service, generation: generation, remember: false)
        }
    }

    private func enqueueIndex(using service: PhotoLibraryService, onlyIfNeeded: Bool) {
        guard embedder.availability == .ready else {
            phase = .missingModel(embedder.availability)
            return
        }
        guard !onlyIfNeeded || loadedLibraryVersion != service.libraryVersion else { return }
        queue.enqueue { [weak self] in
            guard let self else { return }
            await self.index(using: service)
        }
    }

    private func index(using service: PhotoLibraryService) async {
        guard !Task.isCancelled else { return }
        // Only the very first index owns the screen; after that the results
        // stay put and the progress shows in a strip above them.
        if !hasIndexedBefore { phase = .indexing }
        isIndexing = true
        defer { isIndexing = false }
        processed = 0
        total = 0
        let version = service.libraryVersion
        let photos = await service.fetchImages(source: .allPhotos)
        do {
            try await indexService.scan(
                assets: photos,
                store: indexStore,
                includeSearch: true,
                searchEmbedder: embedder
            ) { [weak self] done, total in
                Task { @MainActor in
                    self?.processed = max(self?.processed ?? 0, done)
                    self?.total = total
                }
            }
            loadedLibraryVersion = version
            hasIndexedBefore = true
            let count = try await indexStore.searchEmbeddingCount()
            phase = count == photos.count ? .ready : .partial
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                generation &+= 1
                await runSearch(using: service, generation: generation, remember: false)
            }
        } catch is CancellationError {
            phase = hasIndexedBefore ? .partial : .consent
        } catch {
            // A failed refresh must not throw away results already on screen.
            phase = hasIndexedBefore ? .partial : .failed
        }
    }

    private func runSearch(using service: PhotoLibraryService, generation: Int, remember: Bool) async {
        isSearching = true
        queryFailed = false
        // A superseded run must not clear the flag the newer run still owns.
        defer { if generation == self.generation { isSearching = false } }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              UserDefaults.standard.bool(forKey: Self.enabledKey),
              phase != .missingModel(embedder.availability) else { return }
        if remember { addRecent(text) }
        do {
            let eligible = selectedPeople.isEmpty ? nil : selectedPeople
                .map { Set($0.photoIDs) }
                .dropFirst()
                .reduce(Set(selectedPeople[0].photoIDs), { $0.intersection($1) })
            let found = try await SearchIndex.shared.search(
                query: try await embedder.textEmbedding(for: text),
                store: indexStore,
                libraryVersion: service.libraryVersion,
                eligibleIdentifiers: eligible
            )
            let photoByID = Dictionary(
                (await service.fetchAssets(withIDs: Set(found.map(\.assetID)))).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard generation == self.generation, text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = found
            assets = found.compactMap { photoByID[$0.assetID] }
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            // Keep whatever is on screen and say the query failed, rather
            // than reporting an empty library as "no matches".
            queryFailed = true
        }
    }

    private func refreshPeople(using service: PhotoLibraryService) {
        Task { [weak self] in
            let store = await FaceStore.shared()
            let clusters = (try? await store.clusters())?.filter { !$0.isHidden } ?? []
            guard let self else { return }
            people = clusters
            let previous = selectedPeople
            selectedPeople = selectedPeople.compactMap { selected in
                clusters.first { $0.personID == selected.personID }
            }
            // A rename is cosmetic, but a merge, a hide, or new photos change
            // which photos the filter admits — the shown results would
            // otherwise disagree with the chips above them.
            guard previous != selectedPeople,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            generation &+= 1
            await runSearch(using: service, generation: generation, remember: false)
        }
    }

    private func addRecent(_ text: String) {
        recentQueries.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        recentQueries.insert(text, at: 0)
        recentQueries = Array(recentQueries.prefix(10))
        UserDefaults.standard.set(recentQueries, forKey: Self.recentsKey)
    }

    private static func initialPhase(for availability: SearchEmbedder.Availability) -> Phase {
        availability == .ready
            ? (UserDefaults.standard.bool(forKey: enabledKey) ? .partial : .consent)
            : .missingModel(availability)
    }
}
