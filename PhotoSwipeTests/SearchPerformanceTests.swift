import Accelerate
import CoreGraphics
import XCTest
@testable import PhotoSwipe

/// The v6 footprint and latency numbers, as tests rather than throwaway logs.
///
/// **Run these on a device.** The Simulator uses the Mac's cores and has no
/// Neural Engine, so its Core ML timings say nothing about a phone. Select
/// your iPhone in Xcode and run this class; every measurement prints a line
/// beginning with `[perf]`, which is what belongs in
/// `docs/v6-acceptance.md`.
///
/// They skip themselves when the search packages are not installed, so a
/// model-free checkout still passes.
final class SearchPerformanceTests: XCTestCase {
    /// The brief's bar: a warm query on a 30k library, after the debounce.
    private static let warmQueryBudget: Duration = .milliseconds(300)
    private static let libraryCount = 30_000

    private var embedder: SearchEmbedder!

    override func setUpWithError() throws {
        let embedder = SearchEmbedder(bundle: .main)
        try XCTSkipUnless(
            embedder.availability == .ready,
            "Search packages are not installed in this build; nothing to measure."
        )
        self.embedder = embedder
    }

    // MARK: - Model latency

    func testColdLoadThenSteadyStateTextLatency() async throws {
        let clock = ContinuousClock()
        let cold = try await clock.measure { _ = try await embedder.textEmbedding(for: "dog on the beach") }
        report("text tower cold load + first query", cold)

        var samples: [Duration] = []
        for query in ["birthday cake", "whiteboard", "sunset over water", "receipt", "my dog in snow"] {
            samples.append(try await clock.measure { _ = try await embedder.textEmbedding(for: query) })
        }
        report("text query, warm", samples)
        XCTAssertLessThan(median(samples), Self.warmQueryBudget,
                          "Text inference alone already exceeds the whole warm-query budget.")
    }

    func testImageEmbeddingLatency() async throws {
        let image = try makeImage(side: SearchEmbedder.imageSide)
        let clock = ContinuousClock()
        _ = try await embedder.imageEmbedding(for: image)  // Load the tower first.

        var samples: [Duration] = []
        for _ in 0..<10 {
            samples.append(try await clock.measure { _ = try await embedder.imageEmbedding(for: image) })
        }
        let each = median(samples)
        report("image embedding, per photo", samples)
        // What that means for a full pass, which is the number that decides
        // whether indexing is an afternoon or a coffee break.
        let projected = each * Double(Self.libraryCount)
        print("[perf] projected indexing of \(Self.libraryCount) photos: \(format(projected)) of inference "
              + "(excluding thumbnail loading, which the shared scan overlaps)")
    }

    // MARK: - Retrieval

    func testRankingThirtyThousandVectors() throws {
        let dimension = SearchEmbedder.dimension
        let matrix = randomMatrix(rows: Self.libraryCount, dimension: dimension)
        let query = normalized(randomVector(dimension))
        let clock = ContinuousClock()

        var samples: [Duration] = []
        for _ in 0..<10 {
            samples.append(clock.measure {
                let scores = SearchIndex.scores(query: query, matrix: matrix, rows: Self.libraryCount)
                XCTAssertEqual(scores.count, Self.libraryCount)
            })
        }
        report("ranking \(Self.libraryCount) vectors", samples)
    }

    func testWarmQueryEndToEndStaysWithinBudget() async throws {
        let matrix = randomMatrix(rows: Self.libraryCount, dimension: SearchEmbedder.dimension)
        let clock = ContinuousClock()
        _ = try await embedder.textEmbedding(for: "warm up")

        var samples: [Duration] = []
        for query in ["dog on the beach", "birthday cake", "whiteboard"] {
            samples.append(try await clock.measure {
                let vector = try await embedder.textEmbedding(for: query)
                let scores = SearchIndex.scores(query: vector, matrix: matrix, rows: Self.libraryCount)
                _ = SearchIndex.rank(identifiers: (0..<Self.libraryCount).map(String.init),
                                     scores: scores, cutoff: SearchIndex.defaultCutoff)
            })
        }
        report("warm query end to end (text tower + ranking + cutoff)", samples)
        XCTAssertLessThan(median(samples), Self.warmQueryBudget,
                          "The brief's bar is a warm query under 300 ms on a 30k library.")
    }

    // MARK: - Footprint

    func testMemoryHeldByTheSearchMatrix() throws {
        let dimension = SearchEmbedder.dimension
        var matrix = randomMatrix(rows: Self.libraryCount, dimension: dimension)
        let identifiers = (0..<Self.libraryCount).map { "asset-\($0)" }
        // Touch every page so nothing is lazily faulted out of the sample.
        var checksum: Float = 0
        vDSP_sve(matrix, 1, &checksum, vDSP_Length(matrix.count))
        let held = footprintBytes()

        // The matrix cost itself is deterministic; the sample worth recording
        // is the absolute process footprint while the index is resident. A
        // before/after delta is not reliable here — Core ML releases its own
        // buffers on its own schedule, which can make the difference negative.
        let expected = Int64(Self.libraryCount * dimension * MemoryLayout<Float>.size)
        print("[perf] search matrix (\(Self.libraryCount)x\(dimension) Float32): "
              + ByteCountFormatter.string(fromByteCount: expected, countStyle: .memory))
        print("[perf] process footprint holding the index and both towers: "
              + ByteCountFormatter.string(fromByteCount: Int64(held), countStyle: .memory))

        XCTAssertEqual(matrix.count, Self.libraryCount * dimension)
        XCTAssertEqual(identifiers.count, Self.libraryCount)
        XCTAssertTrue(checksum.isFinite)
        // SigLIP 2 carries a 256k embedding table, so its text tower is about
        // four times MobileCLIP's and the whole process sits far higher.
        let budget = SearchEmbedder.spec.family == .sigLIP2 ? 900 : 500
        XCTAssertLessThan(held, UInt64(budget) * 1024 * 1024,
                          "A resident search index should not put the app near a jetsam limit.")
        matrix.removeAll(keepingCapacity: false)
    }

    // MARK: - Helpers

    private func makeImage(side: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(context.makeImage())
    }

    private func randomVector(_ dimension: Int) -> [Float] {
        (0..<dimension).map { _ in Float.random(in: -1...1) }
    }

    private func normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
        var divisor = max(sqrt(sum), .leastNormalMagnitude)
        var output = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &output, 1, vDSP_Length(vector.count))
        return output
    }

    private func randomMatrix(rows: Int, dimension: Int) -> [Float] {
        var matrix = [Float](repeating: 0, count: rows * dimension)
        for row in 0..<rows {
            let vector = normalized(randomVector(dimension))
            matrix.replaceSubrange(row * dimension..<(row + 1) * dimension, with: vector)
        }
        return matrix
    }

    private func median(_ samples: [Duration]) -> Duration {
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return seconds >= 1 ? String(format: "%.2f s", seconds) : String(format: "%.1f ms", seconds * 1000)
    }

    private func report(_ label: String, _ sample: Duration) {
        print("[perf] \(label): \(format(sample))")
    }

    private func report(_ label: String, _ samples: [Duration]) {
        let sorted = samples.sorted()
        print("[perf] \(label): median \(format(median(samples))) "
              + "(min \(format(sorted.first!)), max \(format(sorted.last!)), n=\(samples.count))")
    }

    /// `phys_footprint` is what jetsam actually measures, unlike resident size.
    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
