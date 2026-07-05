import Foundation
import Photos

/// Describes what feeds the swipe deck. The engine downstream is unchanged —
/// reviewed-skipping, video-exclusion, oldest-first ordering, undo, marks, and
/// batch delete all apply the same way regardless of source. This just gates
/// which assets enter the deck in the first place.
struct DeckSource: Hashable {
    enum Scope: Hashable {
        case allPhotos
        case album(PHAssetCollection)

        static func == (lhs: Scope, rhs: Scope) -> Bool {
            switch (lhs, rhs) {
            case (.allPhotos, .allPhotos):
                return true
            case (.album(let a), .album(let b)):
                // PHAssetCollection identity travels via localIdentifier.
                return a.localIdentifier == b.localIdentifier
            default:
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .allPhotos:
                hasher.combine("allPhotos")
            case .album(let collection):
                hasher.combine("album")
                hasher.combine(collection.localIdentifier)
            }
        }
    }

    var scope: Scope
    /// Include only assets whose creationDate is on/after this date. Used by
    /// the browse flow to start from a chosen photo or day, moving forward
    /// in time toward the newest.
    var startFrom: Date?

    init(scope: Scope = .allPhotos, startFrom: Date? = nil) {
        self.scope = scope
        self.startFrom = startFrom
    }

    /// Default source — the full chronological library.
    static let allPhotos = DeckSource(scope: .allPhotos, startFrom: nil)

    func hash(into hasher: inout Hasher) {
        hasher.combine(scope)
        hasher.combine(startFrom)
    }
}
