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

    var progress: Double { total > 0 ? Double(processed) / Double(total) : 0 }

    private let embedder = SearchEmbedder()
    private let indexService = LibraryIndexService()
    private let indexStore = IndexStore.shared
    private let queue = SerialTaskQueue()
    private var debounce: Task<Void, Never>?
    private var generation = 0
    private var loadedLibraryVersion: Int?

    init() {
        recentQueries = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        phase = Self.initialPhase(for: SearchEmbedder().availability)
    }

    deinit { debounce?.cancel() }

    func viewAppeared(using service: PhotoLibraryService) {
        refreshPeople()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        enqueueIndex(using: service, onlyIfNeeded: true)
    }

    func startIndex(using service: PhotoLibraryService) {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        enqueueIndex(using: service, onlyIfNeeded: false)
    }

    func retry(using service: PhotoLibraryService) {
        enqueueIndex(using: service, onlyIfNeeded: false)
    }

    func libraryChanged(using service: PhotoLibraryService) {
        refreshPeople()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        enqueueIndex(using: service, onlyIfNeeded: true)
    }

    func cancel() {
        queue.cancelAll()
        phase = results.isEmpty ? .partial : .ready
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
        phase = .indexing
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
            let count = try await indexStore.searchEmbeddingCount()
            phase = count == photos.count ? .ready : .partial
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                generation &+= 1
                await runSearch(using: service, generation: generation, remember: false)
            }
        } catch is CancellationError {
            phase = .partial
        } catch {
            phase = .failed
        }
    }

    private func runSearch(using service: PhotoLibraryService, generation: Int, remember: Bool) async {
        isSearching = true
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
            results = []
            assets = []
        }
    }

    private func refreshPeople() {
        Task { [weak self] in
            let store = await FaceStore.shared()
            let clusters = (try? await store.clusters())?.filter { !$0.isHidden } ?? []
            guard let self else { return }
            people = clusters
            selectedPeople = selectedPeople.compactMap { selected in
                clusters.first { $0.personID == selected.personID }
            }
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
