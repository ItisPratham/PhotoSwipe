import SwiftUI

/// The app shell shown after onboarding and the permission gate. A bottom tab
/// bar with three tabs — **Clean** (the fast oldest-first all-photos deck),
/// **Browse** (the grid plus Videos / Duplicates / Biggest / Albums entries),
/// and **People** — each backed by its own `NavigationStack`. A settings gear
/// in every tab's toolbar opens the shared `SettingsView` sheet.
///
/// The shared stores are owned once by `RootView` and injected here, so every
/// tab reads and writes the same source of truth (no per-tab duplication).
/// Every entry point still funnels into the single `SwipeView` deck engine via
/// a `DeckSource`.
struct AppTabView: View {
    @ObservedObject var library: PhotoLibraryService
    @ObservedObject var reviewStore: ReviewStore
    @ObservedObject var statsStore: StatsStore
    @ObservedObject var sizeStore: SizeStore

    /// Fires once the Clean tab's deck finishes its first load, so RootView's
    /// launch splash can wait for real content before crossfading in.
    var onCleanLoaded: () -> Void = {}

    @State private var selection: AppTab = .clean
    @State private var showSettings = false

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
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: reviewStore, stats: statsStore)
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
                      onLoaded: onCleanLoaded)
                .navigationTitle("Clean")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { settingsToolbar }
        }
    }

    /// The existing library grid and its surfaced entry points.
    private var browseTab: some View {
        NavigationStack {
            BrowseView(service: library)
                .toolbar { settingsToolbar }
                .navigationDestination(for: AppRoute.self) { destination(for: $0) }
        }
    }

    private var peopleTab: some View {
        NavigationStack {
            PeopleView()
                .toolbar { settingsToolbar }
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
            DuplicatesView(service: library)
        case .swipe(let source):
            SwipeView(service: library,
                      store: reviewStore,
                      stats: statsStore,
                      sizes: sizeStore,
                      source: source)
        }
    }
}
