import Accelerate
import Foundation

/// Clusters face embeddings into people in two stages, which together fight both
/// failure modes of a naive threshold:
///
/// 1. **Assignment** — greedy, highest-quality faces first: each face joins the
///    nearest cluster centroid whose cosine similarity clears `threshold`, else
///    it seeds a new cluster. A slightly strict threshold here keeps *different*
///    people from being pulled into one cluster (less over-merge).
/// 2. **Centroid merge** — clusters whose *averaged* centroids are clearly the
///    same person (similarity ≥ `threshold`) are merged, to fixpoint. Averaging
///    denoises pose/lighting, so same-person splits re-join while genuinely
///    different people (whose centroids sit well below the threshold) stay apart
///    (less over-split).
///
/// Embeddings are L2-normalized, so cosine similarity is a dot product.
/// Stateless, so `Sendable` — the view model runs it off the main actor.
final class FaceClusterer: Sendable {

    /// Default cosine floor for grouping. Higher = stricter = more, smaller
    /// clusters. Tunable from the People screen's sensitivity slider.
    static let defaultThreshold: Float = 0.69

    /// Stage-2 centroid-merge floor. Tracks the assignment threshold with a
    /// small margin (merging uses *averaged*, denoised centroids, so it can be
    /// only slightly stricter) and, crucially, has **no high floor** — so
    /// loosening `threshold` to fix over-splitting actually lets a person's
    /// pose/lighting sub-clusters fuse instead of being pinned apart at 0.72.
    static func mergeThreshold(for threshold: Float) -> Float {
        min(threshold + 0.06, 0.82)
    }

    struct Result: Sendable {
        /// Every final cluster, with its chosen cover face.
        let newPersons: [PersonSeed]
        /// faceID → personID for every face.
        let assignments: [String: String]
    }

    /// Clusters all supplied faces from scratch. `existing` and `newFaces` are
    /// pooled and re-clustered together (deterministic per threshold).
    func cluster(newFaces: [FaceObservation],
                 existing: [FaceObservation],
                 threshold: Float = FaceClusterer.defaultThreshold) -> Result {
        let faces = (existing + newFaces).filter { !$0.embedding.isEmpty }

        // Stage 1: greedy assignment, best faces first.
        var buckets: [Bucket] = []
        for face in faces.sorted(by: { $0.quality > $1.quality }) {
            var bestIndex = -1
            var bestSim: Float = -1
            for (i, bucket) in buckets.enumerated() {
                let sim = dot(face.embedding, bucket.normMean)
                if sim > bestSim {
                    bestSim = sim
                    bestIndex = i
                }
            }
            if bestIndex >= 0, bestSim >= threshold {
                buckets[bestIndex].add(face)
            } else {
                buckets.append(Bucket(face: face))
            }
        }

        // Stage 2: merge same-person clusters by stricter centroid similarity.
        // Assignment can be moderately permissive so one person's varied poses
        // collect; centroid merging must be stricter because it is transitive and
        // can otherwise create large mixed-person clusters.
        let mergeThreshold = Self.mergeThreshold(for: threshold)
        mergeToFixpoint(&buckets, threshold: mergeThreshold)

        // Materialize.
        var newPersons: [PersonSeed] = []
        var assignments: [String: String] = [:]
        for bucket in buckets {
            let personID = UUID().uuidString
            newPersons.append(
                PersonSeed(personID: personID,
                           coverAssetID: bucket.coverAssetID,
                           coverFaceID: bucket.coverFaceID)
            )
            for faceID in bucket.members {
                assignments[faceID] = personID
            }
        }
        return Result(newPersons: newPersons, assignments: assignments)
    }

