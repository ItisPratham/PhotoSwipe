import Foundation

/// The per-photo signals the categorize pass measures on the scan thumbnail
/// (see `LibraryIndexService`), stored as optional `AssetIndex` columns and
/// read back as this snapshot. Everything here is nil-tolerant: a row that
/// predates the pass has nils and belongs to no category.
struct CategorySignals: Sendable, Hashable {
    let localIdentifier: String
    /// Vision scene labels that passed the precision gate, best first, as
    /// `identifier:confidence` pairs decoded from the stored column.
    let labels: [(String, Float)]
    /// Fraction of the image area covered by detected text rectangles, 0…1.
    let textCoverage: Float?
    /// Laplacian-variance sharpness on the 256 px thumbnail.
    let sharpness: Float?
    /// Vision (iOS 18) judged the image a utility shot: receipt, document, etc.
    let isUtility: Bool?
    /// `VNRecognizeAnimalsRequest` found a cat or dog.
    let hasAnimal: Bool?
    /// True for `PHAssetMediaSubtype.photoScreenshot`; those have their own
    /// Browse entry and are kept out of Memes.
    let isScreenshot: Bool

    func label(_ identifier: String) -> Float? {
        labels.first { $0.0 == identifier }?.1
    }

    /// Whether any of `identifiers` was reported at or above `minConfidence`.
    func hasAny(_ identifiers: Set<String>, minConfidence: Float = 0.45) -> Bool {
        labels.contains { identifiers.contains($0.0) && $0.1 >= minConfidence }
    }

    // Hashable/Equatable by identity; the tuple array isn't Hashable itself.
    static func == (lhs: CategorySignals, rhs: CategorySignals) -> Bool {
        lhs.localIdentifier == rhs.localIdentifier
    }
    func hash(into hasher: inout Hasher) { hasher.combine(localIdentifier) }

    /// Storage form of `labels`: `identifier:confidence` pairs, comma-joined.
    static func encode(labels: [(String, Float)]) -> String {
        labels.map { "\($0.0):\(String(format: "%.3f", $0.1))" }.joined(separator: ",")
    }

    static func decode(labels: String?) -> [(String, Float)] {
        guard let labels, !labels.isEmpty else { return [] }
        return labels.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let confidence = Float(parts[1]) else { return nil }
            return (String(parts[0]), confidence)
        }
    }
}

/// The Browse "Categories" entries. Each is a rule over `CategorySignals`;
/// first match wins in `AssetCategory.allCases` order, so a receipt is a
/// receipt before it is a document, and a document is never a meme. The label
/// identifiers are the exact ones `VNClassifyImageRequest` reports.
enum AssetCategory: String, CaseIterable, Hashable, Identifiable {
    case receipts, documents, whiteboards, food, pets, memes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .receipts: return "Receipts"
        case .documents: return "Documents"
        case .whiteboards: return "Whiteboards"
        case .food: return "Food"
        case .pets: return "Pets"
        case .memes: return "Memes"
        }
    }

    var subtitle: String {
        switch self {
        case .receipts: return "Bills, invoices, and till receipts"
        case .documents: return "Pages, letters, notes, and prints"
        case .whiteboards: return "Whiteboards and chalkboards"
        case .food: return "Meals, drinks, and desserts"
        case .pets: return "Cats and dogs"
        case .memes: return "Text-heavy images and saved screenshots"
        }
    }

    var systemImage: String {
        switch self {
        case .receipts: return "doc.text"
        case .documents: return "doc.plaintext"
        case .whiteboards: return "rectangle.and.pencil.and.ellipsis"
        case .food: return "fork.knife"
        case .pets: return "pawprint"
        case .memes: return "text.bubble"
        }
    }

    // MARK: - Rules

    private static let receiptLabels: Set<String> = ["receipt", "ticket", "credit_card"]
    private static let documentLabels: Set<String> = [
        "document", "printed_page", "newspaper", "magazine", "book", "handwriting",
        "sticky_note", "chart", "diagram", "map", "checkbook",
    ]
    private static let whiteboardLabels: Set<String> = ["whiteboard", "chalkboard", "flipchart"]
    private static let foodLabels: Set<String> = ["food", "seafood", "dessert", "frozen_dessert", "drink", "tea_drink"]
    private static let petLabels: Set<String> = ["cat", "adult_cat", "dog", "bulldog", "sheepdog"]
    private static let memeLabels: Set<String> = ["screenshot"]

    /// Whether `signals` fall into this category. Tuned toward precision: a
    /// label alone needs a clear confidence, and
    /// text coverage on its own (which fires on foliage and patterns too)
    /// never makes a document. Better to miss a few than to fill a category
    /// with wrong photos.
    func matches(_ s: CategorySignals) -> Bool {
        let text = s.textCoverage ?? 0
        switch self {
        case .receipts:
            // Only with the label: "utility + text" alone is more often a
            // document than a receipt, and documents is checked next.
            return s.hasAny(Self.receiptLabels, minConfidence: 0.4)
        case .documents:
            return s.hasAny(Self.documentLabels, minConfidence: 0.5)
                || (s.hasAny(Self.documentLabels, minConfidence: 0.3) && text >= 0.3)
                || (s.isUtility == true && text >= 0.45 && !s.isScreenshot
                    && !s.hasAny(Self.whiteboardLabels))
        case .whiteboards:
            return s.hasAny(Self.whiteboardLabels, minConfidence: 0.5)
        case .food:
            return s.hasAny(Self.foodLabels, minConfidence: 0.55)
        case .pets:
            return s.hasAnimal == true || s.hasAny(Self.petLabels, minConfidence: 0.6)
        case .memes:
            guard !s.isScreenshot else { return false }
            return s.hasAny(Self.memeLabels, minConfidence: 0.5)
                || (text >= 0.45 && s.isUtility != false)
        }
    }

    /// The first matching category in declaration order, or nil.
    static func primary(for s: CategorySignals) -> AssetCategory? {
        allCases.first { $0.matches(s) }
    }
}
