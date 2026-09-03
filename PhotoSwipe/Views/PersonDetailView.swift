import SwiftUI

/// A person's detail screen. Photos are grouped by calendar day (newest-first
/// by default). Each date section has a swipe-this-day button. The "Clean all"
/// entry at the top launches the full swipe deck for the person. Tapping the
/// navigation title renames the person inline.
struct PersonDetailView: View {
    let service: PhotoLibraryService
    /// Observed so the kept / marked badges update after a deck session.
    @ObservedObject var store: ReviewStore
    /// Not observed: only handed to the "Also with…" deck.
    let stats: StatsStore
    let sizes: SizeStore
    @StateObject private var viewModel: PersonDetailViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var draftName = ""
    @State private var showMerge = false
    @State private var mergeCandidates: [PersonCluster] = []
    /// "Also with…": pick a second person, then push a deck of the photos
    /// both appear in.
    @State private var showAlsoWith = false
    /// The person picked in the "Also with…" sheet. The deck is pushed from
    /// the sheet's onDismiss, not from inside it: pushing while the sheet is
    /// still animating away can leave the destination blank.
    @State private var alsoWithPick: PersonCluster?
    @State private var alsoWithRoute: AppRoute?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    init(cluster: PersonCluster, service: PhotoLibraryService, store: ReviewStore,
         stats: StatsStore, sizes: SizeStore) {
        self.service = service
        self.store = store
        self.stats = stats
        self.sizes = sizes
        _viewModel = StateObject(wrappedValue: PersonDetailViewModel(cluster: cluster))
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            // Thicker bar material, same reason as Browse.
            .toolbarBackground(.thickMaterial, for: .navigationBar)
            .toolbar { principalTitle; sortButton; optionsMenu }
            .task { await viewModel.load(using: service) }
            .alert("Name this person", isPresented: $showRename) {
                TextField("Name", text: $draftName)
                Button("Save") { Task { await viewModel.rename(to: draftName) } }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showMerge) {
                MergePickerView(title: "Merge into", candidates: mergeCandidates, service: service) { dest in
                    showMerge = false
                    Task { await viewModel.merge(into: dest.personID); dismiss() }
                }
            }
            .sheet(isPresented: $showAlsoWith, onDismiss: {
                guard let other = alsoWithPick else { return }
                alsoWithPick = nil
                let shared = viewModel.photoIDs(sharedWith: other)
                alsoWithRoute = .swipe(.person(shared, preservesOrder: false))
            }) {
                MergePickerView(title: "Also with", candidates: mergeCandidates, service: service) { other in
                    alsoWithPick = other
                    showAlsoWith = false
                }
            }
            .navigationDestination(item: $alsoWithRoute) { route in
                if case .swipe(let source) = route {
                    SwipeView(service: service, store: store, stats: stats, sizes: sizes, source: source)
                }
            }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    cleanAllRow
                    dateGrid
                }
            }
        }
    }

    // MARK: - Subviews

    private var cleanAllRow: some View {
        NavigationLink(value: AppRoute.swipe(.person(viewModel.allSortedIDs))) {
            BrowseEntryRow(title: "Clean these photos",
                           subtitle: "Swipe through \(viewModel.assets.count) photos",
                           systemImage: "hand.tap.fill")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.screenMargin)
        .padding(.vertical, 12)
        .disabled(viewModel.assets.isEmpty)
    }

    private var dateGrid: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(viewModel.groupedByDate) { group in
                Section {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(group.assets) { asset in
                            NavigationLink(value: AppRoute.swipe(.person(
                                viewModel.idsFrom(asset: asset, backwardIn: group)
                            ))) {
                                Thumbnail(asset: asset,
                                          service: service,
                                          decision: store.decision(for: asset.id))
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                NavigationLink(value: AppRoute.swipe(.person(
                                    viewModel.idsFrom(asset: asset, backwardIn: group)
                                ))) {
                                    Label("Swipe from here", systemImage: "play.circle")
                                }
                            } preview: {
                                ThumbnailPreview(asset: asset, service: service)
                            }
                        }
                    }
                } header: {
                    dateSectionHeader(group)
                }
            }
        }
    }

    // Tapping the date header swipes only that day's photos, newest → oldest.
    private func dateSectionHeader(_ group: PersonDetailViewModel.DateGroup) -> some View {
        NavigationLink(value: AppRoute.swipe(.person(viewModel.idsForDay(group)))) {
            HStack {
                Text(group.dateLabel)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var principalTitle: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                draftName = viewModel.name ?? ""
                showRename = true
            } label: {
                Text(viewModel.name ?? "Unnamed")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ToolbarContentBuilder
    private var sortButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                viewModel.sortAscending.toggle()
            } label: {
                Image(systemName: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                    .accessibilityLabel(viewModel.sortAscending ? "Oldest first" : "Newest first")
            }
        }
    }

    @ToolbarContentBuilder
    private var optionsMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task {
                        mergeCandidates = await viewModel.mergeCandidates()
                        showMerge = true
                    }
                } label: {
                    Label("Merge into…", systemImage: "arrow.triangle.merge")
                }
                Button {
                    Task {
                        mergeCandidates = await viewModel.mergeCandidates()
                        showAlsoWith = true
                    }
                } label: {
                    Label("Also with…", systemImage: "person.2")
                }
                Button(role: .destructive) {
                    Task { await viewModel.hidePerson(); dismiss() }
                } label: {
                    Label("Hide person", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("Person options")
            }
        }
    }
}

// MARK: - Merge picker

private struct MergePickerView: View {
    let title: String
    let candidates: [PersonCluster]
    let service: PhotoLibraryService
    let onPick: (PersonCluster) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView("No other people",
                                          systemImage: "person.2.slash",
                                          description: Text("There's no one else to merge into yet."))
                } else {
                    List(candidates) { cluster in
                        Button { onPick(cluster) } label: {
                            MergeRow(cluster: cluster, service: service)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// One person in the merge / "Also with…" pickers: the face-cropped cover
/// (same as the People grid, so a person is recognisable) with name and
/// count. Long-press previews the full cover photo.
private struct MergeRow: View {
    let cluster: PersonCluster
    let service: PhotoLibraryService

    var body: some View {
        HStack(spacing: 12) {
            PersonCoverView(cluster: cluster, service: service)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .contentShape(.contextMenuPreview, Circle())
                .contextMenu {
                    Text(cluster.displayName)
                } preview: {
                    PersonCoverPreview(cluster: cluster, service: service)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.displayName)
                Text("\(cluster.photoCount) photos")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
