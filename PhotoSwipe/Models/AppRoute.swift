import Foundation

enum AppRoute: Hashable {
    case albums
    case duplicates
    case swipe(DeckSource)
}
