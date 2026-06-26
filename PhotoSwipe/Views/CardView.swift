import Photos
import SwiftUI

/// Single photo card with a date label overlay. Loads its image
/// thumbnail-first via the service's opportunistic stream so the card
/// never blocks waiting on an iCloud download.
struct CardView: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                imageLayer
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                dateLabel
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
            .task(id: asset.id) {
                await loadImage(targetSize: targetPixelSize(from: proxy.size))
            }
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dateLabel: some View {
        Text(asset.formattedDate)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(16)
    }

    private func loadImage(targetSize: CGSize) async {
        image = nil
        for await next in service.imageStream(for: asset, targetSize: targetSize) {
            image = next
        }
    }

    private func targetPixelSize(from size: CGSize) -> CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
