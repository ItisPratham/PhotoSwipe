import Foundation
import SwiftData

/// Sendable snapshot of an indexed asset, safe to hand across actor boundaries
/// (the `@Model` object itself is not Sendable).
struct IndexedAsset: Sendable, Hashable {
    let localIdentifier: String
    let featurePrint: Data
    let byteSize: Int64
}

/// The on-disk SwiftData container for the duplicate index. Created once and
/// shared; the schema is fixed, so a failure here is unrecoverable and fatal.
enum IndexContainer {
    static let shared: ModelContainer = {
        let schema = Schema([AssetIndex.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
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

    /// Local identifiers already indexed — lets the scan skip them.
    func indexedIdentifiers() throws -> Set<String> {
        let records = try modelContext.fetch(FetchDescriptor<AssetIndex>())
        return Set(records.map(\.localIdentifier))
    }

    /// Number of indexed assets — tells the UI whether a first scan has run.
    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<AssetIndex>())
    }

    /// Every indexed asset, as Sendable snapshots, for grouping.
    func allIndexed() throws -> [IndexedAsset] {
        try modelContext.fetch(FetchDescriptor<AssetIndex>()).map {
            IndexedAsset(localIdentifier: $0.localIdentifier,
                         featurePrint: $0.featurePrint,
                         byteSize: $0.byteSize)
        }
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
            if let record = existing.first {
                record.featurePrint = item.featurePrint
                record.byteSize = item.byteSize
                record.scannedAt = scannedAt
            } else {
                modelContext.insert(
                    AssetIndex(localIdentifier: item.localIdentifier,
                               featurePrint: item.featurePrint,
                               byteSize: item.byteSize,
                               scannedAt: scannedAt)
                )
            }
        }
        try modelContext.save()
    }

    /// Drops rows whose asset is no longer present in the library.
    func purge(keeping keepIDs: Set<String>) throws {
        let records = try modelContext.fetch(FetchDescriptor<AssetIndex>())
        var changed = false
        for record in records where !keepIDs.contains(record.localIdentifier) {
            modelContext.delete(record)
            changed = true
        }
        if changed { try modelContext.save() }
    }
}
