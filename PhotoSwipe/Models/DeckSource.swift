import Foundation
import Photos

/// Describes what feeds the swipe deck. The engine downstream is unchanged —
/// reviewed-skipping, video-exclusion, oldest-first ordering, undo, marks, and
/// batch delete all apply the same way regardless of source. This just gates
/// which assets enter the deck in the first place.
struct DeckSource: Equatable {
    enum Scope: Equatable {
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
}

// MARK: - Persistence

/// A Codable snapshot of a DeckSource. PHAssetCollection isn't Codable so we
/// travel the collection's `localIdentifier` and re-resolve on restore. If the
/// collection has since been deleted or renamed away we fall back to
/// `.allPhotos` rather than crashing.
extension DeckSource {
    private struct Storable: Codable {
        enum StoredScope: Codable {
            case allPhotos
            case album(String)
        }
        let scope: StoredScope
        let startFrom: Date?
    }

    private var storable: Storable {
        switch scope {
        case .allPhotos:
            return Storable(scope: .allPhotos, startFrom: startFrom)
        case .album(let collection):
            return Storable(scope: .album(collection.localIdentifier),
                            startFrom: startFrom)
        }
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(storable)
    }

    static func decoded(from data: Data) -> DeckSource? {
        guard let stored = try? JSONDecoder().decode(Storable.self, from: data) else {
            return nil
        }
        switch stored.scope {
        case .allPhotos:
            return DeckSource(scope: .allPhotos, startFrom: stored.startFrom)
        case .album(let localIdentifier):
            let result = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [localIdentifier],
                options: nil
            )
            guard let collection = result.firstObject else { return nil }
            return DeckSource(scope: .album(collection),
                              startFrom: stored.startFrom)
        }
    }
}
