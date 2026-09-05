import SwiftUI

struct SearchView: View {
    @ObservedObject var service: PhotoLibraryService
    @ObservedObject var store: ReviewStore
    @ObservedObject var viewModel: SearchViewModel

    @State private var prefetcher = GridPrefetcher(targetSize: Thumbnail.requestSize)
    @State private var inspectedAsset: PhotoAsset?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        content
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: Binding(
                get: { viewModel.query },
                set: { viewModel.queryChanged($0, using: service) }
            ), prompt: "Describe a photo")
            .onSubmit(of: .search) { viewModel.submit(using: service) }
            .task {
                prefetcher.attach(service)
                viewModel.viewAppeared(using: service)
            }
            .onChange(of: service.libraryVersion) { _, _ in viewModel.libraryChanged(using: service) }
            .onChange(of: viewModel.assets) { _, assets in prefetcher.update(assets: assets) }
            .onDisappear {
                prefetcher.release()
                viewModel.viewDisappeared()
            }
            .fullScreenCover(item: $inspectedAsset) { asset in
                PhotoZoomView(asset: asset, service: service)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .missingModel:
            ContentUnavailableView(
                "Search model unavailable",
                systemImage: "magnifyingglass",
                description: Text("Install both local MobileCLIP S2 packages and their provenance file to enable research search.")
            )
        case .consent:
            ContentUnavailableView {
                Label("Search your photos", systemImage: "magnifyingglass")
            } description: {
                Text("PhotoSwipe can create an on-device search index. Nothing leaves your device.")
            } actions: {
                Button("Index my library") { viewModel.startIndex(using: service) }
                    .buttonStyle(.borderedProminent)
            }
        case .indexing:
            VStack(spacing: 16) {
                ProgressView(value: viewModel.progress)
                Text(viewModel.total == 0 ? "Preparing search…" : "Indexing \(viewModel.processed) of \(viewModel.total)…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { viewModel.cancel() }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Search index needs attention", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Your existing results are safe. Try indexing again.")
            } actions: {
                Button("Retry") { viewModel.retry(using: service) }
                    .buttonStyle(.borderedProminent)
            }
        case .partial, .ready:
            results
        }
    }

    private var results: some View {
        ScrollView {
            ScrollBarInstaller().frame(height: 0)
            LazyVStack(alignment: .leading, spacing: 12) {
                indexStatus
                peoplePicker
                if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    recentSearches
                } else if viewModel.assets.isEmpty {
                    if viewModel.isSearching {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if viewModel.queryFailed {
                        ContentUnavailableView {
                            Label("Search didn't finish", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Something went wrong running that query.")
                        } actions: {
                            Button("Try again") { viewModel.submit(using: service) }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                } else {
                    if viewModel.queryFailed {
                        HStack {
                            Label("Search failed. Showing previous results.", systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button("Retry") { viewModel.submit(using: service) }
                        }
                        .font(.caption)
                        .padding(.horizontal, Theme.Spacing.screenMargin)
                    }
                    if !viewModel.results.isEmpty {
                        NavigationLink(value: AppRoute.swipe(.search(
                            query: viewModel.query,
                            ids: viewModel.results.map(\.assetID)
                        ))) {
                            BrowseEntryRow(
                                title: "Swipe these",
                                subtitle: "\(viewModel.results.count) ranked photos",
                                systemImage: "hand.tap.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Theme.Spacing.screenMargin)
                    }
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(viewModel.assets.enumerated()), id: \.element.id) { index, asset in
                            Button { inspectedAsset = asset } label: {
                                Thumbnail(asset: asset, service: service, decision: store.decision(for: asset.id))
                            }
                            .buttonStyle(.plain)
                            .onAppear { prefetcher.cellAppeared(index) }
                            .onDisappear { prefetcher.cellDisappeared(index) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.top, 12)
        }
    }

    /// Refreshes never take the results away; they report themselves here.
    /// A partial index says so and offers the two ways out of it.
    @ViewBuilder
    private var indexStatus: some View {
        if viewModel.isIndexing {
            HStack(spacing: 12) {
                ProgressView(value: viewModel.progress)
                Text(viewModel.total == 0 ? "Indexing…" : "\(viewModel.processed) of \(viewModel.total)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Cancel") { viewModel.cancel() }
                    .font(.caption)
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
        } else if viewModel.phase == .partial {
            HStack(spacing: 12) {
                Label("Some photos aren't indexed yet", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Resume") { viewModel.retry(using: service) }
                    .font(.caption)
                Button("Rescan") { viewModel.rescan(using: service) }
                    .font(.caption)
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
        }
    }

    private var peoplePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.selectedPeople.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(viewModel.selectedPeople) { person in
                            Button {
                                viewModel.togglePerson(person, using: service)
                            } label: {
                                Label(person.displayName, systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.screenMargin)
                }
            }
            Menu {
                ForEach(viewModel.people) { person in
                    Button {
                        viewModel.togglePerson(person, using: service)
                    } label: {
                        Label(
                            person.displayName,
                            systemImage: viewModel.selectedPeople.contains(where: { $0.personID == person.personID })
                                ? "checkmark" : "person"
                        )
                    }
                }
            } label: {
                Label("People", systemImage: "person.2")
            }
            .padding(.horizontal, Theme.Spacing.screenMargin)
        }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if viewModel.recentQueries.isEmpty {
            ContentUnavailableView(
                "Describe what you want to find",
                systemImage: "text.magnifyingglass",
                description: Text("Try “beach”, “birthday cake”, or “with Priya”.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            Text("Recent searches")
                .font(.headline)
                .padding(.horizontal, Theme.Spacing.screenMargin)
            ForEach(viewModel.recentQueries, id: \.self) { query in
                Button {
                    viewModel.useRecent(query, using: service)
                } label: {
                    Label(query, systemImage: "clock.arrow.circlepath")
                }
                .padding(.horizontal, Theme.Spacing.screenMargin)
            }
        }
    }
}
