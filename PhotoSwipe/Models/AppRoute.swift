import Foundation

enum AppRoute: Hashable {
    case albums
    case duplicates
    /// The Categories screen (opt-in sort, counts per category).
    case categories
    /// One category's Browse-style grid; ids resolved by `CategoriesViewModel`.
    case category(AssetCategory, ids: [String])
    /// Browse-first grid for Videos, Screenshots, Biggest files, and shared
    /// photos selected through a person's "Also with" action.
    case collection(PhotoCollection)
    case swipe(DeckSource)
}
