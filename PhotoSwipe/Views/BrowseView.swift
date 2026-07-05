import SwiftUI

/// Sheet-presented browse screen. Photos grouped by day, newest-first — the
/// same shape as Photos.app so users know what they're looking at. Tapping
/// a thumbnail starts the deck at that photo; tapping a day header starts
/// at the beginning of that day. In both cases the deck moves forward in
/// time toward the newest photos, and previously reviewed assets are still
/// skipped by the shared deck engine downstream.
struct BrowseView: View {
    let service: PhotoLibraryService
    let onSelect: (DeckSource) -> Void

    @StateObject private var viewModel = BrowseViewModel()
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            content
                .navigationTitle("Browse")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
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
        } else if viewModel.sections.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.sections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(section.assets) { asset in
                                Button {
                                    select(from: asset)
                                } label: {
                                    Thumbnail(asset: asset, service: service)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Start swiping from \(asset.formattedDate)")
                                .contextMenu {
                                    Button {
                                        select(from: asset)
                                    } label: {
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
                        Button {
                            select(dayStart: section.id)
                        } label: {
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
            .padding(.bottom, 16)
        }
        .scrollIndicators(.visible)
    }

    private func select(from asset: PhotoAsset) {
        onSelect(DeckSource(scope: .allPhotos, startFrom: asset.creationDate))
    }

    private func select(dayStart: Date) {
        onSelect(DeckSource(scope: .allPhotos, startFrom: dayStart))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
