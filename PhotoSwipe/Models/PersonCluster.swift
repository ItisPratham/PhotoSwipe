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
    let photoIDs: [String]
    let faceCount: Int
    let isHidden: Bool

    var id: String { personID }
    var photoCount: Int { photoIDs.count }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Unnamed"
    }
}
