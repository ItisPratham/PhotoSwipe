import Foundation
import Photos

/// Describes what feeds the swipe deck. The engine downstream is unchanged —
/// reviewed-skipping, oldest-first ordering, undo, marks, and batch delete all
/// apply the same way regardless of source. This just gates which assets enter
/// the deck in the first place: the `scope`, the `media` kind, and an optional
/// `startFrom` cutoff.
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

    /// Which media kind feeds the deck. Defaults to `.photos` so every existing
    /// entry point stays photos-only; videos enter only when explicitly asked
    /// for (the Videos browse entry).
    enum Media: Hashable {
        case photos
        case videos
        case all
    }

    var scope: Scope
    var media: Media
    /// Include only assets whose creationDate is on/after this date. Used by
    /// the browse flow to start from a chosen photo or day, moving forward
    /// in time toward the newest.
    var startFrom: Date?

    init(scope: Scope = .allPhotos,
         media: Media = .photos,
         startFrom: Date? = nil) {
        self.scope = scope
        self.media = media
        self.startFrom = startFrom
    }

    /// Default source — the full chronological photo library.
    static let allPhotos = DeckSource(scope: .allPhotos, media: .photos, startFrom: nil)

    func hash(into hasher: inout Hasher) {
        hasher.combine(scope)
        hasher.combine(media)
        hasher.combine(startFrom)
    }
}
