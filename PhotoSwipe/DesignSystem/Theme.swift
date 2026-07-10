import SwiftUI

/// Shared design constants so corner rounding, spacing, and card surfaces stay
/// uniform across the app and can be tuned in one place instead of being
/// re-specified per view.
enum Theme {
    /// Corner radii for the app's rounded surfaces.
    enum Radius {
        static let thumbnail: CGFloat = 6
        static let card: CGFloat = 12
        static let deckCard: CGFloat = 24
    }

    /// Standard paddings and margins.
    enum Spacing {
        /// Leading/trailing margin for full-width content on a screen.
        static let screenMargin: CGFloat = 16
        /// Interior padding of a tappable card row.
        static let cardPadding: CGFloat = 16
    }

    /// The standard elevated card surface, adapting to light/dark automatically.
    static let cardSurface = Color(.secondarySystemBackground)
}
