import SwiftUI

/// The app shell shown after onboarding and the permission gate. A bottom tab
/// bar with four tabs — **Clean** (the fast oldest-first all-photos deck),
/// **Browse** (the grid plus Videos / Duplicates / Biggest / Albums entries),
/// and **People** — each backed by its own `NavigationStack`. A settings gear
/// in every tab's toolbar opens the shared `SettingsView` sheet.
///
/// The shared stores are owned once by `RootView` and injected here, so every
/// tab reads and writes the same source of truth (no per-tab duplication).
/// Every entry point still funnels into the single `SwipeView` deck engine via
/// a `DeckSource`.
///
/// The stores are plain references, not observed: this shell reads nothing
/// from them, it only hands them down. Observing them here would re-evaluate
/// the whole tab tree on every swipe.
struct AppTabView: View {
    let library: PhotoLibraryService
    let reviewStore: ReviewStore
    let statsStore: StatsStore
    let sizeStore: SizeStore

    /// Fires once the Clean tab's deck finishes its first load, so RootView's
    /// launch splash can wait for real content before crossfading in.
    var onCleanLoaded: () -> Void = {}

    @State private var selection: AppTab = .clean
    @State private var showSettings = false
    /// These models outlive navigation destinations so popping and reopening
    /// a scan screen reconnects to the same queue instead of starting a
    /// second library walk beside the first.
    @StateObject private var duplicatesViewModel = DuplicatesViewModel()
    @StateObject private var categoriesViewModel = CategoriesViewModel()
    @StateObject private var searchViewModel = SearchViewModel()

    var body: some View {
        TabView(selection: $selection) {
            cleanTab
                .tabItem { Label("Clean", systemImage: "wand.and.stars") }
                .tag(AppTab.clean)

            browseTab
                .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
                .tag(AppTab.browse)

            peopleTab
                .tabItem { Label("People", systemImage: "person.2") }
                .tag(AppTab.people)

            searchTab
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(service: library, store: reviewStore, stats: statsStore)
        }
    }

    // MARK: - Tabs

    /// Fast path: lands directly in the default oldest-first, all-photos deck.
    private var cleanTab: some View {
        NavigationStack {
            SwipeView(service: library,
                      store: reviewStore,
                      stats: statsStore,
                      sizes: sizeStore,
                      source: .allPhotos,
                      onLoaded: onCleanLoaded,
                      onBackToBrowse: { selection = .browse })
                .navigationTitle("Clean")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { settingsToolbar }
        }
    }

    /// The existing library grid and its surfaced entry points.
    private var browseTab: some View {
        NavigationStack {
            BrowseView(service: library, store: reviewStore)
                .toolbar { settingsToolbar }
                .navigationDestination(for: AppRoute.self) { destination(for: $0) }
        }
    }

    private var peopleTab: some View {
        NavigationStack {
            PeopleView(service: library)
                .toolbar { settingsToolbar }
                .navigationDestination(for: PersonCluster.self) { cluster in
                    PersonDetailView(cluster: cluster, service: library, store: reviewStore,
                                     stats: statsStore, sizes: sizeStore)
                }
                .navigationDestination(for: AppRoute.self) { destination(for: $0) }
        }
    }

    private var searchTab: some View {
        NavigationStack {
            SearchView(service: library, store: reviewStore, viewModel: searchViewModel)
                .toolbar { settingsToolbar }
                .navigationDestination(for: AppRoute.self) { destination(for: $0) }
        }
    }

    // MARK: - Settings gear

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .albums:
            AlbumListView(service: library)
        case .duplicates:
            DuplicatesView(service: library, viewModel: duplicatesViewModel)
        case .categories:
            CategoriesView(service: library, viewModel: categoriesViewModel)
        case .category(let category, let ids):
            CategoryDetailView(category: category, ids: ids, service: library, store: reviewStore)
        case .collection(let collection):
            PhotoCollectionView(
                collection: collection,
                service: library,
                store: reviewStore,
                sizes: sizeStore
            )
        case .swipe(let source):
            SwipeView(service: library,
                      store: reviewStore,
                      stats: statsStore,
                      sizes: sizeStore,
                      source: source)
        }
    }
}
