import SwiftUI

/// Full-size preview shown when long-pressing a thumbnail (the Browse grid and
/// the delete-review grid). Loads a much larger image than the grid cell so the
/// photo is legible before the user acts on it.
struct ThumbnailPreview: View {
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
