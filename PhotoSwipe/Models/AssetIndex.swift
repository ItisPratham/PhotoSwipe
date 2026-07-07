import Foundation
import SwiftData

/// SwiftData record for one scanned asset: its Vision feature print (archived
/// `VNFeaturePrintObservation`), on-device byte size, and when it was scanned.
/// Keyed uniquely by `localIdentifier` so a re-scan updates in place and the
/// index stays incremental. Lives in its own on-disk store (see `IndexStore`) —
/// deliberately *not* UserDefaults, since embeddings are large.
@Model
final class AssetIndex {
    @Attribute(.unique) var localIdentifier: String
    var featurePrint: Data
    var byteSize: Int64
    var scannedAt: Date

    init(localIdentifier: String, featurePrint: Data, byteSize: Int64, scannedAt: Date) {
        self.localIdentifier = localIdentifier
        self.featurePrint = featurePrint
        self.byteSize = byteSize
        self.scannedAt = scannedAt
    }
}
