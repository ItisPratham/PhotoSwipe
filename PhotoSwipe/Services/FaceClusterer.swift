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
    /// clusters. Tunable from the People screen.
    static let defaultThreshold: Float = 0.62

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
        let mergeThreshold = min(max(threshold + 0.12, 0.72), 0.90)
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
