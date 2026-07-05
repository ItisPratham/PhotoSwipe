import SwiftUI

/// Pushed list of the user's albums. Tapping an album pushes the swipe deck
/// scoped to that album's photos via an `AppRoute.swipe` value. All the
/// existing engine rules still apply — videos excluded, reviewed IDs skipped,
/// decisions and deletes routed through the same stores.
struct AlbumListView: View {
    let service: PhotoLibraryService

    @State private var albums: [PhotoLibraryService.AlbumSummary] = []
    @State private var isLoading = true

    var body: some View {
        content
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading albums…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if albums.isEmpty {
            emptyState
        } else {
            List {
                ForEach(albums) { album in
                    NavigationLink(value: AppRoute.swipe(DeckSource(scope: .album(album.collection)))) {
                        AlbumRow(album: album, service: service)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(album.title), \(album.count) photos")
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No albums")
                .font(.headline)
            Text("Create an album in the Photos app to swipe through it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        albums = await service.fetchUserAlbums()
        isLoading = false
    }
}

private struct AlbumRow: View {
    let album: PhotoLibraryService.AlbumSummary
    let service: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            cover
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(album.count) \(album.count == 1 ? "photo" : "photos")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .task(id: album.id) {
            guard let cover = album.cover else { return }
            for await next in service.imageStream(
                for: cover,
                targetSize: CGSize(width: 160, height: 160)
            ) {
                image = next
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if album.cover == nil {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
