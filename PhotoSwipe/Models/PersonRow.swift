import Foundation
import SwiftData

/// SwiftData record for a person cluster's user-facing metadata: an optional
/// user-given `name`, a cover photo/face, and a hidden flag. The cluster's
/// membership lives on `FaceRow.personID`, so names, merges, and hides persist
/// across re-scans (new faces join existing `personID`s). Keyed uniquely by a
/// generated `personID` (a UUID string).
@Model
final class PersonRow {
    @Attribute(.unique) var personID: String
    var name: String?
    /// The photo whose face represents this person in lists.
    var coverAssetID: String?
    /// The specific face used for the cover crop.
    var coverFaceID: String?
    /// The user hid this whole cluster from the People list.
    var isHidden: Bool
    var createdAt: Date
    /// Person ids the user said are *not* this person (merge suggestions the
    /// user declined). Written on both rows of the pair. Optional so existing
    /// stores migrate in place.
    var dismissedMergeIDs: [String]?

    init(personID: String,
         name: String? = nil,
         coverAssetID: String? = nil,
         coverFaceID: String? = nil,
         isHidden: Bool = false,
         createdAt: Date) {
        self.personID = personID
        self.name = name
        self.coverAssetID = coverAssetID
        self.coverFaceID = coverFaceID
        self.isHidden = isHidden
        self.createdAt = createdAt
    }
}
