import Foundation
import SwiftData

/// The on-disk SwiftData container for the face index. Created once and shared;
/// the schema is fixed, so a failure here is unrecoverable and fatal.
enum FaceContainer {
    static let shared: ModelContainer = {
        let schema = Schema([FaceRow.self, PersonRow.self, ScannedAssetRow.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
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
@ModelActor
actor FaceStore {

    // MARK: - Counts & bookkeeping

    /// Assets already run through detection (including zero-face ones) so the
    /// scan can skip them.
    func scannedAssetIdentifiers() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<ScannedAssetRow>()).map(\.localIdentifier))
    }

    /// Number of stored faces — tells the UI whether a first scan has run.
    func faceCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<FaceRow>())
    }

    // MARK: - Writes

    /// Inserts (or updates) freshly detected faces and marks their source assets
    /// scanned, in one save. Existing `personID`/`isIgnored` on an updated face
    /// are preserved.
    func insert(faces: [FaceObservation], scannedAssetIDs: [String], at scannedAt: Date) throws {
        for face in faces {
            let id = face.faceID
            let existing = try modelContext.fetch(
                FetchDescriptor<FaceRow>(predicate: #Predicate { $0.faceID == id })
            )
            let data = Self.data(from: face.embedding)
            let box = face.boundingBox
            if let row = existing.first {
                row.embedding = data
                row.quality = face.quality
                row.bboxX = Double(box.origin.x)
                row.bboxY = Double(box.origin.y)
                row.bboxWidth = Double(box.size.width)
                row.bboxHeight = Double(box.size.height)
                row.scannedAt = scannedAt
            } else {
                modelContext.insert(
                    FaceRow(faceID: id,
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
        for assetID in scannedAssetIDs {
            let existing = try modelContext.fetch(
                FetchDescriptor<ScannedAssetRow>(predicate: #Predicate { $0.localIdentifier == assetID })
            )
            if let row = existing.first {
                row.scannedAt = scannedAt
            } else {
                modelContext.insert(ScannedAssetRow(localIdentifier: assetID, scannedAt: scannedAt))
            }
        }
        try modelContext.save()
    }

    /// Persists a clustering result: creates any brand-new persons, then assigns
    /// each face to its `personID`.
    func applyClustering(newPersons: [PersonSeed],
                         assignments: [String: String],
                         at createdAt: Date) throws {
        for seed in newPersons {
            let pid = seed.personID
            let existing = try modelContext.fetch(
                FetchDescriptor<PersonRow>(predicate: #Predicate { $0.personID == pid })
            )
            if existing.isEmpty {
                modelContext.insert(
                    PersonRow(personID: pid,
                              coverAssetID: seed.coverAssetID,
                              coverFaceID: seed.coverFaceID,
                              createdAt: createdAt)
                )
            }
        }
        for (faceID, personID) in assignments {
            let rows = try modelContext.fetch(
                FetchDescriptor<FaceRow>(predicate: #Predicate { $0.faceID == faceID })
            )
            rows.first?.personID = personID
        }
        try modelContext.save()
    }

    // MARK: - Reads

    /// Faces that still need a cluster (new, unassigned, not ignored).
    func unclusteredFaces() throws -> [FaceObservation] {
        try modelContext.fetch(FetchDescriptor<FaceRow>())
            .filter { $0.personID == nil && !$0.isIgnored }
            .map(Self.snapshot)
    }

    /// Faces already assigned to a cluster (for computing centroids).
    func clusteredFaces() throws -> [FaceObservation] {
        try modelContext.fetch(FetchDescriptor<FaceRow>())
            .filter { $0.personID != nil && !$0.isIgnored }
            .map(Self.snapshot)
    }

    /// Every non-ignored face, for a full deterministic re-cluster.
    func allFaces() throws -> [FaceObservation] {
        try modelContext.fetch(FetchDescriptor<FaceRow>())
            .filter { !$0.isIgnored }
            .map(Self.snapshot)
    }

    /// Deletes the entire face index — faces, people, and scanned markers — so
    /// the next scan re-detects and re-embeds everything from scratch. Needed
    /// when the embedding computation itself changes.
    func wipeAll() throws {
        for face in try modelContext.fetch(FetchDescriptor<FaceRow>()) { modelContext.delete(face) }
        for person in try modelContext.fetch(FetchDescriptor<PersonRow>()) { modelContext.delete(person) }
        for scanned in try modelContext.fetch(FetchDescriptor<ScannedAssetRow>()) { modelContext.delete(scanned) }
        try modelContext.save()
    }

    /// Clears every cluster assignment and removes all PersonRows. This is the
    /// explicit full re-cluster path (`PeopleViewModel.reclusterFull`) — names,
    /// merges, hides, and covers are intentionally lost. The normal incremental
    /// path never calls this.
    func resetAssignments() throws {
        for face in try modelContext.fetch(FetchDescriptor<FaceRow>()) {
            face.personID = nil
        }
        for person in try modelContext.fetch(FetchDescriptor<PersonRow>()) {
            modelContext.delete(person)
        }
        try modelContext.save()
    }

    /// The person clusters for the People tab, biggest first. Cover falls back
    /// to the highest-quality face when the user hasn't chosen one.
    func clusters() throws -> [PersonCluster] {
        let faces = try modelContext.fetch(FetchDescriptor<FaceRow>())
            .filter { $0.personID != nil && !$0.isIgnored }
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
            let photoIDs = Array(Set(rows.map(\.localIdentifier)))
            return PersonCluster(
                personID: pid,
                name: meta?.name,
                coverAssetID: meta?.coverAssetID ?? best?.localIdentifier,
                coverFaceID: meta?.coverFaceID ?? best?.faceID,
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

    func setCover(personID: String, assetID: String, faceID: String) throws {
        if let row = try person(personID) {
            row.coverAssetID = assetID
            row.coverFaceID = faceID
        }
        try modelContext.save()
    }

    /// Merges `source` into `dest`: reassigns the source's faces and deletes the
    /// now-empty source person. The user's name/cover on `dest` are kept.
    func merge(_ source: String, into dest: String) throws {
        guard source != dest else { return }
        let faces = try modelContext.fetch(FetchDescriptor<FaceRow>())
            .filter { $0.personID == source }
        for face in faces { face.personID = dest }
        if let sourceRow = try person(source) {
            modelContext.delete(sourceRow)
        }
        try modelContext.save()
    }

    /// Hides a single stray face: drops it from its cluster and excludes it from
    /// future re-clustering.
    func ignoreFace(faceID: String) throws {
        let rows = try modelContext.fetch(
            FetchDescriptor<FaceRow>(predicate: #Predicate { $0.faceID == faceID })
        )
        if let row = rows.first {
            row.isIgnored = true
            row.personID = nil
        }
        try modelContext.save()
    }

    /// Drops faces and scanned-asset markers for assets no longer in the library,
    /// then removes any person left with no faces.
    func purge(keepingAssetIDs keep: Set<String>) throws {
        var changed = false

        for face in try modelContext.fetch(FetchDescriptor<FaceRow>()) where !keep.contains(face.localIdentifier) {
            modelContext.delete(face)
            changed = true
        }
        for scanned in try modelContext.fetch(FetchDescriptor<ScannedAssetRow>()) where !keep.contains(scanned.localIdentifier) {
            modelContext.delete(scanned)
            changed = true
        }

        let livePersonIDs = Set(
            try modelContext.fetch(FetchDescriptor<FaceRow>()).compactMap(\.personID)
        )
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
