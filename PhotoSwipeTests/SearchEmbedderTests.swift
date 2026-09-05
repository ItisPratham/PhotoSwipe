import XCTest
@testable import PhotoSwipe

final class SearchEmbedderTests: XCTestCase {
    func testEmbeddingStorageRoundTripsAsFixedFloat16Payload() throws {
        var vector = [Float](repeating: 0, count: SearchEmbedder.dimension)
        vector[0] = 1.25
        vector[1] = -0.5

        let data = try SearchEmbedder.float16Data(for: vector)

        XCTAssertEqual(data.count, SearchEmbedder.embeddingByteCount)
        XCTAssertEqual(SearchEmbedder.decodeFloat16(data)?.prefix(2), [1.25, -0.5])
    }

    func testEmbeddingStorageRejectsMalformedPayload() {
        XCTAssertNil(SearchEmbedder.decodeFloat16(Data(repeating: 0, count: 12)))
    }
}
