import Foundation

/// What a swipe *up* does to the current card, on top of counting as a keep.
/// Chosen in Settings; persisted in `UserDefaults` under `storageKey`.
enum SwipeUpAction: Equatable {
    /// Mark the photo as a favorite in the Photos library.
    case favorite

    static let storageKey = "PhotoSwipe.swipeUpAction"

    var title: String {
        switch self {
        case .favorite: return "Favorite"
        }
    }

    var systemImage: String {
        switch self {
        case .favorite: return "heart.fill"
        }
    }
}
