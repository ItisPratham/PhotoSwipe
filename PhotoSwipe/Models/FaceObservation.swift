import CoreGraphics
import Foundation

/// Sendable snapshot of a detected face, safe to hand across actor boundaries
/// (the `@Model` `FaceRow` is not Sendable). Serves double duty: as the
/// pipeline's output (a freshly computed `embedding`, `personID` nil) and as a
/// read back from `FaceStore` (carrying its cluster assignment).
struct FaceObservation: Sendable, Hashable, Identifiable {
    let localIdentifier: String
    let faceIndex: Int
    /// L2-normalized 512-d AdaFace embedding.
    let embedding: [Float]
    let quality: Float
    /// Normalized face bounding box in Vision coordinate space (bottom-left
    /// origin, y-axis up, all values in 0…1).
    let boundingBox: CGRect
    var personID: String?

    /// Stable unique id across the whole library.
    var id: String { "\(localIdentifier)#\(faceIndex)" }
    var faceID: String { id }
}
