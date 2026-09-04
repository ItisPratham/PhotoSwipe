import SwiftUI

/// The Browse tab. Surfaces quick entries into Albums, Videos, Screenshots,
/// Biggest files, and Duplicates, followed by a day-grouped grid of the user's library
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
    @State private var scrollSectionID: Date?
    @State private var fastScrollIndex = 0

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 4
    )

    var body: some View {
        content
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            // Thicker bar material: photos scrolling under the bar, just
            // above the pinned day header, blur out more heavily.
            .toolbarBackground(.thickMaterial, for: .navigationBar)
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
                if viewModel.onThisDayCount > 0 {
                    NavigationLink(value: AppRoute.swipe(.onThisDay)) {
                        BrowseEntryRow(title: "On this day",
                                       subtitle: onThisDaySubtitle,
                                       systemImage: "calendar.badge.clock")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Swipe through photos taken on this day in earlier years")
                    .padding(.horizontal, Theme.Spacing.screenMargin)
                    .padding(.top, 12)
                }

                HStack(spacing: 12) {
                    NavigationLink(value: AppRoute.albums) {
                        BrowseEntryRow(title: "Albums", systemImage: "rectangle.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Browse albums")

                    NavigationLink(
                        value: AppRoute.collection(.videos)
                    ) {
                        BrowseEntryRow(title: "Videos", systemImage: "video")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Browse videos")
                }
                .padding(.horizontal, Theme.Spacing.screenMargin)
                .padding(.top, 12)

                NavigationLink(value: AppRoute.collection(.screenshots)) {
                    BrowseEntryRow(title: "Screenshots",
                                   subtitle: screenshotsSubtitle,
                                   systemImage: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse screenshots")
                .padding(.horizontal, Theme.Spacing.screenMargin)

                NavigationLink(
                    value: AppRoute.collection(.biggestFiles)
                ) {
                    BrowseEntryRow(title: "Biggest files",
                                   subtitle: "Photos & videos, largest first",
                                   systemImage: "arrow.up.arrow.down.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse your biggest files, largest first")
                .padding(.horizontal, Theme.Spacing.screenMargin)

                NavigationLink(value: AppRoute.duplicates) {
                    BrowseEntryRow(title: "Duplicates",
                                   subtitle: "Find bursts & near-identical shots",
                                   systemImage: "square.on.square.dashed")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Find duplicate photos")
                .padding(.horizontal, Theme.Spacing.screenMargin)

                NavigationLink(value: AppRoute.categories) {
                    BrowseEntryRow(title: "Categories",
                                   subtitle: "Receipts, documents, food, pets, and more",
                                   systemImage: "square.grid.2x2")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort photos into categories")
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
                        .id(section.id)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: $scrollSectionID, anchor: .top)
        .onChange(of: scrollSectionID) { _, id in
            guard let id,
                  let index = viewModel.sections.firstIndex(where: { $0.id == id })
            else { return }
            fastScrollIndex = index
        }
        .overlay(alignment: .leading) {
            if viewModel.sections.count > 1 {
                PhotoFastScroller(
                    itemCount: viewModel.sections.count,
                    currentIndex: fastScrollIndex,
                    onSelect: scroll(to:)
                )
            }
        }
    }

    private func scroll(to index: Int) {
        guard viewModel.sections.indices.contains(index) else { return }
        fastScrollIndex = index
        scrollSectionID = viewModel.sections[index].id
    }

    private var onThisDaySubtitle: String {
        let n = viewModel.onThisDayCount, y = viewModel.onThisDayYears
        return "\(n) \(n == 1 ? "photo" : "photos") across \(y) \(y == 1 ? "year" : "years")"
    }

    private var screenshotsSubtitle: String {
        switch viewModel.screenshotCount {
        case 0: return "None in your library"
        case 1: return "1 screenshot"
        case let n: return "\(n) screenshots"
        }
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
