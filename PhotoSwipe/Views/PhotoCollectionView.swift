import SwiftUI

/// Browse-first grid shared by Videos, Screenshots, Biggest files, and
/// co-occurring People results. The grid includes reviewed assets; entering
/// the deck still applies its normal reviewed-item filtering.
struct PhotoCollectionView: View {
    @ObservedObject var service: PhotoLibraryService
    @ObservedObject var store: ReviewStore
    let sizes: SizeStore

    @StateObject private var viewModel: PhotoCollectionViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    init(
        collection: PhotoCollection,
        service: PhotoLibraryService,
        store: ReviewStore,
        sizes: SizeStore
    ) {
        self.service = service
        self.store = store
        self.sizes = sizes
        _viewModel = StateObject(wrappedValue: PhotoCollectionViewModel(collection: collection))
    }

    var body: some View {
        content
            .navigationTitle(viewModel.collection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.thickMaterial, for: .navigationBar)
            .task { await load() }
            .onChange(of: service.libraryVersion) { _, _ in
                Task { await load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            loadingState
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView(
                "Couldn't load collection",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if viewModel.assets.isEmpty {
            ContentUnavailableView("Nothing here", systemImage: viewModel.collection.systemImage)
        } else {
            collectionGrid
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            if viewModel.measureTotal > 0 {
                ProgressView(
                    value: Double(viewModel.measuredCount),
                    total: Double(viewModel.measureTotal)
                )
                Text("Measuring \(viewModel.measuredCount) of \(viewModel.measureTotal)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .controlSize(.large)
                Text("Loading \(viewModel.collection.title.lowercased())…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collectionGrid: some View {
        ScrollView {
            ScrollBarInstaller().frame(height: 0)
            LazyVStack(spacing: 12) {
                NavigationLink(value: AppRoute.swipe(viewModel.deckSource())) {
                    BrowseEntryRow(
                        title: "Clean these",
                        subtitle: viewModel.itemDescription,
                        systemImage: "hand.tap.fill"
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.Spacing.screenMargin)
                .padding(.top, 12)

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(viewModel.assets) { asset in
                        NavigationLink(
                            value: AppRoute.swipe(viewModel.deckSource(startingAt: asset))
                        ) {
                            Thumbnail(
                                asset: asset,
                                service: service,
                                decision: store.decision(for: asset.id)
                            )
                            .overlay(alignment: .bottomLeading) {
                                if asset.isVideo {
                                    Text(asset.formattedDuration)
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(.black.opacity(0.55), in: Capsule())
                                        .padding(4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start cleaning from \(asset.formattedDate)")
                        .contextMenu {
                            NavigationLink(
                                value: AppRoute.swipe(viewModel.deckSource(startingAt: asset))
                            ) {
                                Label("Start cleaning from here", systemImage: "play.circle")
                            }
                        } preview: {
                            ThumbnailPreview(asset: asset, service: service)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private func load() async {
        await viewModel.loadIfNeeded(using: service, sizes: sizes)
    }

}
