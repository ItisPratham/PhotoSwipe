import XCTest
@testable import PhotoSwipe

final class DeckSourceSearchTests: XCTestCase {
    func testSearchSourceKeepsQueryAndRankedIdentifierOrder() {
        let source = DeckSource.search(query: "beach", ids: ["third", "first"])
        XCTAssertEqual(source, DeckSource.search(query: "beach", ids: ["third", "first"]))
        XCTAssertNotEqual(source, DeckSource.search(query: "beach", ids: ["first", "third"]))
    }
}
