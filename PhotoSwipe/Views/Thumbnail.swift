import SwiftUI

/// A square library thumbnail that loads thumbnail-first via the service's
/// opportunistic image stream, so it never blocks on an iCloud download. Used
/// in the Browse grid.
struct Thumbnail: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    /// The pixel size every thumbnail asks for. Shared with `GridPrefetcher`
    /// so a prefetched image is a cache hit for the cell.
    static let requestSize = CGSize(width: 240, height: 240)

    @State private var image: UIImage?

    var body: some View {
        Theme.cardSurface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
            .task(id: asset.id) {
                image = nil
                for await next in service.imageStream(
                    for: asset,
                    targetSize: Self.requestSize
                ) {
                    image = next
                }
            }
    }
}
