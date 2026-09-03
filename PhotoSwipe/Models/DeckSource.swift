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
        /// A specific set of assets (a duplicate group), by localIdentifier.
        case duplicateGroup([String])
        /// A person cluster's photos. With `preservesOrder` the deck follows
        /// the caller's sequence exactly (a day's photos newest→oldest, or
        /// from a tapped photo backward); otherwise PhotoKit's oldest-first
        /// creation-date order applies.
        case person([String], preservesOrder: Bool)
        /// "More like this": the feature-print neighbours of `seedID`, in
        /// ascending-distance order (preserved in the deck).
        case similar(seedID: String, ids: [String])
        /// A Browse category's photos (ids resolved by `CategoriesViewModel`),
        /// oldest first.
        case category(AssetCategory, ids: [String])

        static func == (lhs: Scope, rhs: Scope) -> Bool {
            switch (lhs, rhs) {
            case (.allPhotos, .allPhotos):
                return true
            case (.album(let a), .album(let b)):
                // PHAssetCollection identity travels via localIdentifier.
                return a.localIdentifier == b.localIdentifier
            case (.duplicateGroup(let a), .duplicateGroup(let b)):
                return a == b
            case (.person(let a, let pa), .person(let b, let pb)):
                return a == b && pa == pb
            case (.similar(let sa, let a), .similar(let sb, let b)):
                return sa == sb && a == b
            case (.category(let ca, let a), .category(let cb, let b)):
                return ca == cb && a == b
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
            case .duplicateGroup(let ids):
                hasher.combine("duplicateGroup")
                hasher.combine(ids)
            case .person(let ids, let preservesOrder):
                hasher.combine("person")
                hasher.combine(ids)
                hasher.combine(preservesOrder)
            case .similar(let seedID, let ids):
                hasher.combine("similar")
                hasher.combine(seedID)
                hasher.combine(ids)
            case .category(let category, let ids):
                hasher.combine("category")
                hasher.combine(category)
                hasher.combine(ids)
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

    /// Deck ordering. `.chronological` is the default oldest-first stream;
    /// `.largestFirst` sorts by on-device byte size (desc) to surface space
    /// hogs. `startFrom` is ignored under `.largestFirst`.
    enum Order: Hashable {
        case chronological
        case largestFirst
    }

    /// Media-subtype filter applied at the predicate layer, on top of
    /// `media`. Nil = no restriction. Subtypes are PhotoKit metadata, so the
    /// filter is exact and costs nothing.
    enum Subtype: Hashable {
        case screenshots
    }

    var scope: Scope
    var media: Media
    var order: Order
    var subtype: Subtype?
    /// Include only assets whose creationDate is on/after this date. Used by
    /// the browse flow to start from a chosen photo or day, moving forward
    /// in time toward the newest.
    var startFrom: Date?
    /// For a duplicate-group deck: the localIdentifier of the shot suggested as
    /// the keeper, badged in the deck. Nil for every other source.
    var suggestedKeeperID: String?

    init(scope: Scope = .allPhotos,
         media: Media = .photos,
         order: Order = .chronological,
         subtype: Subtype? = nil,
         startFrom: Date? = nil,
         suggestedKeeperID: String? = nil) {
        self.scope = scope
        self.media = media
        self.order = order
        self.subtype = subtype
        self.startFrom = startFrom
        self.suggestedKeeperID = suggestedKeeperID
    }

    /// Default source — the full chronological photo library.
    static let allPhotos = DeckSource(scope: .allPhotos, media: .photos, startFrom: nil)

    /// Every screenshot in the library, oldest first.
    static let screenshots = DeckSource(scope: .allPhotos, media: .photos, subtype: .screenshots)

    /// Builds the deck for reviewing a duplicate group, keeper badged.
    static func duplicateGroup(_ group: DuplicateGroup) -> DeckSource {
        DeckSource(scope: .duplicateGroup(group.assetIDs),
                   media: .all,
                   suggestedKeeperID: group.suggestedKeeperID)
    }

    /// Builds the deck scoped to a person cluster's photos. `preservesOrder`
    /// keeps the caller's sequence (the person-detail entry points sort
    /// deliberately); pass false for an unordered id set — e.g. the People
    /// grid's context menu, whose ids come from a Set — to get oldest-first.
    static func person(_ photoIDs: [String], preservesOrder: Bool = true) -> DeckSource {
        DeckSource(scope: .person(photoIDs, preservesOrder: preservesOrder), media: .all)
    }

    /// Builds the "More like this" deck for a seed photo. Neighbours arrive
    /// nearest-first from `SimilarPhotosFinder` and the deck keeps that order.
    static func similar(to seedID: String, ids: [String]) -> DeckSource {
        DeckSource(scope: .similar(seedID: seedID, ids: ids), media: .all)
    }

    /// Builds the deck for a Browse category, oldest first.
    static func category(_ category: AssetCategory, ids: [String]) -> DeckSource {
        DeckSource(scope: .category(category, ids: ids), media: .photos)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(scope)
        hasher.combine(media)
        hasher.combine(order)
        hasher.combine(subtype)
        hasher.combine(startFrom)
        hasher.combine(suggestedKeeperID)
    }
}
