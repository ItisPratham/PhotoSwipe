import Foundation
import SwiftData

/// Marks an asset as having been through the face scan — including assets with
/// zero detected faces — so an incremental re-scan skips them instead of
/// re-detecting every time. Keyed uniquely by `localIdentifier`.
@Model
final class ScannedAssetRow {
    @Attribute(.unique) var localIdentifier: String
    var scannedAt: Date

    init(localIdentifier: String, scannedAt: Date) {
        self.localIdentifier = localIdentifier
        self.scannedAt = scannedAt
    }
}
