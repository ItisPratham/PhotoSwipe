import Foundation
import SwiftData

/// Sendable snapshot of an indexed asset, safe to hand across actor boundaries
/// (the `@Model` object itself is not Sendable). Carries the decoded vector,
/// ready for matching; empty when the print couldn't be decoded.
struct IndexedAsset: Sendable, Hashable {
    let localIdentifier: String
    let vector: [Float]
    let byteSize: Int64
    /// Quality signals for the keeper score; nil when not measured yet.
    var sharpness: Float? = nil
    var aestheticScore: Float? = nil
    /// Categorize-pass results, set when the scan ran with categories on.
    var categories: CategoryMeasurement? = nil
    /// Present only when this scan successfully produced a MobileCLIP vector.
    var searchEmbedding: Data? = nil
}

/// What the categorize pass measures for one asset; written to the index
/// columns of the same name. `labels` is the encoded `identifier:confidence`
/// list (see `CategorySignals.encode`).
struct CategoryMeasurement: Sendable, Hashable {
    var labels: String
    var textCoverage: Float
    var isUtility: Bool?
    var hasAnimal: Bool
    var sharpness: Float?
    var aestheticScore: Float?
}

/// The only search columns retrieval needs. Duplicate/category snapshots do
/// not include this type, so SwiftData can leave embedding blobs faulted.
struct SearchEmbeddingSnapshot: Sendable, Hashable {
    let localIdentifier: String
    let embedding: Data
}

/// In-process invalidation for retrieval caches. `libraryVersion` does not
/// advance for a background enrichment write, so searches also key on this.
enum SearchIndexRevision {
    private static let lock = NSLock()
    private static var value = 0

    static var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func advance() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

/// Where the app's SwiftData stores live. Each index gets its **own file**:
/// SwiftData's default `ModelConfiguration` points every container at the same
/// `Application Support/default.store`, so two containers with different
/// schemas would migrate that one file back and forth and drop each other's
/// tables on every open.
enum LocalStores {
    /// A SwiftData store file, `<name>.store`.
    static func url(named name: String) -> URL {
        fileURL(named: "\(name).store")
    }

    /// Any app-owned file in Application Support (the review-decision JSON,
    /// for example). Creates the directory on first use.
    static func fileURL(named fileName: String) -> URL {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: fileName)
    }

    /// Removes the legacy shared `default.store` (and its SQLite sidecars) left
    /// behind by earlier builds. Its contents are undefined after the schema
    /// ping-pong, and both indexes rebuild incrementally, so nothing of value
    /// is lost. Runs at most once per launch.
    static let removeLegacyDefaultStore: Void = {
        let base = URL.applicationSupportDirectory.appending(path: "default.store").path
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }
    }()
}

/// The on-disk SwiftData container for the duplicate index. Created once and
/// shared; the schema is fixed, so a failure here is unrecoverable and fatal.
enum IndexContainer {
    static let shared: ModelContainer = {
        _ = LocalStores.removeLegacyDefaultStore
        let schema = Schema([AssetIndex.self, IndexMetadata.self])
        let configuration = ModelConfiguration(schema: schema,
                                               url: LocalStores.url(named: "duplicates"))
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create the duplicate-index store: \(error)")
        }
    }()
}

