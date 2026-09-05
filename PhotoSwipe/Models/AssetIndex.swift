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

    /// Laplacian-variance sharpness of the 256 px scan thumbnail
    /// (`ImageQuality.sharpness`). Optional so existing stores migrate in
    /// place; nil for rows indexed before 5.0 until a later pass fills it.
    var sharpness: Float?
    /// Vision aesthetics score (iOS 18+), same nil semantics.
    var aestheticScore: Float?

    /// Categorize-pass columns (see `CategorySignals`). All optional: nil
    /// until the pass has run for this row, which `categorizedAt` marks.
    var labels: String?
    var textCoverage: Float?
    var isUtility: Bool?
    var hasAnimal: Bool?
    var categorizedAt: Date?

    /// MobileCLIP image embedding, encoded as 512 little-endian Float16s.
    /// Optional columns keep existing duplicate stores migratable, and avoid
    /// loading these comparatively large blobs in duplicate/category reads.
    var searchEmbedding: Data?
    var embeddedAt: Date?

    init(localIdentifier: String, vector: Data, byteSize: Int64, scannedAt: Date,
         sharpness: Float? = nil, aestheticScore: Float? = nil) {
        self.localIdentifier = localIdentifier
        self.featurePrint = Data()
        self.vector = vector
        self.byteSize = byteSize
        self.scannedAt = scannedAt
        self.sharpness = sharpness
        self.aestheticScore = aestheticScore
    }
}

/// Small per-store metadata. The image/text model fingerprint prevents a
/// changed MobileCLIP pair from mixing vectors from incompatible spaces.
@Model
final class IndexMetadata {
    @Attribute(.unique) var key: String
    var searchModelFingerprint: String?

    init(key: String = "search") {
        self.key = key
    }
}
