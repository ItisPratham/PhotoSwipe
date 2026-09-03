import SwiftUI

/// The Browse tab. Surfaces quick entries into Albums, Videos, Biggest files,
/// and Duplicates, followed by a day-grouped grid of the user's library
/// (Photos.app shape). Tapping a thumbnail or a day header pushes the swipe
/// deck starting at that photo/day. Settings live behind the tab's gear (see
/// `AppTabView`); the default oldest-first deck is the Clean tab.
struct BrowseView: View {
    let service: PhotoLibraryService

    @StateObject private var viewModel = BrowseViewModel()
    @State private var scrolledDay: Date?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 4
    )

    var body: some View {
        content
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.load(using: service)
            }
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
                                ForEach(section.assets) { asset in
                                    NavigationLink(
                                        value: AppRoute.swipe(
                                            DeckSource(scope: .allPhotos,
                                                       startFrom: asset.creationDate)
                                        )
                                    ) {
                                        Thumbnail(asset: asset, service: service)
                                    }
                                    .buttonStyle(.plain)
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
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.quaternary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.Spacing.screenMargin)
                                .padding(.vertical, 6)
                                .background(Color.white)
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
        .scrollPosition(id: $scrolledDay, anchor: .top)
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
