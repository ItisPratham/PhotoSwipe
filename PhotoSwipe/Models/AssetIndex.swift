import Foundation
import SwiftData

/// SwiftData record for one scanned asset: its Vision feature print as a raw
/// float vector, on-device byte size, and when it was scanned. Keyed uniquely
/// by `localIdentifier` so a re-scan updates in place and the index stays
/// incremental. Lives in its own on-disk store (see `IndexStore`) —
/// deliberately *not* UserDefaults, since prints are large.
@Model
final class AssetIndex {
    @Attribute(.unique) var localIdentifier: String

    /// Archived `VNFeaturePrintObservation`, the storage format up to 4.1.
    /// Emptied once `vector` has been filled from it, so old rows shrink on
    /// their first read after the upgrade. Always empty for new rows.
    var featurePrint: Data

    /// The print's element buffer as little-endian Float32s. Nil only for a
    /// row written before 4.2 that hasn't been converted yet; `IndexStore`
    /// converts lazily on read. Added as optional so SwiftData migrates the
    /// existing store in place.
    var vector: Data?

    var byteSize: Int64
    var scannedAt: Date

    init(localIdentifier: String, vector: Data, byteSize: Int64, scannedAt: Date) {
        self.localIdentifier = localIdentifier
        self.featurePrint = Data()
        self.vector = vector
        self.byteSize = byteSize
        self.scannedAt = scannedAt
    }
}
