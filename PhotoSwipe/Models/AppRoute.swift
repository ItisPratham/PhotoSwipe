import Foundation

enum AppRoute: Hashable {
    case albums
    case duplicates
    /// The Categories screen (opt-in sort, counts per category).
    case categories
    /// One category's Browse-style grid; ids resolved by `CategoriesViewModel`.
    case category(AssetCategory, ids: [String])
    case swipe(DeckSource)
}
