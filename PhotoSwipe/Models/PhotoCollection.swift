import Foundation

/// A Browse-first asset collection. The value carries enough information to
/// fetch and title the grid while the resolved ordering stays in its view
/// model and is handed to the deck through `DeckSource.selection`.
enum PhotoCollection: Hashable {
    case videos
    case screenshots
    case biggestFiles
    case shared(with: String, ids: [String])

    var title: String {
        switch self {
        case .videos:
            "Videos"
        case .screenshots:
            "Screenshots"
        case .biggestFiles:
            "Biggest files"
        case .shared(let name, _):
            name == "Unnamed" ? "Photos together" : "With \(name)"
        }
    }

    var systemImage: String {
        switch self {
        case .videos:
            "video"
        case .screenshots:
            "camera.viewfinder"
        case .biggestFiles:
            "arrow.up.arrow.down.circle"
        case .shared:
            "person.2"
        }
    }

    var source: DeckSource {
        switch self {
        case .videos:
            DeckSource(scope: .allPhotos, media: .videos)
        case .screenshots:
            .screenshots
        case .biggestFiles:
            DeckSource(scope: .allPhotos, media: .all, order: .largestFirst)
        case .shared(_, let ids):
            .selection(ids)
        }
    }

    var singularItem: String {
        switch self {
        case .videos:
            "video"
        case .screenshots, .shared:
            "photo"
        case .biggestFiles:
            "item"
        }
    }

    var pluralItem: String {
        switch self {
        case .videos:
            "videos"
        case .screenshots, .shared:
            "photos"
        case .biggestFiles:
            "items"
        }
    }

    var needsSizeOrdering: Bool {
        if case .biggestFiles = self { return true }
        return false
    }
}
