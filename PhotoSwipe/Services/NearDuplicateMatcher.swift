import Accelerate
import Foundation
import Vision

/// Converts between the representations of a Vision feature print: the live
/// observation, the raw float vector used for matching, the compact `Data`
/// stored in the index, and (for rows written by 4.1 and earlier) the
/// archived observation.
enum FeaturePrintCodec {

    /// The observation's element buffer as `Float`s. Empty for an element
    /// type we don't understand, which grouping then skips.
    static func vector(from observation: VNFeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            return observation.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        case .double:
            return observation.data.withUnsafeBytes { raw in
                let doubles = raw.bindMemory(to: Double.self)
                return (0..<count).map { Float(doubles[$0]) }
            }
        case .unknown:
            return []
        @unknown default:
            return []
        }
    }

    /// Decodes an `NSKeyedArchiver`-archived observation (the pre-4.2 storage
    /// format). This is the slow path; the index converts each row once and
    /// stores the raw vector instead.
    static func vector(fromArchived data: Data) -> [Float] {
        guard !data.isEmpty,
              let observation = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: data)
        else { return [] }
        return vector(from: observation)
    }

    static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}

/// Disjoint sets over `0..<count`, with path compression. Indices rather than
/// strings so the hot loop never hashes.
struct IndexUnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    var count: Int { parent.count }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var cursor = x
        while parent[cursor] != root {
            let next = parent[cursor]
            parent[cursor] = root
            cursor = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}

/// The pairwise pass of duplicate grouping: joins every pair of vectors whose
/// squared L2 distance is under the threshold. Uses the identity
/// `|a-b|² = |a|² + |b|² − 2·a·b` so the whole pass is a handful of BLAS
/// matrix products instead of one vDSP call per pair. Vectors of different
/// dimension (different Vision revisions) are never compared; empty vectors
/// join nothing.
enum NearDuplicateMatcher {

    /// Returns the partition of `vectors.indices`. `seedUnions` are joined
    /// first (camera bursts). Cancelable between blocks.
    static func partition(
        vectors: [[Float]],
        distanceThreshold: Float,
        seedUnions: [(Int, Int)] = [],
        blockRows: Int = 128
    ) throws -> IndexUnionFind {
        var uf = IndexUnionFind(count: vectors.count)
        for (a, b) in seedUnions { uf.union(a, b) }

        var byDimension: [Int: [Int]] = [:]
        for (index, vector) in vectors.enumerated() where !vector.isEmpty {
            byDimension[vector.count, default: []].append(index)
        }

        let threshold2 = distanceThreshold * distanceThreshold
        for (dimension, members) in byDimension where members.count > 1 {
            try unionNearPairs(members: members,
                               dimension: dimension,
                               vectors: vectors,
                               threshold2: threshold2,
                               blockRows: max(1, blockRows),
                               into: &uf)
        }
        return uf
    }

    /// Packs the member vectors into one row-major matrix, then for each block
    /// of rows computes the dot products against every later row in a single
    /// `sgemm`, and unions the pairs under the threshold. Only the strict
    /// upper triangle is examined.
    private static func unionNearPairs(
        members: [Int],
        dimension d: Int,
        vectors: [[Float]],
        threshold2: Float,
        blockRows: Int,
        into uf: inout IndexUnionFind
    ) throws {
        let m = members.count
        var matrix = [Float](repeating: 0, count: m * d)
        var norms = [Float](repeating: 0, count: m)
        matrix.withUnsafeMutableBufferPointer { mp in
            norms.withUnsafeMutableBufferPointer { np in
                for (row, index) in members.enumerated() {
                    vectors[index].withUnsafeBufferPointer { vp in
                        (mp.baseAddress! + row * d).update(from: vp.baseAddress!, count: d)
                        vDSP_svesq(vp.baseAddress!, 1, np.baseAddress! + row, vDSP_Length(d))
                    }
                }
            }
        }

        var products = [Float](repeating: 0, count: blockRows * m)
        // Scratch row of squared distances for one matrix row at a time.
        var distances = [Float](repeating: 0, count: m)
        var start = 0
        while start < m - 1 {
            try Task.checkCancellation()
            let rows = min(blockRows, m - 1 - start)
            let colStart = start + 1
            let cols = m - colStart

            // products[rows × cols] = matrix[start..<start+rows] · matrix[colStart..<m]ᵀ
            matrix.withUnsafeBufferPointer { mp in
                products.withUnsafeMutableBufferPointer { pp in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(rows), Int32(cols), Int32(d), 1,
                                mp.baseAddress! + start * d, Int32(d),
                                mp.baseAddress! + colStart * d, Int32(d),
                                0, pp.baseAddress!, Int32(cols))
                }
            }

            // Per row: d² = |a|² + |b|² − 2·a·b as two vDSP passes, then a
            // vector minimum. Most rows have no neighbour under the
            // threshold, so they are dismissed by the minimum alone; only
            // rows with a hit are scanned element by element.
            products.withUnsafeBufferPointer { pp in
                norms.withUnsafeBufferPointer { np in
                    distances.withUnsafeMutableBufferPointer { dp in
                        var minusTwo: Float = -2
                        for r in 0..<rows {
                            let i = start + r
                            // Columns at or before i belong to the lower triangle.
                            let firstCol = max(0, i + 1 - colStart)
                            let n = cols - firstCol
                            guard n > 0 else { continue }
                            var ni = np[i]
                            let rowBase = pp.baseAddress! + r * cols + firstCol
                            let otherNorms = np.baseAddress! + colStart + firstCol
                            vDSP_vsmsa(rowBase, 1, &minusTwo, &ni, dp.baseAddress!, 1, vDSP_Length(n))
                            vDSP_vadd(dp.baseAddress!, 1, otherNorms, 1, dp.baseAddress!, 1, vDSP_Length(n))
                            var minimum: Float = 0
                            vDSP_minv(dp.baseAddress!, 1, &minimum, vDSP_Length(n))
                            guard minimum < threshold2 else { continue }
                            for c in 0..<n where dp[c] < threshold2 {
                                uf.union(members[i], members[colStart + firstCol + c])
                            }
                        }
                    }
                }
            }
            start += rows
        }
    }
}
