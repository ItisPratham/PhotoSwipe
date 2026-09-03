import SwiftUI

/// A square library thumbnail that loads thumbnail-first via the service's
/// opportunistic image stream, so it never blocks on an iCloud download. Used
/// in the Browse grid and the person day grid. When the asset has been judged
/// in the deck, a small badge in the bottom-trailing corner shows the
/// decision: green check for kept, red bin for marked for deletion.
struct Thumbnail: View {
    let asset: PhotoAsset
    let service: PhotoLibraryService
    var decision: ReviewDecision? = nil

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
            .overlay(alignment: .bottomTrailing) {
                if let decision {
                    DecisionBadge(decision: decision)
                        .padding(4)
                }
            }
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

/// The kept / marked corner badge. Filled symbol on a white disc so it reads
/// on any photo.
struct DecisionBadge: View {
    let decision: ReviewDecision

    var body: some View {
        Image(systemName: decision == .kept ? "checkmark.circle.fill" : "trash.circle.fill")
            .font(.system(size: 13.5, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, decision == .kept ? Color.green : Color.red)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .accessibilityLabel(decision == .kept ? "Kept" : "Marked for deletion")
    }
}
