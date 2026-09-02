import Foundation

/// A newly-formed person cluster the clusterer wants persisted: its generated
/// `personID` and the cover face chosen for it. Sendable so it crosses into the
/// `FaceStore` actor.
struct PersonSeed: Sendable, Hashable {
    let personID: String
    let coverAssetID: String?
    let coverFaceID: String?
}
