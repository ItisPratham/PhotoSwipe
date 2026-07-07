import Foundation

/// A set of near-identical assets found by the duplicate scan (a camera burst,
/// or shots the Vision feature-print judged similar). `suggestedKeeperID` is
/// the highest-quality member, offered as the one to keep when reviewing the
/// group in the deck.
struct DuplicateGroup: Identifiable, Hashable {
    /// Stable identity — the keeper's localIdentifier, which is unique per group.
    let id: String
    let assetIDs: [String]
    let suggestedKeeperID: String

    var count: Int { assetIDs.count }
}
