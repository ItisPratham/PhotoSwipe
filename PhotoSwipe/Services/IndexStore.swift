import Foundation
import SwiftData

/// Sendable snapshot of an indexed asset, safe to hand across actor boundaries
/// (the `@Model` object itself is not Sendable). Carries the decoded vector,
/// ready for matching; empty when the print couldn't be decoded.
struct IndexedAsset: Sendable, Hashable {
    let localIdentifier: String
    let vector: [Float]
    let byteSize: Int64
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
        let schema = Schema([AssetIndex.self])
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
                                       byteSize: row.byteSize))
        }
        if converted % 500 != 0 { try modelContext.save() }
        return result
    }

    /// Inserts or updates a batch, then saves.
    func upsert(_ items: [IndexedAsset], scannedAt: Date) throws {
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
            } else {
                modelContext.insert(
                    AssetIndex(localIdentifier: item.localIdentifier,
                               vector: vectorData,
                               byteSize: item.byteSize,
                               scannedAt: scannedAt)
                )
            }
        }
        try modelContext.save()
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
        if changed { try modelContext.save() }
    }
}
