import Photos
import SwiftUI

/// Geometry shared by the deck cards and the deck's prefetcher. Both derive
/// the pixel size they ask PhotoKit for from the same numbers, so an image
/// prefetched for a card is a cache hit when that card mounts and requests it.
enum DeckCardMetrics {
    /// Padding `SwipeView` puts around each card inside the deck slot.
    static let horizontalInset: CGFloat = 20
    static let verticalInset: CGFloat = 28

    /// Pixel size to request for a card laid out at `cardSize` points.
    static func pixelSize(forCardSize cardSize: CGSize) -> CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: cardSize.width * scale, height: cardSize.height * scale)
    }

    /// Pixel size for a card that will sit inside a deck slot of `slot`
    /// points, i.e. the slot minus the insets. This is what `SwipeView` uses
    /// to prefetch, and it must equal what the card computes from its own
    /// geometry.
    static func pixelSize(forSlot slot: CGSize) -> CGSize {
        pixelSize(forCardSize: CGSize(
            width: max(0, slot.width - 2 * horizontalInset),
            height: max(0, slot.height - 2 * verticalInset)
        ))
    }
}

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
            .background(Theme.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.deckCard))
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Photo from \(asset.formattedDate)"))
            .task(id: asset.id) {
                await loadImage(targetSize: DeckCardMetrics.pixelSize(forCardSize: proxy.size))
            }
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
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
}
