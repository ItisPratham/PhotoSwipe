import Foundation
import SwiftData

/// SwiftData record for one detected face. Keyed uniquely by `faceID`
/// (`"<localIdentifier>#<faceIndex>"`) so a re-scan updates in place and the
/// index stays incremental. `embedding` is the L2-normalized 512-d AdaFace
/// vector stored as `Data` (~2 KB); `personID` links the face to its cluster.
/// Lives in its own on-disk store (see `FaceStore`) — deliberately never
/// UserDefaults, since embeddings are large.
@Model
final class FaceRow {
    @Attribute(.unique) var faceID: String
    var localIdentifier: String
    var faceIndex: Int
    var embedding: Data
    var quality: Float

    /// Normalized face bounding box in the source image (0...1). Used to crop a
    /// tight cover thumbnail for the person's cluster.
    var bboxX: Double
    var bboxY: Double
    var bboxWidth: Double
    var bboxHeight: Double

    /// The cluster this face belongs to (a `PersonRow.personID`), or nil until
    /// clustering assigns it.
    var personID: String?

    /// The user hid this as a stray / non-face: excluded from its cluster and
    /// from future re-clustering.
    var isIgnored: Bool

    var scannedAt: Date

    init(faceID: String,
         localIdentifier: String,
         faceIndex: Int,
         embedding: Data,
         quality: Float,
         bboxX: Double,
         bboxY: Double,
         bboxWidth: Double,
         bboxHeight: Double,
         personID: String? = nil,
         isIgnored: Bool = false,
         scannedAt: Date) {
        self.faceID = faceID
        self.localIdentifier = localIdentifier
        self.faceIndex = faceIndex
        self.embedding = embedding
        self.quality = quality
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxWidth = bboxWidth
        self.bboxHeight = bboxHeight
        self.personID = personID
        self.isIgnored = isIgnored
        self.scannedAt = scannedAt
    }
}
