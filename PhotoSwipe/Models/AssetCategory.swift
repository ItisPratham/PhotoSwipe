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

    func hasAny(_ identifiers: Set<String>) -> Bool {
        labels.contains { identifiers.contains($0.0) }
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
    case receipts, documents, whiteboards, food, pets, memes, blurry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .receipts: return "Receipts"
        case .documents: return "Documents"
        case .whiteboards: return "Whiteboards"
        case .food: return "Food"
        case .pets: return "Pets"
        case .memes: return "Memes"
        case .blurry: return "Blurry"
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
        case .blurry: return "The least sharp 10% of your photos"
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
        case .blurry: return "camera.metering.unknown"
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

    /// Whether `signals` fall into this category. `blurThreshold` is the
    /// library's 10th-percentile sharpness, computed by the categorize pass.
    func matches(_ s: CategorySignals, blurThreshold: Float?) -> Bool {
        switch self {
        case .receipts:
            return s.hasAny(Self.receiptLabels)
                || (s.isUtility == true && (s.textCoverage ?? 0) >= 0.30 && !s.hasAny(Self.whiteboardLabels))
        case .documents:
            return s.hasAny(Self.documentLabels)
                || (s.textCoverage ?? 0) >= 0.35 && !s.isScreenshot && !s.hasAny(Self.whiteboardLabels)
        case .whiteboards:
            return s.hasAny(Self.whiteboardLabels)
        case .food:
            return s.hasAny(Self.foodLabels)
        case .pets:
            return s.hasAnimal == true || s.hasAny(Self.petLabels)
        case .memes:
            guard !s.isScreenshot else { return false }
            return s.hasAny(Self.memeLabels) || (s.textCoverage ?? 0) >= 0.25
        case .blurry:
            guard let sharpness = s.sharpness, let blurThreshold else { return false }
            return sharpness < blurThreshold
        }
    }

    /// The first matching category in declaration order, or nil.
    static func primary(for s: CategorySignals, blurThreshold: Float?) -> AssetCategory? {
        allCases.first { $0.matches(s, blurThreshold: blurThreshold) }
    }
}
