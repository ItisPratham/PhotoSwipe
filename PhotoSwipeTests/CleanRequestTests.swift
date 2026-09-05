import XCTest
@testable import PhotoSwipe

/// The one parser behind widget links, Shortcuts, and anything typed into
/// Safari. A wrong entry here opens the wrong deck, so every accepted and
/// rejected shape is pinned.
final class CleanRequestTests: XCTestCase {
    func testEveryDocumentedLinkResolves() {
        XCTAssertEqual(parse("photoswipe://clean")?.entry, nil)
        XCTAssertEqual(parse("photoswipe://clean?entry=screenshots")?.entry, .screenshots)
        XCTAssertEqual(parse("photoswipe://clean?entry=biggest")?.entry, .biggest)
        XCTAssertEqual(parse("photoswipe://clean?entry=duplicates")?.entry, .duplicates)
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(parse("PhotoSwipe://Clean?entry=Duplicates")?.entry, .duplicates)
    }

    func testMalformedLinksAndUnknownEntriesAreRejected() {
        for raw in ["photoswipe://browse", "https://clean?entry=biggest", "photoswipe://clean/deck",
                    "photoswipe://clean?entry=", "photoswipe://clean?entry=people",
                    "photoswipe://clean?entry=screenshots&entry=biggest",
                    "photoswipe://clean?tab=browse", "photoswipe://"] {
            XCTAssertNil(parse(raw), "\(raw) must not open a deck")
        }
    }

    func testCanonicalURLRoundTrips() {
        for entry in [nil] + CleanEntry.allCases.map(Optional.init) {
            let request = CleanRequest(entry: entry)
            XCTAssertEqual(CleanRequest(url: request.url), request)
        }
        XCTAssertEqual(CleanRequest(entry: .biggest).url.absoluteString,
                       "photoswipe://clean?entry=biggest")
    }

    func testEntriesReuseTheExistingBrowseDestinations() {
        XCTAssertEqual(CleanEntry.duplicates.route, .duplicates)
        XCTAssertEqual(CleanEntry.screenshots.route, .swipe(PhotoCollection.screenshots.source))
        XCTAssertEqual(CleanEntry.biggest.route, .swipe(PhotoCollection.biggestFiles.source))
    }

    private func parse(_ raw: String) -> CleanRequest? {
        URL(string: raw).flatMap(CleanRequest.init(url:))
    }
}
