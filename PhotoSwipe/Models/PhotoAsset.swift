import Foundation
import Photos

/// Thin value-type wrapper around `PHAsset`. We key all persisted state on
/// `localIdentifier`, so identity travels with the photo across fetches.
struct PhotoAsset: Identifiable, Equatable {
    let phAsset: PHAsset

    var id: String { phAsset.localIdentifier }
    var creationDate: Date? { phAsset.creationDate }

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
