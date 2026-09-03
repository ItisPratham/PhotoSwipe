import CoreGraphics
import Foundation

/// Sendable UI aggregate for one person: identity, optional name, and cover,
/// plus the distinct photos containing the cluster's faces. Derived by grouping
/// `FaceRow`s by `personID` and joining the `PersonRow` metadata.
///
/// We cluster faces, not photos, so `photoIDs` is the distinct set of
/// `localIdentifier`s among the cluster's faces — a photo with several people
/// appears under each of their clusters.
struct PersonCluster: Identifiable, Sendable, Hashable {
    let personID: String
    let name: String?
    let coverAssetID: String?
    let coverFaceID: String?
    /// Bounding box of the cover face in Vision coordinate space (bottom-left
    /// origin, y-axis up, normalized 0…1). Nil until a face scan has run.
    let coverBoundingBox: CGRect?
    let photoIDs: [String]
    let faceCount: Int
    let isHidden: Bool

    var id: String { personID }
    var photoCount: Int { photoIDs.count }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Unnamed"
    }

    // Hand-written only because CGRect isn't Hashable. Equality covers every
    // field on purpose: SwiftUI uses it to decide whether a cell showing this
    // value needs re-rendering, so a personID-only comparison left photo
    // counts stale after a reload. `Identifiable.id` still carries the
    // stable identity for ForEach and navigation.
    func hash(into hasher: inout Hasher) {
        hasher.combine(personID)
        hasher.combine(name)
        hasher.combine(coverAssetID)
        hasher.combine(coverFaceID)
        hasher.combine(photoIDs)
        hasher.combine(faceCount)
        hasher.combine(isHidden)
        if let box = coverBoundingBox {
            hasher.combine(box.origin.x)
            hasher.combine(box.origin.y)
            hasher.combine(box.size.width)
            hasher.combine(box.size.height)
        }
    }

    static func == (lhs: PersonCluster, rhs: PersonCluster) -> Bool {
        lhs.personID == rhs.personID
            && lhs.name == rhs.name
            && lhs.coverAssetID == rhs.coverAssetID
            && lhs.coverFaceID == rhs.coverFaceID
            && lhs.coverBoundingBox == rhs.coverBoundingBox
            && lhs.photoIDs == rhs.photoIDs
            && lhs.faceCount == rhs.faceCount
            && lhs.isHidden == rhs.isHidden
    }
}
