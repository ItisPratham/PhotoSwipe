import SwiftUI

/// Sheet-presented browse screen. Photos grouped by day, newest-first — the
/// same shape as Photos.app so users know what they're looking at.
///
/// M2 renders the grid only; tapping to start swiping from a specific photo
/// or day lands in M3, where SwipeView provides an `onSelect` handler that
/// swaps the deck's DeckSource. For now the callback is unused.
struct BrowseView: View {
    let service: PhotoLibraryService

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
                                Thumbnail(asset: asset, service: service)
                            }
                        }
                        .padding(.horizontal, 12)
                    } header: {
                        Text(Self.dayFormatter.string(from: section.id))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.regularMaterial)
                    }
                }
            }
            .padding(.bottom, 16)
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