    /// Assigns unclustered `newFaces` to the nearest existing cluster (keyed by
    /// `personID` on the faces in `existingFaces`) or creates new clusters for
    /// them. Existing assignments are **never touched** — this is the normal
    /// incremental path that preserves user names, merges, hides, and covers.
    ///
    /// Each new face (sorted best-quality first) checks every existing centroid
    /// and joins the nearest one above `threshold`. Faces that don't fit any
    /// existing cluster form new same-run buckets, which are merged to fixpoint
    /// before being materialized as brand-new persons.
    ///
    /// Centroids are computed once from `existingFaces` and are not updated as
    /// new faces are assigned — this keeps existing cluster identity stable and
    /// prevents a misassignment from drifting an already-named centroid.
    ///
    /// Callers do **not** call `store.resetAssignments()` before this method.
    func assign(
        newFaces: [FaceObservation],
        existingFaces: [FaceObservation],
        threshold: Float = FaceClusterer.defaultThreshold
    ) -> Result {
        let validNew = newFaces.filter { !$0.embedding.isEmpty }
        guard !validNew.isEmpty else { return Result(newPersons: [], assignments: [:]) }

        // Compute one L2-normalized centroid per existing person from their
        // stored face embeddings (sum → mean → normalize).
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for face in existingFaces where !face.embedding.isEmpty {
            guard let pid = face.personID else { continue }
            if let existing = sums[pid] {
                var added = [Float](repeating: 0, count: existing.count)
                vDSP_vadd(existing, 1, face.embedding, 1, &added, 1, vDSP_Length(existing.count))
                sums[pid] = added
                counts[pid]! += 1
            } else {
                sums[pid] = face.embedding
                counts[pid] = 1
            }
        }
        let existingCentroids: [(pid: String, normMean: [Float])] = sums.compactMap { pid, sum in
            guard let n = counts[pid] else { return nil }
            var mean = [Float](repeating: 0, count: sum.count)
            var divisor = Float(n)
            vDSP_vsdiv(sum, 1, &divisor, &mean, 1, vDSP_Length(sum.count))
            return (pid, FaceEmbedder.l2normalized(mean))
        }

        // Assign each new face (best quality first) to the nearest existing
        // cluster, or accumulate into a fresh same-run bucket.
        var newBuckets: [Bucket] = []
        var assignments: [String: String] = [:]

        for face in validNew.sorted(by: { $0.quality > $1.quality }) {
            var bestPID: String? = nil
            var bestSim: Float = -1
            for entry in existingCentroids {
                let s = dot(face.embedding, entry.normMean)
                if s > bestSim { bestSim = s; bestPID = entry.pid }
            }
            if bestSim >= threshold, let pid = bestPID {
                assignments[face.faceID] = pid
                continue
            }
            var bestIdx = -1
            bestSim = -1
            for (i, b) in newBuckets.enumerated() {
                let s = dot(face.embedding, b.normMean)
                if s > bestSim { bestSim = s; bestIdx = i }
            }
            if bestIdx >= 0, bestSim >= threshold {
                newBuckets[bestIdx].add(face)
            } else {
                newBuckets.append(Bucket(face: face))
            }
        }

        let mergeThreshold = Self.mergeThreshold(for: threshold)
        mergeToFixpoint(&newBuckets, threshold: mergeThreshold)

        var newPersons: [PersonSeed] = []
        for bucket in newBuckets {
            let pid = UUID().uuidString
            newPersons.append(PersonSeed(personID: pid,
                                         coverAssetID: bucket.coverAssetID,
                                         coverFaceID: bucket.coverFaceID))
            for faceID in bucket.members { assignments[faceID] = pid }
        }
        return Result(newPersons: newPersons, assignments: assignments)
    }

    private func mergeToFixpoint(_ buckets: inout [Bucket], threshold: Float) {
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<buckets.count {
                for j in (i + 1)..<buckets.count {
                    if dot(buckets[i].normMean, buckets[j].normMean) >= threshold {
                        buckets[i].merge(buckets[j])
                        buckets.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}

/// A growing cluster: the summed embedding (for a running centroid), its member
/// face ids, and the highest-quality face seen (used as the cover).
private final class Bucket {
    private(set) var sum: [Float]
    private(set) var count: Int
    private(set) var members: [String]
    private(set) var normMean: [Float]
    private(set) var bestQuality: Float
    private(set) var coverAssetID: String
    private(set) var coverFaceID: String

    init(face: FaceObservation) {
        sum = face.embedding
        count = 1
        members = [face.faceID]
        normMean = FaceEmbedder.l2normalized(face.embedding)
        bestQuality = face.quality
        coverAssetID = face.localIdentifier
        coverFaceID = face.faceID
    }

    func add(_ face: FaceObservation) {
        sum = Bucket.add(sum, face.embedding)
        count += 1
        members.append(face.faceID)
        if face.quality > bestQuality {
            bestQuality = face.quality
            coverAssetID = face.localIdentifier
            coverFaceID = face.faceID
        }
        recomputeMean()
    }

    func merge(_ other: Bucket) {
        sum = Bucket.add(sum, other.sum)
        count += other.count
        members.append(contentsOf: other.members)
        if other.bestQuality > bestQuality {
            bestQuality = other.bestQuality
            coverAssetID = other.coverAssetID
            coverFaceID = other.coverFaceID
        }
        recomputeMean()
    }

    private func recomputeMean() {
        var mean = [Float](repeating: 0, count: sum.count)
        var divisor = Float(count)
        vDSP_vsdiv(sum, 1, &divisor, &mean, 1, vDSP_Length(sum.count))
        normMean = FaceEmbedder.l2normalized(mean)
    }

    private static func add(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        vDSP_vadd(a, 1, b, 1, &out, 1, vDSP_Length(a.count))
        return out
    }
}
