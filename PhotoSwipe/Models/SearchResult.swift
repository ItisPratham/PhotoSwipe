import Foundation

struct SearchResult: Identifiable, Hashable, Sendable {
    let assetID: String
    let score: Float

    var id: String { assetID }
}
