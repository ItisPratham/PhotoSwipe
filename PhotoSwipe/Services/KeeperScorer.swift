import Foundation

/// Picks the shot to suggest keeping in a duplicate group. Each signal is
/// rank-normalised *within the group* (so a pair still produces a spread) and
/// the ranks are combined with fixed weights:
///
///   0.45 · sharpness + 0.25 · face quality + 0.15 · pixel count + 0.15 · aesthetics
///
/// A signal that isn't available for every member of the group (rows indexed
/// before it was measured, no face scan yet, pre-iOS 18 for aesthetics) is
/// dropped and the remaining weights renormalised, so the score never
/// compares a measured member against an unmeasured one. Ties break to the
/// oldest photo, then by id, so the same group always names the same keeper.
enum KeeperScorer {
    struct Candidate {
        let id: String
        let created: Date?
        let pixelArea: Int
        let sharpness: Float?
        /// Best face capture quality in the photo; nil when no face scan has
        /// run (the term is then dropped), 0 when the scan found no face.
        let faceQuality: Float?
        let aesthetic: Float?
    }

    static func keeper(among candidates: [Candidate]) -> String? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0].id }

        var weighted: [(weight: Float, ranks: [Float])] = []
        func add(_ weight: Float, _ values: [Float?]) {
            guard values.allSatisfy({ $0 != nil }) else { return }
            weighted.append((weight, ranks(of: values.map { $0! })))
        }
        add(0.45, candidates.map(\.sharpness))
        add(0.25, candidates.map(\.faceQuality))
        add(0.15, candidates.map { Float($0.pixelArea) })
        add(0.15, candidates.map(\.aesthetic))

        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        var scores = [Float](repeating: 0, count: candidates.count)
        if totalWeight > 0 {
            for (weight, ranks) in weighted {
                for i in scores.indices { scores[i] += weight / totalWeight * ranks[i] }
            }
        }

        let best = candidates.indices.max { a, b in
            if scores[a] != scores[b] { return scores[a] < scores[b] }
            let da = candidates[a].created ?? .distantFuture
            let db = candidates[b].created ?? .distantFuture
            if da != db { return da > db }          // older wins → "greater"
            return candidates[a].id > candidates[b].id
        }
        return best.map { candidates[$0].id }
    }

    /// Fractional ranks in 0…1 (0 = lowest value, 1 = highest); equal values
    /// share the average of the positions they span.
    static func ranks(of values: [Float]) -> [Float] {
        let n = values.count
        guard n > 1 else { return [Float](repeating: 1, count: n) }
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n, values[order[j + 1]] == values[order[i]] { j += 1 }
            let average = Float(i + j) / 2
            for k in i...j { ranks[order[k]] = average / Float(n - 1) }
            i = j + 1
        }
        return ranks
    }
}
