import Foundation

/// The three primary destinations in the bottom tab bar. Backed by an enum
/// rather than a raw index so `TabView(selection:)` reads clearly and tabs can
/// be selected programmatically (e.g. jumping to Clean from a People CTA).
enum AppTab: Hashable {
    case clean
    case browse
    case people
}