/// Background-isolated gateway to the index. `@ModelActor` gives it its own
/// `ModelContext` off the main actor, so scanning a large library never touches
/// the UI context. All methods return Sendable snapshots rather than model
/// objects. Writes are incremental (upsert by unique `localIdentifier`); rows
/// for assets that no longer exist are purged.
@ModelActor
actor IndexStore {

    /// The one index actor every screen uses. Sharing it serialises all
    /// reads and writes through a single ModelContext, so a scan still
    /// unwinding after its screen was popped can never race a fresh scan on
    /// a second context. It is built on a background thread on purpose: a
    /// `@ModelActor` created on the main thread does its work on the main
    /// thread, and a 50k-row read there is a visible hang.
    static let shared: IndexStore = DispatchQueue.global(qos: .userInitiated).sync {
        IndexStore(modelContainer: IndexContainer.shared)
    }

    /// Local identifiers already indexed — lets the scan skip them. Reads the
    /// identifier column only; the vectors stay on disk.
    func indexedIdentifiers() throws -> Set<String> {
        var descriptor = FetchDescriptor<AssetIndex>()
        descriptor.propertiesToFetch = [\.localIdentifier]
        return Set(try modelContext.fetch(descriptor).map(\.localIdentifier))
    }

    /// Number of indexed assets — tells the UI whether a first scan has run.
    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<AssetIndex>())
    }

    /// Identifiers that have a print but haven't been through the categorize
    /// pass. Identifier column only.
    func uncategorizedIdentifiers() throws -> [String] {
        var descriptor = FetchDescriptor<AssetIndex>(predicate: #Predicate { $0.categorizedAt == nil })
        descriptor.propertiesToFetch = [\.localIdentifier]
        return try modelContext.fetch(descriptor).map(\.localIdentifier)
    }

    /// Number of rows the categorize pass has covered — tells the UI whether
    /// the Categories section has anything to show yet.
    func categorizedCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<AssetIndex>(predicate: #Predicate { $0.categorizedAt != nil }))
    }

    func pendingSearchEmbeddingIdentifiers() throws -> [String] {
        var descriptor = FetchDescriptor<AssetIndex>(predicate: #Predicate { $0.searchEmbedding == nil })
        descriptor.propertiesToFetch = [\.localIdentifier]
        return try modelContext.fetch(descriptor).map(\.localIdentifier)
    }

    func searchEmbeddingCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<AssetIndex>(predicate: #Predicate { $0.searchEmbedding != nil }))
    }

    func searchEmbeddingSnapshots() throws -> [SearchEmbeddingSnapshot] {
        var descriptor = FetchDescriptor<AssetIndex>(predicate: #Predicate { $0.searchEmbedding != nil })
        descriptor.propertiesToFetch = [\.localIdentifier, \.searchEmbedding]
        return try modelContext.fetch(descriptor).compactMap { row in
            row.searchEmbedding.map { SearchEmbeddingSnapshot(localIdentifier: row.localIdentifier, embedding: $0) }
        }
    }

    /// Clears only search-specific columns when the installed model pair has
    /// changed. Duplicate vectors and category signals remain untouched.
    func prepareSearchEmbeddings(modelFingerprint: String) throws {
        let key = "search"
        let metadata = try modelContext.fetch(FetchDescriptor<IndexMetadata>(
            predicate: #Predicate { $0.key == key }
        )).first ?? {
            let new = IndexMetadata()
            modelContext.insert(new)
            return new
        }()
        guard metadata.searchModelFingerprint != modelFingerprint else { return }

        let rows = try modelContext.fetch(FetchDescriptor<AssetIndex>())
        for row in rows {
            row.searchEmbedding = nil
            row.embeddedAt = nil
        }
        metadata.searchModelFingerprint = modelFingerprint
        try modelContext.save()
        SearchIndexRevision.advance()
    }

    /// Writes successful image embeddings only. A nil or failed embedding is
    /// intentionally absent from this dictionary and stays retryable.
    func applySearchEmbeddings(_ embeddings: [String: Data], at date: Date) throws {
        guard !embeddings.isEmpty else { return }
        let ids = Array(embeddings.keys)
        var start = 0
        var changed = false
        while start < ids.count {
            let chunk = Array(ids[start..<min(ids.count, start + 500)])
            let rows = try modelContext.fetch(FetchDescriptor<AssetIndex>(
                predicate: #Predicate { chunk.contains($0.localIdentifier) }
            ))
            for row in rows {
                guard let data = embeddings[row.localIdentifier],
                      data.count == SearchEmbedder.embeddingByteCount else { continue }
                row.searchEmbedding = data
                row.embeddedAt = date
                changed = true
            }
            start += chunk.count
        }
        if changed {
            try modelContext.save()
            SearchIndexRevision.advance()
        }
    }

    /// Category signals for every categorized row, without the vectors.
    /// `screenshotIDs` marks rows whose asset is a system screenshot.
    func categorySignals(screenshotIDs: Set<String>) throws -> [CategorySignals] {
        var descriptor = FetchDescriptor<AssetIndex>(predicate: #Predicate { $0.categorizedAt != nil })
        descriptor.propertiesToFetch = [
            \.localIdentifier, \.labels, \.textCoverage, \.sharpness, \.isUtility, \.hasAnimal,
        ]
        return try modelContext.fetch(descriptor).map { row in
            CategorySignals(localIdentifier: row.localIdentifier,
                            labels: CategorySignals.decode(labels: row.labels),
                            textCoverage: row.textCoverage,
                            sharpness: row.sharpness,
                            isUtility: row.isUtility,
                            hasAnimal: row.hasAnimal,
                            isScreenshot: screenshotIDs.contains(row.localIdentifier))
        }
    }

    /// Writes categorize-pass results onto existing rows (by identifier) and
    /// stamps `categorizedAt`. Rows that no longer exist are skipped.
    func applyCategories(_ measurements: [String: CategoryMeasurement], at date: Date) throws {
        let ids = Array(measurements.keys)
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(ids.count, start + 500)])
            let rows = try modelContext.fetch(FetchDescriptor<AssetIndex>(
                predicate: #Predicate { chunk.contains($0.localIdentifier) }))
            for row in rows {
                guard let m = measurements[row.localIdentifier] else { continue }
                Self.write(m, to: row, at: date)
            }
            start += chunk.count
        }
        try modelContext.save()
    }

    private static func write(_ m: CategoryMeasurement, to row: AssetIndex, at date: Date) {
        row.labels = m.labels
        row.textCoverage = m.textCoverage
        row.isUtility = m.isUtility
        row.hasAnimal = m.hasAnimal
        if let sharpness = m.sharpness { row.sharpness = sharpness }
        if let aesthetic = m.aestheticScore { row.aestheticScore = aesthetic }
        row.categorizedAt = date
    }

    /// On-device byte size per indexed asset, for the size cache. Reads only
    /// the identifier and size columns.
    func byteSizes() throws -> [String: Int64] {
        var descriptor = FetchDescriptor<AssetIndex>()
        descriptor.propertiesToFetch = [\.localIdentifier, \.byteSize]
        let rows = try modelContext.fetch(descriptor)
        return Dictionary(rows.map { ($0.localIdentifier, $0.byteSize) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Every indexed asset, as Sendable snapshots, for grouping. Rows written
    /// before 4.2 still hold an archived observation; they are decoded here
    /// once, the raw vector written back, and the archive dropped, so the
    /// unarchive cost is paid a single time per row rather than per regroup.
    func allIndexed() throws -> [IndexedAsset] {
        let rows = try modelContext.fetch(FetchDescriptor<AssetIndex>())
        var result: [IndexedAsset] = []
        result.reserveCapacity(rows.count)
        var converted = 0
        for row in rows {
            let vector: [Float]
            if let data = row.vector {
                vector = FeaturePrintCodec.floats(from: data)
            } else {
                vector = FeaturePrintCodec.vector(fromArchived: row.featurePrint)
                row.vector = FeaturePrintCodec.data(from: vector)
                row.featurePrint = Data()
                converted += 1
                if converted % 500 == 0 { try modelContext.save() }
            }
            result.append(IndexedAsset(localIdentifier: row.localIdentifier,
                                       vector: vector,
                                       byteSize: row.byteSize,
                                       sharpness: row.sharpness,
                                       aestheticScore: row.aestheticScore))
        }
        if converted % 500 != 0 { try modelContext.save() }
        return result
    }

    /// Inserts or updates a batch, then saves.
    func upsert(_ items: [IndexedAsset], scannedAt: Date) throws {
        var changedSearchEmbeddings = false
        for item in items {
            let id = item.localIdentifier
            let existing = try modelContext.fetch(
                FetchDescriptor<AssetIndex>(
                    predicate: #Predicate { $0.localIdentifier == id }
                )
            )
            let vectorData = FeaturePrintCodec.data(from: item.vector)
            if let record = existing.first {
                record.vector = vectorData
                record.featurePrint = Data()
                record.byteSize = item.byteSize
                record.scannedAt = scannedAt
                record.sharpness = item.sharpness
                record.aestheticScore = item.aestheticScore
                if let searchEmbedding = item.searchEmbedding {
                    record.searchEmbedding = searchEmbedding
                    record.embeddedAt = scannedAt
                    changedSearchEmbeddings = true
                }
                if let categories = item.categories {
                    Self.write(categories, to: record, at: scannedAt)
                }
            } else {
                let record = AssetIndex(localIdentifier: item.localIdentifier,
                                        vector: vectorData,
                                        byteSize: item.byteSize,
                                        scannedAt: scannedAt,
                                        sharpness: item.sharpness,
                                        aestheticScore: item.aestheticScore)
                if let categories = item.categories {
                    Self.write(categories, to: record, at: scannedAt)
                }
                if let searchEmbedding = item.searchEmbedding {
                    record.searchEmbedding = searchEmbedding
                    record.embeddedAt = scannedAt
                    changedSearchEmbeddings = true
                }
                modelContext.insert(record)
            }
        }
        try modelContext.save()
        if changedSearchEmbeddings { SearchIndexRevision.advance() }
    }

    /// Drops rows whose asset is no longer present in the library. Reads the
    /// identifier column only.
    func purge(keeping keepIDs: Set<String>) throws {
        var descriptor = FetchDescriptor<AssetIndex>()
        descriptor.propertiesToFetch = [\.localIdentifier]
        let records = try modelContext.fetch(descriptor)
        var changed = false
        for record in records where !keepIDs.contains(record.localIdentifier) {
            modelContext.delete(record)
            changed = true
        }
        if changed {
            try modelContext.save()
            SearchIndexRevision.advance()
        }
    }
}
