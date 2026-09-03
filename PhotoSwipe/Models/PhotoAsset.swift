import Foundation
import Photos

/// Thin value-type wrapper around `PHAsset`. We key all persisted state on
/// `localIdentifier`, so identity travels with the photo across fetches.
struct PhotoAsset: Identifiable, Equatable, @unchecked Sendable {
    let phAsset: PHAsset

    var id: String { phAsset.localIdentifier }
    var creationDate: Date? { phAsset.creationDate }

    /// Live Photos report `.image`, so they stay in the photo deck and render
    /// as stills — only true movies count as video here.
    var isVideo: Bool { phAsset.mediaType == .video }

    /// Favorite flag as of the fetch. A swipe-up that favorites the photo
    /// doesn't refresh this wrapper; the card has already advanced by then.
    var isFavorite: Bool { phAsset.isFavorite }

    /// Set by the system for images captured with the screenshot gesture.
    /// Metadata, not a visual guess — see the Screenshots browse entry.
    var isScreenshot: Bool { phAsset.mediaSubtypes.contains(.photoScreenshot) }

    /// Play length in seconds. Zero for stills.
    var duration: TimeInterval { phAsset.duration }

    /// Native pixel dimensions — used to shape the video preview to its aspect.
    var pixelSize: CGSize {
        CGSize(width: phAsset.pixelWidth, height: phAsset.pixelHeight)
    }

    /// Pixel count — a cheap "quality" proxy for suggesting a group's keeper.
    var pixelArea: Int { phAsset.pixelWidth * phAsset.pixelHeight }

    /// Identifies a camera-burst set. Assets sharing this belong to one burst
    /// and can be grouped without any ML.
    var burstIdentifier: String? { phAsset.burstIdentifier }

    /// `m:ss` badge text for the video card. Empty for stills.
    var formattedDuration: String {
        guard isVideo else { return "" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var formattedDate: String {
        guard let date = creationDate else { return "Unknown date" }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        lhs.id == rhs.id
    }
}
