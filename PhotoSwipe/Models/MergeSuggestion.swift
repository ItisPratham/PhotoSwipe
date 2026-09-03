import Foundation

/// Two person clusters whose averaged face embeddings sit close enough that
/// they may be the same person. Proposed, never applied on its own: the
/// People screen asks "Same person?" and a "No" is remembered per pair.
struct MergeSuggestion: Identifiable, Hashable, Sendable {
    let a: PersonCluster
    let b: PersonCluster
    /// Cosine similarity of the two centroids.
    let similarity: Float

    var id: String { Self.pairKey(a.personID, b.personID) }

    /// Order-independent key for a pair, used for persisted dismissals.
    static func pairKey(_ x: String, _ y: String) -> String {
        x < y ? "\(x)|\(y)" : "\(y)|\(x)"
    }
}
