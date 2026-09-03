import Foundation

/// What a swipe *up* does to the current card, on top of counting as a keep.
/// Chosen in Settings and persisted in `UserDefaults` (`kindKey`, plus the
/// album's id and title when an album is chosen).
enum SwipeUpAction: Equatable {
    /// Mark the photo as a favorite in the Photos library.
    case favorite
    /// Add the photo to a user album, chosen once and remembered.
    case album(id: String, title: String)

    static let kindKey = "PhotoSwipe.swipeUpAction"
    static let albumIDKey = "PhotoSwipe.swipeUpAlbumID"
    static let albumTitleKey = "PhotoSwipe.swipeUpAlbumTitle"

    /// Reads the persisted choice. Falls back to favorite when the album mode
    /// was chosen but no album was ever picked.
    static func load(from defaults: UserDefaults = .standard) -> SwipeUpAction {
        guard defaults.string(forKey: kindKey) == "album",
              let id = defaults.string(forKey: albumIDKey),
              let title = defaults.string(forKey: albumTitleKey)
        else { return .favorite }
        return .album(id: id, title: title)
    }

    func save(to defaults: UserDefaults = .standard) {
        switch self {
        case .favorite:
            defaults.set("favorite", forKey: Self.kindKey)
        case .album(let id, let title):
            defaults.set("album", forKey: Self.kindKey)
            defaults.set(id, forKey: Self.albumIDKey)
            defaults.set(title, forKey: Self.albumTitleKey)
        }
    }

    /// Stamp / accessibility title on the card.
    var title: String {
        switch self {
        case .favorite: return "Favorite"
        case .album(_, let title): return title
        }
    }

    var systemImage: String {
        switch self {
        case .favorite: return "heart.fill"
        case .album: return "rectangle.stack.badge.plus"
        }
    }
}
