import Foundation
import SwiftData

/// The on-disk SwiftData container for the face index. Created once and shared;
/// the schema is fixed, so a failure here is unrecoverable and fatal. Lives in
/// its own file (see `LocalStores`) so it never collides with the duplicate index.
enum FaceContainer {
    static let shared: ModelContainer = {
        _ = LocalStores.removeLegacyDefaultStore
        let schema = Schema([FaceRow.self, PersonRow.self, ScannedAssetRow.self])
        let configuration = ModelConfiguration(schema: schema,
                                               url: LocalStores.url(named: "faces"))
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create the face-index store: \(error)")
        }
    }()
}

/// Background-isolated gateway to the face index. `@ModelActor` gives it its own
/// `ModelContext` off the main actor, so scanning a large library never touches
/// the UI context. All methods return Sendable snapshots rather than model
/// objects. Writes are incremental (upsert by unique `faceID`); rows for assets
/// that no longer exist are purged. User names, merges, hides, and covers survive
/// the normal incremental scan path because they live on `PersonRow` — and
/// `applyClustering` only ever inserts new persons, never deletes existing ones.
/// The one exception is `resetAssignments()`, which is the explicit full
/// re-cluster path and intentionally destroys all PersonRows.
///
/// Every read narrows its rows with a predicate and, where the 2 KB embedding
/// isn't needed, restricts the fetched columns with `propertiesToFetch`, so
/// listing people or counting faces never pulls every embedding into memory.
/// Lookups by ID go through chunked `contains` predicates rather than one
/// fetch per row.
@ModelActor
actor FaceStore {

    /// Upper bound on IDs per `contains` predicate. Keeps the generated SQL
    /// well under SQLite's bound-variable limit while still batching well.
    private static let idChunk = 500

    // MARK: - Counts & bookkeeping

    /// Assets already run through detection (including zero-face ones) so the
    /// scan can skip them.
    func scannedAssetIdentifiers() throws -> Set<String> {
        var descriptor = FetchDescriptor<ScannedAssetRow>()
        descriptor.propertiesToFetch = [\.localIdentifier]
        return Set(try modelContext.fetch(descriptor).map(\.localIdentifier))
    }

    /// Number of stored faces — tells the UI whether a first scan has run.
    func faceCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<FaceRow>())
    }

    // MARK: - Writes

    /// Inserts (or updates) freshly detected faces and marks their source assets
    /// scanned, in one save. Existing `personID`/`isIgnored` on an updated face
    /// are preserved. The batch's existing rows are looked up in two chunked
    /// fetches rather than one per face and one per asset.
    func insert(faces: [FaceObservation], scannedAssetIDs: [String], at scannedAt: Date) throws {
        let existingFaces = Dictionary(
            try faceRows(withIDs: faces.map(\.faceID)).map { ($0.faceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for face in faces {
            let data = Self.data(from: face.embedding)
            let box = face.boundingBox
            if let row = existingFaces[face.faceID] {
                row.embedding = data
                row.quality = face.quality
                row.bboxX = Double(box.origin.x)
                row.bboxY = Double(box.origin.y)
                row.bboxWidth = Double(box.size.width)
                row.bboxHeight = Double(box.size.height)
                row.scannedAt = scannedAt
            } else {
                modelContext.insert(
                    FaceRow(faceID: face.faceID,
                            localIdentifier: face.localIdentifier,
                            faceIndex: face.faceIndex,
                            embedding: data,
                            quality: face.quality,
                            bboxX: Double(box.origin.x),
                            bboxY: Double(box.origin.y),
                            bboxWidth: Double(box.size.width),
                            bboxHeight: Double(box.size.height),
                            personID: face.personID,
                            scannedAt: scannedAt)
                )
            }
        }

        let existingScanned = Dictionary(
            try scannedRows(withIDs: scannedAssetIDs).map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for assetID in scannedAssetIDs {
            if let row = existingScanned[assetID] {
                row.scannedAt = scannedAt
            } else {
                modelContext.insert(ScannedAssetRow(localIdentifier: assetID, scannedAt: scannedAt))
            }
        }
        try modelContext.save()
    }

    /// Persists a clustering result: creates any brand-new persons, then assigns
    /// each face to its `personID`. The faces are fetched in chunks by ID with
    /// only the columns the assignment touches, so a full re-cluster of tens
    /// of thousands of faces is a few dozen fetches and no embedding reads.
    func applyClustering(newPersons: [PersonSeed],
                         assignments: [String: String],
                         at createdAt: Date) throws {
        let existingPersons = Set(try personRows(withIDs: newPersons.map(\.personID)).map(\.personID))
        for seed in newPersons where !existingPersons.contains(seed.personID) {
            modelContext.insert(
                PersonRow(personID: seed.personID,
                          coverAssetID: seed.coverAssetID,
                          coverFaceID: seed.coverFaceID,
                          createdAt: createdAt)
            )
        }
        for row in try faceRows(withIDs: Array(assignments.keys), properties: [\.faceID, \.personID]) {
            if let personID = assignments[row.faceID] {
                row.personID = personID
            }
        }
        try modelContext.save()
    }

    // MARK: - Reads

    /// Faces that still need a cluster (new, unassigned, not ignored).
    func unclusteredFaces() throws -> [FaceObservation] {
        try modelContext.fetch(
            FetchDescriptor<FaceRow>(predicate: #Predicate { $0.personID == nil && !$0.isIgnored })
        ).map(Self.snapshot)
    }

    /// Faces already assigned to a cluster (for computing centroids).
    func clusteredFaces() throws -> [FaceObservation] {
        try modelContext.fetch(
            FetchDescriptor<FaceRow>(predicate: #Predicate { $0.personID != nil && !$0.isIgnored })
        ).map(Self.snapshot)
    }

    /// Every non-ignored face, for a full deterministic re-cluster.
    func allFaces() throws -> [FaceObservation] {
        try modelContext.fetch(
            FetchDescriptor<FaceRow>(predicate: #Predicate { !$0.isIgnored })
        ).map(Self.snapshot)
    }

    /// Deletes the entire face index — faces, people, and scanned markers — so
    /// the next scan re-detects and re-embeds everything from scratch. Needed
    /// when the embedding computation itself changes.
    func wipeAll() throws {
        try modelContext.delete(model: FaceRow.self)
        try modelContext.delete(model: PersonRow.self)
        try modelContext.delete(model: ScannedAssetRow.self)
        try modelContext.save()
    }

    /// Clears every cluster assignment and removes all PersonRows. This is the
    /// explicit full re-cluster path (`PeopleViewModel.reclusterFull`) — names,
    /// merges, hides, and covers are intentionally lost. The normal incremental
    /// path never calls this.
    func resetAssignments() throws {
        var descriptor = FetchDescriptor<FaceRow>(predicate: #Predicate { $0.personID != nil })
        descriptor.propertiesToFetch = [\.faceID, \.personID]
        for face in try modelContext.fetch(descriptor) {
            face.personID = nil
        }
        try modelContext.delete(model: PersonRow.self)
        try modelContext.save()
    }

    /// The person clusters for the People tab, biggest first. Cover falls back
    /// to the highest-quality face when the user hasn't chosen one. Reads
    /// every column except the embedding.
    func clusters() throws -> [PersonCluster] {
        var descriptor = FetchDescriptor<FaceRow>(
            predicate: #Predicate { $0.personID != nil && !$0.isIgnored }
        )
        descriptor.propertiesToFetch = [
            \.faceID, \.localIdentifier, \.personID, \.quality,
            \.bboxX, \.bboxY, \.bboxWidth, \.bboxHeight,
        ]
        let faces = try modelContext.fetch(descriptor)
        let persons = try modelContext.fetch(FetchDescriptor<PersonRow>())
        let personByID = Dictionary(persons.map { ($0.personID, $0) },
                                    uniquingKeysWith: { first, _ in first })

        var grouped: [String: [FaceRow]] = [:]
        for face in faces {
            guard let pid = face.personID else { continue }
            grouped[pid, default: []].append(face)
        }

        return grouped.map { pid, rows -> PersonCluster in
            let meta = personByID[pid]
            let best = rows.max { $0.quality < $1.quality }
            let coverFaceID = meta?.coverFaceID ?? best?.faceID
            let coverRow = rows.first { $0.faceID == coverFaceID }
            let coverBBox = coverRow.map {
                CGRect(x: $0.bboxX, y: $0.bboxY, width: $0.bboxWidth, height: $0.bboxHeight)
            }
            let photoIDs = Array(Set(rows.map(\.localIdentifier)))
            return PersonCluster(
                personID: pid,
                name: meta?.name,
                coverAssetID: meta?.coverAssetID ?? best?.localIdentifier,
                coverFaceID: coverFaceID,
                coverBoundingBox: coverBBox,
                photoIDs: photoIDs,
                faceCount: rows.count,
                isHidden: meta?.isHidden ?? false
            )
        }
        .sorted { ($0.photoCount, $0.personID) > ($1.photoCount, $1.personID) }
    }

    // MARK: - Cluster management

    func rename(personID: String, to name: String?) throws {
        guard let row = try person(personID) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        row.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try modelContext.save()
    }

    func setHidden(personID: String, _ hidden: Bool) throws {
        guard let row = try person(personID) else { return }
        row.isHidden = hidden
        try modelContext.save()
    }

    /// Merges `source` into `dest`: reassigns the source's faces and deletes the
    /// now-empty source person. The user's name and cover on `dest` are kept;
    /// where `dest` has none, the source's carry over so a merge never loses
    /// a name the user typed.
    func merge(_ source: String, into dest: String) throws {
        guard source != dest else { return }
        var descriptor = FetchDescriptor<FaceRow>(predicate: #Predicate { $0.personID == source })
        descriptor.propertiesToFetch = [\.faceID, \.personID]
        for face in try modelContext.fetch(descriptor) { face.personID = dest }
        if let sourceRow = try person(source) {
            if let destRow = try person(dest) {
                if destRow.name == nil { destRow.name = sourceRow.name }
                if destRow.coverAssetID == nil {
                    destRow.coverAssetID = sourceRow.coverAssetID
                    destRow.coverFaceID = sourceRow.coverFaceID
                }
            }
            modelContext.delete(sourceRow)
        }
        try modelContext.save()
    }

    /// Drops faces and scanned-asset markers for assets no longer in the library,
    /// then removes any person left with no faces. One pass over the face rows
    /// (identifier and person columns only) serves both the deletion and the
    /// live-person set.
    func purge(keepingAssetIDs keep: Set<String>) throws {
        var changed = false

        var faceDescriptor = FetchDescriptor<FaceRow>()
        faceDescriptor.propertiesToFetch = [\.localIdentifier, \.personID]
        var livePersonIDs = Set<String>()
        for face in try modelContext.fetch(faceDescriptor) {
            if keep.contains(face.localIdentifier) {
                if let pid = face.personID { livePersonIDs.insert(pid) }
            } else {
                modelContext.delete(face)
                changed = true
            }
        }

        var scannedDescriptor = FetchDescriptor<ScannedAssetRow>()
        scannedDescriptor.propertiesToFetch = [\.localIdentifier]
        for scanned in try modelContext.fetch(scannedDescriptor) where !keep.contains(scanned.localIdentifier) {
            modelContext.delete(scanned)
            changed = true
        }

        for person in try modelContext.fetch(FetchDescriptor<PersonRow>()) where !livePersonIDs.contains(person.personID) {
            modelContext.delete(person)
            changed = true
        }

        if changed { try modelContext.save() }
    }

    // MARK: - Helpers

    private func person(_ personID: String) throws -> PersonRow? {
        try modelContext.fetch(
            FetchDescriptor<PersonRow>(predicate: #Predicate { $0.personID == personID })
        ).first
    }

    /// Face rows for the given IDs, fetched in chunks. `properties` limits the
    /// columns loaded eagerly; anything else faults in on access.
    private func faceRows(withIDs ids: [String],
                          properties: [PartialKeyPath<FaceRow>] = []) throws -> [FaceRow] {
        var rows: [FaceRow] = []
        rows.reserveCapacity(ids.count)
        for chunk in Self.chunks(of: ids) {
            var descriptor = FetchDescriptor<FaceRow>(predicate: #Predicate { chunk.contains($0.faceID) })
            if !properties.isEmpty { descriptor.propertiesToFetch = properties }
            rows += try modelContext.fetch(descriptor)
        }
        return rows
    }

    private func scannedRows(withIDs ids: [String]) throws -> [ScannedAssetRow] {
        var rows: [ScannedAssetRow] = []
        for chunk in Self.chunks(of: ids) {
            rows += try modelContext.fetch(
                FetchDescriptor<ScannedAssetRow>(predicate: #Predicate { chunk.contains($0.localIdentifier) })
            )
        }
        return rows
    }

    private func personRows(withIDs ids: [String]) throws -> [PersonRow] {
        var rows: [PersonRow] = []
        for chunk in Self.chunks(of: ids) {
            rows += try modelContext.fetch(
                FetchDescriptor<PersonRow>(predicate: #Predicate { chunk.contains($0.personID) })
            )
        }
        return rows
    }

    private static func chunks(of ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: idChunk).map {
            Array(ids[$0..<min($0 + idChunk, ids.count)])
        }
    }

    private static func snapshot(_ row: FaceRow) -> FaceObservation {
        FaceObservation(
            localIdentifier: row.localIdentifier,
            faceIndex: row.faceIndex,
            embedding: floats(from: row.embedding),
            quality: row.quality,
            boundingBox: CGRect(x: row.bboxX, y: row.bboxY,
                                width: row.bboxWidth, height: row.bboxHeight),
            personID: row.personID
        )
    }

    private static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
