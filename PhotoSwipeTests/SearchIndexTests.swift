import XCTest
@testable import PhotoSwipe

final class SearchIndexTests: XCTestCase {
    func testResultIdentityIncludesAssetAndScore() {
        XCTAssertEqual(SearchResult(assetID: "a", score: 0.8), SearchResult(assetID: "a", score: 0.8))
        XCTAssertNotEqual(SearchResult(assetID: "a", score: 0.8), SearchResult(assetID: "b", score: 0.8))
    }

    func testRankingUsesCutoffThenDeterministicIdentifierTieBreak() {
        let results = SearchIndex.rank(
            identifiers: ["z", "b", "a", "discard"],
            scores: [0.8, 0.9, 0.9, 0.19],
            cutoff: 0.20
        )
        XCTAssertEqual(results.map(\.assetID), ["a", "b", "z"])
    }

    func testPeopleEligibilityAppliesBeforeTheLimit() {
        let ids = (0..<201).map { "asset-\($0)" }
        let scores = (0..<201).map { 1 - Float($0) / 1_000 }
        let results = SearchIndex.rank(
            identifiers: ids,
            scores: scores,
            eligibleIdentifiers: ["asset-200"],
            cutoff: 0.15
        )
        XCTAssertEqual(results.map(\.assetID), ["asset-200"])
    }
}
