import SwiftUI

/// Home screen. Presents the primary "Start swiping" CTA, an entry into
/// Albums, and a day-grouped grid of the user's library (Photos.app shape).
/// Tapping a thumbnail or a day header pushes the swipe deck starting at
/// that photo/day. The overflow menu here hosts Activity, tutorial, support,
/// and the destructive reset action.
struct BrowseView: View {
    let service: PhotoLibraryService
    @ObservedObject var store: ReviewStore
    @ObservedObject var stats: StatsStore

    /// Called once the initial library fetch completes — lets RootView's launch
    /// splash wait for the grid before crossfading in.
    private let onLoaded: () -> Void

    @StateObject private var viewModel = BrowseViewModel()

    @State private var showTutorial = false
    @State private var showStats = false
    @State private var showResetConfirm = false

    @Environment(\.openURL) private var openURL

    init(service: PhotoLibraryService,
         store: ReviewStore,
         stats: StatsStore,
         onLoaded: @escaping () -> Void = {}) {
        self.service = service
        self.store = store
        self.stats = stats
        self.onLoaded = onLoaded
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 4
    )

    var body: some View {
        content
            .navigationTitle("PhotoSwipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    overflowMenu
                }
            }
            .task {
                await viewModel.load(using: service)
                onLoaded()
            }
            .sheet(isPresented: $showTutorial) {
                OnboardingView { showTutorial = false }
            }
            .sheet(isPresented: $showStats) {
                StatsView(stats: stats)
            }
            .alert("Reset review history?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    store.resetAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All photos you've kept or marked for deletion will re-enter the deck. Your Photos library isn't touched — this only clears PhotoSwipe's tracking.")
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
                startSwipingCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                albumsRow
                    .padding(.horizontal, 16)

                videosRow
                    .padding(.horizontal, 16)

                biggestFilesRow
                    .padding(.horizontal, 16)

                duplicatesRow
                    .padding(.horizontal, 16)

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
                                HStack(spacing: 8) {
                                    Text(Self.dayFormatter.string(from: section.id))
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.regularMaterial)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Start swiping from \(Self.dayFormatter.string(from: section.id))")
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.visible)
    }

    // MARK: - CTA card

    private var startSwipingCard: some View {
        NavigationLink(value: AppRoute.swipe(.allPhotos)) {
            HStack(spacing: 16) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start swiping")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Oldest first")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start swiping the whole library, oldest first")
    }

    // MARK: - Albums row

    private var albumsRow: some View {
        NavigationLink(value: AppRoute.albums) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("Albums")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browse albums")
    }

    // MARK: - Videos row

    private var videosRow: some View {
        NavigationLink(
            value: AppRoute.swipe(
                DeckSource(scope: .allPhotos, media: .videos)
            )
        ) {
            HStack(spacing: 12) {
                Image(systemName: "video")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("Videos")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Swipe through videos, oldest first")
    }

    // MARK: - Biggest files row

    private var biggestFilesRow: some View {
        NavigationLink(
            value: AppRoute.swipe(
                DeckSource(scope: .allPhotos, media: .all, order: .largestFirst)
            )
        ) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.headline)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Biggest files")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Photos & videos, largest first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Swipe through your biggest files, largest first")
    }

    // MARK: - Duplicates row

    private var duplicatesRow: some View {
        NavigationLink(value: AppRoute.duplicates) {
            HStack(spacing: 12) {
                Image(systemName: "square.on.square.dashed")
                    .font(.headline)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicates")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Find bursts & near-identical shots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Find duplicate photos")
    }

    // MARK: - Overflow menu

    private var overflowMenu: some View {
        Menu {
            Section {
                Button {
                    showStats = true
                } label: {
                    Label("Activity", systemImage: "chart.bar")
                }
            }

            Section {
                Button {
                    showTutorial = true
                } label: {
                    Label("Show tutorial", systemImage: "questionmark.circle")
                }

                Button {
                    openSupport()
                } label: {
                    Label("Contact support", systemImage: "envelope")
                }
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset review history",
                          systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More")
        }
    }

    private func openSupport() {
        guard let url = ContactLink.makeSupportURL() else { return }
        openURL(url)
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

private struct Thumbnail: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: asset.id) {
                image = nil
                for await next in service.imageStream(
                    for: asset,
                    targetSize: CGSize(width: 240, height: 240)
                ) {
                    image = next
                }
            }
    }
}

/// Full-size preview shown when long-pressing a browse thumbnail. Loads a
/// much larger image than the cell so the user can actually see the photo
/// before deciding whether to start swiping there.
private struct ThumbnailPreview: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(width: 280, height: 280)
            }
        }
        .task(id: asset.id) {
            for await next in service.imageStream(
                for: asset,
                targetSize: CGSize(width: 1200, height: 1200)
            ) {
                image = next
            }
        }
    }
}
