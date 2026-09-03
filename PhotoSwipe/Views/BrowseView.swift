import SwiftUI

/// The Browse tab. Surfaces quick entries into Albums, Videos, Biggest files,
/// and Duplicates, followed by a day-grouped grid of the user's library
/// (Photos.app shape). Tapping a thumbnail or a day header pushes the swipe
/// deck starting at that photo/day. Settings live behind the tab's gear (see
/// `AppTabView`); the default oldest-first deck is the Clean tab.
struct BrowseView: View {
    @ObservedObject var service: PhotoLibraryService
    /// Observed so the kept / marked badges update after a deck session.
    @ObservedObject var store: ReviewStore

    @StateObject private var viewModel = BrowseViewModel()
    /// Warms thumbnails around the visible rows. Sized to match
    /// `Thumbnail`'s request exactly, or the cache would miss.
    @State private var prefetcher = GridPrefetcher(targetSize: Thumbnail.requestSize)

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 4
    )

    var body: some View {
        content
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                prefetcher.attach(service)
                await viewModel.loadIfNeeded(using: service)
            }
            .onChange(of: service.libraryVersion) { _, _ in
                Task { await viewModel.loadIfNeeded(using: service) }
            }
            .onChange(of: viewModel.generation, initial: true) { _, _ in
                prefetcher.update(assets: viewModel.flatAssets)
            }
            .onDisappear { prefetcher.release() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView("Loading library…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            scroll
        }
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                HStack(spacing: 12) {
                    NavigationLink(value: AppRoute.albums) {
                        BrowseEntryRow(title: "Albums", systemImage: "rectangle.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Browse albums")

                    NavigationLink(
                        value: AppRoute.swipe(DeckSource(scope: .allPhotos, media: .videos))
                    ) {
                        BrowseEntryRow(title: "Videos", systemImage: "video")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Swipe through videos, oldest first")
                }
                .padding(.horizontal, Theme.Spacing.screenMargin)
                .padding(.top, 12)

                NavigationLink(
                    value: AppRoute.swipe(DeckSource(scope: .allPhotos, media: .all, order: .largestFirst))
                ) {
                    BrowseEntryRow(title: "Biggest files",
                                   subtitle: "Photos & videos, largest first",
                                   systemImage: "arrow.up.arrow.down.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Swipe through your biggest files, largest first")
                .padding(.horizontal, Theme.Spacing.screenMargin)

                NavigationLink(value: AppRoute.duplicates) {
                    BrowseEntryRow(title: "Duplicates",
                                   subtitle: "Find bursts & near-identical shots",
                                   systemImage: "square.on.square.dashed")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Find duplicate photos")
                .padding(.horizontal, Theme.Spacing.screenMargin)

                if viewModel.sections.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    ForEach(viewModel.sections) { section in
                        Section {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(Array(section.assets.enumerated()), id: \.element.id) { offset, asset in
                                    NavigationLink(
                                        value: AppRoute.swipe(
                                            DeckSource(scope: .allPhotos,
                                                       startFrom: asset.creationDate)
                                        )
                                    ) {
                                        Thumbnail(asset: asset,
                                                  service: service,
                                                  decision: store.decision(for: asset.id))
                                    }
                                    .buttonStyle(.plain)
                                    .onAppear { prefetcher.cellAppeared(section.startIndex + offset) }
                                    .onDisappear { prefetcher.cellDisappeared(section.startIndex + offset) }
                                    .accessibilityLabel("Start swiping from \(asset.formattedDate)")
                                    .contextMenu {
                                        NavigationLink(
                                            value: AppRoute.swipe(
                                                DeckSource(scope: .allPhotos,
                                                           startFrom: asset.creationDate)
                                            )
                                        ) {
                                            Label("Start swiping from here",
                                                  systemImage: "play.circle")
                                        }
                                    } preview: {
                                        ThumbnailPreview(asset: asset, service: service)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        } header: {
                            NavigationLink(
                                value: AppRoute.swipe(
                                    DeckSource(scope: .allPhotos,
                                               startFrom: section.id)
                                )
                            ) {
                                HStack(spacing: 6) {
                                    Text(section.id, format: .dateTime.month(.wide).day().year())
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.screenMargin)
                                .padding(.vertical, 6)
                                .background(Color.black)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Start swiping from \(section.id.formatted(.dateTime.month(.wide).day().year()))")
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.visible)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No photos to browse")
                .font(.headline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}
