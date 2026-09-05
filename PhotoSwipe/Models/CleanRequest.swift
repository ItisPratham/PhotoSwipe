import Foundation

/// Where a `photoswipe://clean` link lands. The widget, the Shortcuts intent,
/// and the URL parser all share these cases, so a new entry cannot be added to
/// one without the others seeing it. The mapping to an actual screen lives in
/// `AppRoute` — this file is compiled into the widget too, and must not drag
/// the app's route graph in with it.
enum CleanEntry: String, CaseIterable, Sendable {
    case screenshots
    case biggest
    case duplicates

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .biggest: "Biggest files"
        case .duplicates: "Duplicates"
        }
    }
}

/// A validated request to open the Clean tab, parsed from `photoswipe://clean`
/// with an optional `entry` query item. One parser for every source: the
/// widget's link, the Shortcuts intent, and anything typed into Safari.
///
/// Anything else — another scheme, another host, an `entry` value that is not
/// a known case — is rejected rather than silently treated as a plain Clean
/// link, so a typo doesn't quietly open the wrong deck.
struct CleanRequest: Equatable {
    let entry: CleanEntry?

    static let scheme = "photoswipe"

    init(entry: CleanEntry? = nil) {
        self.entry = entry
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == "clean",
              components.path.isEmpty || components.path == "/"
        else { return nil }

        let items = components.queryItems ?? []
        guard items.allSatisfy({ $0.name == "entry" }), items.count <= 1 else { return nil }
        guard let raw = items.first?.value else {
            self.entry = nil
            return
        }
        guard let entry = CleanEntry(rawValue: raw.lowercased()) else { return nil }
        self.entry = entry
    }

    /// The canonical link, used by the widget and by `StartCleaningIntent`.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "clean"
        components.queryItems = entry.map { [URLQueryItem(name: "entry", value: $0.rawValue)] }
        return components.url!
    }
}
